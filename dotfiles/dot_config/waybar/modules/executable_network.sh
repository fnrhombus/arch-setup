#!/usr/bin/env bash
# waybar custom module — network state via nmcli.
# Outputs JSON: {text, tooltip, class}.
# Click → nmtui (waybar config); right-click → nm-connection-editor.

set -euo pipefail

# Primary connection name + type. nmcli -t fields are tab-separated by default
# but we use ':' which `set -f` + IFS handles.
read -r name type device <<<"$(nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null \
    | head -1 \
    | awk -F: '{print $1, $2, $3}')"

if [[ -z "${name:-}" ]]; then
    printf '{"text":"  off","tooltip":"No active connection","class":"disconnected"}\n'
    exit 0
fi

case "$type" in
    802-11-wireless)
        signal=$(nmcli -t -f IN-USE,SIGNAL device wifi 2>/dev/null \
            | awk -F: '$1=="*"{print $2; exit}' || echo "")
        icon=""
        [[ -n "$signal" && "$signal" -lt 25 ]] && icon=""
        [[ -n "$signal" && "$signal" -ge 25 && "$signal" -lt 50 ]] && icon=""
        [[ -n "$signal" && "$signal" -ge 50 && "$signal" -lt 75 ]] && icon=""
        text="${icon}  ${name}"
        tooltip="WiFi: ${name} (${signal:-?}%)\nDevice: ${device}"
        class="wifi"
        ;;
    802-3-ethernet)
        text="  ${name}"
        tooltip="Ethernet: ${name}\nDevice: ${device}"
        class="wired"
        ;;
    vpn|wireguard|tun)
        text="  ${name}"
        tooltip="VPN: ${name}"
        class="vpn"
        ;;
    *)
        text="  ${name}"
        tooltip="${type}: ${name}"
        class="other"
        ;;
esac

# JSON-escape (text/tooltip may contain quotes / backslashes).
esc() { jq -Rn --arg s "$1" '$s'; }

printf '{"text":%s,"tooltip":%s,"class":"%s"}\n' \
    "$(esc "$text")" "$(esc "$tooltip")" "$class"
