# Fulcrum native launcher design contract

Fulcrum uses three first-party native UI stacks: SwiftUI (macOS), WinUI 3 (Windows), GTK4 (Linux). Visual parity means a consistent interaction grammar, density, hierarchy, typography and accent, not replacing native windows with WebViews. See [cross-platform-interaction.md](cross-platform-interaction.md) for the behavioral contract.

## Shared launcher tokens

| Token | Baseline | Implementation |
| --- | --- | --- |
| Panel content size | 680 × 460 | macOS baseline, Windows target, GTK default |
| Search typography | 19 native display units | SwiftUI / XAML / GTK CSS |
| Product accent | #D97706 | Shared row icons, chips and selection |
| Selected row | amber 14% | SwiftUI 0.14, XAML #24, GTK alpha 0.14 |
| Hover row | amber 8% | SwiftUI 0.08, XAML #14, GTK alpha 0.08 |
| Icon tile | amber 12% | SwiftUI 0.12, XAML #1F, GTK alpha 0.12 |
| Badge | amber 14% | SwiftUI 0.14, XAML #24, GTK alpha 0.14 |
| Result row min height | 44 | Keep subtitles legible |
| Row corner radius | 8 | Inset, rounded selection |
| Launcher backdrop | Native blur where available; >= 98% opaque GTK fallback | Windows Acrylic, AppKit vibrancy, Linux CSS RGBA |

Native settings forms retain platform conventions; windowing, blur and tray/menu carriers may vary. Background **legibility** does not: a Linux session without compositor blur must not reveal sharp text or icons behind the result list. Use a >= 98% opaque launcher surface there (light and dark), and verify the actual contrast in front of a busy wallpaper and overlapping application text. Acrylic and vibrancy can remain native on Windows/macOS, but should also favor clear results over translucency. Do not sacrifice keyboard focus, legible contrast, accessibility identifiers or the shared Esc/actions/i18n contract.

## Verification

Run `raco test tests/`, `raco rivet schema check rivet-schema.json --json` and `raco rivet acceptance --json` on all three platforms against packaged products. Check light/dark themes, scaling, selection/hover contrast, localized hints and accessibility. On Linux, additionally exercise X11 and Wayland host activation.
