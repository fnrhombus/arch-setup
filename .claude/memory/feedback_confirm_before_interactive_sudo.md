---
name: Confirm before interactive sudo
description: notify-send isn't enough — explicitly ask "ready?" before any sudo that needs the user's swipe/type, and tell them which input is wanted
type: feedback
originSessionId: b7a5587e-d509-4813-a5ae-ca9888755067
---
Before running any sudo (or any other command) that needs the user's interactive auth — finger swipe, PIN, password — **stop and ask for explicit confirmation first**, not just a notify-send. State which input you want them to use ("swipe finger" vs "type password" vs "type PIN") so they know what the test is checking.

**Why:** notify-send fires on every sudo and the user can't tell from the notification alone whether they should respond, what input you want, or which step of a multi-step test they're on. Earlier in 2026-05-05 I batched smoke tests for the new PAM stack and the user was getting auth prompts without knowing which test was active or whether to swipe vs type.

**How to apply:**
- For setup actions (install, copy, etc.) where the input doesn't matter: notify-send is enough; user can use their preferred method.
- For tests where the input *is the variable being tested* (e.g. "does the password fallback work"): ask before each one. "Ready for test N? Type your password (don't swipe)."
- For multi-step interactive sequences: confirm the user is at the keyboard and knows the order before starting.
- For long-running batches that fire multiple sudo prompts: pause between them, or batch all auth into one upfront `sudo -v` if the test design allows.
