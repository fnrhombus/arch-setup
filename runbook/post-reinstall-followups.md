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
