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
