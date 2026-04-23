# Claude Handoff — USB Rebuild (Dev Machine Session)

Paste this into a fresh Claude Code session on the Windows dev machine — the one that produces the Ventoy USB via `pnpm i`. Your job is to unblock fnrhombus's Windows 11 install on Metis (Dell Inspiron 7786) and fix two pre-existing bugs in this repo's `autounattend.xml`.

Branch to work on: **`claude/fix-linux-boot-issue-9ps2s`** — pull the latest before you start.

## TL;DR

1. **Today's unblock, try first**: Fresh `Ventoy2Disk.exe` install (NOT upgrade) on the SanDisk from this Windows dev machine, then `pnpm stage`. **This exact Ventoy+autounattend combo installed Windows successfully 2 days ago.** Only things that changed since: CMOS battery replaced → BIOS reset, and Ventoy was upgraded from 1.0.99 → 1.1.12 via `Ventoy2Disk.sh -u` on Linux. A Windows-native fresh install resets any state drift from both.
2. **If #1 fails, escalate to Rufus** on a second USB. No Ventoy, no autounattend. User manually clicks through Setup at the laptop. Loses auto-OOBE (~10 min of clicks); gains a working Windows.
3. **Repo fixes** (commit separately on this branch regardless of path):
   - Order 6 in `autounattend.xml` is silently broken (hardcoded DISK=0 instead of the documented PowerShell size match).
   - Order 11 still has `/CheckIntegrity /Verify`, which interacts badly with Ventoy wimboot.
   - `docs/autounattend-oobe-patch.md` and `CLAUDE.md` both describe behavior that doesn't exist in the XML — fix the drift.
4. **Don't just re-upgrade Ventoy** via the Linux script — already done, doesn't help, may be part of the problem.

## What's happening

fnrhombus has been stuck on phase 1 (Windows install) for hours. The install fails identically on BOTH his SanDisk 32GB USB and his internal 128GB Netac SATA SSD (which runs Ventoy as a recovery-boot source). Symptoms:

- **Ventoy normal mode** on `Win11_25H2_English_x64_v2.iso`: Windows Boot Manager dies with `0xc000014c`, file `\EFI\Microsoft\Boot\BCD`, before WinPE loads.
- **Ventoy wimboot mode** on the same ISO: WinPE boots, `pe.cmd` runs, DiskPart creates partitions successfully, then `dism.exe /Apply-Image /ImageFile:H:\sources\install.wim /Name:"Windows 11 Pro" /ApplyDir:W:\` fails with `Error: 13, "The data is invalid"`. DISM version `10.0.26100.7920`.

## Root cause (round-2 research)

**Win11 24H2/25H2 ships a new "ConX" setup engine. Ventoy's `auto_install` plugin + heavily-patched Schneegans `autounattend.xml` + ConX is a known-broken combination.**

- Ventoy's **normal mode** hands off to the ConX loader, which mismatches Ventoy's injected BCD path → `0xc000014c`.
- Ventoy's **wimboot mode** lands in a 25H2 WinPE whose DISM can't `/Apply-Image` after the patched diskpart sequence → Error 13 (WIM metadata read failure, per Microsoft TechNet).

The documented workaround ("integrate previous-version setup" via boot.wim registry edit) only works with a minimal autounattend — not a 21-order patched Schneegans XML like ours.

Sources:
- elevenforum: [W11 25H2 autounattend fails, how to integrate legacy setup](https://www.elevenforum.com/t/w11-25h2-autounattend-xml-fails-how-to-integrate-the-previous-legacy-setup.43235/)
- elevenforum: [Custom Win11 Pro 25H2 ISO fails unless old setup is used](https://www.elevenforum.com/t/custom-win11-pro-25h2-iso-fails-to-install-unless-old-setup-is-used.44995/)
- Microsoft TechNet: [DISM Error 13 "data is invalid"](https://social.technet.microsoft.com/Forums/windows/en-US/877705db-2fc5-45e5-9222-1a0ce3ac7c27/dism-applyimage-error-13-the-data-is-invalid)
- Ventoy issues [#722](https://github.com/ventoy/Ventoy/issues/722) and [#1790](https://github.com/ventoy/Ventoy/issues/1790) — 0xc000014c BCD, open since 2022.

## Already ruled out

- **ISO corruption.** SHA256 via Ventoy File checksum completes cleanly.
- **USB hardware.** Failures reproduce on USB AND internal SATA.
- **Ventoy version.** Both sticks on 1.1.12 (boot screen confirms).
- **`/CheckIntegrity /Verify` on the USB copy.** Sed-stripped; didn't help. (Still present in the repo source XML — see repo fixes below.)
- **SATA mode.** AHCI.
- **Fast Boot.** Thorough.
- **Secure Boot.** Disabled.

## CRITICAL repo bugs (fix regardless of path chosen)

### 1. `autounattend.xml` Order 6 — hardcoded DISK=0

The XML has:
```
cmd.exe /c >>X:\pe.cmd (echo:(echo 0)>X:\target-disk.txt)
```
That emits a literal `(echo 0)>X:\target-disk.txt` into pe.cmd — DISK=0 is hardcoded. There's no PowerShell size-matching.

`docs/autounattend-oobe-patch.md` and `CLAUDE.md` both claim Order 6 runs `Get-Disk | ?{$_.Size -gt 500GB -and $_.Size -lt 600GB}`. **That logic doesn't exist in the XML.** Someone regressed the patch without updating docs, or the patch was never applied.

Consequence: a future install could land on the wrong disk. Under Ventoy the disk-0 identity depends on enumeration order (Ventoy virtual disk, Netac, Samsung — any could be 0). Even if DISK=0 happens to hit Samsung today, it's a trap.

**Fix:** restore the PowerShell size-match the docs describe. Something like:
```cmd.exe /c >>X:\pe.cmd (echo:powershell.exe -NoProfile -Command "$d = Get-Disk ^| Where-Object {$_.Size -gt 500GB -and $_.Size -lt 600GB}; if ($d.Count -ne 1) { exit 1 }; $d.Number ^| Out-File -Encoding ascii X:\target-disk.txt")
```
Verify the escaping actually emits the right command in `pe.cmd` after generation. If escaping under Schneegans's cmd-echo-chain format proves too painful, use a PowerShell file in `<Extensions><File path="X:\find-disk.ps1">` — but note `autounattend-oobe-patch.md` §1 warns that Schneegans's `<File>` dropper is unreliable on X:.

### 2. `autounattend.xml` Order 11 — `/CheckIntegrity /Verify` still in source

```xml
<Path>cmd.exe /c >>X:\pe.cmd (echo:dism.exe /Apply-Image /ImageFile:%IMAGE_FILE% %SWM_PARAM% %IMG_PARAM% /ApplyDir:W:\ /CheckIntegrity /Verify || ...)</Path>
```

Strip the flags. They don't help (Error 13 still fires without them) and they cause false-positive verify failures on media with slow reads.

### 3. Doc drift

Update `docs/autounattend-oobe-patch.md` §1 and `CLAUDE.md` to match whatever disk-detection behavior actually ends up in the XML. Don't let docs claim features that aren't there.

## Recommended path A — Fresh Ventoy2Disk.exe reinstall (try first)

**User's data point: same stack worked 2 days ago.** The only changes since are CMOS battery reset (BIOS reconfigured — AHCI/FastBoot/SecureBoot verified correct at the laptop) and a Linux-side `Ventoy2Disk.sh -u` upgrade. A full Windows-native reinstall of Ventoy resets any state drift from the Linux upgrade.

### Steps

1. `git pull` on the repo.
2. Inspect `scripts/fetch-assets.ps1` — confirm the Ventoy version pin. Bump to 1.1.12 if still on 1.0.99.
3. Run `pnpm restore:force` to re-fetch ISOs + the pinned Ventoy release. Fresh download eliminates any corruption from prior staging.
4. Plug the SanDisk into the dev machine.
5. Run `Ventoy2Disk.exe` (from the extracted Ventoy release in `assets/`). **Click "Install" (not "Update")** — a full reinstall wipes the stick's Ventoy state entirely. Confirm the prompts (stick gets wiped).
6. Run `pnpm stage` to robocopy ISOs + configs + phase scripts onto the fresh Ventoy data partition.
7. User brings USB to laptop, F12 → SanDisk UEFI → Ventoy menu → Win11 ISO → **normal mode first**.

If Win11 installs cleanly, unblocked. Done for today. Repo fixes (below) can still land on this branch.

## Recommended path B — Rufus (if path A fails)

Fallback. User has been willing to sacrifice OOBE automation in prior discussions — this commits to that trade. Ventoy stays on SanDisk + Netac for the Arch install (phase 2).

### Steps

1. Pull the branch: `git pull`.
2. Download Rufus latest: https://rufus.ie/
3. Plug a fresh ~8GB+ USB (user will need to source one or reuse SanDisk AFTER Windows is installed — if reusing SanDisk, document that plan in your response so the user doesn't wipe it prematurely).
4. Run Rufus:
   - Device: the fresh USB
   - Boot selection: `assets/Win11_25H2_English_x64_v2.iso` (use the existing Fido-downloaded ISO in the repo's `assets/` dir)
   - Partition scheme: GPT
   - Target system: UEFI (non CSM)
   - Click Start; Rufus offers a "Customize Windows installation" dialog — check:
     - Remove requirement for Secure Boot and TPM 2.0 (belt-and-suspenders; 7786 has TPM but let Rufus skip the check)
     - Remove requirement for online Microsoft account (so local-account tom works)
     - Set username `tom` + password (user will provide — prompt him)
     - Regional settings: US English
   - Rufus builds a plain bootable Win11 installer with these tweaks baked in.
5. User brings USB to laptop, F12 → boot Rufus USB → Win11 Setup GUI → pick Windows 11 Pro → accept EULA → Custom install → pick Samsung SSD → delete all its partitions → pick "Unallocated Space", Setup creates its own default partitions (EFI + MSR + Windows filling the disk). **Issue for phase 2**: Windows will take the full 476GB, not leave 316GB for Arch. See "After Windows is installed" below.
6. OOBE runs normally (Rufus's tweaks skip the MSA login screen); user creates local account `tom`.

### After Windows is installed — shrink for Arch

Because we lose the autounattend's 160GB Windows partition limit, the Arch install phase 2 needs to shrink Windows first. From Windows Disk Management:
- Right-click `C:` → Shrink Volume → shrink by `315000` MB (leaves ~160 GB for Windows, ~315 GB unallocated).
- Reboot, continue phase 2 per `runbook/INSTALL-RUNBOOK.md` starting at the Arch install section.

Document this deviation in `docs/decisions.md` §Q9 or a new §Q9-bis.

## Alternative paths (if paths A + B both fail)

### C. Regenerate Schneegans XML without disk repartitioning

1. Visit https://schneegans.de/windows/unattend-generator/
2. Generate a 25H2-compatible unattend with the following choices:
   - **Disk configuration: Interactive** (user picks disk during install, no auto-partition)
   - OOBE skip, auto-logon for `tom`, local account, Microsoft account skip
   - Our existing Specialize.ps1 additions (hibernation off, HiberbootEnabled=0, DisablePrivacyExperience)
3. Diff against current `autounattend.xml`. Keep our patches that don't touch windowsPE. Drop all Order 5-13ish disk/DISM plumbing.
4. User picks Samsung in Setup's GUI; Windows Setup uses default partitioning.
5. After Windows install, same shrink step as above for Arch.

### D. Keep Ventoy + autounattend, downgrade the ISO path

Install from a **Win11 23H2 ISO** with `install.wim` swapped from 25H2 (legacy Setup runs → autounattend works → 25H2 gets installed). This is the workaround documented in the elevenforum thread above. ~1-2 hr. Keeps full automation. User would have to source a 23H2 ISO (not trivial — Microsoft doesn't host them anymore; needs UUP dump or similar).

## Commit discipline

- One commit per logical change (Rufus isn't a commit — it's a user action; but repo bug fixes each get their own).
- Suggested commits:
  1. `autounattend: restore PowerShell Samsung-by-size disk detection (Order 6)`
  2. `autounattend: strip /CheckIntegrity /Verify from DISM (Order 11)`
  3. `docs: update autounattend-oobe-patch.md and CLAUDE.md to match XML`
  4. (if Rufus path chosen) `docs: add §Q9-bis recording Rufus fallback + post-install shrink`
- Push on feature completion.
- Don't `amend`; make new commits if a hook fails.

## Handing back to the Android coach

When the Rufus USB is ready (or you've confirmed a different path), tell fnrhombus. The Android/phone Claude session will take over and coach him through the physical steps at the laptop.

## Key files

- `autounattend.xml` — the XML itself.
- `ventoy/ventoy.json` — `auto_install` plugin config. For the Rufus path, this can stay unchanged (Ventoy still handles Arch ISO).
- `scripts/fetch-assets.ps1` — bump Ventoy pin if still on 1.0.99. Verify it's already fetching 1.1.12+ for future rebuilds.
- `scripts/stage-usb.ps1` — robocopies onto Ventoy's data partition.
- `docs/decisions.md` §Q9 — partition layout; document the Rufus deviation here.
- `docs/autounattend-oobe-patch.md` — update §1 to match reality.
- `CLAUDE.md` — update the "Phase 1" section to match.

_Updated after round-2 research identified the Win11 25H2 ConX regression as root cause and uncovered the hardcoded-DISK=0 repo bug._
