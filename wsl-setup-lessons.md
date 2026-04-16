# WSL Setup Lessons Learned (from fnwsl)

Hard-won knowledge from building a fully automated WSL2 setup. If you're building something similar, these will save you days of debugging.

---

## MTU / TLS Failures

**Problem**: Large downloads (>10MB) fail with `SSL_read: error:0A00... decryption failed or bad record mac` or `cannot decrypt peer's message`.

**Cause**: WSL2's default MTU (1500) is too large for some network paths. Packets get fragmented and TLS records break.

**Fix**: Set MTU to 1350 on the default network interface. Must happen **before any network operations**:
```bash
iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
[ -n "$iface" ] && sudo ip link set dev "$iface" mtu 1350
```

**Critical details**:
- Do NOT hardcode `eth0` — the interface name varies (especially with mirrored networking).
- The fix must run in the **bootstrap/entrypoint script**, before git clone, apt-get, curl, or mise.
- Persist it via a boot script in wsl.conf (`command=/usr/local/bin/fix-mtu.sh`), not inline, because the interface name may change across reboots.
- Even with MTU fixed, large downloads can still fail transiently. **Always retry** network operations (apt, mise, curl).

## Git Template Errors on WSL

**Problem**: `fatal: cannot copy '/usr/share/git-core/templates/...'` during git clone. Clones appear to succeed but repos are in a broken state.

**Cause**: WSL's filesystem doesn't support some git template file operations (hooks, info/exclude copying fails due to permission mismatches between Windows/Linux).

**Fix**: Set `GIT_TEMPLATE_DIR=""` before any git clone:
```bash
GIT_TEMPLATE_DIR="" git clone https://github.com/...
```

**Where it matters**: Every git clone in the setup — bootstrap repo clone, zgenom clone, zgenom plugin clones. Apply it globally during setup, not just in one place.

## zgenom Plugin Manager

**Problem**: `zgenom ohmyzsh` and `zgenom load` silently do nothing.

**Cause**: `ZGEN_DIR` must be set **before** sourcing `zgenom.zsh`. Without it, `ZGEN_INIT` is empty and all zgenom commands are silent no-ops. The error is completely invisible.

**Fix**:
```zsh
ZGEN_DIR="${HOME}/.zgenom"
source "${ZGEN_DIR}/zgenom.zsh"
```

**Pre-building the cache**: To avoid clone errors on first interactive login, run the full plugin block during install:
```bash
GIT_TEMPLATE_DIR="" zsh -c '
  ZGEN_DIR="${HOME}/.zgenom"
  source "${ZGEN_DIR}/zgenom.zsh"
  zgenom ohmyzsh
  zgenom ohmyzsh plugins/sudo
  # ... all plugins ...
  zgenom save
'
```
Check for `~/.zgenom/init.zsh` to verify it worked. If that file doesn't exist, the pre-build failed.

**oh-my-zsh bootstrap**: `zgenom ohmyzsh` (no args) must be called before any `zgenom ohmyzsh plugins/...` — it clones the oh-my-zsh repo that plugins are loaded from.

## Bitwarden CLI

**Problem**: `bw login --raw` and `bw unlock --raw` suppress interactive prompts, causing silent hangs.

**Fix**: Use interactive commands, parse session key from output:
```bash
bw login                # interactive prompts for email/password
BW_SESSION=$(bw unlock 2>&1 | grep -oP 'export BW_SESSION="\K[^"]+')
```

**Self-hosted server**: Configure before any login:
```bash
bw config server https://your-server:port
```

**SSH key passphrase integration**: Use `bw get password "Item Name"` to fetch passphrases, feed to `ssh-add` via `SSH_ASKPASS`:
```bash
pass=$(bw get password "SSH Key")
askpass=$(mktemp)
printf '#!/bin/sh\necho "%s"\n' "$pass" > "$askpass"
chmod +x "$askpass"
SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force ssh-add ~/.ssh/id_ed25519
rm -f "$askpass"
```

## keychain (SSH Agent)

**Problem**: `keychain` prompts for SSH passphrase during shell init, before Bitwarden is available to supply it.

**Fix**: Always use `--noask` in `.zshrc`:
```bash
eval $(keychain --eval --quiet --nogui --noask ~/.ssh/id_ed25519)
```
Then handle key addition separately (via Bitwarden, first-login script, or manual `ssh-add`).

**Problem**: `mkdir: cannot create directory '~/.keychain': File exists` — keychain needs `.keychain` as a directory but something creates it as a file.

**Fix**: Guard in `.zshrc` before keychain runs:
```bash
[[ -f ~/.keychain ]] && rm -f ~/.keychain
```

## Blank Passwords in Linux

**Problem**: `chpasswd` rejects empty passwords — PAM enforces minimum password quality.

**Fix**: Use `passwd -d username` to delete the password instead of piping an empty string to `chpasswd`.

## PowerShell `exit` vs `return`

**Problem**: `exit` in a PowerShell script closes the entire terminal when run via `irm ... | iex` or `gsudo pwsh -File`.

**Fix**: Use `return` instead of `exit` throughout. For functions that need to abort the script, use `throw` (with `$ErrorActionPreference = "Stop"`).

## Passing Empty Args Through Bash

**Problem**: Empty arguments get swallowed when passed through `bash -c` with `$*`.

**Example**: `bash -c "./script.sh $*"` with args `"" "metis-wsl"` becomes `./script.sh metis-wsl` — the empty first arg disappears and `metis-wsl` becomes `$1`.

**Fix**: Use `"$@"` with proper quoting:
```bash
bash -c './script.sh "$@" < /dev/tty' -- "$@"
```

## raw.githubusercontent.com

**NEVER use it.** GitHub's raw CDN caches aggressively (5+ minutes). Pushes to `main` are not immediately reflected. Use GitHub release asset URLs instead:
```
# BAD — serves stale cached files
https://raw.githubusercontent.com/user/repo/main/script.sh

# GOOD — serves exact release artifact
https://github.com/user/repo/releases/latest/download/script.sh
```

This caused multiple debugging sessions where fixes appeared not to work because setup was still fetching old cached files.

## Windows Terminal Profiles

**Problem**: Windows Terminal auto-detects WSL distros via `source: "Windows.Terminal.Wsl"`. When a distro is renamed (export/import), Terminal creates duplicate profiles.

**Fix**: Hide auto-detected profiles, create an explicit profile:
```powershell
# Hide auto-detected
foreach ($profile in $settings.profiles.list) {
    if ($profile.source -match "Microsoft\.WSL|Windows\.Terminal\.Wsl") {
        $profile.hidden = $true
    }
}
# Create our own
$newProfile = @{
    guid = "{$([guid]::NewGuid())}"
    name = $WslName
    commandline = "wsl.exe -d $WslName"
    hidden = $false
}
```

Profiles without a `source` property are treated as user-defined — Terminal won't interfere with them.

## Docker Desktop + WSL

Docker Desktop auto-detects new WSL distros and tries to configure them immediately. During setup (especially distro rename via export/import), this causes noisy error dialogs.

**Fix**: Detect Docker and warn the user — don't try to manage Docker's lifecycle:
```powershell
if (Get-Process "Docker Desktop" -ErrorAction SilentlyContinue) {
    Write-Host "Docker Desktop is running. You may see WSL integration errors — they're harmless."
}
```

## apt-get Hash Sum Mismatch

**Problem**: `apt-get update` fails with `Hash Sum mismatch` when a mirror is mid-sync.

**Fix**: Retry with clean:
```bash
sudo apt-get update || {
    sudo apt-get clean
    sudo apt-get update
}
```

## First-Login Scripts

For setup steps that need an interactive terminal (Bitwarden login, GitHub auth), drop a self-deleting script in `~/.zshrc.d/`:
```bash
cat > ~/.zshrc.d/first-login.zsh <<'EOF'
if [[ -t 0 ]]; then
    # ... interactive setup ...
    rm -f ~/.zshrc.d/first-login.zsh
fi
EOF
```

**Key details**:
- Guard with `[[ -t 0 ]]` to ensure it's an interactive terminal.
- Don't use `/etc/profile.d/` — that's for bash login shells, not zsh.
- The `.zshrc` must source `~/.zshrc.d/` at the end: `for f in ~/.zshrc.d/*(N); do source "$f"; done`

## PowerShell Parameter Tricks

Distinguishing "not provided" from "empty string":
```powershell
param(
    $Passphrase = $null  # untyped! [string] would coerce $null to ""
)
if ($null -eq $Passphrase) {
    # not provided — prompt
} else {
    # provided (possibly empty) — use as-is
}
```

`[string]` coerces `$null` to `""`, losing the distinction. Use untyped param with `$null` default, then cast to `[string]` after the check.

## General Principles

1. **Retry everything network-related.** WSL networking is flaky. 3 attempts with a 2-second delay handles 99% of transient failures.

2. **Never assume interface names.** Use `ip route show default` to find the active interface dynamically.

3. **Test from release URLs, not from local files.** The release pipeline (sync to main, strip dev files, create release) can introduce subtle differences.

4. **`set -e` and `||` don't mix intuitively.** A command with `|| true` won't trigger `set -e`, but a command inside a function called without `||` will. Be deliberate about error handling boundaries.

5. **Pre-build everything possible during install.** First interactive login should be clean — no cloning, no compiling, no "please wait". The zgenom pre-build and mise tool installs happen during setup so the first `wsl -d name` is instant.
