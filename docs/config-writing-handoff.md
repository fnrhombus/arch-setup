# Config-writing handoff — bare Hyprland dotfiles

You are picking up a fresh task: **author every dotfile and helper script** the
new bare-Hyprland desktop will use after the upcoming Arch reinstall on
"Metis" (Dell Inspiron 7786, dual-boot, owner: `tom`). The user wants no
pre-built dotfile packs (HyDE, ml4w, Caelestia all rejected). All configs
are authored by Claude end-to-end and managed by `chezmoi`.

## Read these first, in order

1. **`docs/decisions.md`** — locked decisions. Pay attention to:
   - §K Theme = **matugen** (Material You from wallpaper) — NOT Catppuccin
   - §D Login screen = **greetd + ReGreet** — NOT SDDM
   - §E Notifications = **swaync** (with history panel) — NOT mako
   - §H App launcher = **fuzzel**
   - §J Font = **JetBrains Mono Nerd** (literal name `"JetBrainsMono Nerd Font"`)
   - §L Dotfiles = **chezmoi**
   - The "Desktop component picks (locked 2026-04-22)" block lists the
     small picks (OSD = SwayOSD, power menu = wleave, color picker =
     hyprpicker, image viewer = imv, PDF = zathura, cursor = Bibata
     hyprcursor format, icon = Papirus-Dark, GTK theme manager = nwg-look,
     Qt = qt6ct + qt5ct, resource monitor = mission-center, audio mixer =
     pwvucontrol, Bluetooth = overskride, network = nm-connection-editor +
     custom waybar module).

2. **`docs/desktop-requirements.md`** — full spec for the bare-Hyprland +
   chezmoi-managed approach. This is the source of truth for components,
   bar contents, workspace strategy, keybind philosophy, theme pipeline,
   power policy, hibernate plan, and implementation gotchas. Read every
   word before writing anything.

3. **`docs/reinstall-planning.md`** — bootloader = **limine** (per §3),
   Secure Boot = on via `sbctl` + `--microsoft` (per §2), §5 covers the
   PAM authentication stacks (PIN / fingerprint / password) you'll need
   to mirror in the greetd config.

4. **`CLAUDE.md`** — repo layout + conventions (atomic commits, parallel
   tool calls, never push without asking, etc.).

5. **`phase-3-arch-postinstall/postinstall.sh`** §13 — already invokes
   `chezmoi init --source=/root/arch-setup/dotfiles && chezmoi apply --force`
   against the in-repo dotfiles tree. No rewrite needed; this is the
   active code path.

## Architectural questions to resolve with the user before writing

These are unanswered. Don't pick unilaterally:

1. **Chezmoi source location**: in-repo subdirectory (e.g.
   `dotfiles/`) or a separate repo (e.g. `fnrhombus/dotfiles`)? The
   former couples configs to the install scripts and lets one PR move
   both; the latter follows the chezmoi convention and makes future
   machines portable. The current main session leaned separate-repo,
   user did not commit either way.

2. **Branch policy**: All in-flight work has been on `desktop-design`.
   If the chezmoi source is in this repo, commit on `desktop-design`
   atomically and don't push until the user reviews. If it's a
   separate repo, you'll be initializing a new one — use the same
   atomic-commit, don't-push-without-asking discipline.

3. **Wallpaper bootstrap**: matugen derives the palette from the
   *current wallpaper*. There must be a default wallpaper baked in for
   first-boot (otherwise the palette is undefined). Pick one with the
   user, or ship a placeholder + a swap procedure.

## What you are writing

Group A — **Hyprland core configs** (bound to atomic-commit boundaries):
- `hyprland.conf` (entry point, sources fragments below)
- `hyprland/monitors.conf` — DP-1 @ 1.5, eDP-1 @ 1, positions per
  desktop-requirements.md "Workspace strategy"
- `hyprland/workspaces.conf` — 1-5 → DP-1, 6-9 → eDP-1, 10 = scratch
- `hyprland/binds.conf` — full ~60-80 bindings per
  desktop-requirements.md "Keybinds" section. Remember `Super+B`/`+C`/
  `+E`/`+Return`/`+F` quicklaunches; `Super+Tab` last-workspace;
  `Super+grave` Hyprspace overview; `Super+Shift+T` theme toggle;
  `Super+Shift+H` hibernate; `Super+Shift+L` lock-now; `Super+N`
  notifications; `Super+V` clipboard; `Super+,` settings panel.
- `hyprland/decoration.conf` — blur, rounded, opacity
- `hyprland/animations.conf` — sane defaults, not flashy
- `hyprland/input.conf` — keyboard, touchpad (natural scroll +
  tap-to-click), per-device touch tablet binding
- `hyprland/exec.conf` — `exec-once` list. MUST INCLUDE:
  `bitwarden-desktop`, `waybar`, `swaync`, `swww-daemon`, `cliphist
  store` (via `wl-paste --watch`), `swayosd-server`, `hypridle`,
  `hyprpaper` if used (probably not — swww instead), and the matugen
  initial-render call.
- `hyprland/post-plugins.d/hyprspace.conf` — Hyprspace config
  (`autoDrag`, `switchOnDrop`) + `Super+grave → overview:toggle` bind
- `hypridle.conf` — `1800s → loginctl lock-session`,
  `1800s → hyprctl dispatch dpms off`, `on-resume → dpms on`,
  `before-sleep → loginctl lock-session`
- `hyprlock.conf` — match the matugen palette, allow PIN +
  fingerprint per the PAM stack (pinpam first, fprintd 5s, password)

Group B — **Bar / notifications / launcher**:
- `waybar/config.jsonc` — modules per desktop-requirements.md "Bar"
  section. Tray, clock, network (custom nmcli module), volume
  (PipeWire), workspace pills, battery, theme-toggle icon. Bitwarden
  auto-shows in the tray once it's running and the SNI bridge is up.
- `waybar/style.css` — matugen template, Catppuccin references gone
- `waybar/modules/network.sh` — nmcli wrapper for the custom module
- `waybar/modules/theme-toggle.sh` — sun/moon glyph, click-to-flip
- `swaync/config.json` — matches dnd toggle hotkey + bar icon
- `swaync/style.css` — matugen template
- `fuzzel/fuzzel.ini` — matugen template

Group C — **Terminal / file / viewer configs**:
- `ghostty/config` — theme tokens come from matugen, not literal hex.
  Drop the `theme = "Catppuccin Mocha"` line entirely.
- `yazi/yazi.toml` + `theme.toml` (matugen template)
- `helix/config.toml` (theme = matugen-generated)
- `imv/config` — minimal
- `zathura/zathurarc` — matugen template

Group D — **Greeter (greetd + ReGreet)**:
- `/etc/greetd/config.toml` (NOT chezmoi — system-level; postinstall
  writes it. You provide the content; user wires the `tee` block into
  postinstall.sh.) `command = "Hyprland"`.
- `/etc/greetd/regreet.css` — matugen template

Group E — **Theme pipeline (the heart of this work)**:
- `matugen/config.toml` — declares every template + output path + the
  reload command for each consumer.
- `matugen/templates/*` — one template per consumer above. Same
  `{{colors.primary.default.hex}}` syntax across all of them.
- `~/.local/bin/theme-toggle` — flips dark/light cached mode, runs
  `matugen --mode <mode> <wallpaper>`, broadcasts via the
  freedesktop color-scheme portal (per desktop-requirements.md
  "Implementation notes" line 357), reloads dependents (waybar
  SIGRTMIN+8, swaync `swaync-client --reload-css`, fuzzel re-read on
  next launch, ghostty via control sequence, GTK via `gsettings`, Qt
  via qt6ct config rewrite).
- `~/.local/bin/wallpaper-rotate` — picks next wallpaper from a
  folder, sets via `swww img`, re-runs matugen, calls theme-toggle
  with the cached mode preserved.
- systemd user timer for `wallpaper-rotate` — every N hours
  (let user pick interval).

Group F — **Helpers + control panel**:
- `~/.local/bin/control-panel` — fuzzel-launched menu (Display | Wifi
  | Bluetooth | Software | Sound | Power | Notifications), dispatches
  to `nwg-displays`, `nm-connection-editor`, `overskride`, `pacseek`
  (in a ghostty), `pwvucontrol`, wleave, `swaync-client -t` per
  user pick.
- `~/.local/bin/validate-hypr-binds.sh` — parses `hyprland.conf` +
  all `source =` includes, enumerates `bind = MOD, KEY, ...` lines,
  flags duplicates and unknown dispatchers, exits non-zero on any
  issue. Same script regenerates `runbook/keybinds.md` from the
  bindings (auto cheat sheet, can't drift).
- `.chezmoiscripts/run_before_validate-binds.sh.tmpl` — chezmoi
  pre-apply hook calling validate-hypr-binds.sh; fail = chezmoi
  refuses to apply.

Group G — **Cheat sheet output**:
- `runbook/keybinds.md` — generated by validate-hypr-binds.sh, but
  commit a hand-checked snapshot so `pnpm pdf` can render it before
  first chezmoi apply.

## Hard rules

- **No Catppuccin references anywhere.** Every color is matugen-templated.
  desktop-requirements.md "Carry-forwards" lists files to clean.
- **No `--ozone-platform=wayland` Electron flags** in any wrapper or
  `.desktop` you ship — Electron is Wayland-native by default since
  late 2025 (per desktop-requirements.md line 350-354). The exception
  is Discord's bundled Electron (irrelevant here).
- **NEVER remove `pam_unix.so` from any auth stack** — last-resort
  password path.
- **PAM module name is `libpinpam.so`, NOT `pam_pinpam.so`** — the
  pinpam-git package ships with the wrong-feeling name. Any greetd
  PAM stack you write must reference `libpinpam.so`. See
  `phase-3-arch-postinstall/postinstall.sh` §7a for the established
  pattern (sudo + hyprlock); mirror it for greetd.
- **Workspace strategy is monitor-bound**, but every workspace bound
  to eDP-1 needs a fallback `monitor:DP-1` so they migrate cleanly
  when the lid closes (post-battery-replacement, but configure now).
- **Workspace overview is Hyprspace, not hyprexpo.** Different namespace
  (`plugin:overview:*`), different dispatcher (`overview:toggle`), and
  no issue-138 workaround needed (Hyprspace handles focus correctly).

## Workflow

- **Atomic commits**, one logical change per commit. Group your
  work along the Group A-G boundaries above when sensible (e.g.
  "hyprland: add base config + sourced fragments", "matugen: add
  pipeline + templates for waybar/swaync/fuzzel"), don't bundle
  unrelated changes.
- **Don't push** without the user's explicit go-ahead. Commit
  locally on the branch they direct you to (likely `desktop-design`
  if the source goes in-repo, else a fresh branch on the new repo).
- **Bitwarden SSH agent for signing**: if `ssh-add -L` fails,
  `export SSH_AUTH_SOCK=/home/tom/.bitwarden-ssh-agent.sock` first.
  If the socket itself doesn't exist, stop and ask the user to open
  Bitwarden Desktop with the SSH-agent toggle on.
- **Run things in parallel** when independent (multiple file writes,
  multiple sub-tasks). Don't serialize what doesn't depend.
- **Don't relitigate decisions.** The user has signed off on bare
  Hyprland, matugen, greetd, limine, hibernate-on, etc. If a config
  choice forces a reopened decision, ASK before writing — don't
  unilaterally drift.

## What you are NOT writing

- The chezmoi `init`/`apply` invocations in `postinstall.sh` —
  user does that pass after your source tree exists.
- The limine bootloader install — separate task.
- The Secure Boot enrollment — separate task.
- The TPM2 PCR allocation script — separate task (covered in
  desktop-requirements.md "TPM2 prep").
- The actual reinstall execution.
- Anything on `phase-1-iso/` (the custom Arch ISO build).

## Branch state when you start

- **`desktop-design`** has all in-flight work — the desktop
  redesign docs, the corrected PAM stacks for sudo/hyprlock,
  hibernate plan, etc. Confirm with the user whether to land
  your work here or on a fresh branch.
- **`reinstall-plan`** is stale — pre-libpinpam fix and pre-design
  changes. Don't base off it.
- **`main`** is the published baseline at the moment of writing
  (the prior HyDE-era install on Metis). The active design lives on
  `desktop-design`; merge to main once the reinstall is verified.

## Open question to surface in your first reply

Once you've read the four docs above, before you write anything,
confirm: (a) chezmoi source location decision, (b) initial wallpaper
pick or placeholder, (c) wallpaper-rotation interval, (d) which
branch to commit on. Those four answers unblock the rest.
