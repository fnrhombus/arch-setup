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
