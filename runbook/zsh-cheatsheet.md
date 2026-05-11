# zsh cheatsheet

Quick reference for the custom zsh setup. Paired with `zsh-tutorial.md` (the explainer).

---

## Keybinds

### History

| Key | Action |
|---|---|
| `↑` / `↓` | Walk history one entry at a time |
| `^P` / `^N` | **Substring search** — type a few chars first, then jump through matches |
| `^R` | fzf interactive history search |
| `!!` | Re-run last command |
| `!$` | Last arg of previous command |

### Autosuggestions (ghost text shown after cursor)

| Key | Action |
|---|---|
| `^E` *(End)* | Accept the whole suggestion |
| `Alt-F` | Accept one word of the suggestion |
| `→` / `^F` | Accept one character |
| Any keystroke | Just continue typing — suggestion stays until accepted or overwritten |

### fzf (upstream binds, `Ctrl-G` cancels any of them)

| Key | Action |
|---|---|
| `^R` | History picker |
| `^T` | File picker — pick path(s), inserts at cursor. `TAB` to multi-select. Preview: `bat` for files, `eza --tree` for dirs |
| `Alt-C` | Directory picker — pick a dir, `cd`s into it. Preview: `eza --tree` |
| `**<TAB>` | Trigger fuzzy completion on the current word (e.g. `ssh **<TAB>`, `cd **<TAB>`, `kill **<TAB>`) |

Inside an fzf prompt: type to filter, `↑/↓` to move, `Enter` to accept, `Tab` to multi-select where supported, `^G` to cancel.

File / dir crawl uses `fd` (respects `.gitignore`, includes dotfiles, excludes `.git/`).

### fzf-tab (replaces zsh's tab menu)

| Key | Action |
|---|---|
| `TAB` | Open fzf-tab menu (when there are 2+ completions) |
| `TAB` inside menu | Toggle multi-select (only for widgets that support it) |
| `Enter` | Accept current selection |
| `^G` / `Esc` | Cancel |
| (preview pane) | Auto-shows `eza` listing for directories on `cd` / `z` / `zi` |

### Standard emacs binds (always)

| Key | Action |
|---|---|
| `^A` / `^E` | Start / end of line |
| `^F` / `^B` | Forward / backward one char |
| `Alt-F` / `Alt-B` | Forward / backward one word |
| `^W` | Kill word backward |
| `Alt-D` | Kill word forward |
| `^U` | Kill from cursor to start of line |
| `^K` | Kill from cursor to end of line |
| `^Y` | Yank (paste) last kill |
| `Alt-.` | Insert last argument of previous command |
| `^L` | Clear screen |
| `^C` | Abort current line |
| `^D` | Logout (on empty line) / delete char |
| `^Z` | Suspend foreground job |

### Sudo plugin

| Key | Action |
|---|---|
| `Esc Esc` | Prepend `sudo ` to the current line; or, if empty, to the previous command |

### Line toggles (zsh-line-toggles)

Toggle common command-line modifiers without retyping. Press once to add, again to remove. Cursor-aware — works on the **pipeline segment containing the cursor** (move to end-of-line with `^E` first if you want whole-line behavior).

| Key | Toggles | Notes |
|---|---|---|
| `Alt-2` | ` 2>&1` | merge stderr into stdout |
| `Alt-1` | ` >/dev/null` | silence stdout |
| `Alt-0` | ` 2>/dev/null` | silence stderr |
| `Alt-9` | ` &>/dev/null` | silence both |
| `Alt-L` | ` \| less` | pipe to pager |
| `Alt-&` | ` &` | run in background |
| `Alt-t` | `time ` (prefix) | benchmark the command |
| `Alt-g` | `noglob ` (prefix) | disable wildcards (URLs with `?`, etc.) |
| `Alt-w` | `watch '…'` (whole line) | poll every 2s; auto-quotes |

The four redirect binds are mutually exclusive — pressing one replaces another already at the segment end. `make | grep error` with cursor in `make` + `Alt-2` becomes `make 2>&1 | grep error`, not appended to the whole line.

---

## Tools

### `extract` — universal archive extractor

```sh
extract foo.tar.gz       # works on tar variants, zip, 7z, rar, gz, bz2, xz, zst, ...
extract foo.zip bar.tgz  # multiple at once
```

### `z` / `zi` — zoxide (frecency-ranked directory jumping)

```sh
z proj            # jump to most-frecent dir matching "proj"
z foo bar         # jump to dir matching both "foo" and "bar"
zi                # interactive picker (fzf)
z -               # back to previous dir
```

`cd` is **unchanged** — still the builtin. zoxide builds its database from your `cd` history automatically.

### `eza` — `ls` replacement (aliased)

| Alias | Command |
|---|---|
| `ls` | `eza --group-directories-first --icons` |
| `ll` | `eza -l --git --group-directories-first --icons` |
| `la` | `eza -la --git --group-directories-first --icons` |
| `lt` | `eza --tree --level=2 --icons` |
| `tree` | `eza --tree --icons` |

### Other tools wired in

| Tool | What it does |
|---|---|
| `mise` | Per-project tool versions (`mise install`, `mise use node@20`, etc.) |
| `direnv` | Auto-load `.envrc` on `cd` (run `direnv allow` once per directory) |
| `fast-syntax-highlighting` | Colors commands as you type |
| `colored-man-pages` | Color in `man` |
| `command-not-found` | Suggests the right package when a binary isn't installed (Arch) |

---

## Completion menu (fzf-tab)

- `TAB` after any partial command/path/arg → fzf-tab opens.
- Type to filter, `Enter` to pick.
- Directory previews use `eza -1 --icons` automatically for `cd`, `z`, `zi`.
- For other contexts: just the candidate list, no preview unless you add a zstyle (see tutorial).

---

## History — relevant `setopt`s

| Option | Effect |
|---|---|
| `SHARE_HISTORY` | New commands from one shell are immediately visible in others |
| `HIST_IGNORE_DUPS` | Don't store an entry if it duplicates the previous one |
| `HIST_IGNORE_ALL_DUPS` | When saving, drop *all* older duplicates of a new entry |
| `HIST_IGNORE_SPACE` | Lines starting with a space aren't recorded |
| `HIST_REDUCE_BLANKS` | Strip superfluous whitespace before recording |
| `HIST_EXPIRE_DUPS_FIRST` | When trimming, evict duplicates before unique entries |

History size: `HISTSIZE=100000` in memory, `SAVEHIST=100000` on disk at `~/.zsh_history`.

---

## Prompt (powerlevel10k)

| Action | Command |
|---|---|
| Re-run prompt wizard | `p10k configure` |
| Edit config | `$EDITOR ~/.p10k.zsh` |
| Reload after edit | `exec zsh` |

p10k loads its "instant prompt" cache early so the prompt appears before plugins finish loading.

---

## Misc

- **Long-running commands** print a timing summary after they finish, controlled by `REPORTTIME=2` (commands over 2 seconds).
- **Local overrides** — drop a `*.zsh` file in `~/.zshrc.d/` and it's sourced automatically at the end of `.zshrc`.
- **Bash completions** — bashcompinit is enabled. Drop bash-style completion files into `~/.local/share/zsh/completions/` or source them from a `.zshrc.d/*.zsh` snippet.
- **Reload plugins after a `.zshrc` plugin-list change** — `rm ~/.zgenom/init.zsh && exec zsh` (zgenom rebuilds its cache on next launch).
- **`#` in interactive shells** — comments work (`INTERACTIVE_COMMENTS` is set), so `ls # comment` is valid at the prompt.
