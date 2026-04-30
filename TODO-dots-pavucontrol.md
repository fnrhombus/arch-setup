# TODO — Flip dots' audio-mixer references from `pwvucontrol` to `pavucontrol`

**Audience:** a Claude session with `rhombu5/dots` push access. This sandbox
can't push there directly. Apply, commit, push, then `git rm` this file from
arch-setup as the single allowed write to arch-setup for this task.

## Why

`docs/decisions.md:242` in `fnrhombus/arch-setup` is the source of truth for
audio-GUI choice and locks in **pavucontrol** (not pwvucontrol). Rationale:

> The PipeWire-native `pwvucontrol` was the original pick, but as of 2026-04
> its AUR build is broken — upstream is blocked on the unmaintained
> `wireplumber-rs` crate (issue #10), and the AUR's only path forward is a
> `libwireplumber-4.0-compat` shim that itself breaks every pipewire bump.

Re-checked 2026-04-30: still broken. `saivert/pwvucontrol#10` open;
`arcnmx/wireplumber.rs` last commit 2024-09; pwvucontrol main pins
features=['v0_4_16'] while Arch ships wireplumber 0.5.x.

postinstall installs `pavucontrol` (extra). dots still has two references
to `pwvucontrol` that need to flip.

## The two edits

### 1. `dot_local/bin/executable_control-panel`

```diff
-    ["  Sound"]="pwvucontrol"
+    ["  Sound"]="pavucontrol"
```

### 2. `dot_config/waybar/config.jsonc`

```diff
-        "on-click-right":  "pwvucontrol",
+        "on-click-right":  "pavucontrol",
```

(Search the file in case `pwvucontrol` is referenced in more than one
module/binding — `grep -n pwvucontrol dot_config/waybar/config.jsonc`.)

## Apply

```bash
cd ~/.local/share/chezmoi   # or wherever rhombu5/dots is checked out

sed -i 's/pwvucontrol/pavucontrol/g' \
    dot_local/bin/executable_control-panel \
    dot_config/waybar/config.jsonc

# Verify nothing else references pwvucontrol that should also flip:
grep -rn pwvucontrol .

git add dot_local/bin/executable_control-panel dot_config/waybar/config.jsonc
git commit -m "$(cat <<'MSG'
audio mixer: pwvucontrol → pavucontrol (matches decisions.md)

pwvucontrol's AUR build is still broken on wireplumber 0.5 (its
binding crate is pinned to 0.4.x and unmaintained — see
saivert/pwvucontrol#10). decisions.md picks pavucontrol; postinstall
installs pavucontrol; dots was the last place still launching the
non-installed binary, which surfaced as a silent no-op when the user
picked Sound from the control panel.
MSG
)"
git push origin main
```

## Cleanup of THIS file

Same atomic-commit pattern as prior dots-side TODOs: in arch-setup,
`git rm TODO-dots-pavucontrol.md`, commit + push to main. Single allowed
write to arch-setup for this task.
