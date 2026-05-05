#!/usr/bin/env zsh
# arch: cloud-storage planter — link Dropbox + OAuth rclone gdrive + seed bisync baseline (self-deleting)
# Skipped during postinstall's zgenom warmup (which sources this file too) so
# we don't block on a browser auth flow that warmup can't complete.
if [[ -n "${_POSTINSTALL_NONINTERACTIVE:-}" ]]; then
    return 0
fi
[[ -t 0 ]] || return 0

_dbox_done=0
_gdrive_done=0

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
            mkdir -p "$HOME/GoogleDrive"
            # Safety: only --resync when the local dir is empty (fresh install).
            # If the user has unrelated files in ~/GoogleDrive that this planter
            # didn't put there, refuse — bisync's first --resync would push them
            # to gdrive, which is rarely what's wanted.
            if [[ -z "$(ls -A "$HOME/GoogleDrive" 2>/dev/null)" ]]; then
                echo "arch: seeding rclone bisync baseline (gdrive → ~/GoogleDrive)..."
                if rclone bisync gdrive: "$HOME/GoogleDrive" --resync --resilient; then
                    mkdir -p "$HOME/.local/state"
                    touch "$_bisync_marker"
                    systemctl --user start rclone-gdrive-bisync.timer 2>/dev/null || true
                    _gdrive_done=1
                    echo "arch: bisync seeded — timer will sync every 5 min."
                else
                    echo "arch: bisync --resync failed — start a new shell to retry."
                fi
            else
                echo "arch: ~/GoogleDrive is non-empty; skipping bisync --resync."
                echo "      Move existing files aside, then start a new shell to seed."
            fi
        else
            _gdrive_done=1
        fi
    fi
    unset _rclone_conf _bisync_marker
fi

# Self-delete only when both services are fully configured. Partial completion
# leaves the planter in place so a future shell can finish what's left.
if (( _dbox_done && _gdrive_done )); then
    rm -f "$HOME/.local/share/arch-setup-bootstraps/cloud-storage-auth.sh"
fi
unset _dbox_done _gdrive_done
