# HANDOFF — Migrate `~/.zshrc.d/` bootstrap planters from postinstall to dots

**Why this is a handoff:** this Claude session works inside `fnrhombus/arch-setup`
only — its GitHub MCP is repo-scoped, and HTTPS `git push` to
`https://github.com/rhombu5/dots.git` fails for lack of credentials. The
refactor below requires writes to **both** repos (dots gets new files;
arch-setup loses the now-redundant heredocs in `postinstall.sh`). A session
with `rhombu5/dots` push access can do both halves.

---

## What's currently wrong

`phase-3-arch-postinstall/postinstall.sh` plants three self-deleting bootstrap
scripts directly into the live user's `~/.zshrc.d/`:

| Planter file | Source location in postinstall.sh | Trigger condition | Self-deletes when |
|---|---|---|---|
| `arch-first-login.zsh` | §9 Phase A (heredoc near line 1067) | TTY login, `gh` not authed | `gh auth status` OK |
| `arch-ssh-signing.zsh` | §9 Phase B (heredoc near line 1002) | Bitwarden SSH-agent socket exists | `~/.ssh/allowed_signers` populated + key registered with `gh` |
| `arch-hyprpm-bootstrap.zsh` | §14 (heredoc near line 1354) | Inside a Hyprland session | hyprexpo + hyprgrass both loaded |

The functional behavior is fine — each bootstrap runs once when its
precondition is first met, then self-deletes. The problem is **layering**:
`postinstall.sh` is generating user-shell-init files at install time, which
is chezmoi territory. Two consequences:

- `~/.local/share/chezmoi` / `rhombu5/dots` is no longer the source of truth for what's in `~/.zshrc.d/`.
- A `chezmoi state delete-bucket --bucket=scriptState && chezmoi apply` won't re-run any of these (they aren't chezmoi scripts), but `~/postinstall.sh` will. Mental model split.

## Why `.chezmoiscripts/run_once_after_apply-*` is NOT a clean fit

`chezmoi run_once_after_apply-*.sh.tmpl` runs at **`chezmoi apply` time**,
which on this machine is during postinstall — long before any of the three
preconditions can be true:

- `arch-first-login`: needs interactive TTY for `bw login` + `gh auth login` master-password / device-code prompts. chezmoi's process context is not guaranteed-interactive.
- `arch-ssh-signing`: needs the Bitwarden SSH-agent socket, which doesn't exist until the user has launched Bitwarden Desktop, logged in, and toggled the SSH-agent setting on. That happens hours-to-days after install.
- `arch-hyprpm-bootstrap`: needs `HYPRLAND_INSTANCE_SIGNATURE`, only set inside a running Hyprland session. Postinstall runs from TTY.

Each script's "fire on first occurrence of precondition" semantic is
fundamentally a per-shell-init pattern, not a one-shot-at-apply-time pattern.
That's why the planter approach exists.

## Target architecture

Source of truth moves back to `rhombu5/dots`. The per-shell self-delete
mechanism stays (preconditions require it). The split:

```
rhombu5/dots/
├── dot_local/share/arch-setup-bootstraps/
│   ├── executable_first-login.sh     ← script body (was the §9 Phase A heredoc)
│   ├── executable_ssh-signing.sh     ← script body (was the §9 Phase B heredoc)
│   └── executable_hyprpm.sh          ← script body (was the §14 heredoc)
└── dot_zshrc.d/arch-bootstrap-runner.zsh  ← tiny dispatcher; sources each
                                              eligible bootstrap, deletes the
                                              individual script on success
```

`fnrhombus/arch-setup` then loses §9's two `cat > ~/.zshrc.d/...` heredocs and
§14's planter block — each replaced by a comment pointing at dots. Postinstall
keeps its non-planter responsibilities (the `gh api user` lookup that writes
`~/.gitconfig.local` once `gh` is authed, etc.).

## File contents — extract from postinstall.sh

Rather than duplicate all three heredoc bodies inside this handoff (where they
will rot), the dots session should:

1. Open `phase-3-arch-postinstall/postinstall.sh` on `main` of `fnrhombus/arch-setup`.
2. Find the three heredocs by their EOF tag names: `AUTHEOF` (Phase A, ~line 1067), `SIGEOF` (Phase B, ~line 1002), `HYPRPMEOF` (§14, ~line 1354).
3. Copy the body of each heredoc verbatim into the new `dot_local/share/arch-setup-bootstraps/executable_*.sh` files.
4. Add a shebang (`#!/usr/bin/env zsh`) and adjust the self-delete line at
   the bottom of each script to point at its NEW location:
   - Old: `rm -f ~/.zshrc.d/arch-first-login.zsh`
   - New: `rm -f ~/.local/share/arch-setup-bootstraps/first-login.sh`

Keep all other logic byte-identical. The `[[ -n "${_POSTINSTALL_NONINTERACTIVE:-}" ]]`
guard at the top of the existing scripts can stay — it's still useful (it
suppresses the bootstraps during postinstall's own zgenom warmup subshell).

## The runner — `dot_zshrc.d/arch-bootstrap-runner.zsh`

```zsh
# arch-setup: dispatch any pending bootstraps from
# ~/.local/share/arch-setup-bootstraps/. Each script self-checks its own
# precondition and self-deletes on success. Runner is a no-op when the
# directory is gone (everything has bootstrapped).
if [[ -n "${_POSTINSTALL_NONINTERACTIVE:-}" ]]; then
    return 0
fi
local _bootstrap_dir="$HOME/.local/share/arch-setup-bootstraps"
[[ -d "$_bootstrap_dir" ]] || return 0
for _bs in "$_bootstrap_dir"/*.sh(N); do
    source "$_bs"
done
unset _bs _bootstrap_dir
# Once the dir is empty, prune it to keep the home tidy.
[[ -d "$HOME/.local/share/arch-setup-bootstraps" ]] \
    && [[ -z "$(ls -A "$HOME/.local/share/arch-setup-bootstraps" 2>/dev/null)" ]] \
    && rmdir "$HOME/.local/share/arch-setup-bootstraps" 2>/dev/null
```

## arch-setup side: postinstall.sh changes

Three independent edits in `phase-3-arch-postinstall/postinstall.sh`. Each can
land in its own commit, but bundling into one "remove planters; dots owns
~/.zshrc.d/ now" commit is fine since the changes are tightly coupled.

1. **§9 Phase A** — keep the `if gh auth status &>/dev/null; then ...` branch
   that writes `~/.gitconfig.local` from `gh api user` (that's not a planter,
   it's a one-shot lookup; runs only when `gh` is already authed at install
   time). Delete the `else` branch's `cat > "$HOME/.zshrc.d/arch-first-login.zsh" <<'AUTHEOF'` heredoc and surrounding logic. Replace with a `log` line noting that `arch-bootstrap-runner` (from dots) handles first-login if `gh` isn't yet authed.

2. **§9 Phase B** — delete the `cat > "$HOME/.zshrc.d/arch-ssh-signing.zsh" <<'SIGEOF'` heredoc entirely. Replace with a `log` line noting that signing is wired by `arch-bootstrap-runner`.

3. **§14** — the entire `else` branch starting at `log "Not in a Hyprland session — planting first-Hyprland-login hyprpm runner."` and including the `cat > "$HOME/.zshrc.d/arch-hyprpm-bootstrap.zsh" <<'HYPRPMEOF'` heredoc. Delete and replace with a `log` line noting that hyprpm bootstrap is handled by `arch-bootstrap-runner`. The IF branch (the inline path that runs hyprpm directly when `HYPRLAND_INSTANCE_SIGNATURE` IS set during postinstall) can stay — it's a useful fast-path for the rare case where postinstall is re-run from inside a Hyprland session.

After these edits, search the rest of `postinstall.sh` for any remaining
references to `~/.zshrc.d/arch-{first-login,ssh-signing,hyprpm-bootstrap}.zsh`
and update or remove. The verify block (around line 1500-1640) should not be
affected — it doesn't currently check for these planter files.

## Apply (dots session)

```bash
cd ~/.local/share/chezmoi   # or wherever rhombu5/dots is checked out

mkdir -p dot_local/share/arch-setup-bootstraps
# (extract the three heredoc bodies from arch-setup's postinstall.sh and
# write to executable_first-login.sh, executable_ssh-signing.sh,
# executable_hyprpm.sh; adjust the self-delete paths as described above)

cat > dot_zshrc.d/arch-bootstrap-runner.zsh <<'EOF'
# (paste the runner from this handoff)
EOF

git add dot_local/share/arch-setup-bootstraps dot_zshrc.d/arch-bootstrap-runner.zsh
git commit -m "$(cat <<'MSG'
move ~/.zshrc.d/ bootstraps from postinstall planters to dots-owned scripts

Three self-deleting planters (first-login, ssh-signing, hyprpm) used to
be written into ~/.zshrc.d/ by phase-3-arch-postinstall/postinstall.sh.
That meant arch-setup was generating user-shell-init files, breaking the
chezmoi-as-source-of-truth contract for ~/.zshrc.d/.

Move the script bodies into dot_local/share/arch-setup-bootstraps/ and
add a small dispatcher in dot_zshrc.d/arch-bootstrap-runner.zsh that
sources each on shell init. Each script still self-checks its own
precondition (TTY for first-login, Bitwarden agent socket for ssh-signing,
HYPRLAND_INSTANCE_SIGNATURE for hyprpm) and self-deletes on success, so
runner overhead drops to zero once everything has bootstrapped.

Companion change in fnrhombus/arch-setup deletes the heredocs from
postinstall.sh §9 + §14.
MSG
)"
git push origin main
```

## Apply (arch-setup session, follow-up)

After the dots commit lands and you've pulled latest in arch-setup:

1. Make the three edits described in "arch-setup side: postinstall.sh changes" above.
2. `git rm HANDOFF-zshrc-bootstraps-to-dots.md` — handoff is consumed.
3. Atomic commit, push to `origin/main`.

## Cleanup of THIS file

Whichever session does the arch-setup-side `postinstall.sh` edits also
deletes this handoff in the same commit (or as the immediately-following
commit if the edits are split across multiple commits). The handoff's
purpose ends when both halves of the refactor have landed.
