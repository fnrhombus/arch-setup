# Secure Boot enablement — zero-prompt plan

**Status:** plan. Not yet executed. Supersedes the "one-prompt" sequence in
[runbook/phase-3-handoff.md](../runbook/phase-3-handoff.md) §"Upgrade Paths"
and [docs/decisions.md](decisions.md) §C "Enabling SB later".

**Goal.** Enable Secure Boot **without surfacing the LUKS recovery prompt**.
Zero prompts in the happy path. The single allowed prompt is the worst-case
fallback at the SB-on transition if the plan goes off the rails. Anything
more is a plan failure.

## Why this is non-trivial

The TPM2 keyslot on `cryptroot` is currently bound to the policy
`signed-PCR-11 + PCR 7` (install.sh §5b — confirmed by absence of the
`/var/lib/tpm-luks-stage2` sentinel). PCR 7 changes on every step of a
typical SB-enablement dance:

| Step | What changes in NVRAM | PCR 7 effect |
|---|---|---|
| Clear PK in firmware (enter Setup Mode) | `PK` → empty; `KEK`, `db`, `dbx` may be wiped depending on firmware | Differs from current value |
| `sbctl enroll-keys` from OS | `PK`, `KEK`, `db`, `dbx` rewritten to user (+ MS) keys | Differs again |
| Toggle `SecureBoot` to `Enabled` in firmware | `SecureBoot` var flips; per-image verification entries start being measured | Differs again, plus per-boot-image verification authorities now in the chain |

A naive sequence — sign binaries, clear keys, enroll, enable SB — produces
**three or four** boots with a different PCR 7. Each one fails the TPM
unseal predicate and surfaces the LUKS passphrase prompt. The conservative
plan currently in `phase-3-handoff.md` collapses this to one prompt by
*expecting* the failure at the final SB-on boot and leaving everything else
to chance — but that "everything else" includes the boot after enrolling
keys with SB still off, which on this hardware will absolutely measure the
new `db`/`KEK`/`PK` into PCR 7 and prompt.

The fix: **drop the PCR 7 binding from the seal for the duration of the
dance**, leave only signed-PCR-11. Re-add PCR 7 once the new SB-on PCR 7
value is the one we want to bind.

## Why dropping PCR 7 temporarily is safe

The threat model **does not regress** during the unbound window. With
signed-PCR-11 alone the seal still requires:

- The running PE binary to be a UKI we built and signed with
  `/etc/systemd/tpm2-pcr-private.pem`, AND
- The unseal request to arrive before `systemd-pcrphase leave-initrd`
  extends the next constant into PCR 11 (the BitLocker-style temporal
  scope holds; see [tpm-luks-bitlocker-parity.md](tpm-luks-bitlocker-parity.md) §"Temporal scope").

The PCR 11 signing private key lives on the LUKS-encrypted root. An
attacker who can swap firmware NVRAM keys still has nothing to sign with;
the chicken-and-egg property from the threat-model table holds during the
window exactly as it does outside it. The only thing the unbound window
gives up is the *user-visible* signal "someone toggled SB on you" — which
we are intentionally suppressing here, because *we* are the one doing the
toggling.

The window is on the order of ~10–30 minutes wall clock and bounded by
this plan, not open-ended.

## Hardware/firmware state on this machine (probed 2026-05-01)

- Firmware: AMI BIOS 5.13 (not Insyde — Dell ships AMI Aptio on the 7786).
- Secure Boot: disabled, Vendor Keys = `microsoft builtin-db builtin-KEK builtin-PK` (factory state).
- Setup Mode: disabled (factory PK is in place; will need to be cleared from firmware UI).
- TPM2 PCR banks: **SHA-1 only allocated** for PCR 0–23. SHA-256 bank empty.
  - This means the install-time enrollment uses **SHA-1 PCR 7** + **SHA-1 signed PCR 11**.
  - `/etc/kernel/uki.conf` carries `PCRBanks=sha256 sha1` — the SHA-1 prediction in `.pcrsig` is what unseals on this TPM.
  - No action needed; just be aware that all PCR references below mean SHA-1.
- Current PCR values (sha1):
  - PCR 7 = `0x723B6906BEDA07473AD2CEBAF65F6CEB894C680F` (SB-off, factory keys)
  - PCR 11 = `0x1320CFD8FC74B1CF6942D653110DDA8BB02A98E4` (post-`enter-initrd`)
- ESP boot path: NVRAM `BootCurrent=0003` chains to `\EFI\Boot\BootX64.efi` (the limine fallback path). There is **no dedicated `limine` NVRAM entry** — only the ESP fallback gets used at boot.
- EFI binaries on disk (all currently unsigned — `sbverify --list` reports no signature table):
  - `/boot/EFI/BOOT/BOOTX64.EFI` (340 KiB, the fallback path firmware actually loads)
  - `/boot/EFI/Linux/arch-linux.efi` (152 MiB UKI)
  - `/boot/EFI/Linux/arch-linux-lts.efi` (151 MiB UKI)
  - `/usr/share/limine/BOOTX64.EFI` (340 KiB, source for `limine-redeploy.hook`)
- Pacman hooks installed: `95-limine-redeploy.hook`, `95-tpm2-reseal.hook`. Both already SB-aware (no-op when sbctl isn't enrolled; resign + reseal on upgrade once it is).
- `sbctl` package: installed (`/usr/bin/sbctl` present); no keys created yet (`Installed: ✗`).

## Pre-flight checklist

Run these as `tom` (with `sudo` where shown). All must hold before starting
the dance.

```sh
# 1. Confirm TPM2 device + tpm2_pcrread bank state.
ls /dev/tpm0 /dev/tpmrm0
tpm2_getcap pcrs            # Expect: sha1 allocated, sha256 empty (this machine).

# 2. Confirm signing keypair + UKIs + hooks are in place.
ls -l /etc/systemd/tpm2-pcr-{private,public}.pem
ls -l /boot/EFI/Linux/arch-linux{,-lts}.efi
ls -l /etc/pacman.d/hooks/95-{limine-redeploy,tpm2-reseal}.hook
ls -l /usr/local/sbin/tpm2-reseal-luks

# 3. Confirm cryptroot has a TPM2 keyslot bound to the policy we expect.
sudo cryptsetup luksDump /dev/disk/by-partlabel/ArchRoot | grep -E '^Keyslot|tpm2|tpm-pcrs|pubkey-pcrs'
#   Expect: a tpm2 token with tpm2-pubkey-pcrs=11 and tpm2-pcrs=7.

# 4. sbctl present, no keys yet, firmware says SB off.
command -v sbctl
sudo sbctl status            # Expect: Installed ✗, Setup Mode ✗ (disabled), Secure Boot ✗.
bootctl status | grep -iE 'secure|setup|firmware'

# 5. The 48-digit LUKS recovery key from install time is physically on hand
#    (the photo from the install banner, AND/OR the Bitwarden vault entry).
#    Do NOT proceed without it. The dance is engineered to be silent, but
#    "engineered" is not "guaranteed" — anything fails, the recovery key is
#    the only way back in.
#
#    NB: this dance does NOT rotate the LUKS recovery key. The string in
#    your install photo stays valid forever. See "What about the LUKS
#    recovery key?" below for the full picture of what changes vs. what
#    doesn't.
```

If any of those fail, **stop and triage**. Do not proceed.

## The dance

### Phase A — sign binaries and drop PCR 7 (in OS, SB still off)

All silent. No reboots between these steps.

```sh
# A.1  Generate sbctl's user keys (PK/KEK/db/dbx). Local-only file ops.
sudo sbctl create-keys

# A.2  Sign all four PE binaries we'll boot. -s registers them in sbctl's
#      tracked-files DB so its pacman hook will keep them signed across
#      kernel + limine upgrades.
for f in \
    /boot/EFI/BOOT/BOOTX64.EFI \
    /usr/share/limine/BOOTX64.EFI \
    /boot/EFI/Linux/arch-linux.efi \
    /boot/EFI/Linux/arch-linux-lts.efi
do
    sudo sbctl sign -s "$f"
done

# A.3  Verify all four PE binaries are signed and validate against the keys
#      sbctl will enroll. (sbctl verify exits non-zero on any unsigned file.)
sudo sbctl verify

# A.4  DROP PCR 7 from the seal. Re-enroll TPM2 keyslot with signed-PCR-11
#      ONLY. Silent — systemd-cryptenroll uses the in-memory dm-crypt master
#      key to authenticate the LUKS header modification, no passphrase
#      required.
sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/ArchRoot
sudo systemd-cryptenroll --tpm2-device=auto \
    --tpm2-public-key=/etc/systemd/tpm2-pcr-public.pem \
    --tpm2-public-key-pcrs=11 \
    /dev/disk/by-partlabel/ArchRoot
#      No --tpm2-pcrs=7 — that's the whole point of this step.

# A.5  Sanity reboot. Boot must be silent. If it prompts, STOP — the
#      signed-PCR-11 policy isn't validating; do not proceed to firmware.
sudo reboot
```

After A.5: log back in. Confirm `bootctl status` still says SB disabled and
PCR 7 is unchanged from before. Then proceed.

### Phase B — clear PK in firmware (one firmware visit)

**Reboot to firmware (F2 at POST).** AMI Aptio 5.13 menus on the Inspiron
7786 typically expose this under one of:

- **Boot → Secure Boot → Secure Boot Mode → Custom → Custom Secure Boot Options → "Delete all Secure Boot variables"** (or "Reset to Setup Mode"), or
- **System Configuration → Secure Boot → Erase Secure Boot Keys / Reset Keys to Factory Defaults → Erase**.

Look for the verb **"erase"**, **"delete"**, or **"clear"** applied to **PK**
or to "Secure Boot keys". The firmware will prompt to confirm. Choose the
option that **clears PK** (puts firmware in Setup Mode) — *not* the option
that "restores factory defaults" (which would re-write Dell's factory PK
and put you back where you started).

Leave **Secure Boot itself disabled** for now. Do not enable it in this
firmware visit.

Save & exit (F10).

**Boot back to OS.** This boot will be silent — PCR 7 changed (PK gone), but
the seal is signed-PCR-11-only.

```sh
# B.1  Confirm firmware is now in Setup Mode.
sudo sbctl status            # Expect: Setup Mode ✓ Enabled, Secure Boot ✗.
```

If Setup Mode is still ✗, the firmware menu didn't take. Repeat the
firmware visit, or look for a different sub-menu. Do **not** run
`sbctl enroll-keys` until Setup Mode is confirmed Enabled — the call will
just fail.

### Phase C — enroll keys, then enable SB (in OS, then second firmware visit)

```sh
# C.1  Enroll our keys. -m includes Microsoft's KEK + UEFI CA in db.
#      Why -m on this hardware: Inspiron 7786 has a discrete NVIDIA MX250
#      whose OPROM is Microsoft-signed. AMI 5.13 may halt at POST if SB is
#      on and an OPROM fails signature validation. Including MS db is the
#      conservative choice for a single-OS install where we don't otherwise
#      care; remove the -m later (re-running enroll-keys) if we ever decide
#      to take full ownership of the trust root.
sudo sbctl enroll-keys -m

# C.2  Re-verify. enroll-keys can sometimes invalidate older signatures
#      on disk (it shouldn't, but: paranoia is cheap here).
sudo sbctl verify
#      If anything is "not signed", re-run `sbctl sign -s <file>` for it.
```

**Reboot to firmware (F2).**

**Enable Secure Boot.** Same menu as Phase B; the option will now read
"Secure Boot: Disabled → Enabled". Save & exit.

**Boot back to OS.** This boot will also be silent: SB is on, our keys
validate the limine fallback PE and the chained UKI, PCR 7 is *different
again* but the seal is still signed-PCR-11-only.

```sh
# C.3  Confirm SB is on with our keys.
sudo sbctl status            # Expect: Setup Mode ✗ Disabled, Secure Boot ✓ Enabled.
bootctl status | grep -iE 'secure|firmware'
```

### Phase D — re-add PCR 7 to the seal (in OS)

```sh
# D.1  Re-enroll TPM2 keyslot with the FULL policy (signed-PCR-11 + the
#      now-stable SB-on PCR 7). Silent — same in-memory dm-crypt master-key
#      authentication as step A.4.
sudo /usr/local/sbin/tpm2-reseal-luks

# D.2  Confirm the LUKS header now shows the right policy.
sudo cryptsetup luksDump /dev/disk/by-partlabel/ArchRoot | grep -E 'tpm2-pcrs|tpm2-pubkey-pcrs'
#      Expect: tpm2-pubkey-pcrs=11, tpm2-pcrs=7.

# D.3  Final verification reboot. Must be silent.
sudo reboot
```

After D.3: log back in. The dance is complete.

```sh
# D.4  Final verification — all four signals green.
sudo sbctl status            # Setup Mode ✗, Secure Boot ✓
sudo sbctl verify            # all four files Signed
sudo cryptsetup luksDump /dev/disk/by-partlabel/ArchRoot | grep -E '^Keyslots|^\s+[0-9]+:|tpm2'
journalctl -b 0 | grep -iE 'tpm2|cryptsetup|signed-pcr|policy'
#      Expect to see systemd-cryptsetup unsealing via the signed-PCR-11
#      policy with no fallback to passphrase prompts.
```

## Failure paths and recovery

The plan is engineered for zero prompts. If you hit one anyway:

| When you see the prompt | What it means | Recovery |
|---|---|---|
| **After A.5** (sanity reboot, before any firmware change) | The signed-PCR-11 policy isn't unsealing — most likely the SHA-1 vs SHA-256 banks are mismatched, or `--tpm2-public-key-pcrs=11` was misspecified. | Type the recovery key, log in, run `sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/ArchRoot && sudo /usr/local/sbin/tpm2-reseal-luks` to revert to the original signed-PCR-11+PCR-7 binding. Triage before re-attempting. |
| **After Phase B reboot** (Setup Mode entered) | Same as above — signed-PCR-11 isn't validating. Less likely if A.5 was silent. | Same recovery as above. The PK is gone, so SB will refuse to enable until you `sbctl enroll-keys`; you can defer that until you've debugged. |
| **After Phase C reboot** (SB enabled) | Either: (a) signed-PCR-11 isn't unsealing, or (b) firmware refused to load limine because signature validation failed. (b) puts you at a black screen *before* the LUKS prompt — you'd never see a passphrase prompt in (b); you'd see a firmware error or boot loop. | For (a): recovery key + retry. For (b): boot back to firmware, **disable Secure Boot** (without clearing keys), boot back to OS, run `sudo sbctl verify` and re-sign anything that's stale, then retry. |
| **After D.3** (final verification) | The newly-bound PCR 7 doesn't match what unseal predicts. Means PCR 7 was still drifting when you ran `tpm2-reseal-luks` — e.g., a pacman upgrade fired a UKI rebuild between Phase C and Phase D and rewrote the `.pcrsig` section. | Recovery key, log in, re-run `sudo /usr/local/sbin/tpm2-reseal-luks`. |

The 48-digit recovery key always works regardless. If the dance goes
sideways and you can't recover the TPM, the system is still unlockable;
re-running the dance from a known-good post-recovery-key state is fine.

**Do not run `pacman -Syu` during the dance.** A kernel/mkinitcpio/systemd
upgrade in the middle would rebuild the UKI (rewriting `.pcrsig`) and fire
the reseal hook (which always uses `--tpm2-pcrs=7`). Both effects can wedge
you mid-dance. Schedule a clean window. If a kernel upgrade is overdue,
do it *before* starting Phase A.

## What about the LUKS recovery key?

It does not change. The 48-digit string from the install banner is still
valid after the dance, will still unlock the disk if anything goes wrong,
and is still the right thing to keep photographed + in Bitwarden. **No new
picture needed.** Quick rundown of what each piece of key material does
during this dance:

| Material | Where it lives | What this dance does to it |
|---|---|---|
| LUKS recovery passphrase (slot 0, the 48-digit BitLocker-style string) | LUKS header on `ArchRoot`; user's photo + Bitwarden | Untouched. `systemd-cryptenroll --wipe-slot=tpm2` only ever touches slot 1. |
| LUKS TPM2 keyslot (slot 1, machine-wrapped, no string form) | LUKS header on `ArchRoot` | Wiped + re-created in step A.4 and again in D.1. Not user-visible; nothing to write down. |
| TPM PCR-11 signing keypair | `/etc/systemd/tpm2-pcr-{private,public}.pem` (mode 600 / 644) on LUKS root | Untouched. Same keypair install.sh §5a generated; signed every UKI you've ever booted. |
| sbctl Secure Boot keys (PK / KEK / db / dbx) | `/var/lib/sbctl/keys/` on LUKS root | **Generated in step A.1** (new this dance). Protected at rest by LUKS. Backed up automatically by sbctl. Never need to be photographed; if lost, re-run Phase A + C. |
| Microsoft KEK + UEFI-CA db | enrolled into firmware NVRAM by `sbctl enroll-keys -m` | Public material; can be re-fetched any time. Nothing to back up. |

The only "key change" you might notice from outside the system is that
firmware NVRAM now carries our PK + KEK + db instead of Dell's factory
defaults. That's exactly the point — it's not a credential rotation, it's
a trust-root replacement.

## What changes in the repo

This plan is **execution-only**. No script changes are required:

- `tpm2-reseal-luks` already does the right thing for Phase D (always
  re-enrolls signed-PCR-11 + PCR 7).
- `sbctl` is already installed.
- The pacman hooks are already SB-aware and will keep things signed +
  resealed across upgrades from Phase D onward.

The "drop PCR 7" step (A.4) is the one operation that has no ergonomic
helper script. If we ever automate this dance end-to-end, the only piece
worth abstracting is a `tpm2-reseal-luks --no-pcr7` mode (env var or
flag) that the dance script can call once at the start and never again.
Not worth doing speculatively for a one-shot procedure.

## Cross-doc cleanup

Once this plan has been executed and verified silent, update:

- `runbook/phase-3-handoff.md` "Upgrade Paths" → "Secure Boot via sbctl":
  replace the "first boot will prompt for the LUKS recovery key" sequence
  with a pointer to this doc.
- `docs/decisions.md` §C "Enabling SB later": same.
- `docs/tpm-luks-bitlocker-parity.md` §Recovery, item 4 "SB enablement":
  same.

The "one-prompt" sequence those docs describe is correct as a *fallback*
(it works, you just eat one prompt) — but the zero-prompt plan in this doc
is the canonical procedure.

## Open commitments (resolve before the fresh reinstall)

These were agreed in conversation on 2026-05-01 and aren't yet reflected
in the scripts or the doc body. Pick them up after running the test on
the current system, before kicking off the fresh reinstall.

1. **Capture the AMI 5.13 menu path on the Inspiron 7786** for clearing
   PK / entering Setup Mode. The Phase B body currently lists best-guess
   verbiage ("Boot → Secure Boot → Custom → Custom Secure Boot Options
   → Delete all Secure Boot variables", or under "System Configuration").
   After the test reveals the real menu, replace the speculation with the
   actual path so the next Claude session coaching this on the fresh
   install has ground truth.

2. **Fold the cost-free OS-side prep into the install scripts.** Add to
   `phase-3-arch-postinstall/postinstall.sh` (or `phase-2-arch-install/chroot.sh`,
   wherever fits the existing structure better):

   ```sh
   # Idempotent — no-op once keys exist.
   sbctl create-keys

   # Idempotent — no-op once each file is signed and tracked.
   for f in /boot/EFI/BOOT/BOOTX64.EFI \
            /usr/share/limine/BOOTX64.EFI \
            /boot/EFI/Linux/arch-linux.efi \
            /boot/EFI/Linux/arch-linux-lts.efi
   do
       sbctl sign -s "$f"
   done
   ```

   Both are no-ops with SB off (firmware doesn't validate). Both shrink
   the post-install dance to: "drop PCR 7, firmware visit 1, enroll-keys,
   firmware visit 2, reseal" — five steps instead of seven, and the only
   sbctl call left in the dance is `enroll-keys -m`.

   The PCR-7 wiggle (A.4 / D.1) stays manual — it's the one piece that
   has to be coordinated with the firmware visits, and `postinstall.sh`
   has no way to know whether you're about to enable SB or not.

3. **Optional, not committed:** consider whether `tpm2-reseal-luks`
   should grow a `--no-pcr7` flag (or `RESEAL_DROP_PCR7=1` env var) so
   step A.4 becomes one helper call instead of two `systemd-cryptenroll`
   invocations. Not worth doing speculatively, but if the dance ever
   gets run a third time, the cost/benefit might tip.
