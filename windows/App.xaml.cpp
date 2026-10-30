#include "pch.h"
#include "App.xaml.h"
#include "MainWindow.xaml.h"
#include "WindowsInstance.h"
#include "Autostart.h"

namespace winrt::RivetHost::implementation {

App::App() {
  InitializeComponent();

#if defined(_DEBUG) && !defined(DISABLE_XAML_GENERATED_BREAK_ON_UNHANDLED_EXCEPTION)
  UnhandledException([](winrt::Windows::Foundation::IInspectable const&,
                        Microsoft::UI::Xaml::UnhandledExceptionEventArgs const& e) {
    if (::IsDebuggerPresent()) {
      auto const message = e.Message();
      (void)message;
      __debugbreak();
    }
  });
#endif
}

void App::OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&) {
  // One instance owns the global hotkey; second launches exit here (the
  // first-party rivet lease, not a hand-rolled mutex). Product acceptance
  // supplies a per-run id so the packaged candidate never forwards into an
  // installed production instance on the same runner.
  auto const application_id = fulcrum::windows::InstanceId();
  instance_lease_ = std::make_unique<rivet::system::SingleInstanceLease>(
      application_id);
  if (!instance_lease_->is_primary()) {
    // Reopen the resident launcher; never leave a second headless process.
    if (!fulcrum::windows::BackgroundLaunch()) {
      if (HWND existing = fulcrum::windows::FindResidentWindow()) {
        ::PostMessageW(existing, fulcrum::windows::kSummonResidentMessage, 0, 0);
      }
    }
    Microsoft::UI::Xaml::Application::Current().Exit();
    return;
  }

  // Keep the initial HWND hidden until the backend's first results are ready.
  window_ = winrt::make<MainWindow>();
}

}  // namespace winrt::RivetHost::implementation
