# Claude Handoff — Android Coach Session (at the laptop)

Paste this into the Claude Code session running on fnrhombus's Android phone. You are coaching him physically at the Dell Inspiron 7786 (**Metis**) while he plugs the USB in and boots it. The dev-machine session has finished preparing the stick.

**When the Windows install succeeds (or you escalate back to the dev-machine session), delete this file (`docs/usb-rebuild-handoff.md`) and push the removal so it doesn't linger.**

Branch: **`claude/fix-linux-boot-issue-9ps2s`** — pull the latest before you start.

## State of the USB (as of this handoff)

- **Stick:** SanDisk Cruzer Glide 32 GB, freshly re-installed with **Ventoy 1.1.11** via `Ventoy2Disk.exe` on Windows (full Install, not Update — wiped and rebuilt from scratch). Prior state: stick had been upgraded 1.0.99 → 1.1.12 via `Ventoy2Disk.sh -u` on Linux, which correlates with the failure timing.
- **Staging:** `pnpm stage` completed cleanly. All ISOs + `autounattend.xml` + `ventoy/ventoy.json` + phase scripts + docs + runbook are on `E:\` (Ventoy data partition).
- **Integrity:** `Win11_25H2_English_x64_v2.iso` on the USB was SHA256-verified against Microsoft's published hash (`assets/Win11_25H2_English_x64_v2.iso.sha256` — commit [19ed2e4](https://github.com/fnrhombus/arch-setup/commit/19ed2e4)). Byte-identical. ISO corruption is ruled out.
- **Arch ISO:** `archlinux-x86_64.iso` on the USB was SHA256-verified against the signed `archlinux-sha256sums.txt` by `stage-usb.ps1`. Clean.

## At the laptop — physical steps

Coach fnrhombus through these. `runbook/INSTALL-RUNBOOK.md` on the USB has more prose if he wants it, but this is the short version.

1. Plug the SanDisk into the Dell 7786.
2. Power on, mash **F12** to get the one-time boot menu.
3. Pick the **UEFI** entry for the SanDisk (NOT the legacy one, NOT the internal drives).
4. Ventoy menu appears. Arrow-key to `Win11_25H2_English_x64_v2.iso`. Press **Enter**.
5. Ventoy asks normal vs wimboot. **Pick normal mode first.** (Enter, or F1.)
6. Windows Setup takes over. With `ventoy/ventoy.json` auto-injecting our autounattend, it should run fully unattended from here: partition the Samsung → apply `install.wim` → reboot → OOBE silenced → autologon as Tom.

**Expected duration, normal path:** ~20 min from menu-pick to desktop.

## If normal mode fails

Known failure modes from today's prior attempts:

- **`0xc000014c` on Windows Boot Manager** (before WinPE loads): Ventoy normal-mode + ConX loader mismatch. Switch to **wimboot mode** (press F1 at the Ventoy prompt).
- **DISM `Error: 13, "The data is invalid"`** during `/Apply-Image` in wimboot mode: this is the hard failure. Win11 25H2 ConX + Ventoy wimboot + patched autounattend is the known-broken combination documented in the elevenforum threads (search "W11 25H2 autounattend fails").

**If wimboot also fails with Error 13:** don't spin. Report back. The dev-machine session has a Rufus fallback path (documented in the prior handoff that this file replaced — `git log --all --diff-filter=D -- docs/usb-rebuild-handoff.md` will recover it). Rufus means no autounattend automation — fnrhombus clicks through Setup manually — but it works.

**What to report back when escalating:**
- Which mode failed (normal / wimboot).
- Exact error code and the preceding cmd-window scrollback if visible.
- Which Ventoy-menu ISO was picked (shouldn't matter but confirm).

## Known repo issues (not blocking this attempt)

The dev-machine session identified three pre-existing bugs in `autounattend.xml` but **has not yet committed fixes** because today's priority was unblocking the install. Don't stress about them during this session — they're flagged here only so you're not surprised if the install hits an edge case:

1. **Order 6 hardcodes DISK=0** instead of running the documented PowerShell size-match against `Get-Disk | Where-Object {$_.Size -gt 500GB -and $_.Size -lt 600GB}`. On this 7786, disk enumeration under Ventoy happens to put Samsung at 0 (that's why the install worked 2 days ago), but it's luck, not logic.
2. **Order 11 still carries `/CheckIntegrity /Verify`** on the DISM line. Causes false-positive verify failures on slow USB media; doesn't help with real corruption.
3. **Doc drift:** `docs/autounattend-oobe-patch.md` §1 and `CLAUDE.md`'s Phase 1 description both claim the PowerShell size-match is in place. It isn't.

If today's install works, the dev-machine session will commit the three fixes on this branch afterward.

## Credentials / passwords fnrhombus will need ready

- **Tom's Windows local-account password:** already baked into `autounattend.xml` (encoded). Nothing to type during install.
- **BIOS password:** if any — he should know. Not needed unless BIOS prompts.
- **Arch root + tom passwords:** phase 2, not today.

## After Windows boots to the Tom desktop

1. Let the `WingetImportOnce` scheduled task fire (~2 min after first logon, installs apps from `phase-1-windows/winget-import.json`).
2. Check `C:\Windows\Setup\Scripts\BitLocker-Recovery.txt` **and** `E:\bitlocker-recovery.txt` (USB) — both should contain the recovery key. Have fnrhombus photograph the USB copy as belt-and-suspenders.
3. Shut down, leave the SanDisk plugged in, and hand back to the runbook for phase 2 (Arch install).

## Clean up before you finish

When the Windows install lands cleanly (or you hand back to the dev-machine session for the Rufus path), delete this file:

```bash
git rm docs/usb-rebuild-handoff.md
git commit -m "docs: remove usb-rebuild-handoff (Windows install succeeded on 2026-04-23)"
git push
```

If the install failed and we're pivoting to Rufus, change the commit message to reflect that — but still delete. This file is a one-shot bridge, not a permanent doc.

_Updated 2026-04-23 after USB rebuild + SHA256 verification on the dev machine. ISO integrity confirmed; failure mode (if any) now points squarely at the Win11 25H2 ConX + Ventoy auto_install + patched autounattend combo._
