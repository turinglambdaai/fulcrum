#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif
#include "GeneratedBackend.hpp"
#include "GeneratedI18n.hpp"
#include "SettingsWindow.xaml.h"
#include "WindowCommands.h"

#include <shellapi.h>
#include <commctrl.h>
#pragma comment(lib, "comctl32.lib")

#include <fstream>
#include <iterator>
#include <map>
#include <optional>

namespace winrt::RivetHost::implementation {
namespace {

constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 0xF11D;
constexpr int kTrayMenuOpen = 1;
constexpr int kTrayMenuAbout = 2;
constexpr int kTrayMenuQuit = 3;
constexpr int kTrayMenuSettings = 4;
constexpr int kTrayMenuUpdates = 5;

constexpr int kHotkeyIdPrimary = 0xF11C;  // Alt+Space
constexpr int kHotkeyIdFallback = 0xF11D; // Ctrl+Alt+Space
constexpr int kWindowWidth = 680;
constexpr int kWindowHeight = 460;

bool is_acceptance_run() {
  wchar_t value[8]{};
  auto const length =
      ::GetEnvironmentVariableW(L"FULCRUM_ACCEPTANCE", value, 8);
  return length == 1 && value[0] == L'1';
}

std::filesystem::path executable_path() {
  std::wstring buffer(32768, L'\0');
  auto const length = ::GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  if (length == 0 || length == buffer.size()) {
    throw std::runtime_error("GetModuleFileNameW failed");
  }
  buffer.resize(length);
  return std::filesystem::path(buffer);
}

std::string utf8(std::filesystem::path const& path) {
  auto const wide = path.wstring();
  if (wide.empty()) {
    return {};
  }
  auto const size = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                          wide.data(),
                                          static_cast<int>(wide.size()),
                                          nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  std::string result(static_cast<std::size_t>(size), '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                            wide.data(), static_cast<int>(wide.size()),
                            result.data(), size, nullptr, nullptr) != size) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  return result;
}

std::string to_utf8(std::wstring const& wide) {
  if (wide.empty()) return {};
  auto const size = ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                          static_cast<int>(wide.size()),
                                          nullptr, 0, nullptr, nullptr);
  std::string result(static_cast<std::size_t>(size > 0 ? size : 0), '\0');
  if (size > 0) {
    ::WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                          result.data(), size, nullptr, nullptr);
  }
  return result;
}

std::wstring to_wide(std::string const& utf8_text) {
  if (utf8_text.empty()) return {};
  auto const size = ::MultiByteToWideChar(CP_UTF8, 0, utf8_text.data(),
                                          static_cast<int>(utf8_text.size()),
                                          nullptr, 0);
  std::wstring result(static_cast<std::size_t>(size > 0 ? size : 0), L'\0');
  if (size > 0) {
    ::MultiByteToWideChar(CP_UTF8, 0, utf8_text.data(),
                          static_cast<int>(utf8_text.size()),
                          result.data(), size);
  }
  return result;
}

// file:///C:/Users/a%20b → C:\Users\a b. The backend hands out file://
// URIs so every host can shell-open them; the "open" verb wants the path.
std::wstring uri_path_to_windows_path(std::wstring const& uri) {
  std::wstring path = uri.substr(8);  // past "file:///"
  auto const query = path.find(L'?');
  if (query != std::wstring::npos) path = path.substr(0, query);
  auto const fragment = path.find(L'#');
  if (fragment != std::wstring::npos) path = path.substr(0, fragment);
  std::wstring out;
  out.reserve(path.size());
  for (std::size_t i = 0; i < path.size(); ++i) {
    if (path[i] == L'%' && i + 2 < path.size()) {
      auto const hex = [](wchar_t c) -> int {
        if (c >= L'0' && c <= L'9') return c - L'0';
        if (c >= L'a' && c <= L'f') return c - L'a' + 10;
        if (c >= L'A' && c <= L'F') return c - L'A' + 10;
        return -1;
      };
      int const hi = hex(path[i + 1]);
      int const lo = hex(path[i + 2]);
      if (hi >= 0 && lo >= 0) {
        out.push_back(static_cast<wchar_t>((hi << 4) | lo));
        i += 2;
        continue;
      }
    }
    out.push_back(path[i] == L'/' ? L'\\' : path[i]);
  }
  return out;
}

rivet::windows::RacketRuntimeConfig runtime_config() {
  auto const exe = executable_path();
  auto const root = exe.parent_path();
  auto const runtime = root / L"runtime";

  rivet::windows::RacketRuntimeConfig config;
  config.executable_path = utf8(exe);
  config.petite_boot = utf8(runtime / L"petite.boot");
  config.scheme_boot = utf8(runtime / L"scheme.boot");
  config.racket_boot = utf8(runtime / L"racket.boot");
  config.backend_bundle = utf8(root / L"res" / L"core.zo");
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;
  config.dll_dir = runtime.wstring();
  return config;
}

// ---- result row visuals -----------------------------------------------------
//
// Rows are built in code rather than a XAML data template: the row contract
// carries icon/badge/hint fields a plain string item cannot express, and a
// code-built visual tree needs no IDL-registered row type. Visual grammar
// matches the macOS host: amber (#D97706) icon tiles and chips, an inset
// rounded selection (App.xaml theme overrides paint it), and the ↵ chip
// only on the selected row.

constexpr BYTE kAmberRed = 0xD9;
constexpr BYTE kAmberGreen = 0x77;
constexpr BYTE kAmberBlue = 0x06;

winrt::Windows::UI::Color amber_color(BYTE alpha) {
  return winrt::Windows::UI::Color{alpha, kAmberRed, kAmberGreen, kAmberBlue};
}

// Segoe Fluent Icons codepoints (the FontIcon default font family).
wchar_t const* row_glyph(rivet_app::ResultRow const& row) {
  if (row.kind == "Calculator") return L"\uE8EF";  // Calculator
  if (row.kind == "Clipboard") return L"\uE77F";   // Paste
  if (row.kind == "Snippet") return L"\uE70F";     // Edit
  if (row.kind == "Quicklink") return L"\uE71B";   // Link
  if (row.kind == "Web Search") return L"\uE774";  // World
  if (row.kind == "Plugin") return L"\uE71D";      // AllApps
  if (row.kind == "System") {
    return row.id == "sys.lock" ? L"\uE72E" : L"\uE713";  // Lock / Settings
  }
  if (row.kind == "Setting") return L"\uE713";         // Settings
  if (row.kind == "Window") return L"\uE739";          // BackToWindow
  if (row.kind == "Update") return L"\uE74E";          // Download
  if (row.kind == "AI") return L"\uE945";              // LightningBolt
  if (row.kind == "File") return L"\uE8A5";            // Document
  return L"\uE721";                                    // Search
}

winrt::Microsoft::UI::Xaml::Controls::Border make_chip(
    std::wstring const& text, float font_size) {
  namespace mx = winrt::Microsoft::UI::Xaml;
  namespace mxc = winrt::Microsoft::UI::Xaml::Controls;
  namespace wum = winrt::Microsoft::UI::Xaml::Media;

  mxc::TextBlock label;
  label.Text(text);
  label.FontSize(font_size);
  label.Foreground(wum::SolidColorBrush{amber_color(0xFF)});
  label.VerticalAlignment(mx::VerticalAlignment::Center);

  mxc::Border chip;
  chip.Background(wum::SolidColorBrush{amber_color(0x24)});
  chip.CornerRadius({10, 10, 10, 10});
  chip.Padding({7, 1, 7, 2});
  chip.VerticalAlignment(mx::VerticalAlignment::Center);
  chip.Child(label);
  return chip;
}

struct RowContent {
  winrt::Microsoft::UI::Xaml::Controls::Grid root{nullptr};
  winrt::Microsoft::UI::Xaml::Controls::Border enter_chip{nullptr};
};

RowContent build_row_content(rivet_app::ResultRow const& row) {
  namespace mx = winrt::Microsoft::UI::Xaml;
  namespace mxc = winrt::Microsoft::UI::Xaml::Controls;
  namespace wum = winrt::Microsoft::UI::Xaml::Media;

  mxc::Grid root;
  root.Margin({12, 7, 12, 7});

  std::array<mx::GridLength, 4> const widths = {
      mx::GridLengthHelper::Auto(),
      mx::GridLengthHelper::FromValueAndType(1, mx::GridUnitType::Star),
      mx::GridLengthHelper::Auto(),
      mx::GridLengthHelper::Auto()};
  for (auto const& width : widths) {
    mxc::ColumnDefinition column;
    column.Width(width);
    root.ColumnDefinitions().Append(column);
  }

  // Icon tile: fixed 28pt amber-tinted square, glyph centered.
  mxc::FontIcon icon;
  icon.Glyph(row_glyph(row));
  icon.FontSize(14);
  mxc::Border icon_tile;
  icon_tile.Width(28);
  icon_tile.Height(28);
  icon_tile.CornerRadius({6, 6, 6, 6});
  icon_tile.Background(wum::SolidColorBrush{amber_color(0x1F)});
  icon_tile.Padding({6, 6, 6, 6});
  icon_tile.Child(icon);
  icon_tile.VerticalAlignment(mx::VerticalAlignment::Center);
  mx::Controls::Grid::SetColumn(icon_tile, 0);
  root.Children().Append(icon_tile);

  // Title + muted subtitle stacked.
  auto const& subtitle = row.subtitle.empty() ? row.kind : row.subtitle;
  mxc::TextBlock title;
  title.Text(to_wide(row.title));
  title.FontSize(13.5);
  title.FontWeight({600});
  title.TextTrimming(mx::TextTrimming::CharacterEllipsis);
  title.MaxLines(1);
  mxc::TextBlock subtitle_label;
  subtitle_label.Text(to_wide(subtitle));
  subtitle_label.FontSize(11.5);
  subtitle_label.Opacity(0.6);
  subtitle_label.TextTrimming(mx::TextTrimming::CharacterEllipsis);
  subtitle_label.MaxLines(1);
  mxc::StackPanel texts;
  texts.Spacing(2);
  texts.VerticalAlignment(mx::VerticalAlignment::Center);
  texts.Margin({10, 0, 8, 0});
  texts.Children().Append(title);
  texts.Children().Append(subtitle_label);
  mx::Controls::Grid::SetColumn(texts, 1);
  root.Children().Append(texts);

  if (!row.badge.empty()) {
    auto badge = make_chip(to_wide(row.badge), 10);
    badge.Margin({0, 0, 8, 0});
    mx::Controls::Grid::SetColumn(badge, 2);
    root.Children().Append(badge);
  }

  // ↵ affordance: only the selected row shows it (UpdateEnterChips).
  auto enter_chip = make_chip(L"\u21B5", 11);
  enter_chip.Visibility(mx::Visibility::Collapsed);
  mx::Controls::Grid::SetColumn(enter_chip, 3);
  root.Children().Append(enter_chip);

  return {root, enter_chip};
}

// ---- hotkey grammar -------------------------------------------------------
//
// One spec shared with the backend (settings.rkt) and the other hosts:
// modifiers alt/ctrl/shift/cmd/win/super, then space | a-z | 0-9 |
// f1-f12 | comma | period | minus | equal | tab.

struct HotkeyBinding {
  UINT mods{0};
  UINT vk{0};
};

bool parse_hotkey(std::string const& spec, HotkeyBinding& out) {
  UINT mods = 0;
  bool has_key = false;
  std::string key;
  std::string lowered = spec;
  std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                 [](unsigned char c) { return static_cast<char>(::tolower(c)); });
  std::size_t start = 0;
  while (start <= lowered.size()) {
    std::size_t plus = lowered.find('+', start);
    std::string token = lowered.substr(
        start, plus == std::string::npos ? std::string::npos : plus - start);
    if (token.empty()) {
      return false;
    }
    if (token == "alt" || token == "option") {
      mods |= MOD_ALT;
    } else if (token == "ctrl" || token == "control") {
      mods |= MOD_CONTROL;
    } else if (token == "shift") {
      mods |= MOD_SHIFT;
    } else if (token == "cmd" || token == "win" || token == "super") {
      mods |= MOD_WIN;
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
  UINT vk = 0;
  if (key == "space") {
    vk = VK_SPACE;
  } else if (key == "tab") {
    vk = VK_TAB;
  } else if (key == "comma") {
    vk = VK_OEM_COMMA;
  } else if (key == "period") {
    vk = VK_OEM_PERIOD;
  } else if (key == "minus") {
    vk = VK_OEM_MINUS;
  } else if (key == "equal") {
    vk = VK_OEM_PLUS;
  } else if (key.size() == 1 && key[0] >= 'a' && key[0] <= 'z') {
    vk = 'A' + static_cast<UINT>(key[0] - 'a');
  } else if (key.size() == 1 && key[0] >= '0' && key[0] <= '9') {
    vk = '0' + static_cast<UINT>(key[0] - '0');
  } else if (key.size() >= 2 && key[0] == 'f' &&
             key.find_first_not_of("0123456789", 1) == std::string::npos) {
    int n = std::atoi(key.c_str() + 1);
    if (n < 1 || n > 12) {
      return false;
    }
    vk = VK_F1 + static_cast<UINT>(n - 1);
  } else {
    return false;
  }
  out.mods = mods;
  out.vk = vk;
  return true;
}

// ---- i18n (about + update surface) -----------------------------------------
//
// Host-wide UI strings for the about dialog and the update flow, keyed
// exactly like shared/i18n/*.json — the single source of truth shared with
// the macOS host (I18nService) and the Linux host. The files are flat
// one-key-per-line JSON objects, so a line-based parser is enough.
// rivet.rktd declares shared/i18n under `resources`, so packages carry it at
// <dir>/app/shared/i18n; the embedded fallback table below keeps the same
// keys for runs where nothing is staged. Lookup: active language → the
// other language → the key itself. The active language follows the
// backend's `language` setting, read once in PullHostSettings — a change
// applies on the next launch, matching this host's one-shot settings pull.
using I18nTable = std::map<std::string, std::wstring>;

struct I18nEntry {
  char const* key;
  char const* zh;
  char const* en;
};

// Only the keys this host renders. The staged JSON (or the mac host's copy
// of the same table) carries the rest of the about/update surface.
constexpr I18nEntry kI18nFallback[] = {
    {"updateAvailableStatus", "发现新版本：Fulcrum v{0} — 输入 “update” 下载",
     "Update available: Fulcrum v{0} — type \"update\" to download"},
    {"updateDownloadedStatusWin",
     "更新已下载 — 输入 “update” 安装并自动重启到新版本",
     "Update downloaded — type \"update\" to install and relaunch"},
    {"updateDownloadFailed", "更新下载失败：{0}",
     "Update download failed: {0}"},
    {"updateUnknownError", "未知错误", "unknown error"},
    {"updateUpToDate", "已是最新版本", "Fulcrum is up to date"},
    {"updateDownloadPercent", "正在下载更新… {0}%",
     "Downloading update… {0}%"},
    {"updateClose", "关闭", "Close"},
    {"aboutContent",
     "一键即达 — 应用、剪贴板、片段、窗口管理与 BYOK AI，尽在一个面板",
     "One keystroke, everything within reach — apps, clipboard, snippets, "
     "window management and BYOK AI in one panel"},
    {"aboutLicense", "以 Business Source License 1.1 授权发布",
     "Released under the Business Source License 1.1"},
    {"aboutWebsite", "访问官网", "Website"},
    {"aboutReportIssue", "问题反馈", "Report an Issue"},
};

I18nTable g_i18n[2];    // 0 = zh, 1 = en
int g_i18n_active = 1;  // "en" until PullHostSettings reports the choice

// Index of the closing quote for the JSON string starting at `start`
// (which points at '"'), honoring backslash escapes.
std::size_t i18n_string_end(std::wstring const& line, std::size_t start) {
  for (std::size_t i = start + 1; i < line.size(); ++i) {
    if (line[i] == L'\\') {
      ++i;
      continue;
    }
    if (line[i] == L'"') {
      return i;
    }
  }
  return std::wstring::npos;
}

std::wstring i18n_unescape(std::wstring const& raw) {
  std::wstring out;
  out.reserve(raw.size());
  for (std::size_t i = 0; i < raw.size(); ++i) {
    if (raw[i] != L'\\') {
      out.push_back(raw[i]);
      continue;
    }
    if (++i >= raw.size()) {
      break;
    }
    switch (raw[i]) {
      case L'"': out.push_back(L'"'); break;
      case L'\\': out.push_back(L'\\'); break;
      case L'/': out.push_back(L'/'); break;
      case L'n': out.push_back(L'\n'); break;
      case L't': out.push_back(L'\t'); break;
      case L'r': out.push_back(L'\r'); break;
      case L'b': out.push_back(L'\b'); break;
      case L'f': out.push_back(L'\f'); break;
      case L'u': {
        if (i + 4 >= raw.size()) {
          i = raw.size();
          break;
        }
        unsigned int code = 0;
        bool valid = true;
        for (int digit = 1; digit <= 4; ++digit) {
          wchar_t const h = raw[i + digit];
          code <<= 4;
          if (h >= L'0' && h <= L'9') {
            code += static_cast<unsigned int>(h - L'0');
          } else if (h >= L'a' && h <= L'f') {
            code += static_cast<unsigned int>(h - L'a') + 10;
          } else if (h >= L'A' && h <= L'F') {
            code += static_cast<unsigned int>(h - L'A') + 10;
          } else {
            valid = false;
            break;
          }
        }
        if (!valid) {
          i = raw.size();
          break;
        }
        i += 4;
        // Consecutive \uXXXX escapes concatenate into (surrogate) pairs.
        out.push_back(static_cast<wchar_t>(code));
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
bool load_i18n_file(std::filesystem::path const& path, int lang) {
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
  auto const size = ::MultiByteToWideChar(CP_UTF8, 0, bytes.data(),
                                          static_cast<int>(bytes.size()),
                                          nullptr, 0);
  if (size <= 0) {
    return false;
  }
  std::wstring text(static_cast<std::size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, bytes.data(), static_cast<int>(bytes.size()),
                        text.data(), size);

  auto& table = g_i18n[lang];
  bool loaded_any = false;
  std::size_t begin = 0;
  while (begin < text.size()) {
    auto end = text.find(L'\n', begin);
    if (end == std::wstring::npos) {
      end = text.size();
    }
    auto line = text.substr(begin, end - begin);
    begin = end + 1;
    if (!line.empty() && line.back() == L'\r') {
      line.pop_back();
    }

    auto const key_start = line.find(L'"');
    if (key_start == std::wstring::npos) {
      continue;
    }
    auto const key_end = i18n_string_end(line, key_start);
    if (key_end == std::wstring::npos) {
      continue;
    }
    auto const colon = line.find(L':', key_end);
    if (colon == std::wstring::npos) {
      continue;
    }
    auto const value_start = line.find(L'"', colon + 1);
    if (value_start == std::wstring::npos) {
      continue;
    }
    auto const value_end = i18n_string_end(line, value_start);
    if (value_end == std::wstring::npos) {
      continue;
    }
    table[to_utf8(line.substr(key_start + 1, key_end - key_start - 1))] =
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
                    to_wide(std::string(lang == 0 ? entry.zh : entry.en)));
    }
    // Keep the older minimal literals as a bootstrap safety net; generated
    // entries win because emplace never overwrites an existing key.
    for (auto const& entry : kI18nFallback) {
      table.emplace(entry.key, to_wide(lang == 0 ? entry.zh : entry.en));
    }
    // Staged product resources: rivet.rktd declares shared/i18n under
    // `resources`, so packages carry it at <dir>/app/shared/i18n; the dev
    // tree wins for `raco rivet dev` runs where nothing is packaged yet
    // (.rivet/stage holds the host binary one level below the repo root).
    std::filesystem::path const candidates[] = {
        exe_dir / L"app" / L"shared" / L"i18n",
        exe_dir / L".." / L"shared" / L"i18n",  // dev tree
    };
    for (auto const& dir : candidates) {
      auto const path = dir / names[lang];
      std::error_code ec;
      if (!std::filesystem::exists(path, ec)) {
        continue;
      }
      if (load_i18n_file(path, lang)) {
        break;
      }
    }
  }
}

void set_i18n_language(std::string const& lang) {
  g_i18n_active = (lang == "en") ? 1 : 0;
}

std::wstring t(char const* key) {
  std::string const needle(key);
  for (int attempt = 0; attempt < 2; ++attempt) {
    auto const& table = g_i18n[(g_i18n_active + attempt) % 2];
    auto const it = table.find(needle);
    if (it != table.end()) {
      return it->second;
    }
  }
  return to_wide(key);
}

// Positional formatting: first argument replaces {0}, and so on.
std::wstring t_format(char const* key, std::vector<std::wstring> const& args) {
  std::wstring out = t(key);
  for (std::size_t i = 0; i < args.size(); ++i) {
    std::wstring const token = L"{" + std::to_wstring(i) + L"}";
    auto const pos = out.find(token);
    if (pos != std::wstring::npos) {
      out.replace(pos, token.size(), args[i]);
    }
  }
  return out;
}

}  // namespace

MainWindow::MainWindow() {
  InitializeComponent();
  Title(L"Fulcrum");
  // i18n tables before any UI string is composed: the staged shared/i18n
  // JSON when packaged, the embedded fallback otherwise.
  load_i18n(executable_path().parent_path());
  ApplyLanguage();
  InitializeBackendAsync();
}

winrt::fire_and_forget MainWindow::InitializeBackendAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = std::make_shared<rivet::windows::Backend>(runtime_config());

  try {
    // Booting the embedded runtime can block on file I/O, so only startup is
    // moved off the UI thread. RPC traffic below is completion-driven.
    co_await winrt::resume_background();
    backend->start();

    // Backend Events arrive on the reader thread; dispatch before touching
    // UI objects or OS clipboard state.
    backend->set_event_handler([dispatcher, weak](std::string const& name,
                                                  rivet::Value const& value) {
      // Shared-state pushes arrive as reserved "$state" events carrying
      // [state-name, wire-value]; decode on the reader thread, dispatch
      // the effect.
      if (name == "$state") {
        auto const* fields = std::get_if<rivet::Value::List>(&value.data);
        if (fields == nullptr || fields->size() != 2) {
          return;
        }
        auto const* state_name =
            std::get_if<std::string>(&(fields->at(0).data));
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
          dispatcher.TryEnqueue([weak, stream]() mutable {
            if (auto window = weak.get()) {
              window->ApplyAiStream(stream);
            }
          });
        } else if (*state_name == "theme") {
          if (auto const* theme = std::get_if<std::string>(&(fields->at(1).data))) {
            std::string value_copy = *theme;
            dispatcher.TryEnqueue([weak, value_copy]() mutable {
              if (auto window = weak.get()) {
                window->ApplyTheme(value_copy);
              }
            });
          }
        } else if (*state_name == "hotkey") {
          if (auto const* spec = std::get_if<std::string>(&(fields->at(1).data))) {
            std::string spec_copy = *spec;
            dispatcher.TryEnqueue([weak, spec_copy]() mutable {
              if (auto window = weak.get()) {
                // Rebinding needs the HWND; the subclass route reads it the
                // same way FinishNativeSetup does.
                if (HWND hwnd = ::FindWindowW(nullptr, L"Fulcrum")) {
                  window->ApplyHotkey(spec_copy);
                }
              }
            });
          }
        } else if (*state_name == "language") {
          if (auto const* language =
                  std::get_if<std::string>(&(fields->at(1).data))) {
            std::string value_copy = *language;
            dispatcher.TryEnqueue([weak, value_copy]() mutable {
              if (auto window = weak.get()) {
                set_i18n_language(value_copy);
                window->ApplyLanguage();
              }
            });
          }
        } else if (*state_name == "search-revision") {
          dispatcher.TryEnqueue([weak]() mutable {
            if (auto window = weak.get()) {
              window->RefreshForRevision();
            }
          });
        }
        return;
      }

      // Event values are bare strings per the backend contract: RVT1 event
      // frames arrive as [name, value] and the runtime hands us value.
      std::string payload;
      if (auto const text = std::get_if<std::string>(&value.data)) {
        payload = *text;
      }
      dispatcher.TryEnqueue([weak, name, payload]() mutable {
        if (auto window = weak.get()) {
          if (name == "copy-to-clipboard") {
            window->WriteClipboardText(to_wide(payload));
            window->HideLauncher();
          } else if (name == "paste-to-frontmost") {
            window->PasteToFrontmost(to_wide(payload));
          } else if (name == "ai-finished") {
            // The answer lands on the clipboard, but the panel stays: the
            // user is reading the streamed text right now.
            window->WriteClipboardText(to_wide(payload));
            window->SetStatusOk(L"Answer copied to the clipboard");
          } else if (name == "open-url") {
            std::wstring target = to_wide(payload);
            // The backend hands out file:// URIs so every host can shell-open
            // them; Explorer's shell verb wants the plain path back.
            if (target.rfind(L"file:///", 0) == 0) {
              target = uri_path_to_windows_path(target);
            }
            ::ShellExecuteW(nullptr, L"open", target.c_str(), nullptr, nullptr,
                            SW_SHOWNORMAL);
            window->HideLauncher();
          } else if (name == "update-available") {
            window->SetStatusOk(to_wide(payload));
          }
        }
      });
    });

    dispatcher.TryEnqueue([weak, backend = std::move(backend)]() mutable {
      if (auto window = weak.get()) {
        window->backend_ = std::move(backend);
        window->api_ = std::make_unique<rivet_app::API>(*window->backend_);
        window->SetStatusOk(t("readyStatus"));
        window->FinishNativeSetup();
        try {
          rivet::update::MsiHandoff::CleanupStaleAttempts(L"site.jrtx.fulcrum");
          if (auto failure =
                  rivet::update::MsiHandoff::ConsumeFailure(L"site.jrtx.fulcrum")) {
            window->SetStatusError(L"Update install failed: " + failure->message);
          }
        } catch (...) {
          // Updater housekeeping must never prevent the launcher from starting.
        }
        window->SearchAsync(L"");
        window->StartSilentUpdateCheck();
        window->PullHostSettings();
        window->RefreshExpansionData();
      } else {
        // Never destroy the last Backend reference on its own reader thread.
        std::thread([backend = std::move(backend)]() mutable {
          backend->stop();
        }).detach();
      }
    });
  } catch (std::exception const& e) {
    auto message = std::string(e.what());
    dispatcher.TryEnqueue([weak, message = std::move(message)] {
      if (auto window = weak.get()) {
        window->SetStatusError(to_wide(message));
      }
    });
  }
}

// ---- snippet auto-expansion (WH_KEYBOARD_LL) ------------------------------
//
// The hook observes keystrokes system-wide; when a snippet keyword lands
// against a word boundary, the keyword is erased with backspaces and the
// snippet text typed in its place via unicode key input. The repair runs
// from a posted message (never inside the hook — LL hooks must return
// fast, and SendInput inside a hook would re-enter it). Injections pass
// through expansion_ignore_ so the hook never processes its own keys.

constexpr UINT kExpansionRepairMessage = WM_APP + 4;

MainWindow* g_expansion_window = nullptr;  // set once at install

LRESULT CALLBACK expansion_hook_proc(int code, WPARAM wParam, LPARAM lParam) {
  if (code >= 0 && wParam == WM_KEYDOWN && g_expansion_window != nullptr &&
      !g_expansion_window->expansion_ignore_.load(std::memory_order_relaxed)) {
    auto const* info = reinterpret_cast<KBDLLHOOKSTRUCT*>(lParam);
    g_expansion_window->OnExpansionKey(info->vkCode);
  }
  return ::CallNextHookEx(nullptr, code, wParam, lParam);
}

void MainWindow::FinishNativeSetup() {
  // HWND lookup via the window title: Fulcrum is single-instance and owns
  // exactly one window with this title. This avoids depending on the
  // WindowsAppSDK interop surface, whose projection shape moved between
  // releases; the official interop call is the 0.2 follow-up.
  auto const hwnd = ::FindWindowW(nullptr, L"Fulcrum");

  // Frosted glass: the system Desktop Acrylic backdrop is the window's
  // surface (the root grid paints nothing). The macOS host's vibrancy is
  // the same design intent on its native stack. Chromeless: no title bar,
  // the panel content IS the window.
  try {
    SystemBackdrop(winrt::Microsoft::UI::Xaml::Media::DesktopAcrylicBackdrop());
    ExtendsContentIntoTitleBar(true);
    SetTitleBar(nullptr);
  } catch (...) {
    // A system backdrop or titlebar surface that fails to attach must not
    // take the launcher down; the window just stays opaque.
  }

  // The ↵ chip follows the list selection.
  ResultsList().SelectionChanged(
      [this](auto&&, auto&&) { UpdateEnterChips(); });

  // Overlay chrome: resizable off, not shown in taskbar/alt-tab, topmost,
  // positioned at the top quarter of the work area — all plain Win32 so we
  // do not depend on newer WindowsAppSDK windowing surfaces.
  if (auto appWindow = this->AppWindow()) {
    appWindow.IsShownInSwitchers(false);
    if (auto presenter = appWindow.Presenter().try_as<
            Microsoft::UI::Windowing::OverlappedPresenter>()) {
      presenter.IsResizable(false);
      presenter.IsMaximizable(false);
      presenter.IsMinimizable(false);
      // The macOS launcher panel ships with no close affordance at all
      // (.titled without .closable); dropping the border and titlebar is
      // the Windows equivalent — the caption X would otherwise sit in the
      // corner and end the whole process: tray, hotkey and all.
      presenter.SetBorderAndTitleBar(false, false);
    }
    // Alt+F4 and system close requests hide the panel instead of ending
    // the process — the Linux host made the same call for its WM close
    // button. Quitting lives in the tray menu, whose Destroy() bypasses
    // this handler.
    appWindow.Closing([this](auto&&, auto&& args) {
      args.Cancel(true);
      this->HideLauncher();
    });
  }
  RECT work{};
  ::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  int const width = work.right - work.left < kWindowWidth
                        ? work.right - work.left
                        : kWindowWidth;
  int const height = work.bottom - work.top < kWindowHeight
                         ? work.bottom - work.top
                         : kWindowHeight;
  int const x = work.left + ((work.right - work.left) - width) / 2;
  int const y = work.top + ((work.bottom - work.top) - height) / 4;
  if (hwnd != nullptr) {
    ::SetWindowPos(hwnd, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE);
  }

  // Bootstrap hotkey (Alt+Space, honest fallback) so the launcher works
  // before the backend answers; PullHostSettings re-binds from the stored
  // spec once the hotkey state arrives.
  ApplyHotkey("alt+space");

  // Window subclass for WM_HOTKEY and clipboard updates. Runs for the
  // window's lifetime; the OS reclaims the subclass with the window.
  SetWindowSubclass(hwnd,
                    [](HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam,
                       UINT_PTR, DWORD_PTR dwRefData) -> LRESULT {
                      auto* self = reinterpret_cast<MainWindow*>(dwRefData);
                      if (msg == WM_HOTKEY && self != nullptr &&
                          self->HandleHotkeyMessage(msg, wParam, lParam)) {
                        return 0;
                      }
                      if (msg == WM_CLIPBOARDUPDATE && self != nullptr) {
                        self->OnClipboardUpdate();
                      }
                      if (msg == kTrayCallbackMessage && self != nullptr) {
                        self->HandleTrayMessage(msg, static_cast<std::int64_t>(lParam),
                                                hWnd);
                      }
                      if (msg == kExpansionRepairMessage && self != nullptr) {
                        self->RepairExpansion(static_cast<std::size_t>(wParam));
                      }
                      if (msg == WM_NCHITTEST && self != nullptr) {
                        // The borderless panel has no titlebar to drag by,
                        // and the macOS panel stays movable through its
                        // transparent titlebar region — keep the Windows
                        // one movable the same way: the padding strip above
                        // the query box (16 DIP, QueryBox's top margin) is
                        // the caption. Everything else stays HTCLIENT so
                        // rows and the query box keep their clicks.
                        POINT point{
                            static_cast<LONG>(static_cast<short>(LOWORD(lParam))),
                            static_cast<LONG>(static_cast<short>(HIWORD(lParam)))};
                        if (::ScreenToClient(hWnd, &point) &&
                            point.y >= 0 &&
                            point.y < static_cast<LONG>(
                                          16 * ::GetDpiForWindow(hWnd) / 96)) {
                          return HTCAPTION;
                        }
                      }
                      return DefSubclassProc(hWnd, msg, wParam, lParam);
                    },
                    1,
                    reinterpret_cast<DWORD_PTR>(this));

  if (::AddClipboardFormatListener(hwnd)) {
    clipboard_listener_installed_ = true;
  }

  // Menu bar presence via the first-party tray surface: left click opens
  // the launcher, right click offers Open/Quit — the discoverable way in
  // when the hotkey is forgotten, and the only quit affordance.
  HICON tray_hicon = ::LoadIconW(::GetModuleHandleW(nullptr),
                                 MAKEINTRESOURCEW(1));
  if (tray_hicon == nullptr) {
    tray_hicon = ::LoadIconW(nullptr, IDI_APPLICATION);
  }
  tray_icon_ = std::make_unique<rivet::system::TrayIcon>(
      hwnd, kTrayIconId, kTrayCallbackMessage, L"Fulcrum", tray_hicon);

  AttachStatusBarCopyAffordance();
  InstallExpansionHook();

  // WinUI Window has no Deactivated event; the Activated state carries it.
  this->Activated([this](auto&&,
                         winrt::Microsoft::UI::Xaml::WindowActivatedEventArgs const& args) {
    if (args.WindowActivationState() ==
            winrt::Microsoft::UI::Xaml::WindowActivationState::Deactivated &&
        !is_acceptance_run()) {
      this->HideLauncher();
    }
  });
}

void MainWindow::HandleTrayMessage(std::uint32_t message, std::int64_t lParam,
                                   HWND hwnd) {
  if (message != kTrayCallbackMessage) {
    return;
  }
  switch (LOWORD(lParam)) {
    case WM_LBUTTONUP:
      if (AppWindow().IsVisible()) {
        HideLauncher();
      } else {
        ShowLauncher();
      }
      break;
    case WM_RBUTTONUP: {
      HMENU menu = ::CreatePopupMenu();
      if (menu != nullptr) {
        ::AppendMenuW(menu, MF_STRING, kTrayMenuOpen, t("trayOpen").c_str());
        ::AppendMenuW(menu, MF_STRING, kTrayMenuSettings, t("traySettings").c_str());
        ::AppendMenuW(menu, MF_STRING, kTrayMenuUpdates, t("trayCheckUpdates").c_str());
        ::AppendMenuW(menu, MF_STRING, kTrayMenuAbout, t("trayAbout").c_str());
        ::AppendMenuW(menu, MF_STRING, kTrayMenuQuit, t("trayQuit").c_str());
        ::SetForegroundWindow(hwnd);  // so outside clicks dismiss the menu
        int const choice = ::TrackPopupMenu(
            menu, TPM_RETURNCMD | TPM_NONOTIFY, 0, 0, 0, hwnd, nullptr);
        ::DestroyMenu(menu);
        if (choice == kTrayMenuOpen) {
          ShowLauncher();
        } else if (choice == kTrayMenuSettings) {
          ShowSettings();
        } else if (choice == kTrayMenuUpdates) {
          CheckForUpdates();
        } else if (choice == kTrayMenuAbout) {
          ShowAbout();
        } else if (choice == kTrayMenuQuit) {
          this->AppWindow().Destroy();
        }
      }
      break;
    }
    default:
      break;
  }
}

bool MainWindow::HandleHotkeyMessage(std::uint32_t, std::uint64_t wParam,
                                     std::int64_t) {
  if (wParam != kHotkeyIdPrimary && wParam != kHotkeyIdFallback) {
    return false;
  }
  if (this->AppWindow() && this->AppWindow().IsVisible()) {
    HideLauncher();
  } else {
    ShowLauncher();
  }
  return true;
}

void MainWindow::OnClipboardUpdate() {
  if (!clipboard_listener_installed_ || api_ == nullptr) {
    return;
  }
  if (!::OpenClipboard(nullptr)) {
    return;
  }
  std::wstring text;
  if (HANDLE handle = ::GetClipboardData(CF_UNICODETEXT)) {
    if (auto const* locked =
            static_cast<wchar_t const*>(::GlobalLock(handle))) {
      text.assign(locked);
      ::GlobalUnlock(handle);
    }
  }
  ::CloseClipboard();

  if (text.empty() || text == last_recorded_clipboard_) {
    return;
  }
  last_recorded_clipboard_ = text;
  // Fire-and-forget: persistence happens on the backend; the UI thread never
  // waits for it.
  api_->clipboard_record(to_utf8(text));
}

void MainWindow::ShowLauncher() {
  actions_mode_ = false;
  HintBar().Text(t("navigationHint"));
  DismissAiPanel();
  DismissDetailPanel();
  QueryBox().Text(L"");
  SearchAsync(std::wstring(L""));
  this->Activate();
  // The hotkey path runs in a WM_HOTKEY handler, which grants the
  // foreground right; claiming it explicitly also covers the tray-open
  // path and the first re-summon after AppWindow().Hide(), which WinUI
  // otherwise shows without bringing to the foreground.
  if (HWND hwnd = ::FindWindowW(nullptr, L"Fulcrum")) {
    ::SetForegroundWindow(hwnd);
  }
  // Focusing synchronously with the show races the activation: the caret
  // never appears and the first keystrokes land nowhere, so the user had
  // to click the panel before it accepted typing. Queue the focus for
  // after the activation tick settles.
  DispatcherQueue().TryEnqueue([this]() {
    QueryBox().Focus(winrt::Microsoft::UI::Xaml::FocusState::Programmatic);
  });
}

void MainWindow::HideLauncher() { this->AppWindow().Hide(); }

void MainWindow::ApplyLanguage() {
  QueryBox().PlaceholderText(t("searchPlaceholder"));
  HintBar().Text(actions_mode_ ? t("navigationHintActions")
                               : t("navigationHint"));
  DetailHeader().Text(t("detailTitle"));
  if (!api_) {
    StatusText().Text(t("startingStatus"));
    StatusBar().Message(t("startingStatus"));
  }
}

void MainWindow::WriteClipboardText(std::wstring const& text) {
  if (!::OpenClipboard(nullptr)) {
    return;
  }
  auto const bytes = (text.size() + 1) * sizeof(wchar_t);
  if (HANDLE handle = ::GlobalAlloc(GMEM_MOVEABLE, bytes)) {
    if (void* locked = ::GlobalLock(handle)) {
      memcpy(locked, text.c_str(), bytes);
      ::GlobalUnlock(handle);
      ::EmptyClipboard();
      if (::SetClipboardData(CF_UNICODETEXT, handle) == nullptr) {
        ::GlobalFree(handle);
      }
    } else {
      ::GlobalFree(handle);
    }
  }
  ::CloseClipboard();
}

void MainWindow::PasteToFrontmost(std::wstring const& text) {
  WriteClipboardText(text);
  // Hiding the overlay returns focus to the window the user came from.
  HideLauncher();
  std::thread([text]() {
    std::this_thread::sleep_for(std::chrono::milliseconds(180));
    INPUT inputs[4]{};
    for (auto& input : inputs) {
      input.type = INPUT_KEYBOARD;
    }
    inputs[0].ki.wVk = VK_CONTROL;
    inputs[1].ki.wVk = 'V';
    inputs[2].ki.wVk = 'V';
    inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;
    inputs[3].ki.wVk = VK_CONTROL;
    inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;
    ::SendInput(4, inputs, sizeof(INPUT));
  }).detach();
}

void MainWindow::ApplyTheme(std::string const& theme) {
  try {
    auto element = this->Content().try_as<
        winrt::Microsoft::UI::Xaml::FrameworkElement>();
    if (element == nullptr) {
      return;
    }
    if (theme == "dark") {
      element.RequestedTheme(
          winrt::Microsoft::UI::Xaml::ElementTheme::Dark);
    } else if (theme == "light") {
      element.RequestedTheme(
          winrt::Microsoft::UI::Xaml::ElementTheme::Light);
    } else {
      element.RequestedTheme(
          winrt::Microsoft::UI::Xaml::ElementTheme::Default);
    }
  } catch (...) {
    // Theme application must never take the launcher down.
  }
}

void MainWindow::ApplyHotkey(std::string const& spec) {
  HWND hwnd = ::FindWindowW(nullptr, L"Fulcrum");
  if (hwnd == nullptr) {
    return;
  }
  ::UnregisterHotKey(hwnd, kHotkeyIdPrimary);
  ::UnregisterHotKey(hwnd, kHotkeyIdFallback);
  hotkey_atom_ = 0;
  HotkeyBinding binding;
  if (parse_hotkey(spec, binding) &&
      ::RegisterHotKey(hwnd, kHotkeyIdPrimary,
                       binding.mods | MOD_NOREPEAT, binding.vk)) {
    hotkey_atom_ = kHotkeyIdPrimary;
    return;
  }
  // The spec did not parse or the combo is taken: the honest fallback
  // keeps the launcher reachable.
  if (::RegisterHotKey(hwnd, kHotkeyIdFallback,
                       MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, VK_SPACE)) {
    hotkey_atom_ = kHotkeyIdFallback;
    if (spec != "ctrl+alt+space") {
      SetStatusOk(L"Fulcrum is ready — that hotkey was taken, using "
                  L"Ctrl+Alt+Space. Change it in settings → hotkey.");
    }
  } else {
    SetStatusError(L"The hotkeys Fulcrum tried are taken by other tools. "
                   L"Change it in settings → hotkey, or release the combo "
                   L"and restart Fulcrum.");
  }
}

void MainWindow::ApplyAiStream(rivet_app::AiStream const& stream) {
  if (stream.phase == "idle") {
    DismissAiPanel();
    return;
  }
  AiPanel().Visibility(
      winrt::Microsoft::UI::Xaml::Visibility::Visible);
  AiText().Text(to_wide(stream.text));
  if (stream.phase == "running") {
    AiPhase().Text(t("aiRunning"));
  } else if (stream.phase == "error") {
    AiPhase().Text(t("aiFailed"));
  } else {
    AiPhase().Text(t("aiAnswer"));
  }
}

void MainWindow::DismissAiPanel() {
  AiPanel().Visibility(winrt::Microsoft::UI::Xaml::Visibility::Collapsed);
}

void MainWindow::ApplyPluginDetail(rivet_app::DetailView const& view) {
  DetailPanel().Visibility(winrt::Microsoft::UI::Xaml::Visibility::Visible);
  DetailText().Text(to_wide(view.text));
  auto items = winrt::single_threaded_observable_vector<winrt::hstring>();
  for (auto const& pair : view.metadata) {
    if (pair.size() >= 2) {
      items.Append(to_wide(pair[0]) + L"  ·  " + to_wide(pair[1]));
    }
  }
  DetailMetadata().ItemsSource(items);
}

void MainWindow::DismissDetailPanel() {
  DetailPanel().Visibility(winrt::Microsoft::UI::Xaml::Visibility::Collapsed);
}

void MainWindow::RefreshForRevision() {
  // Backend-side data changed (FPP2 daemon push): re-run the query the
  // user is looking at, debounced; only the newest search may paint.
  search_generation_ += 1;
  SearchAsync(std::wstring(QueryBox().Text()));
}

void MainWindow::PullHostSettings() {
  if (api_ == nullptr) {
    return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto* api = api_.get();
  std::thread([weak, api, dispatcher]() mutable {
    std::string hotkey;
    std::string theme;
    std::string language;
    try {
      hotkey = api->get_hotkey().get();
    } catch (...) {
    }
    try {
      theme = api->get_theme().get();
    } catch (...) {
    }
    try {
      // Row shape per the backend settings-list contract: [key, value, …].
      auto const rows = api->settings_list().get();
      for (auto const& row : rows) {
        if (row.size() >= 2 && row[0] == "language") {
          language = row[1];
        }
      }
    } catch (...) {
    }
    dispatcher.TryEnqueue(
        [weak, hotkey, theme, language]() mutable {
          if (auto window = weak.get()) {
            set_i18n_language(language);
            window->ApplyLanguage();
            if (!hotkey.empty()) {
              window->ApplyHotkey(hotkey);
            }
            if (!theme.empty()) {
              window->ApplyTheme(theme);
            }
          }
        });
  }).detach();
}

void MainWindow::QueryBox_TextChanged(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::TextChangedEventArgs const&) {
  SearchAsync(std::wstring(QueryBox().Text()));
}

void MainWindow::QueryBox_KeyDown(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args) {
  // ⌘K equivalent: Ctrl+K opens the selected row's secondary actions.
  // Plain Win32 state read: the WinUI InputKeyboardSource projection is
  // not worth its include surface for one modifier check.
  if (args.Key() == winrt::Windows::System::VirtualKey::K &&
      (::GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0) {
    ShowActionsForSelection();
    args.Handled(true);
    return;
  }
  switch (args.Key()) {
    case winrt::Windows::System::VirtualKey::Tab:
      // Autocomplete the selected row's title into the query field.
      if (actions_mode_) {
        break;
      }
      if (auto const index = ResultsList().SelectedIndex();
          index >= 0 && index < static_cast<int>(rows_.size())) {
        QueryBox().Text(to_wide(rows_[static_cast<std::size_t>(index)].title));
        QueryBox().Focus(
            winrt::Microsoft::UI::Xaml::FocusState::Programmatic);
      }
      args.Handled(true);
      break;
    case winrt::Windows::System::VirtualKey::Down:
      MoveSelection(1);
      args.Handled(true);
      break;
    case winrt::Windows::System::VirtualKey::Up:
      MoveSelection(-1);
      args.Handled(true);
      break;
    case winrt::Windows::System::VirtualKey::Enter:
      RunSelected();
      args.Handled(true);
      break;
    case winrt::Windows::System::VirtualKey::Escape:
      // Inside the action panel: back to the search rows first.
      if (actions_mode_) {
        CloseActions();
        args.Handled(true);
        break;
      }
      // A finished AI answer or a plugin detail dismisses before
      // anything else.
      if (AiPanel().Visibility() ==
          winrt::Microsoft::UI::Xaml::Visibility::Visible) {
        DismissAiPanel();
        args.Handled(true);
        break;
      }
      if (DetailPanel().Visibility() ==
          winrt::Microsoft::UI::Xaml::Visibility::Visible) {
        DismissDetailPanel();
        args.Handled(true);
        break;
      }
      // Alfred/Raycast convention: clear the query first, hide only when
      // it is already empty.
      if (QueryBox().Text().empty()) {
        HideLauncher();
      } else {
        QueryBox().Text(L"");
        SearchAsync(L"");
        QueryBox().Focus(
            winrt::Microsoft::UI::Xaml::FocusState::Programmatic);
      }
      args.Handled(true);
      break;
    default:
      break;
  }
}

void MainWindow::ResultsList_DoubleTapped(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Input::DoubleTappedRoutedEventArgs const&) {
  RunSelected();
}

winrt::fire_and_forget MainWindow::SearchAsync(std::wstring const& query) {
  if (api_ == nullptr) {
    co_return;
  }
  auto const generation = search_generation_.fetch_add(1) + 1;
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto* api = api_.get();
  auto const utf8_query = to_utf8(query);

  try {
    co_await winrt::resume_background();
    auto const raw_rows = api->search(utf8_query).get();
    std::vector<rivet_app::ResultRow> rows;
    rows.reserve(raw_rows.size());
    for (auto const& cells : raw_rows) {
      rows.push_back(rivet_app::ResultRow::from(cells));
    }
    dispatcher.TryEnqueue([weak, rows = std::move(rows), generation]() mutable {
      if (auto window = weak.get()) {
        // Only the newest query may paint; stale completions are dropped.
        if (generation == window->search_generation_.load()) {
          window->ApplyResults(std::move(rows));
        }
      }
    });
  } catch (std::exception const& e) {
    auto message = std::string(e.what());
    dispatcher.TryEnqueue([weak, message = std::move(message)] {
      if (auto window = weak.get()) {
        window->SetStatusError(to_wide(message));
      }
    });
  }
}

void MainWindow::ApplyActions(std::vector<rivet_app::ResultRow> rows) {
  ApplyResults(std::move(rows));
  actions_mode_ = true;  // ApplyResults resets it; the actions stay up.
  HintBar().Text(t("navigationHintActions"));
}

void MainWindow::ApplyResults(std::vector<rivet_app::ResultRow> rows) {
  actions_mode_ = false;
  rows_ = std::move(rows);
  auto items = ResultsList().Items();
  items.Clear();
  enter_chips_.clear();
  for (auto const& row : rows_) {
    auto content = build_row_content(row);
    enter_chips_.push_back(content.enter_chip);
    winrt::Microsoft::UI::Xaml::Controls::ListViewItem item;
    item.Content(content.root);
    items.Append(item);
  }
  if (!rows_.empty()) {
    ResultsList().SelectedIndex(0);
  } else {
    ResultsList().SelectedIndex(-1);
  }
  UpdateEnterChips();
}

void MainWindow::UpdateEnterChips() {
  auto const selected = ResultsList().SelectedIndex();
  for (std::size_t i = 0; i < enter_chips_.size(); ++i) {
    enter_chips_[i].Visibility(
        static_cast<int>(i) == selected
            ? winrt::Microsoft::UI::Xaml::Visibility::Visible
            : winrt::Microsoft::UI::Xaml::Visibility::Collapsed);
  }
}

void MainWindow::MoveSelection(int delta) {
  auto const count = static_cast<int>(rows_.size());
  if (count == 0) {
    return;
  }
  auto const current = ResultsList().SelectedIndex();
  auto const next = std::clamp(current + delta, 0, count - 1);
  ResultsList().SelectedIndex(next);
  ResultsList().ScrollIntoView(ResultsList().SelectedItem());
}

void MainWindow::ShowActionsForSelection() {
  auto const index = ResultsList().SelectedIndex();
  if (index < 0 || index >= static_cast<int>(rows_.size()) || api_ == nullptr ||
      actions_mode_) {
    return;
  }
  auto const row = rows_[static_cast<std::size_t>(index)];
  search_rows_ = rows_;
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto* api = api_.get();

  std::thread([weak, api, dispatcher, row]() mutable {
    try {
      auto const raw_actions = api->row_actions(row.id, row.arg).get();
      std::vector<rivet_app::ResultRow> actions;
      actions.reserve(raw_actions.size());
      for (auto const& cells : raw_actions) {
        actions.push_back(rivet_app::ResultRow::from(cells));
      }
      dispatcher.TryEnqueue([weak, actions = std::move(actions)]() mutable {
        if (auto window = weak.get()) {
          window->ApplyActions(std::move(actions));
          if (window->rows_.empty()) {
            window->SetStatusError(t("noSecondaryActions"));
          }
        }
      });
    } catch (std::exception const& e) {
      auto message = std::string(e.what());
      dispatcher.TryEnqueue([weak, message = std::move(message)] {
        if (auto window = weak.get()) {
          window->SetStatusError(to_wide(message));
        }
      });
    }
  }).detach();
}

void MainWindow::CloseActions() {
  actions_mode_ = false;
  auto saved = std::move(search_rows_);
  search_rows_.clear();
  ApplyResults(std::move(saved));
  HintBar().Text(t("navigationHint"));
  QueryBox().Focus(winrt::Microsoft::UI::Xaml::FocusState::Programmatic);
}

void MainWindow::RunSelected() {
  auto const index = ResultsList().SelectedIndex();
  if (index < 0 || index >= static_cast<int>(rows_.size()) || api_ == nullptr) {
    return;
  }
  auto const row = rows_[static_cast<std::size_t>(index)];
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto* api = api_.get();

  // Side effects (app launch, plugin run) belong off the UI thread; the
  // backend Events that follow drive the actual clipboard/URL work.
  std::thread([weak, api, dispatcher, row]() mutable {
    try {
      auto const status = api->run_action(row.id, row.arg).get();
      std::optional<std::string> update_path;
      if (status == "quit-and-install" && row.id == "update.install") {
        auto const state = api->update_state().get();
        if (state.downloaded_path && !state.downloaded_path->empty()) {
          update_path = *state.downloaded_path;
        }
      }
      dispatcher.TryEnqueue([weak, dispatcher, status, row,
                             update_path = std::move(update_path)]() mutable {
        if (auto window = weak.get()) {
          if (status == "ok" || status == "launched" || status == "copied" ||
              status == "opened") {
            if (window->actions_mode_) {
              // A mutating action (pin, delete, copy) keeps the launcher
              // open, back on the search rows.
              window->CloseActions();
            } else {
              window->HideLauncher();
            }
          } else if (status == "started") {
            // AI run: the request continues on a backend thread; the
            // ai-stream State drives the streaming panel.
            window->SetStatusOk(t("aiRunning"));
          } else if (status == "stay") {
            // The result is meant to be read (update check, ...): the
            // event already wrote the status line; keep the panel open.
          } else if (status == "detail") {
            // FPP2 plugin detail: fetch the payload and show it in the
            // panel slot. The RPC runs off the UI thread; the result
            // paints through the dispatcher (captured below — the
            // TryEnqueue lambda would not otherwise see it).
            window->DismissDetailPanel();
            auto* api2 = window->api_.get();
            auto const row_id = row.id;   // rows are already UTF-8
            auto const row_arg = row.arg;
            std::thread([weak, dispatcher, api2, row_id, row_arg]() mutable {
              try {
                auto view = api2->plugin_detail(row_id, row_arg).get();
                dispatcher.TryEnqueue([weak, view]() mutable {
                  if (auto window = weak.get()) {
                    window->ApplyPluginDetail(view);
                  }
                });
              } catch (std::exception const& e) {
                auto message = std::string(e.what());
                dispatcher.TryEnqueue([weak, message = std::move(message)] {
                  if (auto window = weak.get()) {
                    window->SetStatusError(to_wide(message));
                  }
                });
              }
            }).detach();
          } else if (status == "downloading") {
            // The backend download thread owns the transfer; the host
            // mirrors its progress into the status bar.
            window->HideLauncher();
            window->StartUpdateProgressPoll();
          } else if (status == "quit-and-install" &&
                     row.id == "update.install") {
            try {
              if (!update_path) {
                throw std::runtime_error("downloaded update path is missing");
              }
              auto const msi = std::filesystem::path(to_wide(*update_path));
              rivet::update::MsiHandoff::LaunchVerifiedInstaller(
                  L"site.jrtx.fulcrum", msi, executable_path());
              // Existing tray Quit uses Destroy() as the supported process
              // exit path; the detached handoff waits for this PID to leave,
              // upgrades with msiexec /passive /norestart, then relaunches.
              window->AppWindow().Destroy();
            } catch (std::exception const& e) {
              window->SetStatusError(
                  L"Update install failed: " + to_wide(e.what()));
            }
          } else if (status == "delegated") {
            // Host-native actions: window commands reach other apps'
            // windows; about.open and settings.open render this app's own
            // windows.
            if (row.id == "about.open") {
              window->ShowAbout();
            } else if (row.id == "settings.open") {
              window->HideLauncher();
              window->ShowSettings();
            } else if (fulcrum::RunWindowCommand(row.id)) {
              window->HideLauncher();
            } else {
              window->SetStatusError(L"No window found to manage.");
            }
          } else {
            window->SetStatusError(to_wide(status));
          }
        }
      });
    } catch (std::exception const& e) {
      auto message = std::string(e.what());
      dispatcher.TryEnqueue([weak, message = std::move(message)] {
        if (auto window = weak.get()) {
          window->SetStatusError(to_wide(message));
        }
      });
    }
  }).detach();
}

// ---- about ----------------------------------------------------------------

// The tray menu's "About Fulcrum" and the `about` launcher row land here:
// one ContentDialog with version, tagline, license and the site/issue
// links (taskly's OnAbout shape).
winrt::fire_and_forget MainWindow::ShowAbout() {
  namespace mxc = winrt::Microsoft::UI::Xaml::Controls;
  namespace mx = winrt::Microsoft::UI::Xaml;

  auto panel = mxc::StackPanel{};
  panel.Spacing(4);
  auto tagline = mxc::TextBlock{};
  tagline.Text(t("aboutContent"));
  tagline.TextAlignment(mx::TextAlignment::Center);
  tagline.TextWrapping(mx::TextWrapping::Wrap);
  tagline.Margin({0, 0, 0, 8});
  auto license = mxc::TextBlock{};
  license.Text(t("aboutLicense"));
  license.TextAlignment(mx::TextAlignment::Center);
  license.FontSize(12);
  license.Opacity(0.75);
  auto website = mxc::HyperlinkButton{};
  website.Content(winrt::box_value(t("aboutWebsite")));
  website.NavigateUri(
      winrt::Windows::Foundation::Uri{L"https://fulcrum.jrtx.site"});
  website.HorizontalAlignment(mx::HorizontalAlignment::Center);
  website.Padding({0, 0, 0, 0});
  auto issue = mxc::HyperlinkButton{};
  issue.Content(winrt::box_value(t("aboutReportIssue")));
  issue.NavigateUri(winrt::Windows::Foundation::Uri{
      L"https://github.com/turinglambdaai/fulcrum/issues"});
  issue.HorizontalAlignment(mx::HorizontalAlignment::Center);
  issue.Padding({0, 0, 0, 0});
  panel.Children().Append(tagline);
  panel.Children().Append(license);
  panel.Children().Append(website);
  panel.Children().Append(issue);

  auto dialog = mxc::ContentDialog{};
  dialog.Title(winrt::box_value(L"Fulcrum v" + to_wide(rivet_app::kVersion)));
  dialog.Content(winrt::box_value(panel));
  dialog.CloseButtonText(t("updateClose"));
  dialog.XamlRoot(Content().XamlRoot());
  co_await dialog.ShowAsync();
}

// ---- settings -------------------------------------------------------------

// The tray menu's "Settings…" and the `settings` launcher row land here: a
// separate top-level window over the backend settings store (the launcher
// overlay hides on focus loss, so settings cannot live inside it). One
// instance; every show re-attaches, which reloads the current values.
void MainWindow::ShowSettings() {
  if (api_ == nullptr) {
    SetStatusError(L"Settings open once the backend is ready.");
    return;
  }
  if (settings_window_ == nullptr) {
    auto window = winrt::make<SettingsWindow>();
    window.Closed([this](auto&&, auto&&) { settings_window_ = nullptr; });
    settings_window_ = window;
  }
  winrt::get_self<SettingsWindow>(settings_window_)->Attach(api_.get());
  settings_window_.Activate();
}

// ---- snippet auto-expansion ----------------------------------------------

void MainWindow::OnExpansionKey(std::uint32_t vk) {
  // The user typing into Fulcrum's own panel must never self-expand.
  if (::GetForegroundWindow() == ::FindWindowW(nullptr, L"Fulcrum")) {
    expansion_buffer_.clear();
    return;
  }
  if (vk == VK_BACK) {
    if (!expansion_buffer_.empty()) expansion_buffer_.pop_back();
    return;
  }
  wchar_t ch = 0;
  if (vk == VK_SPACE) {
    ch = L' ';
  } else if ((vk >= 0x21 && vk <= 0x7E) || (vk >= 0xBA && vk <= 0xC0) ||
             (vk >= 0xDB && vk <= 0xDF)) {
    ch = static_cast<wchar_t>(::MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR) & 0xFFFF);
  }
  if (ch == 0) {
    expansion_buffer_.clear();
    return;
  }
  bool const boundary =
      ch == L' ' || ch == L'.' || ch == L',' || ch == L';' || ch == L':' ||
      ch == L'!' || ch == L'?';
  if (!boundary) {
    expansion_buffer_ += ch;
    return;
  }
  std::wstring const candidate = expansion_buffer_;
  expansion_buffer_.clear();
  if (candidate.empty() || !expansion_enabled_) {
    return;
  }
  for (std::size_t i = 0; i < expansion_triggers_.size(); ++i) {
    if (expansion_triggers_[i].first == candidate) {
      expansion_ignore_.store(true, std::memory_order_relaxed);
      HWND const hwnd = ::FindWindowW(nullptr, L"Fulcrum");
      if (hwnd != nullptr) {
        ::PostMessageW(hwnd, kExpansionRepairMessage,
                       static_cast<WPARAM>(i), 0);
      }
      break;
    }
  }
}

void MainWindow::RepairExpansion(std::size_t trigger_index) {
  if (trigger_index >= expansion_triggers_.size()) {
    return;
  }
  std::wstring const text = expansion_triggers_[trigger_index].second;
  expansion_ignore_.store(true, std::memory_order_relaxed);
  std::vector<INPUT> inputs;
  // Erase the keyword (the boundary character already landed after it).
  for (std::size_t i = 0; i < expansion_buffer_.size(); ++i) {
    INPUT down{};
    down.type = INPUT_KEYBOARD;
    down.ki.wVk = VK_BACK;
    inputs.push_back(down);
    INPUT up{};
    up.type = INPUT_KEYBOARD;
    up.ki.wVk = VK_BACK;
    up.ki.dwFlags = KEYEVENTF_KEYUP;
    inputs.push_back(up);
  }
  // Type the expansion as unicode key input (no clipboard churn).
  for (wchar_t const unit : text) {
    INPUT down{};
    down.type = INPUT_KEYBOARD;
    down.ki.wVk = 0;
    down.ki.dwFlags = KEYEVENTF_UNICODE;
    down.ki.wScan = static_cast<WORD>(unit);
    inputs.push_back(down);
    INPUT up{};
    up.type = INPUT_KEYBOARD;
    up.ki.wVk = 0;
    up.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
    up.ki.wScan = static_cast<WORD>(unit);
    inputs.push_back(up);
  }
  if (!inputs.empty()) {
    ::SendInput(static_cast<UINT>(inputs.size()), inputs.data(),
                sizeof(INPUT));
  }
  expansion_ignore_.store(false, std::memory_order_relaxed);
}

void MainWindow::InstallExpansionHook() {
  g_expansion_window = this;
  expansion_hook_ = ::SetWindowsHookExW(
      WH_KEYBOARD_LL, expansion_hook_proc, ::GetModuleHandleW(nullptr), 0);
}

void MainWindow::RefreshExpansionData() {
  if (api_ == nullptr) {
    return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto* api = api_.get();
  std::thread([weak, api, dispatcher]() mutable {
    bool enabled = true;
    std::vector<std::pair<std::wstring, std::wstring>> triggers;
    try {
      auto const rows = api->settings_list().get();
      for (auto const& row : rows) {
        if (row.size() >= 3 && row[0] == "expansion-enabled") {
          enabled = row[1] != "off";
        }
      }
      if (enabled) {
        auto const snippets = api->snippet_list().get();
        for (auto const& cells : snippets) {
          if (cells.size() >= 4 && !cells[2].empty() && !cells[3].empty()) {
            triggers.emplace_back(to_wide(cells[2]), to_wide(cells[3]));
          }
        }
      }
    } catch (...) {
      return;  // silent: a failed refresh keeps the previous table
    }
    dispatcher.TryEnqueue(
        [weak, enabled, triggers = std::move(triggers)]() mutable {
          if (auto window = weak.get()) {
            window->expansion_enabled_ = enabled;
            window->expansion_triggers_ = std::move(triggers);
          }
        });
  }).detach();
}

void MainWindow::SetStatusOk(std::wstring const& message) {
  // Routine status lives quietly in the footer; the InfoBar strip is
  // reserved for things that need attention (errors, download failures).
  last_status_ = message;
  StatusText().Text(message);
  StatusBar().IsOpen(false);
}

void MainWindow::SetStatusError(std::wstring const& message) {
  last_status_ = message;
  StatusText().Text(message);
  StatusBar().IsOpen(true);
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
  StatusBar().Message(message);
}

// Right-click either status surface → "Copy message": errors and results
// that only live in the status line must be copyable.
void MainWindow::AttachStatusBarCopyAffordance() {
  auto flyout = winrt::Microsoft::UI::Xaml::Controls::MenuFlyout{};
  auto item = winrt::Microsoft::UI::Xaml::Controls::MenuFlyoutItem{};
  item.Text(L"Copy message");
  item.Click([this](auto&&, auto&&) {
    WriteClipboardText(last_status_);
  });
  flyout.Items().Append(item);
  auto footer_flyout = winrt::Microsoft::UI::Xaml::Controls::MenuFlyout{};
  auto footer_item = winrt::Microsoft::UI::Xaml::Controls::MenuFlyoutItem{};
  footer_item.Text(L"Copy message");
  footer_item.Click([this](auto&&, auto&&) {
    WriteClipboardText(last_status_);
  });
  footer_flyout.Items().Append(footer_item);
  StatusBar().ContextFlyout(flyout);
  StatusText().ContextFlyout(footer_flyout);
}

// Manual check from the tray: manual=true bypasses the 4-hour family
// throttle (the backend stamps the timestamp either way, per the update
// trigger contract). Results surface in the footer; the `update` launcher
// rows drive download and install from here.
void MainWindow::CheckForUpdates() {
  if (api_ == nullptr) {
    SetStatusError(L"Update check once the backend is ready.");
    return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto* api = api_.get();
  std::thread([weak, api, dispatcher]() mutable {
    std::wstring line;
    bool is_error = false;
    try {
      auto const check = api->update_check(true).get();
      if (check.status == "available") {
        auto const version = check.available_version.value_or(std::string("?"));
        line = t_format("updateAvailableStatus", {to_wide(version)});
      } else if (check.status == "up-to-date") {
        line = t("updateUpToDate");
      } else if (check.status == "throttled") {
        line = L"Update check throttled — try again shortly.";
      } else {
        is_error = true;
        line = t_format("updateDownloadFailed",
                        {to_wide(check.error.value_or("check failed"))});
      }
    } catch (std::exception const& e) {
      is_error = true;
      line = to_wide(std::string("Update check failed: ") + e.what());
    } catch (...) {
      is_error = true;
      line = L"Update check failed.";
    }
    dispatcher.TryEnqueue([weak, line, is_error]() mutable {
      if (auto window = weak.get()) {
        if (is_error) {
          window->SetStatusError(line);
        } else {
          window->SetStatusOk(line);
        }
      }
    });
  }).detach();
}

void MainWindow::StartSilentUpdateCheck() {
  if (api_ == nullptr) {
    return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto* api = api_.get();
  // The 4-hour throttle and the manifest verification are backend-owned;
  // this is one cheap RPC the backend may decline (status "throttled").
  // Failures are silent by design — a resident launcher must never nag.
  std::thread([weak, api, dispatcher]() mutable {
    try {
      auto const check = api->update_check(false).get();
      if (check.status != "available") {
        return;
      }
      auto const version = check.available_version.value_or(std::string("?"));
      dispatcher.TryEnqueue([weak, version]() mutable {
        if (auto window = weak.get()) {
          window->SetStatusOk(
              t_format("updateAvailableStatus", {to_wide(version)}));
        }
      });
    } catch (...) {
      // silent: network down, feed unreachable — never nag
    }
  }).detach();
}

void MainWindow::StartUpdateProgressPoll() {
  if (api_ == nullptr || update_polling_.exchange(true)) {
    return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto* api = api_.get();
  std::thread([weak, api, dispatcher]() mutable {
    while (true) {
      try {
        auto const state = api->update_state().get();
        if (state.phase == "downloaded") {
          dispatcher.TryEnqueue([weak]() mutable {
            if (auto window = weak.get()) {
              window->SetStatusOk(t("updateDownloadedStatusWin"));
            }
          });
          break;
        }
        if (state.phase == "error") {
          auto const message = state.message;
          dispatcher.TryEnqueue([weak, message = std::move(message)]() mutable {
            if (auto window = weak.get()) {
              std::wstring const detail =
                  message ? to_wide(*message) : t("updateUnknownError");
              window->SetStatusError(t_format("updateDownloadFailed", {detail}));
            }
          });
          break;
        }
        if (state.phase != "downloading") {
          break;
        }
        auto const percent = state.percent;
        dispatcher.TryEnqueue([weak, percent]() mutable {
          if (auto window = weak.get()) {
            window->SetStatusOk(
                t_format("updateDownloadPercent",
                         {std::to_wstring(percent)}));
          }
        });
      } catch (...) {
        break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1000));
    }
    // Re-entry guard only: clear it on the UI thread (the worker never
    // captures `this`) so a later download can poll again.
    dispatcher.TryEnqueue([weak]() mutable {
      if (auto window = weak.get()) {
        window->update_polling_.store(false, std::memory_order_release);
      }
    });
  }).detach();
}

}  // namespace winrt::RivetHost::implementation
