#!/usr/bin/env zsh
# arch: seed the WinApps Windows VM RDP password from
# ~/.config/winapps/winapps.conf into the GNOME keyring, where Remmina's
# libsecret plugin (org.remmina.Password schema) finds it at connect time.
# Self-deleting; one-shot. Re-run by deleting the keyring entry
# (`secret-tool clear filename ~/.config/remmina/Windows.remmina key password`)
# and re-planting (postinstall §13b, or manual `cp` from
# ~/src/arch-setup@fnrhombus/phase-3-arch-postinstall/planters/).
#
# Unlike callisto-rdp.sh, this planter doesn't go through Bitwarden — the
# dockur container's RDP creds are literal "Docker"/"Docker" (the dockur
# default), and winapps.conf is already the local source of truth. Reading
# from there keeps a single edit point if the password ever rotates.
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

_remmina_file="$HOME/.config/remmina/Windows.remmina"
_planter_file="$HOME/.local/share/arch-setup-bootstraps/windows-rdp.sh"
_winapps_conf="$HOME/.config/winapps/winapps.conf"

# Profile not yet applied? Wait for chezmoi apply.
if [[ ! -f "$_remmina_file" ]]; then
    unset _remmina_file _planter_file _winapps_conf
    return 0
fi

# Already populated? Self-delete and move on.
if secret-tool lookup filename "$_remmina_file" key password &>/dev/null; then
    rm -f "$_planter_file"
    unset _remmina_file _planter_file _winapps_conf
    return 0
fi

# winapps.conf is the source of truth for RDP creds (postinstall §3-winapps
# writes it). If it's missing — user may have opted out of the Windows VM
# install — quietly stand by. The planter reappears every interactive
# shell until winapps.conf shows up.
if [[ ! -f "$_winapps_conf" ]]; then
    unset _remmina_file _planter_file _winapps_conf
    return 0
fi

# Extract RDP_PASS without sourcing arbitrary user content. Postinstall
# writes the value double-quoted (RDP_PASS="Docker"); strip those if
# present, leave bare values alone.
_pw=$(grep -E '^RDP_PASS=' "$_winapps_conf" | head -1 | cut -d= -f2-)
_pw="${_pw#\"}"
_pw="${_pw%\"}"
if [[ -z "$_pw" ]]; then
    echo "arch: windows-rdp planter — RDP_PASS missing from $_winapps_conf." >&2
    unset _remmina_file _planter_file _winapps_conf _pw
    return 0
fi

if printf '%s' "$_pw" | secret-tool store \
        --label="Remmina: Windows - password" \
        filename "$_remmina_file" \
        key password; then
    echo "arch: windows-rdp — password stored in keyring; Remmina will pick it up on next launch."
    rm -f "$_planter_file"
else
    echo "arch: windows-rdp planter — secret-tool store failed (keyring locked?)." >&2
fi
unset _remmina_file _planter_file _winapps_conf _pw
