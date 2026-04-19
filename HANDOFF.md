# HANDOFF — session state for the Android Claude session

**First thing to do: delete this file after reading.** `git rm HANDOFF.md && git commit -m "handoff: android session picked up context, removing handoff" && git push`. Do this *before* starting work so you don't accidentally commit alongside it.

This file is a pure context dump, not a plan — once you've read it, its job is done.

---

## Why this exists

On 2026-04-18 a laptop-side live boot of Arch off the Ventoy USB failed with `EXT4-fs (loop0): VFS: Can't find ext4 filesystem`. A Windows-side debugging session (this one) ruled out ISO corruption and prepared two sticks. You (the Android session) are expected to drive the next attempt from the Dell 7786 itself while the dev PC is not nearby.

## Key finding — the ISO is NOT corrupt

Don't waste time re-downloading the Arch ISO. Already proven with hard evidence:

- `archlinux-x86_64.iso` on USB was hashed directly with `Get-FileHash -Algorithm SHA256`, four-way compared against: (a) fresh upstream download, (b) `sha256sums.txt` on USB, (c) `sha256sums.txt` from upstream. All four hashes matched: `f14bf46afbe782d28835aed99bfa2fe447903872cb9f4b21153196d6ed1d48ae`.
- The USB ISO's `LastWriteTime` (4/17) predates this entire session — those are the same bytes the 7786 tried to boot.
- `stage-usb.ps1` now has a post-copy SHA256 verify step; both sticks below passed it.

So the loop0/ext4 boot failure has some OTHER cause. See "Debugging hypotheses" below.

## Two USB sticks are ready

### Stick F: — SanDisk Cruzer U, 7.5 GB, **primary, known-good**
- Freshly Ventoy-formatted today (MBR, Secure Boot enabled).
- Contains the **Arch-only subset**: `archlinux-x86_64.iso` + sig + sha256sums + `CLAUDE.md` + `phase-6-grow-windows.sh`, plus subdirs `ventoy/`, `phase-2-arch-install/`, `phase-3-arch-postinstall/`, `docs/`, `runbook/`.
- **No Windows ISO, no `autounattend.xml`, no `phase-1-windows/`** — Windows is already installed on the 7786's Samsung SSD. This stick is for Phase 2 only.
- SHA256 verify on Arch ISO: passed.
- **Try this stick FIRST** on the laptop.

### Stick E: — SanDisk Cruzer Glide, 29 GB, **fallback, HARDWARE-SUSPECT**
- Also freshly Ventoy-formatted today.
- Contains the full payload: both ISOs + everything.
- But during staging, the 8 GB Win11 ISO write wedged the Windows kernel for 24+ minutes with 0 B/s disk activity; `Write-VolumeCache -DriveLetter E` also hung; only physically yanking the stick released the stuck I/O. That's a hardware fault signature.
- The files are on it now and hash-verify clean, but the stick has a demonstrated I/O fault under sustained load, which is *exactly the same class of workload* that Ventoy does at boot time (`memdisk copy of ISO into RAM`). This stick is the most plausible single suspect for the original loop0 failure.
- **Only fall back to this stick** if F: is completely unavailable.

## Debugging hypotheses for loop0/ext4 (in rough probability order)

1. **Stick-level hardware fault on the Cruzer Glide (E:)** — strongest candidate given the kernel wedge on the dev PC during a similar workload. Mitigation: F: is a different stick, try it.
2. **7786 USB port/controller flake** — intermittent read errors at boot corrupt the in-RAM copy even from a good stick. Mitigation: try the *other* USB-A port on the 7786. If both ports fail with both sticks, suspect the controller.
3. **Ventoy plugin/config mismatch** — unlikely, `ventoy/ventoy.json` only auto-injects `autounattend.xml` for the Win11 ISO selection. For an Arch selection it doesn't interpose.
4. **Kernel cmdline / label search** — try picking the ISO in "Normal mode" first; if that fails, "Memdisk mode" (`d` at the Ventoy menu). If Memdisk also fails with the same error on F:, the on-disk ISO truly is bad on that stick (but we've already ruled that out for E:).
5. **archisosearchuuid / archisobasedir** — in archiso you can pin the search: edit the Ventoy kernel cmdline at boot to add `archisosearchuuid=<uuid>` where `<uuid>` is the ISO's volume UUID. Unlikely to matter if loop0 can't even read the filesystem, but keep in reserve.

If loop0 fails again: get a rescue shell (the initramfs drops you to a `(initramfs)` prompt after the error), then `dmesg | tail -40` and read it out loud — USB errors (`usb 1-X.Y: reset high-speed USB device...`, `sd X:X:X:X: [sdb] tag#N UNKNOWN(...) Result: hostbyte=...`) will name the cause.

## Session summary — what already landed in this repo

Branch: **`claude/fix-linux-boot-issue-9ps2s`** (not `main`). Recent commits, newest first:

- `handoff: arch iso re-staged + verified, removing handoff` — killed the previous handoff after confirming the ISO is not corrupt.
- `fetch+stage: SHA256-verify Arch ISO, document Memdisk fallback` — `scripts/fetch-assets.ps1` now hash-checks the downloaded ISO against the sibling `sha256sums.txt`; `scripts/stage-usb.ps1` re-hashes the USB copy after robocopy. `runbook/INSTALL-RUNBOOK.md` got a troubleshooting block for the loop0 error.
- `CLAUDE.md: fix pdf description — pnpm pdf renders every runbook/*.md` — prior docs claimed `pnpm pdf` only rendered `INSTALL-RUNBOOK.pdf`; corrected.
- `scripts: split prune out of stage, chain it via pnpm stage` — new `scripts/prune-usb.ps1`, exposed as `pnpm prune:usb`, chained after `pnpm stage` / `pnpm stage:force`. Prunes managed-subdir files that left the repo, and root files not in the allowlist (preserves `.iso` and unknown directories).
- `pnpm-lock: bump marked 18.0.1 → 18.0.2` — fixed a lockfile drift from a stale standalone pnpm; mise-managed pnpm 10.x is now wired up on this machine.

The dev PC has:
- `mise` installed via winget (user scope) — `mise exec -- pnpm ...` is the right way to invoke pnpm here.
- `pnpm prune:usb` as a standalone task.
- `.vscode/settings.json` with file nesting (`*.md` → `${capture}.pdf`), local-only since `/.vscode/` is gitignored.

## What you're picking up to do

1. **Delete this HANDOFF.md** (commit + push, see top of file).
2. On the 7786, boot the F: stick, pick the Arch entry from the Ventoy menu in Normal mode.
3. If it boots into archiso cleanly: mount `/dev/disk/by-label/Ventoy` (this is tricky once booted — see commit `f5cd1c8` "Fix Ventoy data-partition mount from inside the booted Arch ISO" for the fix that was added), then `cd` to the mounted data partition and run `./phase-2-arch-install/install.sh`. That prompts once for root + `tom` passwords, pacstraps, runs chroot.sh, and finishes.
4. Reboot into Arch, log in as `tom`, run `~/postinstall.sh` for Phase 3.
5. If loop0 fails again: see "Debugging hypotheses" above. Don't re-download the ISO — it's not the problem.

## Things NOT to do

- Don't blame the ISO — SHA256 has been exhausted. Four-way match.
- Don't run `pnpm restore:force` as a fix — it re-downloads 10 GB and changes nothing for the loop0 failure.
- Don't use stick E: unless F: is physically broken/lost — E: has a demonstrated I/O fault under load.
- Don't waste time reformatting either stick again — both just got Ventoy-installed fresh today.
- Don't assume branch is `main`. You're on `claude/fix-linux-boot-issue-9ps2s`.
