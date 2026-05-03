---
name: wpws (per-workspace wallpaper + accent)
description: Self-contained Python daemon in dots, designed for extraction to its own repo when stable.
type: project
originSessionId: 1f608502-800c-4723-a701-24396c206988
---
`wpws` is a per-workspace wallpaper + dynamic-accent daemon for Hyprland. Lives in [rhombu5/dots](https://github.com/rhombu5/dots) under `~/.local/bin/wpws` + `~/.config/wpws/config.toml` + `~/.config/themes/*`. Listens on `$XDG_RUNTIME_DIR/hypr/$SIG/.socket2.sock`, swaps wallpaper via `awww img -o`, rewrites `accent.{css,conf,ini}` under `~/.config/themes/`, pushes Hyprland borders/groupbar via `hyprctl keyword` (no reload).

**Why:** built 2026-05-01 to satisfy a "deterministic-yet-distinct wallpaper per workspace + matching dynamic accent" requirement, after deciding the Hyprspace-tile-shows-correct-wallpaper sub-requirement was a separate (C++ patch) problem. Designed self-contained from day one because the user expects to extract it to a standalone repo (likely `fnrhombus/wpws` per the user's GitHub-owner rules) once it stabilizes.

**How to apply:** when working on wpws, treat it as a soon-to-be-extracted project — keep config schema clean (TOML, no chezmoi templating), keep the daemon path-agnostic (`os.path.expanduser` everywhere, no `/home/tom`), and avoid leaking dots-specific assumptions into the daemon code. The dots-side glue (consumer `@import` lines, exec.conf wiring, binds) stays in dots after extraction. Slow path stays matugen (full M3 palette → all themes); fast path is wpws's own ~10ms PIL extractor.
