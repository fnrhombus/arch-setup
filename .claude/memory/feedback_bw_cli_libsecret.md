---
name: bwu/bw libsecret integration pattern
description: Bitwarden CLI gets transparent unlock via gnome-keyring (libsecret). Master password seeded once, every subsequent shell silent. NOT the same as desktop "Unlock with system auth" — desktop still requires master password once per app session.
type: feedback
originSessionId: 1f608502-800c-4723-a701-24396c206988
---
When the user wants `bw <cmd>` to work without re-typing the master password every shell, the right pattern (verified working on metis 2026-04-30) is libsecret-backed.

**Why:** `bw unlock` only takes master password (no `--biometric` flag exists). The desktop app's "Unlock with system authentication" stores a *biometric key* in libsecret, not the master password — so we can't extract it from the desktop's keyring entries. The CLI needs ONE prompt to seed; after that, libsecret holds the master password and every shell is silent.

**Important distinction from desktop "Unlock with system auth"** (confirmed by user 2026-05-01): the desktop biometric flow is *not* equivalent to this CLI pattern. The desktop still requires a master-password unlock once per app session before "Unlock with system auth" becomes available — every vault lock / desktop restart re-arms that requirement. This is a deliberate Bitwarden security choice and not configurable. The CLI `bwu` pattern is genuinely "one prompt forever" (until cache wipe); the desktop is "one prompt per session". Don't promise the user that wiring system-auth on the desktop will give them silent forever-unlock.

**How to apply:**
1. `bwu()` shell function lives in `~/.zsh_aliases` (postinstall §10). It checks `secret-tool lookup service bitwarden user master`; on miss, prompts via `read -rs`, validates non-empty, stores via `secret-tool store`, then calls `bw unlock --passwordenv BW_PASSWORD --raw` and caches the session token under `service=bitwarden type=session`.
2. `bw()` wrapper function: every CLI call checks `BW_SESSION` → if missing, pulls cached session from libsecret → if vault still locked, transparently re-runs `bwu` (silent because master password is in keyring). Skipped when stdin isn't a TTY so scripts don't accidentally prompt.
3. Required for silent flow: gnome-keyring password is **empty** (auto-unlocks at login on a fingerprint-only setup; LUKS provides at-rest security).

**Wipe/rotate:** `secret-tool clear service bitwarden user master` — next `bwu` re-prompts.

**Don't suggest:**
- Auto-running `bw unlock --raw` from `.zprofile` or `.zshrc` — that prompts on every shell start, defeats the point.
- Using `BW_PASSWORD` env var hardcoded in shell rc — sits in plain text on disk.
- Reading the desktop app's biometric key — it's an encryption key, not the master password; CLI can't use it.
