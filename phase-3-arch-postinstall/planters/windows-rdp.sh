#!/usr/bin/env zsh
# arch: seed the dockur Windows VM RDP password from
# /etc/dockur-windows/compose.yaml into the GNOME keyring, where Remmina's
# libsecret plugin (org.remmina.Password schema) finds it at connect time.
# Self-deleting; one-shot. Re-run by deleting the keyring entry
# (`secret-tool clear filename ~/.config/remmina/Windows.remmina key password`)
# and re-planting (postinstall §13b, or manual `cp` from
# ~/src/arch-setup@fnrhombus/phase-3-arch-postinstall/planters/).
#
# Unlike callisto-rdp.sh, this planter doesn't go through Bitwarden — the
# dockur container's RDP creds are literal "Docker"/"Docker" (the dockur
# default), read from the compose file at /etc/dockur-windows/compose.yaml.
# (winapps.conf is no longer a usable source: it targets callisto with the
# MS-account login — see postinstall §3-winapps.)
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
_compose_file="/etc/dockur-windows/compose.yaml"

# Profile not yet applied? Wait for chezmoi apply.
if [[ ! -f "$_remmina_file" ]]; then
    unset _remmina_file _planter_file _compose_file
    return 0
fi

# Already populated? Self-delete and move on.
if secret-tool lookup filename "$_remmina_file" key password &>/dev/null; then
    rm -f "$_planter_file"
    unset _remmina_file _planter_file _compose_file
    return 0
fi

# The compose file is the source of truth for the VM's RDP creds
# (postinstall §1a-dockur writes it). If it's missing — user may have
# opted out of the Windows VM install — quietly stand by. The planter
# reappears every interactive shell until the compose file shows up.
if [[ ! -f "$_compose_file" ]]; then
    unset _remmina_file _planter_file _compose_file
    return 0
fi

# Extract the compose PASSWORD without a YAML parser. Postinstall writes
# it double-quoted (PASSWORD: "Docker"); strip quotes if present.
_pw=$(grep -E '^[[:space:]]*PASSWORD:' "$_compose_file" | head -1 | sed 's/^[^:]*:[[:space:]]*//')
_pw="${_pw#\"}"
_pw="${_pw%\"}"
if [[ -z "$_pw" ]]; then
    echo "arch: windows-rdp planter — PASSWORD missing from $_compose_file." >&2
    unset _remmina_file _planter_file _compose_file _pw
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
unset _remmina_file _planter_file _compose_file _pw
