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
# Compositor + core
hyprland hypridle hyprlock hyprpolkitagent

# Greeter
greetd greetd-regreet

# Bar, notifications, launcher
waybar swaync fuzzel

# Clipboard, wallpaper, screenshots
cliphist wl-clipboard swww
grim slurp satty hyprshot

# Theming + cursor + icon
matugen                          # AUR — wallpaper-derived palette
nwg-look qt5ct qt6ct             # GTK + Qt theme managers
papirus-icon-theme               # icon theme (max app coverage)
bibata-cursor-theme-hyprcursor   # AUR — hyprcursor format, ~6.6 MB

# OSD popups (volume / brightness / caps-lock)
swayosd

# Reachable from the fuzzel control-panel
nwg-displays                     # display config
network-manager-applet           # provides nm-connection-editor
overskride                       # AUR — Bluetooth (GTK4)
pwvucontrol                      # PipeWire-native audio mixer
mission-center                   # AUR — resource/process monitor (GUI)
pacseek                          # AUR — TUI package install/remove

# Daily-use viewers
imv                              # image viewer
zathura zathura-pdf-poppler      # PDF viewer (Xwayland; modal keys)

# Power menu, color picker
wleave hyprpicker                # both AUR

# Hyprland plugins
hyprexpo                         # Mission-Control-style overview

# Portals
xdg-desktop-portal-gtk xdg-desktop-portal-hyprland

# 2-in-1 hardware
iio-hyprland-git hyprgrass wvkbd
```

## Greeter

**greetd + ReGreet** replaces the prior SDDM choice. greetd is a tiny daemon
that handles "show login UI, then start session"; ReGreet is the GTK4 UI it
displays. Together ~3 MB vs SDDM's ~21 MB.

Why switched:
- Theme is plain GTK CSS — matugen output drops in directly. SDDM's Qt
  theme was a separate maintenance surface (the `catppuccin-sddm-theme-mocha`
  package goes away with this switch).
- Wayland-native; no Qt/Xorg legacy paths.
- Fingerprint at greeter still works via the same PAM stack — load-bearing
  per `decisions.md:17` (no battery → no suspend cycles → greeter is the
  one auth moment of the day).

Config: `/etc/greetd/config.toml` with `command = "Hyprland"` for direct
session launch. ReGreet's CSS lives at `/etc/greetd/regreet.css` (matugen
template target).

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

## Notifications (swaync)

**SwayNotificationCenter** replaces the prior mako choice. Same popup
behavior, plus a pull-out panel showing notification history, a
do-not-disturb toggle, and room for widgets.

Why switched:
- Notification history matters when "did Bitwarden finish syncing?" or
  "did the build notify me?" come up — mako gives no recall once the
  popup fades.
- Themed via GTK CSS — matugen template drops in directly. mako uses INI
  + its own color scheme; swaync's CSS aligns with the rest of the stack.
- Pairs naturally with the bar-icon + fuzzel control-panel pattern: a
  waybar icon shows unread count, click pulls the panel.

Bindings: hotkey (Super+N) toggles the panel; bar icon click does the
same; fuzzel control-panel entry "Notifications" same.

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

## Workspace strategy

**Static + monitor-bound.**

- Workspaces 1-5 bound to **DP-1** (external Vizio, primary at the desk)
- Workspaces 6-9 bound to **eDP-1** (internal panel)
- Workspace 10 is a **scratch / floating workspace** — no monitor binding,
  summoned wherever the user is. Used for ephemeral things (a quick note,
  a calculator, a one-off browser tab).

Static (always exists, doesn't disappear when empty) for predictable
muscle-memory: "Slack is on 4, browser on 1" stays true. Monitor-bound so
that closing the lid (post-battery-replacement) cleanly drops the
internal-only workspaces without orphaning.

Hyprland config: `workspace = N, monitor:DP-1` for each workspace, plus
`monitor = DP-1, preferred, 0x0, 1.5` and `monitor = eDP-1, preferred, 0x1440, 1`
to match the locked-in nwg-displays layout (Vizio at 0,0 scale 1.5, internal at 0,1440 scale 1).

## Keybinds

**Rich custom set** (~60-80 bindings) — the "design once, internalize over
a week, never mouse again" approach. Justified by the keyboard-ninja
requirement and the "Claude does the tweaking" clarification — the
upfront design cost is amortized across daily use forever.

Binding categories:
- Window/workspace nav: focus neighbors, swap, send-to-workspace, last-workspace toggle
- App quicklaunches: `Super+B` browser, `Super+C` Claude Code, `Super+E` editor (VSCode), `Super+Return` Ghostty, `Super+F` files (yazi or nautilus)
- Layout: split direction, master/dwindle toggle, resize submap, toggle floating, toggle pinned
- Workspace overview: `Super+Tab` last-workspace; `Super+grave` hyprexpo overview
- System: `Super+Shift+T` theme toggle, `Super+Shift+H` hibernate, `Super+Shift+L` lock now, `Super+N` notification panel, `Super+V` clipboard picker, `Super+,` settings panel
- Capture: `PrtSc` region screenshot, `Shift+PrtSc` window, `Ctrl+PrtSc` full screen, `Super+P` color picker
- Media keys: volume up/down/mute, brightness up/down, mic mute (handled by SwayOSD)

Ships with a printable **cheat sheet** at `runbook/keybinds.md` that
`pnpm pdf` renders alongside the install runbook. First-week reference.

Full binding list lives in `hyprland.conf` (Claude-authored when configs
are written) — this section locks the *philosophy*, not the literal
bytes.

## Workspace overview (within the strategy above)

- `hyprexpo` plugin — Mission-Control-style overview with live thumbnails.
  Bound to `Super+grave` (the key above Tab).
- Workaround for hyprexpo issue #138 (focus stuck after clicking current workspace):
  always dispatch `workspace,e+0` before `hyprexpo:expo,off` in the bind.

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
  - `HandleLidSwitch=hibernate`           # battery — dead code today, live when battery returns
  - `HandleLidSwitchExternalPower=ignore` # AC, clamshell under desk
  - `HandleLidSwitchDocked=ignore`
- **hypridle** — lock on idle, DPMS off on longer idle. **No** idle-hibernate
  timer — the user explicitly does not want hibernation triggered while on AC
  regardless of activity.

### Manual hibernate workflow (current, until battery is replaced)

The internal battery is dead/disconnected (`decisions.md:13`), so when AC
unplugs the laptop hard-cuts instantly — no graceful hibernate is possible
on lid-close-then-unplug. Until a battery is swapped in, hibernate must be
**user-invoked** before unplugging:

- Hotkey: `Super+Shift+H` → `systemctl hibernate`
- Same action exposed in the fuzzel control-panel script (Power → Hibernate)
- Optional waybar power button (custom module) for click-to-hibernate

The logind config above is intentionally future-correct: the `HandleLidSwitch`
branch fires only on battery state and is harmless dead code without one.
When the user swaps in a new battery, lid-close-on-battery starts firing
hibernate automatically — no reconfiguration required.

### Hibernate, not suspend

Modern Intel laptops use s2idle ("modern standby") instead of S3 suspend.
s2idle keeps the CPU in a low-power but warm state — sealed in a bag with
no ventilation, this overheats. **S4 hibernate** dumps RAM to swap and
fully powers off. Wake is ~5–10 sec; state preserved. This is the only
correct answer for the user's bag-stuff-it-and-go workflow.

**This reverses `docs/decisions.md:15`** ("Hibernation is disabled — dual-boot
+ BitLocker would make it risky anyway"). The cited dual-boot/BitLocker risk
doesn't actually apply: Linux swap lives on the Netac (sdb2), Windows has
no driver for LUKS or btrfs and never touches sdb. Worst-case if Windows
boots between hibernate and resume is a TPM2 PCR drift → passphrase
fallback at resume. Not corrupting. `decisions.md:15` needs to be flipped
when these scripts land.

### Hibernate infrastructure (touches `chroot.sh` + `install.sh` — architectural change)

- **Persistent LUKS swap, unlocked by a TPM2-sealed keyfile** — mirrors the
  existing cryptvar pattern (`/etc/cryptsetup-keys.d/cryptvar.key`). Replaces,
  not augments, the current random-key cryptswap (`install.sh:334-337`,
  `chroot.sh:136`).
- Swap ≥ RAM. Metis: 16 GB RAM, 16 GB swap partition — exactly enough
  (tight but workable for typical workloads on a fresh-cache hibernate).
- Kernel cmdline: add `resume=/dev/mapper/cryptswap`.
- mkinitcpio: add `resume` hook AFTER `block`/`sd-encrypt` and BEFORE
  `filesystems` in HOOKS.
- **Pacman post-transaction hook** to re-run `systemd-cryptenroll
  --tpm2-pcrs=0+7` on every `linux`, `mkinitcpio`, and `limine` upgrade.
  Without this, every kernel bump shifts PCR 4 and demands the LUKS
  passphrase on next resume. Hook drops in `/etc/pacman.d/hooks/`.

### TPM2 prep — one-time, before any cryptenroll

The current install seals against the SHA-1 PCR bank because Intel PTT
firmware on Whiskey Lake ships with only `pcr-sha1` allocated and
`systemd-cryptenroll` silently falls back. SHA-1 still works but is
trending toward deprecation. Since the reinstall is fresh, do it right:

1. **Before reinstall**, on the current Arch: `fwupdmgr refresh && fwupdmgr update`
   to take Dell BIOS from 1.16 → ~1.18. Picks up any PTT firmware fixes
   since 2022.
2. **Early in `install.sh`**, before any `systemd-cryptenroll` call:
   `tpm2_pcrallocate sha256:all+sha1:all`, then reboot the TPM (or whole
   machine — simpler). Verify `tpm2_getcap pcrs` shows both banks
   populated. If Intel PTT only allows one active bank at a time on this
   model, choose `sha256` over `sha1`.
3. Then enrol root, var, and swap LUKS — all will pick up
   `tpm2-pcr-bank: sha256` automatically.

Slot inventory headroom: 17 free persistent handles, 2039 free NV indices.
No slot exhaustion risk for any planned sealing.

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

## Implementation notes (from 2026-04 validation pass)

Things to bake into the install / first-boot scripts that aren't decisions
themselves:

- **Drop Electron `--ozone-platform=wayland` flags.** Electron is Wayland-native
  by default since late 2025 — Edge/VSCode/Claude Desktop don't need the
  flag anymore. The `claude-desktop-native` `.desktop` and any
  arch-setup-shipped wrappers should be cleaned up. (Discord's bundled
  Electron build still wants the flag — leave it there.)
- **Use the freedesktop color-scheme portal for theme broadcast.** GTK4,
  libadwaita, Firefox, Chromium, Qt 6.9+ all read it. The theme-toggle
  script should `busctl --user set-property org.freedesktop.portal.Desktop
  /org/freedesktop/portal/desktop org.freedesktop.impl.portal.Settings ...`
  in addition to the per-component CSS reloads. Edge/Bitwarden pick it up
  automatically.
- **Nudge the portal on resume.** `xdg-desktop-portal-hyprland` can race
  with apps started right after `systemd-resume` — apps that read the
  color scheme at startup never re-query. Add a `dispatcher = on,resume,...`
  in hypridle config to trigger a re-broadcast.
- **hyprexpo workaround for issue #138.** Clicking the currently-visible
  workspace in the overview leaves focus stuck. In the keybind, always
  dispatch `workspace,e+0` before `hyprexpo:expo,off`. If this ever
  blocks, **Hyprspace** (KZDKM) is a config-compatible swap.
- **TPM2 PCR re-enrolment hook** — covered in the Hibernate section above.
  Required for kernel/UKI/limine updates on a hibernate-enabled system.

## Non-requirements

- Comprehensive list — the user flagged this is what they thought of in one
  sitting; expect additions.
- ml4w-style GUI settings app — nice to have, not required.
- Compatibility with any upstream dotfile pack — we own configs end-to-end.
