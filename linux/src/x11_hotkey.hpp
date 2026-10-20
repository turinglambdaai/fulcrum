#pragma once

#include <X11/XKBlib.h>
#include <X11/Xlib.h>
#include <glib.h>

#include <functional>
#include <string>
#include <utility>

namespace fulcrum {

// Own the connection and its event queue; never consume GDK's X events.
// All methods and the GLib source run on the GTK main thread.
class X11Hotkey {
 public:
  X11Hotkey() = default;
  X11Hotkey(X11Hotkey const&) = delete;
  X11Hotkey& operator=(X11Hotkey const&) = delete;
  ~X11Hotkey() { stop(); }

  std::string start(char const* display_name,
                    std::function<void(Time)> activate) {
    stop();
    display_ = XOpenDisplay(display_name);
    if (!display_) return "X11 hotkey setup failed: cannot open display.";
    root_ = DefaultRootWindow(display_);
    activate_ = std::move(activate);
    Bool supported = False;
    XkbSetDetectableAutoRepeat(display_, True, &supported);
    detectable_repeat_ = supported;
    auto* channel = g_io_channel_unix_new(ConnectionNumber(display_));
    source_ = g_io_add_watch(channel,
        static_cast<GIOCondition>(G_IO_IN | G_IO_HUP | G_IO_ERR | G_IO_NVAL),
        on_ready, this);
    g_io_channel_unref(channel);
    return "";
  }

  std::string bind(KeySym keysym, unsigned int mods) {
    // Portal sessions do not start this fallback listener.
    if (!display_) return "";
    KeyCode code = XKeysymToKeycode(display_, keysym);
    if (!code) return "X11 hotkey setup failed: cannot resolve keycode.";
    if (code == code_ && mods == mods_) return "";

    // XGrabKey reports conflicts asynchronously. Scope the process-wide
    // handler to this connection and forward errors from other clients.
    XSync(display_, False);
    error_ = 0;
    error_target_ = this;
    previous_handler_ = XSetErrorHandler(on_error);
    for (unsigned int lock : locks_) {
      XGrabKey(display_, code, mods | lock, root_, False,
               GrabModeAsync, GrabModeAsync);
    }
    XSync(display_, False);
    if (error_) {
      ungrab(code, mods);
      XSync(display_, False);
    }
    XSetErrorHandler(previous_handler_);
    error_target_ = nullptr;
    if (error_) {
      return "X11 hotkey setup failed: shortcut unavailable or already in use.";
    }

    // Keep the previous shortcut if any part of the new grab failed.
    ungrab(code_, mods_);
    code_ = code;
    mods_ = mods;
    pressed_ = false;
    XFlush(display_);
    return "";
  }

  void stop() {
    if (source_) {
      g_source_remove(source_);
      source_ = 0;
    }
    if (display_) {
      ungrab(code_, mods_);
      XCloseDisplay(display_);
      display_ = nullptr;
    }
    code_ = 0;
    pressed_ = false;
    activate_ = {};
  }

 private:
  inline static constexpr unsigned int locks_[] = {
      0, LockMask, Mod2Mask, LockMask | Mod2Mask};
  inline static X11Hotkey* error_target_{nullptr};
  inline static XErrorHandler previous_handler_{nullptr};
  Display* display_{nullptr};
  Window root_{None};
  guint source_{0};
  KeyCode code_{0};
  unsigned int mods_{0};
  int error_{0};
  bool pressed_{false};
  bool detectable_repeat_{false};
  std::function<void(Time)> activate_;

  static int on_error(Display* display, XErrorEvent* event) {
    if (error_target_ && error_target_->display_ == display) {
      error_target_->error_ = event->error_code;
      return 0;
    }
    return previous_handler_ ? previous_handler_(display, event) : 0;
  }

  void ungrab(KeyCode code, unsigned int mods) {
    if (!code) return;
    for (unsigned int lock : locks_) {
      XUngrabKey(display_, code, mods | lock, root_);
    }
  }

  static gboolean on_ready(GIOChannel*, GIOCondition condition, gpointer data) {
    auto& self = *static_cast<X11Hotkey*>(data);
    if (condition & (G_IO_HUP | G_IO_ERR | G_IO_NVAL)) {
      self.source_ = 0;
      return G_SOURCE_REMOVE;
    }
    while (self.display_ && XPending(self.display_) > 0) {
      XEvent event;
      XNextEvent(self.display_, &event);
      if (event.xany.send_event) continue;
      if (event.type == KeyRelease && event.xkey.keycode == self.code_) {
        // Legacy servers emulate repeats with adjacent release/press pairs.
        if (!self.detectable_repeat_ && XPending(self.display_) > 0) {
          XEvent next;
          XPeekEvent(self.display_, &next);
          if (next.type == KeyPress && next.xkey.keycode == event.xkey.keycode &&
              next.xkey.time == event.xkey.time) continue;
        }
        self.pressed_ = false;
      } else if (event.type == KeyPress && event.xkey.keycode == self.code_ &&
                 (event.xkey.state & (ShiftMask | ControlMask | Mod1Mask |
                                      Mod3Mask | Mod4Mask | Mod5Mask)) == self.mods_) {
        if (!self.pressed_) {
          self.pressed_ = true;
          // The timestamp belongs to the actual grabbed user event. Passing
          // it across the private connection lets GTK present with credible
          // user interaction time instead of a stale time from GDK's queue.
          self.activate_(event.xkey.time);
        }
      }
    }
    return self.source_ ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
  }
};

}  // namespace fulcrum
