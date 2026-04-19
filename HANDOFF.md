# HANDOFF — raw-dd Arch stick ready, boot it and install

**First thing: delete this file after reading**, *before* starting work, so you don't accidentally commit alongside it:

```powershell
git rm HANDOFF.md
git commit -m "handoff: session picked up raw-dd stick, removing handoff"
git push origin claude/fix-linux-boot-issue-9ps2s
```

(This branch — not `main`.)

---

## What just happened on the dev PC

- Prior handoff asked for a Ventoy-bypass attempt: `dd` the Arch ISO onto a raw USB stick.
- Done. The old Ventoy'd SanDisk Cruzer U (7.6 GB, formerly stick F:, had been reformatted to an `ESD-USB` Windows installer layout — so no Ventoy layout was lost) was wiped and raw-written via [scripts/dd-arch-iso.ps1](scripts/dd-arch-iso.ps1) → [assets/archlinux-x86_64.iso](assets/archlinux-x86_64.iso).
- Full 1,536,851,968 bytes written, no errors. Post-write `Get-Partition` showed a single 252 MB partition (expected: Arch isohybrid's EFI/ISO9660 layout is opaque to Windows, so it only surfaces one of the nested partitions).
- Stick is now plugged into the dev PC as disk 2. **User needs to eject cleanly and move it to the 7786.**

## What to do

### 1. Confirm the stick boots on the 7786

1. Plug the raw stick into the 7786 — try a USB-A port first.
2. Power on → mash **F12** → pick the USB entry.
3. There is **no Ventoy menu** anymore. Should go straight into archiso's systemd-boot menu.
4. Pick "Arch Linux install medium (x86_64, UEFI)" → wait for root shell.

### 2. Interpret the result

- **Boots cleanly to a root shell:** Ventoy was contributing to the loop0 corruption. Proceed to step 3.
- **Same `EXT4-fs: Can't find ext4 filesystem` / `loop0` mount failure:** Ventoy was not the culprit. It's hardware on the 7786 (USB controller, RAM path, capacitor/thermal signature — "cold boot after hours off" is the only known workaround). Do NOT retry more modes. Stop and brief the user; a different plan is needed (e.g. replace the motherboard, try a different-chipset USB stick, or install onto an external drive from another machine and transplant it).

### 3. If it booted — install

From the archiso root shell:

```bash
# Network check (should already have Ethernet/Wi-Fi if available)
ping -c 2 archlinux.org

# Git + clone the branch
pacman -Sy --noconfirm git
cd /tmp
git clone -b claude/fix-linux-boot-issue-9ps2s https://github.com/fnrhombus/arch-setup.git
cd arch-setup
./phase-2-arch-install/install-from-clone.sh
```

`install-from-clone.sh` is the USB-free variant the prior session wrote. It auto-detects the Samsung (512 GB) + Netac (128 GB), prompts for root + `tom` passwords once at the top, pacstraps, and invokes `chroot.sh`.

## Repo state

- Branch: **`claude/fix-linux-boot-issue-9ps2s`** (not main).
- New artifact from this session: [scripts/dd-arch-iso.ps1](scripts/dd-arch-iso.ps1) — parameterised raw-write helper, safety-gated on `BusType -eq 'USB'`. Keep it; it's a generic tool useful beyond this one session.
- Previous artifacts relevant here:
  - [phase-2-arch-install/install-from-clone.sh](phase-2-arch-install/install-from-clone.sh) — the USB-free installer variant.
  - [phase-2-arch-install/install.sh](phase-2-arch-install/install.sh) — the Ventoy-path variant, now unused on this branch but retained for future USB-Ventoy installs.

## What NOT to do

- **Don't `pnpm stage`** — would fail or corrupt the raw-dd stick (no Ventoy filesystem to mirror into).
- **Don't re-download the ISO** — SHA256 is proven clean (`f14bf46afbe782d28835aed99bfa2fe447903872cb9f4b21153196d6ed1d48ae`).
- **Don't assume branch is main.**
- **Don't rerun `dd-arch-iso.ps1` on the stick** — it's written correctly. If the 7786 can't read it, that's a 7786 problem, not a write problem.

## Known memories that matter

- "Dell 7786 loop0/ext4 boot failure is NOT a corrupt ISO" (see `~/.claude/projects/C--dev-arch-setup-fnrhombus/memory/project_loop0_boot_failure_not_iso.md`). This handoff is the next chapter of that story.
