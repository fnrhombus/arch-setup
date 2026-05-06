---
name: TPM2 SHA-256 PCR bank not usable on Inspiron 7786
description: This laptop's TPM reports `sha256: []` in `tpm2_getcap pcrs` (no PCRs allocated to SHA-256, all 24 in SHA-1). systemd-cryptenroll always falls back to SHA-1 with "TPM2 device lacks support for SHA256 PCR bank... falling back to SHA1 bank. This reduces the security level substantially." Confirmed 2026-05-06 as a hardware/firmware limitation — "that message has always been there." Don't try to fix it.
type: project
originSessionId: c7643730-1e04-40e4-858c-463ea02edc91
---
The Dell Inspiron 7786's TPM (2018-era chip) has only the SHA-1 bank populated. `tpm2_pcrallocate` workarounds don't help on this hardware.

**Why:** confirmed by Tom 2026-05-06 — "I think the sha1 thing is a hard limitation of this hardware. That message has always been there."

**How to apply:**
- Don't propose `tpm2_pcrallocate`, `tpm2_clear`, BIOS TPM toggle dances, or other workarounds when you see the SHA-1 fallback warning on this machine.
- The seal will be SHA-1 — accept it; the SB+TPM unseal still works silently.
- `phase-2-arch-install/chroot.sh`'s ukify config already lists `PCRBanks=sha256 sha1` (belt-and-suspenders signing) — leave the sha1 entry; this hardware needs it.
- `phase-2-arch-install/install.sh` §5-prep tries `sha256:all+sha1:all` then falls back to `sha256:all`; on this hardware both fail and it lands in SHA-1. Leave the fallback path — it documents the intent and works on hardware where SHA-256 is available.
- If the laptop is ever replaced with newer hardware, retest — newer TPMs typically have SHA-256 banks active by default.
