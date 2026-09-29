// Fulcrum Linux host — GTK4 floating launcher.
//
// Platform honesty: on X11 the global hotkey is grabbed with XGrabKey; on
// Wayland, compositors do not allow clients to grab global keys, so the
// status bar says so and the same toggle is exposed as
// `fulcrum --toggle` for a compositor keybinding. This is the documented
// gap, not a hidden fallback.
#include "posix_backend.hpp"

#include <gtk/gtk.h>
#include <gdk/x11/gdkx.h>
#include <glib-unix.h>

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/keysym.h>

#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

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

rivet::Value::List parse_rows(rivet::Value const& value) {
  if (auto* list = std::get_if<rivet::Value::List>(&value.data)) {
    return *list;
  }
  return {};
}

ResultRow parse_row(rivet::Value const& value) {
  ResultRow row;
  if (auto* cells = std::get_if<rivet::Value::List>(&value.data);
      cells != nullptr && cells->size() == 8) {
    auto text = [](rivet::Value const& v) -> std::string {
      if (auto const* s = std::get_if<std::string>(&v.data)) return *s;
      return {};
    };
    row.id = text((*cells)[0]);
    row.title = text((*cells)[1]);
    row.subtitle = text((*cells)[2]);
    row.kind = text((*cells)[3]);
    row.arg = text((*cells)[4]);
    row.icon = text((*cells)[5]);
    row.hint = text((*cells)[6]);
    row.badge = text((*cells)[7]);
  }
  return row;
}

std::filesystem::path executable_path() {
  return std::filesystem::read_symlink("/proc/self/exe");
}

struct RacketLayout {
  std::filesystem::path petite_boot;
  std::filesystem::path scheme_boot;
  std::filesystem::path racket_boot;
  std::filesystem::path core;
  std::filesystem::path root;
};

std::optional<RacketLayout> discover_runtime_layout() {
  // Packaged layout: <prefix>/lib/fulcrum/{runtime,res}; dev layout:
  // .rivet/build/linux/…/runtime next to the executable.
  std::vector<std::filesystem::path> roots;
  auto const exe = executable_path();
  roots.push_back(exe.parent_path());
  roots.push_back(exe.parent_path() / ".." / "lib" / "fulcrum");
  for (auto const& root : roots) {
    RacketLayout layout{
        root / "runtime" / "petite.boot",
        root / "runtime" / "scheme.boot",
        root / "runtime" / "racket.boot",
        root / "res" / "core.zo",
        root,
    };
    if (std::filesystem::exists(layout.petite_boot) &&
        std::filesystem::exists(layout.scheme_boot) &&
        std::filesystem::exists(layout.racket_boot) &&
        std::filesystem::exists(layout.core)) {
      return layout;
    }
  }
  return std::nullopt;
}

// ---- application state ---------------------------------------------------

class Launcher {
 public:
  GtkWindow* window{nullptr};
  GtkSearchEntry* search{nullptr};
  GtkListBox* results{nullptr};
  GtkLabel* status{nullptr};
  GtkStack* stack{nullptr};

  std::unique_ptr<fulcrum::linux_runtime::Backend> backend;
  std::vector<ResultRow> rows;
  guint search_source{0};

  static Launcher& instance() {
    static Launcher launcher;
    return launcher;
  }

  void set_status(std::string const& message) {
    gtk_label_set_text(status, message.c_str());
  }

  void start_backend() {
    auto layout = discover_runtime_layout();
    if (!layout.has_value()) {
      set_status("Fulcrum runtime files are missing next to the executable "
                 "(runtime/*.boot and res/core.zo). Reinstall Fulcrum.");
      return;
    }

    fulcrum::linux_runtime::RacketRuntimeConfig config;
    config.executable_path = executable_path().string();
    config.petite_boot = layout->petite_boot.string();
    config.scheme_boot = layout->scheme_boot.string();
    config.racket_boot = layout->racket_boot.string();
    config.backend_bundle = layout->core.string();
    config.dll_dir = (layout->root / "runtime").string();
    config.module_name = "backend";
    config.entry_symbol = "start";

    try {
      backend = std::make_unique<fulcrum::linux_runtime::Backend>(std::move(config));
      backend->set_event_handler([](std::string const& name,
                                    rivet::Value const& value) {
        g_idle_add([](gpointer user_data) -> int {
          auto* job = static_cast<std::pair<std::string, std::string>*>(user_data);
          Launcher::instance().handle_event(job->first, job->second);
          delete job;
          return G_SOURCE_REMOVE;
        }, new std::pair<std::string, std::string>(name, event_payload(value)));
      });
      backend->start();
    } catch (std::exception const& e) {
      set_status(std::string{"Fulcrum backend failed to start: "} + e.what());
      return;
    }
    set_status("Ready — hotkey or `fulcrum --toggle`");
    run_search("");
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

  void run_search(std::string const& query) {
    if (backend == nullptr) {
      return;
    }
    auto* backend_raw = backend.get();
    backend_raw->request_async(
        "search",
        rivet::Value::List{rivet::Value(query)},
        [](fulcrum::linux_runtime::CallResult result) {
          auto* boxed = new fulcrum::linux_runtime::CallResult(std::move(result));
          g_idle_add([](gpointer user_data) -> int {
            std::unique_ptr<fulcrum::linux_runtime::CallResult> job(
                static_cast<fulcrum::linux_runtime::CallResult*>(user_data));
            Launcher::instance().apply_search(std::move(*job));
            return G_SOURCE_REMOVE;
          }, boxed);
        });
  }

  void apply_search(fulcrum::linux_runtime::CallResult result) {
    if (!result.succeeded()) {
      try {
        std::rethrow_exception(result.error);
      } catch (std::exception const& e) {
        set_status(std::string{"Search failed: "} + e.what());
      }
      return;
    }
    rows.clear();
    for (auto const& cell : parse_rows(*result.value)) {
      rows.push_back(parse_row(cell));
    }
    refresh_results();
  }

  void refresh_results() {
    // Rebuild the list; simple and correct beats incremental cleverness at
    // this list size (≤ 12 rows).
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
      gtk_widget_add_css_class(title, "heading");
      gtk_widget_add_css_class(title, "title-4");
      auto* subtitle = gtk_label_new(
          row.subtitle.empty() ? row.kind.c_str() : row.subtitle.c_str());
      gtk_label_set_xalign(GTK_LABEL(subtitle), 0.0);
      gtk_widget_add_css_class(subtitle, "caption");
      gtk_widget_add_css_class(subtitle, "dim-label");
      gtk_label_set_ellipsize(GTK_LABEL(title), PANGO_ELLIPSIZE_END);
      gtk_label_set_ellipsize(GTK_LABEL(subtitle), PANGO_ELLIPSIZE_END);
      gtk_box_append(GTK_BOX(box), title);
      gtk_box_append(GTK_BOX(box), subtitle);
      gtk_list_box_append(results, box);
    }
    if (!rows.empty()) {
      gtk_list_box_select_row(results,
                              gtk_list_box_get_row_at_index(results, 0));
    }
  }

  void run_selected() {
    if (backend == nullptr || rows.empty()) {
      return;
    }
    GtkListBoxRow* selected = gtk_list_box_get_selected_row(results);
    int index = selected != nullptr ? gtk_list_box_row_get_index(selected) : 0;
    if (index < 0 || index >= static_cast<int>(rows.size())) {
      index = 0;
    }
    ResultRow const row = rows[static_cast<std::size_t>(index)];
    set_status("Running…");
    backend->request_async(
        "run-action",
        rivet::Value::List{rivet::Value(row.id), rivet::Value(row.arg)},
        [row](fulcrum::linux_runtime::CallResult result) {
          std::string status_text = row.id;
          bool success = false;
          if (result.succeeded()) {
            if (auto const* text = std::get_if<std::string>(&result.value->data)) {
              status_text = *text;
              success = status_text == "ok" || status_text == "launched" ||
                        status_text == "copied" || status_text == "opened";
            }
          } else {
            try {
              std::rethrow_exception(result.error);
            } catch (std::exception const& e) {
              status_text = e.what();
            }
          }
          auto* boxed = new std::pair<std::string, bool>(status_text, success);
          g_idle_add([](gpointer user_data) -> int {
            std::unique_ptr<std::pair<std::string, bool>> job(
                static_cast<std::pair<std::string, bool>*>(user_data));
            if (job->second) {
              Launcher::instance().hide();
            } else {
              Launcher::instance().set_status("Action failed: " + job->first);
            }
            return G_SOURCE_REMOVE;
          }, boxed);
        });
  }

  void show() {
    gtk_editable_set_text(GTK_EDITABLE(search), "");
    run_search("");
    gtk_widget_set_visible(GTK_WIDGET(window), TRUE);
    gtk_window_present(GTK_WINDOW(window));
  }

  void hide() { gtk_widget_set_visible(GTK_WIDGET(window), FALSE); }

  void toggle() {
    if (gtk_widget_get_visible(GTK_WIDGET(window))) {
      hide();
    } else {
      show();
    }
  }
};

// ---- X11 global hotkey ----------------------------------------------------

struct HotkeyGrab {
  Display* display{nullptr};
  Window window{None};
  bool grabbed{false};
};

HotkeyGrab hotkey_grab;

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
  // GTK4: windows expose a GdkSurface; X11 surfaces carry the XID.
  hotkey_grab.window = gdk_x11_surface_get_xid(
      gtk_native_get_surface(GTK_NATIVE(window)));
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
  hotkey_grab.grabbed = true;
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
  gtk_window_set_child(GTK_WINDOW(window), root);

  g_signal_connect(search, "search-changed",
                   G_CALLBACK(on_search_changed), nullptr);
  g_signal_connect(results, "row-activated",
                   G_CALLBACK(on_row_activated), nullptr);

  auto* controller = gtk_event_controller_key_new();
  g_signal_connect(controller, "key-pressed", G_CALLBACK(on_key_pressed), nullptr);
  gtk_widget_add_controller(window, controller);

  g_signal_connect(window, "notify::is-active",
                   G_CALLBACK(on_window_active_changed), nullptr);

  // Realize once so the XID exists, then install the platform hotkey and
  // (X11 only) the overlay chrome via EWMH. Wayland compositors own these
  // decisions; the status message already covers that honestly.
  gtk_widget_realize(window);
  if (GDK_IS_X11_DISPLAY(gtk_widget_get_display(window))) {
    Display* dpy = gdk_x11_display_get_xdisplay(gtk_widget_get_display(window));
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
      install_x11_hotkey(gtk_widget_get_display(window), GTK_WINDOW(window));
  if (!hotkey_note.empty()) {
    launcher.set_status(hotkey_note);
  }

  write_pid();
  g_unix_signal_add(SIGUSR1, on_sigusr1, nullptr);

  launcher.start_backend();
  launcher.run_search("");
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
  auto* app = gtk_application_new("site.jrtx.fulcrum", G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  int const status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
