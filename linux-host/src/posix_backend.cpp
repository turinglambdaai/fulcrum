#include "posix_backend.hpp"

#include <fcntl.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>

#include <condition_variable>
#include <cstring>
#include <map>
#include <mutex>
#include <stdexcept>
#include <utility>
#include <vector>

// racketcs C API (same entry points the Windows backend uses; libracketcs
// exports them on every platform).
extern "C" {
struct racket_boot_arguments_t {
  char const* boot1_path;
  char const* boot2_path;
  char const* boot3_path;
  char const* exec_file;
  char const* collects_dir;
  char const* config_dir;
  char const* dll_dir;
  void* reserved1;
  void* reserved2;
};

void racket_boot(racket_boot_arguments_t* args);
void racket_embedded_load_file(char const* filename, int with_path);
void* racket_dynamic_require(char const* quoted_module_symbol, char const* symbol);
void* racket_apply(void* procedure, void* args);
void* Scons(void* a, void* d);
void* Snil();
void* Sfixnum(long v);
void* Sstring_to_symbol(char const* s);
void* Scar(void* pair);
int Sscheme_deinit();
}

namespace fulcrum::linux {
namespace {

// A rivet::Transport over a POSIX fd. Ownership is explicit: the long-lived
// reader transport owns its fd, while per-request transports borrow it.
class FdTransport final : public rivet::Transport {
 public:
  FdTransport(int fd, bool own) : fd_(fd), own_(own) {}
  ~FdTransport() override {
    if (own_ && fd_ >= 0) ::close(fd_);
  }

  bool read_exact(std::uint8_t* destination, std::size_t size) override {
    std::size_t done = 0;
    while (done < size) {
      ssize_t n = ::read(fd_, destination + done, size - done);
      if (n == 0) {
        return done == 0;  // clean EOF before any byte
      }
      if (n < 0) {
        if (errno == EINTR) continue;
        return false;
      }
      done += static_cast<std::size_t>(n);
    }
    return true;
  }

  void write_all(std::uint8_t const* source, std::size_t size) override {
    std::size_t done = 0;
    while (done < size) {
      ssize_t n = ::write(fd_, source + done, size - done);
      if (n < 0) {
        if (errno == EINTR) continue;
        throw std::runtime_error("RVT1 transport write failed");
      }
      done += static_cast<std::size_t>(n);
    }
  }

  void flush() override {}

 private:
  int fd_;
  bool own_;
};

// Cancelable one-shot pipe waiter: reading one byte from a pipe that
// shutdown writes to unblocks poll without racing fd teardown.
class WakeupPipe {
 public:
  WakeupPipe() {
    if (::pipe(fds_) != 0) {
      fds_[0] = fds_[1] = -1;
    }
  }
  ~WakeupPipe() {
    for (int& fd : fds_) {
      if (fd >= 0) ::close(fd);
    }
  }
  int read_fd() const { return fds_[0]; }
  void signal() {
    if (fds_[1] >= 0) {
      char byte = 1;
      ssize_t ignored = ::write(fds_[1], &byte, 1);
      (void)ignored;
    }
  }

 private:
  int fds_[2]{-1, -1};
};

}  // namespace

struct Backend::Impl {
  RacketRuntimeConfig config;
  std::atomic<bool> running{false};

  std::mutex state_mutex;
  std::map<std::uint64_t, CompletionHandler> pending;
  std::uint64_t next_request_id{1};
  EventHandler event_handler;

  int request_fd{-1};   // our end of the RVT1 socketpair
  int response_fd{-1};  // same fd today; kept distinct for future split
  WakeupPipe cancel_wakeup;

  std::thread racket_thread;
  std::thread reader_thread;

  explicit Impl(RacketRuntimeConfig cfg) : config(std::move(cfg)) {}

  std::uint64_t allocate_request_id() {
    std::lock_guard lock(state_mutex);
    return next_request_id++;
  }

  void resolve_request(std::uint64_t id, rivet::Value value) {
    CompletionHandler handler;
    {
      std::lock_guard lock(state_mutex);
      auto it = pending.find(id);
      if (it == pending.end()) return;
      handler = std::move(it->second);
      pending.erase(it);
    }
    handler(CallResult{std::move(value), nullptr});
  }

  void fail_request(std::uint64_t id, std::exception_ptr error) {
    CompletionHandler handler;
    {
      std::lock_guard lock(state_mutex);
      auto it = pending.find(id);
      if (it == pending.end()) return;
      handler = std::move(it->second);
      pending.erase(it);
    }
    handler(CallResult{std::nullopt, std::move(error)});
  }

  void fail_all(std::exception_ptr error) {
    std::map<std::uint64_t, CompletionHandler> drained;
    {
      std::lock_guard lock(state_mutex);
      drained = std::move(pending);
      pending.clear();
    }
    for (auto& [id, handler] : drained) {
      handler(CallResult{std::nullopt, error});
    }
  }

  void racket_main() noexcept {
    // One socketpair carries the whole RVT1 connection: we write Requests to
    // socket_fds[0] and the backend reads them from socket_fds[1]; the
    // backend writes to socket_fds[1] and our reader reads socket_fds[0].
    int socket_fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, socket_fds) != 0) {
      running.store(false, std::memory_order_release);
      return;
    }
    int backend_in = socket_fds[1];   // backend reads requests
    int backend_out = socket_fds[1];  // single duplex socket: same fd
    request_fd = socket_fds[0];
    response_fd = socket_fds[0];

    try {
      racket_boot_arguments_t boot{};
      std::memset(&boot, 0, sizeof(boot));
      boot.boot1_path = config.petite_boot.c_str();
      boot.boot2_path = config.scheme_boot.c_str();
      boot.boot3_path = config.racket_boot.c_str();
      boot.exec_file = config.executable_path.c_str();
      boot.collects_dir = config.collects_dir.empty() ? nullptr
                                                      : config.collects_dir.c_str();
      boot.config_dir = config.config_dir.empty() ? nullptr
                                                  : config.config_dir.c_str();
      boot.dll_dir = config.dll_dir.empty() ? nullptr : config.dll_dir.c_str();

      racket_boot(&boot);
      racket_embedded_load_file(config.backend_bundle.c_str(), 1);

      auto const module = Sstring_to_symbol(config.module_name.c_str());
      auto const entry = Sstring_to_symbol(config.entry_symbol.c_str());
      auto const results = racket_dynamic_require(module, entry);
      auto const procedure = Scar(results);
      // serve-fds consumes the two fd numbers as fixnums; the backend port
      // owns the socket fd from here on.
      auto const args = Scons(Sfixnum(backend_in),
                              Scons(Sfixnum(backend_out), Snil));
      (void)racket_apply(procedure, args);
      Sscheme_deinit();
    } catch (...) {
      // Closing our end makes the native reader observe EOF and shut down.
    }

    running.store(false, std::memory_order_release);
    cancel_wakeup.signal();
  }

  void reader_main() noexcept {
    auto transport = std::make_unique<FdTransport>(response_fd, /*own=*/false);
    try {
      for (;;) {
        auto frame = rivet::read_frame(*transport);
        if (!frame.has_value()) {
          break;
        }
        switch (frame->type) {
          case rivet::MessageType::Hello:
            running.store(true, std::memory_order_release);
            break;
          case rivet::MessageType::Response:
            resolve_request(frame->id, rivet::decode_value(frame->payload));
            break;
          case rivet::MessageType::Error: {
            auto error_value = rivet::decode_value(frame->payload);
            std::string message{"Fulcrum backend error"};
            if (auto* text = std::get_if<std::string>(&error_value.data)) {
              message = *text;
            }
            fail_request(frame->id,
                         std::make_exception_ptr(std::runtime_error(std::move(message))));
            break;
          }
          case rivet::MessageType::Event: {
            auto event_value = rivet::decode_value(frame->payload);
            EventHandler handler;
            {
              std::lock_guard lock(state_mutex);
              handler = event_handler;
            }
            if (handler) {
              if (auto* list = std::get_if<rivet::Value::List>(&event_value.data);
                  list != nullptr && !list->empty()) {
                if (auto* name = std::get_if<std::string>(&(*list)[0].data)) {
                  rivet::Value payload =
                      list->size() > 1 ? (*list)[1] : rivet::Value(std::string{});
                  handler(*name, payload);
                }
              }
            }
            break;
          }
          default:
            break;
        }
      }
    } catch (...) {
      // transport dead: fall through to failure delivery
    }
    fail_all(std::make_exception_ptr(
        std::runtime_error("Fulcrum backend transport closed")));
  }
};

Backend::Backend(RacketRuntimeConfig config)
    : impl_(std::make_unique<Impl>(std::move(config))) {}

Backend::~Backend() { stop(); }

void Backend::start() {
  if (impl_->running.load(std::memory_order_relaxed)) {
    throw std::runtime_error("Fulcrum backend is already running");
  }
  impl_->running.store(true, std::memory_order_release);
  impl_->racket_thread = std::thread([impl = impl_.get()]() mutable {
    impl->racket_main();
  });
  impl_->reader_thread = std::thread([impl = impl_.get()]() mutable {
    impl->reader_main();
  });

  // Wait for Hello (bounded) so startup failures surface synchronously.
  auto const deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
  while (!impl_->running.load(std::memory_order_acquire)) {
    if (std::chrono::steady_clock::now() > deadline) {
      stop();
      throw std::runtime_error("Fulcrum backend did not reach Hello within 20s");
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    if (!impl_->racket_thread.joinable()) {
      throw std::runtime_error("Fulcrum backend thread failed to start");
    }
  }
}

void Backend::stop() {
  // Shutdown frame, then join both threads. Safe to call twice. The request
  // socket end stays open until the backend port consumes EOF.
  if (impl_->request_fd >= 0) {
    try {
      FdTransport transport(impl_->request_fd, /*own=*/false);
      rivet::write_frame(transport,
                         rivet::Frame{rivet::MessageType::Shutdown, 0, {}});
      transport.flush();
    } catch (...) {
    }
  }
  impl_->cancel_wakeup.signal();
  if (impl_->racket_thread.joinable()) impl_->racket_thread.join();
  if (impl_->reader_thread.joinable()) impl_->reader_thread.join();
  impl_->fail_all(std::make_exception_ptr(
      std::runtime_error("Fulcrum backend stopped")));
}

std::future<rivet::Value> Backend::call(std::string rpc_name,
                                        rivet::Value::List arguments) {
  auto const id = impl_->allocate_request_id();
  auto promise = std::make_shared<std::promise<rivet::Value>>();
  auto future = promise->get_future();
  {
    std::lock_guard lock(impl_->state_mutex);
    impl_->pending[id] = [promise](CallResult result) mutable {
      if (result.succeeded()) {
        promise->set_value(std::move(*result.value));
      } else {
        std::rethrow_exception(result.error);
      }
    };
  }
  rivet::Value::List request;
  request.emplace_back(std::move(rpc_name));
  for (auto& argument : arguments) {
    request.emplace_back(std::move(argument));
  }
  try {
    FdTransport transport(impl_->request_fd, /*own=*/false);
    rivet::write_frame(transport,
                       rivet::Frame{rivet::MessageType::Request, id,
                                    rivet::encode_value(rivet::Value(std::move(request)))});
    transport.flush();
  } catch (...) {
    impl_->fail_request(id, std::current_exception());
  }
  return future;
}

std::uint64_t Backend::request_async(std::string rpc_name,
                                     rivet::Value::List arguments,
                                     CompletionHandler completion) {
  auto const id = impl_->allocate_request_id();
  {
    std::lock_guard lock(impl_->state_mutex);
    impl_->pending[id] = std::move(completion);
  }
  rivet::Value::List request;
  request.emplace_back(std::move(rpc_name));
  for (auto& argument : arguments) {
    request.emplace_back(std::move(argument));
  }
  try {
    FdTransport transport(impl_->request_fd, /*own=*/false);
    rivet::write_frame(transport,
                       rivet::Frame{rivet::MessageType::Request, id,
                                    rivet::encode_value(rivet::Value(std::move(request)))});
    transport.flush();
  } catch (...) {
    impl_->fail_request(id, std::current_exception());
  }
  return id;
}

void Backend::cancel(std::uint64_t request_id) {
  try {
    FdTransport transport(impl_->request_fd, /*own=*/false);
    rivet::write_frame(transport,
                       rivet::Frame{rivet::MessageType::Cancel, request_id, {}});
    transport.flush();
  } catch (...) {
  }
}

void Backend::set_event_handler(EventHandler handler) {
  std::lock_guard lock(impl_->state_mutex);
  impl_->event_handler = std::move(handler);
}

}  // namespace fulcrum::linux
