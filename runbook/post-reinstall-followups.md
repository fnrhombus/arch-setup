# Post-reinstall follow-ups to /schedule

A landing pad for `/schedule` items deferred until after the next reinstall.
When you're back up and Claude Code has access to a fresh shell, ask Claude
to read this file and set up each item.

## 1. Waybar wireplumber-module crash — watch for upstream fix

**Background.** `waybar 0.15.0` reproducibly SIGABRTs in
`g_ptr_array_add` inside the wireplumber module's `GAsyncReadyCallback`
(triggered by audio sink/route transitions). Two crashes in 36h on
2026-05-01 and 2026-05-02 with identical stack traces. As a workaround,
we swapped the `wireplumber` module for `pulseaudio` in waybar config
(libpulse → pipewire-pulse, same UX, different code path). See
rhombu5/dots commit `fb96964` for the swap.

**Upstream tracker.** [Alexays/Waybar#3974](https://github.com/Alexays/Waybar/issues/3974) — open since 2025-04-24, my data-point comment: [#issuecomment-4364731676](https://github.com/Alexays/Waybar/issues/3974#issuecomment-4364731676).

**Schedule prompt to give Claude:**

> `/schedule` a monthly agent: check Alexays/Waybar#3974 for new
> activity (closed? milestone? merged PR?). Also `pacman -Si waybar`
> against the version that introduced #3974's fix. If a fixed waybar
> version is in `[extra]`, open a PR against rhombu5/dots reverting the
> two-line swap in `dot_config/waybar/config.jsonc` (`"pulseaudio"` →
> `"wireplumber"` in modules-right + the module block key) and ask me to
> test for ~1 week before merging. If still unfixed, ping me with a
> one-line status (last activity date, no action needed).

**Files to revert when fixed:** `dot_config/waybar/config.jsonc` lines 20
and ~89, both `pulseaudio` → `wireplumber`. The module block options are
identical between the two backends, so it's a pure key rename.

## 2. libpinpam fork (try_first_pass / use_first_pass) — file upstream PR

**Background.** [RazeLighter777/pinpam](https://github.com/RazeLighter777/pinpam)'s
`libpinpam.so` (AUR `pinpam-git`) ignores PAM module argv entirely and
always prompts via the conv function. To slot it between
`pam_fprintd_grosshack` and `pam_unix` in the concurrent fingerprint+PIN+
password stack (postinstall.sh §7a), it must honor `try_first_pass` /
`use_first_pass` so it reads `PAM_AUTHTOK` from the prior module
instead of re-prompting. We carry an 84-line patch on the
[`fnrhombus/pinpam@try-first-pass`](https://github.com/fnrhombus/pinpam/tree/try-first-pass)
branch (commit `9b5f364`) and ship it as the `pinpam-fnrhombus`
package built from
`phase-3-arch-postinstall/aur-overrides/pinpam-fnrhombus/PKGBUILD`.

**Upstream tracker.**
- Issue: [RazeLighter777/pinpam#8](https://github.com/RazeLighter777/pinpam/issues/8) — feature request.
- PR: [RazeLighter777/pinpam#9](https://github.com/RazeLighter777/pinpam/pull/9) — `fnrhombus:try-first-pass` → `RazeLighter777:dev`, filed 2026-05-06.

Upstream is active (last push 2026-03-02; recent third-party MRs merged within 2-4 days).

**Schedule prompt to give Claude:**

> `/schedule` a monthly agent: `gh pr view 9 -R RazeLighter777/pinpam`.
> If state is `MERGED` AND the AUR `pinpam-git` PKGBUILD's `_commit`
> advances past the merge: open a PR against arch-setup that deletes
> `phase-3-arch-postinstall/aur-overrides/pinpam-fnrhombus/`, restores
> `pinpam-git` to `AUR_PACKAGES` in postinstall.sh §3, removes the
> `pinpam-fnrhombus` entry from the §3-overrides loop, updates the
> verify checks (`pinpam-fnrhombus pkg` → `pinpam-git`), and updates
> the GLOSSARY.md entry. Ping me with the PR link.

**Files / paths to clean up when fixed:**
- Delete `phase-3-arch-postinstall/aur-overrides/pinpam-fnrhombus/`
- `phase-3-arch-postinstall/postinstall.sh` §3: replace the `pinpam-git`
  comment block with the package re-added to `AUR_PACKAGES`; remove
  `pinpam-fnrhombus` from the §3-overrides loop
- `phase-3-arch-postinstall/postinstall.sh` verify: replace
  `pinpam-fnrhombus pkg` check with `pinpam-git`
- `runbook/GLOSSARY.md`: revert the pinpam entry to reference upstream
- Delete `~/src/pinpam@fnrhombus` if you don't want the fork checkout
- Delete this entry

## 3. pam-fprint-grosshack fork (per-call SIGUSR1 reset) — carry indefinitely

**Background.** [gitlab.com/mishakmak/pam-fprint-grosshack](https://gitlab.com/mishakmak/pam-fprint-grosshack)'s
`pam_fprintd_grosshack.so` uses a static SIGUSR1 flag that's never
reset between auth attempts. Within a single sudo process's retry
loop, the second `pam_authenticate` call sees the leftover flag,
`do_verify` shortcuts, the prompt-pthread is cancelled mid-`pam_prompt`,
echo-off never engages, and partial typed input leaks (visibly) into
the next stack module's prompt. We carry a 1-line sed patch in
`phase-3-arch-postinstall/aur-overrides/pam-fprint-grosshack-fnrhombus/PKGBUILD`'s
`prepare()` that inserts `has_recieved_sigusr1 = false;` before the
`signal (SIGUSR1, ...)` call in `do_auth`, and ship the result as the
`pam-fprint-grosshack-fnrhombus` package.

**Upstream tracker.** Effectively abandoned: last commit 2022-07-27,
last accepted MR same date, four open issues with no maintainer
response since (most recent 2025-03-15). MR filing is a courtesy
with near-zero merge probability.

**Schedule prompt to give Claude:**

> `/schedule` a yearly agent: query
> `https://gitlab.com/api/v4/projects/mishakmak%2Fpam-fprint-grosshack/repository/commits?per_page=5`
> and the merge requests endpoint. If activity is past 2026-05-05,
> file an MR with the `has_recieved_sigusr1 = false;` reset patch
> and ping me. If still abandoned, no action — just confirm status.

**Files / paths to clean up when (unlikely) fixed:**
- Delete `phase-3-arch-postinstall/aur-overrides/pam-fprint-grosshack-fnrhombus/`
- `phase-3-arch-postinstall/postinstall.sh` §3: replace the
  `pam-fprint-grosshack-fnrhombus` entry in §3-overrides with
  `pam-fprint-grosshack` added to `AUR_PACKAGES`
- `phase-3-arch-postinstall/postinstall.sh` verify: replace
  `grosshack-fnrhombus pkg` check with `pam-fprint-grosshack`
- `runbook/GLOSSARY.md`: revert the grosshack entry to reference upstream
- Delete this entry

## 4. waybar-git swap (post-0.15.0 GdkMonitor crash fixes) — watch for stable

**Background.** `waybar 0.15.0` (the [extra] version) has a recurring
GdkMonitor property-access use-after-free on Wayland output remove/
re-add — six SIGSEGVs in 4 days observed 2026-05-04 → 2026-05-08 on a
clamshell+HDMI setup where the lid-handler repeatedly disables and
re-enables eDP-1. Stack signature matches Waybar
[#3530](https://github.com/Alexays/Waybar/issues/3530) (closed) and
[#4361](https://github.com/Alexays/Waybar/issues/4361) (open). Fixes
for that bug class landed on master *after* 0.15.0 was tagged in Feb
2026 — PR
[#4938](https://github.com/Alexays/Waybar/pull/4938) (`hyprland/window`
UAF), [#4946](https://github.com/Alexays/Waybar/pull/4946) (Wayland
globals leak/UAF), [#5007](https://github.com/Alexays/Waybar/pull/5007)
(TOCTOU), among others. Switched from `waybar` to AUR `waybar-git`
2026-05-08.

The companion `waybar.service` drop-in in dots
(`dot_config/systemd/user/waybar.service.d/restart.conf`) is the
belt-and-suspenders auto-respawn — independent of the binary swap; keep
it even after reverting back to stable `waybar`.

**Schedule prompt to give Claude:**

> `/schedule` a monthly agent: `pacman -Si waybar` against the
> [extra] version. If the version is `> 0.15.0` AND the changelog or
> upstream release notes reference fixes for the GdkMonitor UAF
> (Waybar #3530/#4361 or PRs #4938/#4946/#5007), open a PR against
> arch-setup that (a) restores `waybar` to §1's pacman -S list, (b)
> removes the `waybar-git` block from §3's `AUR_PACKAGES`, (c) deletes
> this entry. Ping me with the PR link.

**Files to revert when fixed:**

- `phase-3-arch-postinstall/postinstall.sh` §1: re-add `waybar` to the
  pacman list (around line 255, with the other hypr* / swayosd entries).
- `phase-3-arch-postinstall/postinstall.sh` §3: remove the `waybar-git`
  block (comment + entry) from `AUR_PACKAGES`.
- `README.md`: revert the "Desktop shell / UI" entry from `waybar-git`
  back to `waybar`.
- (`dot_config/systemd/user/waybar.service.d/restart.conf` in dots:
  KEEP — it's independent of the package source.)

## 5. Delete `/boot/limine.conf.pre-recovery.bak` after 2026-05-23

**Background.** `postinstall.sh §16b-limine` (added 2026-05-09 in commit
`3a77cd4`) backs up `/boot/limine.conf` to `/boot/limine.conf.pre-recovery.bak`
the first time it migrates the flat layout to the nested `/+Arch Linux`
layout with the Recovery (linux) sub-entry. The backup exists so that if
the new config breaks boot, you can restore the working pre-fix file from
a live USB without reinstalling limine. Procedure documented in
`runbook/SURVIVAL.md` § "limine.conf got mangled".

After two weeks of stable boots + at least one verified snapper-snapshot
recovery cycle, the backup has served its purpose and just clutters the ESP.

**Action when the date arrives:**

```bash
# Confirm current limine.conf is healthy (nested layout + Recovery sub-entry):
sudo grep -q '//Recovery (linux)' /boot/limine.conf && echo OK
# Then delete the backup:
sudo rm /boot/limine.conf.pre-recovery.bak
# And delete this entry from this file.
```

**Trigger date:** 2026-05-23 (two weeks after 2026-05-09).

## 6. aquamarine PR #291 release — retry DisplayLink dock + Hyprland

**Background.** The Inspiron 7786's DisplayLink dock (`17e9:6000` "DisplayLink
USB3.0 5K Graphic Docking") can drive the TV's HDMI input via the dock's own
video chip — useful when the TV's stuck-asserted HPD on the laptop's native
HDMI makes Linux think a powered-off TV is still connected. The dock path
needs `displaylink` (AUR) + `evdi-dkms` (AUR) plus working evdi support in
Hyprland's backend, `aquamarine`.

DisplayLink/evdi worked under aquamarine through ~v0.9.x, then regressed in
[aquamarine#235](https://github.com/hyprwm/aquamarine/pull/235) ("drm: use
parent device matching for render nodes", merged 2026-02-04, shipped in
v0.10.0+). PR #235 explicitly removed the EVDI render-node skip — the PR
description literally says *"Also remove EVDI check since it wont be needed
after this change"* — and removed the fallback-to-first-render-node
behavior. For evdi (a virtual platform device with no PCI parent and no
co-located render node), the parent-syspath search finds nothing and
`renderNodeFd` stays `-1`, so Hyprland can't enumerate DisplayLink outputs.

Three competing fix PRs were filed:

- [aquamarine#279](https://github.com/hyprwm/aquamarine/pull/279) (sgtaziz)
  — CPU-copy fallback, NVIDIA-focused. OPEN.
- [aquamarine#289](https://github.com/hyprwm/aquamarine/pull/289) (cornedor)
  — unconditional fallback to any render node. OPEN. **Tested locally
  2026-05-04 by building the branch and swapping `libaquamarine.so` —
  dropped Hyprland into safe mode on the i915 + DisplayLink combo. Reverted
  via cached `aquamarine-0.11.0-2-x86_64.pkg.tar.zst`. Recipe is in the auto
  memory file `project_aquamarine_pr289_safemode.md`.**
- [aquamarine#291](https://github.com/hyprwm/aquamarine/pull/291) (jwbron)
  — fall back to first render node on single-renderD systems when
  parent-syspath match fails. **MERGED 2026-05-11**, merge commit
  `f44fecf278a4b7f03e26592db1aba88edd8e51b6`. Headline test bed was Asahi
  M1; whether it covers i915+evdi cleanly is untested. One PR comment
  (waltmck, 2026-05-13) reports a still-open OpenGL issue on Hyprland
  0.55.1, so PR #291 may not be a full win for every configuration.

**Catch — the fix is master-only as of writing (2026-05-20).** Latest
aquamarine release is `v0.11.0` (2026-04-25), which predates the #291 merge.
The installed system has `aquamarine 0.11.0-2`, which does NOT contain the
fix. The next tagged release after 2026-05-11 should pick it up.

**Schedule prompt to give Claude:**

> `/schedule` a weekly agent: query
> <https://api.github.com/repos/hyprwm/aquamarine/releases?per_page=5>. For
> each release tag newer than `v0.11.0`, check whether
> `git -C ~/.local/src/aquamarine@hyprwm` (or via the GitHub compare API:
> `gh api repos/hyprwm/aquamarine/compare/v0.11.0...<new-tag>`) contains
> commit `f44fecf278a4b7f03e26592db1aba88edd8e51b6` (PR #291's merge
> commit). If yes, ping the user with a `notify-send -u critical` and a
> short summary (which release tag, when published). User will then
> manually re-attempt the dock test using the recipe in the auto memory
> file `project_aquamarine_pr289_safemode.md`. If still no new tag, no
> notification — just confirm status in the agent's summary.
>
> While checking, also briefly note the state of
> [aquamarine#294](https://github.com/hyprwm/aquamarine/issues/294)
> ("Giant errorlog when using Displaylink displays") — if closed, mention
> it in the summary since it's a known issue that affects the same path.

**Local references — how to find this investigation after a wipe.**

This whole thread is reconstructable from Dropbox-synced
`~/.claude/projects/` (the auto-memory + the transcript). Without those, the
GitHub links above are still enough — but the build recipe and the safe-mode
data point only live locally.

- **Auto memory file (the test recipe, including the `cmake` invocation
  and the `.bak` recovery one-liner):**
  ```
  ~/.claude/projects/-home-tom-src-arch-setup-fnrhombus/memory/project_aquamarine_pr289_safemode.md
  ```
- **Session transcript with the deep code-level discussion** (root-cause
  walkthrough, three-PR comparison, decision to build PR #289):
  ```
  ~/.claude/projects/-home-tom-src-arch-setup-fnrhombus/c1edcbaf-52d3-490d-973a-bfb192f385c8.jsonl
  ```
  Quick grep recipes:
  ```sh
  # find the regression-discovery exchange
  grep -nE 'PR #235|aquamarine.*235|EVDI check|wont be needed' \
      ~/.claude/projects/-home-tom-src-arch-setup-fnrhombus/c1edcbaf-52d3-490d-973a-bfb192f385c8.jsonl

  # find the three-PR comparison
  grep -nE 'pull/(279|289|291)|cornedor|jwbron|sgtaziz' \
      ~/.claude/projects/-home-tom-src-arch-setup-fnrhombus/c1edcbaf-52d3-490d-973a-bfb192f385c8.jsonl
  ```
- **System-level timeline confirmation** (when displaylink/evdi were
  installed and reverted):
  ```sh
  grep -E 'aquamarine|displaylink|evdi-dkms' /var/log/pacman.log
  # Expect: aquamarine installed 2026-04-30, displaylink + evdi-dkms
  # installed 2026-05-04 01:13 and removed 02:45 — same-night rollback.
  ```
- **Build clone** (`~/.local/src/aquamarine@hyprwm`) — **gone**, deleted
  after the failed test. Re-create from the auto-memory recipe.

**Files / paths to clean up when fixed (dock confirmed working):**

- Update `docs/decisions.md` Q4 ("DisplayLink / External Monitor") — the
  "Monitor via HDMI direct to laptop (bypasses DisplayLink video — avoids
  Wayland issues)" rationale no longer holds in the post-#291 world.
  Document that DisplayLink-via-dock works on aquamarine ≥ `<new-tag>`.
- Update `runbook/GLOSSARY.md` "DisplayLink" entry similarly.
- Update `runbook/phase-3-handoff.md` line 20 ("DisplayLink dock used only
  for ethernet + USB hub, not video").
- Consider adding `displaylink` + `evdi-dkms` to postinstall.sh §3
  `AUR_PACKAGES`, gated on a check that aquamarine has the fix.
- Delete this entry.
