#include "pch.h"
#include "SettingsWindow.xaml.h"
#include "GeneratedI18n.hpp"
#if __has_include("SettingsWindow.g.cpp")
#include "SettingsWindow.g.cpp"
#endif

#include <cmath>
#include <thread>

namespace winrt::RivetHost::implementation {
namespace {

namespace mx = winrt::Microsoft::UI::Xaml;
namespace mxc = winrt::Microsoft::UI::Xaml::Controls;

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

std::wstring translated_setting(std::string const& language, std::string_view key) {
  for (auto const& row : rivet_app::kI18nTable) {
    if (row.key == key) {
      return to_wide(std::string(language == "en" ? row.en : row.zh));
    }
  }
  return to_wide(std::string(key));
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

std::string trimmed(std::string value) {
  auto const begin = value.find_first_not_of(" \t\r\n");
  if (begin == std::string::npos) return {};
  auto const end = value.find_last_not_of(" \t\r\n");
  return value.substr(begin, end - begin + 1);
}

// The backend key a control carries in its Tag ("" when there is none).
std::string tag_key(winrt::Windows::Foundation::IInspectable const& sender) {
  auto element = sender.try_as<mx::FrameworkElement>();
  if (element == nullptr) return {};
  auto tag = element.Tag();
  if (tag == nullptr) return {};
  return to_utf8(std::wstring(winrt::unbox_value<winrt::hstring>(tag)));
}

// A ComboBoxItem's backend value lives in its Tag; the Off provider item
// carries the empty string, which XAML may hand back as a null Tag.
std::string item_value(winrt::Windows::Foundation::IInspectable const& item) {
  return tag_key(item);
}

void select_choice(mxc::ComboBox const& box, std::string const& value) {
  auto items = box.Items();
  for (uint32_t i = 0; i < items.Size(); ++i) {
    if (item_value(items.GetAt(i)) == value) {
      box.SelectedIndex(static_cast<int32_t>(i));
      return;
    }
  }
  box.SelectedIndex(-1);
}

double number_or(std::string const& value, double fallback) {
  try {
    return std::stod(value);
  } catch (...) {
    return fallback;
  }
}

}  // namespace

SettingsWindow::SettingsWindow() {
  InitializeComponent();
  Title(L"Fulcrum Settings");
  try {
    // Mica like the Windows Settings app; a regular title bar stays — this
    // window is a document-style surface, not the launcher overlay.
    SystemBackdrop(mx::Media::MicaBackdrop());
    if (auto appWindow = this->AppWindow()) {
      appWindow.Resize(winrt::Windows::Graphics::SizeInt32{680, 840});
      // Titled Windows windows carry their icon left of the title; WinUI
      // ships a blank unless one is set. Our exe embeds the app icon at
      // resource ID 1 (rivet build), so pointing at the exe itself works
      // in the staged tree and after install alike.
      wchar_t exe_path[MAX_PATH];
      if (::GetModuleFileNameW(nullptr, exe_path, MAX_PATH) > 0) {
        appWindow.SetIcon(exe_path);
      }
    }
  } catch (...) {
    // Backdrop, sizing and the titlebar icon are polish; the form works
    // without them.
  }
}

void SettingsWindow::Attach(rivet_app::API* api) {
  api_ = api;
  Load();
}

void SettingsWindow::Load() {
  if (api_ == nullptr) {
    return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto* api = api_;
  std::thread([weak, api, dispatcher]() mutable {
    std::map<std::string, std::string> values;
    std::string status;
    try {
      // settings-list rows: (key value description …); booleans read on/off.
      for (auto const& row : api->settings_list().get()) {
        if (row.size() >= 2) {
          values[row[0]] = row[1];
        }
      }
    } catch (...) {
    }
    try {
      status = api->ai_status().get();
    } catch (...) {
    }
    dispatcher.TryEnqueue([weak, values = std::move(values), status]() mutable {
      if (auto window = weak.get()) {
        window->Apply(std::move(values), status);
      }
    });
  }).detach();
}

void SettingsWindow::Apply(std::map<std::string, std::string> values,
                           std::string ai_status) {
  values_ = std::move(values);
  loading_ = true;
  auto const get = [this](char const* key) -> std::string {
    auto const it = values_.find(key);
    return it == values_.end() ? std::string() : it->second;
  };
  ApplyLocalization(get("language"));
  select_choice(LanguageBox(), get("language"));
  select_choice(ThemeBox(), get("theme"));
  HotkeyBox().Text(to_wide(get("hotkey")));
  MaxResultsBox().Value(number_or(get("max-results"), 12));
  ClipboardSwitch().IsOn(get("clipboard-enabled") == "on");
  ClipboardLimitBox().Value(number_or(get("clipboard-limit"), 1000));
  WebSearchSwitch().IsOn(get("web-search-enabled") == "on");
  select_choice(DefaultBangBox(), get("default-engine"));
  ExpansionSwitch().IsOn(get("expansion-enabled") == "on");
  PluginsSwitch().IsOn(get("plugins-enabled") == "on");
  PluginTimeoutBox().Value(number_or(get("plugins-timeout-ms"), 2000));
  select_choice(ProviderBox(), get("ai-provider"));
  ModelBox().Text(to_wide(get("ai-model")));
  BaseUrlBox().Text(to_wide(get("ai-base-url")));
  PersonaBox().Text(to_wide(get("ai-persona")));
  SyncRootBox().Text(to_wide(get("sync-root")));
  UpdateUrlBox().Text(to_wide(get("update-base-url")));
  AiStatusText().Text(
      to_wide(ai_status == "ready" ? std::string("Ready") : ai_status));
  loading_ = false;
}

void SettingsWindow::Write(std::string key, std::string value) {
  if (api_ == nullptr || key.empty()) {
    return;
  }
  values_[key] = value;
  if (key == "language") ApplyLocalization(value);
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto* api = api_;
  std::thread([weak, api, dispatcher, key, value]() mutable {
    std::string error;
    try {
      api->settings_set(key, value).get();
    } catch (std::exception const& e) {
      error = e.what();
    } catch (...) {
      error = "settings-set failed";
    }
    dispatcher.TryEnqueue([weak, key, error]() mutable {
      if (auto window = weak.get()) {
        if (error.empty()) {
          window->ClearError();
          if (key == "ai-provider") {
            window->RefreshAiStatus();
          }
        } else {
          // The backend refused the value (grammar, range): say so and
          // fall back to what it actually holds.
          window->ShowError(to_wide(key + ": " + error));
          window->Load();
        }
      }
    });
  }).detach();
}

void SettingsWindow::ApplyLocalization(std::string const& language) {
  LanguageLabel().Text(translated_setting(language, "setting.language"));
  ThemeLabel().Text(translated_setting(language, "setting.theme"));
  HotkeyLabel().Text(translated_setting(language, "setting.hotkey"));
  MaxResultsLabel().Text(translated_setting(language, "setting.max-results"));
  ClipboardLabel().Text(translated_setting(language, "setting.clipboard-enabled"));
  WebSearchLabel().Text(translated_setting(language, "setting.web-search-enabled"));
  ExpansionLabel().Text(translated_setting(language, "setting.expansion-enabled"));
  PluginsLabel().Text(translated_setting(language, "setting.plugins-enabled"));
  ProviderLabel().Text(translated_setting(language, "setting.ai-provider"));
}

void SettingsWindow::RefreshAiStatus() {
  if (api_ == nullptr) {
    return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto* api = api_;
  std::thread([weak, api, dispatcher]() mutable {
    std::string status;
    try {
      status = api->ai_status().get();
    } catch (...) {
    }
    dispatcher.TryEnqueue([weak, status]() mutable {
      if (auto window = weak.get()) {
        window->AiStatusText().Text(
            to_wide(status == "ready" ? std::string("Ready") : status));
      }
    });
  }).detach();
}

void SettingsWindow::SaveKey() {
  if (api_ == nullptr) {
    return;
  }
  auto const key = trimmed(to_utf8(std::wstring(KeyBox().Password())));
  if (key.empty()) {
    return;
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto* api = api_;
  std::thread([weak, api, dispatcher, key]() mutable {
    std::string status;
    try {
      status = api->run_action("ai.key", key).get();
    } catch (std::exception const& e) {
      status = e.what();
    } catch (...) {
      status = "ai.key failed";
    }
    dispatcher.TryEnqueue([weak, status]() mutable {
      if (auto window = weak.get()) {
        window->KeyNotice().Text(
            status == "ok"
                ? std::wstring(L"Key saved — stored on this PC only, never synced.")
                : to_wide(status));
        window->KeyBox().Password(L"");
        window->RefreshAiStatus();
      }
    });
  }).detach();
}

void SettingsWindow::CommitText(mxc::TextBox const& box) {
  if (loading_ || box == nullptr) {
    return;
  }
  auto const key = tag_key(box);
  auto const value = trimmed(to_utf8(std::wstring(box.Text())));
  auto const it = values_.find(key);
  if (it != values_.end() && it->second == value) {
    return;
  }
  Write(key, value);
}

void SettingsWindow::ShowError(std::wstring const& message) {
  ErrorText().Text(message);
  ErrorText().Visibility(mx::Visibility::Visible);
}

void SettingsWindow::ClearError() {
  ErrorText().Text(L"");
  ErrorText().Visibility(mx::Visibility::Collapsed);
}

// ---- XAML handlers ----------------------------------------------------------

void SettingsWindow::Toggle_Toggled(
    winrt::Windows::Foundation::IInspectable const& sender,
    mx::RoutedEventArgs const&) {
  if (loading_) {
    return;
  }
  auto toggle = sender.try_as<mxc::ToggleSwitch>();
  if (toggle == nullptr) {
    return;
  }
  Write(tag_key(sender), toggle.IsOn() ? "on" : "off");
}

void SettingsWindow::Choice_Changed(
    winrt::Windows::Foundation::IInspectable const& sender,
    mxc::SelectionChangedEventArgs const&) {
  if (loading_) {
    return;
  }
  auto box = sender.try_as<mxc::ComboBox>();
  if (box == nullptr || box.SelectedItem() == nullptr) {
    return;
  }
  Write(tag_key(sender), item_value(box.SelectedItem()));
}

void SettingsWindow::Number_Changed(
    mxc::NumberBox const& sender,
    mxc::NumberBoxValueChangedEventArgs const& args) {
  if (loading_) {
    return;
  }
  auto const value = args.NewValue();
  if (std::isnan(value)) {
    return;
  }
  Write(tag_key(sender), std::to_string(static_cast<long long>(value)));
}

void SettingsWindow::Text_LostFocus(
    winrt::Windows::Foundation::IInspectable const& sender,
    mx::RoutedEventArgs const&) {
  CommitText(sender.try_as<mxc::TextBox>());
}

void SettingsWindow::Text_KeyDown(
    winrt::Windows::Foundation::IInspectable const& sender,
    mx::Input::KeyRoutedEventArgs const& args) {
  if (args.Key() == winrt::Windows::System::VirtualKey::Enter) {
    CommitText(sender.try_as<mxc::TextBox>());
    args.Handled(true);
  }
}

void SettingsWindow::Key_KeyDown(
    winrt::Windows::Foundation::IInspectable const&,
    mx::Input::KeyRoutedEventArgs const& args) {
  if (args.Key() == winrt::Windows::System::VirtualKey::Enter) {
    SaveKey();
    args.Handled(true);
  }
}

void SettingsWindow::SaveKey_Click(
    winrt::Windows::Foundation::IInspectable const&,
    mx::RoutedEventArgs const&) {
  SaveKey();
}

}  // namespace winrt::RivetHost::implementation
