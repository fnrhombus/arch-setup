---
name: display-watchdog
description: Hyprland blackout recovery daemon in dots, designed for extraction. Lid-aware: open → re-enable internal, closed → hibernate.
type: project
originSessionId: c73d0872-3515-4435-9e83-dcef6a7117cc
---
display-watchdog — Python daemon in [rhombu5/dots](https://github.com/rhombu5/dots) (`~/.local/bin/display-watchdog`), designed for extraction to its own repo.

**Why:** External-unplug-while-internal-DPMS-off was a real lifecycle hole on Tom's docked-laptop setup — no off-the-shelf tool composes lid awareness with monitor-disconnect recovery (kanshi/shikane do profiles, not lid; binddl scripts only fire on lid-switch). Built it ~80-line stdlib-only Python, CLI-flag-configurable, README structured as a repo root — so the cost to extract later is `git mv` + add LICENSE.

**How to apply:**
- Treat this as the same trajectory as wpws — pull out into its own repo only when there's a second user or it grows past ~150 lines. Don't generalize prematurely while it's a single-user tool.
- The deployment-specific bits (eDP-1 monitor name, exact lid-open recovery command) live in `~/.config/hypr/exec.conf` §3d, not in the daemon — keep that boundary clean if extending.
- README at `~/.local/share/doc/display-watchdog/README.md` is the future repo-root README; edit it like one.
