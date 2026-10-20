#pragma once

#include "pch.h"
#include "SettingsWindow.g.h"
#include "GeneratedBackend.hpp"

#include <map>
#include <string>

namespace winrt::RivetHost::implementation {

// The settings window: a form over the backend settings store, the
// discoverable twin of the `settings` query rows. Every control carries its
// backend key in Tag; edits go through settings-set as they happen, the
// backend validates (hotkey grammar, ranges, provider names), and a refusal
// surfaces inline while the form reloads the backend's truth. The AI key
// rides the ai.key action and never comes back over the wire — ai-status
// reports readiness instead.
struct SettingsWindow : SettingsWindowT<SettingsWindow> {
  SettingsWindow();

  // Hooked up by MainWindow once the backend is ready (and again on every
  // show, which reloads). The API outlives this window: MainWindow owns it.
  void Attach(rivet_app::API* api);

  // XAML handlers (SettingsWindow.xaml).
  void Toggle_Toggled(winrt::Windows::Foundation::IInspectable const&,
                      Microsoft::UI::Xaml::RoutedEventArgs const&);
  void Choice_Changed(winrt::Windows::Foundation::IInspectable const&,
                      Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
  void Number_Changed(Microsoft::UI::Xaml::Controls::NumberBox const&,
                      Microsoft::UI::Xaml::Controls::NumberBoxValueChangedEventArgs const&);
  void Text_LostFocus(winrt::Windows::Foundation::IInspectable const&,
                      Microsoft::UI::Xaml::RoutedEventArgs const&);
  void Text_KeyDown(winrt::Windows::Foundation::IInspectable const&,
                    Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const&);
  void Key_KeyDown(winrt::Windows::Foundation::IInspectable const&,
                   Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const&);
  void SaveKey_Click(winrt::Windows::Foundation::IInspectable const&,
                     Microsoft::UI::Xaml::RoutedEventArgs const&);

 private:
  void Load();
  void Apply(std::map<std::string, std::string> values, std::string ai_status);
  void Write(std::string key, std::string value);
  void RefreshAiStatus();
  void ApplyLocalization(std::string const& language);
  void SaveKey();
  void CommitText(Microsoft::UI::Xaml::Controls::TextBox const& box);
  void ShowError(std::wstring const& message);
  void ClearError();

  rivet_app::API* api_{nullptr};
  // True while Apply pushes values into the controls, so their change
  // handlers do not write them straight back.
  bool loading_{false};
  std::map<std::string, std::string> values_;
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {

struct SettingsWindow : SettingsWindowT<SettingsWindow, implementation::SettingsWindow> {};

}  // namespace winrt::RivetHost::factory_implementation
