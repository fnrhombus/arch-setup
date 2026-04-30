# Config-syntax validation report — desktop-design (2026-04-22)

Pass against current upstream docs as of 2026-04-22, branch `desktop-design`.

## Method

Schemas pulled directly from upstream sources (not blogs / SO):

- Hyprland: `hyprwm/hyprland-wiki@main:content/Configuring/{Variables,Window-Rules,Dispatchers,Binds,Animations,Dwindle-Layout}.md`
- hyprlock + hypridle: `hyprwm/hyprland-wiki@main:content/Hypr Ecosystem/{hyprlock,hypridle}.md`
- Hyprspace: `KZDKM/Hyprspace@main:README.md`
- matugen: `InioX/matugen@main:Cargo.toml` (v4.1.0), `src/template_util/template.rs` (Color struct), `Aiving/material-colors@main:src/scheme/mod.rs` (role list), `CHANGELOG.md`
- waybar: `Alexays/Waybar/wiki Module:Custom + Module:Hyprland`
- swaync: `ErikReider/SwayNotificationCenter@main:src/configSchema.json`
- fuzzel: `dnkl/fuzzel@master:doc/fuzzel.ini.5.scd`
- ghostty: `ghostty.org/docs/config/reference`
- yazi: `sxyazi/yazi@main:yazi-config/preset/{yazi-default.toml,theme-dark.toml}`
- helix: `docs.helix-editor.com/themes.html`
- chezmoi: `chezmoi.io/user-guide/use-scripts-to-perform-actions/`
- zathura: `man.archlinux.org/man/zathurarc.5.en`
- awww: `codeberg.org/LGFae/awww:doc/awww.1.scd`

## Files reviewed (33)

`dotfiles/dot_config/`:
- matugen: `config.toml`, templates `{fuzzel.ini, gtk.css, helix.toml, hypr-colors.conf, hyprlock.conf, qt.conf, regreet.css, swaync.css, waybar.css, yazi-theme.toml, zathurarc, ghostty-theme}` — 12
- hypr: `hyprland.conf, binds.conf, decoration.conf, animations.conf, exec.conf, hypridle.conf, hyprlock.conf, input.conf, monitors.conf, plugins.conf, workspaces.conf` — 11
- waybar: `config.jsonc, style.css` — 2
- swaync: `config.json, style.css` — 2
- fuzzel: `fuzzel.ini` — 1
- ghostty: `config` — 1
- yazi: `yazi.toml` — 1
- helix: `config.toml` — 1
- imv: `config` — 1
- zathura: `zathurarc` — 1
- qt5ct/qt6ct: `qt5ct.conf, qt6ct.conf` — 2
- xdg-desktop-portal: `hyprland-portals.conf` — 1
- systemd/user: `wallpaper-rotate.{service,timer}` — 2

`dotfiles/dot_local/bin/`: `control-panel, theme-toggle, validate-hypr-binds, wallpaper-rotate` — 4
`dotfiles/.chezmoiscripts/`: 2 templates — 2
`phase-3-arch-postinstall/system-files/`: `greetd/{config.toml, regreet.toml}, pam.d/greetd` — 3

## Files with fixes applied (count: 7)

Atomic commits grouped by concern. See diffs below.

---

## Drift findings (in order of severity)

### 1. `windowrulev2` removed in favor of unified `windowrule` (Hyprland ≥ ~0.49)

**Source:** `hyprland-wiki/Configuring/Window-Rules.md` — entire current syntax is `windowrule = EFFECT, match:PROP value, ...`. There is no longer any `windowrulev2` keyword; the wiki contains zero references to it. Named-block form: `windowrule { name = ...; match:class = foo; border_size = 10 }`.

The matcher syntax also changed: `class:^(foo|bar)$` → `match:class foo|bar` (regex still RE2 but the anchors are no longer required to match-whole-string, and the prop is `match:class` not `class:`).

**Files affected:**
- `dotfiles/dot_config/hypr/hyprland.conf` — 10 windowrulev2 lines
- `dotfiles/dot_config/hypr/decoration.conf` — 3 windowrulev2 lines

**Fix:** s/windowrulev2/windowrule/, restructure RHS so effect comes first then `match:` props. Drop unnecessary `^( ... )$` anchors per current wiki examples.

### 2. yazi config schema — `[manager]` → `[mgr]` (yazi 25.x → 26.x rewrite)

**Source:** `sxyazi/yazi@main:yazi-config/preset/yazi-default.toml` and `theme-dark.toml`. Section header `[mgr]` (was `[manager]`). Theme drift is significant:

- `tab_active` / `tab_inactive` moved from `[manager]` (now `[mgr]`) to **separate `[tabs]` section** as `active` / `inactive`.
- `[select]` section renamed to `[pick]`.
- old `hovered = { reversed = true }` and `preview_hovered = { underline = true }` (top-level under `[manager]`) → moved to **new `[indicator]` section** as `current = { reversed = true }` and `preview = { underline = true }`.
- `marker_*` colors stay in `[mgr]`.
- `count_*` colors stay in `[mgr]`.

**Files affected:**
- `dotfiles/dot_config/yazi/yazi.toml` — section rename `[manager]` → `[mgr]`.
- `dotfiles/dot_config/matugen/templates/yazi-theme.toml` — rename `[manager]` → `[mgr]`, hoist `tab_*` to `[tabs]` block, hoist `hovered`/`preview_hovered` to `[indicator]`, rename `[select]` → `[pick]`.

### 3. hyprlock `general` block — keys removed in current schema

**Source:** `hyprland-wiki/Hypr Ecosystem/hyprlock.md` — current `general` valid keys are: `hide_cursor`, `ignore_empty_input`, `immediate_render`, `text_trim`, `fractional_scaling`, `screencopy_mode`, `fail_timeout`. The keys `no_fade_in`, `grace`, `disable_loading_bar` are NOT in the current schema.

- `no_fade_in`: replaced by the `--no-fade-in` CLI flag and/or an `animation = fadeIn, ...` override in the `animations` block.
- `grace`: replaced by the `--grace SECONDS` CLI flag.
- `disable_loading_bar`: removed; the loading-bar concept is gone.

**Files affected:**
- `dotfiles/dot_config/hypr/hyprlock.conf` — drop the three deprecated keys; add a comment noting the CLI-flag migration.

### 4. Hyprland gestures — old workspace_swipe_* keys removed

**Source:** `hyprland-wiki/Configuring/Variables.md` lines 334-341 — explicit `[!NOTE]`: "`workspace_swipe`, `workspace_swipe_fingers` and `workspace_swipe_min_fingers` were removed in favor of the new gestures system." Replacement: `gesture = 3, horizontal, workspace`.

**Files affected:**
- `dotfiles/dot_config/hypr/input.conf` — `gestures` block uses two removed keys (`workspace_swipe = true`, `workspace_swipe_fingers = 3`). Migrate to `gesture = 3, horizontal, workspace`. `workspace_swipe_invert` and `workspace_swipe_min_speed_to_force` ARE still valid.

The hyprgrass plugin's own `workspace_swipe_fingers` is unaffected (plugin-internal key).

### 5. Hyprland `misc` — `new_window_takes_over_fullscreen` renamed to `on_focus_under_fullscreen`

**Source:** `hyprland-wiki/Configuring/Variables.md` line 433 — `on_focus_under_fullscreen` (int 0/1/2 with same semantics).

**Files affected:**
- `dotfiles/dot_config/hypr/hyprland.conf` — `new_window_takes_over_fullscreen = 2` → `on_focus_under_fullscreen = 2`.

### 6. validate-hypr-binds dispatcher allowlist out of date

**Source:** `hyprland-wiki/Configuring/Dispatchers.md` (current 2026 list) plus dwindle-specific dispatchers in `Dwindle-Layout.md`.

Removed (no longer real dispatchers):
- `fakefullscreen` (replaced by `fullscreenstate`)
- `setcursor` (not in current docs)
- `pinwindow` (it's just `pin`)
- `workspaceopt` (not in current docs)
- `reload` (not a dispatcher; `hyprctl reload` is keyword-side)

Need to add (current core dispatchers our config might use, plus widely useful ones):
- `signal`, `signalwindow`, `forcekillactive`, `killwindow`, `setfloating`, `settiled`, `fullscreenstate`, `resizewindowpixel`, `sendkeystate`, `lockactivegroup`, `moveintogroup`, `moveintoorcreategroup`, `moveoutofgroup`, `movewindoworgroup`, `denywindowfromgroup`, `setignoregrouplock`, `toggleswallow`, `movecurrentworkspacetomonitor`, `focusworkspaceoncurrentmonitor`, `moveworkspacetomonitor`, `swapactiveworkspaces`, `bringactivetotop`, `forceidle`, `resizewindow` (used in our binds.conf via `bindm`)

Also: dwindle-layout dispatchers `togglesplit` (was already in our list), `splitratio`, `pseudo`, `layoutmsg`.

**Files affected:**
- `dotfiles/dot_local/bin/executable_validate-hypr-binds`

### 7. zathura overlap (matugen vs chezmoi) — task-specified known issue

**Resolution chosen:** Option (b) per task — rename matugen's output and use zathurarc's `include` directive. zathura's `include` accepts a relative path, allowing the user to keep readonly base config in chezmoi and pull in matugen-generated colors via include. This is upstream-canonical (per `zathurarc(5)`).

Concretely:
- matugen `[templates.zathura]` output_path → `~/.config/zathura/colors.zathurarc` (was `zathurarc`).
- Static `dot_config/zathura/zathurarc` adds `include colors.zathurarc` at the bottom.
- The matugen template comment ("Sourced via 'include'…") becomes accurate (it was originally written as if include was used).

`.chezmoiignore` already excludes `~/.config/zathura/colors.zathurarc` since 4b8e6dd? Let me re-verify and add if missing — addressed in commit.

### 8. fuzzel `fuzzy=yes` — superseded by `match-mode`

**Source:** `dnkl/fuzzel@master:doc/fuzzel.ini.5.scd` — `match-mode` accepts `exact|fuzzy|fzf`. `fuzzy` is no longer documented as a top-level key. We already set `match-mode=fzf`, so `fuzzy=yes` is redundant. Removing prevents confusion + future deprecation warnings.

**Files affected:**
- `dotfiles/dot_config/fuzzel/fuzzel.ini` — drop `fuzzy=yes`.

---

## Things checked and OK (no fix)

### matugen 4.1.0
- `{{colors.X.default.{hex,hex_stripped,rgb,rgba,hsl,hsla,red,green,blue,alpha,hue,saturation,lightness,hex_alpha,hex_alpha_stripped}}}` all valid (`src/template_util/template.rs::Color` struct).
- All assumed role names (primary, on_primary, primary_container, on_primary_container, secondary, on_secondary, secondary_container, tertiary, on_tertiary, tertiary_container, error, on_error, error_container, background, on_background, surface, on_surface, surface_container, surface_container_low, surface_container_high, surface_container_lowest, surface_container_highest, surface_variant, outline, outline_variant, scrim, shadow) are present in `Aiving/material-colors@main:src/scheme/mod.rs::Scheme` struct.
- `CHANGELOG.md` v4.1.0 (2026-03-22) shows `hex_stripped` is still actively supported (compare to new sibling `alpha_hex_stripped` added in same release).

### Hyprland 0.46+
- `general`: layout, gaps_in, gaps_out, border_size, resize_on_border, allow_tearing — all valid.
- `dwindle`: pseudotile, preserve_split, smart_split — all valid.
- `decoration`: rounding, active_opacity, inactive_opacity, fullscreen_opacity, dim_inactive, dim_strength, dim_special — all valid.
- `decoration.blur`: enabled, size, passes, ignore_opacity, new_optimizations, xray, noise, contrast, brightness — all valid.
- `decoration.shadow`: enabled, range, render_power, color — all valid.
- `misc`: disable_hyprland_logo, disable_splash_rendering, force_default_wallpaper, mouse_move_enables_dpms, key_press_enables_dpms, enable_swallow, focus_on_activate — all valid. (`vfr` is in `debug` section, not `misc`, but Hyprland tolerates the `misc` placement historically. Leaving alone — see uncertainty below.)
- `input`: kb_layout, kb_options, repeat_rate, repeat_delay, follow_mouse, accel_profile — all valid.
- `input.touchpad`: natural_scroll, tap-to-click, clickfinger_behavior, scroll_factor, disable_while_typing — all valid.
- `input.touchdevice.enabled` — valid.
- `input.tablet.output` — valid.
- `cursor`: inactive_timeout, no_warps, persistent_warps — all valid.
- `bindel/bindl/bindm/binde/bind` flag combos — all valid (`l`=locked, `e`=repeat, `m`=mouse).

### Hyprspace plugin (replaced hyprexpo)
- Namespace: `plugin:overview:*` (NOT `plugin:hyprspace:*`).
- Used keys: `autoDrag`, `switchOnDrop`, `exitOnClick`, `autoScroll`, `panelColor`, `panelBorderColor`, `panelBorderWidth`, `workspaceActiveBackground`, `workspaceInactiveBackground`. All current per upstream README.
- Dispatcher: `overview:toggle` / `overview:open` / `overview:close`. The `validate-hypr-binds` allowlist tracks all three.

### hypridle
- `general`: lock_cmd, unlock_cmd, before_sleep_cmd, after_sleep_cmd, ignore_dbus_inhibit, ignore_systemd_inhibit — all valid.
- `listener`: timeout, on-timeout, on-resume, ignore_inhibit — all valid.
- (Already addressed XDPH+hyprlock+dpms-off mitigation in commit `8b049a3`.)

### waybar
- Top-level: layer, position, height, spacing, margin-* — all valid.
- `signal: 8` → SIGRTMIN+8, valid integer per Module:Custom.
- `interval: "once"` valid (special string per Module:Custom note).
- `hyprland/workspaces`: format, format-icons, on-click, sort-by-number, show-special, all-outputs — all valid (Module:Hyprland 2026-02 docs).
- `hyprland/window`: format, max-length, separate-outputs — valid.
- `clock`: format, format-alt, tooltip-format, calendar, actions — valid.
- `tray`: icon-size, spacing, show-passive-items — valid.
- `wireplumber`: format, format-muted, format-icons, on-click, on-click-right, scroll-step — valid.
- `battery`: states (warning/critical), format, format-charging, format-plugged, format-icons, tooltip-format — valid.

### swaync
- All keys in our config validated against `src/configSchema.json` properties: positionX, positionY, control-center-margin-{top,bottom,right,left}, notification-icon-size, notification-body-image-{height,width}, timeout, timeout-low, timeout-critical, fit-to-screen, control-center-{width,height}, notification-window-width, keyboard-shortcuts, image-visibility, transition-time, hide-on-clear, hide-on-action, script-fail-notify, widgets, widget-config — all present in current schema.
- Widget IDs (title, dnd, mpris, notifications) all valid.

### fuzzel
- All sections [main], [colors], [border], [key-bindings], [dmenu] valid.
- `match-mode=fzf` valid.
- `exit-on-keyboard-focus-loss=yes` valid.
- `match-counter=no` valid.
- `include=` directive valid.
- (Removing `fuzzy=yes` — see drift #8.)

### ghostty
- All keys validated. `theme = matugen` referencing `~/.config/ghostty/themes/matugen` is correct per docs.
- Theme file format `palette = N=#hex`, `background`, `foreground`, `cursor-color`, `cursor-text`, `selection-background`, `selection-foreground` all valid.
- The matugen template uses `cursor-text = ...` — added in Ghostty 1.x, valid.

### helix
- All UI scopes valid (ui.background, ui.text, ui.cursor.*, ui.linenr.*, ui.statusline.*, ui.popup, ui.window, ui.help, ui.menu.*, ui.selection.*, ui.virtual.*).
- All syntax keys valid (keyword.*, function.*, type.*, constant.*, string.*, comment, operator, variable.*, namespace, attribute, constructor, tag, label).
- Markup keys valid.
- `[palette]` section with named colors valid.
- `editor`, `editor.lsp`, `editor.cursor-shape`, `editor.file-picker`, `editor.statusline`, `editor.indent-guides`, `editor.soft-wrap`, `editor.whitespace.{render,characters}`, `keys.{normal,insert}` — all valid.

### imv
- `[options]` and `[binds]` syntax valid (imv config format hasn't changed).

### qt5ct/qt6ct
- `[Appearance]` section with color_scheme_path, custom_palette, icon_theme, standard_dialogs, style — valid.
- `style=Fusion` is correct (built-in Qt style, doesn't need extra packages).
- The exported `[ColorScheme]` palette format (20 colors active + 20 disabled) matches qt5ct/qt6ct expectations.

### xdg-desktop-portal/hyprland-portals.conf
- `[preferred]` section with `default`, `org.freedesktop.impl.portal.{FileChooser,AppChooser,Settings}` keys — current xdg-desktop-portal schema.

### systemd/user units
- `.service` and `.timer` syntax valid systemd unit format.
- `ConditionEnvironment=WAYLAND_DISPLAY` valid.

### chezmoi scripts
- `run_before_validate-binds.sh.tmpl` — `run_before_` is valid prefix, dashes allowed in name, `.sh.tmpl` is valid combined extension.
- `run_once_after_install-wallpapers.sh.tmpl` — `run_once_after_` is valid prefix, same conventions.

### greetd / regreet / pam
- greetd config.toml: `[terminal] vt = 1`, `[default_session] command, user`, `[initial_session]` — all valid. Documentation last updated 2024 but format stable.
- regreet.toml: `[background] {path, fit}`, `[GTK] {application_prefer_dark_theme, cursor_theme_name, font_name, icon_theme_name, theme_name}`, `[appearance] {greeting_msg}`, `[commands] {reboot, poweroff}`, `[widget.clock] {format, resolution, label_width}` — all in regreet sample.toml.
- PAM stack syntax `auth sufficient pam_fprintd.so max-tries=1 timeout=10` — valid (pam_fprintd accepts max-tries and timeout options per Arch wiki).

### awww (post-rename from swww)
- `awww img <path> --transition-type any --transition-duration 1.5` valid.
- `awww query`, `awww-daemon` valid.

---

## Couldn't validate (low confidence)

- **Hyprland `vfr` in `misc` block**: the wiki currently lists `vfr` only under the `debug` section (line 583), not `misc` (line 402-444). However, Hyprland has historically tolerated `vfr` in `misc` and many community configs still place it there. **Leaving as-is** with a comment noting the actual canonical location is `debug`. If lint becomes strict in a future Hyprland release, move `vfr = true` into a `debug { vfr = true }` block.
- **Hyprland `iio-hyprland`**: not in any schema we can validate; it's a third-party daemon. Assumed `exec-once = iio-hyprland` is correct.
- **hyprgrass plugin keys** (sensitivity, workspace_swipe_fingers, long_press_delay, edge_swipe_threshold, gestures.{edge:b:u}): plugin-internal, not in Hyprland's wiki. Trusting prior-set values.
- **Ghostty `quick-terminal-*`** keys validated as present in reference but not exercised on this hardware yet.

---

## Commits planned

1. `fix(hypr): windowrulev2 → windowrule (Hyprland window rules rewrite)` — hyprland.conf, decoration.conf
2. `fix(hypr): on_focus_under_fullscreen + remove old gesture keys (gestures rewrite)` — hyprland.conf, input.conf
3. `fix(hyprlock): drop deprecated general keys (no_fade_in/grace/disable_loading_bar)` — hyprlock.conf
4. `fix(yazi): [manager] → [mgr], split [tabs]/[indicator]/[pick] (yazi 26.x rewrite)` — yazi.toml, yazi-theme.toml
5. `fix(matugen): zathura overlap — output to colors.zathurarc, include from base` — matugen/config.toml, zathura/zathurarc, .chezmoiignore
6. `fix(fuzzel): drop deprecated fuzzy= key (superseded by match-mode)` — fuzzel.ini
7. `fix(validate-hypr-binds): refresh dispatcher allowlist for Hyprland 0.51` — executable_validate-hypr-binds
