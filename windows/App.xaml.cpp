#include "pch.h"
#include "App.xaml.h"
#include "MainWindow.xaml.h"

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
  std::wstring application_id = L"site.jrtx.fulcrum";
  wchar_t isolated[256]{};
  auto const isolated_length =
      ::GetEnvironmentVariableW(L"FULCRUM_INSTANCE_ID", isolated, 256);
  if (isolated_length > 0 && isolated_length < 256) {
    application_id.assign(isolated, isolated_length);
  }
  instance_lease_ = std::make_unique<rivet::system::SingleInstanceLease>(
      application_id);
  if (!instance_lease_->is_primary()) {
    return;
  }

  window_ = winrt::make<MainWindow>();
  window_.Activate();
}

}  // namespace winrt::RivetHost::implementation
