# Local Claude Code handoff — finish the BitLocker-parity install

You are picking up an Arch + Windows 11 dual-boot install on a Dell Inspiron 7786 ("Metis"). The previous Claude Code session ran on Android and kept getting hit by stream-idle-timeouts on long tool-uses; the user is moving to a local Claude Code session for the rest of the install.

You inherit no shared context — start by reading `CLAUDE.md` for repo-wide rules, then `docs/decisions.md` §Q9 + §Q11 + §A for the partition / encryption / bootloader design.

## Branch + checkout

The install is on **`claude/option-b-uki-tpm-parity`** (PR #14, draft, do NOT merge). Everything below assumes this branch.

```sh
git clone -b claude/option-b-uki-tpm-parity https://github.com/fnrhombus/arch-setup
cd arch-setup
```

If the user already has the repo cloned, `git pull origin claude/option-b-uki-tpm-parity` is enough.

## What this branch contains (don't redo)

The session that produced this branch shipped, in order:

1. **`docs/tpm-luks-bitlocker-parity.md`** — full design doc for the LUKS-TPM seal: signed PCR 11 policy + stage-2 PCR 7 binding, replacing the broken `--tpm2-pcrs=0+7` approach. Read this first if you need the rationale; the implementation in (2)-(4) follows it exactly.
2. **`phase-2-arch-install/install.sh`** §5a + §5b — generates an RSA-2048 keypair at `/mnt/etc/systemd/tpm2-pcr-{private,public}.pem`, enrolls TPM2 against `--tpm2-public-key=... --tpm2-public-key-pcrs=11` for cryptroot + cryptswap.
3. **`phase-2-arch-install/chroot.sh`** — switches mkinitcpio to UKI mode (writes `/boot/EFI/Linux/arch-{linux,linux-lts}.efi`), writes `/etc/kernel/uki.conf` (PCR signing config) + `/etc/kernel/cmdline`, rewrites `/boot/limine.conf` to `protocol: efi_chainload` the UKIs. Updated `/usr/local/sbin/tpm2-reseal-luks` to use signed-policy + read `/var/lib/tpm-luks-stage2` flag for PCR 7 binding.
4. **`phase-3-arch-postinstall/postinstall.sh`** §7.5 — stage-2 PCR 7 binding once the system boots and PCR 7 is stable. Drops `/var/lib/tpm-luks-stage2` so the reseal hook keeps PCR 7 across `pacman -Syu`.
5. **`autounattend.xml`** — bumped EFI partition from 512 MiB to **1 GiB** (UKIs run ~150-250 MB each; 4 of them + sbctl-signed copies wouldn't fit in 512 MiB). `docs/decisions.md` §Q9 + `docs/autounattend-oobe-patch.md` reflect the new size.
6. **`phase-2-arch-install/chroot.sh`** — sets `PRESETS=('default')` to skip fallback-UKI generation. The default linux-lts UKI serves as the regression-safety fallback. Kept just-in-case while we observed the ESP-too-small failure; still useful since 4 UKIs would still be tight on 1 GiB once sbctl-signed copies show up.
7. **`scripts/stage-usb.ps1` → `scripts/stage-ventoy.ps1`** rename (target isn't always a USB stick — Phase 0-alt internal Netac-Ventoy is also a target). Added Win11 ISO sha256 verification on staged copy.
8. **Win11 fetcher rewrite** — Fido is gone. `scripts/fetch-win11-hash.mjs` (Playwright) drives microsoft.com/software-download/windows11 directly, scraping the authoritative SHA-256 + the per-session ISO download URL from the same browser context. Three pnpm modes:
   - `pnpm hash:win11` — print the live MS hash
   - `pnpm hash:win11:update` — overwrite `assets/Win11_*.iso.sha256`
   - `pnpm fetch:win11` — download ISO + verify + write sidecar
   `fetch-assets.ps1` (the `pnpm i` postinstall) calls `pnpm fetch:win11` automatically when the canonical Win11 ISO is missing.

9. **CI disabled** per user directive (`.github/workflows/lint.yml` set to `workflow_dispatch:` only). Don't try to fix CI failures.

## Where the user is, physically (as of handoff)

The user is on the Inspiron 7786, mid-install. Sequence so far:

1. **Phase 1 first attempt** — Win11 installed, 512 MiB ESP. (This is the reason the ESP bump happened.)
2. **Phase 2 first attempt** — install.sh ran, got past pacstrap, **failed at mkinitcpio UKI generation** because the 512 MiB ESP couldn't fit two UKIs. Screenshot in conversation history showed `objcopy: /boot/EFI/Linux/arch-linux.efi.text1: No space left on device`.
3. **`PRESETS=('default')` patch** committed. Tested on hardware again — **failed identically**, even with just the two default UKIs. Concluded the 1 GiB ESP bump in `autounattend.xml` is the only reliable fix.
4. **The user is now in Windows** on the Inspiron, about to repopulate the Ventoy data partition (probably the **Netac-Ventoy** internal install — Phase 0-alt) with the latest branch contents (new `autounattend.xml`, new repo state).
5. **Next steps for them**: reboot into Ventoy → Win11 install (auto-unattend will lay out the new 1 GiB ESP) → reboot into Ventoy → Arch live → `git clone -b claude/option-b-uki-tpm-parity ...` → run `phase-2-arch-install/install.sh` → boot into Arch → run `~/postinstall.sh`.

You may rejoin them at any of those steps.

## What you'll likely be asked

In rough order of likelihood:

- **Diagnose a Phase 2 install.sh failure.** Most plausible: a Playwright/UKI/ukify edge case we haven't seen yet. The user will share a screenshot or error text. Read the immediate context before assuming; the install is multi-stage and a failure at step N can mean a problem at step N-3.
- **First-boot LUKS prompt appears.** This is the bug the whole branch was built to fix. If it happens, the install-time TPM enrollment failed silently — check the install.sh log for "TPM2 enrolled (signed PCR 11)" lines; their absence narrows it to either the `systemd-cryptenroll` invocation or the keypair generation in §5a.
- **postinstall.sh §7.5 stage-2 fails.** Less critical — the install-time stage-1 already gives silent boot. Stage-2 just makes Secure Boot toggle a meaningful event. Common cause: `cryptsetup --test-passphrase --token-only` probe behaving differently on real hardware than our test path expected.
- **A different Windows reinstall hiccup.** The user previously did one already; the autounattend is well-tested except for the new EFI=1 GiB. If diskpart errors, walk through `autounattend-oobe-patch.md`.
- **Tablet-mode work** (`claude/tablet-mode-detection`, PR #10) — also draft, also pending hardware verification. Don't merge into the TPM branch unless the user asks; they're independent feature branches.

## Verify-success checklist

After Phase 2 + Phase 3 succeed, confirm:

```sh
# Both LUKS volumes have a TPM2 token bound to the signed PCR 11 policy:
sudo systemd-cryptenroll /dev/disk/by-partlabel/ArchRoot
sudo systemd-cryptenroll /dev/disk/by-partlabel/ArchSwap
# (Look for `tpm2` lines with `tpm2-pubkey-pcrs=11` and — after postinstall —
#  `pcrs=7` too.)

# UKIs carry the PCR signature + public-key PE sections:
objdump -h /boot/EFI/Linux/arch-linux.efi | grep -E '\.pcrsig|\.pcrpkey'

# The signing keypair lives where ukify expects it, properly permissioned:
ls -la /etc/systemd/tpm2-pcr-{private,public}.pem
# private should be 600 root:root, public 644 root:root.

# Reboot test: silent boot, no LUKS prompt. If a prompt appears, capture
# `journalctl -b -1 -u systemd-cryptsetup@cryptroot` for diagnosis.
```

The verify block in `phase-3-arch-postinstall/postinstall.sh` (~line 1639) runs an automated version of these.

## Don't merge

PR #14 is **draft on purpose**. The user wants to test on hardware before merging. Don't `gh pr ready` or merge. Don't push to `main`.

## Style + working rules

Match the existing repo style — see `CLAUDE.md`'s "Working style" + "Commit discipline" sections. Atomic commits, push on feature completion, never force-push, never skip pre-commit hooks unless the user says so explicitly. Lint CI is disabled but pre-commit (Hyprland binds validator) is still active.

If you spawn a subagent, keep its prompt under ~2k tokens — the previous session learned the hard way that long prompts cause stream-idle-timeouts on web Claude Code. Local Claude Code is more resilient but smaller-is-better is a free win.
