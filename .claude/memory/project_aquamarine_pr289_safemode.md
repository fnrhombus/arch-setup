---
name: Aquamarine PR #289 sent Hyprland into safe mode on i915 + DisplayLink
description: 2026-05-04 test of cornedor's render-node-fallback fix put Hyprland in safe mode; reverted via cached .bak; reboot after.
type: project
---

**Aquamarine PR #289 (cornedor's render-node fallback fix) put Hyprland into safe mode on the Inspiron 7786 + i915 + DisplayLink dock combo — 2026-05-04.**

**Why it matters:** the user wanted to test this PR locally to confirm DisplayLink+Hyprland is fixed and post a confirming comment. Outcome was the opposite: Hyprland fell into safe mode, user dropped to TTY. Rather than the existing Asahi M1 confirmations (which the PR has 2 of), this is a *negative* signal on i915 — worth posting back to the PR if the user is willing.

**Setup that produced this:**

- Hyprland 0.54.3 (Arch package, depends on `libaquamarine.so=10`).
- DisplayLink USB3.0 5K Graphic Docking (vendor `17e9:6000`) on USB-C.
- DisplayLink driver 6.2 + evdi-dkms 1.14.15 freshly installed via `yay`.
- evdi loaded, displaylink.service running, `card0-DVI-I-1` enumerated by kernel as connected.
- TV (Vizio V505-G9) on dock's Display 1 HDMI input — never displayed under Linux pre-test, "no signal" throughout.

**Build steps used (work fine; the issue is runtime, not build):**

```sh
git clone git@github.com:hyprwm/aquamarine.git ~/.local/src/aquamarine@hyprwm
cd ~/.local/src/aquamarine@hyprwm
gh pr checkout 289
cmake --no-warn-unused-cli -DCMAKE_BUILD_TYPE:STRING=Release -DCMAKE_INSTALL_PREFIX:PATH=/usr -S . -B ./build
cmake --build ./build --config Release --target all -j$(nproc)
sudo cp /usr/lib/libaquamarine.so.0.11.0 /usr/lib/libaquamarine.so.0.11.0.bak  # backup
sudo cp build/libaquamarine.so.0.11.0 /usr/lib/                                 # install
# restart Hyprland → safe mode
```

Recovery one-liner (cached package):
```sh
sudo pacman -U /var/cache/pacman/pkg/aquamarine-0.11.0-2-x86_64.pkg.tar.zst
```

In this session we used the `.bak` instead — same effect, faster.

**How to apply:** if user re-attempts after PR #289 (or its successor) lands, redo the build steps above and watch for the same safe-mode symptom. If it recurs, the fix in #289 doesn't cover the i915 + evdi combo and a separate patch is needed (probably revisits the parent-syspath matching for evdi specifically). The user's checkout of PR #289 lives at `~/.local/src/aquamarine@hyprwm` if they want to inspect or tweak.

PR conversation as of test time: <https://github.com/hyprwm/aquamarine/pull/289> — #289, #291, #279 all addressing the same regression introduced by PR #235 (2026-02-04).
