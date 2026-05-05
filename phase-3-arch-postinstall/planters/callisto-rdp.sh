#!/usr/bin/env zsh
# arch: seed Callisto RDP password from Bitwarden into the GNOME keyring,
# where Remmina's libsecret plugin (org.remmina.Password schema) finds it
# at connect time. Self-deleting; one-shot. Re-run by deleting the keyring
# entry (`secret-tool clear filename ~/.config/remmina/Callisto.remmina key password`)
# and re-planting (postinstall §13b, or manual `cp` from
# ~/src/arch-setup@fnrhombus/phase-3-arch-postinstall/planters/).
#
# Skipped during postinstall's zgenom warmup (which sources this file too).
if [[ -n "${_POSTINSTALL_NONINTERACTIVE:-}" ]]; then
    return 0
fi
[[ -t 0 ]] || return 0

_remmina_file="$HOME/.config/remmina/Callisto.remmina"
_planter_file="$HOME/.local/share/arch-setup-bootstraps/callisto-rdp.sh"

# Profile not yet applied? Wait for chezmoi apply.
if [[ ! -f "$_remmina_file" ]]; then
    unset _remmina_file _planter_file
    return 0
fi

# Already populated? Self-delete and move on.
if secret-tool lookup filename "$_remmina_file" key password &>/dev/null; then
    rm -f "$_planter_file"
    unset _remmina_file _planter_file
    return 0
fi

# Need bw unlocked. The `bw` shell wrapper auto-prompts via bwu, but only
# if libsecret already cached the master password. Don't trigger an
# interactive seed-prompt from inside a planter — leave that to the
# user's first explicit `bwu` so the timing is theirs to control.
if ! command -v bw &>/dev/null; then
    unset _remmina_file _planter_file
    return 0
fi
_bw_status=$(command bw status 2>/dev/null | jq -r .status 2>/dev/null)
if [[ "$_bw_status" != "unlocked" ]]; then
    # If session is cached in libsecret, surface it without prompting.
    if [[ -z "${BW_SESSION:-}" ]]; then
        BW_SESSION=$(secret-tool lookup service bitwarden type session 2>/dev/null) && export BW_SESSION
        _bw_status=$(command bw status 2>/dev/null | jq -r .status 2>/dev/null)
    fi
fi
if [[ "$_bw_status" != "unlocked" ]]; then
    echo "arch: callisto-rdp planter waiting on \`bwu\` (vault locked)." >&2
    unset _remmina_file _planter_file _bw_status
    return 0
fi
unset _bw_status

# Look up the password by matching the .remmina profile's username AND
# domain against the BW vault: items whose name == the domain field
# (e.g. "MicrosoftAccount") AND whose login.username == the username
# field. Both come straight from the .remmina file so there's a single
# source of truth — no separate "BW item name" knob to keep in sync.
_username=$(grep -E '^username=' "$_remmina_file" | head -1 | cut -d= -f2-)
_bw_item=$(grep -E '^domain=' "$_remmina_file" | head -1 | cut -d= -f2-)
if [[ -z "$_username" || -z "$_bw_item" ]]; then
    echo "arch: callisto-rdp planter — Callisto.remmina missing username= or domain= line." >&2
    unset _remmina_file _planter_file _username _bw_item
    return 0
fi
_pw=$(command bw list items --search "$_bw_item" 2>/dev/null \
    | jq -r --arg u "$_username" --arg n "$_bw_item" \
        'map(select(.name == $n and .login.username == $u)) | .[0].login.password // empty')
if [[ -z "$_pw" ]]; then
    echo "arch: callisto-rdp planter — no BW '$_bw_item' item with login.username=$_username." >&2
    unset _remmina_file _planter_file _pw _username _bw_item
    return 0
fi
unset _username _bw_item

if printf '%s' "$_pw" | secret-tool store \
        --label="Remmina: Callisto - password" \
        filename "$_remmina_file" \
        key password; then
    echo "arch: callisto-rdp — password stored in keyring; Remmina will pick it up on next launch."
    rm -f "$_planter_file"
else
    echo "arch: callisto-rdp planter — secret-tool store failed (keyring locked?)." >&2
fi
unset _remmina_file _planter_file _pw
