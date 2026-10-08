#pragma once

#include "pch.h"
#include "MainWindow.g.h"
#include "GeneratedBackend.hpp"

#include <string>
#include <vector>

namespace rivet_app {

// One search result row, positional per the backend contract:
// (id title subtitle kind arg icon hint badge). The generated client hands
// rows over as vector<vector<string>>; the host keeps this typed view.
struct ResultRow {
  std::string id;
  std::string title;
  std::string subtitle;
  std::string kind;
  std::string arg;
  std::string icon;
  std::string hint;
  std::string badge;

  static ResultRow from(std::vector<std::string> const& cells) {
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
};

}  // namespace rivet_app

namespace winrt::RivetHost::implementation {

struct MainWindow : MainWindowT<MainWindow> {
  MainWindow();

  // XAML event handlers (MainWindow.xaml).
  void QueryBox_TextChanged(winrt::Windows::Foundation::IInspectable const&,
                            Microsoft::UI::Xaml::Controls::TextChangedEventArgs const&);
  void QueryBox_KeyDown(winrt::Windows::Foundation::IInspectable const&,
                        Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const&);
  void ResultsList_ItemClick(winrt::Windows::Foundation::IInspectable const&,
                             Microsoft::UI::Xaml::Controls::ItemClickEventArgs const&);

  // Called by App.xaml.cpp after the window is shown: native-only setup that
  // needs the final HWND (topmost overlay chrome, global hotkey, clipboard
  // listener).
  void FinishNativeSetup();

  // Global hotkey message pump hook. Returns true when the message was the
  // Fulcrum hotkey.
  bool HandleHotkeyMessage(std::uint32_t message, std::uint64_t wParam, std::int64_t lParam);

  // Tray callback: left click opens the launcher, right click opens the
  // Open/Quit menu.
  void HandleTrayMessage(std::uint32_t message, std::int64_t lParam, HWND hwnd);

 private:
  void OnClipboardUpdate();
  winrt::fire_and_forget InitializeBackendAsync();
  winrt::fire_and_forget SearchAsync(std::wstring const& query);
  void RunSelected();
  void ShowLauncher();
  void HideLauncher();
  void MoveSelection(int delta);
  void ApplyResults(std::vector<rivet_app::ResultRow> rows);
  void SetStatusOk(std::wstring const& message);
  void SetStatusError(std::wstring const& message);

  std::shared_ptr<rivet::windows::Backend> backend_;
  std::unique_ptr<rivet_app::API> api_;
  std::vector<rivet_app::ResultRow> rows_;
  std::atomic<std::uint64_t> search_generation_{0};
  std::uint64_t hotkey_atom_{0};
  std::atomic<bool> clipboard_listener_installed_{false};
  std::wstring last_recorded_clipboard_;
  std::unique_ptr<rivet::system::TrayIcon> tray_icon_;
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {

struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};

}  // namespace winrt::RivetHost::factory_implementation
