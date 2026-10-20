#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <glib.h>

#include <cstdlib>
#include <iostream>
#include <stdexcept>

#include "../linux/src/x11_hotkey.hpp"

extern "C" Bool XTestFakeKeyEvent(Display*, unsigned int, Bool, unsigned long);

void check(bool condition, char const* message) {
  if (!condition) throw std::runtime_error(message);
}

void pump() {
  auto until = g_get_monotonic_time() + 50000;
  while (g_get_monotonic_time() < until) {
    g_main_context_iteration(nullptr, FALSE);
    g_usleep(1000);
  }
}

void key(Display* display, KeySym sym, bool down) {
  XTestFakeKeyEvent(display, XKeysymToKeycode(display, sym), down, 0);
  XSync(display, False);
  pump();
}

void chord(Display* display, KeySym sym, bool caps = false, bool num = false) {
  if (caps) { key(display, XK_Caps_Lock, true); key(display, XK_Caps_Lock, false); }
  if (num) { key(display, XK_Num_Lock, true); key(display, XK_Num_Lock, false); }
  key(display, XK_Alt_L, true);
  key(display, sym, true);
  key(display, sym, false);
  key(display, XK_Alt_L, false);
  if (caps) { key(display, XK_Caps_Lock, true); key(display, XK_Caps_Lock, false); }
  if (num) { key(display, XK_Num_Lock, true); key(display, XK_Num_Lock, false); }
}

int main() {
  try {
    Display* ui = XOpenDisplay(nullptr);
    check(ui != nullptr, "private X server unavailable");
    Window window = XCreateSimpleWindow(ui, DefaultRootWindow(ui),
                                       0, 0, 100, 100, 0, 0, 0);
    XSelectInput(ui, window, StructureNotifyMask | PropertyChangeMask);
    XMapWindow(ui, window);
    XSetInputFocus(ui, window, RevertToParent, CurrentTime);
    XSync(ui, False);
    while (XPending(ui)) { XEvent event; XNextEvent(ui, &event); }

    Display* input = XOpenDisplay(nullptr);
    check(input != nullptr, "input connection unavailable");
    int toggles = 0;
    Time last_timestamp = CurrentTime;
    bool visible = true;
    fulcrum::X11Hotkey hotkey;
    auto toggle = [&](Time timestamp) {
      ++toggles;
      last_timestamp = timestamp;
      visible = !visible;
      if (visible) {
        XMapWindow(ui, window);
        XSetInputFocus(ui, window, RevertToParent, CurrentTime);
      } else {
        XUnmapWindow(ui, window);
      }
      XFlush(ui);
    };
    check(hotkey.start(DisplayString(ui), toggle).empty(),
          "hotkey connection failed");
    // Model GNOME owning Alt+Space: a failed initial grab must be reported,
    // and releasing the desktop binding must permit a successful retry.
    XGrabKey(input, XKeysymToKeycode(input, XK_space), Mod1Mask,
             DefaultRootWindow(input), False, GrabModeAsync, GrabModeAsync);
    XSync(input, False);
    check(!hotkey.bind(XK_space, Mod1Mask).empty(),
          "desktop-owned Alt+Space was not reported as a conflict");
    XUngrabKey(input, XKeysymToKeycode(input, XK_space), Mod1Mask,
               DefaultRootWindow(input));
    XSync(input, False);
    check(hotkey.bind(XK_space, Mod1Mask).empty(),
          "Alt+Space failed after releasing desktop's grab");

    // A normal UI event must neither trigger a hotkey nor leave GDK's queue.
    Atom property = XInternAtom(input, "FULCRUM_REGRESSION", False);
    unsigned char value = 1;
    XChangeProperty(input, window, property, XA_INTEGER, 8, PropModeReplace,
                    &value, 1);
    XSync(input, False);
    pump();
    check(toggles == 0, "ordinary UI event triggered a hotkey");
    XEvent event;
    check(XCheckTypedWindowEvent(ui, window, PropertyNotify, &event),
          "hotkey listener stole a UI event");
    for (int i = 0; i < 1000; ++i) {
      XChangeProperty(input, window, property, XA_INTEGER, 8, PropModeReplace,
                      &value, 1);
    }
    XSync(input, False);
    pump();
    check(toggles == 0, "UI event burst triggered a feedback loop");
    XSync(ui, False);
    int properties = 0;
    while (XCheckTypedWindowEvent(ui, window, PropertyNotify, &event)) ++properties;
    std::cout << "UI property events retained: " << properties << "/1000\n";
    check(properties == 1000, "UI events were consumed by the hotkey listener");

    key(input, XK_space, true); key(input, XK_space, false);
    chord(input, XK_a);
    check(toggles == 0, "wrong key or modifiers triggered a hotkey");
    chord(input, XK_space);
    check(toggles == 1, "one chord must trigger exactly once");
    check(last_timestamp != CurrentTime,
          "hotkey callback receives the grabbed user-event timestamp");
    chord(input, XK_space, true);
    chord(input, XK_space, false, true);
    chord(input, XK_space, true, true);
    check(toggles == 4, "CapsLock/NumLock changed hotkey matching");

    key(input, XK_Alt_L, true);
    key(input, XK_space, true);
    pump();
    int held_count = toggles;
    g_usleep(800000);
    pump();
    check(toggles == held_count, "held key autorepeat retriggered hotkey");
    key(input, XK_space, false); key(input, XK_Alt_L, false);

    // Another client owns the replacement shortcut; retain the old binding.
    XGrabKey(input, XKeysymToKeycode(input, XK_b), Mod1Mask,
             DefaultRootWindow(input), False, GrabModeAsync, GrabModeAsync);
    XSync(input, False);
    check(!hotkey.bind(XK_b, Mod1Mask).empty(), "conflict was not reported");
    int before = toggles;
    chord(input, XK_space);
    check(toggles == before + 1, "failed rebind lost the previous shortcut");
    XUngrabKey(input, XKeysymToKeycode(input, XK_b), Mod1Mask,
               DefaultRootWindow(input));
    XSync(input, False);
    fulcrum::X11Hotkey competitor;
    check(competitor.start(DisplayString(ui), [](Time) {}).empty(),
          "competitor connection failed");
    check(competitor.bind(XK_b, Mod1Mask).empty(),
          "failed rebind leaked partial grabs");
    competitor.stop();
    check(hotkey.bind(XK_b, Mod1Mask).empty(), "replacement bind failed");
    before = toggles;
    chord(input, XK_space);
    check(toggles == before, "old shortcut remained grabbed");
    chord(input, XK_b);
    check(toggles == before + 1, "replacement shortcut did not trigger");

    hotkey.stop();
    hotkey.stop();
    before = toggles;
    chord(input, XK_b);
    check(toggles == before, "stopped listener still dispatched");
    fulcrum::X11Hotkey next;
    check(next.start(DisplayString(ui), toggle).empty(),
          "restart connection failed");
    check(next.bind(XK_b, Mod1Mask).empty(), "stop did not release grabs");
    chord(input, XK_b);
    check(toggles == before + 1, "restarted listener did not trigger");
    next.stop();
    check(!next.start("invalid-display", [](Time) {}).empty(),
          "invalid display failure was not reported");
    XCloseDisplay(input);
    XDestroyWindow(ui, window);
    XCloseDisplay(ui);
    std::cout << "PASS: isolated events, matching, locks, autorepeat, conflict, "
                 "rebind, cleanup, and connection failure\n";
    return EXIT_SUCCESS;
  } catch (std::exception const& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return EXIT_FAILURE;
  }
}
