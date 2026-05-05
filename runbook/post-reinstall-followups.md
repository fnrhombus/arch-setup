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

## 2. Hyprlax fractional-scale over-zoom — wait for upstream merge

**Background.** On 2026-05-04 we hit a hyprlax 2.2.2 bug where any
non-integer monitor scale (1.5, 1.6667, 1.75, …) renders the wallpaper
1.5×-ish zoomed in. Root cause traced to two sites in upstream that
both treat `monitor->width/height` (which come from `wl_output.mode` =
physical scanout pixels) as if they were logical:
`fractional_scale_preferred` in `src/platform/wayland.c` (EGL buffer
+ viewport destination) and `glViewport` in `src/core/render_core.c`.
At scale=1 the multiplications are no-ops, which is why the laptop
display was fine. As a workaround we built a patched binary from our
fork and dropped it at `/usr/local/bin/hyprlax`, which is on the
systemd user-session PATH (~/.local/bin is NOT — Hyprland is launched
under uwsm via a systemd user target, which doesn't inherit interactive
shell PATH). `/usr/local/bin` resolves before `/usr/bin/hyprlax` so the
patched build wins.

**Upstream tracker.** [sandwichfarm/hyprlax#87](https://github.com/sandwichfarm/hyprlax/issues/87) (issue) and [sandwichfarm/hyprlax#88](https://github.com/sandwichfarm/hyprlax/pull/88) (PR from `fnrhombus/hyprlax fix/fractional-scale-overzoom`).

**Schedule prompt to give Claude:**

> `/schedule` a monthly agent: check sandwichfarm/hyprlax#87 for status,
> and check `pacman -Si hyprlax-bin` against the version that includes
> the merged fix. Also check that the merged commit's diff actually
> matches what we shipped — they may have rewritten it. When the
> fixed version is in AUR and installed, remove
> `/usr/local/bin/hyprlax` (so PATH falls through to the upstream
> build) and `which hyprlax` should resolve to `/usr/bin/hyprlax`
> under the systemd user PATH.
> If still unmerged, ping me with a one-line status.

**Files / paths to clean up when fixed:**
`sudo rm /usr/local/bin/hyprlax`, then under the systemd user PATH
`which hyprlax` should print `/usr/bin/hyprlax`. Also delete
`~/.local/bin/hyprlax` if it's still around (an earlier install attempt
dropped a copy there) and `~/src/hyprlax@fnrhombus` if you don't want
the fork checkout around.

## 3. libpinpam fork (try_first_pass / use_first_pass) — file upstream PR

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

**Upstream tracker.** PR not yet filed (we wanted to validate end-to-end
on the live system first; confirmed working 2026-05-05). File at
[RazeLighter777/pinpam](https://github.com/RazeLighter777/pinpam) when
ready — branch from `dev` per their README. Upstream is active (last
push 2026-03-02; recent third-party MRs merged within 2-4 days).

**Schedule prompt to give Claude:**

> `/schedule` a monthly agent: `gh pr list -R RazeLighter777/pinpam
> --search "try_first_pass OR use_first_pass" --state all`. If a PR
> with that subject is merged AND the merge commit is on `master` (or
> the AUR `pinpam-git` PKGBUILD's `_commit` advances past the merge):
> open a PR against arch-setup that deletes
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

## 4. pam-fprint-grosshack fork (per-call SIGUSR1 reset) — carry indefinitely

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
