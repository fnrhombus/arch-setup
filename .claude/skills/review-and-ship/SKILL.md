---
name: review-and-ship
description: Iterative review-until-clean loop for the arch-setup repo. Reviews decisions, runbook, and scripts for issues; commits, pushes, and syncs the Ventoy USB; repeats until a full pass produces zero changes; then regenerates the runbook PDF.
---

# review-and-ship

Run an iterative review-commit-sync loop over the arch-setup bootstrap repo until the whole thing converges on zero changes, then emit the PDF runbook.

## When to invoke

The user asks for a review pass, a "ship it", a "make sure everything's ideal", or anything that implies "look at everything end-to-end and fix what's wrong". Typical trigger phrases: "review", "go through it", "make sure it's right", "ship".

## The loop — one iteration

Do all four of these. As much in parallel as is sensible:

1. **Think carefully about whether every choice is ideal.**
   - Are there better options than the ones in `docs/decisions.md`? If you have **high confidence** in an improvement, make it. If **unsure, discuss with the user — DO NOT GUESS**.
   - Cross-check `docs/decisions.md`, `docs/autounattend-oobe-patch.md`, `docs/wsl-setup-lessons.md`, `runbook/INSTALL-RUNBOOK.md`, `runbook/phase-3-handoff.md`, `runbook/phase-3.5-hardware-handoff.md`, `runbook/GLOSSARY.md`, `runbook/SURVIVAL.md`, `autounattend.xml`, `phase-2-arch-install/*.sh`, `phase-3-arch-postinstall/*.sh`, `scripts/*.ps1`, `scripts/runbook-pdf.mjs`, `ventoy/ventoy.json` for drift. `docs/decisions.md` is the source of truth; anything else that disagrees with it is the thing that's wrong.

2. **Think carefully about what's going to go wrong on the real hardware** and make sure the runbook has recovery instructions for it.
   - Examples: wrong BIOS mode, Secure Boot surprise, no Ethernet after Arch install, btrfs won't mount, systemd-boot doesn't see Windows, fingerprint not detected, Hyprland fails to start.
   - Every plausible failure mode needs either a preventive step or a rescue recipe in the runbook.

3. **Think carefully about anything missed.** If **high confidence**, add it. Otherwise discuss with the user.

4. **Commit, push, sync USB.**
   - `git status` + `git diff` to see what's changed.
   - Stage specific files (not `git add -A`).
   - Commit with a message that names the *why*, not just the *what*. No Claude co-author line.
   - `git push origin main`.
   - `pnpm stage` to mirror artifacts onto the Ventoy USB. Auto-detects the `Ventoy`-labeled partition; soft-exits if no USB is plugged in (that's fine — note it in the turn summary).

## Repeat until convergence

Re-run the loop until one full iteration produces **zero file changes and no commits**. Report the number of iterations.

Delegate review passes to an `Explore` subagent (Sonnet model) with a detailed, self-contained brief — it has to see everything without your conversation context. Ask it for a **"CLEAN — no changes needed"** verdict or a specific list of issues with file paths and line numbers.

## After convergence — emit the PDF

Only once the loop has converged:

- Render `runbook/INSTALL-RUNBOOK.md` → `runbook/INSTALL-RUNBOOK.pdf` via `pnpm pdf` (script already wired in `package.json`, uses `marked` + Edge headless).
- Target spec: **5.5" × 8.5" pages, 0.5" max margins, 12pt body font.** If any single spec makes it drastically harder, drop that one — not all three.
- Commit + push the PDF (and re-stage USB if the PDF belongs there — default: not staged, since the markdown is already on the USB).

## What to watch for (non-exhaustive)

- **Parity drift** between `docs/decisions.md` and downstream scripts/docs. E.g., package lists in `postinstall.sh` vs. the Software Inventory in `runbook/phase-3-handoff.md`; tools in `postinstall.sh` vs. definitions in `runbook/GLOSSARY.md`.
- **Ventoy staging gaps** — files referenced by the runbook that aren't in `stage-usb.ps1`'s `$rootFiles`.
- **Diskpart/autounattend**: EFI 512 MB, MSR 16 MB, Windows 160 GiB, trailing unallocated on the Samsung. Netac untouched in phase 1. Disk selected by 500-600 GB size window, not by disk number.
- **NVIDIA**: MX250 is blacklisted. Any mention of nvidia/Optimus/nouveau being *used* is wrong.
- **Tool inventory**: `postinstall.sh` is authoritative for what's actually installed. If a doc claims a tool is installed and it's not in postinstall, one of them is wrong.

## What to leave alone

- `debug.log` — treat as stray output, don't commit.
- `assets/*.iso` — gitignored, populated by `pnpm restore`.
- `node_modules/` — gitignored.

## Tone

Terse. Report the iteration count, what changed each round, and the final PDF size. No trailing summary beyond that.
