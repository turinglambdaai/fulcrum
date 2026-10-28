// Exercise the real launcher widgets without starting its embedded backend.
#include <cmath>
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
  // Pure positioning checks exercise coordinate math independent of a
  // particular CI virtual monitor topology. Negative origins and smaller
  // work areas are common with laptop + external-display setups.
  GdkRectangle work{0, 30, 1920, 1000};
  auto top = upper_quarter_placement(work, 680, 460);
  check(top.x == 620 && top.y == 165,
        "launcher sits at top quarter of usable work area, not screen center");
  GdkRectangle left_monitor{-1920, 0, 1920, 1080};
  auto negative = upper_quarter_placement(left_monitor, 680, 460);
  check(negative.x == -1300 && negative.y == 155,
        "left-hand monitors preserve negative global X coordinates");
  check(monitor_contains_point(left_monitor, -1000, 500) &&
            !monitor_contains_point(work, -1000, 500),
        "pointer monitor selection respects multi-monitor boundaries");
  GdkRectangle small{100, 50, 500, 400};
  auto small_pos = upper_quarter_placement(small, 500, 400);
  check(small_pos.x == 100 && small_pos.y == 50,
        "small work areas do not produce a negative placement offset");

  auto* app = gtk_application_new("site.jrtx.fulcrum.ui-test",
                                   G_APPLICATION_NON_UNIQUE);
  g_application_register(G_APPLICATION(app), nullptr, nullptr);
  on_activate(app, nullptr);
  auto& launcher = Launcher::instance();
  // The test executable has no adjacent runtime: startup stops before boot.
  check(launcher.api == nullptr, "UI fixture does not start the backend");
  check(GTK_IS_ENTRY(launcher.search) && launcher.search_icon != nullptr &&
            GTK_IS_IMAGE(launcher.search_icon),
        "search uses an editable GTK entry plus a separate native symbolic icon");
  launcher.set_status(tr("ready"));
  check(!gtk_widget_get_visible(GTK_WIDGET(launcher.status)),
        "normal ready/hotkey hint is hidden instead of taking up a search row");
  launcher.set_status("Failed to register hotkey: change desktop bindings");
  check(gtk_widget_get_visible(GTK_WIDGET(launcher.status)) &&
            has_label(GTK_WIDGET(launcher.status),
                      "Failed to register hotkey: change desktop bindings"),
        "actionable hotkey failures remain visible in the native status area");
  launcher.set_status(tr("ready"));
  check(!gtk_widget_get_visible(GTK_WIDGET(launcher.status)),
        "clearing an actionable status removes its layout space");
  // Ubuntu 26.04 may reject portal CreateSession before backend startup.
  // The late backend ready notification must not conceal a broken hotkey.
  Launcher::post_hotkey_failure(
      "Portal hotkey failed: An app id is required. "
      "Bind fulcrum --toggle in desktop Settings.");
  pump(30);
  launcher.set_status(tr("ready"));
  check(launcher.hotkey_failure_active &&
            gtk_widget_get_visible(GTK_WIDGET(launcher.status)) &&
            has_label(GTK_WIDGET(launcher.status),
                      "Portal hotkey failed: An app id is required. "
                      "Bind fulcrum --toggle in desktop Settings."),
        "Wayland portal rejection remains visible after backend ready");
  launcher.hotkey_failure_active = false;
  launcher.set_status(tr("ready"));
  check(!gtk_widget_get_visible(GTK_WIDGET(launcher.status)),
        "normal ready status may clear after explicit hotkey-error recovery");
  // Regression: a normal interactive summon must not map the bare search
  // placeholder before the first asynchronous backend result arrives.
  launcher.hide();
  launcher.initial_results_ready = false;
  launcher.show();
  check(!gtk_widget_get_visible(GTK_WIDGET(launcher.window)) &&
            launcher.summon_when_ready,
        "startup query shell remains hidden before first native result rows");
  Launcher::SearchOutcome initial;
  initial.ok = true;
  initial.rows.push_back(parse_row(
      {"settings.open", "Settings…", "Preferences", "Setting", "", "", "", ""}));
  launcher.apply_search(std::move(initial));
  check(launcher.initial_results_ready &&
            gtk_widget_get_visible(GTK_WIDGET(launcher.window)),
        "first native backend rows reveal the requested launcher exactly once");

  // Error is also a completed first result: a failed backend search must
  // display the actionable failure, not leave the resident process invisible.
  launcher.hide();
  launcher.initial_results_ready = false;
  launcher.show();
  Launcher::SearchOutcome failed;
  failed.ok = false;
  failed.error = "test query failure";
  launcher.apply_search(std::move(failed));
  check(launcher.initial_results_ready &&
            gtk_widget_get_visible(GTK_WIDGET(launcher.window)) &&
            has_label(GTK_WIDGET(launcher.status), "Search failed: test query failure"),
        "initial search RPC errors reveal the launcher and visible diagnostic");
  launcher.set_status(tr("ready"));

  // A user-authorized login item creates the same backend but never opens
  // a launcher on its own. Only the later interactive summon reveals it.
  launcher.hide();
  g_login_background_start = true;
  launcher.initial_results_ready = false;
  Launcher::SearchOutcome login_background;
  login_background.ok = true;
  login_background.rows.push_back(parse_row(
      {"settings.open", "Settings…", "", "Setting", "", "", "", ""}));
  launcher.apply_search(std::move(login_background));
  check(launcher.initial_results_ready &&
            !gtk_widget_get_visible(GTK_WIDGET(launcher.window)) &&
            !launcher.summon_when_ready,
        "login background receives native results without revealing the panel");
  g_login_background_start = false;
  launcher.show();
  check(gtk_widget_get_visible(GTK_WIDGET(launcher.window)),
        "the same resident launcher can still be summoned interactively");

  // The GTK Settings window uses the same five-section information
  // architecture as Windows/macOS, with a functional Commands content slot.
  settings_build();
  check(GTK_IS_STACK(g_settings_form->stack), "GTK Settings has a real native page stack");
  for (auto const* page : {"general", "features", "ai", "commands", "sync"}) {
    check(gtk_stack_get_child_by_name(GTK_STACK(g_settings_form->stack), page) != nullptr,
          "settings stack contains platform-aligned category");
  }
  check(g_settings_form->commands_list != nullptr &&
            has_label(GTK_WIDGET(g_settings_form->window), "Start at login"),
        "Linux Commands and local startup controls are discoverable");
  gtk_window_destroy(g_settings_form->window);
  delete g_settings_form;
  g_settings_form = nullptr;

  // XDG Exec values are parsed as desktop-entry command syntax. AppImages
  // can legitimately live in folders containing spaces and '%' characters;
  // those bytes need quoting / field-code escaping, not a shell invocation.
  std::string const special_exec =
      fulcrum_desktop_exec_quote("/tmp/My Files/Fulcrum 50%.AppImage");
  check(special_exec == "\"/tmp/My Files/Fulcrum 50%%.AppImage\"",
        "autostart Exec quotes paths and escapes percent field codes");

  char const* saved_xdg = g_getenv("XDG_CONFIG_HOME");
  std::string const original_xdg = saved_xdg ? saved_xdg : "";
  bool const had_xdg = saved_xdg != nullptr;
  gchar* temp_config = g_dir_make_tmp("fulcrum-autostart-ui-XXXXXX", nullptr);
  check(temp_config != nullptr, "isolated XDG autostart fixture created");
  if (temp_config != nullptr) {
    g_setenv("XDG_CONFIG_HOME", temp_config, TRUE);
    std::string error;
    check(fulcrum_set_autostart(true, executable_path().string(), error) &&
              fulcrum_autostart_enabled(), "XDG login item writes only after opt-in");
    gchar* saved_content = nullptr;
    if (g_file_get_contents(fulcrum_autostart_path().string().c_str(),
                            &saved_content, nullptr, nullptr)) {
      std::string const content(saved_content);
      check(content.find("--background") != std::string::npos &&
                content.find("Exec=") != std::string::npos,
            "Linux login item starts silently with a valid desktop Exec entry");
      g_free(saved_content);
    } else {
      check(false, "XDG login item content can be read back");
    }
    check(fulcrum_set_autostart(false, executable_path().string(), error) &&
              !fulcrum_autostart_enabled(), "disabling login startup removes own entry");
    std::filesystem::remove_all(temp_config);
    g_free(temp_config);
  }
  if (had_xdg) g_setenv("XDG_CONFIG_HOME", original_xdg.c_str(), TRUE);
  else g_unsetenv("XDG_CONFIG_HOME");
  // Check that the live X11 window actually advertises its program-chosen
  // position to the WM. The helper runs on every summon, not just startup.
  launcher.show();
  auto* placement_surface = gtk_native_get_surface(GTK_NATIVE(launcher.window));
  auto* xdisplay = gdk_x11_display_get_xdisplay(
      gtk_widget_get_display(GTK_WIDGET(launcher.window)));
  auto const xid = gdk_x11_surface_get_xid(placement_surface);
  XSizeHints hints{};
  long supplied = 0;
  check(XGetWMNormalHints(xdisplay, xid, &hints, &supplied) != 0 &&
            (hints.flags & USPosition) != 0,
        "X11 summon sets the WM's USPosition hint");
  launcher.rows.clear();
  for (int i = 0; i < 12; ++i) {
    launcher.rows.push_back(parse_row({"settings.set", "Option " + std::to_string(i),
        "Select to cycle", "Setting", "option-" + std::to_string(i),
        "setting", "", "system"}));
  }
  launcher.refresh_results();
  focus(launcher.window);
  pump(80);
  graphene_rect_t glyph_bounds{}, entry_bounds{};
  bool const glyph_measured = gtk_widget_compute_bounds(
      launcher.search_icon, GTK_WIDGET(launcher.window), &glyph_bounds);
  bool const entry_measured = gtk_widget_compute_bounds(
      GTK_WIDGET(launcher.search), GTK_WIDGET(launcher.window), &entry_bounds);
  if (glyph_measured && entry_measured) {
    auto const glyph_center = glyph_bounds.origin.y + glyph_bounds.size.height / 2.0;
    auto const entry_center = entry_bounds.origin.y + entry_bounds.size.height / 2.0;
    check(std::abs(glyph_center - entry_center) <= 3.0,
          "search glyph and entry share one horizontal visual centerline");
  } else {
    check(false, "native search glyph and editable entry must both lay out");
  }
  auto* scrolled = gtk_widget_get_ancestor(GTK_WIDGET(launcher.results),
                                          GTK_TYPE_SCROLLED_WINDOW);
  auto* first = gtk_list_box_get_row_at_index(launcher.results, 0);
  check(gtk_widget_get_height(scrolled) >= 3 * gtk_widget_get_height(GTK_WIDGET(first)),
        "results viewport shows multiple candidates");
  check(has_label(GTK_WIDGET(first), "system"), "current setting badge is rendered");

  // A .desktop Icon=absolute/path should create a native file icon,
  // while an invalid entry must fall back to the generic glyph.
  gchar* icon_dir = g_dir_make_tmp("fulcrum-icon-test-XXXXXX", nullptr);
  check(icon_dir != nullptr, "test icon directory can be created");
  if (icon_dir != nullptr) {
    std::string icon_path = std::string(icon_dir) + "/app.svg";
    char const* svg = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'>"
                      "<rect width='32' height='32' fill='#d97706'/></svg>";
    check(g_file_set_contents(icon_path.c_str(), svg, -1, nullptr) != FALSE,
          "test app icon is written");
    auto app = parse_row({"app.launch", "Test App", "/tmp/test.desktop",
                          "Application", "dtest", icon_path, "", ""});
    GtkWidget* app_image = application_icon(app);
    check(GTK_IS_IMAGE(app_image) &&
              gtk_image_get_storage_type(GTK_IMAGE(app_image)) == GTK_IMAGE_GICON,
          "application row renders its real desktop Icon path");
    auto missing = parse_row({"app.launch", "Missing Icon", "/tmp/test.desktop",
                              "Application", "dmissing",
                              "/no/such/fulcrum/icon.svg", "", ""});
    check(application_icon(missing) == nullptr,
          "broken app icons allow the generic glyph fallback");
    if (app_image) g_object_ref_sink(app_image);
    if (app_image) g_object_unref(app_image);
    std::filesystem::remove(icon_path);
    std::filesystem::remove(icon_dir);
    g_free(icon_dir);
  }
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
  check(std::string(gtk_entry_get_placeholder_text(launcher.search)).find(
            "搜索") != std::string::npos,
        "language changes update the existing search field immediately");
  check(gtk_list_box_row_get_index(gtk_list_box_get_selected_row(launcher.results)) == 11,
        "language refresh preserves ordinary application selection");
  set_i18n_language("en");
  check(g_action_map_lookup_action(G_ACTION_MAP(app), "restart") == nullptr &&
            g_action_map_lookup_action(G_ACTION_MAP(app), "quit") == nullptr,
        "search UI does not expose redundant Restart/Quit app actions");
  check(launcher.app != nullptr,
        "the resident native tray still owns application lifecycle");

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
