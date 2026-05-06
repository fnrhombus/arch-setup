# LUKS TPM2 BitLocker Parity — Design Notes

## The promise

Cold boot prompts for nothing. The user types a password once, at the greeter, after the disk has already silently unsealed itself against an intact boot chain. The 48-digit LUKS recovery key only ever surfaces under the same conditions BitLocker would surface its own: Secure Boot toggled, firmware updated, TPM cleared, boot chain tampered with, drive transplanted. That is the bar. Anything that prompts on a normal `pacman -Syu` reboot has missed it.

## Three attempts

**Passphrase-only** was the obvious starting point and the obvious failure: it works, but every cold boot puts a prompt in front of the user. It defeats the parity goal entirely — BitLocker is silent, so we have to be silent.

**`--tpm2-pcrs=0+7` enrolled from the live ISO** was the second swing. Cleaner: the TPM unseals when PCR 0 (firmware) and PCR 7 (Secure Boot policy) match, the user types nothing on a normal boot. In practice the PCR values measured under the live ISO did not match the PCR values measured at first boot of the installed system — the firmware blob shifts between EFI app contexts in ways that are not predictable from the live environment. The user got a passphrase prompt anyway. (Hence postinstall §7.5 historically deferring the enroll until inside the installed system, where measured values are stable.) That deferral works, but the design is fragile: any boot-chain change rebroadcasts the prompt, and there is no signature anchor to re-bind to.

**This design** seals against a *policy* rather than against specific PCR values. The policy says "the running UKI carries a signature, valid against this public key, over a PCR 11 prediction that the kernel will measure into PCR 11 during early boot". The unseal succeeds whenever a UKI we built and signed is running. PCR drift between firmware versions is no longer fatal — only signing key compromise or post-`leave-initrd` unseal attempts are.

## Trust anchor shift

The TPM moves from a fingerprint check on the boot chain to a credential check on a signing key. Before, "is this the same firmware + Secure Boot policy I was sealed against" was the question; now, "is the thing asking to unseal carrying a signature from a key only I (the installed root) hold" is the question. The signing private key lives at `/etc/systemd/tpm2-pcr-private.pem` on the LUKS-encrypted root — it is itself protected by the very LUKS volume it gates.

The unseal credential and the signing credential live in the same trust envelope: the TPM gates LUKS, LUKS gates the private key. Drive transplant defense is handled by the SRK binding (TPM2 keys are wrapped under the storage root key, which is unique to the physical TPM chip), not by the policy — pull the disk and shove it in a different machine and the wrapped key is a brick. Pull the TPM chip itself and you still need to defeat the PIN gate (deferred — see §Q11, but the slot is sized for it).

## Temporal scope (phase locking)

PCR 11 is the systemd-stoked phase register. The UKI measures itself into PCR 11 at firmware exit, then `systemd-pcrphase` extends additional well-known constants into PCR 11 at named transitions — `enter-initrd` when the initrd userspace begins, `leave-initrd` when the real root pivots in, `ready` once the system is up. ukify, called by mkinitcpio at UKI build time, *predicts* the PCR 11 sequence for a chosen set of phase points and signs each prediction. Those signatures land in a `.pcrsig` PE section of the UKI.

`systemd-cryptsetup` requests an unseal at `enter-initrd` (the only phase where we need to unlock the disk). The TPM walks the PCR 11 policy: did the running thing produce a signature, against the registered public key, that matches the *current* PCR 11 value? If yes, unseal. After `systemd-pcrphase leave-initrd` extends the next constant into PCR 11, the prediction set no longer contains a matching signature — no UKI in the world can produce one without the private key. The seal is now uncrackable for the rest of the runtime. This is the same temporal scope BitLocker uses against TPM-only mode: the unseal window is bounded by the boot phase, not by attacker patience.

## Stage-2 PCR 7 binding

Install-time enrollment cannot bind to PCR 7 because PCR 7 is not measurable from the live ISO in a way that matches the installed system — the live ISO boots through its own EFI stub with its own Secure Boot policy measurements. Install-time gets the signed-PCR-11 policy only.

Postinstall §7.5 runs once the installed system is up, measures the real PCR 7, and re-enrolls each TPM2 slot with `--tpm2-pcrs=7` *added* to the existing `--tpm2-public-key-pcrs=11` policy. From then on the unseal predicate is "valid signed PCR 11 prediction AND PCR 7 matches enrolled value". That restores BitLocker semantics around Secure Boot toggling: flip SB on or off and the TPM refuses to unseal until the user types the recovery key and reseals. Without §7.5, SB toggling would be silent — which is a security regression, not a feature. §7.5 drops a sentinel at `/var/lib/tpm-luks-stage2` so the chroot reseal hook knows to include `--tpm2-pcrs=7` on every future reseal.

## Implementation map

- `phase-2-arch-install/install.sh` §5a — generates the RSA-2048 keypair at `/mnt/etc/systemd/tpm2-pcr-{private,public}.pem` (mode 600 / 644) before chroot.
- `phase-2-arch-install/install.sh` §5b — `systemd-cryptenroll --tpm2-public-key=… --tpm2-public-key-pcrs=11` against cryptroot and cryptswap. No specific PCR values bound at install.
- `phase-2-arch-install/chroot.sh` — UKI mode: `mkinitcpio.d/linux.preset` writes UKIs into `/boot/EFI/Linux/arch-{linux,linux-lts}{,-fallback}.efi`. `/etc/kernel/uki.conf` carries `PCRPrivateKey=/etc/systemd/tpm2-pcr-private.pem`, `PCRPublicKey=…public.pem`, `PCRBanks=sha256`, `Phases=enter-initrd`. `/etc/kernel/cmdline` holds the kernel cmdline (no longer in `limine.conf`). `limine.conf` Linux entries use `protocol: efi_chainload` against the UKI paths. The pacman post-upgrade reseal hook re-runs `systemd-cryptenroll` after every kernel update so newly-built UKIs unseal silently.
- `phase-3-arch-postinstall/postinstall.sh` §7.5 — stage-2 PCR 7 binding. Adds PCR 7 to the existing signed-PCR-11 policy, drops the `/var/lib/tpm-luks-stage2` sentinel.

## Threat model

| Scenario | Outcome | Mechanism |
|---|---|---|
| Stolen powered-off | Brick | LUKS at-rest; no TPM unseal without booting an authentic UKI on this exact TPM |
| Stolen suspended (S3) | Recoverable by attacker | Out of scope — RAM holds keys; same as BitLocker TPM-only |
| Drive transplant to another machine | Brick | SRK is per-TPM; wrapped policy key cannot be used elsewhere |
| Evil-maid swaps UKI for unsigned | Recovery key prompt | No `.pcrsig` section → no signature → unseal denied |
| Evil-maid swaps UKI for *signed* (chicken-and-egg) | Brick | Signing key lives on LUKS root which is offline pre-unseal; attacker has nothing to sign with |
| BIOS / firmware update | Recovery key on next boot only | PCR 7 bank changes; user reseals with `tpm2-reseal-luks` |
| Secure Boot toggle | Recovery key on next boot only | Same — PCR 7 changes; intentional |
| TPM clear | Recovery key prompt; full re-enroll required | Wrapped key is gone; postinstall §7.5 re-runs cleanly |
| Kernel update (silent) | Silent boot, no prompt | mkinitcpio rebuilds UKI, ukify re-signs PCR 11 prediction, reseal hook re-binds |
| Private signing key stolen | Catastrophic — attacker can mint UKIs that unseal | Mitigated by LUKS protecting the key at rest; rotation procedure in §Recovery |

## Recovery procedures

**1. Post-firmware-update reseal** (PCR 7 changed; expected once after a Dell BIOS update):

```sh
# Boot, type recovery key at LUKS prompt, log in, then:
sudo /usr/local/sbin/tpm2-reseal-luks
# Reboot — silent unseal again.
```

**2. Post-TPM-clear re-enroll** (rare; user cleared TPM in BIOS, or motherboard swap):

```sh
# Boot from recovery key, log in, then:
sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/ArchRoot
sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/ArchSwap
# Re-run postinstall §7.5 (idempotent; detects missing tpm2 slots and re-enrolls).
sudo bash -c 'cd ~tom && sudo -u tom ./postinstall.sh'   # or cherry-pick the §7.5 block
```

**3. Lost private key** (regenerate, rebuild every UKI, re-enroll):

```sh
# Boot from recovery key, log in.
sudo openssl genrsa -out /etc/systemd/tpm2-pcr-private.pem 2048
sudo openssl rsa -in /etc/systemd/tpm2-pcr-private.pem -pubout \
    -out /etc/systemd/tpm2-pcr-public.pem
sudo chmod 600 /etc/systemd/tpm2-pcr-private.pem
sudo chmod 644 /etc/systemd/tpm2-pcr-public.pem
sudo mkinitcpio -P                                          # rebuild + re-sign all UKIs
sudo /usr/local/sbin/tpm2-reseal-luks                       # re-enroll with new pubkey
# Reboot — silent unseal.
```

**4. SB enablement** (BIOS file-load of pre-staged `.auth` files): see `runbook/phase-3-handoff.md` "Upgrade Paths → Secure Boot via sbctl" — single BIOS trip (Custom Mode → Replace PK + Append KEK + Append db + Secure Boot Enable on), then first boot prompts for the recovery key (PCR 7 changed), `tpm2-reseal-luks` rebinds, silent on the boot after that.

## Why not Option A / Option C

**Option A** = TPM2 sealed against PCR 11 alone (signed) with no PCR 7 binding. Silent across kernel updates and silent across SB toggles. The latter is a security regression — flipping Secure Boot off is exactly the canonical "boot chain tampered" signal we want to gate on. Stage-2 PCR 7 binding (§7.5) costs nothing and recovers it.

**Option C** = sd-boot + shim + signed kernel images, the bog-standard Arch wiki approach. We already chose limine for its first-class snapper-rollback integration (see §Q10A); switching bootloaders here for marginal benefit is wrong. Shim is unnecessary when the user controls firmware (Setup Mode → enroll our own keys via `sbctl`); it exists to ride Microsoft's signature, which we don't need.

## Key material inventory

| Key | Location | Protection | Lifecycle |
|---|---|---|---|
| LUKS recovery key (48 hex digits) | User's photo + Bitwarden | User's responsibility | Generated at install; immutable |
| Sealed cryptroot TPM2 slot | LUKS header on Samsung `ArchRoot` | TPM SRK + signed PCR 11 + PCR 7 | Re-sealed after every kernel update via reseal hook |
| Sealed cryptswap TPM2 slot | LUKS header on Netac `ArchSwap` | TPM SRK + signed PCR 11 + PCR 7 | Same lifecycle as cryptroot |
| PCR signing private key | `/etc/systemd/tpm2-pcr-private.pem` (mode 600, root) on LUKS root | LUKS at rest; root-only at runtime | Generated at install; rotation procedure above |
| PCR signing public key | `/etc/systemd/tpm2-pcr-public.pem` (mode 644) on LUKS root | None needed (public) | Embedded in LUKS metadata at enroll time |
| TPM SRK | TPM chip, non-extractable | Hardware | Reset only by `tpm2_clear` from BIOS |

## Verification checklist

```sh
# TPM2 token visible on each LUKS volume:
sudo systemd-cryptenroll /dev/disk/by-partlabel/ArchRoot
sudo systemd-cryptenroll /dev/disk/by-partlabel/ArchSwap

# UKI carries a .pcrsig PE section (the signed PCR 11 predictions):
objdump -h /boot/EFI/Linux/arch-linux.efi | grep -E '\.pcrsig|\.uname|\.osrel'

# LUKS keyslots populated as expected (slot 0 = passphrase, slot 1 = TPM2):
sudo cryptsetup luksDump /dev/disk/by-partlabel/ArchRoot | grep -E '^Keyslots|^\s+[0-9]+:'

# Stage-2 sentinel present (set by postinstall §7.5):
ls -l /var/lib/tpm-luks-stage2

# The real test: power-cycle, observe silent boot. No LUKS prompt → success.
```
