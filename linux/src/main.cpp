// Fulcrum Linux host — GTK4 floating launcher over one embedded Racket CS
// backend, speaking RVT1 through Rivet's platform/linux runtime.
//
// Mirrors the official Linux scaffold's threading model: boot the runtime
// off the main loop behind a mutex-guarded startup handoff, dispatch every
// completion to the main loop before touching widgets, and keep shutdown
// idempotent. Single-instance activation rides Rivet's first-party
// SingleInstanceLease (`fulcrum --toggle` forwards to the primary). The
// launcher-specific parts that have no rivet counterpart stay honest about
// their platform reach: X11 grabs keys and sets EWMH state directly;
// Wayland compositors own those decisions, and the status bar says so.
#include <gdk/x11/gdkx.h>
#include <gtk/gtk.h>

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <tuple>
#include <utility>
#include <vector>

#include "GeneratedBackend.hpp"
#include "system_services.hpp"

namespace {

struct ResultRow {
  std::string id;
  std::string title;
  std::string subtitle;
  std::string kind;
  std::string arg;
  std::string icon;
  std::string hint;
  std::string badge;
};

ResultRow parse_row(std::vector<std::string> const& cells) {
  ResultRow row;
  if (cells.size() >= 8) {
    row.id = cells[0];
    row.title = cells[1];
    row.subtitle = cells[2];
    row.kind = cells[3];
    row.arg = cells[4];
    row.icon = cells[5];
    row.hint = cells[6];
    row.badge = cells[7];
  }
  return row;
}

// Rivet's POSIX shutdown plumbing (defined after Launcher). Installed once
// the embedded runtime has booted — see on_backend_ready for the ordering.
void install_shutdown_hook_once();

// Tray menu composition (defined after Launcher). Called when the backend
// `language` setting lands so the labels follow it without a restart.
void apply_tray_language();

std::filesystem::path executable_path() {
  return std::filesystem::read_symlink("/proc/self/exe");
}

struct HotkeyGrab {
  Display* display{nullptr};
  Window window{None};
};

HotkeyGrab hotkey_grab;

// Portal-side global shortcuts (rivet GlobalShortcuts adapter). Held for
// the process lifetime: the object owns the portal session and its async
// bind must not be destroyed mid-flight.
std::unique_ptr<rivet::system::GlobalShortcuts> g_portal_shortcuts;

// The launcher hotkey as (X11 modifier mask, keysym). The grammar is one
// spec shared with the backend (settings.rkt) and the other hosts:
// modifiers alt/ctrl/shift/cmd/win/super, then space | a-z | 0-9 |
// f1-f12 | comma | period | minus | equal | tab.
struct HotkeySpec {
  unsigned int mods{Mod1Mask};
  KeySym keysym{XK_space};
};

HotkeySpec current_hotkey;
KeyCode current_hotkey_code{0};

bool parse_hotkey(std::string const& spec, HotkeySpec& out) {
  unsigned int mods = 0;
  bool has_key = false;
  std::string key;
  std::string lowered = spec;
  std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                 [](unsigned char c) {
                   return static_cast<char>(std::tolower(c));
                 });
  std::size_t start = 0;
  while (start <= lowered.size()) {
    std::size_t plus = lowered.find('+', start);
    std::string token = lowered.substr(
        start, plus == std::string::npos ? std::string::npos : plus - start);
    if (token.empty()) {
      return false;
    }
    if (token == "alt" || token == "option") {
      mods |= Mod1Mask;
    } else if (token == "ctrl" || token == "control") {
      mods |= ControlMask;
    } else if (token == "shift") {
      mods |= ShiftMask;
    } else if (token == "cmd" || token == "win" || token == "super") {
      mods |= Mod4Mask;
    } else if (!has_key) {
      has_key = true;
      key = token;
    } else {
      return false;
    }
    if (plus == std::string::npos) {
      break;
    }
    start = plus + 1;
  }
  if (!has_key || mods == 0) {
    return false;
  }
  KeySym sym = NoSymbol;
  if (key == "space") {
    sym = XK_space;
  } else if (key == "tab") {
    sym = XK_Tab;
  } else if (key == "comma") {
    sym = XK_comma;
  } else if (key == "period") {
    sym = XK_period;
  } else if (key == "minus") {
    sym = XK_minus;
  } else if (key == "equal") {
    sym = XK_equal;
  } else if (key.size() == 1 && key[0] >= 'a' && key[0] <= 'z') {
    sym = XK_a + static_cast<KeySym>(key[0] - 'a');
  } else if (key.size() == 1 && key[0] >= '0' && key[0] <= '9') {
    sym = XK_0 + static_cast<KeySym>(key[0] - '0');
  } else if (key.size() >= 2 && key[0] == 'f' &&
             key.find_first_not_of("0123456789", 1) == std::string::npos) {
    int n = std::atoi(key.c_str() + 1);
    if (n < 1 || n > 12) {
      return false;
    }
    sym = XK_F1 + static_cast<KeySym>(n - 1);
  } else {
    return false;
  }
  out.mods = mods;
  out.keysym = sym;
  return true;
}

// Rebinds the X11 grab to `spec`. Returns a human-readable note on failure
// ("" on success). A spec that does not parse is ignored quietly: the
// previous binding stays and the hotkey never becomes unreachable.
std::string apply_x11_hotkey(std::string const& spec) {
  Display* dpy = hotkey_grab.display;
  if (dpy == nullptr || hotkey_grab.window == None) {
    return "";
  }
  HotkeySpec parsed;
  if (!parse_hotkey(spec, parsed)) {
    return "";
  }
  if (current_hotkey_code != 0) {
    XUngrabKey(dpy, current_hotkey_code, current_hotkey.mods,
               hotkey_grab.window);
    XUngrabKey(dpy, current_hotkey_code, current_hotkey.mods | Mod2Mask,
               hotkey_grab.window);
    current_hotkey_code = 0;
  }
  KeyCode code = XKeysymToKeycode(dpy, parsed.keysym);
  if (code == 0) {
    return "X11 hotkey setup failed: cannot resolve the key keycode.";
  }
  XGrabKey(dpy, code, parsed.mods, hotkey_grab.window, True, GrabModeAsync,
           GrabModeAsync);
  XGrabKey(dpy, code, parsed.mods | Mod2Mask, hotkey_grab.window, True,
           GrabModeAsync, GrabModeAsync);  // with NumLock
  current_hotkey = parsed;
  current_hotkey_code = code;
  XSelectInput(dpy, hotkey_grab.window, KeyPressMask);
  return "";
}

// ---- native window management (win.* actions) -----------------------------
//
// The backend ranks the rows; the host performs the move, because only a
// client with an X connection can reach other apps' windows. Targets the
// active window, tiles relative to the monitor's _NET_WORKAREA, and asks
// the window manager via _NET_MOVERESIZE_WINDOW (the EWMH-sanctioned
// request that animates and respects constraints). Compile-tested like the
// rest of the Linux host; runtime verification tracks the Linux beta.

namespace wincmd {

struct Geometry {
  int x{0}, y{0}, w{0}, h{0};
};

std::map<unsigned long, Geometry>& saved() {
  static std::map<unsigned long, Geometry> map;
  return map;
}

bool send_moveresize(Display* dpy, Window target, int x, int y, int w, int h) {
  XEvent xev{};
  xev.xclient.type = ClientMessage;
  xev.xclient.window = target;
  xev.xclient.message_type =
      XInternAtom(dpy, "_NET_MOVERESIZE_WINDOW", False);
  xev.xclient.format = 32;
  // Bits 8-10: gravity (0 = use window's), bit 12: source indication
  // (1 = application).
  xev.xclient.data.l[0] = (1 << 12);
  xev.xclient.data.l[1] = x;
  xev.xclient.data.l[2] = y;
  xev.xclient.data.l[3] = w;
  xev.xclient.data.l[4] = h;
  return XSendEvent(dpy, DefaultRootWindow(dpy), False,
                    SubstructureRedirectMask | SubstructureNotifyMask,
                    &xev) != 0;
}

bool run_window_command(std::string const& id) {
  // GTK4 owns the Display; borrow it (nullptr on pure Wayland: the honest
  // failure path).
  GdkDisplay* gdk_display = gdk_display_get_default();
  if (gdk_display == nullptr || !GDK_IS_X11_DISPLAY(gdk_display)) {
    return false;
  }
  Display* dpy = gdk_x11_display_get_xdisplay(GDK_X11_DISPLAY(gdk_display));
  if (dpy == nullptr) {
    return false;
  }
  Window root = DefaultRootWindow(dpy);
  Atom active_atom = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", True);
  if (active_atom == None) {
    return false;
  }
  Atom actual_type = None;
  int actual_format = 0;
  unsigned long nitems = 0, bytes_after = 0;
  unsigned char* data = nullptr;
  if (XGetWindowProperty(dpy, root, active_atom, 0, 1, False, XA_WINDOW,
                         &actual_type, &actual_format, &nitems, &bytes_after,
                         &data) != Success ||
      nitems < 1) {
    return false;
  }
  Window target = reinterpret_cast<unsigned long*>(data)[0];
  XFree(data);
  if (target == None) {
    return false;
  }

  // Work area of the monitor holding the window (root-relative).
  int x{0}, y{0};
  unsigned int w{0}, h{0}, bw{0}, depth{0};
  Window child = None;
  if (!XGetGeometry(dpy, target, &child, &x, &y, &w, &h, &bw, &depth)) {
    return false;
  }
  // Tiling area: the root _NET_WORKAREA (single-head accurate; per-head
  // workareas need XRandR probing, a later refinement).
  Atom workarea_atom = XInternAtom(dpy, "_NET_WORKAREA", True);
  long wx{0}, wy{0}, ww{0}, wh{0};
  if (workarea_atom != None) {
    unsigned char* wa = nullptr;
    if (XGetWindowProperty(dpy, root, workarea_atom, 0, 4, False, XA_CARDINAL,
                           &actual_type, &actual_format, &nitems,
                           &bytes_after, &wa) == Success &&
        nitems >= 4) {
      long* values = reinterpret_cast<long*>(wa);
      wx = values[0]; wy = values[1]; ww = values[2]; wh = values[3];
      XFree(wa);
    }
  }

  bool need_saved = id != "win.restore";
  if (need_saved) {
    saved()[target] = {x, y, static_cast<int>(w), static_cast<int>(h)};
  }

  if (id == "win.left") {
    return send_moveresize(dpy, target, static_cast<int>(wx), static_cast<int>(wy),
                           static_cast<int>(ww) / 2, static_cast<int>(wh));
  }
  if (id == "win.right") {
    return send_moveresize(dpy, target, static_cast<int>(wx) + static_cast<int>(ww) / 2,
                           static_cast<int>(wy), static_cast<int>(ww) / 2,
                           static_cast<int>(wh));
  }
  if (id == "win.maximize") {
    return send_moveresize(dpy, target, static_cast<int>(wx), static_cast<int>(wy),
                           static_cast<int>(ww), static_cast<int>(wh));
  }
  if (id == "win.almost-max") {
    int const mw = static_cast<int>(ww) * 9 / 10;
    int const mh = static_cast<int>(wh) * 88 / 100;
    return send_moveresize(dpy, target, static_cast<int>(wx) + (static_cast<int>(ww) - mw) / 2,
                           static_cast<int>(wy) + (static_cast<int>(wh) - mh) / 2, mw, mh);
  }
  if (id == "win.center") {
    return send_moveresize(dpy, target,
                           static_cast<int>(wx) + (static_cast<int>(ww) - static_cast<int>(w)) / 2,
                           static_cast<int>(wy) + (static_cast<int>(wh) - static_cast<int>(h)) / 2,
                           static_cast<int>(w), static_cast<int>(h));
  }
  if (id == "win.restore") {
    auto it = saved().find(target);
    if (it == saved().end()) {
      return false;
    }
    Geometry g = it->second;
    saved().erase(it);
    return send_moveresize(dpy, target, g.x, g.y, g.w, g.h);
  }
  return false;
}

}  // namespace wincmd

// ---- i18n (about + update surface) ------------------------------------------
//
// Strings are keyed exactly like shared/i18n/*.json — the single source of
// truth shared with the macOS host (I18nService) and the Windows host. The
// files are flat one-key-per-line JSON objects, so a line-based parser is
// enough. rivet.rktd declares shared/i18n under `resources`, so builds stage
// the files beside the host; the embedded fallback table below keeps the
// same keys for runs where nothing is staged. Lookup: active language → the
// other language → the key itself. The active language follows the backend's
// `language` setting, read once in pull_host_settings — a change applies on
// the next launch, matching this host's one-shot settings pull.
using I18nTable = std::map<std::string, std::string>;

struct I18nEntry {
  char const* key;
  char const* zh;
  char const* en;
};

// Only the keys this host renders. The staged JSON (or the mac host's copy
// of the same table) carries the rest of the about/update surface.
I18nEntry const kI18nFallback[] = {
    {"updateAvailableStatus", "发现新版本：Fulcrum v{0} — 输入 “update” 下载",
     "Update available: Fulcrum v{0} — type \"update\" to download"},
    {"updateDownloadedStatusLinux",
     "更新已下载 — 输入 “update” 打开文件夹，解压 tar.gz 完成升级",
     "Update downloaded — type \"update\" to open the folder, then extract "
     "the tar.gz to upgrade"},
    {"updateDownloadFailed", "更新下载失败：{0}",
     "Update download failed: {0}"},
    {"updateUnknownError", "未知错误", "unknown error"},
    {"updateDownloadPercent", "正在下载更新… {0}%",
     "Downloading update… {0}%"},
    {"aboutContent",
     "一键即达 — 应用、剪贴板、片段、窗口管理与 BYOK AI，尽在一个面板",
     "One keystroke, everything within reach — apps, clipboard, snippets, "
     "window management and BYOK AI in one panel"},
    {"aboutLicense", "以 Business Source License 1.1 授权发布",
     "Released under the Business Source License 1.1"},
    {"aboutWebsite", "访问官网", "Website"},
    {"aboutReportIssue", "问题反馈", "Report an Issue"},
    {"trayOpen", "打开 Fulcrum", "Open Fulcrum"},
    {"trayQuit", "退出 Fulcrum", "Quit Fulcrum"},
    {"trayFixHotkey", "修复 Alt+Space 冲突", "Fix Alt+Space conflict"},
    {"hotkeyShadowed",
     "唤出热键 {0} 被 GNOME 的窗口菜单占用 — 托盘菜单中的「修复 Alt+Space」可解除",
     "Summon hotkey {0} is shadowed by GNOME's window menu — \"Fix "
     "Alt+Space\" in the tray menu frees it"},
    {"hotkeyFreed",
     "已解除 Alt+Space 占用（GNOME 窗口菜单绑定已清空），现在试试热键",
     "Alt+Space freed — GNOME's window-menu binding cleared; try the "
     "hotkey now"},
};

I18nTable g_i18n[2];                // 0 = zh, 1 = en
std::atomic<int> g_i18n_active{1};  // "en" until pull_host_settings reports

// Index of the closing quote for the JSON string starting at `start`
// (which points at '"'), honoring backslash escapes.
std::size_t i18n_string_end(std::string const& line, std::size_t start) {
  for (std::size_t i = start + 1; i < line.size(); ++i) {
    if (line[i] == '\\') {
      ++i;
      continue;
    }
    if (line[i] == '"') {
      return i;
    }
  }
  return std::string::npos;
}

void i18n_append_utf8(std::string& out, unsigned int code) {
  if (code < 0x80) {
    out.push_back(static_cast<char>(code));
  } else if (code < 0x800) {
    out.push_back(static_cast<char>(0xC0 | (code >> 6)));
    out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
  } else if (code < 0x10000) {
    out.push_back(static_cast<char>(0xE0 | (code >> 12)));
    out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
  } else {
    out.push_back(static_cast<char>(0xF0 | (code >> 18)));
    out.push_back(static_cast<char>(0x80 | ((code >> 12) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
  }
}

std::string i18n_unescape(std::string const& raw) {
  std::string out;
  out.reserve(raw.size());
  for (std::size_t i = 0; i < raw.size(); ++i) {
    if (raw[i] != '\\') {
      out.push_back(raw[i]);
      continue;
    }
    if (++i >= raw.size()) {
      break;
    }
    switch (raw[i]) {
      case '"': out.push_back('"'); break;
      case '\\': out.push_back('\\'); break;
      case '/': out.push_back('/'); break;
      case 'n': out.push_back('\n'); break;
      case 't': out.push_back('\t'); break;
      case 'r': out.push_back('\r'); break;
      case 'b': out.push_back('\b'); break;
      case 'f': out.push_back('\f'); break;
      case 'u': {
        auto const hex4 = [&](std::size_t at, unsigned int& code) -> bool {
          if (at + 4 > raw.size()) return false;
          code = 0;
          for (std::size_t d = 0; d < 4; ++d) {
            char const h = raw[at + d];
            code <<= 4;
            if (h >= '0' && h <= '9') code += static_cast<unsigned int>(h - '0');
            else if (h >= 'a' && h <= 'f') code += static_cast<unsigned int>(h - 'a') + 10;
            else if (h >= 'A' && h <= 'F') code += static_cast<unsigned int>(h - 'A') + 10;
            else return false;
          }
          return true;
        };
        unsigned int code = 0;
        if (!hex4(i + 1, code)) {
          i = raw.size();
          break;
        }
        i += 4;
        if (code >= 0xD800 && code <= 0xDBFF && i + 6 < raw.size() &&
            raw[i + 1] == '\\' && raw[i + 2] == 'u') {
          unsigned int low = 0;
          if (hex4(i + 3, low) && low >= 0xDC00 && low <= 0xDFFF) {
            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
            i += 6;
          }
        }
        i18n_append_utf8(out, code);
        break;
      }
      default:
        out.push_back(raw[i]);
        break;
    }
  }
  return out;
}

// Tolerant loader for the flat "key": "value" table. Returns true when at
// least one entry was read; a malformed line is skipped, never fatal.
bool load_i18n_file(char const* path, int lang) {
  std::ifstream file(path, std::ios::binary);
  if (!file) {
    return false;
  }
  std::string bytes((std::istreambuf_iterator<char>(file)),
                    std::istreambuf_iterator<char>());
  if (bytes.size() >= 3 && bytes[0] == '\xEF' && bytes[1] == '\xBB' &&
      bytes[2] == '\xBF') {
    bytes.erase(0, 3);  // tolerate a BOM; the generator does not emit one
  }
  if (bytes.empty()) {
    return false;
  }
  auto& table = g_i18n[lang];
  bool loaded_any = false;
  std::size_t begin = 0;
  while (begin < bytes.size()) {
    auto end = bytes.find('\n', begin);
    if (end == std::string::npos) {
      end = bytes.size();
    }
    std::string line = bytes.substr(begin, end - begin);
    begin = end + 1;
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }

    auto const key_start = line.find('"');
    if (key_start == std::string::npos) {
      continue;
    }
    auto const key_end = i18n_string_end(line, key_start);
    if (key_end == std::string::npos) {
      continue;
    }
    auto const colon = line.find(':', key_end);
    if (colon == std::string::npos) {
      continue;
    }
    auto const value_start = line.find('"', colon + 1);
    if (value_start == std::string::npos) {
      continue;
    }
    auto const value_end = i18n_string_end(line, value_start);
    if (value_end == std::string::npos) {
      continue;
    }
    table[line.substr(key_start + 1, key_end - key_start - 1)] =
        i18n_unescape(line.substr(value_start + 1,
                                  value_end - value_start - 1));
    loaded_any = true;
  }
  return loaded_any;
}

void load_i18n(std::filesystem::path const& exe_dir) {
  char const* names[] = {"zh.json", "en.json"};
  for (int lang = 0; lang < 2; ++lang) {
    auto& table = g_i18n[lang];
    table.clear();
    for (auto const& entry : kI18nFallback) {
      table.emplace(entry.key, lang == 0 ? entry.zh : entry.en);
    }
    // Staged product resources: rivet.rktd declares shared/i18n under
    // `resources`, so packages carry it at <dir>/app/shared/i18n; the dev
    // tree wins for `raco rivet dev` runs where nothing is packaged yet
    // (.rivet/stage holds the host binary one level below the repo root).
    std::filesystem::path const candidates[] = {
        exe_dir / "app" / "shared" / "i18n",
        exe_dir / ".." / "shared" / "i18n",  // dev tree
    };
    for (auto const& dir : candidates) {
      auto const path = dir / names[lang];
      std::error_code ec;
      if (!std::filesystem::exists(path, ec)) {
        continue;
      }
      if (load_i18n_file(path.c_str(), lang)) {
        break;
      }
    }
  }
}

void set_i18n_language(std::string const& lang) {
  g_i18n_active = (lang == "en") ? 1 : 0;
}

std::string tr(char const* key) {
  int const active = g_i18n_active.load(std::memory_order_relaxed);
  for (int attempt = 0; attempt < 2; ++attempt) {
    auto const& table = g_i18n[(active + attempt) % 2];
    auto const it = table.find(key);
    if (it != table.end()) {
      return it->second;
    }
  }
  return key;
}

// Positional formatting: first argument replaces {0}, and so on.
std::string tr_format(char const* key, std::vector<std::string> const& args) {
  std::string out = tr(key);
  for (std::size_t i = 0; i < args.size(); ++i) {
    std::string const token = "{" + std::to_string(i) + "}";
    auto const pos = out.find(token);
    if (pos != std::string::npos) {
      out.replace(pos, token.size(), args[i]);
    }
  }
  return out;
}

// ---- about ----------------------------------------------------------------

// The launcher row `about.open` (the backend ranks it, the host renders
// it): a native GTK about dialog — version, tagline, feedback pointer,
// license, website.
void show_about_dialog(GtkWindow* parent) {
  auto* dialog = gtk_about_dialog_new();
  gtk_about_dialog_set_program_name(GTK_ABOUT_DIALOG(dialog), "Fulcrum");
  gtk_about_dialog_set_version(GTK_ABOUT_DIALOG(dialog), rivet_app::kVersion);
  std::string const comments =
      tr("aboutContent") + "\n" + tr("aboutReportIssue") +
      ": github.com/turinglambdaai/fulcrum/issues";
  gtk_about_dialog_set_comments(GTK_ABOUT_DIALOG(dialog), comments.c_str());
  std::string const license = tr("aboutLicense");
  gtk_about_dialog_set_license(GTK_ABOUT_DIALOG(dialog), license.c_str());
  gtk_about_dialog_set_website(GTK_ABOUT_DIALOG(dialog),
                               "https://fulcrum.jrtx.site");
  std::string const website_label = tr("aboutWebsite");
  gtk_about_dialog_set_website_label(GTK_ABOUT_DIALOG(dialog),
                                     website_label.c_str());
  gtk_window_set_transient_for(GTK_WINDOW(dialog), parent);
  gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
  gtk_window_present(GTK_WINDOW(dialog));
}

// ---- application state ---------------------------------------------------

struct Launcher {
  GtkWindow* window{nullptr};
  GtkSearchEntry* search{nullptr};
  GtkListBox* results{nullptr};
  GtkLabel* status{nullptr};
  // Live AI answer panel (hidden until the backend pushes ai-stream).
  GtkWidget* ai_panel{nullptr};
  GtkLabel* ai_phase{nullptr};
  GtkLabel* ai_text{nullptr};
  // FPP2 plugin detail panel (hidden until a detail row runs).
  GtkWidget* detail_panel{nullptr};
  GtkLabel* detail_text{nullptr};
  GtkLabel* detail_meta{nullptr};

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::unique_ptr<rivet_app::API> api;
  // Tray presence: the visible way back once the panel hides (close
  // button, Esc, focus loss). StatusNotifierItem where a watcher runs —
  // GNOME's AppIndicator extension, KDE, wlroots trays; sessions without
  // one keep the portal hotkey and `fulcrum --toggle` as summon paths.
  std::unique_ptr<rivet::system::TrayIcon> tray;
  std::string tray_menu_lang{"en"};
  // GNOME's stock activate-window-menu binding owns Alt+Space: the tray
  // grows a one-click fix while the conflict stands.
  bool hotkey_shadowed{false};
  GtkApplication* app{nullptr};
  std::vector<ResultRow> rows;
  guint search_source{0};
  // Matches the macOS/Windows hosts: only the newest query may paint, so a
  // slow completion can never overwrite a newer result set.
  std::atomic<int> search_generation{0};
  // Re-entry guard for the download-progress poller (updater 0.2).
  std::atomic<bool> update_polling{false};
  // Clipboard-history capture: the GTK host has no change notification, so
  // a 1s poll (same cadence as the macOS pasteboard timer) diffs the
  // clipboard text and records new values backend-side.
  std::string last_clipboard_text;

  // Official scaffold startup handoff: the boot thread publishes either a
  // started backend or an error; the main loop adopts it exactly once.
  std::mutex startup_mutex;
  std::thread startup_thread;
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  std::string startup_error;
  std::atomic<bool> shutting_down{false};
  // Teardown is reachable from three threads — the GTK main loop
  // (GApplication shutdown, tray quit) and the shutdown-hook watcher
  // (SIGTERM/SIGINT) — so the stop itself is serialized, and the backend
  // stop runs once.
  std::mutex stop_mutex;
  bool backend_stopped_{false};
  // Ctrl+K mode: `rows` currently holds secondary actions and
  // search_rows remembers the live result list.
  bool actions_mode{false};
  std::vector<ResultRow> search_rows;

  static Launcher& instance() {
    static Launcher launcher;
    return launcher;
  }

  void set_status(std::string const& message) {
    gtk_label_set_text(status, message.c_str());
  }

  // Marshal a status string from any worker thread onto the main loop.
  static void post_status(std::string message) {
    g_idle_add([](gpointer user_data) -> int {
      std::unique_ptr<std::string> text(static_cast<std::string*>(user_data));
      Launcher::instance().set_status(*text);
      return G_SOURCE_REMOVE;
    }, new std::string(std::move(message)));
  }

  // ---- backend-rendered settings -------------------------------------------

  // The theme setting is backend-owned; GTK can only ask for the dark
  // variant explicitly — light/system fall back to the user's GTK theme.
  static void apply_theme(std::string const& theme) {
    GtkSettings* settings = gtk_settings_get_default();
    if (settings == nullptr) {
      return;
    }
    g_object_set(settings, "gtk-application-prefer-dark-theme",
                 theme == "dark" ? TRUE : FALSE, nullptr);
  }

  void apply_ai_stream(rivet_app::AiStream const& stream) {
    if (stream.phase == "idle") {
      dismiss_ai_panel();
      return;
    }
    gtk_widget_set_visible(ai_panel, TRUE);
    gtk_label_set_text(ai_text, stream.text.c_str());
    if (stream.phase == "running") {
      gtk_label_set_text(ai_phase, "AI is answering…");
    } else if (stream.phase == "error") {
      gtk_label_set_text(ai_phase, "AI request failed");
    } else {
      gtk_label_set_text(ai_phase, "AI answer");
    }
  }

  void dismiss_ai_panel() { gtk_widget_set_visible(ai_panel, FALSE); }

  void apply_plugin_detail(rivet_app::DetailView const& view) {
    gtk_widget_set_visible(detail_panel, TRUE);
    gtk_label_set_text(detail_text, view.text.c_str());
    std::string meta;
    for (auto const& pair : view.metadata) {
      if (pair.size() >= 2) {
        if (!meta.empty()) meta += "\n";
        meta += pair[0] + "  ·  " + pair[1];
      }
    }
    gtk_label_set_text(detail_meta, meta.c_str());
  }

  void dismiss_detail_panel() {
    gtk_widget_set_visible(detail_panel, FALSE);
  }

  // The backend bumped search-revision (FPP2 daemon push): refresh the
  // rows for whatever query is on screen, debounced through the same
  // 120 ms path as typing.
  void refresh_for_revision() {
    if (search_source != 0) {
      g_source_remove(search_source);
    }
    search_source =
        g_timeout_add(250, [](gpointer) -> int {
          Launcher& l = Launcher::instance();
          l.search_source = 0;
          l.run_search(gtk_editable_get_text(GTK_EDITABLE(l.search)));
          return G_SOURCE_REMOVE;
        }, nullptr);
  }

  // One-time read of the backend-owned settings the host renders (hotkey,
  // theme) plus the `language` key that steers the i18n table. The backend
  // pushes hotkey/theme changes afterwards via the reserved $state events;
  // this seeds the initial values.
  void pull_host_settings() {
    if (api == nullptr) {
      return;
    }
    auto* api_raw = api.get();
    std::thread([api_raw]() mutable {
      std::string hotkey;
      std::string theme;
      std::string language;
      try {
        hotkey = api_raw->get_hotkey().get();
      } catch (...) {
      }
      try {
        theme = api_raw->get_theme().get();
      } catch (...) {
      }
      try {
        // Row shape per the backend settings-list contract: [key, value, …].
        for (auto const& row : api_raw->settings_list().get()) {
          if (row.size() >= 2 && row[0] == "language") {
            language = row[1];
          }
        }
      } catch (...) {
      }
      g_idle_add([](gpointer user_data) -> int {
        std::unique_ptr<std::tuple<std::string, std::string, std::string>>
            values(static_cast<std::tuple<std::string, std::string,
                                          std::string>*>(user_data));
        auto const& [hotkey, theme, language] = *values;
        Launcher& launcher = Launcher::instance();
        set_i18n_language(language);
        apply_tray_language();
        if (!hotkey.empty()) {
          std::string note = apply_x11_hotkey(hotkey);
          if (!note.empty()) {
            launcher.set_status(note);
          }
        }
        if (!theme.empty()) {
          apply_theme(theme);
        }
        return G_SOURCE_REMOVE;
      }, new std::tuple<std::string, std::string, std::string>(
             std::move(hotkey), std::move(theme), std::move(language)));
    }).detach();
  }

  // ---- clipboard history capture --------------------------------------------

  static void on_clipboard_read(GObject* source, GAsyncResult* result,
                                gpointer) {
    Launcher& launcher = Launcher::instance();
    gchar* text =
        gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), result, nullptr);
    if (text == nullptr) {
      return;
    }
    if (text != launcher.last_clipboard_text) {
      launcher.last_clipboard_text = text;
      std::string payload = text;
      std::thread([payload]() mutable {
        Launcher& launcher = Launcher::instance();
        if (launcher.shutting_down.load(std::memory_order_acquire)) {
          return;
        }
        auto* api_raw = launcher.api.get();
        if (api_raw == nullptr) {
          return;
        }
        try {
          api_raw->clipboard_record(payload);
        } catch (...) {
          // Persistence must never take the launcher down.
        }
      }).detach();
    }
    g_free(text);
  }

  static gboolean poll_clipboard(gpointer) {
    Launcher& launcher = Launcher::instance();
    if (launcher.api == nullptr ||
        launcher.shutting_down.load(std::memory_order_acquire)) {
      return G_SOURCE_CONTINUE;
    }
    GdkClipboard* clipboard =
        gtk_widget_get_clipboard(GTK_WIDGET(launcher.window));
    gdk_clipboard_read_text_async(clipboard, nullptr, on_clipboard_read,
                                  nullptr);
    return G_SOURCE_CONTINUE;
  }

  // Updater 0.2 (in-app install stays macOS-only on this line): the 4-hour
  // throttle and manifest verification are backend-owned, so the silent
  // launch check is one cheap RPC the backend may decline ("throttled").
  // Failures are silent by design — a resident launcher must never nag.
  void start_silent_update_check() {
    if (api == nullptr) {
      return;
    }
    auto* api_raw = api.get();
    std::thread([api_raw]() mutable {
      try {
        auto const check = api_raw->update_check(false).get();
        if (check.status != "available") {
          return;
        }
        post_status(tr_format("updateAvailableStatus",
                              {check.available_version.value_or("?")}));
      } catch (...) {
        // silent: network down, feed unreachable — never nag
      }
    }).detach();
  }

  // Mirror the backend's download thread into the status bar; when the
  // artifact is verified the user gets the open-folder / manual-install
  // guidance (the "update" launcher rows drive reveal on this state).
  void start_update_progress_poll() {
    if (api == nullptr || update_polling.exchange(true)) {
      return;
    }
    auto* api_raw = api.get();
    std::thread([api_raw]() mutable {
      while (true) {
        try {
          auto const state = api_raw->update_state().get();
          if (state.phase == "downloaded") {
            post_status(tr("updateDownloadedStatusLinux"));
            break;
          }
          if (state.phase == "error") {
            post_status(tr_format(
                "updateDownloadFailed",
                {state.message.value_or(tr("updateUnknownError"))}));
            break;
          }
          if (state.phase != "downloading") {
            break;
          }
          post_status(tr_format("updateDownloadPercent",
                                {std::to_string(state.percent)}));
        } catch (...) {
          break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1000));
      }
      // Re-entry guard only: clear it from the worker so a later download
      // can poll again.
      Launcher::instance().update_polling.store(false, std::memory_order_release);
    }).detach();
  }

  static std::string event_payload(rivet::Value const& value) {
    // Event values are bare strings per the backend contract: RVT1 event
    // frames arrive as [name, value] and the runtime hands us value.
    if (auto const* text = std::get_if<std::string>(&value.data)) {
      return *text;
    }
    return {};
  }

  // Paste-to-frontmost: the clipboard already carries the text (set on the
  // main thread in handle_event); after the panel hides and focus returns
  // to the previous app, synthesize Ctrl+V — XTEST on X11, `wtype` on
  // Wayland. GDK is main-thread-only, so the X11 check happens on the main
  // thread and this worker touches only Xlib (XInitThreads ran at startup)
  // or spawns a process.
  static void paste_keystroke_async(bool x11_session) {
    std::thread([x11_session]() {
      std::this_thread::sleep_for(std::chrono::milliseconds(180));
      if (x11_session) {
        Display* dpy = XOpenDisplay(nullptr);
        if (dpy != nullptr) {
          KeyCode ctrl = XKeysymToKeycode(dpy, XK_Control_L);
          KeyCode v = XKeysymToKeycode(dpy, XK_v);
          if (ctrl != 0 && v != 0) {
            XTestFakeKeyEvent(dpy, ctrl, True, CurrentTime);
            XTestFakeKeyEvent(dpy, v, True, CurrentTime);
            XTestFakeKeyEvent(dpy, v, False, CurrentTime);
            XTestFakeKeyEvent(dpy, ctrl, False, CurrentTime);
            XFlush(dpy);
          }
          XCloseDisplay(dpy);
          return;
        }
      }
      GError* error = nullptr;
      if (!g_spawn_command_line_async("wtype -M ctrl -P v -p v -m ctrl",
                                      &error)) {
        Launcher::post_status(
            "Paste-to-frontmost on Wayland needs `wtype` (install it), or "
            "run Fulcrum in an X11 session.");
        if (error != nullptr) {
          g_error_free(error);
        }
      }
    }).detach();
  }

  void handle_state_push(rivet::Value const& value) {
    // Reserved "$state" frames carry [state-name, wire-value].
    auto const* fields = std::get_if<rivet::Value::List>(&value.data);
    if (fields == nullptr || fields->size() != 2) {
      return;
    }
    auto const* state_name = std::get_if<std::string>(&(fields->at(0).data));
    if (state_name == nullptr) {
      return;
    }
    if (*state_name == "ai-stream") {
      rivet_app::AiStream stream;
      try {
        stream = rivet_app::detail::decode_AiStream(fields->at(1));
      } catch (...) {
        return;
      }
      g_idle_add([](gpointer user_data) -> int {
        std::unique_ptr<rivet_app::AiStream> stream(
            static_cast<rivet_app::AiStream*>(user_data));
        Launcher::instance().apply_ai_stream(*stream);
        return G_SOURCE_REMOVE;
      }, new rivet_app::AiStream(std::move(stream)));
    } else if (*state_name == "theme") {
      if (auto const* theme = std::get_if<std::string>(&(fields->at(1).data))) {
        std::string value_copy = *theme;
        g_idle_add([](gpointer user_data) -> int {
          std::unique_ptr<std::string> theme(
              static_cast<std::string*>(user_data));
          apply_theme(*theme);
          return G_SOURCE_REMOVE;
        }, new std::string(std::move(value_copy)));
      }
    } else if (*state_name == "search-revision") {
      g_idle_add([](gpointer) -> int {
        Launcher::instance().refresh_for_revision();
        return G_SOURCE_REMOVE;
      }, nullptr);
    } else if (*state_name == "hotkey") {
      if (auto const* spec = std::get_if<std::string>(&(fields->at(1).data))) {
        std::string spec_copy = *spec;
        g_idle_add([](gpointer user_data) -> int {
          std::unique_ptr<std::string> spec(
              static_cast<std::string*>(user_data));
          std::string note = apply_x11_hotkey(*spec);
          if (!note.empty()) {
            Launcher::instance().set_status(note);
          }
          return G_SOURCE_REMOVE;
        }, new std::string(std::move(spec_copy)));
      }
    }
  }

  void handle_event(std::string const& name, std::string const& payload) {
    if (name == "copy-to-clipboard") {
      if (GdkClipboard* clipboard =
              gtk_widget_get_clipboard(GTK_WIDGET(window))) {
        gdk_clipboard_set_text(clipboard, payload.c_str());
      }
      hide();
    } else if (name == "paste-to-frontmost") {
      if (GdkClipboard* clipboard =
              gtk_widget_get_clipboard(GTK_WIDGET(window))) {
        gdk_clipboard_set_text(clipboard, payload.c_str());
      }
      hide();
      bool const x11_session =
          GDK_IS_X11_DISPLAY(gdk_display_get_default());
      paste_keystroke_async(x11_session);
    } else if (name == "ai-finished") {
      // The answer lands on the clipboard, but the panel stays: the user
      // is reading the streamed text right now.
      if (GdkClipboard* clipboard =
              gtk_widget_get_clipboard(GTK_WIDGET(window))) {
        gdk_clipboard_set_text(clipboard, payload.c_str());
      }
      set_status("Answer copied to the clipboard");
    } else if (name == "open-url") {
      gtk_show_uri(GTK_WINDOW(window), payload.c_str(), GDK_CURRENT_TIME);
      hide();
    } else if (name == "update-available") {
      set_status(payload);
    }
  }

  // All request/response traffic runs on short-lived worker threads; the
  // callbacks only marshal (boxed) results back through g_idle_add.

  struct SearchOutcome {
    bool ok{false};
    int generation{0};
    std::vector<ResultRow> rows;
    std::string error;
  };

  void run_search(std::string const& query) {
    if (api == nullptr || shutting_down.load(std::memory_order_acquire)) {
      return;
    }
    auto* api_raw = api.get();
    auto* boxed = new SearchOutcome;
    boxed->generation = search_generation.fetch_add(1) + 1;
    std::thread([api_raw, query, boxed]() mutable {
      try {
        for (auto const& cells : api_raw->search(query).get()) {
          boxed->rows.push_back(parse_row(cells));
        }
        boxed->ok = true;
      } catch (std::exception const& e) {
        boxed->error = e.what();
      }
      g_idle_add([](gpointer user_data) -> int {
        std::unique_ptr<SearchOutcome> job(
            static_cast<SearchOutcome*>(user_data));
        Launcher& launcher = Launcher::instance();
        if (job->generation == launcher.search_generation.load()) {
          launcher.apply_search(std::move(*job));
        }
        return G_SOURCE_REMOVE;
      }, boxed);
    }).detach();
  }

  void apply_search(SearchOutcome result) {
    if (!result.ok) {
      set_status("Search failed: " + result.error);
      return;
    }
    rows = std::move(result.rows);
    refresh_results();
  }

  void refresh_results() {
    // Rebuild the list; simple and correct beats incremental cleverness at
    // this list size (≤ max-results rows).
    for (GtkWidget* child = gtk_widget_get_first_child(GTK_WIDGET(results));
         child != nullptr;) {
      GtkWidget* next = gtk_widget_get_next_sibling(child);
      gtk_list_box_remove(results, child);
      child = next;
    }
    for (auto const& row : rows) {
      auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
      gtk_widget_set_margin_top(box, 6);
      gtk_widget_set_margin_bottom(box, 6);
      gtk_widget_set_margin_start(box, 10);
      gtk_widget_set_margin_end(box, 10);
      auto* title = gtk_label_new(row.title.c_str());
      gtk_label_set_xalign(GTK_LABEL(title), 0.0);
      gtk_label_set_ellipsize(GTK_LABEL(title), PANGO_ELLIPSIZE_END);
      gtk_widget_add_css_class(title, "heading");
      auto* subtitle = gtk_label_new(
          row.subtitle.empty() ? row.kind.c_str() : row.subtitle.c_str());
      gtk_label_set_xalign(GTK_LABEL(subtitle), 0.0);
      gtk_label_set_ellipsize(GTK_LABEL(subtitle), PANGO_ELLIPSIZE_END);
      gtk_widget_add_css_class(subtitle, "caption");
      gtk_widget_add_css_class(subtitle, "dim-label");
      gtk_box_append(GTK_BOX(box), title);
      gtk_box_append(GTK_BOX(box), subtitle);
      gtk_list_box_append(results, box);
    }
    if (!rows.empty()) {
      gtk_list_box_select_row(results,
                              gtk_list_box_get_row_at_index(results, 0));
    }
  }

  struct RunOutcome {
    bool success{false};
    std::string status;
    std::string action_id;
    std::string arg;
  };

  void show_actions_for_selection() {
    if (api == nullptr || rows.empty() || actions_mode) {
      return;
    }
    GtkListBoxRow* selected = gtk_list_box_get_selected_row(results);
    int index = selected != nullptr ? gtk_list_box_row_get_index(selected) : 0;
    if (index < 0 || index >= static_cast<int>(rows.size())) {
      index = 0;
    }
    ResultRow const row = rows[static_cast<std::size_t>(index)];
    search_rows = rows;
    auto* api_raw = api.get();
    std::thread([api_raw, row]() mutable {
      std::vector<ResultRow> actions;
      std::string error;
      try {
        for (auto const& cells : api_raw->row_actions(row.id, row.arg).get()) {
          actions.push_back(parse_row(cells));
        }
      } catch (std::exception const& e) {
        error = e.what();
      }
      g_idle_add([](gpointer user_data) -> int {
        std::unique_ptr<std::vector<ResultRow>> job(
            static_cast<std::vector<ResultRow>*>(user_data));
        Launcher& launcher = Launcher::instance();
        launcher.actions_mode = true;
        launcher.rows = std::move(*job);
        launcher.refresh_results();
        if (launcher.rows.empty()) {
          launcher.set_status("No secondary actions for this result");
        }
        return G_SOURCE_REMOVE;
      }, new std::vector<ResultRow>(std::move(actions)));
      (void)error;
    }).detach();
  }

  void close_actions() {
    actions_mode = false;
    rows = std::move(search_rows);
    search_rows.clear();
    refresh_results();
    gtk_widget_grab_focus(GTK_WIDGET(search));
  }

  void run_selected() {
    if (api == nullptr || rows.empty()) {
      return;
    }
    GtkListBoxRow* selected = gtk_list_box_get_selected_row(results);
    int index = selected != nullptr ? gtk_list_box_row_get_index(selected) : 0;
    if (index < 0 || index >= static_cast<int>(rows.size())) {
      index = 0;
    }
    ResultRow const row = rows[static_cast<std::size_t>(index)];
    set_status("Running…");
    auto* api_raw = api.get();
    std::thread([api_raw, row]() mutable {
      auto* boxed = new RunOutcome;
      boxed->action_id = row.id;
      boxed->arg = row.arg;
      try {
        boxed->status = api_raw->run_action(row.id, row.arg).get();
        boxed->success = boxed->status == "ok" ||
                         boxed->status == "launched" ||
                         boxed->status == "copied" ||
                         boxed->status == "opened" ||
                         boxed->status == "started" ||
                         boxed->status == "detail" ||
                         boxed->status == "stay" ||
                         boxed->status == "downloading" ||
                         boxed->status == "delegated";
      } catch (std::exception const& e) {
        boxed->status = e.what();
      }
      g_idle_add([](gpointer user_data) -> int {
        std::unique_ptr<RunOutcome> job(static_cast<RunOutcome*>(user_data));
        if (job->success) {
          // About rides "delegated": the backend ranks the row, the host
          // renders its native about dialog (main thread: GTK owns the
          // widgets here).
          if (job->action_id == "about.open") {
            show_about_dialog(Launcher::instance().window);
            return G_SOURCE_REMOVE;
          }
          // Window commands ride "delegated": the backend ranks the rows,
          // the host performs the native window move on the frontmost
          // X11 window (main thread: GDK owns the display here).
          if (job->action_id.rfind("win.", 0) == 0) {
            if (!wincmd::run_window_command(job->action_id)) {
              Launcher::instance().set_status(
                  "Window command failed (X11/Wayland window manager refused).");
              return G_SOURCE_REMOVE;
            }
          }
          if (job->status == "started") {
            // AI run: the request continues on a backend thread; the
            // ai-stream State drives the streaming panel.
            Launcher::instance().set_status("AI is answering…");
            return G_SOURCE_REMOVE;
          }
          if (job->status == "stay") {
            // The result is meant to be read (update check, ...): the
            // notify event already wrote the status line (selectable, so
            // errors can be copied); keep the panel open.
            return G_SOURCE_REMOVE;
          }
          if (job->status == "detail") {
            // FPP2 plugin detail: fetch the payload and show it in the
            // panel slot. The RPC runs on a worker thread; the paint
            // marshals back through g_idle_add.
            Launcher::instance().dismiss_detail_panel();
            std::string const row_id = job->action_id;
            auto* api_raw = Launcher::instance().api.get();
            std::thread([api_raw, row_id, arg = job->arg]() mutable {
              try {
                auto view = api_raw->plugin_detail(row_id, arg).get();
                g_idle_add([](gpointer user_data) -> int {
                  std::unique_ptr<rivet_app::DetailView> view(
                      static_cast<rivet_app::DetailView*>(user_data));
                  Launcher::instance().apply_plugin_detail(*view);
                  return G_SOURCE_REMOVE;
                }, new rivet_app::DetailView(std::move(view)));
              } catch (std::exception const& e) {
                Launcher::post_status(std::string("Detail error: ") + e.what());
              }
            }).detach();
            return G_SOURCE_REMOVE;
          }
          if (job->status == "downloading") {
            // The backend download thread owns the transfer; the host
            // mirrors its progress into the status bar.
            Launcher::instance().hide();
            Launcher::instance().start_update_progress_poll();
            return G_SOURCE_REMOVE;
          }
          if (Launcher::instance().actions_mode) {
            // A mutating action (pin, delete, copy) keeps the launcher
            // open, back on the search rows.
            Launcher::instance().close_actions();
          } else {
            Launcher::instance().hide();
          }
        } else {
          Launcher::instance().set_status("Action failed: " + job->status);
        }
        return G_SOURCE_REMOVE;
      }, boxed);
    }).detach();
  }

  void show() {
    actions_mode = false;
    dismiss_ai_panel();
    dismiss_detail_panel();
    gtk_editable_set_text(GTK_EDITABLE(search), "");
    run_search("");
    gtk_widget_set_visible(GTK_WIDGET(window), TRUE);
    gtk_window_present(window);
  }

  void hide() { gtk_widget_set_visible(GTK_WIDGET(window), FALSE); }

  void toggle() {
    if (gtk_widget_get_visible(GTK_WIDGET(window))) {
      hide();
    } else {
      show();
    }
  }

  // ---- backend lifecycle -------------------------------------------------

  void start_backend() {
    // raco rivet build/dev stages runtime/*.boot and res/core.zo beside the
    // executable; that is the only layout the official CLI produces.
    std::filesystem::path const root = executable_path().parent_path();
    std::filesystem::path const petite = root / "runtime" / "petite.boot";
    std::filesystem::path const scheme = root / "runtime" / "scheme.boot";
    std::filesystem::path const racket_boot = root / "runtime" / "racket.boot";
    std::filesystem::path const core = root / "res" / "core.zo";
    if (!std::filesystem::exists(petite) ||
        !std::filesystem::exists(scheme) ||
        !std::filesystem::exists(racket_boot) ||
        !std::filesystem::exists(core)) {
      set_status("Missing Rivet runtime layout (runtime/*.boot, res/core.zo) "
                 "next to the executable. Build with raco rivet build/dev.");
      return;
    }

    rivet::linux_runtime::RacketRuntimeConfig config;
    config.executable_path = executable_path().string();
    config.petite_boot = petite.string();
    config.scheme_boot = scheme.string();
    config.racket_boot = racket_boot.string();
    config.backend_bundle = core.string();
    config.module_name = rivet_app::kModuleName;
    config.entry_symbol = rivet_app::kEntryName;

    startup_thread = std::thread([config = std::move(config)]() mutable {
      auto backend =
          std::make_unique<rivet::linux_runtime::Backend>(std::move(config));
      try {
        backend->start();
        std::lock_guard lock(Launcher::instance().startup_mutex);
        Launcher::instance().startup_backend = std::move(backend);
      } catch (std::exception const& e) {
        std::lock_guard lock(Launcher::instance().startup_mutex);
        Launcher::instance().startup_error = e.what();
      }
      g_idle_add([](gpointer) -> int {
        Launcher::instance().on_backend_ready();
        return G_SOURCE_REMOVE;
      }, nullptr);
    });
  }

  void on_backend_ready() {
    // The embedded Racket runtime installs its own SIGTERM handler while
    // booting and would leave an earlier hook inert — the runtime's
    // handler is the last writer (the same lesson the SyncPilot host
    // logged with a sigaction interposer). Installing here, once the boot
    // thread has finished, on the main loop thread, is the last word:
    // SIGTERM/SIGINT now run the orderly stop and exit instead of being
    // absorbed into a half-dead process. Before this point a signal hits
    // the default disposition and simply kills the process — nothing
    // worth tearing down exists yet.
    install_shutdown_hook_once();

    std::lock_guard stop_lock(stop_mutex);
    if (startup_thread.joinable()) {
      startup_thread.join();
    }

    std::unique_ptr<rivet::linux_runtime::Backend> backend;
    std::string error;
    {
      std::lock_guard lock(startup_mutex);
      backend = std::move(startup_backend);
      error = std::move(startup_error);
    }

    if (shutting_down.load(std::memory_order_acquire)) {
      if (backend != nullptr) {
        backend->stop();
      }
      return;
    }
    if (!error.empty()) {
      set_status("Fulcrum backend failed to start: " + error);
      return;
    }
    if (backend == nullptr) {
      set_status("Fulcrum backend error: startup completed without a backend");
      return;
    }

    backend_ = std::move(backend);
    api = std::make_unique<rivet_app::API>(*backend_);

    backend_->set_event_handler(
        [](std::string const& name, rivet::Value const& value) {
          if (name == "$state") {
            // Reserved state pushes need the raw list payload; decode on
            // the main loop (handle_state_push marshals internally).
            auto* job = new std::pair<std::string, rivet::Value>(
                name, value);
            g_idle_add([](gpointer user_data) -> int {
              std::unique_ptr<std::pair<std::string, rivet::Value>> frame(
                  static_cast<std::pair<std::string, rivet::Value>*>(
                      user_data));
              Launcher::instance().handle_state_push(frame->second);
              return G_SOURCE_REMOVE;
            }, job);
            return;
          }
          auto* job = new std::pair<std::string, std::string>(
              name, event_payload(value));
          g_idle_add([](gpointer user_data) -> int {
            std::unique_ptr<std::pair<std::string, std::string>> payload(
                static_cast<std::pair<std::string, std::string>*>(user_data));
            Launcher::instance().handle_event(payload->first, payload->second);
            return G_SOURCE_REMOVE;
          }, job);
        });

    set_status("Ready — hotkey or `fulcrum --toggle`");
    run_search("");
    start_silent_update_check();
    pull_host_settings();
    g_timeout_add(1000, poll_clipboard, nullptr);
  }

  void stop_backend() {
    std::lock_guard lock(stop_mutex);
    shutting_down.store(true, std::memory_order_release);
    if (startup_thread.joinable()) {
      startup_thread.join();
    }
    if (backend_ != nullptr && !backend_stopped_) {
      backend_stopped_ = true;
      backend_->stop();
    }
  }

 private:
  std::unique_ptr<rivet::linux_runtime::Backend> backend_;
};

// ---- X11 global hotkey ----------------------------------------------------

gboolean on_x11_hotkey(GIOChannel*, GIOCondition, gpointer) {
  Launcher::instance().toggle();
  // Drain pending X events for the connection.
  while (XPending(hotkey_grab.display) > 0) {
    XEvent event;
    XNextEvent(hotkey_grab.display, &event);
  }
  return G_SOURCE_CONTINUE;
}

std::string install_x11_hotkey(GdkDisplay* display, GtkWindow* window) {
  if (GDK_IS_X11_DISPLAY(display) == 0) {
    return "Wayland session: compositors do not allow global key grabs. "
           "Bind `fulcrum --toggle` to a key in your compositor settings.";
  }
  hotkey_grab.display = gdk_x11_display_get_xdisplay(GDK_X11_DISPLAY(display));
  hotkey_grab.window =
      gdk_x11_surface_get_xid(gtk_native_get_surface(GTK_NATIVE(window)));

  // Bootstrap grab so the launcher is reachable before the backend
  // answers; the stored hotkey spec re-binds once the state arrives.
  std::string note = apply_x11_hotkey("alt+space");
  if (!note.empty()) {
    return note;
  }

  int x11_fd = ConnectionNumber(hotkey_grab.display);
  GIOChannel* channel = g_io_channel_unix_new(x11_fd);
  g_io_add_watch(channel, G_IO_IN, on_x11_hotkey, nullptr);
  g_io_channel_unref(channel);
  return "";
}

// ---- single instance via the first-party rivet lease ----------------------
// `fulcrum --toggle` forwards the argument to the running primary, whose
// activation handler presents the panel on the GTK main loop (the handler
// itself runs on the lease's watcher thread).

gboolean activate_on_main(gpointer) {
  // A forwarded --toggle is a real toggle: the compositor keybinding
  // summons a hidden panel and dismisses a visible one.
  Launcher::instance().toggle();
  return G_SOURCE_REMOVE;
}

void on_activation(std::vector<std::string> arguments) {
  (void)arguments;  // fulcrum only ever forwards --toggle
  g_idle_add(activate_on_main, nullptr);
}

// ---- tray ------------------------------------------------------------------
// The visible way back after the panel hides. Without it, a launcher that
// closes to the background has no summon affordance a mouse user can find:
// the portal hotkey needs a consent prompt that is easy to miss, and
// `fulcrum --toggle` is a terminal incantation.

void tray_quit() {
  // A real quit: GApplication's shutdown path stops the backend, and the
  // shutdown hook keeps SIGTERM equivalent.
  g_application_quit(G_APPLICATION(Launcher::instance().app));
}

// GNOME's stock "activate window menu" binding is <Alt>space — the
// compositor consumes the summon key before the portal shortcut ever
// sees it, and the consent UI does not resolve that for the user. When
// the active trigger is Alt+Space and that keybinding still exists, the
// tray grows a one-click fix (clearing the stock binding) instead of
// leaving every GNOME user to debug gsettings on their own.
bool trigger_is_alt_space(std::string const& trigger) {
  std::string lowered = trigger;
  std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                 [](unsigned char c) {
                   return static_cast<char>(std::tolower(c));
                 });
  return lowered.find("alt") != std::string::npos &&
         lowered.find("space") != std::string::npos;
}

std::string gnome_window_menu_binding() {
  std::string out;
  FILE* gsettings = popen(
      "gsettings get org.gnome.desktop.wm.keybindings "
      "activate-window-menu 2>/dev/null",
      "r");
  if (gsettings == nullptr) {
    return out;
  }
  char buf[256];
  while (fgets(buf, sizeof buf, gsettings) != nullptr) {
    out += buf;
  }
  pclose(gsettings);
  return out;
}

void rebuild_tray_menu();

void tray_fix_hotkey() {
  int const rc = std::system(
      "gsettings set org.gnome.desktop.wm.keybindings "
      "activate-window-menu \"[]\"");
  Launcher& launcher = Launcher::instance();
  if (rc == 0) {
    launcher.hotkey_shadowed = false;
    rebuild_tray_menu();
    Launcher::post_status(tr("hotkeyFreed"));
  } else {
    Launcher::post_status(std::string("gsettings failed (rc=") +
                          std::to_string(rc) + ")");
  }
}

std::vector<rivet::system::TrayMenuItem> tray_menu_items() {
  std::vector<rivet::system::TrayMenuItem> items;
  items.push_back(rivet::system::TrayMenuItem(
      tr("trayOpen"), [] { Launcher::instance().show(); }));
  if (Launcher::instance().hotkey_shadowed) {
    items.push_back(rivet::system::TrayMenuItem(
        tr("trayFixHotkey"), [] { tray_fix_hotkey(); }));
  }
  items.push_back(rivet::system::TrayMenuItem(
      rivet::system::TrayMenuItem::Type::separator));
  items.push_back(
      rivet::system::TrayMenuItem(tr("trayQuit"), [] { tray_quit(); }));
  return items;
}

void rebuild_tray_menu() {
  Launcher& launcher = Launcher::instance();
  if (launcher.tray) {
    launcher.tray->set_menu(tray_menu_items());
  }
}

// Runs once the portal bind names the compositor's chosen combo: a
// GNOME session whose window menu still owns Alt+Space keeps the summon
// dead no matter how correct the binding is — say so, and put the fix
// one tray click away.
void check_hotkey_shadowing(std::string const& trigger) {
  if (!trigger_is_alt_space(trigger)) {
    return;
  }
  std::string const binding = gnome_window_menu_binding();
  std::string lowered = binding;
  std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                 [](unsigned char c) {
                   return static_cast<char>(std::tolower(c));
                 });
  if (lowered.find("alt") == std::string::npos ||
      lowered.find("space") == std::string::npos) {
    return;
  }
  Launcher& launcher = Launcher::instance();
  launcher.hotkey_shadowed = true;
  rebuild_tray_menu();
  Launcher::post_status(tr_format("hotkeyShadowed", {trigger}));
}

// The menu is composed at tray construction with the startup language; the
// backend `language` setting lands shortly after boot and re-composes it
// (set_menu replaces the whole menu), so the labels never need a restart.
void apply_tray_language() {
  Launcher& launcher = Launcher::instance();
  std::string const active =
      (g_i18n_active.load(std::memory_order_relaxed) == 0) ? "zh" : "en";
  if (!launcher.tray || active == launcher.tray_menu_lang) {
    return;
  }
  launcher.tray_menu_lang = active;
  rebuild_tray_menu();
}

void build_tray() {
  try {
    if (!rivet::system::TrayIcon::available()) {
      return;
    }
    Launcher& launcher = Launcher::instance();
    launcher.tray = std::make_unique<rivet::system::TrayIcon>(
        rivet_app::kIdentifier, "Fulcrum", "fulcrum");
    launcher.tray->set_tooltip(
        "Fulcrum", tr("aboutContent").c_str());
    launcher.tray->set_menu(tray_menu_items());
    launcher.tray->set_activation_handler(
        [] { Launcher::instance().show(); });
  } catch (std::exception const& error) {
    // A session that cannot host the tray is supported: the portal hotkey
    // and `fulcrum --toggle` stay the summon paths.
    std::cerr << "fulcrum: tray unavailable: " << error.what() << "\n";
  }
}

// ---- shutdown hook ---------------------------------------------------------

void install_shutdown_hook_once() {
  static bool installed = false;
  if (installed) {
    return;
  }
  installed = true;
  try {
    rivet::system::InstallShutdownHook(
        [] { Launcher::instance().stop_backend(); });
  } catch (std::exception const& error) {
    std::cerr << "fulcrum: shutdown hook unavailable: " << error.what()
              << "\n";
  }
}

// ---- GTK wiring -----------------------------------------------------------

// WM close = hide, exactly like the hosts' close buttons. Returning TRUE
// keeps GTK's hide-on-close default out of the picture: its path was
// observed killing the X11 surface behind GDK's back, after which the
// resident launcher could never be presented again.
gboolean on_close_request(GtkWindow*, gpointer) {
  Launcher::instance().hide();
  return TRUE;
}

void on_search_changed(GtkSearchEntry*, gpointer) {
  Launcher& launcher = Launcher::instance();
  if (launcher.search_source != 0) {
    g_source_remove(launcher.search_source);
  }
  // Debounce fast typing.
  launcher.search_source =
      g_timeout_add(120, [](gpointer) -> int {
        Launcher& l = Launcher::instance();
        l.search_source = 0;
        l.run_search(gtk_editable_get_text(GTK_EDITABLE(l.search)));
        return G_SOURCE_REMOVE;
      }, nullptr);
}

void on_row_activated(GtkListBox*, GtkListBoxRow*, gpointer) {
  Launcher::instance().run_selected();
}

gboolean on_key_pressed(GtkEventControllerKey*, guint keyval, guint,
                        GdkModifierType state, gpointer) {
  // Ctrl+K equivalent: the selected row's secondary actions.
  if (keyval == GDK_KEY_k && (state & GDK_CONTROL_MASK) != 0) {
    Launcher::instance().show_actions_for_selection();
    return TRUE;
  }
  switch (keyval) {
    case GDK_KEY_Tab:
    case GDK_KEY_ISO_Left_Tab: {
      // Autocomplete the selected row's title into the query field.
      Launcher& launcher = Launcher::instance();
      if (launcher.actions_mode || launcher.rows.empty()) {
        return TRUE;
      }
      GtkListBoxRow* selected =
          gtk_list_box_get_selected_row(launcher.results);
      int index = selected != nullptr ? gtk_list_box_row_get_index(selected) : 0;
      if (index < 0 || index >= static_cast<int>(launcher.rows.size())) {
        index = 0;
      }
      gtk_editable_set_text(GTK_EDITABLE(launcher.search),
                            launcher.rows[static_cast<std::size_t>(index)]
                                .title.c_str());
      gtk_editable_set_position(GTK_EDITABLE(launcher.search), -1);
      return TRUE;
    }
    case GDK_KEY_Escape:
      // Inside the action panel: back to the search rows first.
      if (Launcher::instance().actions_mode) {
        Launcher::instance().close_actions();
        return TRUE;
      }
      // A plugin detail panel or a finished AI answer dismisses first.
      if (gtk_widget_get_visible(Launcher::instance().detail_panel)) {
        Launcher::instance().dismiss_detail_panel();
        return TRUE;
      }
      if (gtk_widget_get_visible(Launcher::instance().ai_panel)) {
        Launcher::instance().dismiss_ai_panel();
        return TRUE;
      }
      // Alfred/Raycast convention: clear the query first, hide only when
      // it is already empty.
      if (const gchar* text =
              gtk_editable_get_text(GTK_EDITABLE(Launcher::instance().search));
          text != nullptr && *text != '\0') {
        gtk_editable_set_text(GTK_EDITABLE(Launcher::instance().search), "");
        Launcher::instance().run_search("");
      } else {
        Launcher::instance().hide();
      }
      return TRUE;
    case GDK_KEY_Down:
    case GDK_KEY_Up: {
      Launcher& launcher = Launcher::instance();
      int const delta = keyval == GDK_KEY_Down ? 1 : -1;
      GtkListBoxRow* current = gtk_list_box_get_selected_row(launcher.results);
      int index = current != nullptr ? gtk_list_box_row_get_index(current) : 0;
      index = std::clamp(index + delta, 0,
                         static_cast<int>(launcher.rows.size()) - 1);
      if (!launcher.rows.empty()) {
        gtk_list_box_select_row(launcher.results,
                                gtk_list_box_get_row_at_index(launcher.results,
                                                              index));
      }
      return TRUE;
    }
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter:
      Launcher::instance().run_selected();
      return TRUE;
    default:
      return FALSE;
  }
}

void on_window_active_changed(GObject* obj, GParamSpec*, gpointer) {
  auto* gtk_window = GTK_WINDOW(obj);
  // Hide on focus loss, matching the other platform hosts.
  if (!gtk_window_is_active(gtk_window) &&
      gtk_widget_get_visible(GTK_WIDGET(gtk_window))) {
    Launcher::instance().hide();
  }
}

void on_activate(GtkApplication* app, gpointer) {
  Launcher& launcher = Launcher::instance();
  launcher.app = app;  // tray quit routes through GApplication's shutdown

  // The panel hides on focus loss; without a hold, GTK would treat the
  // hidden window as "last window closed" and shut the whole app down.
  g_application_hold(G_APPLICATION(app));

  auto* window = gtk_application_window_new(app);
  launcher.window = GTK_WINDOW(window);
  gtk_window_set_title(launcher.window, "Fulcrum");
  gtk_window_set_default_size(launcher.window, 680, 440);
  gtk_window_set_resizable(launcher.window, FALSE);
  // The WM's close button HIDES, exactly like the other hosts: the
  // process stays resident (hotkey / --toggle / tray summon it back).
  // A close that quits would strand the user with no way to summon.
  // Handled explicitly: letting GTK's hide-on-close default run lets the
  // X11 surface die behind GDK's back ("GdkSurface unexpectedly
  // destroyed"), leaving a resident process with a window that can never
  // be presented again.
  gtk_window_set_hide_on_close(launcher.window, TRUE);
  g_signal_connect(window, "close-request",
                   G_CALLBACK(on_close_request), nullptr);
  gtk_widget_add_css_class(window, "fulcrum-window");

  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  auto* search = gtk_search_entry_new();
  gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(search),
                                        "Search apps, clipboard, snippets, the web…");
  gtk_widget_set_margin_top(search, 10);
  gtk_widget_set_margin_start(search, 10);
  gtk_widget_set_margin_end(search, 10);
  launcher.search = GTK_SEARCH_ENTRY(search);

  auto* status = gtk_label_new("Starting embedded Racket CS…");
  gtk_label_set_xalign(GTK_LABEL(status), 0.0);
  gtk_label_set_selectable(GTK_LABEL(status), TRUE);
  gtk_widget_set_margin_start(status, 12);
  gtk_widget_set_margin_top(status, 6);
  launcher.status = GTK_LABEL(status);

  // Live AI answer panel: hidden until the backend pushes the ai-stream
  // state, then shows the growing answer (GTK propagates the natural
  // height so short answers never reserve dead space).
  auto* ai_panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
  gtk_widget_set_visible(ai_panel, FALSE);
  gtk_widget_set_margin_start(ai_panel, 12);
  gtk_widget_set_margin_end(ai_panel, 12);
  gtk_widget_set_margin_top(ai_panel, 4);
  auto* ai_phase = gtk_label_new("AI is answering…");
  gtk_label_set_xalign(GTK_LABEL(ai_phase), 0.0);
  gtk_widget_add_css_class(ai_phase, "caption");
  gtk_widget_add_css_class(ai_phase, "dim-label");
  auto* ai_scroll = gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(ai_scroll),
                                 GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_max_content_height(
      GTK_SCROLLED_WINDOW(ai_scroll), 170);
  gtk_scrolled_window_set_propagate_natural_height(
      GTK_SCROLLED_WINDOW(ai_scroll), TRUE);
  auto* ai_text = gtk_label_new("");
  gtk_label_set_wrap(GTK_LABEL(ai_text), TRUE);
  gtk_label_set_xalign(GTK_LABEL(ai_text), 0.0);
  gtk_label_set_selectable(GTK_LABEL(ai_text), TRUE);
  gtk_widget_add_css_class(ai_text, "monospace");
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(ai_scroll), ai_text);
  gtk_box_append(GTK_BOX(ai_panel), ai_phase);
  gtk_box_append(GTK_BOX(ai_panel), ai_scroll);
  launcher.ai_panel = ai_panel;
  launcher.ai_phase = GTK_LABEL(ai_phase);
  launcher.ai_text = GTK_LABEL(ai_text);

  // FPP2 plugin detail panel: same slot, static payload (text + a
  // metadata block).
  auto* detail_panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
  gtk_widget_set_visible(detail_panel, FALSE);
  gtk_widget_set_margin_start(detail_panel, 12);
  gtk_widget_set_margin_end(detail_panel, 12);
  gtk_widget_set_margin_top(detail_panel, 4);
  auto* detail_header = gtk_label_new("Details");
  gtk_label_set_xalign(GTK_LABEL(detail_header), 0.0);
  gtk_widget_add_css_class(detail_header, "caption");
  gtk_widget_add_css_class(detail_header, "dim-label");
  auto* detail_scroll = gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(detail_scroll),
                                 GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_max_content_height(
      GTK_SCROLLED_WINDOW(detail_scroll), 180);
  gtk_scrolled_window_set_propagate_natural_height(
      GTK_SCROLLED_WINDOW(detail_scroll), TRUE);
  auto* detail_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
  auto* detail_text = gtk_label_new("");
  gtk_label_set_wrap(GTK_LABEL(detail_text), TRUE);
  gtk_label_set_xalign(GTK_LABEL(detail_text), 0.0);
  gtk_label_set_selectable(GTK_LABEL(detail_text), TRUE);
  auto* detail_meta = gtk_label_new("");
  gtk_label_set_wrap(GTK_LABEL(detail_meta), TRUE);
  gtk_label_set_xalign(GTK_LABEL(detail_meta), 0.0);
  gtk_label_set_selectable(GTK_LABEL(detail_meta), TRUE);
  gtk_widget_add_css_class(detail_meta, "dim-label");
  gtk_box_append(GTK_BOX(detail_box), detail_text);
  gtk_box_append(GTK_BOX(detail_box), detail_meta);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(detail_scroll),
                                detail_box);
  gtk_box_append(GTK_BOX(detail_panel), detail_header);
  gtk_box_append(GTK_BOX(detail_panel), detail_scroll);
  launcher.detail_panel = detail_panel;
  launcher.detail_text = GTK_LABEL(detail_text);
  launcher.detail_meta = GTK_LABEL(detail_meta);

  auto* scrolled = gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                 GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  auto* results = gtk_list_box_new();
  gtk_list_box_set_selection_mode(GTK_LIST_BOX(results), GTK_SELECTION_SINGLE);
  gtk_list_box_set_activate_on_single_click(GTK_LIST_BOX(results), FALSE);
  launcher.results = GTK_LIST_BOX(results);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), results);

  auto* hint = gtk_label_new("↑↓ navigate · ↵ run · esc hide — Fulcrum");
  gtk_label_set_xalign(GTK_LABEL(hint), 0.0);
  gtk_widget_add_css_class(hint, "caption");
  gtk_widget_add_css_class(hint, "dim-label");
  gtk_widget_set_margin_start(hint, 12);
  gtk_widget_set_margin_top(hint, 4);
  gtk_widget_set_margin_bottom(hint, 8);

  gtk_box_append(GTK_BOX(root), search);
  gtk_box_append(GTK_BOX(root), status);
  gtk_box_append(GTK_BOX(root), ai_panel);
  gtk_box_append(GTK_BOX(root), detail_panel);
  gtk_box_append(GTK_BOX(root), scrolled);
  gtk_box_append(GTK_BOX(root), hint);
  gtk_window_set_child(launcher.window, root);

  g_signal_connect(search, "search-changed",
                   G_CALLBACK(on_search_changed), nullptr);
  g_signal_connect(results, "row-activated",
                   G_CALLBACK(on_row_activated), nullptr);

  auto* controller = gtk_event_controller_key_new();
  gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE);
  g_signal_connect(controller, "key-pressed", G_CALLBACK(on_key_pressed),
                   nullptr);
  gtk_widget_add_controller(window, controller);

  g_signal_connect(window, "notify::is-active",
                   G_CALLBACK(on_window_active_changed), nullptr);

  // Realize once so the XID exists, then install the overlay chrome (X11
  // only, through EWMH) and the platform hotkey. Wayland compositors own
  // those decisions; the status message covers that honestly.
  gtk_widget_realize(window);
  if (GDK_IS_X11_DISPLAY(gtk_widget_get_display(window))) {
    Display* dpy =
        gdk_x11_display_get_xdisplay(gtk_widget_get_display(window));
    Window xid = gdk_x11_surface_get_xid(
        gtk_native_get_surface(GTK_NATIVE(window)));
    Atom wm_state = XInternAtom(dpy, "_NET_WM_STATE", False);
    Atom above = XInternAtom(dpy, "_NET_WM_STATE_ABOVE", False);
    Atom skip_taskbar = XInternAtom(dpy, "_NET_WM_STATE_SKIP_TASKBAR", False);
    Atom wm_window_type = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
    Atom utility = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_UTILITY", False);
    XChangeProperty(dpy, xid, wm_window_type, XA_ATOM, 32, PropModeReplace,
                    reinterpret_cast<unsigned char*>(&utility), 1);
    XChangeProperty(dpy, xid, wm_state, XA_ATOM, 32, PropModeAppend,
                    reinterpret_cast<unsigned char*>(&above), 1);
    XChangeProperty(dpy, xid, wm_state, XA_ATOM, 32, PropModeAppend,
                    reinterpret_cast<unsigned char*>(&skip_taskbar), 1);
  }
  // Hotkey, portal-first: where org.freedesktop.portal.GlobalShortcuts is
  // available (Wayland compositors and modern X11 desktops), the summon
  // shortcut is registered through the portal — the compositor asks for
  // consent once and owns the final binding. Sessions without the portal
  // fall back to the X11 grab (X11 only, by platform rules).
  if (rivet::system::GlobalShortcuts::available()) {
    // The object must outlive the async bind; it owns the portal session.
    g_portal_shortcuts = std::make_unique<rivet::system::GlobalShortcuts>();
    g_portal_shortcuts->set_activation_handler(
        [](std::string const&, std::uint64_t, std::string const&) {
          Launcher::instance().toggle();
        });
    g_portal_shortcuts->bind(
        {rivet::system::GlobalShortcutSpec{
            "summon", "Summon Fulcrum", "ALT+space"}},
        std::string(),
        [](rivet::system::GlobalShortcutBindResult const& result) {
          switch (result.status) {
            case rivet::system::GlobalShortcutBindStatus::cancelled:
              Launcher::post_status(
                  "Hotkey binding dismissed — bind `fulcrum --toggle` in "
                  "compositor settings instead.");
              break;
            case rivet::system::GlobalShortcutBindStatus::failed:
              Launcher::post_status("Portal hotkey failed: " +
                                    result.message);
              break;
            case rivet::system::GlobalShortcutBindStatus::bound:
              // The compositor owns the final combo; say what it chose —
              // and on GNOME check that the stock window menu is not
              // shadowing the very same combo.
              if (!result.bindings.empty() &&
                  !result.bindings[0].trigger_description.empty()) {
                std::string const trigger =
                    result.bindings[0].trigger_description;
                Launcher::post_status("Summon hotkey: " + trigger);
                check_hotkey_shadowing(trigger);
              }
              break;
            default:
              break;
          }
        });
    launcher.start_backend();
  } else {
    std::string hotkey_note = install_x11_hotkey(
        gtk_widget_get_display(window), launcher.window);
    if (!hotkey_note.empty()) {
      launcher.set_status(hotkey_note);
    }
    launcher.start_backend();
  }
  // Open on launch. A launcher that starts hidden is an invisible app on
  // every session where the summon path is not yet alive — Wayland before
  // the portal consent is granted, after a reboot, a rejected grab. The
  // panel is one Esc (or focus loss) away from hidden again.
  launcher.show();

  // The tray rides last: menus render with the i18n table loaded in main,
  // and the language arrival re-composes them (apply_tray_language).
  build_tray();
}

void on_shutdown(GApplication*, gpointer) {
  Launcher::instance().stop_backend();
}

}  // namespace

int main(int argc, char** argv) {
  (void)argc;
  (void)argv;  // --toggle is handled through the lease / activate() below.
  // The first-party rivet lease replaces the old pid-file + SIGUSR1 scheme:
  // second launches forward --toggle to the primary and exit.
  rivet::system::SingleInstanceLease lease("site.jrtx.fulcrum");
  if (!lease.is_primary()) {
    if (!lease.forward_arguments({"--toggle"})) {
      std::cerr << "fulcrum: running instance not reachable\n";
      return 1;
    }
    return 0;
  }
  // A --toggle that arrives when no primary is running is a summon, not an
  // error: the fresh instance becomes the primary and activate() opens the
  // panel. GApplication never sees the flag — the app runs without argv so
  // the option parser cannot reject it.
  lease.set_activation_handler(on_activation);

  // Load the i18n tables before any UI string is composed: the staged
  // shared/i18n JSON when packaged, the embedded fallback otherwise.
  load_i18n(executable_path().parent_path());

  XInitThreads();
  auto* app =
      gtk_application_new("site.jrtx.fulcrum", G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), nullptr);
  int const status =
      g_application_run(G_APPLICATION(app), 0, nullptr);
  g_object_unref(app);
  return status;
}
