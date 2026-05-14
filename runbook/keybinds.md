# Hyprland keybinds

> Hand-curated cheat sheet. Mirror any change to `~/.config/hypr/binds.conf`
> (chezmoi source: `dots/home/dot_config/hypr/binds.conf`). The validator
> `~/.local/bin/validate-hypr-binds` catches duplicate `(MOD, KEY)` pairs
> and unknown dispatchers on every `chezmoi apply`.
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
| `Super + I` | Bitwarden |
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
| `Super + /` | Keybinds cheatsheet popup (hypr-cheatsheet) |

## Theme + system

| Keys | Action |
|---|---|
| `Super + Ctrl + T` | Flip dark / light theme |
| `Super + Alt + H` | Hibernate now |
| `Super + Alt + L` | Lock screen now |
| `Super + Ctrl + R` | Reload Hyprland + waybar |
| `Super + Ctrl + B` | Toggle waybar |
| `Super + Shift + W` | Reshuffle hyprmural wallpapers |

## Window management

| Keys | Action |
|---|---|
| `Super + Q` | Close window |
| `Super + Ctrl + Q` | Power menu (wleave) |
| `Super + T` | Toggle floating |
| `Super + M` | Toggle horizontal / vertical split |
| `Super + U` | Maximize (no bar) |
| `Super + F11` | Fullscreen (true) |
| `Super + Ctrl + P` | Pin floating window |
| `Super + G` | Toggle group (tabs) |
| `Super + ]` / `Super + [` | Group tab next / previous |
| `Super + R` | Resize submap (then h/j/k/l, Esc/Enter to exit) |

## Layout switchers (whole workspace)

| Keys | Action |
|---|---|
| `Super + Alt + T` | Tile all (dwindle) |
| `Super + Alt + F` | Float all |
| `Super + Alt + B` | Tab all |
| `Super + Alt + S` | Toggle scrolling layout (dwindle ↔ scrolling) |
| `Super + Alt + K` | Toggle tablet mode (manual override) |

## Focus

| Keys | Action |
|---|---|
| `Super + h` / `Super + Left` | Focus left (edge → prev workspace) |
| `Super + j` / `Super + Down` | Focus down |
| `Super + k` / `Super + Up` | Focus up |
| `Super + l` / `Super + Right` | Focus right (edge → next workspace) |

## Move window

| Keys | Action |
|---|---|
| `Super + Ctrl + h/j/k/l` | Move window (vim) |
| `Super + Ctrl + arrow keys` | Move window (edge → adjacent workspace + follow) |

## Workspaces

| Keys | Action |
|---|---|
| `Super + 1..5` | Switch to workspace 1-5 (DP-1 / external Vizio) |
| `Super + 6..9` | Switch to workspace 6-9 (eDP-1 / internal) |
| `Super + 0` | Toggle scratchpad workspace |
| `Super + Alt + 1..9` | Send window to workspace (stay) |
| `Super + Alt + 0` | Send window to scratchpad (stay) |
| `Super + Ctrl + 1..9` | Send window to workspace and follow |
| `Super + Ctrl + 0` | Send window to scratchpad and follow |
| `Super + Ctrl + Left/Right` | Send window to prev/next workspace and follow |
| `Super + Tab` | Last-used workspace |
| `` Super + grave (`) `` | Workspace overview (Hyprspace — drag windows to move) |

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
| `Alt + PrintScreen` | Active window |
| `Ctrl + PrintScreen` | Full screen (output) |
| `Super + PrintScreen` | Region → satty (annotate) |

## Notes

- Display turns off after **28 minutes** idle (DPMS); lock fires at **30 minutes** idle.
- Hibernate is **manual only** (Super+Alt+H or control panel) until
  the dead battery is replaced — AC unplug is a hard cut, no graceful
  hibernate is possible from lid-close + unplug.
- Workspace strategy is **monitor-bound**: 1-5 always live on the Vizio,
  6-9 always on the internal panel. A workspace 6-9 with no internal
  monitor available migrates to the Vizio automatically (lid-close-ready).
- All bindings are validated on every `chezmoi apply` —
  `validate-hypr-binds` flags duplicate `(MOD, KEY)` pairs and unknown
  dispatchers. SwayOSD also pops up on every dispatched bind, so
  unbound keys are visually obvious.
