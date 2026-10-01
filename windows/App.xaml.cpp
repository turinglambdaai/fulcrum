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
  // first-party rivet lease, not a hand-rolled mutex).
  instance_lease_ = std::make_unique<rivet::system::SingleInstanceLease>(
      L"site.jrtx.fulcrum");
  if (!instance_lease_->is_primary()) {
    return;
  }

  window_ = winrt::make<MainWindow>();
  window_.Activate();
}

}  // namespace winrt::RivetHost::implementation
