---
name: Confirm before interactive sudo
description: For setup/inspection sudo, use `sudoa` (silent). Only when user input is genuinely needed, ask "ready?" first and name the input (swipe / PIN / password) — don't just fire notify-send and proceed.
type: feedback
originSessionId: 5e82d926-12ce-46b6-b750-a8708e5ab04e
---
Default Claude-side sudo to `sudoa` (the unattended claude-askpass wrapper documented in `~/.claude/CLAUDE.linux.md` "Two sudo wrappers"). It pulls the password from Bitwarden silently — no notification, no prompt, no swipe required. That covers nearly every sudo call Claude makes (package installs, file writes, service restarts, inspections).

When the user genuinely has to authenticate interactively — a destructive change you're asking them to validate via the auth itself, or a test where the input *is* the variable being tested — **stop and ask for explicit confirmation first**. State which input you want them to use ("swipe finger" vs "type password" vs "type PIN") so they know what's being checked.

**Why:** Earlier guidance was "notify-send before sudo so the user knows to swipe." That was correct before the `sudoa` / claude-askpass / Bitwarden libsecret stack landed. Now `sudoa` makes notification spam unnecessary for the common case, and the user explicitly pushed back on stray notifications. Notify-send alone is also insufficient for genuinely interactive cases — the user can't tell from the popup alone what input is wanted or which step of a multi-step test they're on (observed during 2026-05-05 PAM-stack smoke tests).

**How to apply:**
- **Setup / inspection / install:** use `sudoa` — silent, no announcement needed.
- **Genuinely interactive (test designs auth itself, destructive validation):** ask "ready for X? Type your password (don't swipe)" or similar. One ask per round of input.
- **Multi-step interactive sequences:** confirm the user is at the keyboard and knows the order before starting.
- **Long batches with multiple interactive prompts:** pause between them, or batch all auth into one upfront `sudo -v` if the test design allows.
- **Don't** fall back to `notify-send + sudo` — leftover Critical notifications replay their sound next session and the user has explicitly asked not to see them. `sudonf` exists for the rare case where a notification cue genuinely helps; see CLAUDE.linux.md.
