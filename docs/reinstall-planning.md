# Reinstall planning — desktop layer, Secure Boot, limine, ISO build

Written 2026-04-21 ahead of a clean reinstall of Metis. HyDE on the current
install contaminated `/boot/loader/entries/*` (systemd-boot entries it
shouldn't be authoring) and wrote opinions into `~/.config/` that the user is
unhappy with. Omarchy is already rejected ("too much"). This memo captures
the research that will feed the reinstall decisions. It does **not** yet
modify `docs/decisions.md` — those edits happen once the user has read this
and signed off.

---

## 1. Desktop layer — alternatives to HyDE

### Candidates surveyed

| Name | Category | Upstream | Bootloader lock-in |
|------|----------|----------|--------------------|
| HyDE | Hyprland starter | [HyDE-Project/HyDE](https://github.com/HyDE-Project/HyDE) | none (current baseline) |
| ml4w | Hyprland starter | [mylinuxforwork/dotfiles](https://github.com/mylinuxforwork/dotfiles) | none |
| JaKooLit | Hyprland starter | [JaKooLit/Arch-Hyprland](https://github.com/JaKooLit/Arch-Hyprland) | none |
| Caelestia | Hyprland starter | caelestia-dots/caelestia | none |
| Omarchy | Hyprland starter | basecamp/omarchy | **limine** (hard preflight) |
| niri | scrollable Wayland WM | [niri-wm/niri](https://github.com/niri-wm/niri) | n/a |
| Sway + waybar | tiling Wayland WM | swaywm/sway | n/a |
| KDE Plasma 6 + Polonium | full DE + tiling script | kde.org | n/a |
| GNOME + PaperWM | full DE + tiling ext | paperwm/PaperWM | n/a |
| COSMIC DE | full DE (alpha) | pop-os/cosmic-epoch | n/a |
| Regolith | i3 on Ubuntu/X11 | regolith-desktop | ruled out (X11-only, Ubuntu-first) |

### Scoring

Weighted for this user: opinionated defaults, keyboard-first, **not ricing**,
Wayland on Intel iGPU only, keeps the locked decisions (Ghostty, tmux,
VSCode, Claude Code CLI, Remmina).

**HyDE** — what we have today. Opinionated, Catppuccin-bundled, works. But:
the install script is invasive (clobbers `~/.config/hypr/`, prompts for
shell and can land `tom` in fish, touches `/boot/loader/entries/*` for its
own "boot fallback" flow). Uninstall path exists but leaves dotfile
breadcrumbs. Score: fine, but the user is specifically annoyed with it.

**ml4w** — installs to `~/.mydotfiles` and symlinks into `~/.config/`.
Cleanest uninstall story of the Hyprland starter-kits
([wiki](https://mylinuxforwork.github.io/dotfiles/getting-started/uninstall)):
`ml4w-hyprland-setup -m uninstall` drops the symlinks and restores backed-up
configs. Productivity-biased (sane panel/shortcuts, no theme-switcher
gimmicks). Does NOT touch `/boot`. **Most conservative starter-kit.**

**JaKooLit** — multi-distro installer, theme-picker style. Similar surface
area to HyDE (a lot of stuff) but the distro-agnostic installer is a
negative here (extra layers we don't need on Arch). Active upstream.

**Caelestia** — quickshell-based, heavy, niche. Skip.

**niri** — scrollable tiling, in `extra`, stable, keyboard-first. Radically
different window-management model (horizontal scrolling strip, not tiling).
User hasn't tried it; switching to a paradigm they haven't test-driven is a
poor fit for a user who wants "just works." Not the right first move for
this reinstall.

**Sway + waybar** — stable, low-eye-candy, tiny config surface. Mature
Wayland story. No starter kit that's opinionated enough; user would be
hand-rolling a config, which is exactly the "I'm not trying to make rice"
negative-signal they explicitly called out. Skip.

**KDE Plasma 6 + Polonium** — Plasma 6 is the clear "Just Works" DE on Intel
iGPU + Wayland in 2026. Polonium (
[zeroxoneafour/polonium](https://github.com/zeroxoneafour/polonium))
is a keyboard-driven tiling KWin script, spiritual successor to Bismuth, ~active
upstream. Plasma 6 ships a first-class Wayland session, native HiDPI + mixed
scaling (DP-1 @ 1.5 + eDP-1 @ 1 works out of the box — no `nwg-displays` dance
with X=0 gotchas), and a SDDM + fingerprint integration path that's
battle-tested. Catppuccin theming is a one-package install
(`plasma6-themes-catppuccin` AUR). This is the "what if you ditched Hyprland
entirely" option. The cost: Ghostty's aesthetic, the fuzzel launcher, and
mako lose their reason to exist (Plasma ships krunner + notification
daemon); keeping them is fine but the point of a DE is that the bar and
launcher come with the DE. For a user who likes tiling but doesn't enjoy
config tweaking, Plasma + Polonium hits the sweet spot better than any
Hyprland starter. Wayland-native tablet-mode + auto-rotation (via
`iio-sensor-proxy`, same backend as we already use) is built in — we stop
maintaining `iio-hyprland` AUR + hyprgrass plugin code.

**GNOME + PaperWM** — scrollable-like tiling as a GNOME extension. PaperWM
is fine but GNOME's opinions collide hard with keyboard-first tmux users,
and extensions break across GNOME major versions. Skip.

**COSMIC DE** — still alpha in April 2026. Pop!_OS's long-awaited Wayland
DE; not ready for a primary machine. Revisit in a year.

### Verdict

**Top pick: KDE Plasma 6 + Polonium**. The user said "I'm not trying to make
rice" and "I don't enjoy config tweaking." Plasma 6 is the DE that takes
the most opinions off the user's plate in 2026, has no NVIDIA-Wayland
pitfalls on Intel-only, and its tiling story (Polonium) is a KWin script
the user enables once and never thinks about again. We retire a pile of
AUR glue code (`iio-hyprland-git`, `hyprgrass`, `wvkbd`, `hyprpolkitagent`)
and lean on `kwin_wayland` + `plasma-workspace`'s own tablet-mode and
auto-rotation. Keeps Ghostty as the terminal (not the bar-spawned one),
keeps tmux + Claude Code + VSCode unchanged. Biggest downside: visual
polish is less "wow" than Hyprland — but that was never a user requirement.

**Runner-up: ml4w** if the user wants to stay on Hyprland. Cleanest install
and uninstall footprint of the starter kits. Does not touch `/boot`.
Productivity-oriented defaults, less ricing-flavored than HyDE. If we stay
on Hyprland, we switch from HyDE to ml4w and keep everything else.

**HyDE stays as the fallback option** — it works, we know how it behaves,
we have idempotent install logic for it in `postinstall.sh` already. If
Plasma 6 trial on Metis shows a dealbreaker (e.g., fingerprint at SDDM
regresses, Vizio scaling bug), we can fall back with one line changed.

Sources:
- [Preconfigured setups — Hyprland Wiki](https://wiki.hypr.land/Getting-Started/Preconfigured-setups/)
- [ml4w uninstall docs](https://mylinuxforwork.github.io/dotfiles/getting-started/uninstall)
- [Polonium](https://github.com/zeroxoneafour/polonium) — KWin 6 tiling, keyboard-driven
- [Plasma 6 and traditional window tiling — Ivan Čukić (KDE)](https://cukic.co/2024/06/04/plasma-6-and-tiling/)
- [Niri](https://wiki.archlinux.org/title/Niri)

---

## 2. Secure Boot reality check

I have been wrong about this being "impossible." The correct status as of
April 2026:

### Doable? **Yes**, via `sbctl` + user-enrolled keys.

`sbctl` ([Foxboron/sbctl](https://github.com/Foxboron/sbctl)) is the
standard Arch path. Flow:

1. In firmware setup, clear the factory keys (PK/KEK/db) to enter
   **Setup Mode**. (On the Dell 7786, this is the "Delete all keys" /
   "Reset to setup mode" option under Boot Sequence → Secure Boot.)
2. `sbctl create-keys` — generates PK/KEK/db under `/usr/share/secureboot/`.
3. `sbctl enroll-keys --microsoft` — enrolls our keys **plus** Microsoft's,
   so Windows Boot Manager (which is signed by Microsoft) keeps booting.
   Critical for dual-boot: without `--microsoft`, Windows becomes
   unbootable.
4. Re-enable Secure Boot in firmware.
5. `sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi`
   `sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI`
   `sbctl sign -s /boot/vmlinuz-linux`
   `sbctl sign -s /boot/vmlinuz-linux-lts` — sign the bootloader + both
   kernels. `sbctl` remembers these paths and its pacman hook
   (`/usr/share/libalpm/hooks/zz-sbctl.hook`) re-signs them on every
   bootloader/kernel update.
6. For systemd-boot specifically: `bootctl install` and
   `bootctl update` look for `.efi.signed` companion files next to the
   `.efi` under `/usr/lib/systemd/boot/efi/`. Signing in-place there
   (`sbctl sign -s /usr/lib/systemd/boot/efi/systemd-bootx64.efi`) makes
   the signed copy survive across systemd package updates cleanly.

### Bootloaders

- **systemd-boot**: fully supported. sbctl pacman hook covers it. The
  `bootctl update` + deferred-signing trick above is a known gotcha; Arch
  Wiki calls it out.
- **limine**: also supported. sbctl signs `limine-bios.sys` / `BOOTX64.EFI`
  from `/usr/share/limine/`. `limine bios-install` writes a signed blob.
  Less well-trodden path than systemd-boot but it works
  ([Goodfellow, Feb 2026](https://maxgoodfellow.dev/2026/02/secureboot-with-limine)).
- **UKI (Unified Kernel Images)** — systemd-boot + `mkinitcpio --uki` is the
  cleanest Secure Boot path (single signed file covers kernel + initramfs +
  cmdline + microcode). Locks down the kernel cmdline as a Secure Boot
  measurement, which closes an otherwise-open attack vector (append
  `init=/bin/sh` to a plain-text loader entry). **Not currently in our
  setup** — we use plain `vmlinuz-linux` + `initramfs-linux.img`. UKI is
  the recommended long-term path but is a follow-on change, not coupled to
  enabling Secure Boot.

### TPM2 + Secure Boot interaction

This is the piece I had confused. Current LUKS enrollment is **PCR 0+7**
(`decisions.md` §Q11). PCR 7 measures the Secure Boot **state + key hashes**,
not just on/off. So:

- Today: Secure Boot is **OFF**. PCR 7 has a stable hash representing
  "Secure Boot off." The TPM unseals fine.
- Enabling Secure Boot changes PCR 7 even if we never touch a kernel or
  bootloader — enrolling our own keys changes the hash again.
- Net: **turning Secure Boot on will invalidate the existing TPM2 LUKS
  enrollment.** First boot after the change drops to the passphrase
  prompt.

### Migration recipe (Secure Boot toggle on an existing install)

```bash
# 1. Install sbctl
sudo pacman -S sbctl

# 2. From a booted Arch session, prepare keys
sudo sbctl status                          # confirm Setup Mode: Enabled after firmware toggle
sudo sbctl create-keys
sudo sbctl enroll-keys --microsoft         # KEEP Microsoft's KEK or Windows bricks

# 3. Sign everything EFI currently loads
sudo sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi
sudo sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI
sudo sbctl sign -s /boot/vmlinuz-linux
sudo sbctl sign -s /boot/vmlinuz-linux-lts

# 4. Also sign the systemd source so bootctl update preserves signature
sudo sbctl sign -s /usr/lib/systemd/boot/efi/systemd-bootx64.efi

# 5. Verify
sudo sbctl verify                          # every entry should say "signed"

# 6. Reboot, enter firmware, re-enable Secure Boot, save, reboot.
#    Expect: LUKS passphrase prompt (PCR 7 changed).

# 7. Once back in Arch, re-seal the TPM:
sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/ArchRoot
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 \
    /dev/disk/by-partlabel/ArchRoot

# 8. Reboot one more time to confirm silent unlock is restored.
```

Same re-enrollment is required if the user ever **disables** Secure Boot,
updates the firmware (PCR 0 shifts), or runs `sbctl enroll-keys` again.

### Verdict for the reinstall

Enable Secure Boot **on the clean install**, not as a later migration. Do
it at the end of phase 2 (post-LUKS, post-bootloader, pre-TPM2 enroll), so
the TPM gets sealed against the "Secure Boot on + our keys" PCR 7 state
from the start and there's no re-seal round-trip. Bake `sbctl sign` +
`sbctl enroll-keys --microsoft` into `chroot.sh`, assuming firmware is
already in Setup Mode (document in runbook: clear PK/KEK/db in BIOS before
booting the live ISO).

Keep Microsoft's KEK in the enrollment (`--microsoft`). Windows Boot
Manager is Microsoft-signed; drop it and dual-boot breaks.

Authoritative sources:
- [Arch Wiki: UEFI/Secure Boot](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot)
- [Arch Wiki: Trusted Platform Module](https://wiki.archlinux.org/title/Trusted_Platform_Module)
- [sbctl README](https://github.com/Foxboron/sbctl)
- [CachyOS Wiki: Secure Boot Setup](https://wiki.cachyos.org/configuration/secure_boot_setup/)

---

## 3. Limine — independent of Omarchy

The question: given a reinstall is already happening (migration cost ≈ 0),
is limine worth adopting **regardless** of Omarchy?

### Pros (for this specific setup)

1. **Snapper snapshot boot menu** — `limine-snapper-sync` AUR package
   auto-generates boot entries for each `snap-pac` snapshot. One-keystroke
   rollback from the limine menu. We have snapper + snap-pac installed
   already (see `postinstall.sh` §1) but snapshots today are
   reachable only by `arch-chroot`-from-recovery. This is the single
   biggest win.
2. **Bootable recovery ISO from disk** — we have an `ArchRecovery`
   partition on the Netac (`/dev/sdb1`, 1.5 GB Arch ISO written with
   `dd`) that systemd-boot can't list without hand-authored loader
   entries pointing at a kernel + initramfs we'd have to extract. Limine
   can boot ISO images directly via its loopback stanza:
   ```
   /Recovery ISO
       protocol: chainload
       path: boot():/ArchRecovery/archlinux-x86_64.iso
   ```
   — no extraction, no re-generation when the ISO is refreshed.
3. **Visible branded menu** — small quality-of-life win. systemd-boot's
   menu is functional-not-pretty; limine renders a Catppuccin-themeable
   list with icons.

### Cons

1. **UKI support is weaker.** systemd-boot auto-discovers
   `EFI/Linux/*.efi` UKIs; limine needs a manual `limine.conf` stanza per
   UKI. If we ever migrate to UKI for Secure Boot hardening, systemd-boot
   is the smoother ride. Workable on limine, just one more thing to
   maintain.
2. **Secure Boot story is newer.** It works
   ([Goodfellow Feb 2026](https://maxgoodfellow.dev/2026/02/secureboot-with-limine)),
   but the community has a decade of systemd-boot + sbctl tire tracks
   and only a year of limine + sbctl. More likely to hit a corner case.
3. **Windows chainload is manual.** systemd-boot auto-detects
   `\EFI\Microsoft\Boot\bootmgfw.efi`. Limine needs an explicit
   `/Windows` stanza. Three lines of config — not a dealbreaker, but it's
   three lines we don't currently maintain.
4. **Arch Wiki coverage.** systemd-boot is canonical on the Wiki. Limine
   has a page but it's shorter and less linked-to. Troubleshooting is a
   smaller audience.

### Migration cost on a clean install

Minimal. `chroot.sh` today has ~25 lines of bootloader config (the
`bootctl install` call plus the three `loader/entries/arch*.conf` writes).
Swap for:

```bash
pacman -S limine limine-snapper-sync
mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
efibootmgr --create --disk "$SAMSUNG" --part 1 \
    --loader '\EFI\limine\BOOTX64.EFI' --label 'Limine' --unicode
# write /boot/limine.conf (timeout, default, arch + arch-lts + windows
# chainload + recovery ISO stanzas)
systemctl enable limine-snapper-sync.service
```

`limine-snapper-sync` adds a pacman hook that regenerates limine's
snapshot sub-menu on every `snap-pac`-triggered snapshot. Roughly on par
with the size of the current systemd-boot block — no net script-complexity
increase.

### Verdict: **yes, adopt limine on this reinstall.**

Single biggest reason: **snapshot rollback from the boot menu, on a
btrfs+snapper+snap-pac setup we already maintain.** Today, if a `pacman
-Syu` breaks boot, recovery is "boot the recovery ISO, chroot, roll back
subvolume, regen initramfs" — ~15 minutes of tense typing. With limine,
it's "pick the pre-update snapshot from the boot menu, reboot into it,
fix the package at leisure" — ~30 seconds. That's the whole reason we
set up snapper in the first place; systemd-boot leaves it stranded.

Secondary wins (bootable recovery ISO from disk, Catppuccin menu) are
real but small.

The `decisions.md` §Q10-A section argued against limine specifically
because Omarchy was the only reason. That reasoning is stale once
Omarchy is off the table and we're evaluating limine on its own merits.
Update `decisions.md` §Q10-A to flip from systemd-boot → limine as part
of this reinstall planning.

Sources:
- [Arch Wiki: Limine](https://wiki.archlinux.org/title/Limine)
- [`limine-snapper-sync` AUR](https://aur.archlinux.org/packages/limine-snapper-sync)
- [EndeavourOS: Limine + Snapper guide](https://forum.endeavouros.com/t/guide-how-to-install-and-configure-endeavouros-for-bootable-btrfs-snapshots-using-limine-and-limine-snapper-sync/69742)

---

## 4. Summary of proposed decision deltas

| decisions.md section | Current | Proposed |
|----------------------|---------|----------|
| §Q3 Compositor       | Hyprland + HyDE | **Plasma 6 + Polonium** (or: Hyprland + ml4w as runner-up) |
| §Q10-A Bootloader    | systemd-boot | **limine** (+ `limine-snapper-sync`) |
| §Q11 Encryption      | PCR 0+7, Secure Boot **off** | **Secure Boot on** via `sbctl` + `enroll-keys --microsoft`; still PCR 0+7 |
| §Q10-D Login screen  | SDDM | SDDM (unchanged — Plasma 6's default anyway) |
| §Q10-E Notifications | mako | Plasma `knotifications` (replaces mako if we switch); mako stays if Hyprland |
| §Q10-F Launcher      | fuzzel | krunner (Plasma-native, Alt+Space) replaces fuzzel on Plasma; fuzzel stays if Hyprland |

Not changing:
- Ghostty, tmux, VSCode, Claude Code, Helix, Bitwarden SSH agent, mise,
  chezmoi, Remmina/FreeRDP, zsh+zgenom+p10k, Catppuccin Mocha theme —
  all DE-agnostic.

Script-level impact:
- `phase-2-arch-install/chroot.sh` — swap `bootctl install` block for
  limine block; add `sbctl` + Secure Boot signing at the tail.
- `phase-3-arch-postinstall/postinstall.sh` — replace HyDE install
  block with `plasma-meta` + `kwin-tiling-script-polonium` + Catppuccin
  Plasma theme (or ml4w install if we stay on Hyprland). Drop
  `iio-hyprland-git`, `hyprgrass`, `wvkbd`, `hyprpolkitagent` AUR
  entries on the Plasma path; keep them on the Hyprland path.

Not in scope of this memo: UKI migration. That's a separate follow-on
once Secure Boot + limine are proven on real hardware.

---

## 5. Authentication stacks (PIN / password / fingerprint)

Three auth methods are in play:
- **Password** — `pam_unix.so` reading `/etc/shadow`.
- **PIN** — `pam_pinpam.so` from the `pinpam-git` AUR package. PIN is
  stored in TPM NVRAM (not `/etc/shadow`); the TPM enforces the attempt
  counter in hardware (§5 of pinpam's SECURITY.md). Returns
  `AUTHINFO_UNAVAIL` when no PIN is set, so `sufficient` falls through
  cleanly on first boot before `pinutil setup` has been run.
- **Fingerprint** — `pam_fprintd.so` driving fprintd over D-Bus. Goodix
  538C reader on `libfprint-tod-git`. Has `max-tries=` and `timeout=`
  module options — `timeout=-1` means "always active," positive values
  give up after N seconds ([`man pam_fprintd`]).

### Design invariants

The laptop spends 90% of its life under the user's desk. The fingerprint
reader (power button on the Dell 7786) is only physically reachable at
cold boot, before the laptop goes under the desk. Once docked, the hand
can't reach the reader — so any PAM surface that **blocks** on a
fingerprint prompt is broken UX.

Two invariants drive all three stacks:

1. **Fingerprint is always an option** at every surface. Never removed.
2. **Fingerprint is never required** and never the first prompt at a
   surface where the reader is unreachable. At sudo and hyprlock, PIN
   prompts first — the common case (user types PIN, done) never sees the
   finger prompt at all. If a user Ctrl+C's past PIN, the finger module
   runs next with `max-tries=1 timeout=5`: one attempt, five-second wait,
   then fall through to password. No lingering prompts.

At SDDM (cold boot) the finger IS reachable, so it goes first with
`timeout=10`; the user can touch the reader or type a password and
whichever lands first wins.

### Target stacks

| Surface  | Prompt order                                        | PIN | Finger | Password |
|----------|-----------------------------------------------------|-----|--------|----------|
| SDDM     | fingerprint (10s) → password                        | —   | yes    | yes      |
| hyprlock | PIN → fingerprint (5s) → password                   | yes | yes    | yes      |
| sudo     | PIN → fingerprint (5s) → password                   | yes | yes    | yes      |

All three stacks use `pam_pinpam.so` / `pam_fprintd.so` with `sufficient`
control so any one match ends the auth successfully. `pam_unix.so` is
never removed — it stays the unconditional fallback via the
`system-auth` / `system-login` / `login` include at the end of each
stack.

### Root cause of each observed bug on the live system

1. **SDDM: "Password" field accepts PIN, then asks for finger after.** The
   live `/etc/pam.d/sddm` had `auth sufficient pam_fprintd.so` hand-
   prepended AND the original stack underneath (verified in-situ 2026-04-21).
   pam_fprintd scans while the user types; if the user hits Enter first,
   the stack falls through to `system-login` → pam_unix **and** — because
   of how SDDM's own conversation loop works — fprintd's D-Bus prompt is
   still active, so the user sees a finger prompt after the password. The
   "PIN works in the password field" is an incidental side-effect of
   `postinstall.sh`'s `sed -i '1i pam_pinpam.so'` loop having touched SDDM
   in an earlier run (or the user manually). pam_pinpam with `sufficient`
   at line 1 accepts whatever the greeter feeds and, if it matches a TPM-
   stored PIN, authenticates — but then the fprintd line still fires. The
   fix is to own the whole file (not `sed -i 1i`) and keep pam_pinpam out
   of it.

2. **hyprlock: PIN silently rejected, only password works.** Two
   compounding bugs here, only the second one was caught on first
   investigation:
   - **The real root cause** (caught 2026-04-22 after a re-test): the
     PAM line referenced `pam_pinpam.so`, but pinpam-git installs its
     module as `libpinpam.so` — every other PAM module follows the
     `pam_*.so` naming convention but pinpam doesn't. PAM's dlopen
     failed silently (`PAM unable to dlopen(/usr/lib/security/pam_pinpam.so)`
     in the journal); PAM marked it a "faulty module" and skipped to the
     next line. PIN was never even attempted, regardless of whether
     `pinutil setup` had run.
   - **The originally-suspected cause** (turned out to be a red herring
     this round): an early reading of `pinutil status` returned
     `{"Ok":null}` and the agent interpreted that as "no PIN
     provisioned." After running `pinutil setup` and re-testing, the
     dlopen-failure was still in the journal — so the status reading
     either meant something else or the user provisioned PIN
     immediately after.

   Fix: reference `libpinpam.so` literally in the PAM lines. Comment in
   §7a calls out the naming quirk so this doesn't get re-broken.

3. **sudo: fingerprint prompts first, Ctrl+C falls to password, PIN never
   offered.** The live sudo stack has fprintd at line 1 *above* pam_pinpam
   — postinstall's `sed -i '1i'` on the for-loop puts pinpam at line 1,
   but the `sudo` file was also hand-edited to include fprintd (or a
   previous `end-4` postinstall run authored it). When sudo evaluates the
   stack, fprintd runs first and blocks on a D-Bus prompt to the reader.
   Fix: fully overwrite `/etc/pam.d/sudo` with a stack that contains
   `pam_pinpam.so sufficient` + `include system-auth` and NOTHING ELSE.

### Why PIN is more secure than a weak password (the Windows Hello pitch)

A password is a **symmetric secret**: the exact same string the user types
also exists somewhere as a hash (`/etc/shadow` locally, or a password
database on a server). Dump the hash, brute-force it offline, impersonate
the user anywhere they reuse the password. A TPM-backed PIN is **user-
provided entropy that unseals a hardware-bound private key**: the PIN
itself isn't stored anywhere off the TPM chip; the TPM uses it to unlock
a key that never leaves silicon. Three things follow from that: (a) the
PIN is useless off this specific laptop — there's no hash to exfiltrate,
no credential to reuse on another machine; (b) the TPM enforces anti-
hammering in hardware, so `pam_tally` / `pam_faillock` races aren't the
only line of defence — a clone of `/etc/shadow` on a stolen disk can be
brute-forced at line rate, a clone of the TPM's NVRAM cannot; (c) on
Windows, PINs are additionally gated by **PCR measurements** so a booted-
but-tampered OS can't unseal the key either (we don't use that for pinpam,
but we do use it for LUKS via PCR 0+7 — same primitive, same idea).
Cold-boot still demands a full password on Windows because PCR values
haven't stabilised yet and the TPM hasn't handed out a session — once
you're logged in and the TPM has a trusted session, a short PIN is
provably at least as strong as a long password, because the ceiling on
attempts is enforced below the OS. Microsoft's
[Windows Hello FAQ](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/faq)
phrases it as "the PIN is stronger than a password — not because of
entropy, but because of the difference between providing entropy vs.
using a symmetric key."

### Script-level impact

`postinstall.sh` §7a now owns all three PAM files end-to-end via `tee`
heredocs (previously §7 used `sed -i '1i'` which was not idempotent
across format changes and didn't touch SDDM). The verify block checks
module presence at every surface (pinpam at sudo+hyprlock, fprintd at
all three with the expected `max-tries=1` + `timeout=N` options, no
pinpam at sddm) plus ordering (`pinpam` before `fprintd` at sudo and
hyprlock so the common PIN case never sees a finger prompt).

Sources:
- [`man pam_fprintd(8)`](https://manpages.debian.org/testing/libpam-fprintd/pam_fprintd.8) — `max-tries=`, `timeout=`, and the note that "the PAM stack is by design a serialised authentication, so it is not possible for pam_fprintd to allow authentication through passwords and fingerprints at the same time" (so parallel prompts are the app's job, not PAM's).
- [Windows Hello for Business FAQ](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/faq) — PIN vs. password threat model.
- [pinpam source `pinpam-pam/src/lib.rs`](https://github.com/RazeLighter777/pinpam/blob/main/pinpam-pam/src/lib.rs) — returns `AUTHINFO_UNAVAIL` when no PIN is set, which is the clean-fallthrough signal PAM's `sufficient` stanza needs.
