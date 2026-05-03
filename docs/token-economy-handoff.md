# Token-economy handoff — what burned context this session, what could fix it

Written 2026-04-23 at the end of a long Opus 4.7 (1M context) session that
hit ~408k / 1m tokens (~41%). The session covered ~50 atomic commits
across desktop-design (decisions docs, dotfiles authoring, validation
agents, fix passes). Categorized post-mortem so a fresh session can pick
up tooling improvements before doing more long-running work in this repo.

## Where the tokens actually went

From `/context` at the end:

| Bucket | Tokens | % of context |
|---|---|---|
| Messages | 378.5k | 37.9% (94% of *used* context) |
| System tools | 14.1k | 1.4% |
| System prompt | 8.5k | 0.8% |
| Memory files | 6.1k | 0.6% |
| Project CLAUDE.md | (within memory) ~6k | — |
| Skills | 752 | 0.1% |
| Free | 559k | 55.9% |

So **almost all the cost was conversational messages**. Within that:

1. **Sub-agent reports came back full-fat** — each conflict / validation /
   research agent dumped a 3-5k-token formatted-markdown report directly
   into context. Three agents → ~12-15k tokens of agent output that I
   then summarized in my own messages. ~2x cost.
2. **Repeated `Read` of large files** — `phase-3-arch-postinstall/postinstall.sh`
   (~1300 lines) read in chunks across multiple turns. Some sections
   re-read after earlier reads got cleared from context.
3. **Big Bash outputs** — `git log --all`, `grep -rn` across docs,
   `git branch -v` etc. dumped 50-200 lines per call.
4. **Decision walkthroughs** — I picked an essay-style "explain the choice
   in markdown with a table + recommendation" pattern for each of the ~10
   small component decisions. Each response: ~600-1200 tokens. Could have
   been ~150 tokens with a tighter format.
5. **Web research duplication** — three separate validation agents fetched
   overlapping upstream docs (Hyprland wiki, matugen README, etc.).
6. **Long file writes echoed back** — every `Write` tool call returns the
   filename in the result; usually small, but with ~50 file writes it adds up.

## What would have helped (ordered by ROI)

### High-value: MCPs

1. **Sourcegraph MCP** (or any LSP-backed code-search MCP) — symbol-level
   queries instead of `Read` on the full file. Would have saved ~30k+
   tokens on the postinstall.sh re-reads + grep dumps. Highest ROI add.
   - Repo: https://github.com/sourcegraph/sourcegraph-mcp
2. **A "file-backed agent" MCP** — agent writes its full report to a file,
   returns a 200-word abstract + path. Saves ~10-15k tokens per multi-agent
   session. May need to be custom; I'm not aware of an off-the-shelf one
   that works exactly this way. (Workaround in current Claude Code: tell
   the agent in its prompt to do this — write report to `/tmp/agent-X.md`,
   return summary only.)
3. **A docs-cache MCP** — caches markdown summaries of frequently-hit
   project docs (Hyprland wiki, Arch wiki, GitHub READMEs). Three agents
   independently fetched the same Hyprland wiki pages this session.
4. **A `git-mcp` that returns structured output** — instead of CLI text
   dumps from `git log` / `git branch -v` / `git status`. Returns JSON
   that's both more compact and more parseable.

### Medium-value: agent definitions

1. **`config-validator` subagent** — input: file path + tool name + current
   spec; output: <300-word "drift report" structured as
   `{file, line, current_value, current_best, source}`. The general-purpose
   agents I dispatched returned 2-3 page reports.
2. **`decision-walker` subagent** — input: spec + question + my recommendation;
   output: <150-word "should you accept this rec? Y/N + 1 sentence".
   Would have replaced 10 essay-length response turns.
3. **`web-research-cited` subagent** — strict <500-word output, table format,
   one citation per row, no preamble. Saves 1-2k tokens per dispatch
   compared to the verbose markdown the general-purpose agent returns by
   default.

### Built-in features I underused

1. **The `Explore` agent** (already provided by this environment) for
   codebase searches. I used `Bash` + `grep` repeatedly, which dumps raw
   matches. Explore returns curated findings. Would have helped ~5-10
   times this session.
2. **Plan mode** for design phases — would have prevented mid-discussion
   file reads, kept token usage low while designing.
3. **`TaskCreate` / `TaskUpdate`** — I tracked the ~10 component decisions
   in inline message lists ("Decision 1 of 10:", "Decision 2 of 10:") and
   re-listed them in summary turns. Tasks would have kept that state out
   of message body.

### Patterns I should fix (no tooling needed)

1. **Stop re-listing context in every response** — if the user asked
   "what's next?", I summarized the whole status list. Fine first time;
   wasteful by the third.
2. **Cite file:line, not file contents** — I included full file content
   in many responses where a `path/to/file.sh:120-140` reference would
   have done. The user can `Read` if they want.
3. **Tighter markdown format for choices** — `| pick | rationale |` two-row
   table beats a paragraph + headers + sub-bullets.
4. **One commit message per logical change, not per atomic file** — I
   wrote some commit messages with 3-paragraph descriptions for
   2-line changes. Affects token-usage when commits are read back later
   in the session via `git log` outputs.

## Specific recommendations for fresh session

1. **Install Sourcegraph MCP first** before doing any more file-touching
   work in this repo — `phase-3-arch-postinstall/postinstall.sh` will
   continue to be re-read otherwise.
2. **Define 2 custom agents** in `~/.claude/agents/`:
   - `repo-syntax-validator` (max output 400 words, structured drift table)
   - `web-research-cited` (max output 500 words, table format, citations
     mandatory)
   And dispatch those instead of `general-purpose` for repeatable patterns.
3. **Use the `Explore` agent** for any "find me X across the codebase"
   query rather than Bash-grep loops.
4. **In long conversations, ask sub-agents to write reports to files** —
   include in the agent prompt: "Write your full report to
   `/tmp/agent-<descriptor>.md`. Return only a 200-word abstract + that
   file path."
5. **Plan mode for the next big design discussion** if any remain.

## What's left in flight on this branch (`desktop-design`)

Status as of this commit:

- 8 fix-list items from the validation agents:
  - swww→awww: DONE (commit `e42da09`)
  - XDPH+hyprlock+dpms-off mitigation: DONE (commit `8b049a3`)
  - .chezmoiignore for matugen paths: DONE (commit `4b8e6dd`)
  - XDPH portal pin: PENDING
  - `style=kvantum` → `style=Fusion`: PENDING
  - Bibata package split (xcursor + hyprcursor): PENDING
  - hyprexpo deprecated `enable_gesture`/etc keys removed: OBSOLETE (swapped to Hyprspace)
  - Re-dispatch syntax-validation agent for full coverage: PENDING
- One known overlap: matugen renders to `~/.config/zathura/zathurarc`,
  which is the same path chezmoi manages — needs the matugen template
  expanded to cover non-color settings too, or a different output path
  with a wrapper.
- The bigger TODO list (postinstall §13 rewrite, chroot.sh hibernate
  refactor, limine, TPM2 PCR, install.sh source-path, phase-1-iso
  bake) is captured in `docs/desktop-requirements.md` "Implementation
  notes" section.

---

# Follow-up post-mortem — 2026-05-02 ("uber-session" continuation)

Written at the end of another long Opus 4.7 (1M context) session that
covered ~15 atomic commits across two repos (arch-setup, dots) plus a
release cycle on a third (azure-ddns v0.2.2 + v0.2.3). Topics: wpws
daemon autostart, Hyprspace plugin re-load, azure-ddns AUR publish,
azure-ddns AF_NETLINK fix, tray icon wiring, Edge `DefaultBrowser`
policy, sudo-fingerprint cue discovery.

## What was actioned from the previous post-mortem (above): none

This session re-confirmed every recommendation from the 2026-04-23
post-mortem and applied **zero** of them up front:

| Prior recommendation | Status this session |
|---|---|
| Sourcegraph / LSP MCP before more `postinstall.sh` work | Not installed; postinstall.sh re-read in chunks across multiple turns again |
| File-backed subagent reports (`/tmp/agent-X.md` + abstract) | Did not do — 4 subagents returned ~12-15k tokens of full-fat reports |
| Custom agents in `~/.claude/agents/` (`repo-syntax-validator`, `web-research-cited`) | Never defined |
| Use `Explore` agent for codebase searches | Used `grep` + `Bash` instead, repeatedly |
| `TaskCreate` for tracked work | Used inline status lists |

Root cause: this doc lives in `docs/` of the arch-setup repo, with no
memory pointer. Session-start context doesn't surface it.

## What burned tokens this session, beyond the prior list

1. **Sudo-fingerprint cue discovery cycle (~3k tokens).** Sudo timed
   out → retry → bell test (silent in Ghostty) → notify-send test
   (worked) → memory write. The end state — the user's `sudonf`
   wrapper, with critical-urgency notify + auto-dismiss — already
   existed in `~/.local/bin/` but was undocumented in Claude memory.
   The session paid the full discovery cost.
2. **Inline diagnosis when subagent was the right call.** Two arcs
   that should have been delegated:
   - "no public IP" diagnosis on azure-ddns (~5 Bash + Read of
     binary + jq pipeline) → ~4k tokens inline that a subagent could
     have returned as a 1k summary.
   - Tray icon investigation (12+ tool calls, intersected with
     unrelated user questions) → another ~3-4k tokens that didn't
     need to live in main context.
3. **One-shot gotchas not memorized after discovery.** Three this
   session, each costing ~1.5-2k tokens to rediscover:
   - Hyprland exec-once silently no-ops bare command names
     (Hyprland inherits PATH from greetd, which lacks `~/.local/bin`).
   - `hyprpm enable` is a no-op when the plugin is already enabled;
     loading the `.so` requires `hyprpm reload`.
   - azure-ddns systemd unit's `RestrictAddressFamilies` was missing
     `AF_NETLINK`, breaking `ip(8)` address enumeration.
4. **Bash micro-consolidation misses.** ~10 cases where two-three
   sequential calls (`rfkill unblock` → `sleep` → `bluetoothctl
   power on`; `ip link` then `ethtool -P`; etc.) could have been one
   chained call. ~50 tokens each, ~500 tokens total.
5. **Subagent prompt overhead.** Each of the 4 subagent prompts I
   wrote was ~1-1.5k tokens (necessary because the agent has no
   prior context). For repeatable patterns this should compress
   into a slash-command + custom-agent definition.

## Updated highest-leverage actions for the next fresh session

In strict descending ROI:

1. **Write a memory pointer to this doc.** It's the single fix that
   makes every other recommendation surfaceable at session start.
   `MEMORY.md` entry: one line, link + 80-char hook.
2. **Add the file-backed-report instruction to every subagent
   prompt.** This is a copy-paste line. No tooling to install, just
   discipline:
   > "Write your full report to `/tmp/agent-<descriptor>.md`.
   > Return only a 200-word abstract + that file path."
3. **Memorize one-shot gotchas the moment they're solved.** A
   2-line memory ("Hyprland exec-once needs full path; greetd's
   inherited PATH lacks `~/.local/bin`") prevents the next
   investigation. Cost: 30 seconds. Savings: 1-2k tokens per
   recurrence.
4. **Surface user-installed tooling in memory.** If the user has
   wrappers like `sudonf` in `~/.local/bin`, those should be
   memorized so Claude reaches for them instead of building from
   scratch. Suggest: a `tools_installed.md` memory listing the
   non-obvious wrappers + their purpose.
5. **Sourcegraph MCP** — still the highest-tooling-ROI item from
   the prior post-mortem, still unactioned. Until it's installed,
   `postinstall.sh` (~1500 lines now) will continue to absorb
   ~5-10k tokens per session that touches it.
6. **Use `Explore` for cross-codebase finds.** Two specific moments
   this session would have benefited: finding `pick_ipv6` in the
   azure-ddns binary, and locating section boundaries in
   postinstall.sh. (The Explore agent is built-in; no install
   step.)

## What worked well

- **Subagent delegation for multi-step bug fixes** — 4 subagents
  collectively did ~30 minutes of work and freed my main context
  from their tool noise. This pattern should be the default for
  any investigation deeper than 3 Bash calls.
- **Atomic commits across repos.** The user's CLAUDE.md guidance to
  commit per logical change was straightforward to follow with
  small `git diff` checks before each commit.
- **Parallel reads / status checks** at the start of each
  investigation. The few times I batched diagnostic calls, results
  came back fast and consolidated.

## Specific memory entries to write before next session

1. `feedback_subagent_file_backed_reports.md` — every subagent
   prompt must include the file-backed-report directive.
2. `reference_token_economy_handoff.md` — pointer to this doc with
   summary of high-leverage actions.
3. `reference_user_tooling.md` — `sudonf`, `bwu`, `wpws`, etc.
   The wrappers the user expects Claude to know about.
4. `feedback_memorize_gotchas.md` — when a non-obvious bug is
   solved, immediately write a 2-line feedback memory before
   moving on.
