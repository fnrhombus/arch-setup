# TODO — Matugen bootstrap fallbacks for `rhombu5/dots`

**Audience:** a Claude session with push access to `rhombu5/dots`. This
sandbox can't push there directly. Apply both fixes in a single commit,
push, and `git rm` this file from `arch-setup` (single allowed write to
arch-setup, same atomic-commit pattern as prior dots-side TODOs).

---

## Why

User hit two related failures on first login post-install:

1. **Ghostty refuses to launch:** `config error theme matugen not found,
   tried /home/tom/.config/ghostty/themes/matugen,
   /usr/share/ghostty/themes/matugen`. Cause: `dot_config/ghostty/config`
   sets `theme = matugen` which references a file matugen *generates*.
   If matugen never successfully ran, the file doesn't exist and ghostty
   errors at every launch. Waybar + swaync have a `create_colors.css`
   fallback for this exact scenario; ghostty doesn't.

2. **`run_once_after_install-wallpapers.sh.tmpl` keeps failing on first
   apply:** uses GitHub's anonymous REST API
   (`https://api.github.com/repos/fnrhombus/callisto/contents/...`) which
   rate-limits at 60 req/h per IP and returns a JSON object (not array)
   when limited. The python parser then `TypeError`s (`string indices
   must be integers, not 'str'`). On the user's actual laptop this hit
   immediately because they'd already used the API quota up via
   unrelated traffic from the same egress IP. Result: empty
   `~/Pictures/Wallpapers/`, matugen never runs, ghostty errors per #1.

---

## Fix 1: Ship a static ghostty theme stub

Create the file:

```
dot_config/ghostty/themes/create_matugen
```

The `create_` prefix means chezmoi creates the file if missing, but
**never updates it after that** — so when matugen renders the real theme
to `~/.config/ghostty/themes/matugen`, chezmoi leaves it alone. If
matugen never ran, the static stub is still there and ghostty boots.

File contents (matches the format of `dot_config/matugen/templates/ghostty-theme`,
with the matugen accent variables substituted with sane Material You
defaults so the file is fully self-contained):

```
# Ghostty theme — STATIC FALLBACK used when matugen has never rendered.
# matugen overwrites this file on first wallpaper-rotate; chezmoi's
# `create_` prefix keeps the matugen output in place after that.
#
# Same VS Code Default Dark+ palette as the matugen template, with
# cursor + selection accents pinned to a neutral Material You purple
# (#6750A4 family) instead of being wallpaper-derived.

palette = 0=#000000
palette = 1=#cd3131
palette = 2=#0dbc79
palette = 3=#e5e510
palette = 4=#2472c8
palette = 5=#bc3fbc
palette = 6=#11a8cd
palette = 7=#e5e5e5
palette = 8=#666666
palette = 9=#f14c4c
palette = 10=#23d18b
palette = 11=#f5f543
palette = 12=#3b8eea
palette = 13=#d670d6
palette = 14=#29b8db
palette = 15=#e5e5e5

background = #1e1e1e
foreground = #d4d4d4

cursor-color = #6750a4
cursor-text = #ffffff
selection-background = #4f378b
selection-foreground = #eaddff
```

---

## Fix 2: Replace API-based wallpaper bootstrap with shallow git clone

Replace the entire contents of
`.chezmoiscripts/run_once_after_install-wallpapers.sh.tmpl` with:

```bash
#!/usr/bin/env bash
# chezmoi run-once hook — populate ~/Pictures/Wallpapers/ from the user's
# callisto repo on first apply. After the first SUCCESSFUL run, chezmoi
# tracks this script's hash; only re-runs if the script's content changes.
# A non-zero exit makes chezmoi retry on the next apply, which is what we
# want for transient network failures.
#
# Source: https://github.com/fnrhombus/callisto/tree/main/static/wallpaper/linux
# (top-level only; subfolders intentionally skipped per user direction.)
#
# Prior implementation used the GitHub anonymous REST API and kept hitting
# the 60-req/h IP-based rate limit, which crashed the python parser. Shallow
# + sparse clone bypasses that — git's smart-HTTP transport isn't subject
# to the same quota as the REST API.

set -euo pipefail

dest="$HOME/Pictures/Wallpapers"
mkdir -p "$dest"

tmp=$(mktemp -d -t callisto-XXXXXX)
trap 'rm -rf "$tmp"' EXIT

if ! git clone --depth 1 --filter=blob:none --no-checkout \
        https://github.com/fnrhombus/callisto.git "$tmp" >/dev/null 2>&1; then
    echo "wallpapers: callisto clone failed — chezmoi will retry on next apply" >&2
    exit 1
fi
git -C "$tmp" sparse-checkout init --cone >/dev/null
git -C "$tmp" sparse-checkout set static/wallpaper/linux >/dev/null
git -C "$tmp" checkout >/dev/null 2>&1

src="$tmp/static/wallpaper/linux"
if [[ ! -d "$src" ]]; then
    echo "wallpapers: $src missing in callisto checkout" >&2
    exit 1
fi

shopt -s nullglob nocaseglob
for f in "$src"/*.{jpg,jpeg,png,webp}; do
    name=$(basename "$f")
    target="$dest/$name"
    if [[ -f "$target" ]]; then
        echo "wallpapers: skip (exists) $name"
        continue
    fi
    echo "wallpapers: copying $name"
    cp -- "$f" "$target"
done

# Force retry-on-next-apply if the dest is still empty after the copy.
# (Either callisto's wallpaper dir was empty, or every glob was a miss
# due to a case nuance, or nothing matched the extension list — in any
# of those, we'd rather have chezmoi retry than silently leave matugen
# with nothing to seed from.)
if ! compgen -G "$dest"/* >/dev/null; then
    echo "wallpapers: dest still empty after copy — failing for retry" >&2
    exit 1
fi
```

---

## Apply

In `~/.local/share/chezmoi` (rhombu5/dots checkout):

```bash
# Fix 1: drop the ghostty theme stub
mkdir -p dot_config/ghostty/themes
cat > dot_config/ghostty/themes/create_matugen <<'EOF'
<paste the full theme contents from Fix 1 above>
EOF

# Fix 2: rewrite the wallpaper bootstrap
cat > .chezmoiscripts/run_once_after_install-wallpapers.sh.tmpl <<'EOF'
<paste the full script contents from Fix 2 above>
EOF

git add dot_config/ghostty/themes/create_matugen \
        .chezmoiscripts/run_once_after_install-wallpapers.sh.tmpl
git commit -m "matugen bootstrap robustness: ghostty fallback theme + shallow-clone wallpaper script

- Ghostty was erroring at every launch when matugen had never rendered
  (theme = matugen referenced a non-existent file). create_matugen
  ships a static VS Code Default Dark+ stub; matugen overwrites it on
  first wallpaper-rotate, chezmoi's create_ prefix keeps the matugen
  output in place afterwards.

- Wallpaper bootstrap kept failing on first apply due to GitHub anon-API
  rate limits. Shallow + sparse clone of fnrhombus/callisto bypasses
  the quota and exits non-zero on transient failure so chezmoi retries
  on the next apply."
git push origin main
```

On the laptop (after the dots fix is pushed):

```bash
# Pull + apply dots; the new wallpaper bootstrap re-runs because the
# script's hash changed. Force matugen re-render afterward.
chezmoi update
~/.local/bin/wallpaper-rotate --first
ls -l ~/.config/ghostty/themes/matugen   # confirm exists
pkill -SIGUSR2 ghostty 2>/dev/null
```

If chezmoi insists the script already ran (run_once tracking), nuke its
script-state bucket and re-apply:

```bash
chezmoi state delete-bucket --bucket=scriptState
chezmoi apply
```

---

## Cleanup

Once both fixes are pushed and the laptop confirms `chezmoi apply` lands
the wallpapers and matugen renders the ghostty theme: `git rm` this file
from arch-setup as the **single allowed write to arch-setup** for this
task (atomic commit, push to main).
