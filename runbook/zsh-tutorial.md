# How to use your shell

A practical guide to driving this terminal. Workflow-focused: how to find things, get around, reuse past commands, complete what you're typing, and use the modern CLI utilities that are installed.

For a dense one-page reference, see `zsh-cheatsheet.md`.

---

## 1. Moving around

You have **four** ways to change directory. Pick the right one for the situation.

### `cd` — when you know the path

```sh
cd ~/src/dots@rhombu5
cd ../sibling
cd -            # back to previous directory
cd              # home
```

Standard zsh `cd`. Tab-completes intermediate components.

### `z <pattern>` — when you've been there before

```sh
z dots          # jumps to most-frecent dir matching "dots"
z dots arch     # AND-ed: dir matching both
```

Powered by **zoxide**, which silently records every `cd` and ranks dirs by *frecency* (recency × frequency). Works only on dirs you've visited at least once — fresh installs have to seed the database by `cd`ing around for a while.

### `zi` — when you've been there before but can't remember the name

```sh
zi              # opens an fzf picker over your full zoxide database
zi proj         # picker, pre-filtered
```

Use this when you'd type `z something` but can't think of `something`.

### `Alt-C` — when it's somewhere under here

Opens an fzf picker over **directories under the current dir**, recursively. Selecting one `cd`s to it. Live preview shows an `eza` tree of the highlighted dir.

This is `^T`'s sibling — same picker shape, but for `cd` instead of inserting a path.

### Mental model

| If you... | Use |
|---|---|
| Know the exact path | `cd` |
| Know roughly which past dir you want | `z foo` |
| Remember you've been there but not what it was called | `zi` |
| Know it's somewhere under here | `Alt-C` |

---

## 2. Finding things

### Files by name — `fd`

`fd` is a faster, friendlier `find`. Respects `.gitignore` by default (no more wading through `node_modules`).

```sh
fd README                    # any file with "README" in the name, anywhere below cwd
fd -e md                     # all .md files
fd -e py -e js              # all .py or .js files
fd README ~/src              # search a specific tree
fd -t d node_modules        # only directories named node_modules
fd -H .env                   # include hidden files
fd -I build                  # ignore .gitignore (include build dirs etc.)
fd 'test_.*\.py'             # regex
fd README -x bat             # for each match, run `bat <match>`
```

### Files / dirs by fuzzy name — `^T` and `Alt-C`

When you're typing a command and need to *insert* a path:

```sh
vim <hit ^T, pick file>
cp <^T> /tmp/
git diff <^T>
```

`^T` opens fzf over files under cwd. Type to filter, `TAB` to multi-select, `Enter` to insert path(s) at the cursor. Preview pane shows `bat` (for files) or `eza --tree` (for dirs) of whatever's highlighted.

Use `^T` when you want a path **inserted into a command**. Use `Alt-C` when you want to **`cd` there**. Use `fd` when you want the list **printed**.

### Content of files — `rg` (ripgrep)

```sh
rg pattern                          # search for "pattern" in all files below cwd
rg pattern src/                     # in a specific dir
rg -i pattern                       # case-insensitive
rg -F 'literal.string'              # no regex, fixed string
rg -tpython 'def main'              # only Python files
rg -g '*.md' pattern                # only files matching glob
rg -l pattern                       # just list filenames, not matches
rg --files-without-match pattern    # files that DON'T contain pattern
rg -A3 -B3 pattern                  # 3 lines of context above/below each hit
rg -C5 pattern                      # 5 lines of context on each side
rg pattern | fzf                    # pipe into fzf for interactive narrowing
```

Like `fd`, respects `.gitignore` by default. `rg -uu pattern` to ignore the ignore (and search hidden files too).

### Past commands — `^R`

`^R` opens fzf over your shell history. Type to filter, `Enter` puts the command back on the prompt so you can edit before running.

This is different from `^P/^N`, which steps through matches in-place. Use `^P/^N` when you're typing and want the last command starting with what you've typed; use `^R` when you want the full picker UI.

---

## 3. Reading and viewing

### `bat` — `cat` with syntax highlighting and paging

```sh
bat README.md                # syntax-highlighted, with line numbers and a header
bat *.py                     # concatenate multiple files, each with a header
bat -p file                  # plain mode: no decorations, just highlighted content
bat -A file                  # show non-printing chars (tabs, line endings)
bat --diff <(cmd1) <(cmd2)   # syntax-highlighted diff
echo '{"a":1}' | bat -l json # pipe in, force language
```

Pages automatically with `less` for long files. Press `q` to quit, `/` to search, `n` for next match.

Use `bat` whenever you'd reach for `cat`. The aliases haven't replaced `cat` itself, so `cat` remains pure for scripts.

### `eza` (your `ls`)

The aliases:

| Alias | What it shows |
|---|---|
| `ls` | One-line names with icons, dirs first |
| `ll` | Long-form (perms, size, date) with git status, icons |
| `la` | Like `ll` but includes hidden files |
| `lt` | Tree, 2 levels deep |
| `tree` | Tree, unlimited depth |

Useful eza flags to know:

```sh
eza -la --git --header             # what `la` gives you, with column headers
eza --tree --level=3 --git-ignore  # tree, respecting .gitignore
eza -la --sort=modified            # sort by mtime
eza -la --total-size               # show recursive dir size
eza -la --git                      # show git status per file
```

### `less` (auto-invoked by `bat`, `man`)

Inside a `less` page:

| Key | Action |
|---|---|
| `Space` / `f` | Page down |
| `b` | Page up |
| `↓` `↑` | Line at a time |
| `g` / `G` | Top / bottom |
| `/pattern` | Search forward |
| `?pattern` | Search backward |
| `n` / `N` | Next / previous match |
| `q` | Quit |

### `man` (with colors)

Just `man cmd`. The `colored-man-pages` plugin makes headings, options, and emphasis show in color via `less`.

### `tldr` — quick crib sheets

When `man` is too much:

```sh
tldr rsync          # 5 common rsync recipes, in plain English
tldr tar
tldr ffmpeg
tldr --update       # refresh the local cache
```

---

## 4. Reusing past commands

### Ghost text (autosuggestions)

As you type, the most relevant past command appears as grey ghost text after the cursor.

| Key | Effect |
|---|---|
| `^E` (End) | Accept the whole suggestion |
| `Alt-F` | Accept one word at a time |
| `→` or `^F` | Accept one character |
| Any other key | Continue typing; suggestion updates as you go |

You don't have to do anything to *show* a suggestion — just start typing. The suggestion is whatever past command best matches.

### `^P` / `^N` — substring history search

Type a few characters first, then `^P`. Walks backward through history entries that *contain* what you typed; `^N` walks forward.

```
$ git che<^P>
$ git checkout main                    # most-recent match
$ <^P>
$ git checkout -b feature/foo          # next-most-recent
```

The cursor stays where it was, so the match snippet you typed is highlighted in the recalled line. Useful when you remember a partial command but not the prefix.

### `^R` — full fuzzy picker over history

When you want to *see* a bunch of candidates and filter visually:

```
^R, type "rsync", browse the matches, Enter to put it back on the prompt
```

`Esc` cancels. `^G` also cancels.

### Bang patterns

| Pattern | Means |
|---|---|
| `!!` | The previous command, verbatim |
| `sudo !!` | Re-run the previous command with sudo |
| `!$` | Last argument of the previous command |
| `!*` | All arguments of the previous command |
| `!:0` | The command name of the previous command (first word) |
| `!grep` | Most recent command starting with `grep` |
| `!?pattern?` | Most recent command containing `pattern` |
| `^old^new` | Re-run previous command with first `old` replaced by `new` |
| `^old^new^:G` | Same but replace all occurrences |

```sh
$ ls /etc/passwd
$ cat !$              # = cat /etc/passwd
$ vim !$              # = vim /etc/passwd
$ make
$ sudo !!             # = sudo make
$ ls *.txt
$ ^txt^md             # = ls *.md
```

### `Alt-.` — insert last argument as you go

`Alt-.` (or `Esc .`) inserts the last argument of the previous command at the cursor. Press it again to walk back through earlier last-args.

```sh
$ vim /etc/hosts
$ ls -la <Alt-.>      # becomes: ls -la /etc/hosts
```

The most ergonomic "act on the same thing again" move.

### `Esc Esc` — `sudo` prefix

Hit `Esc Esc` to prepend `sudo ` to the current command. If the line is empty, it prepends `sudo ` to the *previous* command and re-runs it.

```sh
$ pacman -Syu
zsh: you cannot perform this operation unless you are root.
$ <Esc Esc>    # line becomes: sudo pacman -Syu
```

---

## 5. Line toggles — mutate the command you're typing

`zsh-line-toggles` binds a handful of `Alt`-keys that insert or remove common command-line modifiers — the stderr/stdout redirects, a `| less` pipe, `&` to background, `time`/`noglob` prefixes, a `watch` wrapper — without retyping them. Press a key once to add the modifier, again to toggle it back off. The toggles are cursor-aware: they act on the **pipeline segment containing the cursor**, not the whole line (move to end-of-line with `^E` first for whole-line behavior).

The full bind table lives in `zsh-cheatsheet.md`. Two things it doesn't cover — rebinding, and what default binds the plugin displaces — are below.

### Rebinding the keys

Each toggle reads its keybind from a `ZLT_KEY_*` variable. Set any of them **before** the plugin loads (i.e. ahead of the `zgenom load fnrhombus/zsh-line-toggles` line in `.zshrc`) to override the default. `^[` is the escape prefix that means "Alt":

```zsh
ZLT_KEY_STDERR_TO_STDOUT='^[r'   # Alt-r instead of Alt-2
ZLT_KEY_PIPE_LESS='^[p'          # Alt-p instead of Alt-L
```

The full set of variables and their defaults:

| Variable | Default | Toggles |
|---|---|---|
| `ZLT_KEY_STDERR_TO_STDOUT` | `Alt-2` | ` 2>&1` |
| `ZLT_KEY_SILENCE_STDOUT` | `Alt-1` | ` >/dev/null` |
| `ZLT_KEY_SILENCE_STDERR` | `Alt-0` | ` 2>/dev/null` |
| `ZLT_KEY_SILENCE_ALL` | `Alt-9` | ` &>/dev/null` |
| `ZLT_KEY_PIPE_LESS` | `Alt-L` | ` \| less` |
| `ZLT_KEY_BACKGROUND` | `Alt-&` | ` &` |
| `ZLT_KEY_TIME_PREFIX` | `Alt-t` | `time ` (prefix) |
| `ZLT_KEY_NOGLOB_PREFIX` | `Alt-g` | `noglob ` (prefix) |
| `ZLT_KEY_WATCH` | `Alt-w` | `watch '…'` (whole-line wrap) |

### What the defaults displace

The default binds override these emacs/viins defaults. Most are rarely used, but if you rely on one, rebind the toggle via its variable above (or bind the original action back after the plugin loads):

| Bind | Default it overrides | Used often? |
|---|---|---|
| `Alt-0..9` | `digit-argument` (e.g. `Alt-5 ^D` deletes 5 chars) | rarely |
| `Alt-L` | `down-case-word` (lowercases the next word) | occasionally |
| `Alt-t` | `transpose-words` | occasionally |
| `Alt-g` | unbound by default in emacs mode | — |
| `Alt-w` | `copy-region-as-kill` | rarely |
| `Alt-&` | `tilde-expand` | rarely |

---

## 6. Tab completion

Hit `<TAB>` after a partial command, path, option, or argument. If there are multiple candidates, **fzf-tab** opens a fuzzy picker:

- Type to filter
- `↑/↓` to move
- `TAB` to multi-select (for args that take multiple values, like `kill <pid>`)
- `Enter` to accept
- `^G` or `Esc` to cancel

Matching is case-insensitive in both directions: `dow<TAB>` completes `Downloads`, `DEP<TAB>` completes `dependencies`.

For directory contexts (`cd`, `z`, `zi`), the preview pane shows an `eza -1` listing of the highlighted dir.

### The `**<TAB>` super-trigger

Prefix a word with `**` and `<TAB>` opens fzf — works in many command contexts:

```sh
ssh **<TAB>             # ssh-config hosts
cd **<TAB>              # directories
vim some/path/**<TAB>   # paths under some/path
git checkout **<TAB>    # branches and files
kill **<TAB>            # process picker
unset **<TAB>           # env vars
```

Memorize `**<TAB>` for kill and ssh especially — much faster than typing PIDs or hostnames.

---

## 7. Archives — `extract`

One command for any compressed file:

```sh
extract foo.tar.gz
extract foo.zip
extract foo.7z
extract foo.tar.zst
extract bar.tgz baz.rar    # multiple at once
```

Replaces the family of `tar xvf` / `tar xvJf` / `unzip` / `7z x` / `unrar x` you'd otherwise have to keep straight.

---

## 8. Per-project tooling

### `mise` — language/tool versions per project

In any directory with `mise.toml` or `.tool-versions`, the right versions of `node`, `python`, `go`, `rust`, `bun`, etc. are automatically on PATH when you `cd` in.

```sh
mise use node@22              # pin node 22 for this project (writes to local mise.toml)
mise use --global node@22     # set as global default
mise install                  # install everything mise.toml asks for
mise current                  # show what's active here
mise ls-remote node           # show available node versions
mise upgrade                  # upgrade installed tools
```

### `direnv` — env vars per project

Drop an `.envrc` in any directory:

```sh
# .envrc
export DATABASE_URL=postgres://localhost/myapp
export PATH="$PWD/scripts:$PATH"
layout python                  # set up a python virtualenv automatically
```

Then `direnv allow` once per directory (security: each `.envrc` must be explicitly trusted). After that, env vars activate on `cd` in and deactivate on `cd` out.

Common stdlib `.envrc` patterns: `layout node`, `layout python`, `layout ruby`, `use_nix`, `dotenv` (loads a `.env` file as exports).

---

## 9. Other utilities you have

### `jq` — JSON

```sh
echo '{"a":{"b":[1,2,3]}}' | jq '.a.b[1]'    # → 2
curl api.example.com/x.json | jq '.users[] | .email'
jq '.[] | select(.active)' data.json
jq -r '.name' data.json                       # raw output (no quotes)
jq '. + {extra: "field"}' data.json           # add a key
```

### `yq` — YAML (same syntax as jq)

```sh
yq '.services.web.image' docker-compose.yml
yq -i '.version = "2.0"' config.yaml          # in-place edit
yq -o=json file.yaml                          # convert YAML → JSON
```

### `sd` — simpler `sed` for find-and-replace

```sh
echo "lots of bats" | sd bat ferret    # → "lots of ferrets"
sd 'old' 'new' file.txt                # in-place edit, just one file
fd -e py -x sd 'foo' 'bar'             # find all .py files, replace foo→bar in each
```

Use `sd` when you want simple text substitution without `sed`'s arcane syntax. Falls back to `sed` for streaming pipelines and addresses (`/pattern/d`, line ranges, etc.) where sd doesn't reach.

### `btop` — top / htop replacement

```sh
btop                       # interactive process viewer with graphs
```

Hit `q` to quit, `m` to switch memory view, `?` for help.

### `xh` — `curl` / `httpie` replacement

```sh
xh httpbin.org/get
xh post httpbin.org/post name=alice age:=30      # JSON body
xh GET httpbin.org/get param==value              # query string
xh --form POST httpbin.org/post name=alice       # form-encoded
xh -d https://example.com/file.zip               # download
xh --download --output renamed.zip <url>         # download to specific name
```

JSON pretty-printed automatically. Headers separated visually.

---

## 10. Aliases — see what's defined

```sh
alias              # list every alias currently defined
alias | grep git   # narrow to git-related
alias ll           # show what `ll` expands to
```

Edit `~/.zsh_aliases` to add your own; then `source ~/.zsh_aliases` (no full restart needed).

---

## 11. The prompt

Powerlevel10k. To re-run the configuration wizard:

```sh
p10k configure
```

Walks you through layout (lean, classic, rainbow), what to show (git status, exit code, time, dir), and writes `~/.p10k.zsh`. You can re-run it any time. Hand-editing `~/.p10k.zsh` is also fine — every option is commented.

After editing: `exec zsh` to reload.

---

## 12. Quick-reference cheats you'll forget

| Forget to... | Workaround |
|---|---|
| ...edit a long command | `^X^E` opens it in `$EDITOR`, save & quit to run |
| ...clear the screen | `^L` |
| ...kill the current line | `^U` (start to cursor) or `^K` (cursor to end) |
| ...escape from a long command | `^C` to abort the line |
| ...background a foreground job | `^Z` suspends, then `bg` |
| ...bring a job back | `fg` |
| ...see jobs | `jobs` |
| ...repeat the last find | `Alt-.` for last argument |
| ...check what a command will do | `tldr <cmd>` for examples, `man <cmd>` for full docs |
| ...find when a file was last edited | `eza -la --sort=modified` |
| ...see disk usage | `du -sh *` or grouped: `du -sh */` |
| ...see what's listening on a port | `ss -tlnp` |

---

## 13. Putting it together — three real workflows

### "I need to find every Python file that imports `requests` and check what version is pinned"

```sh
rg -l 'import requests' --type=py            # files with the import
rg -tpython 'requests[=><~]' requirements*.txt pyproject.toml setup.py 2>/dev/null
```

### "I just made a typo in `cd`; the dir I want is somewhere I've been before"

```sh
zi          # interactive picker, type to filter
```

### "I want to bulk-rename .txt to .md in a project, respecting .gitignore"

```sh
fd -e txt -x mv {} {.}.md
```

(`{.}` is fd's substitution for "the match with extension stripped.")
