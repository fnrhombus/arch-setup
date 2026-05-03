---
name: audit-reinstall-parity
description: Audit whether a fresh post-postinstall (plus first interactive shell) would reproduce the current live system. Use when the user asks about reinstall parity, drift between scripts and live state, or "what would I lose if I reinstalled". Embeds the gotchas (chezmoi clobbers postinstall §10 writes, arch-setup-bootstraps planters fill in user-specific state, verify CLI semantics with --help before inferring) that prevent false-positive drift findings.
---

# audit-reinstall-parity

Audit whether a fresh `bash postinstall.sh` plus first interactive shell would reproduce the current live system.

## When to invoke

User asks any variant of:
- "would a fresh install be the same as live?"
- "what would I lose if I reinstalled?"
- "audit drift between scripts and live"
- "is X reproducible from the repo?"

## Out of scope (do NOT flag as drift)

- Orphan packages — extras with no script reference and no functional impact.
- Temp files, cache, runtime sockets.
- Anything in `~/src`.
- Leftover state from packages no longer installed (e.g. `/etc/letsencrypt/` after certbot was removed) — gone on a fresh install too.

## Three layers — trace ALL THREE before flagging anything

A "fresh post-postinstall" is the stacked result of three layers:

1. **Install scripts** (`~/src/arch-setup@fnrhombus/`): pacstrap, chroot.sh, postinstall.sh package installs / HEREDOCs / system-file writes.
2. **chezmoi** (`~/.local/share/chezmoi/` → live `$HOME`): postinstall §13 runs `chezmoi init --apply rhombu5/dots` AFTER §10 writes `~/.zshrc` and `~/.zsh_aliases`. **chezmoi clobbers postinstall's writes for any chezmoi-managed path.** Always run `chezmoi managed -- <path>` before treating a postinstall HEREDOC as canonical. If managed, chezmoi's source is canonical and `chezmoi diff` empty means live = canonical.
3. **arch-setup-bootstraps planters** (`~/.local/share/arch-setup-bootstraps/`, shipped via dots, dispatched by `~/.zshrc.d/arch-bootstrap-runner.zsh`): self-deleting scripts that fire on first interactive shell to do user-specific setup (gh auth, ssh signing, etc.). A planter file still on disk means it never ran successfully — but the target file may have been hand-set, producing the same final state. Read the planter's logic before declaring its target unreproducible.

## Direction of fix

For each real difference, decide **which side is wrong** before writing the fix. Sometimes the script is stale and the live system got the right answer via yay dep resolution, hand-correction, or an upstream fix. "Live differs from script" doesn't automatically mean "fix the live system."

## Verifying state with CLI tools

Read the tool's `--help` before inferring meaning from output. Don't infer from error strings:
- `pinutil test` returning `PinIsEmpty` means "you submitted an empty PIN", not "no PIN configured". `pinutil status` is authoritative.
- Any tool with both `test` and `status` subcommands: prefer `status` for state queries.

## Method

1. Inventory what `bash postinstall.sh` would produce (packages, system files, services, user-level writes). A subagent with the brief "produce a comprehensive inventory of every persistent state change" over postinstall.sh + chroot.sh + install.sh works well — it isolates the inventory from the comparison.
2. Query live state in parallel: `pacman -Qe`, `pacman -Qm`, `systemctl list-unit-files --state=enabled`, `chezmoi diff`, `chezmoi managed`, `/etc` mtimes vs install date.
3. For each apparent gap, trace the three layers before declaring drift.
4. Report only confirmed drift, with which side is wrong and the fix.

## Tone

Terse. Show conclusions, not process. End with the shortest accurate summary: "live matches" or "N real drifts: X (live wrong, fix Y); Z (script wrong, fix W)".
