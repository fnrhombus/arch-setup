# Azure DDNS — extraction complete, follow-ups for arch-setup

**Audience:** the next Claude session working in `fnrhombus/arch-setup`.
This is a forward handoff, not a task brief — the extraction itself is
done. What's below is what's still owed in *this* repo as a result.

## What was accomplished

The DDNS code that used to live here as `staged-azure-ddns/` has been
extracted, packaged, released, and pushed to the AUR.

- **Standalone repo:** [fnrhombus/azure-ddns](https://github.com/fnrhombus/azure-ddns)
  — public, MIT, single-maintainer, no formal audit.
- **Release:** [v0.1.0](https://github.com/fnrhombus/azure-ddns/releases/tag/v0.1.0).
- **AUR packages, both live:**
  - https://aur.archlinux.org/packages/azure-ddns — stable; re-published
    on every GitHub release.
  - https://aur.archlinux.org/packages/azure-ddns-git — rolling;
    re-published on every push to `main` touching packaging-relevant
    paths.
- **CI:** lint (shellcheck, `bash -n`, `systemd-analyze verify`,
  `namcap`) + a real `makepkg` build inside an Arch container on every
  PR touching packaging — green on `main`.
- **AUR push automation** is keyed on dedicated repo secrets and an
  isolated ed25519 deploy key.

## Functional drift from what was here

None. One non-cosmetic addition upstream: the `azure-ddns` script
accepts env-var overrides for the env-file, IP cache, and token cache
paths (defaults unchanged; overrides exist only to make the script
testable without root). Service/timer/dispatcher differences vs. the
in-repo `metis-ddns/` copy are comment-only.

## Decisions worth knowing (so they don't get relitigated)

- **Public repo, not private.** The original "private until verified on
  a fresh VM + one external user reports success" plan was dropped in
  favor of shipping. Worth a line in `docs/decisions.md` if you keep
  that current.
- **PKGBUILDs at `aur/<flavor>/PKGBUILD`, not repo root.** CI fills real
  `sha256sums` before AUR push; in-repo PKGBUILDs use `SKIP`. A manual
  `makepkg -si` from a fresh checkout therefore won't integrity-check
  unless the user runs `updpkgsums` first.
- **End-to-end on a real Arch box has not been smoke-tested.** CI
  builds inside an Arch container and `namcap` is clean, but neither
  flavor has been installed and run against a live Azure zone since
  the extraction. That smoke test is the only meaningful validation
  step still owed — but it's an `azure-ddns`-side concern, not an
  `arch-setup` one.

## Carry-forward work in this repo (ranked)

1. **Migrate postinstall to AUR.** `phase-3-arch-postinstall/postinstall.sh`
   §4d currently consumes the in-repo `metis-ddns/` tree directly.
   Switch it to install from the AUR (`yay -S azure-ddns`, or
   equivalent — whatever AUR helper postinstall already uses). The
   production instance on Metis can stay on the in-repo copy until
   cutover.

2. **Rename env-file paths.** `setup-azure-ddns.sh` and `postinstall.sh`
   currently read/write `/etc/metis-ddns.env`; the upstream package
   expects `/etc/azure-ddns.env`. The runbook references the old path
   too. All three need the same rename in lockstep with §1.

3. **Delete `phase-3-arch-postinstall/metis-ddns/`.** Once §1 lands and
   Metis is cut over, the in-repo copy is dead weight.

4. **Lint workflow cleanup.** `.github/workflows/lint.yml` lists
   `staged-azure-ddns` under `ignore_paths` (line ~44). The directory is
   gone now; drop that line. Trivial — bundle into any nearby commit.

5. **(Optional) Service principal label.** The Azure SP is named
   `metis-ddns` in `setup-azure-ddns.sh`. Cosmetic — rename to
   `azure-ddns` if you want symmetry with the package name, or leave
   it.

## When this file is consumed

Once §1–§4 above are merged, `git rm` this file in the same commit as
§4 (or any later cleanup commit). It exists only to brief the
post-extraction session.
