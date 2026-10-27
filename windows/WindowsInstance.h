#pragma once

#include <windows.h>
#include <string>

// HWND-only activation handshake. Isolated product acceptance runs and
// installed Fulcrum processes use different SingleInstanceLease IDs, so
// the window property is also keyed by the exact lease ID.
namespace fulcrum::windows {

inline constexpr UINT kSummonResidentMessage = WM_APP + 5;
inline constexpr UINT kAcceptanceQuitMessage = WM_APP + 6;

inline std::wstring InstanceId() {
  std::wstring id = L"site.jrtx.fulcrum";
  wchar_t isolated[256]{};
  DWORD const length =
      ::GetEnvironmentVariableW(L"FULCRUM_INSTANCE_ID", isolated, 256);
  if (length > 0 && length < 256) id.assign(isolated, length);
  return id;
}

inline std::wstring InstanceProperty() {
  return L"Rivet.Fulcrum.Instance." + InstanceId();
}

inline void MarkResidentWindow(HWND hwnd) {
  if (!hwnd) return;
  auto const property = InstanceProperty();
  ::SetPropW(hwnd, property.c_str(),
             reinterpret_cast<HANDLE>(static_cast<UINT_PTR>(1)));
}

inline HWND FindResidentWindow() {
  auto const property = InstanceProperty();
  HWND hwnd = nullptr;
  while ((hwnd = ::FindWindowExW(nullptr, hwnd, nullptr, L"Fulcrum")) != nullptr) {
    if (::GetPropW(hwnd, property.c_str()) != nullptr) return hwnd;
  }
  return nullptr;
}

}  // namespace fulcrum::windows
