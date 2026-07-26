#!/usr/bin/env zsh
# arch: wait for Bitwarden SSH agent to expose THIS host's key, then wire git
# signing and register the key with GitHub (self-deleting, but only once every
# step has actually succeeded).
# Skipped during postinstall's own zgenom warmup — see first-login.sh.
if [[ -n "${_POSTINSTALL_NONINTERACTIVE:-}" ]]; then
    return 0
fi
# Explicitly set SSH_AUTH_SOCK to the Bitwarden socket here (rather than rely
# on .zshrc.d load order) so we never wire signing to the wrong agent's key
# if some future drop-in sets a competing SSH_AUTH_SOCK first.
# `[[ -o interactive ]]`, not `[[ -t 0 ]]`: p10k's instant-prompt
# redirects fd 0 during .zshrc init, so `-t 0` returns false in
# Ghostty/Hyprland zsh — this whole block would silently never run.
if [[ -o interactive ]] && command -v gh &>/dev/null && gh auth status &>/dev/null \
   && [[ -S "$HOME/.bitwarden-ssh-agent.sock" ]]; then
  # $HOST is a zsh built-in; fall back to /etc/hostname or "arch" if for
  # some reason it's not set. Avoids a hard dep on inetutils' `hostname`
  # binary (which arch-setup §1 installs but isn't guaranteed everywhere).
  _hn="${HOST:-$(cat /etc/hostname 2>/dev/null || echo arch)}"
  # The agent holds EVERY machine's key, so select this host's by its comment
  # instead of taking the first line. A bare `head -1` wires whichever key the
  # agent happens to list first, which on any host that doesn't sort first is
  # a different machine entirely. Comment may be the bare hostname or an fqdn.
  _pubkey=$(SSH_AUTH_SOCK="$HOME/.bitwarden-ssh-agent.sock" ssh-add -L 2>/dev/null \
            | awk -v h="${_hn:l}" 'tolower($3) == h || index(tolower($3), h ".") == 1')
  _nkeys=$(printf '%s' "$_pubkey" | grep -c '^ssh-')

  if [[ "$_nkeys" -ne 1 ]]; then
    # Zero means this host's key isn't in the vault yet; more than one means an
    # ambiguous comment. Either way, guessing risks signing as another machine,
    # so leave the planter in place and let a later login retry.
    echo "arch: ssh-signing — expected 1 agent key commented '${_hn}', found ${_nkeys}. Leaving planter for next login." >&2
  else
    _gh_user=$(gh api user --jq '.login' 2>/dev/null) || _gh_user=""
    _gh_id=$(gh api user --jq '.id' 2>/dev/null) || _gh_id=""
    if [[ -n "$_gh_user" && -n "$_gh_id" ]]; then
      _gh_email="${_gh_id}+${_gh_user}@users.noreply.github.com"
      _ok=1

      # allowed_signers is chezmoi-managed and must accumulate one line per
      # machine — every host needs every host's key to verify shared history.
      # Append if absent; never truncate, or the other hosts' keys are lost
      # until the next `chezmoi apply`.
      _keybody=$(printf '%s' "$_pubkey" | awk '{print $1" "$2}')
      if ! grep -qF "$_keybody" ~/.ssh/allowed_signers 2>/dev/null; then
        printf '%s %s\n' "$_gh_email" "$_keybody" >> ~/.ssh/allowed_signers
      fi

      # Append signing stanza if not already present
      if ! grep -q 'gpgsign = true' ~/.gitconfig.local 2>/dev/null; then
        cat >> ~/.gitconfig.local <<'GITEOF'
[gpg]
    format = ssh
[gpg "ssh"]
    allowedSignersFile = ~/.ssh/allowed_signers
[commit]
    gpgsign = true
[tag]
    gpgsign = true
GITEOF
      fi
      # Pin the key explicitly rather than leaning on `defaultKeyCommand`,
      # which git resolves by reading the FIRST line of `ssh-add -L` — the same
      # wrong-machine key the selection above exists to avoid.
      git config -f ~/.gitconfig.local user.signingKey "key::${_keybody}"

      # Register with GitHub. Both calls need token scopes that `gh auth login`
      # does not grant by default (admin:public_key, admin:ssh_signing_key);
      # without them they 404. Check the outcome rather than discarding it —
      # swallowing this is how a host ends up signing commits that every clone
      # then reports as `unknown_key`.
      _tmp=$(mktemp); printf '%s\n' "$_pubkey" > "$_tmp"
      for _type in authentication signing; do
        _out=$(gh ssh-key add "$_tmp" --title "${_hn} - arch" --type "$_type" 2>&1)
        # An already-registered key reports "key is already in use"; that is
        # the desired end state, so treat it as success.
        if [[ $? -ne 0 ]] && ! print -r -- "$_out" | grep -qi 'already'; then
          echo "arch: ssh-signing — could not add ${_type} key: ${_out}" >&2
          echo "arch:   fix with: gh auth refresh -h github.com -s admin:public_key -s admin:ssh_signing_key" >&2
          _ok=0
        fi
      done
      rm -f "$_tmp"

      if [[ "$_ok" -eq 1 ]]; then
        echo "arch: wired SSH signing for '${_hn}' and registered its key with GitHub."
        rm -f ~/.local/share/arch-setup-bootstraps/ssh-signing.sh
      else
        # Local signing is wired; only GitHub registration failed. Keep the
        # planter so the next login retries once the scopes are granted.
        echo "arch: ssh-signing — local config written, GitHub registration incomplete. Planter kept." >&2
      fi
      unset _ok _keybody _out _type
    fi
    unset _gh_user _gh_id _gh_email _tmp
  fi
  unset _pubkey _nkeys _hn
fi
