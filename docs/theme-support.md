# Multi-theme support — design

## Goal

Add multi-theme (light + dark + multiple palettes) to Octodo, with
`Catppuccin Mocha` as the default and eight additional palettes available.
The theme also drives the terminal background default. Existing chrome is
migrated; widgets outside the chrome keep hardcoded colors for follow-ups.

## Architecture

### `ThemePalette` (interface)

A palette declares every color the chrome needs:

| Token        | Used for                                    |
| ------------ | ------------------------------------------- |
| `id`         | Stable string key persisted to settings     |
| `displayName`| Human-readable name shown in Settings UI    |
| `brightness`| `Brightness.dark` / `Brightness.light`     |
| 7 accents    | Blue / Green / Yellow / Pink / Purple / Teal / Orange |
| 5 text tiers | `textPrimary` / `textBody` / `textSecondary` / `textMuted` / `textOverlay` |
| 8 surfaces   | `surface0` (scaffold) / `surface1` / `surface2` / `dialog` / `drawer` / `popup` / `row` / `outline` |
| 2 overlays   | `hoverOverlay` (accent @ 30%) / `focusOverlay` (accent @ 45%) |

`ThemePaletteExtension` carries the active `ThemePalette` on
`ThemeData.extensions` so widgets read it via
`Theme.of(context).extension<ThemePaletteExtension>()!.palette`.

A `BuildContext` extension `.palette` is the canonical lookup.

### Built-in palettes

| ID                   | Name                  | Brightness |
| -------------------- | --------------------- | ---------- |
| `catppuccin-mocha`   | Catppuccin Mocha      | dark       |
| `catppuccin-macchiato` | Catppuccin Macchiato| dark       |
| `catppuccin-frappe`  | Catppuccin Frappé     | dark       |
| `catppuccin-latte`   | Catppuccin Latte      | light      |
| `dracula`            | Dracula               | dark       |
| `solarized-dark`     | Solarized Dark        | dark       |
| `solarized-light`    | Solarized Light       | light      |
| `tokyo-night`        | Tokyo Night           | dark       |
| `nord`               | Nord                  | dark       |

`AppPalettes.all` is the ordered registry.

### Settings

New setting: `appearance.themeName` (`String`), default
`catppuccin-mocha`. Codec validates against the registry — unknown IDs
fall back to default. Resetting to default reverts to Mocha.

The terminal background tracks the active palette's `surface0`
directly — the previous `terminal.backgroundColor` user override was
removed because it defeated the "theme change retints the terminal"
goal (an explicit override always won over the palette).
`kTerminalBackground` resolves to the live palette value.

### MaterialApp wiring

```dart
final palette = AppPalettes.byId(themeName);
MaterialApp(
  theme: buildAppTheme(palette: AppPalettes.byId(<dark id>)),
  darkTheme: buildAppTheme(palette: palette),
  themeMode: ThemeMode.dark,  // derived from palette.brightness
  ...
)
```

`OctodoApp` rebuilds on `appearance.themeName` writes.

### Migration scope (chrome only)

- `lib/main.dart` — drawer scaffold, list, new-workspace button, settings
  button, expansion toggle, close-workspace + exit confirmation dialogs.
- `lib/ui/settings/settings_dialog.dart` — header, sidebar, footer, detail
  background, dialog chrome.
- `lib/ui/settings/widgets/trailing_widgets.dart` — text field borders,
  error text, focus ring.
- `lib/ui/update/update_pill.dart` — urgent + compact modes.
- `lib/ui/update/update_popover_view.dart` — popover chrome.

Hardcoded dark literals in:
- per-pane tab chip in `lib/src/terminal/pane_tree.dart`
- terminal view internals
- any dialog/popover not listed above

…are intentionally **not** migrated in this pass. They will appear dark
inside a light theme until follow-up work. Calling this out so reviewers
know it's deliberate.

### Settings UI

Adds a "Theme" row in the General section using `EnumDropdownTrailing`
via a new `StringDropdownTrailing` (or reuse `StringTextFieldTrailing`
as a curated dropdown — `StringSetting` already supports it). Dropdown
lists each palette by `displayName`, with a leading sun/moon icon for
brightness.

### Backwards-compat

- `AppColors` static class is kept as a thin shim over the active palette
  for any widget still importing it; reads go through a global
  `currentPalette()` lookup populated on app start. Newly-written code
  should reach for `context.palette` instead.

## Files touched

- `lib/src/theme/app_theme.dart` — refactor to palette-driven
- `lib/src/theme/palettes.dart` — new (palette definitions + registry)
- `lib/src/theme/palette_context.dart` — new (`context.palette` extension)
- `lib/src/settings/settings_catalog.dart` — add `themeName`
- `lib/src/settings/setting_codec.dart` — add `PaletteIdCodec`
- `lib/main.dart` — wire `theme`/`darkTheme`/`themeMode`, migrate chrome
- `lib/ui/settings/settings_dialog.dart` — chrome migration + Theme row
- `lib/ui/settings/widgets/trailing_widgets.dart` — palette-aware borders
- `lib/ui/update/update_pill.dart` — chrome migration
- `lib/ui/update/update_popover_view.dart` — chrome migration

## Verification

- `flutter analyze` clean
- `flutter test` passes (existing tests)
- Manual: switch between Mocha and Latte — drawer, settings dialog,
  update pill, and confirmation dialogs visibly retint; `terminal.bg`
  default follows the palette unless explicitly overridden.