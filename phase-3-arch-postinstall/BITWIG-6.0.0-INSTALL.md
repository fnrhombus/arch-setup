# Bitwig Studio 6.0.0 Installation (with bugfix jar)

## Prerequisites
- `debtap` installed (AUR package)
- `~/bak/` directory exists for backups

## Setup

1. Download the deb from official Bitwig servers:
```bash
cd /tmp
wget 'https://www.bitwig.com/dl/Bitwig%20Studio/6.0.0/installer_linux/' -O bitwig-studio-6.0.deb
```

2. Convert deb to Arch package using debtap:
```bash
debtap /tmp/bitwig-studio-6.0.deb
```
The converted package will be created in `~/.local/share/user-dirs/Downloads/bitwig-6.0.0/`

3. Uninstall any existing Bitwig and install the new package:
```bash
sudo pacman -R bitwig-studio --noconfirm 2>/dev/null || true
sudo pacman -U ~/.local/share/user-dirs/Downloads/bitwig-6.0.0/bitwig-studio-6.0.0-1-x86_64.pkg.tar.zst --noconfirm
```

4. Download and swap in the bugfix jar:
```bash
# Download bugfix jar
cd /tmp
wget 'https://www.bitwig.com/dl/Bitwig%20Studio/6.0.0/installer_linux/' -O bitwig-studio-6.0.deb
bsdtar -xOf bitwig-studio-6.0.deb | bsdtar -xf - --strip-components=3 opt/bitwig-studio/bin/bitwig.jar --to-stdout > bugfix-bitwig.jar

# Backup original and swap
sudo mv /opt/bitwig-studio/bin/bitwig.jar ~/bak/bitwig.jar.backup
sudo cp /tmp/bugfix-bitwig.jar /opt/bitwig-studio/bin/bitwig.jar
sudo chmod 644 /opt/bitwig-studio/bin/bitwig.jar
```

5. Run Bitwig:
```bash
/opt/bitwig-studio/BitwigStudio
```

## Notes
- The bugfix jar is extracted directly from the deb during installation
- Original jar is backed up to `~/bak/` for recovery if needed
