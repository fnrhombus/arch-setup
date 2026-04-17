# SURVIVAL.md — if the desktop is broken

**This is the "get back to Claude" card.** The normal plan is: Claude Code teaches you everything from inside a working Hyprland session. This doc is for the case where that session isn't there — SDDM didn't come up, Hyprland crashed, a package broke the GUI, whatever.

Goal: get to a shell, get online, start Claude, let Claude diagnose.

If you can't boot Arch at all, skip to **§6 — nuclear options**.

---

## 1. Get to a text console (TTY)

If you see a black screen, a graphical boot loop, a frozen SDDM login, or anything you can't type into:

- **Press `Ctrl + Alt + F3`** (try F2, F4, F5, F6 if F3 is blank).
- You should get a plain login prompt:
  ```
  archlinux login:
  ```

If there's no response at all — the kernel or firmware wedged. Hold power **10 seconds**, power back on, at the systemd-boot menu pick a different entry (older kernel if you have one, or the Arch recovery partition on the Netac). Retry `Ctrl+Alt+F3` once it's up.

## 2. Log in

```
archlinux login: tom
Password: <the password you set during phase 2>
```

If the password doesn't work, the `tom` account got scrambled. Boot the Netac recovery entry (Arch live ISO), then:

```bash
mount -o subvol=@ /dev/disk/by-label/ArchRoot /mnt
arch-chroot /mnt
passwd tom
exit
umount -R /mnt
reboot
```

## 3. Get on the network

The booted system uses **NetworkManager** (with `iwd` as its Wi-Fi backend). Use `nmtui` from a TTY — it's the text UI that comes with NetworkManager.

### Wi-Fi

```bash
nmtui                                # full-screen TUI; pick "Activate a connection"
# or one-liner:
nmcli device wifi connect <YourSSID> password <YourPSK>
```

Sanity-check:
```bash
nmcli device status                  # devices + which are connected
ip -brief address                    # should show an IP on wlan0
ping -c 2 1.1.1.1                    # network works
ping -c 2 archlinux.org              # DNS works
```

### Ethernet (via DisplayLink dock)

Plug the dock in. It "just works" — the NIC is a generic USB Ethernet, no DisplayLink driver needed. NetworkManager picks it up automatically. Verify with `ip -brief address`.

### If NetworkManager itself is dead

Only as a last resort — stop NM and drive `iwd` directly:
```bash
sudo systemctl stop NetworkManager
sudo systemctl start iwd
iwctl                                # see §"Wi-Fi (iwctl fallback)" below
```

### Wi-Fi (iwctl fallback — only from the live ISO, or after stopping NM)

```bash
iwctl
# inside:
device list
station wlan0 scan
station wlan0 get-networks
station wlan0 connect <YourSSID>
exit
```

## 4. Start Claude

Claude Code is installed globally via `npm` (managed by `mise`). From any TTY login:

```bash
claude
```

If `claude: command not found`:
- `which node`  → should be a mise-shimmed path under `~/.local/share/mise/`.
- `npm list -g --depth=0`  → should show `@anthropic-ai/claude-code`.
- Reinstall: `npm install -g @anthropic-ai/claude-code`.

Once Claude is running, **point it at this repo** (copied to `~/src/arch-setup@fnrhombus/` during phase 3):
```bash
cd ~/src/arch-setup@fnrhombus
claude
```

Tell Claude what's wrong. It has `CLAUDE.md`, `docs/decisions.md`, `runbook/phase-3-handoff.md`, and the phase scripts all available.

## 5. If Claude needs a GUI (browser auth, screenshot, etc.)

From the TTY you can try to restart the graphical stack:

```bash
sudo systemctl restart sddm         # the usual first try
```

If SDDM won't come up:
```bash
journalctl -u sddm -b -n 50         # last 50 lines of SDDM's journal this boot
```

To bypass SDDM entirely and start Hyprland by hand:
```bash
# From a TTY, not from inside a failed X/Wayland session:
Hyprland
```

If Hyprland crashes or shows a black screen, read its own log:
```bash
cat ~/.local/share/hyprland/hyprland.log | tail -100
```

## 6. Nuclear options

### Arch won't boot (systemd-boot menu missing or broken)

1. **F12 at the Dell logo** → pick the Netac's EFI boot entry directly (the recovery Arch ISO `dd`'d onto the Netac's first partition — systemd-boot can't chain-load a raw ISO partition, so it's not in the systemd-boot menu). The ISO's own bootloader takes over and gives you a live Arch environment.
2. If the Netac entry isn't in F12 either, boot the **Ventoy USB** → Arch live ISO.
3. From the live environment — the EFI lives at `/boot` on the installed system, so mount it there (matches `chroot.sh`'s `bootctl --path=/boot install`):
   ```bash
   mount -o subvol=@ /dev/disk/by-label/ArchRoot /mnt
   # Find the EFI partition — Windows diskpart doesn't set a PARTLABEL, so
   # grep by the GPT EFI type GUID instead:
   EFI=$(lsblk -rno NAME,PARTTYPE | awk '$2=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"{print "/dev/"$1; exit}')
   mount "$EFI" /mnt/boot
   arch-chroot /mnt
   bootctl --path=/boot install     # reinstalls systemd-boot to the ESP
   ```

### Samsung is physically dead

Everything on it is gone. Windows install is gone. The `/` btrfs is gone. The Netac still has its data, but it's not bootable on its own (no EFI).

- Boot Ventoy USB, re-run phases 1 → 3 after replacing the drive.
- Recovery from a **snapshot** isn't automatic yet — snapper subvolumes live on the Samsung too.

### Everything is on fire, user just wants Windows back

- Boot Ventoy USB → Windows 11 entry. It'll re-run `autounattend.xml`, which wipes the Samsung and reinstalls Windows. The Netac is left alone.

---

## Minimal CLI tools available after postinstall

You'll have these even from a naked TTY:

| Tool       | What it does |
|------------|--------------|
| `nmcli` / `nmtui` | NetworkManager CLI + TUI — the primary way to manage Wi-Fi and Ethernet |
| `iwctl`    | `iwd` client — fallback if NetworkManager is broken (stop NM first) |
| `journalctl` | Read systemd logs |
| `systemctl` | Start/stop/restart services (SDDM, NetworkManager-less) |
| `claude`   | Claude Code |
| `helix` / `hx` | Terminal editor |
| `tmux`     | Sessions / splits in a single TTY |
| `btop`     | Live system monitor |
| `curl`, `wget`, `gh` | Network tooling |
| `pacman`   | Package manager (`sudo pacman -S <pkg>`) |

If you need a browser from a TTY and Claude can't solve it: `sudo pacman -S w3m` (text browser) or boot into the recovery partition to get X11 + a real browser.
