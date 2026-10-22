// Real release-artifact AppImage upgrade through Rivet's detached handoff.
// Unlike linux-appimage-handoff-test.cpp, this test launches an actual signed
// release AppImage after replacing a previous released AppImage. The caller
// runs it under xvfb + D-Bus with APPIMAGE_EXTRACT_AND_RUN=1 (no FUSE needed).
#include "update_handoff.hpp"

#include <glib.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
namespace fs = std::filesystem;
using namespace std::chrono_literals;

std::string file_digest(fs::path const& path) {
  GChecksum* ctx = g_checksum_new(G_CHECKSUM_SHA256);
  if (!ctx) throw std::runtime_error("could not allocate SHA-256");
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    g_checksum_free(ctx);
    throw std::runtime_error("could not read AppImage: " + path.string());
  }
  std::vector<char> buffer(1024 * 1024);
  while (input) {
    input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    auto const count = input.gcount();
    if (count > 0) {
      g_checksum_update(ctx, reinterpret_cast<guchar const*>(buffer.data()),
                        static_cast<gssize>(count));
    }
  }
  if (!input.eof()) {
    g_checksum_free(ctx);
    throw std::runtime_error("failed while hashing AppImage: " + path.string());
  }
  std::string result(g_checksum_get_string(ctx));
  g_checksum_free(ctx);
  return result;
}

void wait_for(std::function<bool()> predicate, std::string const& reason) {
  for (int i = 0; i < 240; ++i) {
    if (predicate()) return;
    std::this_thread::sleep_for(100ms);
  }
  throw std::runtime_error("timeout: " + reason);
}

bool numeric_pid(std::string const& value) {
  return !value.empty() &&
      value.find_first_not_of("0123456789") == std::string::npos;
}

std::string proc_text(fs::path const& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return {};
  return std::string((std::istreambuf_iterator<char>(in)),
                     std::istreambuf_iterator<char>());
}

std::vector<pid_t> appimage_processes(fs::path const& target) {
  std::vector<pid_t> result;
  auto const target_text = target.string();
  for (auto const& entry : fs::directory_iterator("/proc")) {
    auto const name = entry.path().filename().string();
    if (!numeric_pid(name)) continue;
    pid_t const pid = static_cast<pid_t>(std::strtol(name.c_str(), nullptr, 10));
    if (pid <= 1 || pid == ::getpid()) continue;
    auto const base = entry.path();
    if (proc_text(base / "cmdline").find(target_text) != std::string::npos ||
        proc_text(base / "environ").find("APPIMAGE=" + target_text) != std::string::npos) {
      result.push_back(pid);
    }
  }
  return result;
}

void stop_relaunched_app(fs::path const& target) {
  auto pids = appimage_processes(target);
  for (pid_t pid : pids) ::kill(pid, SIGTERM);
  for (int i = 0; i < 30; ++i) {
    std::this_thread::sleep_for(100ms);
    pids = appimage_processes(target);
    if (pids.empty()) return;
  }
  for (pid_t pid : pids) ::kill(pid, SIGKILL);
}

void real_upgrade(fs::path const& old_release,
                  fs::path const& new_release,
                  std::string const& expected_sha,
                  std::string const& expected_version) {
  if (!old_release.is_absolute() || !new_release.is_absolute()) {
    throw std::runtime_error("release artifact paths must be absolute");
  }
  if (!fs::is_regular_file(old_release) || !fs::is_regular_file(new_release)) {
    throw std::runtime_error("both official release AppImages must exist");
  }
  if (expected_sha.size() != 64 ||
      file_digest(new_release) != expected_sha) {
    throw std::runtime_error("new release AppImage SHA-256 does not match the manifest sidecar");
  }
  if (file_digest(old_release) == expected_sha) {
    throw std::runtime_error("old and new AppImage assets must be different");
  }

  std::string templ = "/tmp/fulcrum-real-appimage-upgrade-XXXXXX";
  std::vector<char> temp(templ.begin(), templ.end());
  temp.push_back('\0');
  char* made = ::mkdtemp(temp.data());
  if (!made) throw std::runtime_error("mkdtemp failed");
  fs::path const root(made);
  fs::path const state = root / "state";
  fs::path const install = root / "install";
  fs::path const updates = root / "updates";
  fs::create_directories(state);
  fs::create_directories(install);
  fs::create_directories(updates);
  fs::path const target = install / "Fulcrum.AppImage";
  fs::path const candidate = updates / new_release.filename();
  fs::copy_file(old_release, target);
  fs::copy_file(new_release, candidate);
  fs::permissions(target, fs::perms::owner_read | fs::perms::owner_write |
                         fs::perms::owner_exec | fs::perms::group_read |
                         fs::perms::group_exec);
  fs::permissions(candidate, fs::perms::owner_read | fs::perms::owner_write |
                             fs::perms::owner_exec | fs::perms::group_read |
                             fs::perms::group_exec);
  if (::setenv("XDG_STATE_HOME", state.c_str(), 1) != 0) {
    fs::remove_all(root);
    throw std::runtime_error("could not isolate XDG_STATE_HOME");
  }

  constexpr char const* application_id = "site.jrtx.fulcrum.real-upgrade-test";
  pid_t const caller = ::fork();
  if (caller < 0) {
    fs::remove_all(root);
    throw std::runtime_error("fork failed");
  }
  if (caller == 0) {
    try {
      rivet::update::AppImageHandoffOptions options;
      options.version = expected_version;
      options.artifact_sha256 = expected_sha;
      options.rollback_allowed = true;
      options.settle_seconds = 5;
      rivet::update::AppImageHandoff::LaunchReplacement(
          application_id, candidate, target, {}, 10, options);
      ::_exit(0);
    } catch (...) {
      ::_exit(42);
    }
  }

  int status = 0;
  if (::waitpid(caller, &status, 0) != caller ||
      !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    stop_relaunched_app(target);
    fs::remove_all(root);
    throw std::runtime_error("could not start detached AppImage handoff");
  }

  auto const journal = fs::path(target.string() + ".rivet-handoff-journal");
  auto const backup = fs::path(target.string() + ".rivet-backup");
  try {
    wait_for([&] {
      return fs::is_regular_file(target) &&
             file_digest(target) == expected_sha &&
             !fs::exists(journal) && !fs::exists(backup);
    }, "official v" + expected_version +
       " AppImage must replace the older release, launch, and commit");
    if (auto failure = rivet::update::AppImageHandoff::ConsumeFailure(application_id)) {
      throw std::runtime_error("handoff reported failure: " + failure->message);
    }
    if (file_digest(target) != expected_sha) {
      throw std::runtime_error("installed AppImage digest changed after commit");
    }
    std::cout << "PASS: official AppImage old-to-new replacement, SHA-256, "
              << "launch health check and commit for v" << expected_version << "\n";
  } catch (...) {
    stop_relaunched_app(target);
    fs::remove_all(root);
    throw;
  }

  // Do not leave the real app or the Xvfb session running after the test.
  stop_relaunched_app(target);
  fs::remove_all(root);
}
}  // namespace

int main(int argc, char** argv) {
  if (argc != 5 || std::string(argv[1]) != "--real-upgrade") {
    std::cerr << "usage: " << argv[0]
              << " --real-upgrade OLD_APPIMAGE NEW_APPIMAGE EXPECTED_SHA256 NEW_VERSION\n";
    return 2;
  }
  try {
    real_upgrade(fs::absolute(argv[2]), fs::absolute(argv[3]), argv[4], argv[5]);
    return 0;
  } catch (std::exception const& e) {
    std::cerr << "real AppImage upgrade failed: " << e.what() << "\n";
    return 1;
  }
}
