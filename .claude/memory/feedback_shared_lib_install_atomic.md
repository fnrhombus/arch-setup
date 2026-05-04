---
name: Never `cp` over a live shared library — use atomic install/mv
description: Overwriting /usr/lib/*.so via cp invalidates the running process's mmap and crashes it; use install or mv to get a new inode.
type: feedback
---

**Never `cp` over a `/usr/lib/*.so` (or any shared library) that's currently mmap'd by a running process. The process WILL crash, often as a GPF in `ld-linux-x86-64.so.2`.**

**Why:** `cp` truncates and overwrites the same inode. Running processes have the old bytes mmap'd; the mmap'd pages become inconsistent with the new file mid-execution → general protection fault. Pacman never has this problem because it `rename(2)`s a temp file into place — atomic, gets a new inode, the old inode stays valid until the last reference (the running process) closes it.

**How to apply:** when installing a hand-built shared library:

```sh
# WRONG: kills the running process that has the .so mapped
sudo cp build/libfoo.so.X.Y.Z /usr/lib/libfoo.so.X.Y.Z

# RIGHT: atomic rename via install(1)
sudo install -m644 -o root -g root build/libfoo.so.X.Y.Z /usr/lib/libfoo.so.X.Y.Z
# OR equivalent two-step:
sudo cp build/libfoo.so.X.Y.Z /usr/lib/libfoo.so.X.Y.Z.new
sudo mv /usr/lib/libfoo.so.X.Y.Z.new /usr/lib/libfoo.so.X.Y.Z
```

**Empirically observed 2026-05-04** while testing aquamarine PRs against a running Hyprland 0.54.3. Both attempts (PR #289 bdeded4 and a0a68db alone) "crashed" — but the crashes were in the dynamic linker AT THE EXACT SECOND of the `cp`, not after Hyprland tried to use the new code. The patches themselves were never actually executed.

**Bonus pitfall observed same session:** leaving a `.bak` file alongside a real `.so` in `/usr/lib/` is dangerous. Pacman post-transaction hooks run `ldconfig`, which rebuilds the SONAME → version symlinks based on whatever `.so` files match the SONAME. If the `.bak` has the same SONAME (same upstream source, different build), `ldconfig` may pick it as the canonical file and silently re-target the SONAME symlink. Result: subsequent `pacman -R` of unrelated packages can leave the system pointing at a deleted `.bak`. Clean up `.bak` files immediately after testing, or store them outside `/usr/lib/`.
