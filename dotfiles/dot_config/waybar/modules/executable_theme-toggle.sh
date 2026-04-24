#!/usr/bin/env bash
# waybar custom module — theme toggle indicator. Reads cached mode and
# emits the corresponding glyph. Click handler in waybar config calls
# ~/.local/bin/theme-toggle which flips mode and signals waybar
# (SIGRTMIN+8 = signal 8) to re-run this script.

set -euo pipefail

mode_file="${XDG_CACHE_HOME:-$HOME/.cache}/matugen/mode"
mode=$( [[ -f "$mode_file" ]] && cat "$mode_file" || echo "dark" )

case "$mode" in
    light) printf '%s' "" ;;   # sun
    *)     printf '%s' "" ;;   # moon (default)
esac
echo
