#pragma once

#include "pch.h"
#include "App.xaml.g.h"

namespace winrt::RivetHost::implementation {

struct App : AppT<App> {
  App();
  void OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&);

 private:
  Microsoft::UI::Xaml::Window window_{nullptr};
  std::unique_ptr<rivet::system::SingleInstanceLease> instance_lease_;
};

}  // namespace winrt::RivetHost::implementation
