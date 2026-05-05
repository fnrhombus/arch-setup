---
name: greetd is dead tech
description: greetd is no longer in use; don't reference it in new code or design comments
type: project
originSessionId: b7a5587e-d509-4813-a5ae-ca9888755067
---
As of 2026-05-05 the user explicitly stated **greetd is not in use**. The bare-TTY → uwsm → Hyprland flow is the only login path going forward; greetd is dead tech.

**Why:** the user's prior framing in `docs/decisions.md` and elsewhere described greetd as "kept installed but disabled as fallback." That framing is no longer accurate — it's not a fallback, it's not used at all.

**How to apply:**
- **In new design comments / docs / commit messages:** describe the design directly (e.g. "cold-boot login excludes PIN by design") without referencing greetd as the basis or pattern.
- **Script infrastructure:** `chroot.sh` §11 still installs the greetd template, `postinstall.sh` §7a still re-stomps it for drift correction, and `system-files/pam.d/greetd` still exists. Leave these as inert infrastructure unless the user asks for a full purge — removing them is a multi-file refactor (chroot.sh + postinstall.sh + decisions.md + GLOSSARY.md + system-files) and is out of scope for any unrelated change.
- **If asked about login surfaces:** the only active login surface is `/etc/pam.d/login` (TTY). Don't list greetd alongside.
- **If the user asks for a greetd purge:** propose the full sweep, don't half-do it.
