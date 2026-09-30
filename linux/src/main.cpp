// Fulcrum Linux host — GTK4 floating launcher over one embedded Racket CS
// backend, speaking RVT1 through Rivet's platform/linux runtime.
//
// Mirrors the official Linux scaffold's threading model: boot the runtime
// off the main loop behind a mutex-guarded startup handoff, dispatch every
// completion to the main loop before touching widgets, and keep shutdown
// idempotent. Launcher-specific parts (global hotkey, overlay chrome,
// clipboard watcher, single-instance activation) are honest about their
// platform reach: X11 grabs keys and sets EWMH state directly; Wayland
// compositors own those decisions, and the status bar says so.
#include <gdk/x11/gdkx.h>
#include <gtk/gtk.h>
#include <glib-unix.h>

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/keysym.h>

#include <algorithm>
#include <atomic>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "GeneratedBackend.hpp"

namespace {

constexpr char kSingleInstancePathSuffix[] = "/fulcrum/host.pid";

struct ResultRow {
  std::string id;
  std::string title;
  std::string subtitle;
  std::string kind;
  std::string arg;
  std::string icon;
  std::string hint;
  std::string badge;
};

ResultRow parse_row(std::vector<std::string> const& cells) {
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

std::filesystem::path executable_path() {
  return std::filesystem::read_symlink("/proc/self/exe");
}

struct HotkeyGrab {
  Display* display{nullptr};
  Window window{None};
};

HotkeyGrab hotkey_grab;

// ---- application state ---------------------------------------------------

struct Launcher {
  GtkWindow* window{nullptr};
  GtkSearchEntry* search{nullptr};
  GtkListBox* results{nullptr};
  GtkLabel* status{nullptr};

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::unique_ptr<rivet_app::API> api;
  std::vector<ResultRow> rows;
  guint search_source{0};

  // Official scaffold startup handoff: the boot thread publishes either a
  // started backend or an error; the main loop adopts it exactly once.
  std::mutex startup_mutex;
  std::thread startup_thread;
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  std::string startup_error;
  std::atomic<bool> shutting_down{false};

  static Launcher& instance() {
    static Launcher launcher;
    return launcher;
  }

  void set_status(std::string const& message) {
    gtk_label_set_text(status, message.c_str());
  }

  static std::string event_payload(rivet::Value const& value) {
    if (auto* list = std::get_if<rivet::Value::List>(&value.data);
        list != nullptr && !list->empty()) {
      if (auto const* text = std::get_if<std::string>(&list->back().data)) {
        return *text;
      }
    }
    return {};
  }

  void handle_event(std::string const& name, std::string const& payload) {
    if (name == "copy-to-clipboard") {
      if (GdkClipboard* clipboard =
              gtk_widget_get_clipboard(GTK_WIDGET(window))) {
        gdk_clipboard_set_text(clipboard, payload.c_str());
      }
      hide();
    } else if (name == "open-url") {
      gtk_show_uri(GTK_WINDOW(window), payload.c_str(), GDK_CURRENT_TIME);
      hide();
    } else if (name == "update-available") {
      set_status(payload);
    }
  }

  // All request/response traffic runs on short-lived worker threads; the
  // callbacks only marshal (boxed) results back through g_idle_add.

  struct SearchOutcome {
    bool ok{false};
    std::vector<ResultRow> rows;
    std::string error;
  };

  void run_search(std::string const& query) {
    if (api == nullptr || shutting_down.load(std::memory_order_acquire)) {
      return;
    }
    auto* api_raw = api.get();
    std::thread([api_raw, query]() mutable {
      auto* boxed = new SearchOutcome;
      try {
        for (auto const& cells : api_raw->search(query).get()) {
          boxed->rows.push_back(parse_row(cells));
        }
        boxed->ok = true;
      } catch (std::exception const& e) {
        boxed->error = e.what();
      }
      g_idle_add([](gpointer user_data) -> int {
        std::unique_ptr<SearchOutcome> job(
            static_cast<SearchOutcome*>(user_data));
        Launcher::instance().apply_search(std::move(*job));
        return G_SOURCE_REMOVE;
      }, boxed);
    }).detach();
  }

  void apply_search(SearchOutcome result) {
    if (!result.ok) {
      set_status("Search failed: " + result.error);
      return;
    }
    rows = std::move(result.rows);
    refresh_results();
  }

  void refresh_results() {
    // Rebuild the list; simple and correct beats incremental cleverness at
    // this list size (≤ max-results rows).
    for (GtkWidget* child = gtk_widget_get_first_child(GTK_WIDGET(results));
         child != nullptr;) {
      GtkWidget* next = gtk_widget_get_next_sibling(child);
      gtk_list_box_remove(results, child);
      child = next;
    }
    for (auto const& row : rows) {
      auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
      gtk_widget_set_margin_top(box, 6);
      gtk_widget_set_margin_bottom(box, 6);
      gtk_widget_set_margin_start(box, 10);
      gtk_widget_set_margin_end(box, 10);
      auto* title = gtk_label_new(row.title.c_str());
      gtk_label_set_xalign(GTK_LABEL(title), 0.0);
      gtk_label_set_ellipsize(GTK_LABEL(title), PANGO_ELLIPSIZE_END);
      gtk_widget_add_css_class(title, "heading");
      auto* subtitle = gtk_label_new(
          row.subtitle.empty() ? row.kind.c_str() : row.subtitle.c_str());
      gtk_label_set_xalign(GTK_LABEL(subtitle), 0.0);
      gtk_label_set_ellipsize(GTK_LABEL(subtitle), PANGO_ELLIPSIZE_END);
      gtk_widget_add_css_class(subtitle, "caption");
      gtk_widget_add_css_class(subtitle, "dim-label");
      gtk_box_append(GTK_BOX(box), title);
      gtk_box_append(GTK_BOX(box), subtitle);
      gtk_list_box_append(results, box);
    }
    if (!rows.empty()) {
      gtk_list_box_select_row(results,
                              gtk_list_box_get_row_at_index(results, 0));
    }
  }

  struct RunOutcome {
    bool success{false};
    std::string status;
  };

  void run_selected() {
    if (api == nullptr || rows.empty()) {
      return;
    }
    GtkListBoxRow* selected = gtk_list_box_get_selected_row(results);
    int index = selected != nullptr ? gtk_list_box_row_get_index(selected) : 0;
    if (index < 0 || index >= static_cast<int>(rows.size())) {
      index = 0;
    }
    ResultRow const row = rows[static_cast<std::size_t>(index)];
    set_status("Running…");
    auto* api_raw = api.get();
    std::thread([api_raw, row]() mutable {
      auto* boxed = new RunOutcome;
      try {
        boxed->status = api_raw->run_action(row.id, row.arg).get();
        boxed->success = boxed->status == "ok" ||
                         boxed->status == "launched" ||
                         boxed->status == "copied" ||
                         boxed->status == "opened";
      } catch (std::exception const& e) {
        boxed->status = e.what();
      }
      g_idle_add([](gpointer user_data) -> int {
        std::unique_ptr<RunOutcome> job(static_cast<RunOutcome*>(user_data));
        if (job->success) {
          Launcher::instance().hide();
        } else {
          Launcher::instance().set_status("Action failed: " + job->status);
        }
        return G_SOURCE_REMOVE;
      }, boxed);
    }).detach();
  }

  void show() {
    gtk_editable_set_text(GTK_EDITABLE(search), "");
    run_search("");
    gtk_widget_set_visible(GTK_WIDGET(window), TRUE);
    gtk_window_present(window);
  }

  void hide() { gtk_widget_set_visible(GTK_WIDGET(window), FALSE); }

  void toggle() {
    if (gtk_widget_get_visible(GTK_WIDGET(window))) {
      hide();
    } else {
      show();
    }
  }

  // ---- backend lifecycle -------------------------------------------------

  void start_backend() {
    // raco rivet build/dev stages runtime/*.boot and res/core.zo beside the
    // executable; that is the only layout the official CLI produces.
    std::filesystem::path const root = executable_path().parent_path();
    std::filesystem::path const petite = root / "runtime" / "petite.boot";
    std::filesystem::path const scheme = root / "runtime" / "scheme.boot";
    std::filesystem::path const racket_boot = root / "runtime" / "racket.boot";
    std::filesystem::path const core = root / "res" / "core.zo";
    if (!std::filesystem::exists(petite) ||
        !std::filesystem::exists(scheme) ||
        !std::filesystem::exists(racket_boot) ||
        !std::filesystem::exists(core)) {
      set_status("Missing Rivet runtime layout (runtime/*.boot, res/core.zo) "
                 "next to the executable. Build with raco rivet build/dev.");
      return;
    }

    rivet::linux_runtime::RacketRuntimeConfig config;
    config.executable_path = executable_path().string();
    config.petite_boot = petite.string();
    config.scheme_boot = scheme.string();
    config.racket_boot = racket_boot.string();
    config.backend_bundle = core.string();
    config.module_name = rivet_app::kModuleName;
    config.entry_symbol = rivet_app::kEntryName;

    startup_thread = std::thread([config = std::move(config)]() mutable {
      auto backend =
          std::make_unique<rivet::linux_runtime::Backend>(std::move(config));
      try {
        backend->start();
        std::lock_guard lock(Launcher::instance().startup_mutex);
        Launcher::instance().startup_backend = std::move(backend);
      } catch (std::exception const& e) {
        std::lock_guard lock(Launcher::instance().startup_mutex);
        Launcher::instance().startup_error = e.what();
      }
      g_idle_add([](gpointer) -> int {
        Launcher::instance().on_backend_ready();
        return G_SOURCE_REMOVE;
      }, nullptr);
    });
  }

  void on_backend_ready() {
    if (startup_thread.joinable()) {
      startup_thread.join();
    }

    std::unique_ptr<rivet::linux_runtime::Backend> backend;
    std::string error;
    {
      std::lock_guard lock(startup_mutex);
      backend = std::move(startup_backend);
      error = std::move(startup_error);
    }

    if (shutting_down.load(std::memory_order_acquire)) {
      if (backend != nullptr) {
        backend->stop();
      }
      return;
    }
    if (!error.empty()) {
      set_status("Fulcrum backend failed to start: " + error);
      return;
    }
    if (backend == nullptr) {
      set_status("Fulcrum backend error: startup completed without a backend");
      return;
    }

    backend_ = std::move(backend);
    api = std::make_unique<rivet_app::API>(*backend_);

    backend_->set_event_handler(
        [](std::string const& name, rivet::Value const& value) {
          auto* job = new std::pair<std::string, std::string>(
              name, event_payload(value));
          g_idle_add([](gpointer user_data) -> int {
            std::unique_ptr<std::pair<std::string, std::string>> payload(
                static_cast<std::pair<std::string, std::string>*>(user_data));
            Launcher::instance().handle_event(payload->first, payload->second);
            return G_SOURCE_REMOVE;
          }, job);
        });

    set_status("Ready — hotkey or `fulcrum --toggle`");
    run_search("");
  }

  void stop_backend() {
    shutting_down.store(true, std::memory_order_release);
    if (startup_thread.joinable()) {
      startup_thread.join();
    }
    if (backend_ != nullptr) {
      backend_->stop();
    }
  }

 private:
  std::unique_ptr<rivet::linux_runtime::Backend> backend_;
};

// ---- X11 global hotkey ----------------------------------------------------

gboolean on_x11_hotkey(GIOChannel*, GIOCondition, gpointer) {
  Launcher::instance().toggle();
  // Drain pending X events for the connection.
  while (XPending(hotkey_grab.display) > 0) {
    XEvent event;
    XNextEvent(hotkey_grab.display, &event);
  }
  return G_SOURCE_CONTINUE;
}

std::string install_x11_hotkey(GdkDisplay* display, GtkWindow* window) {
  if (GDK_IS_X11_DISPLAY(display) == 0) {
    return "Wayland session: compositors do not allow global key grabs. "
           "Bind `fulcrum --toggle` to a key in your compositor settings.";
  }
  hotkey_grab.display = gdk_x11_display_get_xdisplay(display);
  hotkey_grab.window =
      gdk_x11_surface_get_xid(gtk_native_get_surface(GTK_NATIVE(window)));
  Display* dpy = hotkey_grab.display;

  KeyCode code = XKeysymToKeycode(dpy, XK_space);
  if (code == 0) {
    return "X11 hotkey setup failed: cannot resolve the Space keycode.";
  }
  XGrabKey(dpy, code, Mod1Mask, hotkey_grab.window, True, GrabModeAsync,
           GrabModeAsync);
  XGrabKey(dpy, code, Mod1Mask | Mod2Mask, hotkey_grab.window, True,
           GrabModeAsync, GrabModeAsync);  // with NumLock
  XSelectInput(dpy, hotkey_grab.window, KeyPressMask);

  int x11_fd = ConnectionNumber(dpy);
  GIOChannel* channel = g_io_channel_unix_new(x11_fd);
  g_io_add_watch(channel, G_IO_IN, on_x11_hotkey, nullptr);
  g_io_channel_unref(channel);
  return "";
}

// ---- single instance via pid file + SIGUSR1 -------------------------------

std::filesystem::path pid_path() {
  char const* data_dir = std::getenv("FULCRUM_DATA_DIR");
  std::filesystem::path base =
      data_dir != nullptr && *data_dir != '\0'
          ? std::filesystem::path{data_dir}
          : (std::getenv("XDG_RUNTIME_DIR") != nullptr
                 ? std::filesystem::path{std::getenv("XDG_RUNTIME_DIR")}
                 : std::filesystem::path{"/tmp"});
  return base / kSingleInstancePathSuffix;
}

void write_pid() {
  std::filesystem::create_directories(pid_path().parent_path());
  std::ofstream out(pid_path());
  out << getpid();
}

gboolean on_sigusr1(gpointer) {
  Launcher::instance().show();
  return G_SOURCE_CONTINUE;
}

// ---- GTK wiring -----------------------------------------------------------

void on_search_changed(GtkSearchEntry*, gpointer) {
  Launcher& launcher = Launcher::instance();
  if (launcher.search_source != 0) {
    g_source_remove(launcher.search_source);
  }
  // Debounce fast typing.
  launcher.search_source =
      g_timeout_add(120, [](gpointer) -> int {
        Launcher& l = Launcher::instance();
        l.search_source = 0;
        l.run_search(gtk_editable_get_text(GTK_EDITABLE(l.search)));
        return G_SOURCE_REMOVE;
      }, nullptr);
}

void on_row_activated(GtkListBox*, GtkListBoxRow*, gpointer) {
  Launcher::instance().run_selected();
}

gboolean on_key_pressed(GtkEventControllerKey*, guint keyval, guint,
                        GdkModifierType, gpointer) {
  switch (keyval) {
    case GDK_KEY_Escape:
      Launcher::instance().hide();
      return TRUE;
    case GDK_KEY_Down:
    case GDK_KEY_Up: {
      Launcher& launcher = Launcher::instance();
      int const delta = keyval == GDK_KEY_Down ? 1 : -1;
      GtkListBoxRow* current = gtk_list_box_get_selected_row(launcher.results);
      int index = current != nullptr ? gtk_list_box_row_get_index(current) : 0;
      index = std::clamp(index + delta, 0,
                         static_cast<int>(launcher.rows.size()) - 1);
      if (!launcher.rows.empty()) {
        gtk_list_box_select_row(launcher.results,
                                gtk_list_box_get_row_at_index(launcher.results,
                                                              index));
      }
      return TRUE;
    }
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter:
      Launcher::instance().run_selected();
      return TRUE;
    default:
      return FALSE;
  }
}

void on_window_active_changed(GObject* obj, GParamSpec*, gpointer) {
  auto* gtk_window = GTK_WINDOW(obj);
  // Hide on focus loss, matching the other platform hosts.
  if (!gtk_window_is_active(gtk_window) &&
      gtk_widget_get_visible(GTK_WIDGET(gtk_window))) {
    Launcher::instance().hide();
  }
}

void on_activate(GtkApplication* app, gpointer) {
  Launcher& launcher = Launcher::instance();

  auto* window = gtk_application_window_new(app);
  launcher.window = GTK_WINDOW(window);
  gtk_window_set_title(launcher.window, "Fulcrum");
  gtk_window_set_default_size(launcher.window, 680, 440);
  gtk_window_set_resizable(launcher.window, FALSE);
  gtk_window_set_hide_on_close(launcher.window, FALSE);
  gtk_widget_add_css_class(window, "fulcrum-window");

  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  auto* search = gtk_search_entry_new();
  gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(search),
                                        "Search apps, clipboard, snippets, the web…");
  gtk_widget_set_margin_top(search, 10);
  gtk_widget_set_margin_start(search, 10);
  gtk_widget_set_margin_end(search, 10);
  launcher.search = GTK_SEARCH_ENTRY(search);

  auto* status = gtk_label_new("Starting embedded Racket CS…");
  gtk_label_set_xalign(GTK_LABEL(status), 0.0);
  gtk_widget_set_margin_start(status, 12);
  gtk_widget_set_margin_top(status, 6);
  launcher.status = GTK_LABEL(status);

  auto* scrolled = gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                 GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  auto* results = gtk_list_box_new();
  gtk_list_box_set_selection_mode(GTK_LIST_BOX(results), GTK_SELECTION_SINGLE);
  gtk_list_box_set_activate_on_single_click(GTK_LIST_BOX(results), FALSE);
  launcher.results = GTK_LIST_BOX(results);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), results);

  auto* hint = gtk_label_new("↑↓ navigate · ↵ run · esc hide — Fulcrum");
  gtk_label_set_xalign(GTK_LABEL(hint), 0.0);
  gtk_widget_add_css_class(hint, "caption");
  gtk_widget_add_css_class(hint, "dim-label");
  gtk_widget_set_margin_start(hint, 12);
  gtk_widget_set_margin_top(hint, 4);
  gtk_widget_set_margin_bottom(hint, 8);

  gtk_box_append(GTK_BOX(root), search);
  gtk_box_append(GTK_BOX(root), status);
  gtk_box_append(GTK_BOX(root), scrolled);
  gtk_box_append(GTK_BOX(root), hint);
  gtk_window_set_child(launcher.window, root);

  g_signal_connect(search, "search-changed",
                   G_CALLBACK(on_search_changed), nullptr);
  g_signal_connect(results, "row-activated",
                   G_CALLBACK(on_row_activated), nullptr);

  auto* controller = gtk_event_controller_key_new();
  g_signal_connect(controller, "key-pressed", G_CALLBACK(on_key_pressed),
                   nullptr);
  gtk_widget_add_controller(window, controller);

  g_signal_connect(window, "notify::is-active",
                   G_CALLBACK(on_window_active_changed), nullptr);

  // Realize once so the XID exists, then install the overlay chrome (X11
  // only, through EWMH) and the platform hotkey. Wayland compositors own
  // those decisions; the status message covers that honestly.
  gtk_widget_realize(window);
  if (GDK_IS_X11_DISPLAY(gtk_widget_get_display(window))) {
    Display* dpy =
        gdk_x11_display_get_xdisplay(gtk_widget_get_display(window));
    Window xid = gdk_x11_surface_get_xid(
        gtk_native_get_surface(GTK_NATIVE(window)));
    Atom wm_state = XInternAtom(dpy, "_NET_WM_STATE", False);
    Atom above = XInternAtom(dpy, "_NET_WM_STATE_ABOVE", False);
    Atom skip_taskbar = XInternAtom(dpy, "_NET_WM_STATE_SKIP_TASKBAR", False);
    Atom wm_window_type = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
    Atom utility = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_UTILITY", False);
    XChangeProperty(dpy, xid, wm_window_type, XA_ATOM, 32, PropModeReplace,
                    reinterpret_cast<unsigned char*>(&utility), 1);
    XChangeProperty(dpy, xid, wm_state, XA_ATOM, 32, PropModeAppend,
                    reinterpret_cast<unsigned char*>(&above), 1);
    XChangeProperty(dpy, xid, wm_state, XA_ATOM, 32, PropModeAppend,
                    reinterpret_cast<unsigned char*>(&skip_taskbar), 1);
  }
  std::string hotkey_note =
      install_x11_hotkey(gtk_widget_get_display(window), launcher.window);
  if (!hotkey_note.empty()) {
    launcher.set_status(hotkey_note);
  }

  write_pid();
  g_unix_signal_add(SIGUSR1, on_sigusr1, nullptr);

  launcher.start_backend();
}

void on_shutdown(GApplication*, gpointer) {
  Launcher::instance().stop_backend();
}

}  // namespace

int main(int argc, char** argv) {
  std::signal(SIGUSR1, SIG_IGN);  // handled through the GSource instead

  for (int i = 1; i < argc; ++i) {
    if (std::string{argv[i]} == "--toggle") {
      std::ifstream pid_file(pid_path());
      if (!pid_file) {
        std::cerr << "fulcrum: no running instance\n";
        return 1;
      }
      pid_t pid = 0;
      pid_file >> pid;
      if (pid <= 0 || kill(pid, SIGUSR1) != 0) {
        std::cerr << "fulcrum: running instance not reachable\n";
        return 1;
      }
      return 0;
    }
  }

  XInitThreads();
  auto* app =
      gtk_application_new("site.jrtx.fulcrum", G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), nullptr);
  int const status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
