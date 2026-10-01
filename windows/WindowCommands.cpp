#include "pch.h"
#include "WindowCommands.h"

#include <map>
#include <winuser.h>

namespace fulcrum {
namespace {

// Original geometry per window, for Restore. Stale entries are harmless:
// restoring into a saved RECT just moves the window where it was.
std::map<HWND, RECT>& Saved() {
  static std::map<HWND, RECT> map;
  return map;
}

RECT WorkArea(HWND hwnd) {
  HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{sizeof(info)};
  GetMonitorInfoW(monitor, &info);
  return info.rcWork;
}

bool Apply(HWND hwnd, int x, int y, int w, int h) {
  return SetWindowPos(hwnd, nullptr, x, y, w, h,
                      SWP_NOZORDER | SWP_NOACTIVATE) != 0;
}

void Unmaximize(HWND hwnd) {
  if (IsZoomed(hwnd)) {
    ShowWindow(hwnd, SW_RESTORE);
  }
}

} // namespace

bool RunWindowCommand(std::string const& id) {
  HWND hwnd = GetForegroundWindow();
  if (hwnd == nullptr) {
    return false;
  }
  RECT area = WorkArea(hwnd);
  int const aw = area.right - area.left;
  int const ah = area.bottom - area.top;

  if (id == "win.left" || id == "win.right" || id == "win.maximize" ||
      id == "win.almost-max" || id == "win.center") {
    RECT current{};
    GetWindowRect(hwnd, &current);
    Saved()[hwnd] = current;
  }

  if (id == "win.left") {
    Unmaximize(hwnd);
    return Apply(hwnd, area.left, area.top, aw / 2, ah);
  }
  if (id == "win.right") {
    Unmaximize(hwnd);
    return Apply(hwnd, area.left + aw / 2, area.top, aw / 2, ah);
  }
  if (id == "win.maximize") {
    Unmaximize(hwnd);
    return Apply(hwnd, area.left, area.top, aw, ah);
  }
  if (id == "win.almost-max") {
    Unmaximize(hwnd);
    int const w = aw * 9 / 10;
    int const h = ah * 88 / 100;
    return Apply(hwnd, area.left + (aw - w) / 2, area.top + (ah - h) / 2, w, h);
  }
  if (id == "win.center") {
    RECT current{};
    GetWindowRect(hwnd, &current);
    int const w = current.right - current.left;
    int const h = current.bottom - current.top;
    return Apply(hwnd, area.left + (aw - w) / 2, area.top + (ah - h) / 2, w, h);
  }
  if (id == "win.restore") {
    auto it = Saved().find(hwnd);
    if (it == Saved().end()) {
      return false;
    }
    RECT saved = it->second;
    Saved().erase(it);
    return Apply(hwnd, saved.left, saved.top, saved.right - saved.left,
                 saved.bottom - saved.top);
  }
  return false;
}

} // namespace fulcrum
