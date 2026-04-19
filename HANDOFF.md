# HANDOFF — copy fixed install.sh to USB, hand it back to the user

**First thing to do: delete this file after reading**, *before* starting the fix so you don't accidentally commit alongside it:

```powershell
git rm HANDOFF.md
git commit -m "handoff: dev pc session updated install.sh on USB, removing handoff"
git push
```

---

## Context

The user is sitting at the Dell 7786 with a booted Arch live ISO; they're stopped at runbook step 2c. Two things failed on the laptop:

1. The manual dm-linear recipe (and `install.sh`'s section 0.5) both targeted `/dev/sdb1` with offset 0 → `device-mapper: create ioctl on sdb1 failed: Device or resource busy`. archiso's probe hooks hold the kernel-synthesised partition node open, so you have to build the passthrough against the parent disk at partition 1's sector offset instead.
2. Falling back to `git clone`: Arch live ISO doesn't ship git, `zsh: command not found`.

Commit **`d170d47`** on this branch (`claude/fix-linux-boot-issue-9ps2s`) fixes `install.sh` to use `partx -g -o START,SECTORS` on `/dev/sdX` and target `dmsetup create` against the parent disk. The USB hasn't been re-staged since that commit, so it still carries the buggy script.

The user walked over instead of typing PATs on a live-ISO keyboard. Get the fixed `install.sh` onto stick **F:** (SanDisk Cruzer U, 7.5 GB, Arch-only) and hand it back.

## What to do

1. **Confirm branch state.** Should already be on `claude/fix-linux-boot-issue-9ps2s` with `d170d47` present:
   ```powershell
   git status
   git log --oneline -1
   git pull origin claude/fix-linux-boot-issue-9ps2s   # in case something newer landed
   ```

2. **Confirm the USB is stick F:, not E:.** The earlier handoff flagged stick E (Cruzer Glide 29 GB) as I/O-suspect after a kernel wedge during the Win11 ISO write — only use it if F: is dead. Sanity check:
   ```powershell
   Get-Volume -DriveLetter F | Format-List FileSystemLabel, Size, SizeRemaining
   ```
   FileSystemLabel should be `Ventoy`, Size ~7.5 GB.

3. **Copy just the one fixed file** — minimal, targeted. Avoids any chance of `pnpm stage` trying to pull the Win11 ISO back onto F: (F: is intentionally Arch-only and a 5 GB ISO would crowd it):
   ```powershell
   Copy-Item phase-2-arch-install\install.sh F:\phase-2-arch-install\install.sh -Force
   ```

4. **Verify the fix landed on the stick.** Look for the new `PART_START=$(partx` line that's only in the fixed version:
   ```powershell
   Select-String -Path F:\phase-2-arch-install\install.sh -Pattern 'PART_START=\$\(partx'
   ```
   Should print a match on a line around 130. If it doesn't, the copy didn't happen — do not hand the stick back.

5. **Flush + safely eject.** Write caches before the user yanks it:
   ```powershell
   Write-VolumeCache -DriveLetter F
   ```
   Then right-click the USB icon in the taskbar → Eject, or use the Settings app.

6. **Delete this handoff** (per the top of the file) and push.

## Success criteria

- `Select-String` in step 4 prints a match.
- `git push` succeeds.
- Stick is ejected cleanly.

## Not needed

- **Don't run `pnpm stage`.** It would re-copy the Win11 ISO onto F: (if the dev PC still has it in `assets/`), which isn't useful — Windows is already installed on the 7786 — and could crowd the stick.
- **Don't re-download the Arch ISO.** SHA256 has been proven four-way clean; the boot failure is upstream of and unrelated to ISO contents.
- **Don't touch stick E:.** I/O-faulty per the earlier handoff — kernel wedged for 24+ min during a sustained-write workload on it.

## What the user will do next on the 7786

Re-run `bash /run/ventoy/phase-2-arch-install/install.sh` off the USB (after doing a fresh dm-linear mount — the fixed install.sh now handles that correctly). Password prompts → pacstrap → chroot → reboot into Arch.
