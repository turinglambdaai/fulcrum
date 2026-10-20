# Fulcrum native launcher design contract

Fulcrum uses three first-party native UI stacks: SwiftUI (macOS), WinUI 3 (Windows), GTK4 (Linux). Visual parity means consistent interaction, density, hierarchy, typography and accent — not replacing native windowing systems with a WebView.

## Shared launcher tokens

| Token | Target | Implementation notes |
| --- | --- | --- |
| Panel content size | 680 × 460 | macOS minimum, Windows target, GTK default |
| Search typography | 19 native display units | SwiftUI / XAML / GTK CSS |
| Product accent | #D97706 | Keep throughout row icons, chips, selection |
| Selected row background | amber at 14% | SwiftUI 0.14; XAML #24; GTK alpha 0.14 |
| Hover row background | amber at 8% | SwiftUI 0.08; XAML #14; GTK alpha 0.08 |
| Icon tile background | amber at 12% | SwiftUI 0.12; XAML #1F; GTK alpha 0.12 |
| Badge background | amber at 14% | SwiftUI 0.14; XAML #24; GTK alpha 0.14 |
| Result row minimum height | 44 | Native list controls; don't compress subtitles |
| Row corner radius | 8 | Inset selection and rounded items |

## Keyboard and accessibility

- The query field is focused when opening the panel.
- Up/Down navigates, Return executes, Tab completes the selected result when not viewing actions.
- macOS uses Command+K and Windows/Linux use Ctrl+K for secondary actions.
- Escape first exits actions or detail/AI, then clears the query if nonempty, then hides the empty launcher. The footer should reflect the current actions mode.
- Retain native accessibility identifiers and native view roles; do not encode backend logic in host renderers.

## Native surfaces and intentional differences

Windows Fluent/Mica/Acrylic, macOS vibrancy and Linux compositor-dependent GTK translucency are intentionally different. Keep contrast readable without assuming Linux has a blur compositor. Platform-native settings forms can follow each OS's conventions while sharing the same backend settings model.

## Before merge

Run raco test tests/, raco rivet schema check rivet-schema.json --json, and raco rivet acceptance --json on all three OS runners against the packaged application. Verify 12*12 -> 144, theme light/dark, focus, hover and selection, badges, keyboard actions, Esc semantics and localized footer text. On Linux also inspect X11 and Wayland compositor behavior; on Windows inspect scaling; on macOS inspect resize and accessibility.
