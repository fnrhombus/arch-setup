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
