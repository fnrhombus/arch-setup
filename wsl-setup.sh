#!/bin/bash
set -e

# Fix wsl.conf
cat > /etc/wsl.conf << 'EOF'
[user]
default=tom

[boot]
systemd=true

[interop]
appendWindowsPath=false
EOF

echo "=== wsl.conf updated ==="
cat /etc/wsl.conf
