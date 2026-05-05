---
name: RTL8723BE ASPM AER storm
description: Default ASPM on the RTL8723BE Wi-Fi card flaps and floods correctable PCIe AER errors at ~50-150k/sec, pinning a CPU core. Fix is `options rtl8723be aspm=0`.
type: project
---

The Realtek RTL8723BE Wi-Fi card on the Inspiron 7786 (`10ec:b723` behind Cannon Point root port `8086:9db1` at PCI `00:1d.0`) flaps L0s/L1 ASPM state transitions, generating sustained correctable PCIe RxErrs that fire the aerdrv IRQ at 50-150k/sec.

**Symptoms:**
- `irq/121-aerdrv` pinned at 40-50% CPU on one core throughout the session.
- `cat /proc/interrupts | awk '/^\s*121:/{...}'` shows tens-of-thousands-per-second deltas.
- `journalctl -k` floods `pcieport 0000:00:1d.0: PCIe Bus Error: severity=Correctable, type=Physical Layer ... RxErr (First)` with `aer_ratelimit: NNNNN callbacks suppressed` lines (the AER reports get rate-limited but the IRQs keep firing).
- Long-tail effect: combined with other CPU consumers (qemu VM, browser tabs), the system becomes one bad fork-exec away from feeling hung — keypresses lag, exec'd processes stall on startup. Suspect this in any otherwise-unexplained "Hyprland feels frozen" report on this hardware.
- `cat /sys/bus/pci/devices/0000:00:1d.0/aer_dev_correctable` shows the running RxErr counter (`TOTAL_ERR_COR`).

**Why:** The card's default ASPM behavior on this Cannon Point root port doesn't negotiate the L0s/L1 exit cleanly, so the receiver sees junk symbols on every state transition. The link auto-corrects (it's a *correctable* error class) but each event raises a kernel interrupt.

**How to apply:**
- Live system fix: `/etc/modprobe.d/rtl8723be.conf` contains `options rtl8723be aspm=0 ant_sel=2 fwlps=N ips=N`. After writing, `modprobe -r rtl8723be && modprobe rtl8723be`.
- Reinstall reproducibility: same heredoc lives in `phase-2-arch-install/chroot.sh` right after the blacklist-nvidia.conf block, so a fresh install gets the fix from first boot.
- Diagnostic-only confirmation (no module reload needed): `setpci -s 00:1d.0 CAP_EXP+10.b=0:3 && setpci -s 02:00.0 CAP_EXP+10.b=0:3` clears ASPMC bits on both ends; storm rate drops from steady-state to 0/sec instantly. Useful for proving ASPM is the cause without touching modprobe.
- `ant_sel=2 fwlps=N ips=N` are kept defensively (canonical RTL8723BE stability config in many forum threads) but were *not* what fixed the AER storm — verified empirically: setting only those left the rate at 58k/sec; adding `aspm=0` took it to 0.
- `pcie_aspm=off` on the kernel cmdline would also work (kernel-wide hammer); not used because the targeted module option is sufficient.
