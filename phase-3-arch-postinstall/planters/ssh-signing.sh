#!/usr/bin/env zsh
# arch: wait for Bitwarden SSH agent to expose a key, then wire git signing (self-deleting)
# Skipped during postinstall's own zgenom warmup — see first-login.sh.
if [[ -n "${_POSTINSTALL_NONINTERACTIVE:-}" ]]; then
    return 0
fi
# Explicitly set SSH_AUTH_SOCK to the Bitwarden socket here (rather than rely
# on .zshrc.d load order) so we never wire signing to the wrong agent's key
# if some future drop-in sets a competing SSH_AUTH_SOCK first.
if [[ -t 0 ]] && command -v gh &>/dev/null && gh auth status &>/dev/null \
   && [[ -S "$HOME/.bitwarden-ssh-agent.sock" ]]; then
  _pubkey=$(SSH_AUTH_SOCK="$HOME/.bitwarden-ssh-agent.sock" ssh-add -L 2>/dev/null | head -1)
  if [[ "$_pubkey" == ssh-* ]]; then
    _gh_user=$(gh api user --jq '.login' 2>/dev/null) || _gh_user=""
    _gh_id=$(gh api user --jq '.id' 2>/dev/null) || _gh_id=""
    if [[ -n "$_gh_user" && -n "$_gh_id" ]]; then
      _gh_email="${_gh_id}+${_gh_user}@users.noreply.github.com"
      echo "${_gh_email} ${_pubkey}" > ~/.ssh/allowed_signers
      # Append signing stanza if not already present
      if ! grep -q 'gpgsign = true' ~/.gitconfig.local 2>/dev/null; then
        cat >> ~/.gitconfig.local <<'GITEOF'
[gpg]
    format = ssh
[gpg "ssh"]
    allowedSignersFile = ~/.ssh/allowed_signers
    defaultKeyCommand = ssh-add -L
[commit]
    gpgsign = true
[tag]
    gpgsign = true
GITEOF
      fi
      _tmp=$(mktemp); printf '%s\n' "$_pubkey" > "$_tmp"
      # $HOST is a zsh built-in; fall back to /etc/hostname or "arch" if for
      # some reason it's not set. Avoids a hard dep on inetutils' `hostname`
      # binary (which arch-setup §1 installs but isn't guaranteed everywhere).
      _hn="${HOST:-$(cat /etc/hostname 2>/dev/null || echo arch)}"
      gh ssh-key add "$_tmp" --title "${_hn} - arch" --type authentication 2>/dev/null || true
      gh ssh-key add "$_tmp" --type signing 2>/dev/null || true
      rm -f "$_tmp"
      echo "arch: wired SSH signing with pubkey from Bitwarden SSH agent."
      rm -f ~/.local/share/arch-setup-bootstraps/ssh-signing.sh
    fi
    unset _gh_user _gh_id _gh_email _tmp
  fi
  unset _pubkey
fi
