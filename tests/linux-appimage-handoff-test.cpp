// Headless process-external AppImage handoff transaction test.
// Uses executable shell fixtures to test Rivet's atomic swap/rollback without
// requiring FUSE or a real AppImage mount in CI. The release acceptance gate
// still calls for genuine old-version AppImage -> new-version upgrades.
#include "update_handoff.hpp"

#include <glib.h>
#include <sys/wait.h>
#include <unistd.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
namespace fs = std::filesystem;
using namespace std::chrono_literals;

std::string digest(std::string const& bytes) {
  GChecksum* ctx = g_checksum_new(G_CHECKSUM_SHA256);
  if (!ctx) throw std::runtime_error("could not allocate SHA256");
  g_checksum_update(ctx, reinterpret_cast<guchar const*>(bytes.data()),
                    static_cast<gssize>(bytes.size()));
  std::string value(g_checksum_get_string(ctx));
  g_checksum_free(ctx);
  return value;
}

void write_executable(fs::path const& path, std::string const& contents) {
  std::ofstream out(path);
  out << contents;
  out.close();
  if (!out) throw std::runtime_error("could not write fixture");
  fs::permissions(path, fs::perms::owner_all | fs::perms::group_read |
                             fs::perms::group_exec);
}

std::string slurp(fs::path const& path) {
  std::ifstream in(path);
  if (!in) return {};
  return std::string((std::istreambuf_iterator<char>(in)),
                     std::istreambuf_iterator<char>());
}

void until(std::function<bool()> done, std::string const& why) {
  for (int n = 0; n < 120; ++n) {
    if (done()) return;
    std::this_thread::sleep_for(100ms);
  }
  throw std::runtime_error("timeout: " + why);
}

void case_handoff(fs::path const& root, bool valid_candidate) {
  const auto id = valid_candidate ? "site.jrtx.fulcrum.test.success"
                                  : "site.jrtx.fulcrum.test.rollback";
  fs::create_directories(root);
  const fs::path target = root / "Installed.AppImage";
  const fs::path candidate = root / "Verified.AppImage";
  const std::string old = "#!/bin/sh\nsleep 10\n# old-install\n";
  const std::string replacement =
      valid_candidate ? "#!/bin/sh\nsleep 15\n# new-install\n"
                      : "#!/bin/sh\nexit 3\n# failed-install\n";
  write_executable(target, old);
  write_executable(candidate, replacement);

  pid_t pid = fork();
  if (pid < 0) throw std::runtime_error("fork failed");
  if (pid == 0) {
    try {
      rivet::update::AppImageHandoffOptions options;
      options.version = "0.14.0";
      options.artifact_sha256 = digest(replacement);
      options.rollback_allowed = true;
      options.settle_seconds = 1;
      rivet::update::AppImageHandoff::LaunchReplacement(
          id, candidate, target, {}, 5, options);
      _exit(0);
    } catch (...) {
      _exit(42);
    }
  }

  int status = 0;
  if (waitpid(pid, &status, 0) != pid ||
      !WIFEXITED(status) || WEXITSTATUS(status) != 0)
    throw std::runtime_error("failed to spawn external handoff");

  if (valid_candidate) {
    until([&] {
      return slurp(target) == replacement &&
             !fs::exists(fs::path(target.string() + ".rivet-backup")) &&
             !fs::exists(fs::path(target.string() + ".rivet-handoff-journal"));
    }, "new executable must replace old one and commit its journal");
    auto failure = rivet::update::AppImageHandoff::ConsumeFailure(id);
    if (failure) throw std::runtime_error("valid replacement reported failure");
  } else {
    until([&] {
      return slurp(target) == old &&
             !fs::exists(fs::path(target.string() + ".rivet-handoff-journal")) &&
             rivet::update::AppImageHandoff::ConsumeFailure(id).has_value();
    }, "unhealthy replacement must restore old executable and record failure");
  }
}

}  // namespace

int main() {
  std::string templ = "/tmp/fulcrum-updater-integration-XXXXXX";
  std::vector<char> path(templ.begin(), templ.end());
  path.push_back('\0');
  char* temp = mkdtemp(path.data());
  if (!temp) return 1;
  fs::path const root(temp);
  auto cleanup = [&] { std::error_code ec; fs::remove_all(root, ec); };
  try {
    fs::create_directories(root / "state");
    if (setenv("XDG_STATE_HOME", (root / "state").c_str(), 1) != 0)
      throw std::runtime_error("setenv failed");
    case_handoff(root / "success", true);
    case_handoff(root / "rollback", false);
    cleanup();
    std::cout << "AppImage process-external swap and rollback passed\n";
    return 0;
  } catch (std::exception const& e) {
    std::cerr << "AppImage transaction failed: " << e.what() << "\n";
    cleanup();
    return 1;
  }
}
