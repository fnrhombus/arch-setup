#!/usr/bin/env zsh
# arch: cloud-storage planter — link Dropbox (official daemon, general
# sync) + OAuth rclone gdrive (~/gdrive bisync) + OAuth rclone
# Dropbox (~/.claude memory+plans bisync) + seed each baseline.
# Self-deleting once all three sections succeed.
# Skipped during postinstall's zgenom warmup (which sources this file too) so
# we don't block on a browser auth flow that warmup can't complete.
if [[ -n "${_POSTINSTALL_NONINTERACTIVE:-}" ]]; then
    return 0
fi
# `[[ -o interactive ]]`, not `[[ -t 0 ]]`: powerlevel10k's instant-prompt
# redirects fd 0 during .zshrc init, so `-t 0` returns false in any
# Ghostty/Hyprland zsh that uses p10k — the planter would silently
# return 0 every login. The actual question is whether the shell
# itself is interactive, which is what `-o interactive` answers.
[[ -o interactive ]] || return 0

_dbox_done=0
_gdrive_done=0
_claude_done=0

# --- Dropbox: link account on first run ---
if command -v dropbox &>/dev/null; then
    if [[ -f "$HOME/.dropbox/info.json" ]]; then
        _dbox_done=1
    else
        echo ""
        echo "=== arch: Dropbox first-link ==="
        echo "Starting the Dropbox daemon — it will print a https://www.dropbox.com/cli_link?... URL."
        echo "Open it in a browser, log in, and the daemon picks up sync automatically."
        # `dropbox start -i` downloads the bundled daemon on first run, prints the
        # link URL, and starts dropboxd in the background. info.json appears once
        # the user has actually clicked the link.
        dropbox start -i || true
        if [[ -f "$HOME/.dropbox/info.json" ]]; then
            _dbox_done=1
            systemctl --user start dropbox.service 2>/dev/null || true
        else
            echo "arch: Dropbox not yet linked — start a new shell after clicking the URL."
        fi
    fi
fi

# --- rclone: OAuth Google Drive remote, then seed bisync baseline ---
if command -v rclone &>/dev/null; then
    _rclone_conf="$HOME/.config/rclone/rclone.conf"
    _bisync_marker="$HOME/.local/state/rclone-bisync-initialized"

    if [[ ! -f "$_rclone_conf" ]] || ! grep -q '^\[gdrive\]' "$_rclone_conf" 2>/dev/null; then
        echo ""
        echo "=== arch: rclone Google Drive OAuth ==="
        echo "Opening a browser to authorize rclone for Google Drive."
        # `rclone config create` is the non-interactive variant of `rclone config`;
        # for OAuth backends it still opens a browser to capture the token (the
        # only path to a valid refresh token), then writes the [gdrive] block.
        rclone config create gdrive drive scope=drive || true
    fi

    if grep -q '^\[gdrive\]' "$_rclone_conf" 2>/dev/null; then
        if [[ ! -f "$_bisync_marker" ]]; then
            mkdir -p "$HOME/gdrive"
            # Safety: only --resync when the local dir is empty (fresh install).
            # If the user has unrelated files in ~/gdrive that this planter
            # didn't put there, refuse — bisync's first --resync would push them
            # to gdrive, which is rarely what's wanted.
            if [[ -z "$(ls -A "$HOME/gdrive" 2>/dev/null)" ]]; then
                echo "arch: seeding rclone bisync baseline (gdrive → ~/gdrive)..."
                # --filter-from: exclude Google Photos videos (MD5 mismatch on
                # transfer because Google transcodes them server-side, breaking
                # bisync's hash check). Photos sync fine; videos don't. The
                # filter file lives in dots (chezmoi) and stays in sync with
                # rclone-gdrive-bisync.service.
                if rclone bisync gdrive: "$HOME/gdrive" \
                        --filter-from "$HOME/.config/rclone/gdrive-filters.txt" \
                        --resync --resilient \
                        --max-delete 25 --create-empty-src-dirs; then
                    mkdir -p "$HOME/.local/state"
                    touch "$_bisync_marker"
                    systemctl --user start rclone-gdrive-bisync.timer 2>/dev/null || true
                    _gdrive_done=1
                    echo "arch: bisync seeded — timer will sync every 5 min."
                else
                    echo "arch: bisync --resync failed — start a new shell to retry."
                fi
            else
                echo "arch: ~/gdrive is non-empty; skipping bisync --resync."
                echo "      Move existing files aside, then start a new shell to seed."
            fi
        else
            _gdrive_done=1
        fi
    fi
    # --- rclone Dropbox: claude memory + plans bisync ---
    # Hybrid setup: official Dropbox daemon (above) handles general
    # ~/Dropbox sync; this rclone remote selectively bisyncs just the
    # Claude memory dirs + plans dir to dropbox:claude/ for cross-machine
    # continuity, gated by ~/.config/rclone/claude-filters.txt.
    _claude_marker="$HOME/.local/state/rclone-dropbox-claude-bisync-initialized"
    _claude_filter="$HOME/.config/rclone/claude-filters.txt"

    if [[ ! -f "$_rclone_conf" ]] || ! grep -q '^\[dropbox\]' "$_rclone_conf" 2>/dev/null; then
        echo ""
        echo "=== arch: rclone Dropbox OAuth (Claude memory + plans) ==="
        echo "Opening a browser to authorize rclone for Dropbox."
        # `>/dev/null` muzzles rclone's post-auth config dump — by default
        # `rclone config create` echoes the resulting [dropbox] block to
        # stdout, *including the access_token + refresh_token JSON*. The
        # config gets persisted to rclone.conf either way; suppress the
        # echo so credentials don't leak into the calling shell's
        # transcript / journal / scrollback.
        rclone config create dropbox dropbox >/dev/null || true
    fi

    if grep -q '^\[dropbox\]' "$_rclone_conf" 2>/dev/null && [[ -f "$_claude_filter" ]]; then
        if [[ ! -f "$_claude_marker" ]]; then
            echo "arch: seeding rclone bisync baseline (dropbox:claude → ~/.claude memory+plans)..."
            # --resync-mode path2: local ~/.claude wins on the initial
            # baseline. Without it, an empty dropbox:claude/ would wipe
            # any local memories on first sync.
            if rclone bisync dropbox:claude "$HOME/.claude" \
                    --filter-from "$_claude_filter" \
                    --resync --resync-mode path2 \
                    --resilient --max-delete 25 --create-empty-src-dirs; then
                mkdir -p "$HOME/.local/state"
                touch "$_claude_marker"
                systemctl --user start rclone-dropbox-claude-bisync.timer 2>/dev/null || true
                _claude_done=1
                echo "arch: claude bisync seeded — timer will sync every 5 min."
            else
                echo "arch: dropbox:claude bisync --resync failed — start a new shell to retry."
            fi
        else
            _claude_done=1
        fi
    fi
    unset _claude_marker _claude_filter
    unset _rclone_conf _bisync_marker
fi

# Self-delete only when all three sections are fully configured. Partial
# completion leaves the planter in place so a future shell can finish
# whatever's left.
if (( _dbox_done && _gdrive_done && _claude_done )); then
    rm -f "$HOME/.local/share/arch-setup-bootstraps/cloud-storage-auth.sh"
fi
unset _dbox_done _gdrive_done _claude_done
