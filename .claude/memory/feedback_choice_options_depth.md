---
name: choice options need depth + hidden constraints
description: When offering options via AskUserQuestion for a real decision, surface likely-hidden constraints (cost, license, maturity) up front and give enough comparative depth — labels + descriptions alone are often not enough.
type: feedback
originSessionId: 1dadf963-e3fc-4373-a96d-63ea923a729d
---
When presenting decision options via AskUserQuestion, don't stop at concise labels and one-line descriptions. Provide enough comparative depth that the user can evaluate trade-offs without doing their own research. Use the `preview` field for concrete comparison (table-like layout, cost/maturity/dependencies, what each option actually means in practice).

Up front, also surface constraints the user is likely to filter on but didn't state: cost / license, maturity / production-readiness, runtime dependencies, ecosystem fit. They may have a hard constraint they didn't mention.

**Why:** On 2026-05-03 the user rejected an initial 4-option AskUserQuestion ("which Google Drive client?") with "that's not enough info for me to choose. it must be free." — a hidden constraint (free) and a depth complaint in one message. The follow-up with previews showing offline behavior, sync model, disk usage, status, and Hyprland fit landed on the first try.

**How to apply:** When the choice has real engineering trade-offs (sync model, performance, license, beta vs stable), use `preview` blocks with comparative attributes. When it's a simple preference (color, name), labels are fine. Err on the side of more depth for technical infrastructure choices.
