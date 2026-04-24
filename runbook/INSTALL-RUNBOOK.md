# Install Runbook — Windows + Arch dual-boot

Print this. Keep it next to the laptop.

Total wall-clock: ~90 min active, ~2 h with waits.

You'll need:
- Ventoy USB (already built + staged via `pnpm i` on the dev machine — whatever drive letter Windows mounts it at, e.g. `E:` or `F:`)
- Wi-Fi SSID + password
- The Bitwarden master password (for later — Bitwarden desktop in Arch)
- A second device (phone) to read this if you can't print
- A safe place to stash **two** recovery secrets: the **BitLocker recovery key** (see Phase 1 step 7) and the **LUKS passphrase** you pick in Phase 2d

What gets touched:
- **Samsung 512 GB** → EFI + MSR + Windows 160 GB (BitLocker) + Arch LUKS+btrfs (~316 GB)
- **Netac 128 GB** → Arch recovery ISO (unencrypted) + LUKS swap (16 GB, random key per boot) + LUKS ext4 for `/var/log` + `/var/cache`

**Both drives are required.** `install.sh` size-detects both and aborts if either is missing. If you've repurposed the Netac for something else, swap it back in before starting — the layout is not optional (swap, recovery partition, and the `/var/log`+`/var/cache` ext4 all depend on it per [docs/decisions.md](../docs/decisions.md) §Q9).

Three things to know before starting:
- **Hostnames are intentionally different**: Windows = `Metis`, Arch = `inspiron`. Your router sees whichever OS is up. This is cosmetic, not a bug (see recovery §D if it bothers you).
- **First Windows boot after Arch install will prompt for the BitLocker recovery key.** Expected — systemd-boot changes PCR values. Phase 1 step 7 stashes the key in Bitwarden.
- **First Arch boot after install will prompt for the LUKS passphrase.** Also expected — TPM2 autounlock isn't wired until Phase 3 runs `systemd-cryptenroll`. After that, Arch boots silently (same model as BitLocker). The passphrase stays as a key slot forever so you can always recover.

---

## Phase 0 — BIOS prep (5 min)

1. Plug the Ventoy USB. Power on. Hammer **F2** to enter BIOS setup.
2. Set:
   - **Boot Mode**: UEFI (not Legacy)
   - **Secure Boot**: **Disabled** for the install (systemd-boot isn't signed out of the box). `decisions.md` wants Secure Boot ON long-term; that's a separate later step using `sbctl` to enroll your own keys. Don't block on it now — get the install running first, then re-enable with signed kernel/bootloader after Phase 3 stabilizes.
   - **SATA Operation**: AHCI (should already be; RAID/Intel RST will hide disks from Arch)
   - **Fast Boot**: Disabled (stops it skipping the boot menu)
   - **Fingerprint Reader**: **Enabled** (Dell BIOS hides this under Security → Fingerprint Reader on some firmware revisions). If it's disabled, Linux won't see the sensor at all and Phase 3 fingerprint enrollment will fail with "no devices".
3. Save & exit. Hammer **F12** at the Dell logo → boot menu → pick the USB (something like "UEFI: SanDisk …" or the WD label).

**If the USB isn't in F12:** go back to BIOS → Boot Sequence → Add Boot Option, or make sure USB Boot is enabled. Secure Boot being on will also hide it.

---

## Phase 1 — Windows install (~30 min, mostly unattended)

1. Ventoy menu appears. Pick **`Win11_25H2_English_x64_v2.iso`**.
2. If Ventoy shows "Boot in normal mode" / "Boot in grub2 mode" — pick **normal**.
3. `autounattend.xml` takes over. You'll see:
   - diskpart scrolls, Samsung gets wiped and laid out
   - Windows files copy (~10 min)
   - Reboots itself **twice** — leave the USB in both times; Ventoy will re-show the menu. **Don't press anything** — it'll auto-select the Win11 ISO via the `autosel` timer. If the timer expires and you're stuck, just re-pick Win11.
   - Finally lands on the `Tom` desktop. No prompts, no OOBE.

**If you see** `No unique 500-600 GB disk found - refusing to proceed`:
The inline PowerShell safety check in `autounattend.xml` aborted because either zero or multiple disks fell in the 500–600 GB window. Likely causes and fixes, in order of likelihood:
- **An external drive is plugged in that's also 500–600 GB** → unplug it, press any key to dismiss the pause, power-cycle (hold power), retry F12 → USB.
- **The Samsung is missing from BIOS** → reboot into BIOS (F2). Confirm the Samsung SSD 840 PRO appears under Storage. If it doesn't: reseat the drive, or the SATA controller is still in RAID mode (flip to AHCI — Phase 0 step 2).
- **The Samsung's size is outside the window** → If you're running on different hardware than decisions.md §Q9 describes, the hardcoded 500–600 GB bounds are wrong. Fix: edit `autounattend.xml` — search for `500GB` and `600GB`, widen the window, re-stage the USB with `pnpm stage`.

4. **Wi-Fi should already be connected** — `autounattend.xml` embeds three profiles (`ATTgs5BwGZ`, `rhombus`, `rhombus_legacy`), all WPA2PSK, `connectionMode=auto`. Windows adds all three and connects to whichever is in range. Confirm via the taskbar network icon. If none are visible (different location), click the icon → pick SSID → enter password. The winget-import scheduled task waits up to 20 min for `cdn.winget.microsoft.com` and proceeds as soon as you're online.

5. Watch for winget to run:
   - It's a scheduled task called **`WingetImportOnce`**, starts ~2 min after logon.
   - Open Task Manager → Details, you'll see `winget.exe` churning. Takes 10–20 min depending on your connection.
   - It self-deletes the task on success.

**If winget never runs or fails:**
- Open PowerShell, run `schtasks /Query /TN WingetImportOnce /V /FO LIST` — look at **Last Result** (0 = ok, anything else = failed).
- Log files at `C:\Windows\Setup\Scripts\winget-*.log`.
- Manual fallback: `winget import -i C:\Windows\Setup\Scripts\winget-import.json --accept-package-agreements --accept-source-agreements --ignore-versions`

6. **BitLocker runs in parallel with winget** — it's in `FirstLogon.ps1`. With UsedSpaceOnly on a ~10-GB-used fresh install, encryption finishes in ~5 min. Check progress: `manage-bde -status C:` in PowerShell.

7. **Stash the BitLocker recovery key RIGHT NOW** — before doing anything else:
   - File #1: `C:\Windows\Setup\Scripts\BitLocker-Recovery.txt`
   - File #2: `<VENTOY_USB>:\bitlocker-recovery.txt` (same content)
   - Open it. Copy the 48-digit key.
   - Paste into Bitwarden as a **Secure Note** titled "Inspiron BitLocker recovery". Save.
   - Also take a phone photo of it as a belt-and-suspenders backup.
   - Once you've confirmed the key is safely in Bitwarden, delete both files: `Remove-Item C:\Windows\Setup\Scripts\BitLocker-Recovery.txt, <USB_LETTER>:\bitlocker-recovery.txt -Force` (substitute whatever drive letter Windows assigned the Ventoy stick — check **This PC**)
   - **Do not skip this.** You'll need this key in Phase 2e — the first Windows boot after Arch install will almost certainly prompt for it.

8. Once winget is done (or even while it's running — Arch install doesn't care about Windows state), shut down. Leave the USB in.

---

## Phase 2 — Arch install (~40 min)

### 2a. Boot the Arch live environment

1. Power on, F12, pick USB again.
2. Ventoy menu → pick **`archlinux-x86_64.iso`** → "Boot in normal mode". (The filename is always the undated symlink — `fetch-assets.ps1` mirrors that, not a dated release.)
3. At the Arch ISO menu, pick **"Arch Linux install medium (x86_64, UEFI)"**. You land at a root shell.

**If step 3 fails with `ERROR: Failed to mount '/dev/loop0'` + `EXT4-fs: VFS: Can't find ext4 filesystem`:** archiso copied the rootfs image to RAM but couldn't loop-mount it. Two causes, try in order:

1. **Ventoy ISO-virtualization hiccup** (tried first because it's a 30-second retry). Reboot, Ventoy menu, arrow onto `archlinux-x86_64.iso`, press **`d`** to toggle Memdisk mode (status indicator appears next to the filename), then Enter. Memdisk loads the whole ISO into RAM before boot, bypassing Ventoy's loopback layer. The 7786's 16 GB RAM easily absorbs the 1.3 GB ISO.

2. **Corrupt ISO on the USB.** If Memdisk mode fails with the same error, the ISO file itself is bad (download or robocopy corrupted it — `fetch-assets.ps1` and `stage-usb.ps1` both SHA256-verify post-op now, but older sticks may predate that). Go back to the dev machine:

   ```powershell
   # Replace V: with the Ventoy data drive letter
   CertUtil -hashfile V:\archlinux-x86_64.iso SHA256
   Get-Content V:\archlinux-sha256sums.txt | Select-String archlinux-x86_64.iso
   ```
   If the two hashes don't match, re-download + re-stage:
   ```powershell
   pnpm restore:force   # re-downloads + verifies the Arch ISO
   pnpm stage:force     # re-copies + verifies on the USB
   ```

### 2b. Network

- **Ethernet via USB-C dock is the primary path** — plug it in before booting. `install.sh` pings `archlinux.org`; if ethernet is up, it skips Wi-Fi entirely.
- **Wi-Fi fallback**: if no ethernet, `install.sh` auto-connects using the embedded profiles (`ATTgs5BwGZ`, `rhombus`, `rhombus_legacy`). You do nothing.

**If BOTH fail** (dock ethernet driver missing from live ISO, all Wi-Fi networks out of range), fall back to manual iwctl:

```bash
iwctl
device list                              # note your wifi device, probably wlan0
station wlan0 scan
station wlan0 get-networks
station wlan0 connect YOUR_SSID          # prompts for passphrase
exit
ping -c2 archlinux.org
```

**If `device list` is empty:** `rfkill unblock all`, try again. If still empty, plug in the USB-C dock for wired ethernet.

### 2c. Fetch the installer

Clone the repo fresh from GitHub — `install.sh` reads everything it needs (chroot.sh, phase-3 staging, p10k sidecar) from its own parent directory:

```bash
git clone https://github.com/fnrhombus/arch-setup /tmp/arch-setup
```

No Ventoy-USB mount step. The previous USB-mounted variant was fragile (dm-linear lock collisions) and has been removed from the repo; clone-only is the canonical path.

### 2d. Run the installer

**Optional but worth the 20 seconds if your connection feels slow:** the live ISO ships with a stale/geographically-random mirrorlist. pacstrap on a bad mirror can appear to hang at <50 KB/s for 20+ min before it finishes. Refresh first:

```bash
reflector --latest 10 --sort rate --protocol https --save /etc/pacman.d/mirrorlist
```
If `reflector` complains about no network, you haven't connected yet — go back to 2b. If it exits OK but the result still looks wrong (`head /etc/pacman.d/mirrorlist`), skip it — pacstrap will still work on the default list, just slower.

```bash
bash /tmp/arch-setup/phase-2-arch-install/install.sh
```

It will:
1. Size-detect the Samsung (500–600 GB) and Netac (100–150 GB). **Aborts loudly if either is missing** — don't blindly retry, fix it.
2. Detect whether Ventoy is installed on the Netac (no-USB recovery workflow). If yes → partitions only the reserved region, preserves Ventoy. If no → wipes Netac per the original Q9 layout (recovery + swap + /var).
3. Show the plan and ask `[yes/NO]`. Type **`yes`** exactly.
4. **Prompt once up-front for two passwords** (each confirmed twice):
   - **root password** — account recovery.
   - **tom's password** — your daily login. You'll bypass it with TPM-PIN and fingerprint later.
5. **Auto-generate a 48-digit LUKS recovery key** (BitLocker-format: 8 groups of 6 digits, dash-separated) and display it with a loud banner. **Save it to Bitwarden as `Metis LUKS` right now** — then re-type it back exactly at the prompt. Script refuses to continue until the type-back matches. The key is never written to disk: Bitwarden is the only copy from here on.
6. LUKS-format both data partitions (Samsung root + Netac /var), mkfs, pacstrap (~15 min — biggest wait, fully unattended).
7. Enter chroot (passwords + LUKS UUIDs handed in via mode-600 files), install systemd-boot, write `/etc/crypttab.initramfs` + `/etc/crypttab`, add `sd-encrypt` to mkinitcpio HOOKS, wire services + PAM for fingerprint-sudo + gnome-keyring.
8. Copy `postinstall.sh` + dotfiles into `/home/tom/`.
9. Unmount, close LUKS mappers, print "Done."

**If install.sh dies:**
- **"No 500–600 GB disk detected"** → phase-1 Windows install didn't run. Boot back into Windows first.
- **"Samsung has <3 partitions"** → same — Windows didn't lay out the disk.
- **pacstrap fails** → network dropped. Reconnect (`iwctl` for Wi-Fi, or replug the dock for ethernet), then re-run. The script is **not idempotent**, so clear the partial state first:
  ```bash
  umount -R /mnt
  swapoff -a
  # Wipe every partition that install.sh created on Samsung + Netac.
  # (lsblk shows them; the Samsung btrfs is the biggest partition on the 500–600 GB disk.)
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT /dev/sda /dev/sdb 2>/dev/null
  # For each Arch-owned partition (btrfs on Samsung, swap + ext4 + ISO on Netac), wipefs:
  # e.g. wipefs -a /dev/sda4 /dev/sdb1 /dev/sdb2 /dev/sdb3
  ```
  Then re-run `install.sh`. Recovery is ugly because it's a fresh install — if uncertain, just start over, it's fast.
- **"Could not find EFI System partition"** → Windows install put the EFI somewhere weird. Use `gdisk -l /dev/sda` to confirm GUID `c12a7328…`.
- **chroot script fails mid-way** → you can `arch-chroot /mnt` manually and finish the remaining steps from `chroot.sh` by hand.

9. When it says "Done": `reboot`. Pull the USB as it powers off.

### 2e. First boot into Arch

- systemd-boot menu appears with:
  - **Arch Linux** (linux kernel) + **Arch Linux (fallback)**
  - **Arch Linux LTS** (linux-lts kernel) + **Arch Linux LTS (fallback)** — the safety net if a linux upgrade breaks something
  - Auto-discovered **Windows Boot Manager**

  3-sec timeout; Arch Linux (the non-LTS) is default.
- **LUKS passphrase prompt** appears early in boot: `Please enter passphrase for disk (cryptroot):`. Type the passphrase you set in Phase 2d. The /var volume auto-unlocks from a keyfile — only cryptroot asks you for anything. After Phase 3's `systemd-cryptenroll` runs, this prompt is replaced by silent TPM unlock.
- It boots to a black screen, then to **SDDM** (graphical login).

**If the systemd-boot menu doesn't show Windows:** boot into Arch anyway, then as root: `bootctl list` should show Windows. If not: `ls /boot/EFI/Microsoft/Boot/bootmgfw.efi` — missing file means Windows install didn't write it (rare). Fix later; don't block on this.

**Expected: BitLocker recovery prompt on first Windows boot after this step.** Systemd-boot installing itself to the shared EFI changes the TPM's PCR values → BitLocker can't auto-unseal → you get the blue "Enter recovery key" screen. This is not a bug.
- Type the 48-digit key from Bitwarden.
- Windows unlocks, boots normally.
- Windows re-seals to the new PCR values automatically. Next boots: silent unlock, no prompt ever again (unless bootloader changes).
- **If you don't have the key when this screen appears — you are locked out of Windows.** Phase 1 step 7 exists for this reason.

**If nothing boots:** BIOS → Boot Sequence → make sure "Linux Boot Manager" is listed and first. If only "Windows Boot Manager" is there, run from a live USB: `bootctl --path=/boot install` to re-register.

### 2f. Clear the BitLocker prompt now (before Phase 3)

Do this before starting Phase 3 — you want the BitLocker key mess handled while you're still thinking about it, not 25 minutes into Hyprland setup.

1. Reboot. At the systemd-boot menu, pick **Windows Boot Manager**.
2. BitLocker prompts for the recovery key. Type the 48-digit key from Bitwarden ("Inspiron BitLocker recovery").
3. Windows boots. Log in as `Tom`. Let it sit for 30 seconds so BitLocker re-seals against the new PCR values.
4. Shut down: **Start → Power → Shut down**. (Fast Startup is off, so this is a clean shutdown, not a hybrid-hibernate.)
5. Power on → systemd-boot → pick **Arch Linux** → back into Arch. No more BitLocker prompts from here.

If the BitLocker key doesn't work: you have the phone photo from Phase 1 step 7 as a last-ditch copy. If even that doesn't work, Windows is gone and you need to reinstall — Arch is unaffected.

---

## Phase 3 — Post-install (~25 min)

### 3a. Get a terminal

At SDDM, log in as **tom**. Hyprland starts with **no config yet** → blank screen, no keybindings, no launcher. That's expected.

**Switch to a TTY:** `Ctrl + Alt + F2` → text login as `tom`.

### 3b. Run postinstall

```bash
chmod +x ~/postinstall.sh
~/postinstall.sh
```

It will:
1. `sudo` prompt for your password — type it. (No fingerprint/PIN yet.)
2. **pacman** — all CLI tooling, Bitwarden (desktop + CLI), Ghostty, fuzzel, cliphist, swaync, satty, hyprshot, mise, chezmoi, gh, snapper. Signed binaries from `extra`, ~5 min.
3. **yay** — only the 4 AUR-exclusive packages: `visual-studio-code-bin`, `microsoft-edge-stable-bin`, `catppuccin-sddm-theme-mocha`, `pinpam-git`. ~5 min build time.
4. Installs Claude Code CLI: `mise use -g node@lts` pulls a LTS Node via mise, then `mise exec -- npm install -g @anthropic-ai/claude-code`. (There is no mise plugin named "claude-code" — Claude Code is shipped through npm. Completions are printed at runtime by `claude --print-completion zsh`; no external file download.) **No local SSH keys are generated** — keys live in your Bitwarden vault as "SSH key" items and surface via `~/.bitwarden-ssh-agent.sock` once Bitwarden desktop is running with the SSH-agent toggle on (Phase 3e). A planter in `~/.zshrc.d/arch-ssh-signing.zsh` waits until `ssh-add -L` returns a pubkey, then wires git commit signing + registers the key with GitHub automatically.
5. **Points Bitwarden at your self-hosted server** `https://hass4150.duckdns.org:7277` — CLI via `bw config server`, desktop via pre-seeded `~/.config/Bitwarden/data.json`. If the desktop login screen still shows "bitwarden.com" in the "Logging in on:" dropdown, pick **Self-hosted** and paste that URL manually.
6. **Prompt you to enroll your fingerprint** — touch the sensor 5 times, slight re-position each touch. Reader is auto-detected; if enrollment fails the script prints a diagnostic (full `lsusb`, `fprintd-list`, last 20 log lines) and offers to install `libfprint-git` from AUR and retry.
7. **Prompt you to set a TPM-PIN** (`pinutil setup`) — 6+ chars. This is what you'll type for sudo from now on.
7.5. **Enroll TPM2 for silent LUKS autounlock** (`systemd-cryptenroll --tpm2-pcrs=0+7 /dev/disk/by-partlabel/ArchRoot`). Prompts once for your LUKS passphrase so it can add the TPM slot. After this reboot, `cryptroot` unseals from the TPM automatically — no passphrase prompt at boot. Passphrase slot stays intact as recovery.
8. Wires `~/.ssh/config` for Bitwarden SSH agent.
9. Plants `~/.zshrc.d/arch-first-login.zsh` (one-shot: `bw login` + `gh auth login` + git name/email) and `~/.zshrc.d/arch-ssh-signing.zsh` (every-login, self-deletes once SSH signing is wired).
10. Builds zgenom plugins (warms cache so first login is fast), writes tmux/helix/ghostty configs.
11. Takes a **snapper baseline snapshot** of `/` — you can roll back later via `snapper -c root list`.
12. Installs USB-serial udev rules (ESP32/Pico/FTDI/CH340) and adds you to `uucp`.
13. Runs the **end-4/dots-hyprland installer interactively** — it'll ask questions. Accept defaults unless you know better. If it asks whether to **overwrite existing config files**, say **yes** — your `~/.config` is fresh and there is nothing here worth keeping. If it asks about a user-level systemd service restart, say yes too.
14. Prints a verify table — scan for **FAIL** rows.

**If fingerprint enroll fails:** postinstall already handles the Goodix fallback interactively. If you declined or it still fails:
```bash
SKIP_FPRINT=1 ~/postinstall.sh    # re-run skipping finger step
```
Then manually: `lsusb | grep -iE 'goodix|validity|synaptics'`, `fprintd-list-devices`. Check https://fprint.freedesktop.org/supported-devices.html for your VID:PID.

**If `pinutil` is missing** after AUR install:
```bash
SKIP_PIN=1 ~/postinstall.sh       # re-run skipping PIN step
# Then manually:
yay -S pinpam-git
sudo pinutil setup
```

**If something else fails mid-run:** re-run `~/postinstall.sh`. It's idempotent.

### 3c. Reboot into Hyprland

```bash
sudo reboot
```

- SDDM again. Log in as tom.
- Hyprland comes up with end-4 config: waybar at top, wallpaper, keybindings live.
- Default terminal: `Super + Return` opens Ghostty. (If end-4 has re-mapped it, the keybind cheatsheet is bound to `Super + /`.)
- App launcher: `Super + Space` (fuzzel).

**Escape hatch if NO keybinding opens a terminal** (keybind variant mismatch, Hyprland config didn't install, wayland handshake fail): `Ctrl + Alt + F3` drops to TTY3 where you can log in as `tom` and debug. `Ctrl + Alt + F1` jumps back to the SDDM/Hyprland session. Worst case: from TTY3, `journalctl --user -u hyprland -b` tells you why Hyprland dropped you to a featureless compositor.

### 3e. Bitwarden one-time setup

1. Launch Bitwarden from the launcher.
2. Log in with your master password (only time you type it).
3. **Settings → Security → enable "Unlock with system keyring"**. You'll be asked for the master password once more — after that, gnome-keyring holds it and Bitwarden auto-unlocks at login.
4. **Settings → SSH agent → Enable**. The socket appears at `~/.bitwarden-ssh-agent.sock` (already wired into `~/.ssh/config`).
5. Add any SSH keys you want as **"SSH key"** vault items.
6. **You MUST log out and back in now** (or at least close + reopen every terminal). `SSH_AUTH_SOCK` is set by `~/.zshrc.d/bitwarden-ssh-agent.zsh` at shell start — it only notices the new socket in a fresh shell. Skip this and the 3f sanity check `ssh-add -l` will fail even though the agent is actually working.

After the re-login: Bitwarden auto-unlocks (via gnome-keyring), and `ssh-add -l` lists your keys with no prompt.

### 3e-bis. Azure DDNS one-time setup (`metis.rhombus.rocks`)

`postinstall.sh` installs the `metis-ddns` script + systemd timer + NetworkManager dispatcher hook + the `az` CLI, and stubs `/etc/metis-ddns.env` from a template. **You still have to fill in the service-principal credentials once.**

On this laptop (or any machine with `az` CLI):

```bash
az login                                 # device-code flow, opens browser
SUB=$(az account show --query id -o tsv)
RG=<your-DNS-resource-group>             # the one containing rhombus.rocks
ZONE_ID=$(az network dns zone show -g "$RG" -n rhombus.rocks --query id -o tsv)
az ad sp create-for-rbac \
    --name metis-ddns \
    --role "DNS Zone Contributor" \
    --scopes "$ZONE_ID" \
    --years 2
```

Last command prints `appId`, `password`, `tenant`. Paste them into `/etc/metis-ddns.env` (mode 600, root-owned — `sudoedit /etc/metis-ddns.env`):

```ini
AZ_TENANT_ID=<tenant>
AZ_CLIENT_ID=<appId>
AZ_CLIENT_SECRET=<password>
AZ_SUBSCRIPTION_ID=<SUB>
AZ_RESOURCE_GROUP=<RG>
AZ_DNS_ZONE=rhombus.rocks
AZ_DNS_RECORD=metis
DDNS_DISABLE_IPV4=1                      # IPv6-only — flip to 0 if you ever expose v4
```

Kick the first run:

```bash
sudo systemctl start metis-ddns.service
sudo journalctl -u metis-ddns -n 30
```

First call may 403 with "AuthorizationFailed" — Azure role assignments propagate in 30s–5min. Wait, retry. After first success, the timer + NM hook take over and you don't think about it again until the SP secret expires in 2 years.

**Verify from the outside** (any machine, even your phone):

```bash
dig AAAA metis.rhombus.rocks +short
```

Should return your laptop's current public IPv6 address.

### 3e-ter. Let's Encrypt cert for `metis.rhombus.rocks`

Only useful **after step 3e-bis succeeds** (DNS must resolve before the dns-01 challenge will).

`postinstall.sh` installs `certbot` + the `certbot-dns-azure` plugin and stubs `/etc/letsencrypt/azure.ini` from a template. Same SP that DDNS uses works here — `DNS Zone Contributor` already lets it write the TXT challenge records.

Mirror the SP creds into `/etc/letsencrypt/azure.ini` (the keys differ from the DDNS env file because certbot's plugin uses its own INI scheme):

```ini
dns_azure_environment = "AzurePublicCloud"
dns_azure_tenant_id = <tenant>
dns_azure_subscription_id = <SUB>
dns_azure_resource_group = <RG>
dns_azure_sp_client_id = <appId>
dns_azure_sp_client_secret = <password>
```

Issue the cert (one-time):

```bash
sudo certbot certonly \
    --authenticator dns-azure \
    --dns-azure-credentials /etc/letsencrypt/azure.ini \
    --dns-azure-propagation-seconds 60 \
    -d metis.rhombus.rocks \
    --agree-tos -m <your-email> --no-eff-email
```

Cert lands at `/etc/letsencrypt/live/metis.rhombus.rocks/{fullchain,privkey}.pem`. `certbot-renew.timer` is already enabled by postinstall — it'll renew within 30d of expiry, twice daily, with no further action.

### 3e-quater. Firewall — confirm and tweak

`postinstall.sh` enables `ufw` with default-deny incoming, default-allow outgoing, and `22/tcp ALLOW` for SSH (Callisto pubkey already in `~/.ssh/authorized_keys`). Rules apply to **both IPv4 and IPv6** — ufw is dual-stack out of the box.

```bash
sudo ufw status verbose                  # confirm "Status: active", "Default: deny (incoming)"
sudo ufw allow <port>/tcp                # add a rule
sudo ufw delete allow <port>/tcp         # remove a rule
```

Why this matters: your router can globally enable/disable IPv6 TCP to Metis but can't filter per port. With IPv6 there's no NAT — every device gets a publicly routable address, so anything bound to a port on the laptop is exposed when the router-side toggle is on. ufw is the per-port gate on the host side.

### 3f. Sanity checks

```bash
# sudo: clear cache, then test. Pay attention to WHICH prompt appears.
sudo -k
sudo echo ok
```

The prompt you see tells you what's wired:
- `PIN:` → pinpam is working. TPM-PIN is your daily sudo auth. ✓
- `Place your finger on the fingerprint reader` → fprintd is working. ✓
- `[sudo] password for tom:` → **neither TPM-PIN nor fingerprint is wired**. Something went wrong. See recovery §I below before relying on this.

```bash
# fingerprint enrolled?
fprintd-list tom               # should show a fingerprint enrolled

# PAM wiring
sudo grep -E 'pam_pinpam|pam_fprintd' /etc/pam.d/sudo
# Expect both lines, both marked `sufficient`, before the pam_unix.so fallback.

# ssh agent
echo $SSH_AUTH_SOCK            # should be ~/.bitwarden-ssh-agent.sock (set by ~/.zshrc.d/bitwarden-ssh-agent.zsh)
ssh-add -l                     # should list keys once Bitwarden desktop is unlocked + SSH-agent toggle is on
```

---

## Phase 4 — Start the Claude session with the handoff

1. Open Ghostty. Start tmux: `tmux new -s main` (prefix = **Ctrl+a**).
2. Clone the setup repo so Claude has context:
   ```bash
   mkdir -p ~/src
   cd ~/src
   # Primary: clone from GitHub (if repo is pushed).
   git clone git@github.com:fnrhombus/arch-setup.git arch-setup@fnrhombus
   cd arch-setup@fnrhombus
   ```

   **If the clone fails** (repo not pushed, or gh auth not wired yet), recover from the Ventoy USB — it still has the repo contents synced there pre-install:
   ```bash
   # Re-insert the Ventoy USB (you pulled it at end of Phase 2d).
   sudo mkdir -p /mnt/ventoy
   sudo mount /dev/disk/by-label/Ventoy /mnt/ventoy

   # Sanity-check what's actually at the USB root before copying — the sync
   # step (pre-install) may have only pushed the phase-2/3 script dirs and
   # not the markdown docs. If the `.md` files are missing, Claude still has
   # enough to proceed with just phase-3 script + CLAUDE.md.
   ls /mnt/ventoy/*.md /mnt/ventoy/CLAUDE.md 2>/dev/null

   mkdir -p ~/src/arch-setup@fnrhombus
   # Copy every repo file that IS on the USB; missing ones silently skip
   # thanks to 2>/dev/null. Falls through to a whole-USB snapshot only if
   # the targeted copy produced no files at all.
   cp -r /mnt/ventoy/phase-1-windows \
         /mnt/ventoy/phase-2-arch-install \
         /mnt/ventoy/phase-3-arch-postinstall \
         /mnt/ventoy/runbook \
         /mnt/ventoy/docs \
         /mnt/ventoy/autounattend.xml \
         /mnt/ventoy/CLAUDE.md \
         /mnt/ventoy/phase-6-grow-windows.sh \
         ~/src/arch-setup@fnrhombus/ 2>/dev/null
   if [[ -z "$(ls -A ~/src/arch-setup@fnrhombus 2>/dev/null)" ]]; then
       warn "Targeted copy got nothing — falling back to a whole-USB snapshot."
       cp -r /mnt/ventoy ~/src/arch-setup-snapshot
       cd ~/src/arch-setup-snapshot
   else
       cd ~/src/arch-setup@fnrhombus
   fi
   ```

3. Start Claude in that directory:
   ```bash
   claude
   ```

4. Feed it the handoff as the first message:
   ```
   Read runbook/phase-3-handoff.md. That's the brief. Start by walking
   me through the Hyprland keybindings — I'm looking at a fresh
   Hyprland session with the end-4/illogical-impulse dotfiles and I
   don't know how to do anything yet.
   ```

   Claude will read `runbook/phase-3-handoff.md`, `docs/decisions.md`, and `CLAUDE.md` on its own and have the full context.

---

## Things that will eat time but aren't broken

- **pacstrap and yay builds look stuck** — they're not. `base-devel` pulls ~50 packages, AUR builds compile from source. Don't Ctrl-C.
- **zgenom first-login rebuild** — if postinstall's pre-build didn't fully warm the cache, your first `zsh` login will take 20 seconds. One-time.
- **end-4 installer** — asks a dozen questions. Defaults are fine.
- **fingerprint enroll** — takes 5 touches but the reader is picky about angle. If it keeps rejecting, lift fully off between touches.

## Things that are actually broken if you see them

- **"No network" during pacstrap** → wifi dropped. Reconnect, restart install.
- **systemd-boot doesn't list any entries after `bootctl list`** → reinstall with `bootctl --path=/boot install` as root.
- **SDDM loops back to login** → Hyprland is crashing. Drop to TTY, `cat ~/.local/share/hyprland/hyprland.log`. Usually a missing config include from end-4 — re-run its installer.
- **`sudo` rejects your TPM-PIN** → TPM got reset or the PIN index was evicted. Re-run `sudo pinutil setup`. Password still works as fallback.

---

## First-boot failure modes (will it all actually come up?)

These are the failure modes most likely to hit on the very first boot after `install.sh` reboots. Each has a recovery path that assumes you have the Ventoy USB handy.

### A. Kernel panic: "Cannot open root device" / "VFS: Unable to mount root fs"

**Cause:** btrfs module didn't make it into the initramfs, so the kernel boots but can't read `/`. `chroot.sh` now forces `MODULES=(btrfs)` in `/etc/mkinitcpio.conf` — but if that line got overridden or mkinitcpio threw a warning you ignored, this is what you see.

**Fix:** Boot the Ventoy USB → Arch ISO → live environment. Then:
```bash
# Unlock the LUKS container first — /dev/disk/by-label/ArchRoot is the btrfs
# label inside LUKS, so it only appears after `cryptsetup open`. Use the
# raw partition via PARTLABEL (set by install.sh sgdisk).
cryptsetup open /dev/disk/by-partlabel/ArchRoot cryptroot
# Prompt for the LUKS passphrase (the one from Phase 2d / Bitwarden).
mount -o subvol=@ /dev/mapper/cryptroot /mnt
# Find the EFI partition by GPT type GUID — Windows diskpart doesn't
# assign a PARTLABEL, so by-partlabel lookups are unreliable.
EFI=$(lsblk -rno NAME,PARTTYPE | awk '$2=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"{print "/dev/"$1; exit}')
mount "$EFI" /mnt/boot
arch-chroot /mnt
grep -q '^MODULES=(btrfs)' /etc/mkinitcpio.conf || sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
mkinitcpio -P
exit
umount -R /mnt
cryptsetup close cryptroot
reboot
```

### B. Emergency shell at boot: "Dependency failed for /var/log"

**Cause:** The `/var/log` and `/var/cache` bind mounts race the ext4 mount at `/mnt/netac-var`. `install.sh` now writes `x-systemd.requires-mounts-for=/mnt/netac-var` into both fstab entries, but if the fstab-rewrite step silently skipped (look for `[!] fstab post-process failed` in install output), the ordering won't be there.

**Fix (from the emergency shell at boot):**
```bash
# Log in as root (password you set in chroot).
mount -o remount,rw /
vim /etc/fstab   # or `vi` — nano is NOT installed, only vim and helix are pacstrapped
# Find the two lines whose target is /var/log and /var/cache.
# In their options column (4th column), append:
#   ,x-systemd.requires-mounts-for=/mnt/netac-var
# Save with :wq
systemctl daemon-reload
reboot
```
If editing fstab from emergency mode is scary: add `systemd.unit=rescue.target` to the kernel command line in systemd-boot (press `e` on the Arch entry at boot, append to `options=`), which gives a full single-user shell with `/` writable.

### C. BitLocker recovery prompt on next Windows boot (and keeps prompting)

**First prompt is expected, not a failure.** systemd-boot installing itself to the shared EFI rewrites the PCR values the TPM sealed BitLocker against. First Windows boot after Arch install → blue "Enter recovery key" screen. Type the 48-digit key (stored in Bitwarden as "Inspiron BitLocker recovery" per Phase 1 step 7) to get in.

**But Windows does NOT auto-reseal the TPM protector just because you entered the recovery key** — that path unlocks the drive but leaves the TPM protector sealed against the *old* (pre-Arch) PCRs. So the next boot, and the next, and the next will all keep prompting unless you force a re-seal.

**Fix (elevated PowerShell, after you've unlocked into Windows with the recovery key):**

```powershell
# 1. Sanity-check Fast Startup is OFF (we disable it via autounattend, but confirm
#    — resume-from-hibernate shuffles PCRs and would re-break the seal on every wake).
#    Fast Startup requires hibernation; if hibernation is off, Fast Startup is off too.
powercfg /a
#    Look for "Hibernation has not been enabled" in the NOT-available section.
#    DO NOT grep for "hybrid" — that matches "Hybrid Sleep", a different feature.
#    Definitive registry check (0 = off = good, 1 = on, missing = hiberation off):
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
# If Fast Startup is on, disable it first:
#   powercfg /h off

# 2. Suspend BitLocker until manually re-enabled. Data stays encrypted; the unlock
#    key is stored in clear on disk temporarily. -RebootCount 0 means "stay
#    suspended until I say so" (not "0 reboots remaining").
manage-bde -protectors -disable C: -RebootCount 0

# 3. Reboot. No BitLocker prompt this time (protection suspended).
shutdown /r /t 0

# 4. Back in Windows, re-enable. This re-seals the TPM protector against
#    *current* PCR values (i.e. the new systemd-boot → WBM → Windows chain).
manage-bde -protectors -enable C:

# 5. Confirm: TPM protector should show as "Enabled" again.
manage-bde -protectors -get C:
```

After that, every subsequent boot unlocks via TPM silently. The boot chain needs to stay stable for this to hold — if something later changes it (systemd-boot update rewriting its EFI binary, Windows update replacing the boot manager, firmware update changing Secure Boot state), you'll get prompted once more and have to run the same dance.

**Nuclear option: turn BitLocker off.** You already have LUKS on the Linux side. If your Windows partition doesn't need encryption-at-rest (home dev laptop, not regulated-device territory), decrypting removes the entire class of problem:

```powershell
manage-bde -off C:         # background decryption, ~30-60 min for 160 GB
manage-bde -status C:      # watch progress
```

Trade-off: stolen laptop + removed drive + NTFS reader = your Windows files are readable.

### D. Hostname shows as `Metis` on the network, not `inspiron`

**Cause:** Windows unattend names the machine `Metis`, Arch's `chroot.sh` names it `inspiron`. Both are correct for their respective OS — they just don't match. Your router's DHCP lease will show whichever OS booted most recently.

**This is cosmetic.** If you care: edit `/etc/hostname` in Arch to `Metis` (and the `127.0.1.1` line in `/etc/hosts`), or change Windows via `Rename-Computer -NewName inspiron -Restart` from an elevated PowerShell. Neither change is required for anything to work.

### E. Snapper complains `config "root" does not exist` or `.snapshots not found`

**Cause:** `postinstall.sh` skips `snapper -c root create-config /` (which would try to re-create an already-mounted `/.snapshots` subvolume) and writes the config by hand. If that hand-write was skipped — e.g., `postinstall.sh` was re-run after partial state — you're missing the config.

**Fix:**
```bash
sudo install -d -m 750 /etc/snapper/configs
sudo cp /etc/snapper/config-templates/default /etc/snapper/configs/root
sudo sed -i 's|^SUBVOLUME=.*|SUBVOLUME="/"|;s|^ALLOW_USERS=.*|ALLOW_USERS="tom"|' /etc/snapper/configs/root
# Guard against double-append if you're re-running this:
grep -q '^SNAPPER_CONFIGS=.*root' /etc/conf.d/snapper 2>/dev/null || \
  echo 'SNAPPER_CONFIGS="root"' | sudo tee -a /etc/conf.d/snapper
sudo chown :tom /.snapshots 2>/dev/null || true
sudo chmod 750 /.snapshots
sudo snapper -c root create --description "manual baseline"
```

### F. Bluetooth doesn't auto-enable after reboot

**Cause:** The AutoEnable sed rewriters in `chroot.sh` all silently no-op'd (a distro change in `/etc/bluetooth/main.conf` defaults would do it). There's now a final `>>` append fallback, but if the config file didn't exist at all when chroot.sh ran, the whole `if` block was skipped.

**Fix:**
```bash
sudo tee -a /etc/bluetooth/main.conf >/dev/null <<EOF

[Policy]
AutoEnable=true
EOF
sudo systemctl restart bluetooth
```

### G. Can't get back into Windows from the Arch systemd-boot menu

**Cause:** Windows Boot Manager didn't auto-register with systemd-boot. Check `bootctl list` — if you don't see `title: Windows Boot Manager`, the `\EFI\Microsoft\Boot\bootmgfw.efi` file is missing or wasn't detected.

**Fix:** Reboot, hit F12 at the Dell logo, pick "Windows Boot Manager" directly from the firmware menu. From inside Windows, re-run Arch's `bootctl` from a live USB later to re-register. You are not stuck — both OSes are still bootable via F12.

### H. SDDM shows but fingerprint prompt never appears at login

SDDM login doesn't use fingerprint by default — it's wired for **sudo/polkit/hyprlock** only. Type your password at SDDM. Fingerprint kicks in the first time you `sudo` after login.

### I. `sudo` fails with "PAM module not found" — you're locked out of root

**Cause:** If `pinpam-git` failed to install but `postinstall.sh`'s PAM wiring ran anyway (or vice versa), `/etc/pam.d/sudo` references a `pam_pinpam.so` module that doesn't exist on disk. Same for `pam_fprintd.so` if fprintd was uninstalled. PAM's error mode for a missing module is to **fail the entire auth stack**, not fall through — which means your password won't work either. You are hard-locked.

**Fix — from the Ventoy USB Arch live environment:**
```bash
# Boot Ventoy → Arch ISO → live env → connect wifi.
cryptsetup open /dev/disk/by-partlabel/ArchRoot cryptroot   # LUKS passphrase
mount -o subvol=@ /dev/mapper/cryptroot /mnt
arch-chroot /mnt

# Strip every non-standard auth line from /etc/pam.d/sudo back to defaults.
cat > /etc/pam.d/sudo <<'EOF'
#%PAM-1.0
auth       include      system-auth
account    include      system-auth
session    include      system-auth
EOF
exit
umount -R /mnt; cryptsetup close cryptroot
reboot
```
After reboot, `sudo` takes your **password** (TPM-PIN + fingerprint are gone until you re-wire PAM). Fix the missing module: reinstall `pinpam-git` or `fprintd`, then re-run the PAM wiring blocks from `postinstall.sh` by hand.

**Prevention:** after `postinstall.sh` finishes, always test sudo from a **second** terminal before closing the one you ran the script in. If sudo fails, you can fix PAM from the still-privileged parent session without rebooting.

**Sibling issue — locked out of SDDM login:** the same kind of break can hit `/etc/pam.d/sddm` (if postinstall added a `pam_fprintd.so` line and fprintd is missing). Symptom: SDDM rejects every password. Recovery is identical to the sudo case — boot the Ventoy USB → Arch live → unlock LUKS → chroot → restore the file:
```bash
cryptsetup open /dev/disk/by-partlabel/ArchRoot cryptroot   # LUKS passphrase
mount -o subvol=@ /dev/mapper/cryptroot /mnt
arch-chroot /mnt
cat > /etc/pam.d/sddm <<'EOF'
#%PAM-1.0
auth       include      system-login
account    include      system-login
password   include      system-login
session    include      system-login
EOF
exit
umount -R /mnt; cryptsetup close cryptroot
reboot
```
Password login returns; re-wire fingerprint after you've reinstalled fprintd.

### J. `ssh-add -l` returns "error fetching identities" in every new shell

**Cause:** Bitwarden desktop isn't running, OR Bitwarden's SSH-agent toggle is off, OR the socket moved. `~/.zshrc.d/bitwarden-ssh-agent.zsh` only exports `SSH_AUTH_SOCK` if the socket file exists, so if the socket is gone, `ssh-add` talks to no agent and errors.

**Fix:**
1. Check the socket exists: `ls -l ~/.bitwarden-ssh-agent.sock`
2. If missing: launch Bitwarden desktop, unlock, Settings → SSH agent → toggle on. Quit and reopen a terminal.
3. If present but `ssh-add -l` still errors: `SSH_AUTH_SOCK=~/.bitwarden-ssh-agent.sock ssh-add -l` to rule out an env issue.
4. If the SSH-signing planter at `~/.zshrc.d/arch-ssh-signing.zsh` was never deleted, it will try again on each login — once Bitwarden is back online with at least one "SSH key" vault item, the planter fires and self-deletes.

### K-pre. end-4 dots-hyprland clone failed in postinstall

**Cause:** `postinstall.sh` clones `https://github.com/end-4/dots-hyprland.git` at step 13. If network dropped or GitHub rate-limited you, the clone fails and postinstall prints a retry hint. Everything else in postinstall already succeeded — you just don't have dotfiles yet.

**Fix:**
```bash
GIT_TEMPLATE_DIR="" git clone --depth 1 https://github.com/end-4/dots-hyprland.git ~/dotfiles/dots-hyprland
cd ~/dotfiles/dots-hyprland
./install.sh                          # interactive; accept defaults
```
Re-login (or `Super+Shift+R` to reload Hyprland) once the installer finishes.

### L-nvidia. NVIDIA modules load despite the blacklist (screen tearing, GBM errors)

**Cause:** `/etc/modprobe.d/blacklist-nvidia.conf` is written but the modules are already baked into the initramfs, OR a kernel upgrade pulled them back in.

**Fix:**
```bash
# Verify the blacklist file exists and has the expected lines:
cat /etc/modprobe.d/blacklist-nvidia.conf
# Expected: blacklist nouveau / blacklist nvidia / blacklist nvidia_drm / etc.
# Rebuild the initramfs for all kernels so the blacklist takes effect at boot:
sudo mkinitcpio -P
# Confirm no NVIDIA modules are loaded after reboot:
lsmod | grep -iE 'nvidia|nouveau'     # expect empty output
```
If modules still load: check `/etc/mkinitcpio.conf` — `MODULES=(btrfs)` should NOT contain `nvidia` or `nouveau`. Check `/etc/modules-load.d/` for any file forcing them.

### M-luks. LUKS prompt rejects your passphrase at boot

**Cause:** Most likely you fat-fingered it during Phase 2d (same failure mode as the account passwords below — the `prompt_luks` helper in `install.sh` only confirms against its own re-entry, never against reality). Less likely: initramfs keyboard layout is wrong, so a symbol you're typing is different from what the kernel receives.

**Fix (still have the passphrase in Bitwarden, typo was at install time):** you don't — if both copies were typed wrong identically, the LUKS header's slot 0 holds that typo as the real passphrase. Continue reading — there's no magic recovery.

**Fix (typo at install, no backup):** boot the Ventoy USB → Arch ISO → live env. The Samsung data is unreachable without the passphrase. Full reinstall is the only path — re-run Phase 2 with the corrected passphrase, being careful to type it slowly both times.

**Fix (passphrase is correct, layout issue):** at the LUKS prompt, try typing slowly. If your passphrase contains symbols (`!@#$%^&*`), the initramfs may be using a US layout even if your physical keyboard is something else. Workaround: reinstall with a passphrase that's ASCII letters + digits only until SDDM, then change it later with `sudo cryptsetup luksChangeKey /dev/disk/by-partlabel/ArchRoot`.

**Preventive note for re-running Phase 2:** `install.sh` enforces an 8+ character minimum and re-prompts on mismatch, but it cannot catch a consistent typo. Type slowly; verify against Bitwarden before hitting Enter the second time.

### N-luks. TPM autounlock didn't kick in — still getting the passphrase prompt every boot

**Cause:** One of three things:
1. `postinstall.sh` skipped the TPM enrollment block (no `/dev/tpm0`, or `SKIP_TPM_LUKS=1` was set).
2. Enrollment succeeded but the PCR values the TPM sealed against have drifted — a firmware update, Secure Boot state change, or bootloader swap between enrollment and now will all do this.
3. The LUKS crypttab entry is missing `tpm2-device=auto` (older `chroot.sh` runs).

**Check:**
```bash
# Is there a tpm2 slot?
sudo systemd-cryptenroll /dev/disk/by-partlabel/ArchRoot
# Expect to see a row with TYPE=tpm2. If only "password", enrollment didn't happen.

# Is crypttab.initramfs asking for TPM?
grep tpm2-device /etc/crypttab.initramfs
# Expect: ...luks,discard,tpm2-device=auto
```

**Fix (no tpm2 slot):** re-run the enrollment manually:
```bash
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/disk/by-partlabel/ArchRoot
# Type the LUKS passphrase when prompted; new slot added.
sudo reboot
```

**Fix (PCR drift):** unenroll the stale slot, re-enroll against current PCRs:
```bash
sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/ArchRoot
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/disk/by-partlabel/ArchRoot
sudo reboot
```

**Fix (crypttab missing option):**
```bash
sudo sed -i 's/luks,discard$/luks,discard,tpm2-device=auto/' /etc/crypttab.initramfs
sudo mkinitcpio -P
sudo reboot
```

If TPM enrollment keeps failing entirely, not a blocker — the passphrase path works forever. You type ~6 chars extra per boot; that's it.

### K. "Login incorrect" at SDDM / first TTY — you fat-fingered `tom`'s password at the install prompt

**Cause:** `install.sh`'s `prompt_password` accepts any entry that matches its own confirmation. If you typed the same wrong password twice, it hashed that wrong password via `openssl passwd -6` and handed it to `chroot.sh`, which applied it with `chpasswd -e`. No interactive validation ever happened. Same goes for `root`.

**Fix — from the Ventoy USB Arch live environment:**
```bash
# Boot Ventoy → Arch ISO → live env.
cryptsetup open /dev/disk/by-partlabel/ArchRoot cryptroot   # LUKS passphrase
mount -o subvol=@ /dev/mapper/cryptroot /mnt
arch-chroot /mnt
passwd tom        # set a new one
passwd            # while you're here, reset root too if needed
exit
umount -R /mnt
cryptsetup close cryptroot
reboot
```
No other state needs resetting — PAM, keyring, and Bitwarden are all keyed off the new password automatically from the next login.

---

## Recovery

- **Primary recovery**: boot the Ventoy USB, pick the Arch ISO → live environment with `pacstrap`, `arch-chroot`, etc.
- **Secondary recovery**: the Netac has the Arch ISO dd'd onto partition 1. It's not auto-discovered by systemd-boot (systemd-boot can't chain-load a raw ISO partition). To use it, boot into Dell F12 boot menu and pick the Netac's EFI entry — the ISO's own bootloader takes over. So: same live environment, without needing the USB.
- **Full reinstall**: boot USB → Arch ISO → re-run `install.sh`. It's size-gated and will abort if anything looks off, so you can't accidentally double-wipe.

## Package-name drift (AUR)

If any `yay -S` call in `postinstall.sh` fails with "package not found", the AUR name changed. Search with `yay -Ss <partial>` and substitute. The likely-drifters:
- `bitwarden` (sometimes `bitwarden-desktop`)
- `bitwarden-cli` (stable)
- `pinpam-git` (could be `pinpam` if it ever reaches stable)
- `catppuccin-sddm-theme-mocha` (rename-prone)
- `hyprshot` (check `hyprshot-git` from AUR if the stable name disappears)

Re-run `postinstall.sh` after fixing — it's idempotent.
