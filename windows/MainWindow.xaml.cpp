#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif
#include "GeneratedBackend.hpp"
#include "WindowCommands.h"

#include <shellapi.h>
#include <commctrl.h>
#pragma comment(lib, "comctl32.lib")

namespace winrt::RivetHost::implementation {
namespace {

constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 0xF11D;
constexpr int kTrayMenuOpen = 1;
constexpr int kTrayMenuQuit = 2;

constexpr int kHotkeyIdPrimary = 0xF11C;  // Alt+Space
constexpr int kHotkeyIdFallback = 0xF11D; // Ctrl+Alt+Space
constexpr int kWindowWidth = 680;
constexpr int kWindowHeight = 440;

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

std::wstring result_line(rivet_app::ResultRow const& row) {
  std::wstring line = to_wide(row.title);
  if (!row.subtitle.empty()) {
    line += L"  —  ";
    line += to_wide(row.subtitle);
  }
  return line;
}

}  // namespace

MainWindow::MainWindow() {
  InitializeComponent();
  Title(L"Fulcrum");
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
      // Event values are bare strings per the backend contract: RVT1 event
      // frames arrive as [name, value] and the runtime hands us value.
      std::string payload;
      if (auto const text = std::get_if<std::string>(&value.data)) {
        payload = *text;
      }
      dispatcher.TryEnqueue([weak, name, payload]() mutable {
        if (auto window = weak.get()) {
          if (name == "copy-to-clipboard") {
            if (::OpenClipboard(nullptr)) {
              auto const wide = to_wide(payload);
              auto const bytes = (wide.size() + 1) * sizeof(wchar_t);
              if (HANDLE handle = ::GlobalAlloc(GMEM_MOVEABLE, bytes)) {
                if (void* locked = ::GlobalLock(handle)) {
                  memcpy(locked, wide.c_str(), bytes);
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
            window->HideLauncher();
          } else if (name == "open-url") {
            std::wstring const url = to_wide(payload);
            ::ShellExecuteW(nullptr, L"open", url.c_str(), nullptr, nullptr,
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
        window->SetStatusOk(L"Ready — press Alt+Space anywhere");
        window->FinishNativeSetup();
        window->SearchAsync(L"");
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

void MainWindow::FinishNativeSetup() {
  // HWND lookup via the window title: Fulcrum is single-instance and owns
  // exactly one window with this title. This avoids depending on the
  // WindowsAppSDK interop surface, whose projection shape moved between
  // releases; the official interop call is the 0.2 follow-up.
  auto const hwnd = ::FindWindowW(nullptr, L"Fulcrum");

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
    }
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

  // Global hotkey: Alt+Space first, Ctrl+Alt+Space as the honest fallback
  // when Alt+Space is taken by another tool.
  hotkey_atom_ = 0;
  if (!::RegisterHotKey(hwnd, kHotkeyIdPrimary,
                        MOD_ALT | MOD_NOREPEAT, VK_SPACE)) {
    if (::RegisterHotKey(hwnd, kHotkeyIdFallback,
                         MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, VK_SPACE)) {
      hotkey_atom_ = kHotkeyIdFallback;
      SetStatusOk(L"Ready — press Ctrl+Alt+Space anywhere");
    } else {
      SetStatusError(L"Both Alt+Space and Ctrl+Alt+Space are taken by other "
                     L"tools; release one and restart Fulcrum.");
    }
  } else {
    hotkey_atom_ = kHotkeyIdPrimary;
  }

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

  // WinUI Window has no Deactivated event; the Activated state carries it.
  this->Activated([this](auto&&,
                         winrt::Microsoft::UI::Xaml::WindowActivatedEventArgs const& args) {
    if (args.WindowActivationState() ==
        winrt::Microsoft::UI::Xaml::WindowActivationState::Deactivated) {
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
        ::AppendMenuW(menu, MF_STRING, kTrayMenuOpen, L"Open Fulcrum");
        ::AppendMenuW(menu, MF_STRING, kTrayMenuQuit, L"Quit Fulcrum");
        ::SetForegroundWindow(hwnd);  // so outside clicks dismiss the menu
        int const choice = ::TrackPopupMenu(
            menu, TPM_RETURNCMD | TPM_NONOTIFY, 0, 0, 0, hwnd, nullptr);
        ::DestroyMenu(menu);
        if (choice == kTrayMenuOpen) {
          ShowLauncher();
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
  QueryBox().Text(L"");
  SearchAsync(std::wstring(L""));
  this->Activate();
  QueryBox().Focus(winrt::Microsoft::UI::Xaml::FocusState::Programmatic);
}

void MainWindow::HideLauncher() { this->AppWindow().Hide(); }

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

void MainWindow::ResultsList_ItemClick(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::ItemClickEventArgs const&) {
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
}

void MainWindow::ApplyResults(std::vector<rivet_app::ResultRow> rows) {
  actions_mode_ = false;
  rows_ = std::move(rows);
  auto items = winrt::single_threaded_observable_vector<winrt::hstring>();
  for (auto const& row : rows_) {
    items.Append(result_line(row));
  }
  ResultsList().ItemsSource(items);
  if (!rows_.empty()) {
    ResultsList().SelectedIndex(0);
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
            window->SetStatusError(L"No secondary actions for this result");
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
      dispatcher.TryEnqueue([weak, status, row]() mutable {
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
          } else if (status == "delegated") {
            // Window commands execute natively: the backend cannot reach
            // other apps' windows.
            if (fulcrum::RunWindowCommand(row.id)) {
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

void MainWindow::SetStatusOk(std::wstring const& message) {
  StatusBar().Severity(
      Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success);
  StatusBar().Message(message);
}

void MainWindow::SetStatusError(std::wstring const& message) {
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
  StatusBar().Message(message);
}

}  // namespace winrt::RivetHost::implementation
