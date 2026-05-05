#!/usr/bin/env zsh
# arch: one-time bw+gh login (self-deleting). Skipped during postinstall's
# own zgenom warmup (which sources this file too) so the script doesn't
# block waiting for a browser-based gh auth flow it can't complete.
if [[ -n "${_POSTINSTALL_NONINTERACTIVE:-}" ]]; then
    return 0
fi
if [[ -t 0 ]]; then
  if command -v bw &>/dev/null && ! bw login --check &>/dev/null; then
    echo ""
    echo "=== arch: Bitwarden CLI login (for secrets scripting) ==="
    bw login || true
  fi
  if command -v gh &>/dev/null && ! gh auth status &>/dev/null; then
    echo ""
    echo "=== arch: GitHub auth ==="
    gh auth login || true
  fi
  if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    _gh_user=$(gh api user --jq '.login' 2>/dev/null) || _gh_user=""
    _gh_id=$(gh api user --jq '.id' 2>/dev/null) || _gh_id=""
    if [[ -n "$_gh_user" && -n "$_gh_id" ]]; then
      _gh_email="${_gh_id}+${_gh_user}@users.noreply.github.com"
      # Surgical update via `git config --file` — do NOT `cat > ~/.gitconfig.local`;
      # that would wipe the SSH-signing block ssh-signing.sh appends.
      touch ~/.gitconfig.local
      git config --file ~/.gitconfig.local user.name  "$_gh_user"
      git config --file ~/.gitconfig.local user.email "$_gh_email"
      echo "arch: git identity = ${_gh_user} <${_gh_email}>"
    fi
    unset _gh_user _gh_id _gh_email
    rm -f ~/.local/share/arch-setup-bootstraps/first-login.sh
  fi
fi
