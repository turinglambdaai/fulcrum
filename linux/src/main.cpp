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

#include "../GeneratedI18n.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
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
#include <unistd.h>

#include "GeneratedBackend.hpp"
#include "system_services.hpp"
#include "x11_hotkey.hpp"

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

// ---- panel styling ----------------------------------------------------------
//
// One stylesheet drives the panel look — glass background, amber (#D97706)
// rows, the ↵ chip on the selected row only — the same design tokens the
// macOS host renders through vibrancy and the Windows host through Desktop
// Acrylic. GNOME compositors do not blur, so the glass is an alpha
// background: KWin and other blurring compositors upgrade it to frosted
// glass for free, and a session without a compositor degrades to a solid
// panel. Re-applied when the backend pushes the theme state, because the
// dark variant picks its own glass tone.

static GtkCssProvider* g_panel_css = nullptr;

static void apply_panel_css() {
  gboolean dark = FALSE;
  if (GtkSettings* settings = gtk_settings_get_default()) {
    g_object_get(settings, "gtk-application-prefer-dark-theme", &dark,
                 nullptr);
  }
  char const* glass_css = dark
      ? R"CSS(
window.fulcrum-window {
  background-color: rgba(28,28,30,0.88);
  border-radius: 12px;
  border: 1px solid rgba(255,255,255,0.10);
  color: #f2f2f2;
}
)CSS"
      : R"CSS(
window.fulcrum-window {
  background-color: rgba(250,250,249,0.92);
  border-radius: 12px;
  border: 1px solid rgba(0,0,0,0.10);
  color: #1d1d1f;
}
)CSS";
  static char const* const shared_css = R"CSS(
window.fulcrum-window entry {
  background: none;
  border: none;
  box-shadow: none;
  outline: none;
  font-size: 19px;
  padding: 10px 4px;
}
window.fulcrum-window list {
  padding: 2px 8px 8px;
  background: none;
}
window.fulcrum-window list row {
  min-height: 44px;
  border-radius: 8px;
  margin: 1px 2px;
  padding: 4px 8px;
  background-color: transparent;
}
window.fulcrum-window list row:hover {
  background-color: alpha(#D97706, 0.08);
}
window.fulcrum-window list row:selected {
  background-color: alpha(#D97706, 0.14);
}
.fulcrum-row-title {
  font-size: 13px;
  font-weight: 600;
}
.fulcrum-row-subtitle {
  font-size: 11px;
}
.fulcrum-row-icon {
  background-color: alpha(#D97706, 0.12);
  border-radius: 6px;
  padding: 5px;
  color: #D97706;
}
.fulcrum-badge {
  background-color: alpha(#D97706, 0.14);
  color: #D97706;
  border-radius: 9px;
  padding: 1px 7px;
  font-size: 10px;
  font-weight: 700;
}
.fulcrum-enter {
  color: #D97706;
  font-weight: 700;
  opacity: 0;
}
list row:selected .fulcrum-enter {
  opacity: 1;
}
)CSS";

  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr) {
    return;
  }
  if (g_panel_css != nullptr) {
    gtk_style_context_remove_provider_for_display(
        display, GTK_STYLE_PROVIDER(g_panel_css));
    g_object_unref(g_panel_css);
    g_panel_css = nullptr;
  }
  g_panel_css = gtk_css_provider_new();
  gtk_css_provider_load_from_string(g_panel_css,
                                    (std::string(glass_css) + shared_css).c_str());
  gtk_style_context_add_provider_for_display(
      display, GTK_STYLE_PROVIDER(g_panel_css),
      GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

// Symbolic icon candidates per row kind, checked against the actual theme
// so a bare system never paints the "missing icon" box.
static char const* pick_icon(std::initializer_list<char const*> candidates) {
  GtkIconTheme* theme =
      gtk_icon_theme_get_for_display(gdk_display_get_default());
  if (theme == nullptr) {
    return nullptr;
  }
  for (char const* name : candidates) {
    if (gtk_icon_theme_has_icon(theme, name)) {
      return name;
    }
  }
  return nullptr;
}

static char const* row_icon_name(ResultRow const& row) {
  if (row.kind == "Calculator") {
    return pick_icon({"accessories-calculator-symbolic"});
  }
  if (row.kind == "Clipboard") {
    return pick_icon({"edit-paste-symbolic"});
  }
  if (row.kind == "Snippet") {
    return pick_icon({"text-editor-symbolic"});
  }
  if (row.kind == "Quicklink") {
    return pick_icon({"web-browser-symbolic", "link-symbolic"});
  }
  if (row.kind == "Web Search") {
    return pick_icon({"web-browser-symbolic", "system-search-symbolic"});
  }
  if (row.kind == "Plugin") {
    return pick_icon({"view-grid-symbolic", "system-run-symbolic"});
  }
  if (row.kind == "System") {
    return row.id == "sys.lock"
               ? pick_icon({"system-lock-screen-symbolic"})
               : pick_icon({"preferences-system-symbolic",
                            "emblem-system-symbolic"});
  }
  if (row.kind == "Setting") {
    return pick_icon({"preferences-system-symbolic"});
  }
  if (row.kind == "Window") {
    return pick_icon({"window-new-symbolic", "view-grid-symbolic"});
  }
  if (row.kind == "Update") {
    return pick_icon({"document-save-symbolic", "go-down-symbolic"});
  }
  if (row.kind == "AI") {
    return pick_icon({"starred-symbolic", "system-search-symbolic"});
  }
  if (row.kind == "File") {
    return pick_icon({"folder-documents-symbolic"});
  }
  return pick_icon({"application-x-executable-symbolic"});
}

// Rivet's POSIX shutdown plumbing (defined after Launcher). Installed once
// the embedded runtime has booted — see on_backend_ready for the ordering.
void install_shutdown_hook_once();

// Tray menu composition (defined after Launcher). Called when the backend
// `language` setting lands so the labels follow it without a restart.
void apply_tray_language();
void request_restart();
bool g_restart_requested{false};

// Settings window (defined after Launcher): the tray menu and the leading
// settings row open it.
void show_settings_window();

std::filesystem::path executable_path() {
  return std::filesystem::read_symlink("/proc/self/exe");
}

fulcrum::X11Hotkey g_x11_hotkey;

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
  HotkeySpec parsed;
  if (!parse_hotkey(spec, parsed)) {
    return "";
  }
  std::string const failure = g_x11_hotkey.bind(parsed.keysym, parsed.mods);
  if (failure.empty()) {
    return "";
  }

  // A launcher must never become unreachable because its preferred chord is
  // already owned by the desktop. macOS and Windows both fall back to the
  // three-modifier chord; keep Linux on the same interaction contract. The
  // X11Hotkey object retains the previous binding until this replacement has
  // been grabbed successfully, so a failed fallback is still non-destructive.
  HotkeySpec fallback;
  if (parse_hotkey("ctrl+alt+space", fallback) &&
      !(parsed.keysym == fallback.keysym && parsed.mods == fallback.mods) &&
      g_x11_hotkey.bind(fallback.keysym, fallback.mods).empty()) {
    return "Requested hotkey unavailable; using Ctrl+Alt+Space.";
  }
  return failure;
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
// `language` setting, refreshed after settings changes as well as at startup.
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
    {"traySettings", "设置…", "Settings…"},
    {"trayCheckUpdates", "检查更新…", "Check for Updates…"},
    {"trayAbout", "关于 Fulcrum", "About Fulcrum"},
    {"trayQuit", "退出 Fulcrum", "Quit Fulcrum"},
    {"trayRestart", "重启 Fulcrum", "Restart Fulcrum"},
    {"appMenu", "应用菜单", "Application menu"},
    {"searchPlaceholder", "搜索应用、剪贴板、片段、网页…",
     "Search apps, clipboard, snippets, the web…"},
    {"navigationHint", "↑↓ 选择 · 回车执行 · Ctrl+K 操作 · Esc 清空/隐藏",
     "↑↓ navigate · ↵ run · ctrl+k actions · esc clear/hide"},
    {"navigationHintActions", "↑↓ 选择 · 回车执行 · Esc 返回",
     "↑↓ navigate · ↵ run · esc back"},
    {"noSecondaryActions", "此结果没有次要操作",
     "No secondary actions for this result"},
    {"ready", "就绪 — 使用热键或 fulcrum --toggle 唤出",
     "Ready — hotkey or `fulcrum --toggle`"},
    {"settingUpdated", "设置已更新", "Setting updated"},
    {"notSet", "未设置", "Not set"},
    {"setting.language", "语言", "Language"},
    {"setting.theme", "主题", "Theme"},
    {"setting.hotkey", "全局快捷键", "Hotkey"},
    {"setting.max-results", "候选数量", "Maximum results"},
    {"setting.clipboard-enabled", "剪贴板历史", "Clipboard history"},
    {"setting.expansion-enabled", "片段自动展开", "Snippet expansion"},
    {"setting.web-search-enabled", "网页搜索", "Web search"},
    {"setting.plugins-enabled", "插件", "Plugins"},
    {"setting.ai-provider", "AI 服务商", "AI provider"},
    {"setting.language.description", "回车切换中文与英文，立即生效",
     "Select to switch between Chinese and English immediately"},
    {"setting.theme.description", "回车切换跟随系统、浅色、深色，立即生效",
     "Select to cycle system, light and dark immediately"},
    {"setting.hotkey.description", "回车切换全局唤出快捷键",
     "Select to cycle the global summon hotkey"},
    {"setting.max-results.description", "回车切换候选数量",
     "Select to cycle the maximum results"},
    {"setting.clipboard-enabled.description", "回车切换剪贴板历史记录",
     "Select to toggle clipboard history"},
    {"setting.expansion-enabled.description", "自动展开在 Linux 上不受支持",
     "Automatic expansion is not supported on Linux"},
    {"setting.web-search-enabled.description", "回车切换网页搜索候选",
     "Select to toggle web search results"},
    {"setting.plugins-enabled.description", "回车切换插件加载",
     "Select to toggle plugin loading"},
    {"setting.ai-provider.description", "回车切换未设置、OpenAI、Anthropic、Ollama",
     "Select to cycle not set, OpenAI, Anthropic and Ollama"},
    {"updateUpToDate", "已是最新版本", "Fulcrum is up to date"},
    {"updateCheckFailed", "检查更新失败：{0}", "Update check failed: {0}"},
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
    for (auto const& entry : rivet_app::kI18nTable) {
      table.emplace(std::string(entry.key),
                    std::string(lang == 0 ? entry.zh : entry.en));
    }
    // Handwritten entries predate generated i18n and remain a small bootstrap
    // safety net. emplace deliberately cannot override the generated table.
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

void set_i18n_language(std::string const& lang);
void refresh_settings_language();

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
  GtkButton* hotkey_fix{nullptr};
  GtkLabel* navigation_hint{nullptr};
  GtkMenuButton* app_menu{nullptr};
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
  guint focus_loss_source{0};
  // Focus-loss dismissal starts only after the compositor has activated this
  // presentation at least once. Wayland may report a newly presented surface
  // as visible-but-inactive while it resolves activation; hiding during that
  // handoff made the v0.13.1 summon hotkey look completely dead on Ubuntu.
  bool activated_since_show{false};
  int host_settings_generation{0};
  int theme_revision{0};
  int hotkey_revision{0};
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

  // Explicit light/dark uses GTK's built-in theme; system clears overrides.
  static void apply_theme(std::string const& theme) {
    GtkSettings* settings = gtk_settings_get_default();
    if (settings == nullptr) {
      return;
    }
    if (theme == "system") {
      gtk_settings_reset_property(settings, "gtk-theme-name");
      gtk_settings_reset_property(settings, "gtk-application-prefer-dark-theme");
    } else {
      g_object_set(settings, "gtk-theme-name", "Adwaita",
                   "gtk-application-prefer-dark-theme", theme == "dark", nullptr);
    }
    apply_panel_css();
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

  struct HostSettings {
    int generation{0};
    int theme_revision{0};
    int hotkey_revision{0};
    std::string hotkey;
    std::string theme;
    std::string language;
  };

  void apply_host_settings(HostSettings const& values) {
    if (values.generation != host_settings_generation || shutting_down.load()) return;
    if (!values.language.empty()) set_i18n_language(values.language);
    if (!values.hotkey.empty() && values.hotkey_revision == hotkey_revision) {
      std::string note = apply_x11_hotkey(values.hotkey);
      if (!note.empty()) set_status(note);
    }
    if (!values.theme.empty() && values.theme_revision == theme_revision) {
      apply_theme(values.theme);
    }
  }

  // Read the backend-owned settings the host renders (hotkey,
  // theme) plus the `language` key that steers the i18n table. The backend
  // pushes hotkey/theme changes afterwards via the reserved $state events;
  // this also refreshes language after a settings action.
  void pull_host_settings() {
    if (api == nullptr) {
      return;
    }
    auto* api_raw = api.get();
    auto* values = new HostSettings;
    values->generation = ++host_settings_generation;
    values->theme_revision = theme_revision;
    values->hotkey_revision = hotkey_revision;
    std::thread([api_raw, values]() mutable {
      try {
        // Row shape per the backend settings-list contract: [key, value, …].
        // One RPC provides a coherent snapshot rather than three mixed reads.
        for (auto const& row : api_raw->settings_list().get()) {
          if (row.size() < 2) continue;
          if (row[0] == "language") values->language = row[1];
          else if (row[0] == "theme") values->theme = row[1];
          else if (row[0] == "hotkey") values->hotkey = row[1];
        }
      } catch (...) {
      }
      g_idle_add([](gpointer user_data) -> int {
        std::unique_ptr<HostSettings> values(static_cast<HostSettings*>(user_data));
        Launcher::instance().apply_host_settings(*values);
        return G_SOURCE_REMOVE;
      }, values);
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
          auto& launcher = Launcher::instance();
          ++launcher.theme_revision;
          apply_theme(*theme);
          return G_SOURCE_REMOVE;
        }, new std::string(std::move(value_copy)));
      }
    } else if (*state_name == "search-revision") {
      g_idle_add([](gpointer) -> int {
        Launcher::instance().refresh_for_revision();
        return G_SOURCE_REMOVE;
      }, nullptr);
    } else if (*state_name == "language") {
      if (auto const* language =
              std::get_if<std::string>(&(fields->at(1).data))) {
        std::string value_copy = *language;
        g_idle_add([](gpointer user_data) -> int {
          std::unique_ptr<std::string> language(
              static_cast<std::string*>(user_data));
          set_i18n_language(*language);
          return G_SOURCE_REMOVE;
        }, new std::string(std::move(value_copy)));
      }
    } else if (*state_name == "hotkey") {
      if (auto const* spec = std::get_if<std::string>(&(fields->at(1).data))) {
        std::string spec_copy = *spec;
        g_idle_add([](gpointer user_data) -> int {
          std::unique_ptr<std::string> spec(
              static_cast<std::string*>(user_data));
          ++Launcher::instance().hotkey_revision;
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
    std::string selected_arg;
  };

  void run_search(std::string const& query, std::string selected_arg = {}) {
    if (api == nullptr || shutting_down.load(std::memory_order_acquire)) {
      return;
    }
    auto* api_raw = api.get();
    auto* boxed = new SearchOutcome;
    boxed->generation = search_generation.fetch_add(1) + 1;
    boxed->selected_arg = std::move(selected_arg);
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
    refresh_results(result.selected_arg);
  }

  void scroll_to_selection() {
    auto* selected = gtk_list_box_get_selected_row(results);
    auto* scrolled = gtk_widget_get_ancestor(GTK_WIDGET(results),
                                            GTK_TYPE_SCROLLED_WINDOW);
    graphene_rect_t bounds{};
    if (selected == nullptr || scrolled == nullptr ||
        !gtk_widget_compute_bounds(GTK_WIDGET(selected), scrolled,
                                    &bounds)) return;
    auto* adjustment = gtk_scrolled_window_get_vadjustment(
        GTK_SCROLLED_WINDOW(scrolled));
    double const offset = gtk_adjustment_get_value(adjustment);
    gtk_adjustment_clamp_page(adjustment, offset + bounds.origin.y,
                             offset + bounds.origin.y + bounds.size.height);
  }

  void refresh_results(std::string const& selected_arg = {},
                       std::string const& selected_id = "settings.set") {
    // Rebuild the list; simple and correct beats incremental cleverness at
    // this list size (≤ max-results rows).
    for (GtkWidget* child = gtk_widget_get_first_child(GTK_WIDGET(results));
         child != nullptr;) {
      GtkWidget* next = gtk_widget_get_next_sibling(child);
      gtk_list_box_remove(results, child);
      child = next;
    }
    for (auto const& row : rows) {
      // Row grammar matches the macOS/Windows hosts: amber icon tile,
      // title over muted subtitle, badge chip, and the ↵ chip that the
      // stylesheet shows only on the selected row.
      auto* box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
      gtk_widget_set_valign(box, GTK_ALIGN_CENTER);

      if (char const* icon_name = row_icon_name(row)) {
        auto* icon = gtk_image_new_from_icon_name(icon_name);
        gtk_image_set_pixel_size(GTK_IMAGE(icon), 16);
        gtk_widget_add_css_class(icon, "fulcrum-row-icon");
        gtk_box_append(GTK_BOX(box), icon);
      }

      auto* texts = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1);
      gtk_widget_set_valign(texts, GTK_ALIGN_CENTER);
      gtk_widget_set_hexpand(texts, TRUE);
      std::string title_text = row.title;
      std::string subtitle_text = row.subtitle.empty() ? row.kind : row.subtitle;
      if (row.id == "settings.set") {
        std::string const key = "setting." + row.arg;
        if (tr(key.c_str()) != key) {
          title_text = tr(key.c_str()) + " (" + row.arg + ")";
          subtitle_text = tr((key + ".description").c_str());
        }
      }
      auto* title = gtk_label_new(title_text.c_str());
      gtk_label_set_xalign(GTK_LABEL(title), 0.0);
      gtk_label_set_ellipsize(GTK_LABEL(title), PANGO_ELLIPSIZE_END);
      gtk_widget_add_css_class(title, "fulcrum-row-title");
      auto* subtitle = gtk_label_new(subtitle_text.c_str());
      gtk_label_set_xalign(GTK_LABEL(subtitle), 0.0);
      gtk_label_set_ellipsize(GTK_LABEL(subtitle), PANGO_ELLIPSIZE_END);
      gtk_widget_add_css_class(subtitle, "fulcrum-row-subtitle");
      gtk_widget_add_css_class(subtitle, "dim-label");
      gtk_box_append(GTK_BOX(texts), title);
      gtk_box_append(GTK_BOX(texts), subtitle);
      gtk_box_append(GTK_BOX(box), texts);

      if (!row.badge.empty() || row.id == "settings.set") {
        auto* badge = gtk_label_new(row.badge.empty() ? tr("notSet").c_str() : row.badge.c_str());
        gtk_widget_add_css_class(badge, "fulcrum-badge");
        gtk_widget_set_valign(badge, GTK_ALIGN_CENTER);
        gtk_box_append(GTK_BOX(box), badge);
      }

      auto* enter = gtk_label_new("\u21B5");
      gtk_widget_add_css_class(enter, "fulcrum-enter");
      gtk_widget_set_valign(enter, GTK_ALIGN_CENTER);
      gtk_box_append(GTK_BOX(box), enter);

      gtk_list_box_append(results, box);
    }
    if (!rows.empty()) {
      auto selected = std::find_if(rows.begin(), rows.end(), [&](auto const& row) {
        return row.id == selected_id && row.arg == selected_arg;
      });
      int const index = selected == rows.end() ? 0 :
          static_cast<int>(std::distance(rows.begin(), selected));
      gtk_list_box_select_row(results,
                              gtk_list_box_get_row_at_index(results, index));
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
        gtk_label_set_text(launcher.navigation_hint,
                           tr("navigationHintActions").c_str());
        if (launcher.rows.empty()) {
          launcher.set_status(tr("noSecondaryActions"));
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
    gtk_label_set_text(navigation_hint, tr("navigationHint").c_str());
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
    if (row.id == "settings.set") ++host_settings_generation;
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
          // The settings window rides "delegated" the same way.
          if (job->action_id == "settings.open") {
            Launcher::instance().hide();
            show_settings_window();
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
          if (job->action_id == "settings.set") {
            auto& launcher = Launcher::instance();
            launcher.set_status(tr("settingUpdated"));
            launcher.pull_host_settings();
            launcher.run_search(
                gtk_editable_get_text(GTK_EDITABLE(launcher.search)), job->arg);
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

  void show(guint32 user_time = GDK_CURRENT_TIME) {
    cancel_focus_loss();
    activated_since_show = false;
    actions_mode = false;
    if (navigation_hint != nullptr) {
      gtk_label_set_text(navigation_hint, tr("navigationHint").c_str());
    }
    dismiss_ai_panel();
    dismiss_detail_panel();
    gtk_editable_set_text(GTK_EDITABLE(search), "");
    run_search("");
    gtk_widget_set_visible(GTK_WIDGET(window), TRUE);
    auto* display = gtk_widget_get_display(GTK_WIDGET(window));
    if (GDK_IS_X11_DISPLAY(display)) {
      guint32 const present_time =
          user_time != GDK_CURRENT_TIME
              ? user_time
              : gdk_x11_display_get_user_time(display);
      gtk_window_present_with_time(window, present_time);
    } else {
      gtk_window_present(window);
    }
    // X11 can grant focus synchronously; Wayland repeats this when the
    // is-active notification arrives below.
    gtk_widget_grab_focus(GTK_WIDGET(search));
    // A hidden window can remain the compositor's active toplevel. In that
    // case showing it again produces no is-active transition, so seed the
    // focus-loss guard from the state immediately after present.
    activated_since_show = gtk_window_is_active(window);
  }

  void cancel_focus_loss() {
    if (focus_loss_source != 0) {
      g_source_remove(focus_loss_source);
      focus_loss_source = 0;
    }
  }

  void hide() {
    cancel_focus_loss();
    gtk_widget_set_visible(GTK_WIDGET(window), FALSE);
  }

  void toggle(guint32 user_time = GDK_CURRENT_TIME) {
    if (gtk_widget_get_visible(GTK_WIDGET(window))) {
      hide();
    } else {
      show(user_time);
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

    set_status(tr("ready"));
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

void set_i18n_language(std::string const& lang) {
  int const active = (lang == "en") ? 1 : 0;
  bool const changed = g_i18n_active.exchange(active) != active;
  auto& launcher = Launcher::instance();
  if (launcher.search != nullptr) {
    gtk_search_entry_set_placeholder_text(launcher.search,
                                          tr("searchPlaceholder").c_str());
  }
  if (launcher.navigation_hint != nullptr) {
    gtk_label_set_text(launcher.navigation_hint, tr("navigationHint").c_str());
  }
  if (launcher.hotkey_fix != nullptr) {
    gtk_button_set_label(launcher.hotkey_fix, tr("trayFixHotkey").c_str());
  }
  if (launcher.app_menu != nullptr) {
    gtk_widget_set_tooltip_text(GTK_WIDGET(launcher.app_menu), tr("appMenu").c_str());
    auto* menu = g_menu_new();
    g_menu_append(menu, tr("trayRestart").c_str(), "app.restart");
    g_menu_append(menu, tr("trayQuit").c_str(), "app.quit");
    gtk_menu_button_set_menu_model(launcher.app_menu, G_MENU_MODEL(menu));
    g_object_unref(menu);
  }
  if (changed && launcher.results != nullptr) {
    auto* selected = gtk_list_box_get_selected_row(launcher.results);
    int index = selected != nullptr ? gtk_list_box_row_get_index(selected) : -1;
    std::string const arg = index >= 0 && index < static_cast<int>(launcher.rows.size())
        ? launcher.rows[static_cast<std::size_t>(index)].arg : "";
    std::string const id = index >= 0 && index < static_cast<int>(launcher.rows.size())
        ? launcher.rows[static_cast<std::size_t>(index)].id : "";
    launcher.refresh_results(arg, id);
  }
  if (changed && launcher.api != nullptr) launcher.set_status(tr("ready"));
  apply_tray_language();
  refresh_settings_language();
}

// ---- settings window ---------------------------------------------------------
//
// A form over the backend settings store — the discoverable twin of the
// `settings` query rows, reached from the tray menu and the leading
// settings row. Every control carries its backend key; edits go through
// settings-set as they happen, the backend validates (hotkey grammar,
// ranges, provider names), a refusal shows inline and the form reloads the
// backend's truth. The AI key rides the ai.key action and never comes back
// over the wire; ai-status reports readiness instead. One window, hidden on
// close and reloaded on every show.

enum class SettingKind { toggle, choice, number, text };

struct SettingBinding {
  std::string key;
  SettingKind kind{SettingKind::text};
  std::vector<std::string> choices;  // choice: drop-down index → value
  GtkWidget* widget{nullptr};
};

struct SettingsForm {
  GtkWindow* window{nullptr};
  std::vector<std::unique_ptr<SettingBinding>> bindings;
  // Keep backend-defined localized labels alive across language changes.
  std::vector<std::tuple<GtkLabel*, std::string, std::string>> localized_labels;
  GtkLabel* ai_status{nullptr};
  GtkLabel* key_notice{nullptr};
  GtkWidget* key_entry{nullptr};
  GtkLabel* error{nullptr};
  std::map<std::string, std::string> values;
  // True while apply pushes values into the controls, so their change
  // handlers do not write them straight back.
  bool loading{false};
};

SettingsForm* g_settings_form = nullptr;

void settings_load();

void settings_show_error(std::string const& message) {
  if (g_settings_form == nullptr) return;
  gtk_label_set_text(g_settings_form->error, message.c_str());
  gtk_widget_set_visible(GTK_WIDGET(g_settings_form->error), !message.empty());
}

void settings_refresh_ai_status() {
  auto* api_raw = Launcher::instance().api.get();
  if (api_raw == nullptr) return;
  std::thread([api_raw]() {
    std::string status;
    try {
      status = api_raw->ai_status().get();
    } catch (...) {
    }
    g_idle_add([](gpointer user_data) -> int {
      std::unique_ptr<std::string> text(static_cast<std::string*>(user_data));
      if (g_settings_form != nullptr) {
        gtk_label_set_text(g_settings_form->ai_status,
                           *text == "ready" ? "Ready" : text->c_str());
      }
      return G_SOURCE_REMOVE;
    }, new std::string(std::move(status)));
  }).detach();
}

void settings_write(std::string const& key, std::string const& value) {
  if (g_settings_form == nullptr || key.empty()) return;
  // A form edit supersedes any host snapshot requested before this write.
  auto& launcher = Launcher::instance();
  ++launcher.host_settings_generation;
  auto* api_raw = launcher.api.get();
  if (api_raw == nullptr) return;
  g_settings_form->values[key] = value;
  std::thread([api_raw, key, value]() {
    std::string error;
    try {
      api_raw->settings_set(key, value).get();
    } catch (std::exception const& e) {
      error = e.what();
    } catch (...) {
      error = "settings-set failed";
    }
    g_idle_add([](gpointer user_data) -> int {
      std::unique_ptr<std::pair<std::string, std::string>> result(
          static_cast<std::pair<std::string, std::string>*>(user_data));
      auto const& [written_key, written_error] = *result;
      if (g_settings_form == nullptr) return G_SOURCE_REMOVE;
      if (written_error.empty()) {
        settings_show_error("");
        if (written_key == "ai-provider") {
          settings_refresh_ai_status();
        } else if (written_key == "language") {
          set_i18n_language(g_settings_form->values[written_key]);
          apply_tray_language();
        }
      } else {
        // The backend refused the value (grammar, range): say so and fall
        // back to what it actually holds.
        settings_show_error(written_key + ": " + written_error);
        settings_load();
      }
      return G_SOURCE_REMOVE;
    }, new std::pair<std::string, std::string>(key, std::move(error)));
  }).detach();
}

std::string settings_trimmed(std::string value) {
  auto const begin = value.find_first_not_of(" \t\r\n");
  if (begin == std::string::npos) return {};
  auto const end = value.find_last_not_of(" \t\r\n");
  return value.substr(begin, end - begin + 1);
}

void settings_commit_entry(SettingBinding* binding) {
  if (g_settings_form == nullptr || g_settings_form->loading) return;
  std::string const value = settings_trimmed(
      gtk_editable_get_text(GTK_EDITABLE(binding->widget)));
  auto const it = g_settings_form->values.find(binding->key);
  if (it != g_settings_form->values.end() && it->second == value) return;
  settings_write(binding->key, value);
}

void on_setting_switch(GObject* object, GParamSpec*, gpointer user_data) {
  if (g_settings_form == nullptr || g_settings_form->loading) return;
  auto* binding = static_cast<SettingBinding*>(user_data);
  settings_write(binding->key,
                 gtk_switch_get_active(GTK_SWITCH(object)) ? "on" : "off");
}

void on_setting_choice(GObject* object, GParamSpec*, gpointer user_data) {
  if (g_settings_form == nullptr || g_settings_form->loading) return;
  auto* binding = static_cast<SettingBinding*>(user_data);
  guint const index = gtk_drop_down_get_selected(GTK_DROP_DOWN(object));
  if (index == GTK_INVALID_LIST_POSITION || index >= binding->choices.size()) return;
  settings_write(binding->key, binding->choices[index]);
}

void on_setting_number(GtkSpinButton* spin, gpointer user_data) {
  if (g_settings_form == nullptr || g_settings_form->loading) return;
  auto* binding = static_cast<SettingBinding*>(user_data);
  settings_write(binding->key,
                 std::to_string(gtk_spin_button_get_value_as_int(spin)));
}

void on_setting_entry_activate(GtkEntry*, gpointer user_data) {
  settings_commit_entry(static_cast<SettingBinding*>(user_data));
}

void on_setting_entry_leave(GtkEventControllerFocus*, gpointer user_data) {
  settings_commit_entry(static_cast<SettingBinding*>(user_data));
}

void settings_save_key() {
  if (g_settings_form == nullptr) return;
  auto* api_raw = Launcher::instance().api.get();
  if (api_raw == nullptr) return;
  std::string const key = settings_trimmed(
      gtk_editable_get_text(GTK_EDITABLE(g_settings_form->key_entry)));
  if (key.empty()) return;
  std::thread([api_raw, key]() {
    std::string status;
    try {
      status = api_raw->run_action("ai.key", key).get();
    } catch (std::exception const& e) {
      status = e.what();
    } catch (...) {
      status = "ai.key failed";
    }
    g_idle_add([](gpointer user_data) -> int {
      std::unique_ptr<std::string> text(static_cast<std::string*>(user_data));
      if (g_settings_form != nullptr) {
        gtk_label_set_text(
            g_settings_form->key_notice,
            *text == "ok" ? "Key saved — stored on this machine only, never synced."
                          : text->c_str());
        gtk_editable_set_text(GTK_EDITABLE(g_settings_form->key_entry), "");
        settings_refresh_ai_status();
      }
      return G_SOURCE_REMOVE;
    }, new std::string(std::move(status)));
  }).detach();
}

void on_save_key_clicked(GtkButton*, gpointer) { settings_save_key(); }
void on_key_entry_activate(GtkPasswordEntry*, gpointer) { settings_save_key(); }

// ---- form construction

GtkWidget* settings_row(GtkWidget* section, char const* label_text,
                        GtkWidget* control, char const* setting_key = nullptr) {
  auto* row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
  gtk_widget_set_margin_top(row, 8);
  gtk_widget_set_margin_bottom(row, 8);
  gtk_widget_set_margin_start(row, 14);
  gtk_widget_set_margin_end(row, 14);
  std::string const lookup = setting_key == nullptr
      ? "" : "setting." + std::string(setting_key);
  std::string const translated = lookup.empty() ? "" : tr(lookup.c_str());
  auto* label = gtk_label_new(!lookup.empty() && translated != lookup
                                  ? translated.c_str() : label_text);
  if (!lookup.empty()) {
    g_settings_form->localized_labels.emplace_back(
        GTK_LABEL(label), lookup, label_text);
  }
  gtk_label_set_xalign(GTK_LABEL(label), 0.0);
  gtk_label_set_wrap(GTK_LABEL(label), TRUE);
  gtk_widget_set_hexpand(label, TRUE);
  gtk_widget_set_halign(control, GTK_ALIGN_END);
  gtk_widget_set_valign(control, GTK_ALIGN_CENTER);
  gtk_box_append(GTK_BOX(row), label);
  gtk_box_append(GTK_BOX(row), control);
  gtk_box_append(GTK_BOX(section), row);
  return row;
}

void settings_hint(GtkWidget* section, char const* text) {
  auto* label = gtk_label_new(text);
  gtk_label_set_xalign(GTK_LABEL(label), 0.0);
  gtk_label_set_wrap(GTK_LABEL(label), TRUE);
  gtk_widget_add_css_class(label, "caption");
  gtk_widget_add_css_class(label, "dim-label");
  gtk_widget_set_margin_start(label, 14);
  gtk_widget_set_margin_end(label, 14);
  gtk_widget_set_margin_bottom(label, 8);
  gtk_box_append(GTK_BOX(section), label);
}

GtkWidget* settings_section(GtkWidget* page, char const* title) {
  auto* heading = gtk_label_new(title);
  gtk_label_set_xalign(GTK_LABEL(heading), 0.0);
  gtk_widget_add_css_class(heading, "heading");
  gtk_widget_set_margin_top(heading, 14);
  gtk_box_append(GTK_BOX(page), heading);
  auto* frame = gtk_frame_new(nullptr);
  auto* body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  gtk_frame_set_child(GTK_FRAME(frame), body);
  gtk_box_append(GTK_BOX(page), frame);
  return body;
}

SettingBinding* settings_bind(std::string key, SettingKind kind,
                              GtkWidget* widget,
                              std::vector<std::string> choices = {}) {
  auto binding = std::make_unique<SettingBinding>();
  binding->key = std::move(key);
  binding->kind = kind;
  binding->widget = widget;
  binding->choices = std::move(choices);
  auto* raw = binding.get();
  g_settings_form->bindings.push_back(std::move(binding));
  return raw;
}

GtkWidget* settings_add_toggle(GtkWidget* section, char const* label,
                               char const* key) {
  auto* toggle = gtk_switch_new();
  auto* binding = settings_bind(key, SettingKind::toggle, toggle);
  g_signal_connect(toggle, "notify::active", G_CALLBACK(on_setting_switch), binding);
  settings_row(section, label, toggle, key);
  return toggle;
}

void settings_add_choice(GtkWidget* section, char const* label, char const* key,
                         std::vector<std::pair<char const*, char const*>> const& options) {
  std::vector<char const*> labels;
  std::vector<std::string> values;
  for (auto const& [text, value] : options) {
    labels.push_back(text);
    values.push_back(value);
  }
  labels.push_back(nullptr);
  auto* drop = gtk_drop_down_new_from_strings(labels.data());
  auto* binding = settings_bind(key, SettingKind::choice, drop, std::move(values));
  g_signal_connect(drop, "notify::selected", G_CALLBACK(on_setting_choice), binding);
  settings_row(section, label, drop, key);
}

void settings_add_number(GtkWidget* section, char const* label, char const* key,
                         double min, double max) {
  auto* spin = gtk_spin_button_new_with_range(min, max, 1);
  auto* binding = settings_bind(key, SettingKind::number, spin);
  g_signal_connect(spin, "value-changed", G_CALLBACK(on_setting_number), binding);
  settings_row(section, label, spin, key);
}

void settings_add_text(GtkWidget* section, char const* label, char const* key,
                       char const* placeholder) {
  auto* entry = gtk_entry_new();
  gtk_entry_set_placeholder_text(GTK_ENTRY(entry), placeholder);
  gtk_widget_set_size_request(entry, 260, -1);
  auto* binding = settings_bind(key, SettingKind::text, entry);
  g_signal_connect(entry, "activate", G_CALLBACK(on_setting_entry_activate), binding);
  auto* focus = gtk_event_controller_focus_new();
  g_signal_connect(focus, "leave", G_CALLBACK(on_setting_entry_leave), binding);
  gtk_widget_add_controller(entry, focus);
  settings_row(section, label, entry, key);
}

void refresh_settings_language() {
  if (g_settings_form == nullptr) return;
  for (auto const& [label, key, fallback] : g_settings_form->localized_labels) {
    std::string const value = tr(key.c_str());
    gtk_label_set_text(label, value == key ? fallback.c_str() : value.c_str());
  }
}

void settings_build() {
  g_settings_form = new SettingsForm();
  auto* window = gtk_window_new();
  g_settings_form->window = GTK_WINDOW(window);
  gtk_window_set_title(GTK_WINDOW(window), "Fulcrum Settings");
  gtk_window_set_default_size(GTK_WINDOW(window), 660, 760);
  gtk_window_set_hide_on_close(GTK_WINDOW(window), TRUE);

  auto* scrolled = gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                 GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  auto* page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_margin_top(page, 8);
  gtk_widget_set_margin_bottom(page, 24);
  gtk_widget_set_margin_start(page, 28);
  gtk_widget_set_margin_end(page, 28);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), page);
  gtk_window_set_child(GTK_WINDOW(window), scrolled);

  auto* general = settings_section(page, "General");
  settings_add_choice(general, "Language", "language",
                      {{"中文", "zh"}, {"English", "en"}});
  settings_add_choice(general, "Theme", "theme",
                      {{"System", "system"}, {"Light", "light"}, {"Dark", "dark"}});
  settings_add_text(general, "Hotkey", "hotkey", "alt+space");
  settings_hint(general,
                "Modifiers alt / ctrl / shift / super plus a key: space, a–z, 0–9, "
                "f1–f12, comma, period, minus, equal, tab. Applies immediately; "
                "a taken combo falls back to Ctrl+Alt+Space.");
  settings_add_number(general, "Maximum results", "max-results", 5, 25);

  auto* features = settings_section(page, "Features");
  settings_add_toggle(features, "Record clipboard history", "clipboard-enabled");
  settings_add_number(features, "Clipboard history limit", "clipboard-limit", 10, 100000);
  settings_add_toggle(features, "Web search rows (bangs and fallback)", "web-search-enabled");
  settings_add_choice(features, "Default bang", "default-engine",
                      {{"!g", "!g"}, {"!d", "!d"}, {"!gh", "!gh"}, {"!so", "!so"},
                       {"!w", "!w"}, {"!yt", "!yt"}, {"!m", "!m"}, {"!t", "!t"}});
  auto* expansion = settings_add_toggle(
      features, "Expand snippet keywords as you type in any app",
      "expansion-enabled");
  gtk_widget_set_sensitive(expansion, FALSE);
  settings_hint(features,
                "Snippet expansion is not supported on Linux yet; the setting "
                "is shown so the three hosts expose the same feature map.");
  settings_add_toggle(features, "Load plugins", "plugins-enabled");
  settings_add_number(features, "Plugin call timeout (ms)", "plugins-timeout-ms", 100, 10000);

  auto* ai = settings_section(page, "AI");
  settings_add_choice(ai, "Provider", "ai-provider",
                      {{"Off", ""}, {"OpenAI", "openai"},
                       {"Anthropic", "anthropic"}, {"Ollama", "ollama"}});
  settings_add_text(ai, "Model", "ai-model", "provider default");
  settings_add_text(ai, "Base URL", "ai-base-url", "provider default");
  settings_add_text(ai, "Persona", "ai-persona", "prepended to every request");
  auto* key_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  auto* key_entry = gtk_password_entry_new();
  gtk_password_entry_set_show_peek_icon(GTK_PASSWORD_ENTRY(key_entry), TRUE);
  gtk_widget_set_size_request(key_entry, 240, -1);
  g_signal_connect(key_entry, "activate", G_CALLBACK(on_key_entry_activate), nullptr);
  auto* save = gtk_button_new_with_label("Save");
  g_signal_connect(save, "clicked", G_CALLBACK(on_save_key_clicked), nullptr);
  gtk_box_append(GTK_BOX(key_box), key_entry);
  gtk_box_append(GTK_BOX(key_box), save);
  g_settings_form->key_entry = key_entry;
  settings_row(ai, "API key", key_box);
  auto* status = gtk_label_new("");
  gtk_label_set_xalign(GTK_LABEL(status), 0.0);
  gtk_widget_add_css_class(status, "dim-label");
  gtk_widget_set_margin_start(status, 14);
  gtk_widget_set_margin_end(status, 14);
  gtk_box_append(GTK_BOX(ai), status);
  g_settings_form->ai_status = GTK_LABEL(status);
  auto* notice = gtk_label_new("");
  gtk_label_set_xalign(GTK_LABEL(notice), 0.0);
  gtk_label_set_wrap(GTK_LABEL(notice), TRUE);
  gtk_widget_add_css_class(notice, "caption");
  gtk_widget_add_css_class(notice, "dim-label");
  gtk_widget_set_margin_start(notice, 14);
  gtk_widget_set_margin_end(notice, 14);
  gtk_box_append(GTK_BOX(ai), notice);
  g_settings_form->key_notice = GTK_LABEL(notice);
  settings_hint(ai, "Stored in ai-keys.json on this machine; never mirrored to the sync folder.");

  auto* sync = settings_section(page, "Sync & Updates");
  settings_add_text(sync, "Sync folder (beta)", "sync-root", "empty = off");
  settings_hint(sync,
                "A folder a file sync service replicates (Syncthing, Nextcloud, "
                "Dropbox); settings and snippets mirror there.");
  settings_add_text(sync, "Update feed base URL", "update-base-url", "https://…");

  auto* error = gtk_label_new("");
  gtk_label_set_xalign(GTK_LABEL(error), 0.0);
  gtk_label_set_wrap(GTK_LABEL(error), TRUE);
  gtk_label_set_selectable(GTK_LABEL(error), TRUE);
  gtk_widget_add_css_class(error, "error");
  gtk_widget_set_margin_top(error, 12);
  gtk_widget_set_visible(error, FALSE);
  gtk_box_append(GTK_BOX(page), error);
  g_settings_form->error = GTK_LABEL(error);
}

void settings_apply(std::map<std::string, std::string> values, std::string ai_status) {
  if (g_settings_form == nullptr) return;
  g_settings_form->values = std::move(values);
  g_settings_form->loading = true;
  for (auto const& binding : g_settings_form->bindings) {
    auto const it = g_settings_form->values.find(binding->key);
    std::string const value = it == g_settings_form->values.end() ? "" : it->second;
    switch (binding->kind) {
      case SettingKind::toggle:
        gtk_switch_set_active(GTK_SWITCH(binding->widget), value == "on");
        break;
      case SettingKind::choice: {
        guint selected = GTK_INVALID_LIST_POSITION;
        for (std::size_t i = 0; i < binding->choices.size(); ++i) {
          if (binding->choices[i] == value) {
            selected = static_cast<guint>(i);
            break;
          }
        }
        gtk_drop_down_set_selected(GTK_DROP_DOWN(binding->widget), selected);
        break;
      }
      case SettingKind::number: {
        double number = 0;
        try {
          number = std::stod(value);
        } catch (...) {
        }
        gtk_spin_button_set_value(GTK_SPIN_BUTTON(binding->widget), number);
        break;
      }
      case SettingKind::text:
        gtk_editable_set_text(GTK_EDITABLE(binding->widget), value.c_str());
        break;
    }
  }
  gtk_label_set_text(g_settings_form->ai_status,
                     ai_status == "ready" ? "Ready" : ai_status.c_str());
  g_settings_form->loading = false;
}

void settings_load() {
  auto* api_raw = Launcher::instance().api.get();
  if (api_raw == nullptr || g_settings_form == nullptr) return;
  std::thread([api_raw]() {
    auto* payload = new std::pair<std::map<std::string, std::string>, std::string>();
    try {
      // settings-list rows: (key value description …); booleans read on/off.
      for (auto const& row : api_raw->settings_list().get()) {
        if (row.size() >= 2) {
          payload->first[row[0]] = row[1];
        }
      }
    } catch (...) {
    }
    try {
      payload->second = api_raw->ai_status().get();
    } catch (...) {
    }
    g_idle_add([](gpointer user_data) -> int {
      std::unique_ptr<std::pair<std::map<std::string, std::string>, std::string>>
          loaded(static_cast<std::pair<std::map<std::string, std::string>,
                                       std::string>*>(user_data));
      settings_apply(std::move(loaded->first), std::move(loaded->second));
      return G_SOURCE_REMOVE;
    }, payload);
  }).detach();
}

void show_settings_window() {
  if (Launcher::instance().api == nullptr) {
    Launcher::instance().set_status("Settings open once the backend is ready…");
    return;
  }
  if (g_settings_form == nullptr) {
    settings_build();
  }
  settings_load();
  gtk_window_present(g_settings_form->window);
}

// ---- X11 global hotkey ----------------------------------------------------

std::string install_x11_hotkey(GdkDisplay* display) {
  if (GDK_IS_X11_DISPLAY(display) == 0) {
    return "Wayland session: compositors do not allow global key grabs. "
           "Bind `fulcrum --toggle` to a key in your compositor settings.";
  }
  std::string note = g_x11_hotkey.start(
      gdk_display_get_name(display), [](Time time) {
        Launcher::instance().toggle(static_cast<guint32>(time));
      });
  if (!note.empty()) return note;
  // Use the root on a dedicated connection so the grab works even when
  // the launcher is hidden, without changing GDK's event mask or queue.
  return apply_x11_hotkey("alt+space");
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

gboolean show_on_main(gpointer) {
  Launcher::instance().show();
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

void request_restart() {
  g_restart_requested = true;
  tray_quit();
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
    if (launcher.hotkey_fix != nullptr) {
      gtk_widget_set_visible(GTK_WIDGET(launcher.hotkey_fix), FALSE);
    }
    rebuild_tray_menu();
    Launcher::post_status(tr("hotkeyFreed"));
  } else {
    Launcher::post_status(std::string("gsettings failed (rc=") +
                          std::to_string(rc) + ")");
  }
}

// Manual update check from the tray: manual=true bypasses the 4-hour
// family throttle (the backend stamps the timestamp either way). The
// result lands in the launcher status line; the `update` query rows drive
// download and install from there.
void tray_check_updates() {
  auto* api_raw = Launcher::instance().api.get();
  if (api_raw == nullptr) {
    Launcher::post_status("Update check once the backend is ready…");
    return;
  }
  std::thread([api_raw]() {
    std::string line;
    try {
      auto const check = api_raw->update_check(true).get();
      if (check.status == "available") {
        line = tr_format("updateAvailableStatus",
                         {check.available_version.value_or("?")});
      } else if (check.status == "up-to-date") {
        line = tr("updateUpToDate");
      } else {
        line = tr_format("updateCheckFailed",
                         {check.error.value_or("check failed")});
      }
    } catch (std::exception const& e) {
      line = tr_format("updateCheckFailed", {e.what()});
    } catch (...) {
      line = tr("updateCheckFailed") + ": unknown error";
    }
    Launcher::post_status(std::move(line));
  }).detach();
}

std::vector<rivet::system::TrayMenuItem> tray_menu_items() {
  std::vector<rivet::system::TrayMenuItem> items;
  items.push_back(rivet::system::TrayMenuItem(
      tr("trayOpen"), [] { Launcher::instance().show(); }));
  items.push_back(rivet::system::TrayMenuItem(
      tr("traySettings"), [] { show_settings_window(); }));
  // Check for Updates and About always travel together (the family rule).
  items.push_back(rivet::system::TrayMenuItem(
      tr("trayCheckUpdates"), [] { tray_check_updates(); }));
  items.push_back(rivet::system::TrayMenuItem(
      tr("trayAbout"),
      [] { show_about_dialog(Launcher::instance().window); }));
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
  if (launcher.hotkey_fix != nullptr) {
    gtk_widget_set_visible(GTK_WIDGET(launcher.hotkey_fix), TRUE);
  }
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
        launcher.scroll_to_selection();
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
  auto& launcher = Launcher::instance();
  launcher.cancel_focus_loss();
  if (gtk_window_is_active(gtk_window)) {
    launcher.activated_since_show = true;
    gtk_widget_grab_focus(GTK_WIDGET(launcher.search));
    return;
  }
  if (!gtk_widget_get_visible(GTK_WIDGET(gtk_window)) ||
      !launcher.activated_since_show) return;
  // Allow focus handoffs to settle before dismissing the launcher.
  launcher.focus_loss_source = g_timeout_add(150, [](gpointer) -> gboolean {
    auto& launcher = Launcher::instance();
    if (gtk_widget_get_visible(GTK_WIDGET(launcher.window)) &&
        !gtk_window_is_active(launcher.window)) {
      // Window-manager moves can temporarily take focus while a button is held.
      auto* display = gtk_widget_get_display(GTK_WIDGET(launcher.window));
      auto* seat = gdk_display_get_default_seat(display);
      auto* pointer = seat != nullptr ? gdk_seat_get_pointer(seat) : nullptr;
      GdkModifierType modifiers = GdkModifierType(0);
      if (pointer != nullptr) {
        gdk_surface_get_device_position(
            gtk_native_get_surface(GTK_NATIVE(launcher.window)), pointer,
            nullptr, nullptr, &modifiers);
      }
      if ((modifiers & (GDK_BUTTON1_MASK | GDK_BUTTON2_MASK | GDK_BUTTON3_MASK)) != 0)
        return G_SOURCE_CONTINUE;
      auto* windows = gtk_window_get_toplevels();
      for (guint i = 0; i < g_list_model_get_n_items(windows); ++i) {
        auto* candidate = GTK_WINDOW(g_list_model_get_item(windows, i));
        bool owned_active = false;
        if (gtk_window_is_active(candidate)) {
          for (auto* parent = gtk_window_get_transient_for(candidate);
               parent != nullptr; parent = gtk_window_get_transient_for(parent)) {
            if (parent == launcher.window) owned_active = true;
          }
        }
        g_object_unref(candidate);
        // Recheck when a launcher-owned dialog loses focus as well.
        if (owned_active) return G_SOURCE_CONTINUE;
      }
      launcher.focus_loss_source = 0;
      launcher.hide();
    }
    launcher.focus_loss_source = 0;
    return G_SOURCE_REMOVE;
  }, nullptr);
}

void on_activate(GtkApplication* app, gpointer) {
  Launcher& launcher = Launcher::instance();
  launcher.app = app;  // tray quit routes through GApplication's shutdown
  GActionEntry actions[3]{};
  actions[0].name = "restart";
  actions[0].activate = [](GSimpleAction*, GVariant*, gpointer) { request_restart(); };
  actions[1].name = "quit";
  actions[1].activate = [](GSimpleAction*, GVariant*, gpointer) { tray_quit(); };
  actions[2].name = "fix-hotkey";
  actions[2].activate = [](GSimpleAction*, GVariant*, gpointer) { tray_fix_hotkey(); };
  g_action_map_add_action_entries(G_ACTION_MAP(app), actions, 3, nullptr);

  // The panel hides on focus loss; without a hold, GTK would treat the
  // hidden window as "last window closed" and shut the whole app down.
  g_application_hold(G_APPLICATION(app));

  auto* window = gtk_application_window_new(app);
  launcher.window = GTK_WINDOW(window);
  gtk_window_set_title(launcher.window, "Fulcrum");
  gtk_window_set_default_size(launcher.window, 680, 460);
  gtk_window_set_resizable(launcher.window, FALSE);
  // Chromeless like the other hosts: the panel content IS the window, and
  // the stylesheet rounds it. Close still hides (below) via Esc / the tray.
  gtk_window_set_decorated(launcher.window, FALSE);
  apply_panel_css();
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
  gtk_accessible_update_property(GTK_ACCESSIBLE(search),
                                 GTK_ACCESSIBLE_PROPERTY_LABEL,
                                 "FulcrumQuery", -1);
  gtk_widget_set_margin_top(search, 10);
  gtk_widget_set_margin_start(search, 10);
  gtk_widget_set_margin_end(search, 10);
  launcher.search = GTK_SEARCH_ENTRY(search);
  gtk_widget_set_hexpand(search, TRUE);
  auto* search_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  gtk_box_append(GTK_BOX(search_row), search);

  auto* status = gtk_label_new("Starting embedded Racket CS…");
  gtk_label_set_xalign(GTK_LABEL(status), 0.0);
  gtk_label_set_selectable(GTK_LABEL(status), TRUE);
  gtk_widget_set_margin_start(status, 12);
  gtk_widget_set_margin_top(status, 6);
  launcher.status = GTK_LABEL(status);

  auto* hotkey_fix = gtk_button_new_with_label(tr("trayFixHotkey").c_str());
  gtk_widget_set_visible(hotkey_fix, FALSE);
  gtk_widget_set_halign(hotkey_fix, GTK_ALIGN_START);
  gtk_widget_set_margin_start(hotkey_fix, 12);
  gtk_widget_set_margin_top(hotkey_fix, 4);
  g_signal_connect(hotkey_fix, "clicked",
                   G_CALLBACK(+[](GtkButton*, gpointer) { tray_fix_hotkey(); }),
                   nullptr);
  launcher.hotkey_fix = GTK_BUTTON(hotkey_fix);

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
  gtk_widget_set_vexpand(scrolled, TRUE);
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                 GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  auto* results = gtk_list_box_new();
  gtk_list_box_set_selection_mode(GTK_LIST_BOX(results), GTK_SELECTION_SINGLE);
  gtk_list_box_set_activate_on_single_click(GTK_LIST_BOX(results), FALSE);
  launcher.results = GTK_LIST_BOX(results);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), results);

  auto* hint = gtk_label_new("↑↓ navigate · ↵ run · esc hide — Fulcrum");
  launcher.navigation_hint = GTK_LABEL(hint);
  gtk_label_set_xalign(GTK_LABEL(hint), 0.0);
  gtk_widget_add_css_class(hint, "caption");
  gtk_widget_add_css_class(hint, "dim-label");
  gtk_widget_set_margin_start(hint, 12);
  gtk_widget_set_margin_top(hint, 4);
  gtk_widget_set_margin_bottom(hint, 8);

  gtk_box_append(GTK_BOX(root), search_row);
  gtk_box_append(GTK_BOX(root), status);
  gtk_box_append(GTK_BOX(root), hotkey_fix);
  gtk_box_append(GTK_BOX(root), ai_panel);
  gtk_box_append(GTK_BOX(root), detail_panel);
  gtk_box_append(GTK_BOX(root), scrolled);
  gtk_box_append(GTK_BOX(root), hint);
  gtk_window_set_child(launcher.window, root);
  set_i18n_language(g_i18n_active.load() == 0 ? "zh" : "en");

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
  // Wayland must use the portal. On X11 the native grab is authoritative:
  // stock Ubuntu exposes the portal even when its GlobalShortcuts backend
  // cannot bind, which previously made the tested X11 fallback unreachable.
  if (!GDK_IS_X11_DISPLAY(gtk_widget_get_display(window)) &&
      rivet::system::GlobalShortcuts::available()) {
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
                  "Hotkey permission was dismissed. Reopen Fulcrum and allow "
                  "the shortcut, or bind `fulcrum --toggle` in Settings.");
              check_hotkey_shadowing("Alt+Space");
              g_idle_add(show_on_main, nullptr);
              break;
            case rivet::system::GlobalShortcutBindStatus::failed:
              Launcher::post_status(
                  "Portal hotkey failed: " + result.message +
                  ". Bind `fulcrum --toggle` in desktop Settings.");
              check_hotkey_shadowing("Alt+Space");
              g_idle_add(show_on_main, nullptr);
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
    std::string hotkey_note = install_x11_hotkey(gtk_widget_get_display(window));
    if (!hotkey_note.empty()) {
      launcher.set_status(hotkey_note);
    }
    launcher.start_backend();
  }
  // Open on launch. A launcher that starts hidden is an invisible app on
  // every session where the summon path is not yet alive — Wayland before
  // the portal consent is granted, after a reboot, a rejected grab. The
  // panel is one Esc (or focus loss) away from hidden again.
  char const* acceptance_hotkey = std::getenv("FULCRUM_ACCEPTANCE_HOTKEY");
  if (acceptance_hotkey != nullptr && std::string(acceptance_hotkey) == "1") {
    // Product acceptance drives the same main-loop activation handoff used by
    // portal/X11 callbacks. Starting hidden makes this a real summon test;
    // the delay lets AT-SPI attach before the panel is presented.
    launcher.hide();
    g_timeout_add(400, [](gpointer) -> gboolean {
      activate_on_main(nullptr);
      return G_SOURCE_REMOVE;
    }, nullptr);
  } else {
    launcher.show();
  }

  // The tray rides last: menus render with the i18n table loaded in main,
  // and the language arrival re-composes them (apply_tray_language).
  build_tray();
}

void on_shutdown(GApplication*, gpointer) {
  Launcher::instance().cancel_focus_loss();
  g_x11_hotkey.stop();
  Launcher::instance().stop_backend();
}

}  // namespace

int run_application() {
  // The first-party rivet lease replaces the old pid-file + SIGUSR1 scheme:
  // second launches forward --toggle to the primary and exit.
  char const* isolated_id = std::getenv("FULCRUM_INSTANCE_ID");
  std::string const application_id =
      isolated_id != nullptr && *isolated_id != '\0'
          ? isolated_id
          : "site.jrtx.fulcrum";
  rivet::system::SingleInstanceLease lease(application_id);
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

int main(int, char**) {
  std::string const executable = executable_path().string();
  int const status = run_application();
  // Release the single-instance lease and stop the backend before re-exec.
  if (g_restart_requested) {
    execl(executable.c_str(), executable.c_str(), static_cast<char*>(nullptr));
    std::cerr << "fulcrum: restart failed: " << g_strerror(errno) << '\n';
    return 1;
  }
  return status;
}
