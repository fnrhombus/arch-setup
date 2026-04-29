# TODO — Relocate `arch-hyprpm-bootstrap` in `rhombu5/dots`

**Audience:** a future Claude session running on the laptop, with a working
checkout of [rhombu5/dots](https://github.com/rhombu5/dots) at
`~/.local/share/chezmoi/`.

**This file is temporary.** Delete it (and commit the deletion) once the fix
below is applied and pushed to `rhombu5/dots`.

---

## Why this exists

The file `dot_zshrc.d/arch-hyprpm-bootstrap.zsh` in `rhombu5/dots` runs on
**every** zsh start. It invokes `hyprpm` to install/load Hyprland plugins
(hyprgrass, hyprexpo) if they aren't already present.

That's wrong for two reasons:

1. **It's a one-time bootstrap, not a per-shell concern.** Once the plugins
   are installed, the script just no-ops on every shell — pure overhead.
2. **It races with p10k instant-prompt and the PIN-only sudo PAM stack.**
   When opening Ghostty for the first time after login, p10k instant-prompt
   fires before the PAM module's TTY is fully attached. If anything in
   `hyprpm` triggers `sudo` (or any PAM-mediated op) in that window, the
   prompt hangs on a correct PIN — exact reproducer the user hit on
   2026-04-2x.

The fix is to move the bootstrap out of `.zshrc.d/` (per-shell) into
`.chezmoiscripts/` (runs **once**, the next time `chezmoi apply` is run).

## The fix

In `~/.local/share/chezmoi/`:

1. **Read** `dot_zshrc.d/arch-hyprpm-bootstrap.zsh` and translate its body
   into a plain `bash` script (drop any zsh-only constructs — `[[ ... ]]` is
   fine in bash, but watch for `=~` differences and array syntax).

2. **Create** `.chezmoiscripts/run_once_after_apply-hyprpm-bootstrap.sh.tmpl`
   with the translated body. The chezmoi naming convention:
   - `run_once_` → tracked by hash; only re-runs if the script's content changes
   - `after_apply` → runs after `chezmoi apply` finishes writing files
   - `.tmpl` → chezmoi template-renders it (use this if you need to gate on
     `{{ if eq .chezmoi.os "linux" }}` or similar; otherwise drop the
     `.tmpl` suffix and skip rendering)

   Top of the file:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   # Bootstrap Hyprland plugins via hyprpm. Runs once after chezmoi apply.
   # Original location: dot_zshrc.d/arch-hyprpm-bootstrap.zsh (removed —
   # ran every shell start and raced with PAM PIN prompt + p10k instant-prompt).
   ```

   Don't `sudo` anything inside this script — `hyprpm` operates per-user.
   If the original script ran under sudo, that's another bug; flag it and
   ask the user before keeping that behavior.

3. **Delete** `dot_zshrc.d/arch-hyprpm-bootstrap.zsh`.

4. **`chmod +x`** the new script (chezmoi requires executable bit on
   `run_once_*` scripts).

5. Commit in `rhombu5/dots` with message:

   ```
   move arch-hyprpm-bootstrap from .zshrc.d/ to chezmoi run_once

   Was running on every shell start; raced with the PIN-only sudo PAM
   stack + p10k instant-prompt and caused Ghostty to hang on a correct
   PIN. Bootstrap is one-time work — belongs in chezmoi run_once, not
   per-shell init.
   ```

6. **Push** to `origin/main` (or whatever the default branch is on
   `rhombu5/dots`).

7. On the laptop, run `chezmoi update && chezmoi apply` to pull and apply.
   Verify the new script ran (look for plugin install logs) and that
   `~/.zshrc.d/arch-hyprpm-bootstrap.zsh` is gone.

8. Smoke test: open a fresh Ghostty window. p10k instant-prompt should
   come up cleanly with no PAM hang. `sudo true` (PIN prompt) should
   resolve normally.

## Cleanup of THIS file

Once the steps above are done and pushed:

```bash
cd /home/user/arch-setup   # or wherever this repo is checked out
git rm TODO-dots-hyprpm-relocation.md
git commit -m "drop dots-hyprpm relocation TODO (fix landed in rhombu5/dots)"
git push origin main
```

That's the whole task.
