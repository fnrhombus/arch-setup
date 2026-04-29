# HANDOFF — Extract azure-ddns into its own repo

**Audience:** a fresh Claude Code session with read access to
`fnrhombus/arch-setup` and read+write access to `fnrhombus/azure-ddns`.

**Task, in one sentence:** publish the contents of
`staged-azure-ddns/` (in arch-setup) to the standalone repo
`fnrhombus/azure-ddns`, then write a short report back here.

That's the entire scope. Not running `az login`, not deploying DDNS, not
touching `/etc/metis-ddns.env` on any host, not modifying the in-arch-setup
production copy at `phase-3-arch-postinstall/metis-ddns/`. Just the
extraction.

---

## Context (read these before doing anything)

1. `staged-azure-ddns/HANDOFF.md` in arch-setup — the original briefing that
   describes the rename map (`metis-ddns` → `azure-ddns`, env paths, etc.)
   and the file → install-path mapping. **That doc is ground truth for
   what the new repo should contain.**
2. `staged-azure-ddns/README.md` and `staged-azure-ddns/PKGBUILD` in
   arch-setup — user-facing docs and AUR recipe. They go in the new repo's
   root.
3. `phase-3-arch-postinstall/metis-ddns/` in arch-setup — the still-running
   production copy. Read it to confirm the staged tree matches (modulo the
   renames). Don't modify it.

---

## What to do

### 1. Determine current state of `fnrhombus/azure-ddns`

It may or may not exist yet. Check:

```bash
gh repo view fnrhombus/azure-ddns 2>/dev/null && echo EXISTS || echo MISSING
```

(or equivalently a `git ls-remote https://github.com/fnrhombus/azure-ddns`).

Three cases:

- **Missing** → create it (private, per the staged HANDOFF.md directive:
  *"keep this repo private until the PKGBUILD has been verified on a fresh
  Arch VM and at least one external user reports success"*).
- **Exists, empty** → push the staged tree as the initial commit.
- **Exists, populated** → diff against the staged tree. If they match
  modulo cosmetic differences, do nothing and report. If the staged tree
  is newer, open a PR (don't force-push to main).

### 2. If creating: initialize from the staged tree

```bash
# Work in /tmp, never inside the arch-setup checkout
mkdir -p /tmp/azure-ddns
cp -r /path/to/arch-setup/staged-azure-ddns/. /tmp/azure-ddns/
cd /tmp/azure-ddns

# Drop the handoff doc — it was for this extraction, not for the public repo
rm HANDOFF.md

git init -b main
git add .
git commit -m "initial extraction from fnrhombus/arch-setup"
gh repo create fnrhombus/azure-ddns --private --source=. --remote=origin --push
```

Verify the PKGBUILD lints cleanly (don't fix it if it doesn't — just
report):

```bash
namcap PKGBUILD 2>&1 || echo "namcap not installed, skipping"
shellcheck bin/azure-ddns 2>&1 || true
```

### 3. If exists and populated: diff and reconcile

```bash
# Clone the existing repo
git clone https://github.com/fnrhombus/azure-ddns /tmp/azure-ddns

# Diff structurally (the staged copy is canonical-as-of-this-handoff)
diff -ru \
  /path/to/arch-setup/staged-azure-ddns/ \
  /tmp/azure-ddns/ \
  2>&1 | tee /tmp/azure-ddns-diff.txt
```

If the diff is empty (or only `HANDOFF.md` differs — that file is meant to
be dropped), stop. Move on to the report.

If there are real differences and the staged copy is *ahead*, push as a
branch + PR — don't auto-merge:

```bash
cd /tmp/azure-ddns
git checkout -b sync-from-arch-setup-$(date +%Y%m%d)
# overwrite with staged tree (excluding HANDOFF.md and .git)
rsync -a --delete \
  --exclude=.git --exclude=HANDOFF.md \
  /path/to/arch-setup/staged-azure-ddns/ ./
git add -A
git commit -m "sync from arch-setup staging"
git push -u origin HEAD
gh pr create --fill --draft
```

If there are differences and the *upstream* is ahead (someone edited
azure-ddns after the staging snapshot), do nothing. Note the divergence in
the report.

### 4. Smoke-check (no deployment, no Azure auth)

Just structural sanity. Don't run anything against a live system or Azure:

- `bash -n bin/azure-ddns` — syntax-only parse
- `systemd-analyze verify systemd/azure-ddns.service systemd/azure-ddns.timer`
  if available
- `head -1 dispatcher.d/90-azure-ddns` — confirm shebang

---

## Rules of engagement

- **`fnrhombus/arch-setup` is read-only**, except for the single
  handoff-back commit described below. Don't `git add` anything else
  in this repo. Don't fix typos, don't refactor, don't edit
  `phase-3-arch-postinstall/metis-ddns/` even if it has obvious bugs —
  surface those in the report.
- **`fnrhombus/azure-ddns`** is your sandbox. Push freely (atomic commits,
  no force-push to main). For an existing populated repo, branches and
  PRs only — do not push to main.
- **Do not run `az login`** or any Azure CLI mutation. If you need to
  *probe* Azure (e.g. `az network dns zone show` to confirm a name),
  ask the user before authenticating. The default is: don't.
- **Do not deploy or restart `metis-ddns.service`** on any host.

---

## Your output: a handoff-back commit to arch-setup

Write a markdown file at the **root of the arch-setup checkout**:

```
HANDOFF-BACK-azure-ddns.md
```

Then commit it together with the deletion of this handoff (which has
served its purpose) and the deletion of the `staged-azure-ddns/` directory
(now redundant — its contents live upstream). That single commit is your
**only allowed write** to `fnrhombus/arch-setup`.

```bash
cd /path/to/arch-setup
git checkout main
git pull --ff-only origin main
git add HANDOFF-BACK-azure-ddns.md
git rm TODO-azure-ddns-handoff.md
git rm -r staged-azure-ddns/
git commit -m "azure-ddns: extracted to fnrhombus/azure-ddns; report back"
git push origin main
```

If the push races with another commit, `git pull --rebase origin main` and
push again — but do not make any second substantive commit.

### What goes in `HANDOFF-BACK-azure-ddns.md`

Fact-dense, no narrative. The next arch-setup session needs to act on it.

```markdown
# Azure DDNS extraction — handoff back

## Outcome
<created | synced | already-current | blocked>: <one sentence>

## Repo state
- URL: https://github.com/fnrhombus/azure-ddns
- Visibility: <private | public>
- Default branch: main
- HEAD commit: <sha> "<message>"
- File tree: `bin/azure-ddns`, `systemd/azure-ddns.{service,timer}`,
  `dispatcher.d/90-azure-ddns`, `azure-ddns.env.template`,
  `README.md`, `LICENSE`, `PKGBUILD`

## Drift between in-arch-setup `metis-ddns/` and upstream `azure-ddns`
<diff summary, or "naming-only — no logic differences">

## Smoke-check results
- `bash -n bin/azure-ddns`: <pass | fail + first error>
- `systemd-analyze verify`: <pass | fail | not-run>
- `namcap PKGBUILD`: <output | not-run>

## Suggested next-session work for arch-setup
- [ ] Update `phase-3-arch-postinstall/postinstall.sh` §4d to install
      `azure-ddns` from AUR (once the PKGBUILD is submitted there) or via
      a `git clone + makepkg -si` of `fnrhombus/azure-ddns`, instead of
      consuming the in-repo `metis-ddns/` tree.
- [ ] Delete `phase-3-arch-postinstall/metis-ddns/` once postinstall §4d
      is migrated.
- [ ] Adjust the env-file path: postinstall currently writes to
      `/etc/metis-ddns.env`; the upstream package expects
      `/etc/azure-ddns.env`. `setup-azure-ddns.sh` and any docs/runbook
      references need the same rename.
- [ ] <other items you discovered>

## Things you noticed but did NOT fix
<bullets — bugs in metis-ddns/, doc drift, README typos, etc.>
```

That's the entire output. Once pushed, you're done.
