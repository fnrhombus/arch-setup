# autounattend.xml — hand-patch record

Source of truth for all of this is [decisions.md](decisions.md). The `autounattend.xml` the user generated on schneegans.de is a starting skeleton; the patches below have been **already applied**. This doc records what was changed so future edits don't accidentally undo them.

## 1. Disk detection + diskpart (windowsPE pass, Orders 6–9)

**Stock Schneegans behavior:** a chain of `cmd.exe /c echo:...` commands appends a fixed diskpart script to `X:\pe.cmd` that runs `SELECT DISK=0` unconditionally and creates a 300 MB EFI + an NTFS partition that fills the remaining space (minus a 1 GB recovery partition it later carves off).

**Patched behavior:**
- **Order 6** runs an inline PowerShell one-liner: `Get-Disk | ?{$_.Size -gt 500GB -and $_.Size -lt 600GB}`. If exactly one disk matches, its number is written to `X:\target-disk.txt`. Zero or multiple matches → the script exits 1 and the runbook's recovery entry under Phase 1 step 3 handles it.
- **Order 7** reads the number via `set /p TARGET_DISK=<X:\target-disk.txt` and uses `%TARGET_DISK%` in the generated `X:\diskpart.txt`, which lays out: EFI 512 MB FAT32 → MSR 16 MB → Windows 160 GiB NTFS → trailing ~316 GiB left unallocated for Arch btrfs.
- **Orders 8–9** drop the Schneegans recovery partition (decisions.md §Q9: recovery ISO lives on the Netac, not the Samsung).

Everything is embedded inline via the same cmd-echo-chain style Schneegans uses. **Do not re-introduce external files** (`windows-diskpart.txt`, `windows-diskpart-preflight.ps1`) — the earlier plan to use them was replaced because Schneegans's `<Extensions><File path=...>` dropper doesn't reliably land files on `X:\` in WinPE across all boot media.

## 2. Full-silent OOBE block (oobeSystem pass)

In `<settings pass="oobeSystem">` → `<component name="Microsoft-Windows-Shell-Setup" ...>`, the `<OOBE>` element is patched to:

```xml
<OOBE>
  <ProtectYourPC>3</ProtectYourPC>
  <HideEULAPage>true</HideEULAPage>
  <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
  <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
  <HideLocalAccountScreen>true</HideLocalAccountScreen>
  <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
  <SkipMachineOOBE>true</SkipMachineOOBE>
  <SkipUserOOBE>true</SkipUserOOBE>
  <NetworkLocation>Home</NetworkLocation>
</OOBE>
```

`SkipMachineOOBE` and `SkipUserOOBE` are deprecated by Microsoft but still honored on Windows 11; they stay as belt-and-suspenders.

`AutoLogon` (already configured with `LogonCount=1`, local password, account `Tom`) needs no change — it takes over once OOBE is silenced.

## 3. Specialize.ps1 additions

The `$scripts = @(...)` array in the `Specialize.ps1` file embedded in the XML's `<Extensions>` section has these extra blocks appended:

```powershell
# Belt-and-suspenders OOBE privacy skip
{
    reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v DisablePrivacyExperience /t REG_DWORD /d 1 /f;
};
# Disable hibernation + Fast Startup (decisions.md §Q9: "Disable Windows Fast Startup + hibernation for clean dual-boot")
{
    powercfg.exe /hibernate off;
    reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f;
};
# Keep Netac drive untouched by Windows - no swap/pagefile relocation here.
# decisions.md §Q9 reserves the entire Netac for Linux (Arch recovery ISO, swap, /var/log + /var/cache).
```

Note on "use the Netac for anything that doesn't hurt daily performance": the Netac's 128 GB is fully allocated in decisions.md §Q9 (1.5 GB recovery + 16 GB swap + ~110 GB `/var/log`+`/var/cache`). There is no room for Windows pagefile/temp without cutting into the Linux allocation. Per the fallback rule ("benefit Linux most"), the Netac stays Linux-only.

## 4. Prerequisites checklist (manual, before USB boot)

- [ ] BIOS: SATA controller mode **AHCI** (was RAID — decisions.md §Q9).
- [ ] BIOS: Secure Boot **Disabled** for the install (Ventoy Secure Boot support is awkward; re-enable after Arch with `sbctl` — INSTALL-RUNBOOK.md Phase 0).
- [ ] Back up anything on either drive — the preflight is safe but the install pass is destructive on the selected disk.
- [ ] Netac physically connected (so the Arch installer can see it in phase 2). Netac is never the Windows detection target, so connection is fine.

## 5. Post-install sanity checks

After Windows lands on the desktop as `Tom`:

- `Get-Partition` in PowerShell — confirm EFI 512 MB, MSR 16 MB, NTFS 160 GiB, and trailing unallocated ~316 GiB on the Samsung. Netac untouched.
- `powercfg /a` — "Hibernation has not been enabled" in output.
- `fsutil behavior query disableLastAccess` — value 1 (already set by the stock Schneegans script).
