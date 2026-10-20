// Exercise the real launcher widgets without starting its embedded backend.
#define main fulcrum_host_main
#include "../linux/src/main.cpp"
#undef main

namespace {
int failures = 0;

void check(bool condition, char const* message) {
  std::cout << (condition ? "PASS: " : "FAIL: ") << message << '\n';
  if (!condition) ++failures;
}

void pump(int milliseconds) {
  auto end = std::chrono::steady_clock::now() +
             std::chrono::milliseconds(milliseconds);
  do {
    while (g_main_context_iteration(nullptr, FALSE)) {}
    g_usleep(1000);
  } while (std::chrono::steady_clock::now() < end);
}

bool selected_row_is_visible(GtkListBox* results, GtkWidget* scrolled, int index) {
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(1);
  do {
    // GTK scroll/layout updates may complete on a later frame in CI.
    pump(10);
    auto* selected = gtk_list_box_get_selected_row(results);
    graphene_rect_t bounds{};
    if (selected != nullptr && gtk_list_box_row_get_index(selected) == index &&
        gtk_widget_compute_bounds(GTK_WIDGET(selected), scrolled, &bounds) &&
        bounds.origin.y >= -1 &&
        bounds.origin.y + bounds.size.height <= gtk_widget_get_height(scrolled) + 1)
      return true;
  } while (std::chrono::steady_clock::now() < deadline);
  return false;
}

bool has_label(GtkWidget* widget, char const* text) {
  if (GTK_IS_LABEL(widget) &&
      std::string(gtk_label_get_text(GTK_LABEL(widget))) == text) return true;
  for (auto* child = gtk_widget_get_first_child(widget); child != nullptr;
       child = gtk_widget_get_next_sibling(child)) {
    if (has_label(child, text)) return true;
  }
  return false;
}

void focus(GtkWindow* window) {
  // Set up a stable focus owner before exercising focus transitions below.
  g_signal_handlers_block_by_func(window,
      reinterpret_cast<gpointer>(on_window_active_changed), nullptr);
  gtk_window_present(window);
  pump(40);
  auto* surface = gtk_native_get_surface(GTK_NATIVE(window));
  auto* display = gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
  XSetInputFocus(display, gdk_x11_surface_get_xid(surface), RevertToParent,
                 CurrentTime);
  XSync(display, False);
  pump(40);
  g_signal_handlers_unblock_by_func(window,
      reinterpret_cast<gpointer>(on_window_active_changed), nullptr);
}
}  // namespace

int main() {
  std::cout << std::unitbuf;
  XInitThreads();
  load_i18n(executable_path().parent_path());
  gtk_init();
  auto* app = gtk_application_new("site.jrtx.fulcrum.ui-test",
                                   G_APPLICATION_NON_UNIQUE);
  g_application_register(G_APPLICATION(app), nullptr, nullptr);
  on_activate(app, nullptr);
  auto& launcher = Launcher::instance();
  // The test executable has no adjacent runtime: startup stops before boot.
  check(launcher.api == nullptr, "UI fixture does not start the backend");
  launcher.rows.clear();
  for (int i = 0; i < 12; ++i) {
    launcher.rows.push_back(parse_row({"settings.set", "Option " + std::to_string(i),
        "Select to cycle", "Setting", "option-" + std::to_string(i),
        "setting", "", "system"}));
  }
  launcher.refresh_results();
  focus(launcher.window);
  pump(80);
  auto* scrolled = gtk_widget_get_ancestor(GTK_WIDGET(launcher.results),
                                          GTK_TYPE_SCROLLED_WINDOW);
  auto* first = gtk_list_box_get_row_at_index(launcher.results, 0);
  check(gtk_widget_get_height(scrolled) >= 3 * gtk_widget_get_height(GTK_WIDGET(first)),
        "results viewport shows multiple candidates");
  check(has_label(GTK_WIDGET(first), "system"), "current setting badge is rendered");
  launcher.rows.back().badge.clear();
  launcher.refresh_results();
  pump(40);
  check(has_label(GTK_WIDGET(gtk_list_box_get_row_at_index(launcher.results, 11)),
                  "Not set"), "empty setting values have an explicit state");

  for (int i = 0; i < 11; ++i) {
    on_key_pressed(nullptr, GDK_KEY_Down, 0, GdkModifierType(0), nullptr);
    pump(20);
  }
  check(selected_row_is_visible(launcher.results, scrolled, 11),
        "keyboard selection scrolls the last candidate into view");
  auto* selected = gtk_list_box_get_selected_row(launcher.results);
  check((gtk_widget_get_state_flags(GTK_WIDGET(selected)) & GTK_STATE_FLAG_SELECTED) != 0,
        "keyboard selection remains highlighted");
  Launcher::SearchOutcome refreshed;
  refreshed.ok = true;
  refreshed.rows = launcher.rows;
  refreshed.selected_arg = "option-11";
  launcher.apply_search(std::move(refreshed));
  pump(80);
  check(selected_row_is_visible(launcher.results, scrolled, 11),
        "setting refresh preserves the visible selected option");

  auto* surface = gtk_native_get_surface(GTK_NATIVE(launcher.window));
  auto* display = gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
  graphene_rect_t search_bounds{};
  bool search_measured = gtk_widget_compute_bounds(GTK_WIDGET(launcher.search),
      GTK_WIDGET(launcher.window), &search_bounds);
  if (search_measured) {
    XTestFakeMotionEvent(display, -1, static_cast<int>(search_bounds.origin.x + 15),
                         static_cast<int>(search_bounds.origin.y + 15), CurrentTime);
    XTestFakeButtonEvent(display, 1, True, CurrentTime);
    XTestFakeButtonEvent(display, 1, False, CurrentTime);
    XSync(display, False);
    pump(250);
  }
  check(search_measured && gtk_widget_get_visible(GTK_WIDGET(launcher.window)),
        "clicking inside the search field keeps the panel visible");

  launcher.rows.back().id = "app.open";
  launcher.rows.back().arg = "/test/app";
  launcher.refresh_results();
  gtk_list_box_select_row(launcher.results,
                         gtk_list_box_get_row_at_index(launcher.results, 11));
  set_i18n_language("zh");
  check(std::string(gtk_search_entry_get_placeholder_text(launcher.search)).find(
            "搜索") != std::string::npos,
        "language changes update the existing search field immediately");
  check(gtk_list_box_row_get_index(gtk_list_box_get_selected_row(launcher.results)) == 11,
        "language refresh preserves ordinary application selection");
  set_i18n_language("en");
  check(g_action_map_lookup_action(G_ACTION_MAP(app), "restart") != nullptr,
        "restart is available as a native application action");

  auto* settings = gtk_settings_get_default();
  gchar* original_theme = nullptr;
  g_object_get(settings, "gtk-theme-name", &original_theme, nullptr);
  g_object_set(settings, "gtk-theme-name", "Adwaita-dark", nullptr);
  Launcher::apply_theme("light");
  pump(80);
  gchar* light_theme = nullptr;
  g_object_get(settings, "gtk-theme-name", &light_theme, nullptr);
  check(std::string(light_theme).find("-dark") == std::string::npos,
        "light setting overrides a dark system GTK theme");
  GdkRGBA background{};
  auto* style = gtk_widget_get_style_context(GTK_WIDGET(launcher.window));
  check(gtk_style_context_lookup_color(style, "theme_bg_color", &background) &&
            background.red > .7 && background.green > .7 && background.blue > .7,
        "light setting renders a light window background");
  g_free(light_theme);
  Launcher::apply_theme("dark");
  pump(80);
  check(gtk_style_context_lookup_color(style, "theme_bg_color", &background) &&
            background.red < .3 && background.green < .3 && background.blue < .3,
        "dark setting renders a dark window background");
  Launcher::HostSettings old_snapshot;
  old_snapshot.generation = launcher.host_settings_generation;
  old_snapshot.theme_revision = launcher.theme_revision;
  old_snapshot.theme = "light";
  launcher.handle_state_push(rivet::Value(rivet::Value::List{
      rivet::Value("theme"), rivet::Value("dark")}));
  pump(40);
  launcher.apply_host_settings(old_snapshot);
  pump(40);
  check(gtk_style_context_lookup_color(style, "theme_bg_color", &background) &&
            background.red < .3 && background.green < .3 && background.blue < .3,
        "older settings snapshot cannot overwrite a newer theme push");
  old_snapshot.theme_revision = launcher.theme_revision;
  old_snapshot.language = "zh";
  ++launcher.host_settings_generation;
  launcher.apply_host_settings(old_snapshot);
  check(g_i18n_active.load() == 1,
        "superseded settings snapshot cannot restore an old language");
  old_snapshot.generation = launcher.host_settings_generation;
  SettingsForm form;
  g_settings_form = &form;
  settings_write("language", "en");
  launcher.apply_host_settings(old_snapshot);
  check(g_i18n_active.load() == 1 &&
            launcher.host_settings_generation > old_snapshot.generation,
        "settings form edits supersede in-flight host language snapshots");
  g_settings_form = nullptr;
  Launcher::apply_theme("system");
  gchar* restored_theme = nullptr;
  g_object_get(settings, "gtk-theme-name", &restored_theme, nullptr);
  check(std::string(restored_theme) == original_theme,
        "system theme restores the desktop GTK theme");
  g_free(original_theme);
  g_free(restored_theme);

  // An inactive notification may precede the following focus-in event.
  auto* other = GTK_WINDOW(gtk_window_new());
  gtk_window_present(other);
  focus(other);
  launcher.show();
  on_window_active_changed(G_OBJECT(launcher.window), nullptr, nullptr);
  check(gtk_widget_get_visible(GTK_WIDGET(launcher.window)),
        "transient inactive notification does not immediately hide the panel");
  pump(250);
  check(gtk_widget_get_visible(GTK_WIDGET(launcher.window)),
        "a summoned panel cannot hide before its first compositor activation");
  focus(launcher.window);
  on_window_active_changed(G_OBJECT(launcher.window), nullptr, nullptr);
  pump(250);
  check(gtk_widget_get_visible(GTK_WIDGET(launcher.window)),
        "panel stays visible when focus returns during the handoff");

  gtk_window_set_transient_for(other, launcher.window);
  gtk_window_present(other);
  focus(other);
  pump(250);
  check(gtk_widget_get_visible(GTK_WIDGET(launcher.window)),
        "launcher-owned dialog does not dismiss the panel");
  gtk_window_set_transient_for(other, nullptr);
  launcher.show();
  focus(launcher.window);
  on_window_active_changed(G_OBJECT(launcher.window), nullptr, nullptr);
  XTestFakeButtonEvent(display, 1, True, CurrentTime);
  XSync(display, False);
  pump(30);
  focus(other);
  pump(350);
  check(gtk_widget_get_visible(GTK_WIDGET(launcher.window)),
        "pointer-held window moves survive focus loss beyond the debounce");
  XTestFakeButtonEvent(display, 1, False, CurrentTime);
  XSync(display, False);
  launcher.show();
  focus(launcher.window);
  on_window_active_changed(G_OBJECT(launcher.window), nullptr, nullptr);
  focus(other);
  pump(250);
  check(!gtk_widget_get_visible(GTK_WIDGET(launcher.window)),
        "sustained focus loss to another window hides the panel");

  gtk_window_destroy(other);
  g_x11_hotkey.stop();
  launcher.tray.reset();
  launcher.stop_backend();
  gtk_window_destroy(launcher.window);
  g_object_unref(app);
  return failures == 0 ? 0 : 1;
}
