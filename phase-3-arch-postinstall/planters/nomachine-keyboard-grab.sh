#!/usr/bin/env zsh
# arch: enable "Enable active keyboard grabbing" in nxplayer's player.cfg.
# Under Wayland+XWayland (Hyprland), the X11 XGrabKeyboard call is what
# gets relayed to the compositor via zwp_xwayland_keyboard_grab_v1, so
# global Super-* combos (Win+E, etc.) reach the remote session instead
# of firing local Hyprland binds. NoMachine ships this gated behind a
# separate config option (per-session "Grab keyboard" is Qt-level only,
# too late in the dispatch chain to win against the compositor). Self-
# deleting; one-shot. Re-run by setting the value back to false in
# ~/.nx/config/player.cfg and re-planting (postinstall §13b, or manual
# `cp` from ~/src/arch-setup@fnrhombus/phase-3-arch-postinstall/planters/).
#
# Skipped during postinstall's zgenom warmup (which sources this file too).
if [[ -n "${_POSTINSTALL_NONINTERACTIVE:-}" ]]; then
    return 0
fi
# `[[ -o interactive ]]`, not `[[ -t 0 ]]`: powerlevel10k's instant-prompt
# redirects fd 0 during .zshrc init, so `-t 0` returns false in any
# Ghostty/Hyprland zsh that uses p10k — the planter would silently
# return 0 every login. The actual question is whether the shell
# itself is interactive, which is what `-o interactive` answers.
[[ -o interactive ]] || return 0

_cfg="$HOME/.nx/config/player.cfg"
_planter_file="$HOME/.local/share/arch-setup-bootstraps/nomachine-keyboard-grab.sh"

# Config not yet created? nxplayer writes it on first launch — wait.
if [[ ! -f "$_cfg" ]]; then
    unset _cfg _planter_file
    return 0
fi

# Already correct? Self-delete and move on.
if grep -qF 'Enable active keyboard grabbing" value="true"' "$_cfg"; then
    rm -f "$_planter_file"
    unset _cfg _planter_file
    return 0
fi

# nxplayer rewrites player.cfg from in-memory state on exit (same trap
# as Remmina with *.remmina). Editing while it's running gets clobbered
# and the planter would self-delete before the change becomes durable.
# Defer to a future login where the user isn't running it.
if pgrep -x nxplayer.bin >/dev/null 2>&1; then
    unset _cfg _planter_file
    return 0
fi

# Flip the value. Temp file alongside the original keeps the mv atomic
# (same filesystem) so a partial write can't corrupt nxplayer's XML.
_tmp="${_cfg}.planter-tmp.$$"
if sed 's|\(<option key="Enable active keyboard grabbing" value="\)false\("[[:space:]]*/>\)|\1true\2|' \
        "$_cfg" > "$_tmp" \
        && grep -qF 'Enable active keyboard grabbing" value="true"' "$_tmp"; then
    chmod --reference="$_cfg" "$_tmp" 2>/dev/null
    mv -- "$_tmp" "$_cfg"
    echo "arch: nomachine-keyboard-grab — active grabbing enabled in player.cfg."
    rm -f "$_planter_file"
else
    rm -f "$_tmp"
    echo "arch: nomachine-keyboard-grab planter — pattern not found or sed failed in $_cfg." >&2
fi
unset _cfg _planter_file _tmp
