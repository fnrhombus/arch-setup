# autounattend.xml — hand-patch checklist

Source of truth for all of this is [decisions.md](decisions.md). The `autounattend.xml` the user generated on schneegans.de is a starting skeleton — splice the fragments below in by hand.

## 1. Replace the `windowsPE` diskpart block

The stock XML builds its diskpart script via ~15 `cmd.exe /c echo:...` commands in the `windowsPE` pass that append line-by-line into `X:\diskpart.txt`. **Delete all of those.** Replace them with two `RunSynchronousCommand` entries (plus the two files they reference, which must reach `X:\` before diskpart runs — either via Schneegans' `<Extensions><File path="X:\...">` mechanism or another inlining approach):

```xml
<RunSynchronousCommand wcm:action="add">
  <Order>1</Order>
  <Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\windows-diskpart-preflight.ps1</Path>
  <Description>Auto-detect Samsung 512GB disk by size; substitute into diskpart template.</Description>
</RunSynchronousCommand>
<RunSynchronousCommand wcm:action="add">
  <Order>2</Order>
  <Path>cmd.exe /c "diskpart.exe /s X:\diskpart-runtime.txt &gt;&gt;X:\diskpart.log || ( type X:\diskpart.log &amp; echo diskpart failed. &amp; pause &amp; exit /b 1 )"</Path>
</RunSynchronousCommand>
```

Files referenced:
- `windows-diskpart.txt` — the layout template (EFI 512 MB / MSR 16 MB / Windows 160 GB / rest unallocated for Arch).
- `windows-diskpart-preflight.ps1` — size-based disk detection + token substitution.

The stock XML's `<ImageInstall><OSImage><InstallToAvailablePartition>true</InstallToAvailablePartition></OSImage></ImageInstall>` is **correct as-is** — we create exactly one NTFS partition, so "first available NTFS" always picks it.

Also keep the stock Windows Defender disable block (`defender.vbs` writer + cscript launcher) if you want it; it's independent of the partition changes.

## 2. Rewrite the `<OOBE>` block for full silence

In `<settings pass="oobeSystem">` → `<component name="Microsoft-Windows-Shell-Setup" ...>`, replace the existing `<OOBE>` element with:

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

`SkipMachineOOBE` and `SkipUserOOBE` are deprecated by Microsoft but still honored on Windows 11; leave them in as belt-and-suspenders.

`AutoLogon` (already configured with `LogonCount=1`, local password, account `Tom`) needs no change — it takes over once OOBE is silenced.

## 3. Extend `Specialize.ps1` $scripts array

Append these script blocks to the `$scripts = @(...)` list in the `Specialize.ps1` file embedded in the XML's `<Extensions>` section. They implement the dual-boot prep items from decisions.md §Q9.

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

Note on user intent ("use the Netac for anything that doesn't hurt daily performance"): the Netac's 128 GB is fully allocated in decisions.md §Q9 (1.5 GB recovery + 16 GB swap + ~110 GB `/var/log`+`/var/cache`). There is no room for Windows pagefile/temp without cutting into the Linux allocation. Per the user's fallback rule ("benefit Linux most"), we leave Netac Linux-only and do not relocate Windows data onto it.

## 4. Prerequisites checklist (manual, before USB boot)

- [ ] BIOS: SATA controller mode **AHCI** (was RAID — decisions.md §Q9).
- [ ] BIOS: Secure Boot stays **ON**.
- [ ] Back up anything on either drive — the preflight is safe but the install pass is destructive on the selected disk.
- [ ] Netac physically connected (so the preflight log records both disks and future Arch installer can see the Netac). Netac is never the detection target, so connection is fine.

## 5. Post-install sanity checks

After Windows lands on the desktop as `Tom`:

- `Get-Partition` in PowerShell — confirm EFI 512 MB, MSR 16 MB, NTFS 160 GiB, and trailing unallocated ~316 GiB on the Samsung. Netac untouched.
- `powercfg /a` — "Hibernation has not been enabled" in output.
- `fsutil behavior query disableLastAccess` — value 1 (already set by the stock Schneegans script).
