#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# archiso profiledef for fnrhombus/arch-setup — a customized Arch live ISO
# that bundles this repo at /root/arch-setup so phase-2 install.sh is a
# single command away the moment you boot it.
#
# Derived from the upstream releng profile
# (https://gitlab.archlinux.org/archlinux/archiso/-/tree/master/configs/releng)
# as of archiso 87. Re-sync with upstream periodically — in particular the
# `file_permissions` block, which is fiddly to get right.

iso_name="arch-setup"
iso_label="ARCHSETUP_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="fnrhombus/arch-setup <https://github.com/fnrhombus/arch-setup>"
iso_application="Arch Linux Live ISO with fnrhombus/arch-setup preloaded"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux'
           'uefi.systemd-boot')
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')

# Permissions table. Mirrors releng with three additions for our custom
# payload:
#   - /root/arch-setup              → 750 so the repo tree under /root is
#                                     readable/writable by root inside the
#                                     live env for in-place edits.
#   - /root/.ssh + authorized_keys  → 700 / 600 so sshd accepts Callisto's
#                                     key on first boot without a chmod
#                                     dance. sshd refuses world-readable
#                                     authorized_keys files silently.
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/.gnupg"]="0:0:700"
  ["/root/.ssh"]="0:0:700"
  ["/root/.ssh/authorized_keys"]="0:0:600"
  ["/root/arch-setup"]="0:0:750"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/Installation_guide"]="0:0:755"
  ["/usr/local/bin/livecd-sound"]="0:0:755"
)
