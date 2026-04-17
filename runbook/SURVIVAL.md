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

If the password doesn't work, the `tom` account got scrambled. Boot the recovery partition (Netac), `arch-chroot /mnt/samsung-root` (adjust path to match your actual mount), `passwd tom`, reboot.

## 3. Get on the network

### Wi-Fi (iwd / iwctl)

The install uses `iwd`, not `NetworkManager` or `wpa_supplicant`. Commands:

```bash
# Interactive shell
iwctl

# Inside iwctl:
device list                          # find your adapter (usually wlan0)
station wlan0 scan
station wlan0 get-networks           # shows SSIDs
station wlan0 connect <YourSSID>     # prompts for password
exit
```

Sanity-check:
```bash
ip -brief address                    # should show an IP on wlan0
ping -c 2 1.1.1.1                    # network works
ping -c 2 archlinux.org              # DNS works
```

### Ethernet (via DisplayLink dock)

Plug the dock in. It "just works" on Linux — the network adapter is a standard USB NIC, no DisplayLink driver needed. Check with `ip -brief address`.

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

1. Boot the **Arch recovery entry** (on the Netac — systemd-boot has an entry for it; arrow down at the menu).
2. If systemd-boot itself is gone, boot the **Ventoy USB** → Arch live ISO.
3. From the live environment:
   ```bash
   mount /dev/disk/by-label/archroot /mnt
   mount /dev/disk/by-partlabel/EFI /mnt/efi
   arch-chroot /mnt
   bootctl install                  # reinstalls systemd-boot to the ESP
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
| `iwctl`    | Wi-Fi control |
| `nmtui`    | *Not installed* — uses `iwd` only, no NetworkManager |
| `journalctl` | Read systemd logs |
| `systemctl` | Start/stop/restart services (SDDM, NetworkManager-less) |
| `claude`   | Claude Code |
| `helix` / `hx` | Terminal editor |
| `tmux`     | Sessions / splits in a single TTY |
| `btop`     | Live system monitor |
| `curl`, `wget`, `gh` | Network tooling |
| `pacman`   | Package manager (`sudo pacman -S <pkg>`) |

If you need a browser from a TTY and Claude can't solve it: `sudo pacman -S w3m` (text browser) or boot into the recovery partition to get X11 + a real browser.
