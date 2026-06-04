#!/usr/bin/env zsh
# arch: fill RDP_PASS in ~/.config/winapps/winapps.conf from Bitwarden.
# Postinstall §3-winapps writes the conf targeting callisto.rhombus.rocks
# with RDP_PASS deliberately empty (no secrets in the repo); this planter
# looks up the Bitwarden item whose name == "MicrosoftAccount" and whose
# login.username == the conf's RDP_USER, and writes the password in place.
# Self-deleting; one-shot. Re-run by blanking RDP_PASS and re-planting
# (postinstall §13b, or manual `cp` from
# ~/src/arch-setup@fnrhombus/phase-3-arch-postinstall/planters/).
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

_winapps_conf="$HOME/.config/winapps/winapps.conf"
_planter_file="$HOME/.local/share/arch-setup-bootstraps/winapps-rdp-pass.sh"

# Conf not yet written? Wait for postinstall §3-winapps.
if [[ ! -f "$_winapps_conf" ]]; then
    unset _winapps_conf _planter_file
    return 0
fi

# Already filled? Self-delete and move on. (Same no-source extraction as
# windows-rdp.sh: postinstall writes the value double-quoted.)
_pw=$(grep -E '^RDP_PASS=' "$_winapps_conf" | head -1 | cut -d= -f2-)
_pw="${_pw#\"}"
_pw="${_pw%\"}"
if [[ -n "$_pw" ]]; then
    rm -f "$_planter_file"
    unset _winapps_conf _planter_file _pw
    return 0
fi
unset _pw

# Need bw unlocked. The `bw` shell wrapper auto-prompts via bwu, but only
# if libsecret already cached the master password. Don't trigger an
# interactive seed-prompt from inside a planter — leave that to the
# user's first explicit `bwu` so the timing is theirs to control.
if ! command -v bw &>/dev/null; then
    unset _winapps_conf _planter_file
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
    echo "arch: winapps-rdp-pass planter waiting on \`bwu\` (vault locked)." >&2
    unset _winapps_conf _planter_file _bw_status
    return 0
fi
unset _bw_status

# RDP_USER from the conf is the single source of truth — the BW item is
# always named "MicrosoftAccount" (one per account, distinguished by
# login.username), so there's no separate item-name knob to keep in sync.
_username=$(grep -E '^RDP_USER=' "$_winapps_conf" | head -1 | cut -d= -f2-)
_username="${_username#\"}"
_username="${_username%\"}"
if [[ -z "$_username" ]]; then
    echo "arch: winapps-rdp-pass planter — winapps.conf missing RDP_USER= line." >&2
    unset _winapps_conf _planter_file _username
    return 0
fi
_pw=$(command bw list items --search "MicrosoftAccount" 2>/dev/null \
    | jq -r --arg u "$_username" \
        'map(select(.name == "MicrosoftAccount" and .login.username == $u)) | .[0].login.password // empty')
if [[ -z "$_pw" ]]; then
    echo "arch: winapps-rdp-pass planter — no BW 'MicrosoftAccount' item with login.username=$_username." >&2
    unset _winapps_conf _planter_file _pw _username
    return 0
fi
unset _username

# In-place fill via a temp file in the same dir (atomic rename, keeps the
# conf out of any intermediate world-readable state), then lock perms down.
_tmp=$(mktemp "${_winapps_conf}.XXXXXX") || {
    echo "arch: winapps-rdp-pass planter — mktemp failed." >&2
    unset _winapps_conf _planter_file _pw _tmp
    return 0
}
if sed "s|^RDP_PASS=.*|RDP_PASS=\"${_pw//|/\\|}\"|" "$_winapps_conf" >"$_tmp" \
        && chmod 600 "$_tmp" && mv "$_tmp" "$_winapps_conf"; then
    echo "arch: winapps-rdp-pass — RDP_PASS filled in winapps.conf from Bitwarden."
    rm -f "$_planter_file"
else
    rm -f "$_tmp"
    echo "arch: winapps-rdp-pass planter — failed writing $_winapps_conf." >&2
fi
unset _winapps_conf _planter_file _pw _tmp
