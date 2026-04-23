# Hyprland keybinds

> Initial hand-checked snapshot. After first `chezmoi apply`,
> `~/.local/bin/validate-hypr-binds --emit-cheatsheet` regenerates this
> file from `~/.config/hypr/binds.conf` so it can never drift.
>
> `Super` = the Windows / Command key.

## App quicklaunches

| Keys | Action |
|---|---|
| `Super + Return` | Ghostty (terminal) |
| `Super + B` | Microsoft Edge (browser) |
| `Super + C` | Claude Code (in Ghostty) |
| `Super + E` | VSCode |
| `Super + F` | Nautilus (file manager) |
| `Super + Y` | Yazi (TUI files, in Ghostty) |
| `Super + Space` | Fuzzel app launcher |

## Pickers + utilities

| Keys | Action |
|---|---|
| `Super + V` | Clipboard history picker |
| `Super + P` | Color picker (hyprpicker) |
| `Super + ,` | Control panel (settings menu) |
| `Super + N` | Toggle notification panel |
| `Super + ;` | Emoji picker |

## Theme + system

| Keys | Action |
|---|---|
| `Super + Shift + T` | Flip dark / light theme |
| `Super + Shift + H` | Hibernate now |
| `Super + Shift + L` | Lock screen now |
| `Super + Shift + R` | Reload Hyprland config |
| `Super + Shift + W` | Rotate wallpaper now |

## Window management

| Keys | Action |
|---|---|
| `Super + Q` | Close window |
| `Super + Shift + Q` | Power menu (wleave) |
| `Super + T` | Toggle floating |
| `Super + M` | Toggle split direction |
| `Super + U` | Maximize (no bar) |
| `Super + F11` | Fullscreen |
| `Super + Shift + P` | Pin floating window |
| `Super + G` | Toggle group (tabs) |
| `Super + R` | Resize submap (then h/j/k/l, Esc to exit) |

## Focus

| Keys | Action |
|---|---|
| `Super + h` / `Super + Left` | Focus left |
| `Super + j` / `Super + Down` | Focus down |
| `Super + k` / `Super + Up` | Focus up |
| `Super + l` / `Super + Right` | Focus right |

## Move window

| Keys | Action |
|---|---|
| `Super + Shift + h/j/k/l` | Move window |
| `Super + Shift + arrow keys` | Move window (alt) |

## Workspaces

| Keys | Action |
|---|---|
| `Super + 1..5` | Switch to workspace 1-5 (DP-1 / external Vizio) |
| `Super + 6..9` | Switch to workspace 6-9 (eDP-1 / internal) |
| `Super + 0` | Toggle scratch workspace |
| `Super + Shift + 1..9` | Send window to workspace |
| `Super + Shift + 0` | Send window to scratch |
| `Super + Tab` | Last-used workspace |
| `Super + grave` (\`) | Workspace overview (hyprexpo) |

## Mouse

| Action | Effect |
|---|---|
| `Super + Left-drag` | Move window |
| `Super + Right-drag` | Resize window |
| `Super + Scroll wheel` | Cycle workspaces |

## Media keys (SwayOSD wraps these to show the popup)

| Key | Action |
|---|---|
| `Volume Up / Down` | Output volume ± (with OSD) |
| `Volume Mute` | Mute output |
| `Mic Mute` | Mute input |
| `Brightness Up / Down` | Display brightness ± |
| `Play / Pause / Next / Prev` | Media keys (playerctl) |

## Screenshots — saved to `~/Pictures/Screenshots/`

| Keys | Action |
|---|---|
| `PrintScreen` | Region screenshot |
| `Shift + PrintScreen` | Active window |
| `Ctrl + PrintScreen` | Full screen |
| `Super + PrintScreen` | Region → satty (annotate) |

## Notes

- Lock + DPMS off both fire after **30 minutes** idle.
- Hibernate is **manual only** (Super+Shift+H or control panel) until
  the dead battery is replaced — AC unplug is a hard cut, no graceful
  hibernate is possible from lid-close + unplug.
- Workspace strategy is **monitor-bound**: 1-5 always live on the Vizio,
  6-9 always on the internal panel. A workspace 6-9 with no internal
  monitor available migrates to the Vizio automatically (lid-close-ready).
- All bindings are validated on every `chezmoi apply` —
  `validate-hypr-binds` flags duplicate `(MOD, KEY)` pairs and unknown
  dispatchers. SwayOSD also pops up on every dispatched bind, so
  unbound keys are visually obvious.
