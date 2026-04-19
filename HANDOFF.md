# HANDOFF — stick is updated; run the fixed install.sh on the 7786

**First thing to do: delete this file after reading**, *before* starting the next step so you don't accidentally commit alongside it:

```bash
git rm HANDOFF.md
git commit -m "handoff: 7786 session picked up updated stick, removing handoff"
git push
```

---

## Context

The Dell 7786 is mid-Phase-2 (Arch bare-metal install) off the booted Arch live ISO. Last session on the 7786 discovered two bugs and pushed a fix for one:

1. **Fixed and on the stick now.** `phase-2-arch-install/install.sh`'s section 0.5 was doing `dmsetup create ... /dev/sdb1 offset=0` which hit `device-mapper: create ioctl on sdb1 failed: Device or resource busy` — archiso's probe hooks hold the kernel-synthesised partition node open. Commit **`d170d47`** rewrote section 0.5 to build the passthrough against the parent `/dev/sdX` at partition 1's sector offset via `partx -g -o START,SECTORS`. The dev PC just landed that fix onto stick **F:** and verified it with SHA256 + a `Select-String` for `PART_START=$(partx` at line 136.

2. **Still unresolved (doesn't block Phase 2).** Arch live ISO ships without `git`, so the "fall back to `git clone` over a PAT" escape hatch doesn't exist on the laptop. Not relevant now that the stick is updated — but if you somehow need repo changes into archiso later, `pacman -Sy git` in the live ISO works.

## Stick state

- **F:\ (SanDisk Cruzer U, 7.5 GB, Arch-only)** — contains the fixed `install.sh`. Cache is flushed and the drive should already be unplugged from the dev PC. Plug into the 7786.
- **E:\ (SanDisk Cruzer Glide, 29 GB)** — don't touch; still the I/O-flaky one from two sessions ago (kernel wedged on 8 GB Win11 write). Not needed here anyway.

## What to do on the 7786

1. **Plug F: into a USB-A port on the 7786** (preferably the same port the user has been using; switching ports is a variable to change only if something else breaks).
2. **Mount the Ventoy data partition.** The new `install.sh` does this for you in section 0.5 — you just run the script. But if you need to mount it manually first for any reason, the recipe (from commit `d170d47`) is roughly:
   ```bash
   DISK=$(lsblk -ndo NAME,TRAN | awk '$2=="usb"{print $1; exit}')   # sdb, sdc, ...
   PART_START=$(partx -g -o START "/dev/$DISK" | head -n1 | awk '{print $1}')
   PART_SIZE=$(partx -g -o SECTORS "/dev/$DISK" | head -n1 | awk '{print $1}')
   echo "0 $PART_SIZE linear /dev/$DISK $PART_START" | dmsetup create ventoy-data
   mkdir -p /run/ventoy
   mount -o ro /dev/mapper/ventoy-data /run/ventoy
   ```
3. **Run the installer:**
   ```bash
   bash /run/ventoy/phase-2-arch-install/install.sh
   ```
   One password prompt at the top (root + `tom`, hashed via `openssl passwd -6` → handed to chroot via a mode-600 file). Then pacstrap runs, `chroot.sh` runs, and it finishes.
4. **Reboot.** You should land in systemd-boot → pick Arch → log in as `tom`.
5. **Phase 3.** Run `~/postinstall.sh` for the user-side setup (yay, AUR packages, zgenom, chezmoi, fprintd, etc.).

## Success criteria

- `install.sh` reaches "install complete" without any `dmsetup`/`mount` errors.
- Reboot lands in Arch.
- `tom` login works; `~/postinstall.sh` exists and is executable.

## If it fails

- **dm-linear / mount error again** — then the fix didn't land on the stick despite our SHA256 verify. Very unlikely. Cross-check by `grep 'PART_START=' /run/ventoy/phase-2-arch-install/install.sh` on the laptop — should print a line around 136.
- **Loop0 / archiso boot error** — see the `runbook/INSTALL-RUNBOOK.md` §2a troubleshooting block and the memory note "Dell 7786 loop0/ext4 boot failure is NOT a corrupt ISO". SHA256 has been proven four-way clean; don't re-download.
- **pacstrap fails partway** — network or mirror flake. `ip link show` + `iwctl` to (re)connect; retry `install.sh` (it handles idempotency for partition creation).

## What NOT to do

- **Don't re-download the Arch ISO.** SHA256 is four-way verified clean.
- **Don't run `pnpm stage` or `pnpm restore:force`.** F: is intentionally Arch-only; those scripts would pull the Win11 ISO onto it and may crowd the 7.5 GB stick. The dev PC already staged everything you need.
- **Don't touch stick E:.** I/O-faulty per earlier session.
- **Don't assume branch is `main`.** You're on `claude/fix-linux-boot-issue-9ps2s`.
- **Don't use `Set-Disk -IsOffline` to "eject" USB sticks on Windows** — it persists across replug and leaves the stick dead on next insert. `Write-VolumeCache` + physical unplug is correct for USB.
