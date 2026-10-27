#pragma once
// Per-user Windows login item. Never add this to the synced backend schema.
#include <windows.h>
#include <shellapi.h>
#include <string>

namespace fulcrum::windows {
inline constexpr wchar_t kAutostartRegistry[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
inline bool BackgroundLaunch() {
  int argc = 0;
  LPWSTR* argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) return false;
  bool const active = argc > 1 && ::lstrcmpiW(argv[1], L"--background") == 0;
  ::LocalFree(argv);
  return active;
}
inline bool AutostartEnabled() {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kAutostartRegistry, 0, KEY_READ,
                      &key) != ERROR_SUCCESS) return false;
  wchar_t buffer[1024]{};
  DWORD size = sizeof(buffer), type = 0;
  auto const status = ::RegQueryValueExW(key, L"Fulcrum", nullptr, &type,
                                          reinterpret_cast<BYTE*>(buffer), &size);
  ::RegCloseKey(key);
  return status == ERROR_SUCCESS && type == REG_SZ &&
         size >= sizeof(wchar_t) && buffer[0] != L'\0';
}
inline bool SetAutostart(bool enabled) {
  if (!enabled) {
    HKEY key = nullptr;
    if (::RegOpenKeyExW(HKEY_CURRENT_USER, kAutostartRegistry, 0,
                        KEY_SET_VALUE, &key) != ERROR_SUCCESS) return true;
    auto const rc = ::RegDeleteValueW(key, L"Fulcrum");
    ::RegCloseKey(key);
    return rc == ERROR_SUCCESS || rc == ERROR_FILE_NOT_FOUND;
  }
  wchar_t executable[32768]{};
  DWORD const chars = ::GetModuleFileNameW(nullptr, executable, 32768);
  if (chars == 0 || chars >= 32768) return false;
  std::wstring command = L"\"" + std::wstring(executable) +
                         L"\" --background";
  // Windows Run command lines must remain within the documented limit.
  if (command.size() >= 260) return false;
  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kAutostartRegistry, 0, nullptr,
                        0, KEY_SET_VALUE, nullptr, &key, nullptr)
      != ERROR_SUCCESS) return false;
  DWORD const bytes = static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t));
  auto const rc = ::RegSetValueExW(key, L"Fulcrum", 0, REG_SZ,
        reinterpret_cast<BYTE const*>(command.c_str()), bytes);
  ::RegCloseKey(key);
  return rc == ERROR_SUCCESS;
}
}  // namespace fulcrum::windows
