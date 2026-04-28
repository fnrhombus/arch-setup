# Phone-Coach Handoff — Metis Reinstall via Netac-Ventoy

**Paste this into a new Claude conversation on your phone before you reboot Metis.** It gives the new session everything it needs to coach you through the install — `runbook/INSTALL-RUNBOOK.md` is the printed reference; this is the chat-shaped, "I'll tell you what I'm seeing" version.

> **Be concise**: the user is reading on a 5-inch screen mid-install. Short instructions, ask "what do you see?" before assuming.

---

## Who the user is

- **Tom** (`fnrhombus`), reinstalling Arch Linux + Windows 11 dual-boot on **Metis** = Dell Inspiron 7786 (17" 2-in-1).
- This is a **clean-slate reinstall** of a system that's been running for months — *not* a first-time install. The user knows the laptop; they just need someone to ride along while it boots through three phases.

## Where in the flow they are

The user is paused right *before* reboot. They've just finished `prep-netac-ventoy.sh` on Metis (script at the repo root). That script:
- Wiped the Netac SSD.
- Installed Ventoy onto the Netac (whole-disk install).
- Populated it with both ISOs (Win11 + Arch), the autounattend.xml, ventoy.json, and the rest of the arch-setup repo.

The Netac is now Metis's **internal** Ventoy boot medium (the laptop's USB ports won't reliably boot Ventoy — that's why we did the Netac trick).

## Three things not otherwise obvious from this doc

1. **The Win11 ProductKey is real, license-genuine, and local-only.** The user replaced the Schneegans placeholder in `autounattend.xml` before running the prep script, then `git update-index --skip-worktree`'d the file so `git status` hides the change. The real key only lives in the autounattend.xml that got rsynced onto the Netac Ventoy partition. **Never suggest** "git pull / git checkout autounattend.xml" or "regenerate the answer file" — you'd replace the real key with the placeholder and the Win11 install would prompt the user to buy a license. Phase 1 activates Windows silently; no key entry required.

2. **The boot medium is the internal Netac, not a USB.** At F12, the entry is usually labeled "Netac SSD …" or "Internal SSD" — whichever is NOT "Windows Boot Manager" and NOT the USB stick that was used to bring the ISOs onto Metis during prep. The USB stick is no longer required and can be removed.

3. **Host-side prep workarounds on the old Linux (gone after reboot, safe to ignore).** Running `prep-netac-ventoy.sh` required `pacman -S gptfdisk exfatprogs parted rsync ventoy-bin` on the running Arch, plus a `/usr/local/bin/mkexfatfs` shim that translates old Ventoy argv to `mkfs.exfat`'s new flags. These are gone after reboot — Phase 1 is Windows, Phase 2 is a fresh Arch live ISO. If the script ever needs to be re-run (re-imaging the Netac from inside a *different* running Arch), the same workarounds need to be re-applied. **Not a concern for this install.**

## What's about to happen (the three phases)

```
REBOOT 1 → F12 → Netac → Ventoy menu → Win11_25H2_English_x64_v2.iso
                                       ↓
                   Phase 1 (Windows install, ~30 min, unattended)
                   - autounattend.xml runs the whole thing
                   - 2 auto-reboots within Phase 1; leave the
                     Netac in-place, Ventoy auto-selects Win11 again
                   - Lands on the Tom desktop, no OOBE prompts
                   - winget runs in background to install apps
                   - BitLocker encrypts C: in background
                   - **Stash the BitLocker recovery key in Bitwarden
                     as "Metis BitLocker recovery"** before doing
                     anything else (it's at C:\Windows\Setup\Scripts\
                     BitLocker-Recovery.txt + same name on the
                     Netac's Ventoy data partition)

REBOOT 2 → F12 → Netac → Ventoy menu → archlinux-x86_64.iso
                                       ↓
                   Phase 2 (Arch install, ~40 min)
                   - At Arch live env shell:
                       git clone https://github.com/fnrhombus/arch-setup /tmp/arch-setup
                       (or use the staged copy at the Ventoy partition)
                       bash /tmp/arch-setup/phase-2-arch-install/install.sh
                   - Script asks for root password + tom password
                   - Then displays a YELLOW BANNER with a 48-char LUKS
                     recovery key. **PHOTOGRAPH THIS NOW.** Type
                     "I HAVE THE KEY" exactly to continue.
                   - pacstrap + chroot + limine + greetd + TPM2 + … (~25 min unattended)
                   - "Done." → reboot

REBOOT 3 → limine boot menu → Arch Linux (default after 3 sec)
                              ↓
                  - Type the LUKS recovery key once (TPM not enrolled yet)
                  - Land at greetd (graphical login), log in as tom
                  - Ctrl+Alt+F2 → TTY → ~/postinstall.sh (~25 min)
                  - First Hyprland session comes up after final reboot

REBOOT 4 → BitLocker re-prompt → enter the BitLocker recovery key
                                   from Bitwarden → re-seal per
                                   runbook §C → silent thereafter
```

## What Claude should do during the call

- **Ask, don't assume.** "What's on screen right now?" is the right opener.
- **Refer them to the printed runbook** for long sections (`runbook/INSTALL-RUNBOOK.md` PDF is on paper; PDF also on the Ventoy data partition under `runbook/INSTALL-RUNBOOK.pdf` if it was rendered before staging — otherwise the .md is there).
- **Photograph reminders**: at LUKS-key display (Phase 2) and BitLocker recovery key file (Phase 1). These are one-shot; if the photo's blurry, it's gone.
- **If Phase 2's install.sh dies**: the cleanup trap unmounts /mnt and closes LUKS for clean retry. Just re-run.
- **If Phase 1's Win11 install pauses with "no unique 500-600 GB disk found"**: an external drive in that size range is plugged in; unplug it, retry.
- **If the Netac's Ventoy menu doesn't show**: confirm Boot Mode = UEFI, Secure Boot = Disabled in BIOS. The Netac's Ventoy entry in F12 is usually labeled by the Netac model name ("Netac SSD …") or "Internal SSD".

## Hardware quick reference

| Component | Detail |
|---|---|
| Machine | Dell Inspiron 7786 (17" 2-in-1) |
| CPU | Intel i7-8565U |
| RAM | 16 GB DDR4-2400 |
| GPU | Intel UHD 620 (NVIDIA MX250 blacklisted — incompatible with Wayland) |
| Storage primary | Samsung SSD 840 PRO **512 GB** — Windows + Arch root live here |
| Storage secondary | Netac SSD **128 GB** — currently Ventoy boot medium; will be wiped + re-imaged as §Q9 layout (recovery + cryptswap + cryptvar) by Phase 2 |
| Wi-Fi | Qualcomm Atheros (works in live ISO) |
| Fingerprint | Goodix 27C6:538C |
| TPM | Intel PTT 2.0 (firmware) |

## Wi-Fi / network

- Wired ethernet via USB-C dock = primary path. Plug in before booting Phase 2 if available.
- Wi-Fi profiles already embedded in autounattend.xml + install.sh: `ATTgs5BwGZ`, `rhombus`, `rhombus_legacy`. All WPA2PSK.
- If neither works in the Arch live env: `iwctl` interactive flow.

## Critical secrets the user needs ready

| Secret | When | Where it'll come from |
|---|---|---|
| BitLocker recovery key | Phase 1, before doing anything else | `C:\Windows\Setup\Scripts\BitLocker-Recovery.txt` — photograph + transcribe to Bitwarden as "Metis BitLocker recovery" |
| LUKS recovery key | Phase 2, after the password prompts | install.sh displays in a yellow banner — photograph + transcribe to Bitwarden as "Metis LUKS recovery" |
| root password | Phase 2 prompt | User types (twice, confirmed) |
| tom password | Phase 2 prompt | User types (twice, confirmed). This is daily-login fallback; PIN + fingerprint will be wired in Phase 3. |
| TPM PIN | Phase 3 | User picks during postinstall §7 (6+ chars). |
| Bitwarden master password | Phase 3, one time | Unlocks the vault at first launch in Hyprland. |

## Useful commands during install (so Claude can suggest them)

```bash
# Phase 2 live env, before install.sh:
ip -brief address                       # confirm ethernet/wifi up
ping -c 2 archlinux.org                 # confirm DNS works
lsblk -o NAME,SIZE,MODEL,LABEL          # confirm both disks visible
reflector --latest 10 --sort rate \
   --protocol https --save /etc/pacman.d/mirrorlist  # speed up pacstrap

# Phase 2 install.sh failure recovery:
umount -R /mnt
swapoff -a
wipefs -a /dev/sda4 /dev/sdb1 /dev/sdb2 /dev/sdb3   # whichever Arch-owned parts exist
# then re-run install.sh

# Phase 3 postinstall.sh failure: re-run, it's idempotent.
SKIP_FPRINT=1 ~/postinstall.sh         # skip fingerprint enroll
SKIP_PIN=1   ~/postinstall.sh          # skip TPM PIN setup
```

## Recovery doors

- **LUKS prompt rejects the key** → see runbook/INSTALL-RUNBOOK.md §M-luks. If photo is misread, hex chars are 0-9 a-f only (no o/l/I confusion possible).
- **BitLocker keeps re-prompting** → runbook §C: `manage-bde -protectors -disable C: -RebootCount 0 → reboot → -enable C:`.
- **Hyprland comes up to a blank screen** (chezmoi didn't apply — usually network was down at postinstall §13) → `Ctrl+Alt+F3` to TTY, connect Wi-Fi via `iwctl`, then `chezmoi init --apply rhombu5/dots`.
- **Nothing boots** → BIOS → Boot Sequence → make sure "Limine Boot Manager" is listed and first.

## Where to look for more depth

If you (Claude on the phone) need more context than this card carries, the user can `ssh` from another device to read these on Metis (after Phase 3 wires sshd):

- `runbook/INSTALL-RUNBOOK.md` — full step-by-step + 14 troubleshooting sections (§A through §N)
- `runbook/SURVIVAL.md` — TTY-only rescue card
- `runbook/GLOSSARY.md` — every non-obvious tool/package
- `runbook/keybinds.md` — Hyprland keybindings cheat sheet
- `docs/decisions.md` — locked design rationale (single source of truth)

## When the user says "we're done"

Help them tick off the post-install one-time actions:
1. `~/setup-azure-ddns.sh` (after `az login` device-code) — Azure DDNS + Let's Encrypt creds.
2. `sudo certbot certonly --authenticator dns-azure -d metis.rhombus.rocks ...` — issue the cert.
3. Bitwarden desktop: log in once, enable "Unlock with system keyring", enable SSH agent.
4. Re-seal BitLocker on Windows side (runbook §C).
5. SSH from Callisto smoke test.

After all five tick: merge `desktop-design` → `main` and delete the branch (intentionally held until verified).
