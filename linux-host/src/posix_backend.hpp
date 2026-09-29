// Fulcrum Linux host — embedded Racket CS backend over RVT1 (POSIX fds).
//
// Same ownership contract as the Windows backend: Racket CS boots on a
// dedicated worker thread, one reader thread resolves requests and delivers
// events, and completion handlers are NOT thread-affine — GTK callers must
// dispatch to the main loop before touching widgets.
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <future>
#include <memory>
#include <optional>
#include <string>
#include <thread>

#include "rivet/protocol.hpp"

namespace fulcrum::linux_runtime {

struct RacketRuntimeConfig {
  std::string executable_path;
  std::string petite_boot;
  std::string scheme_boot;
  std::string racket_boot;
  std::string backend_bundle;
  std::string collects_dir;
  std::string config_dir;
  std::string dll_dir;  // POSIX: plain path appended to the boot config
  std::string module_name{"backend"};
  std::string entry_symbol{"start"};
  std::size_t max_pending_requests{1024};
};

struct CallResult {
  std::optional<rivet::Value> value;
  std::exception_ptr error;

  bool succeeded() const noexcept { return value.has_value() && !error; }
};

using CompletionHandler = std::function<void(CallResult)>;
using EventHandler = std::function<void(std::string const&, rivet::Value const&)>;

// Owns one embedded Racket CS instance and its RVT1 transport (socketpair).
class Backend final {
 public:
  explicit Backend(RacketRuntimeConfig config);
  ~Backend();

  Backend(Backend const&) = delete;
  Backend& operator=(Backend const&) = delete;

  void start();
  void stop();
  bool running() const noexcept;

  std::future<rivet::Value> call(std::string rpc_name,
                                 rivet::Value::List arguments = {});

  std::uint64_t request_async(std::string rpc_name,
                              rivet::Value::List arguments,
                              CompletionHandler completion);

  void cancel(std::uint64_t request_id);
  void set_event_handler(EventHandler handler);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace fulcrum::linux_runtime
