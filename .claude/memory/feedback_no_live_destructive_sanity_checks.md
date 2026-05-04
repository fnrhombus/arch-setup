---
name: Don't run side-effecting commands as "sanity checks"
description: After applying a script that does live actions (window moves, file edits, network calls), do not invoke it with real args "just to check it runs" — that IS the action.
type: feedback
---

**Don't follow a script-edit with a live invocation labelled as a sanity check. If the script has side effects, the invocation IS the side effect.**

**Why:** 2026-05-03 — after editing `~/.local/bin/hypr-edge-nav`, ran `hypr-edge-nav move r` "to check rc=0" and accidentally moved the user's focused window (Claude Code) from ws6 to ws7, then pushed it to the left edge of ws7. User had to be told and the window had to be silently moved back to a non-original column.

**How to apply:**

- Sanity-checking a script means `script-name` (no args, expect usage error) or `script-name --help`. That's it.
- Calling the script with valid args means *running it*. If the script does something to the live system (moves windows, sends notifications, makes API calls, edits files, dispatches to a window manager), do not do this without explicit user permission *for that specific invocation*.
- "Apply + sanity-check" patterns are fine for pure validators / parsers. For action scripts they're a footgun.
- When verification *requires* a live action and there's no dry-run flag, ask first: "Want me to run a live test that will move the focused window?" Don't invent a "sanity check" framing that hides the side effect.
