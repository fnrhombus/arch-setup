# Desktop / dotfiles — requirements and design

Living spec for the bare-Hyprland + chezmoi-managed configs approach picked
for the fresh reinstall. Evolves as the user adds requirements; not
comprehensive at any one time.

## Approach

- **Compositor**: Hyprland (native tiling, hard requirement).
- **Config ownership**: Claude-authored, committed to chezmoi. Opinionated
  dotfile packs (HyDE, ml4w, Caelestia) rejected — they save the *user*
  time, but the user has Claude do the tweaking, so packs only add
  drift-prone upstream layers without paying for themselves.
- **Theme system**: matugen (Material You, wallpaper-derived palette).
  Replaces the prior Catppuccin Mocha default — Catppuccin was never
  load-bearing, just what was picked from what was available one day.

## Components (pacman / AUR)

```
hyprland hypridle hyprlock hyprpolkitagent
waybar fuzzel mako cliphist wl-clipboard
swww grim slurp satty hyprshot
xdg-desktop-portal-gtk xdg-desktop-portal-hyprland
iio-hyprland-git wvkbd     # 2-in-1 (rotation, OSK)
matugen                    # AUR — wallpaper-derived theme generator
hyprexpo                   # Hyprland plugin — Mission-Control-style overview
pacseek                    # TUI fuzzy package installer (or a fuzzel-launched yay wrapper)
```

## Visual

- **Transparency / blur** via Hyprland's `decoration { blur, active_opacity, rounded }`.
- **Wallpaper rotation** — `swww` driven by a systemd user timer pointed at
  a wallpaper folder. Each rotation regenerates the matugen palette and
  reloads dependent components.
- **Dynamic accent** — matugen derives the full palette from the current
  wallpaper. No fixed palette.
- **Master dark / light switch** — `~/.local/bin/theme-toggle` flips the
  cached mode, runs matugen with the new mode against the current wallpaper,
  signals dependents to reload (waybar via SIGRTMIN+8, etc.). Propagates to:
  Hyprland colors, waybar, ghostty, GTK (gsettings), Qt (qt5ct/qt6ct), mako,
  fuzzel, VSCode (CLI). Three entry points:
  - hotkey (Super+Shift+T)
  - waybar bar icon (custom module, sun/moon glyph that flips on click)
  - fuzzel entry
  - Edge has no clean headless toggle → left as manual.

## Bar (waybar)

- Clock / date
- NetworkManager (network module)
- Volume (PipeWire)
- Tray — Bitwarden and other Status-Notifier-Item-aware apps. Older
  XEmbed-only apps won't show; that's a Wayland tray limit, not waybar.
- Battery
- Workspace pills with current highlighted
- Theme toggle icon (sun/moon), click flips dark/light

## Clipboard history

Windows-style picker (Win+V analog): every copy is captured to history,
hotkey opens a searchable list of recent items, pick one to paste.

- `cliphist` daemon (`wl-paste --watch cliphist store`) running as a
  systemd user service — captures text and image clips on every clipboard
  change.
- `Super+V` opens a fuzzel picker: `cliphist list | fuzzel --dmenu | cliphist decode | wl-copy`.
- History size: cap at a sensible number (default 750 items, tunable).
- No cross-device sync (intentionally — Bitwarden handles credential
  transport; we don't want clipboard contents leaving the machine).
- Pinning: cliphist doesn't pin natively; if pinning matters, a small
  wrapper script can mark items in a sidecar file. Defer until requested.

## Workspace switcher

- `hyprexpo` plugin — Mission-Control-style overview with live thumbnails.
  Bound to Super+Tab.

## Settings / control panel

- A fuzzel-launched script that surfaces "Display | Wifi | Bluetooth |
  Software | Sound | Power" and dispatches to the right tool
  (nwg-displays, nm-connection-editor, blueman-manager, pacseek,
  pavucontrol, etc.). User never has to remember `nwg-displays` by name.
- Bound to a hotkey (Super+comma or similar) and exposed as a desktop entry.

## Package management

- `pacseek` for the Omarchy-style fuzzy install/remove TUI. Decide during
  implementation whether to also wrap it in a fuzzel launcher for the
  master "Software" entry in the control-panel script.

## Power policy

- **systemd-logind drop-in** at `/etc/systemd/logind.conf.d/00-arch-setup.conf`:
  - `HandleLidSwitch=hibernate`           # battery
  - `HandleLidSwitchExternalPower=ignore` # AC, clamshell under desk
  - `HandleLidSwitchDocked=ignore`
- **hypridle** — lock on idle, DPMS off on longer idle. **No** idle-hibernate
  timer — the user explicitly does not want hibernation triggered while on AC
  regardless of activity.

### Hibernate, not suspend

Modern Intel laptops use s2idle ("modern standby") instead of S3 suspend.
s2idle keeps the CPU in a low-power but warm state — sealed in a bag with
no ventilation, this overheats. **S4 hibernate** dumps RAM to swap and
fully powers off. Wake is ~5–10 sec; state preserved. This is the only
correct answer for the user's bag-stuff-it-and-go workflow.

### Hibernate infrastructure (touches `chroot.sh` — architectural change)

- **Persistent** swap encryption (current cryptswap regenerates a random
  key per boot — can't decrypt on resume). Two viable patterns:
  1. LUKS swap unlocked by a TPM2-sealed keyfile (same model as cryptvar).
  2. LUKS swap unlocked by the same keyfile as root.
- Swap ≥ RAM. Metis: 16 GB RAM, 16 GB swap partition — exactly enough
  (tight but workable for typical workloads on a fresh-cache hibernate).
- Kernel cmdline: add `resume=UUID=<swap-LUKS-mapper>`.
- mkinitcpio: add `resume` hook before `filesystems` in HOOKS.

### Monitor handoff on lid close

Hyprland monitor config needs `workspace=N,monitor:DP-1` fallbacks for any
workspace currently bound to eDP-1, so workspaces migrate to the external
display when the lid closes rather than orphaning.

## Carry-forwards (cleanup when dotfiles land)

References to Catppuccin in the rest of the repo become stale once matugen
takes over and need to be reworked:

- `phase-3-arch-postinstall/postinstall.sh` — drops `catppuccin-sddm-theme-mocha`
  from the AUR list and the verify check; ghostty config no longer pinned to
  `Catppuccin Mocha`.
- `docs/decisions.md` — §Q on theme.
- `runbook/GLOSSARY.md` — Catppuccin entry.
- SDDM theme — pick a matugen-driven theme or a neutral default.

## Carried 2-in-1 packages (still required)

`iio-hyprland-git` (rotation), `hyprgrass` (touch gestures), `wvkbd` (OSK)
remain — these are hardware-driver-level on Hyprland, not theme-pack
dependencies.

## Non-requirements

- Comprehensive list — the user flagged this is what they thought of in one
  sitting; expect additions.
- ml4w-style GUI settings app — nice to have, not required.
- Compatibility with any upstream dotfile pack — we own configs end-to-end.
