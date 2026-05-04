---
name: Revisit hard monitor-binding for workspaces 1-9
description: User dislikes that workspaces 1-5 are hard-bound to DP-1 and 6-9 to eDP-1; surprising silent migration when DP-1 appears (e.g., off-but-plugged-in TV).
type: project
---

**User wants to revisit `dot_config/hypr/workspaces.conf` — currently workspaces 1-5 are hard-bound to monitor DP-1 and 6-9 to eDP-1.**

**Why:** discovered 2026-05-04 that an HDMI cable to a powered-off TV was enough for Hyprland to register DP-1, which silently sent super+[1-5] keypresses to the invisible TV monitor. Symptom looked like "super+[1-9] is broken" — actually "workspace switched on a screen you can't see." User said "i didn't realize workspaces were monitor bound like that. i don't like that, remind me to come back to it later."

**How to apply:** When the user circles back to this, the open design questions are:
- Should workspace 1-9 be free-roaming across monitors (no `monitor:NAME` rule), with the user just placing them where they want?
- Or should they be soft-bound (default to a monitor but transparently migrate when that monitor is absent)? The 6-9 rules already document the desired migration pattern in workspaces.conf comments — but it's not actually implemented as a fallback rule, just noted.
- Or should there be a per-context monitor preset (work/lid-closed/portable) selected at runtime?

Don't propose a fix unprompted — wait for them to bring it up. When they do, surface these three options for them to pick from.
