#pragma once
// Per-user XDG autostart belongs to the local host, not synced settings.
#include <gtk/gtk.h>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <system_error>

inline std::filesystem::path fulcrum_autostart_path() {
  char const* config = std::getenv("XDG_CONFIG_HOME");
  auto const base = config && *config ? std::filesystem::path(config)
      : std::filesystem::path(g_get_home_dir()) / ".config";
  return base / "autostart" / "site.jrtx.fulcrum.desktop";
}

inline bool fulcrum_autostart_enabled() {
  return std::filesystem::is_regular_file(fulcrum_autostart_path());
}

inline std::string fulcrum_desktop_exec_quote(std::string const& path) {
  std::string result(1, '"');
  for (char c : path) {
    if (c == '%') result += "%%";
    else {
      if (c == '$' || c == 0x60 || c == '\\' || c == '"') result += '\\';
      result += c;
    }
  }
  return result + '"';
}

inline bool fulcrum_set_autostart(bool enabled,
                                  std::string const& executable,
                                  std::string& error) {
  try {
    auto const path = fulcrum_autostart_path();
    if (!enabled) {
      std::error_code ec;
      std::filesystem::remove(path, ec);
      if (ec) { error = ec.message(); return false; }
      return true;
    }
    if (!std::filesystem::exists(executable)) {
      error = "Fulcrum executable does not exist"; return false;
    }
    std::filesystem::create_directories(path.parent_path());
    std::string const entry =
        "[Desktop Entry]\nType=Application\nName=Fulcrum\n"
        "Comment=Start Fulcrum in the background at login\n"
        "Terminal=false\nX-GNOME-Autostart-enabled=true\nExec=" +
        fulcrum_desktop_exec_quote(executable) + " --background\n";
    GError* write_error = nullptr;
    bool const ok = g_file_set_contents(path.string().c_str(),
                                        entry.c_str(), -1, &write_error);
    if (!ok) {
      error = write_error ? write_error->message : "Could not write autostart";
      if (write_error) g_error_free(write_error);
    }
    return ok;
  } catch (std::exception const& e) {
    error = e.what(); return false;
  }
}
