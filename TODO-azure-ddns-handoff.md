# HANDOFF — Finish wiring Azure DDNS on Metis

**Audience:** a fresh Claude Code session running **on Metis** (Dell Inspiron
7786, user `tom`, single-OS Arch). You have local access to:
- `/tmp/arch-setup` (or `~/arch-setup`) — checkout of `fnrhombus/arch-setup`
- The internet, including the public `fnrhombus/azure-ddns` repo
- A working browser for the device-code auth flow

**You may push to `fnrhombus/arch-setup` exactly once**, and only to commit
the handoff-back document described at the end of this file (and the
deletion of this `TODO-azure-ddns-handoff.md`). No other commits, no
incidental cleanup, no fixes-while-you're-here. If you find other issues,
write them into the handoff-back's "Other findings" section — the next
session will act on them.

**You may freely modify `fnrhombus/azure-ddns`** if you discover bugs or
drift while you're in there.

---

## Why this exists

The Arch reinstall has run end-to-end on Metis. Phase 3 postinstall installed
`azure-cli`, `bw`, and `gh`, staged `~/setup-azure-ddns.sh` into `/home/tom/`,
and dropped a stub `/etc/metis-ddns.env` from the template. The Azure-side
provisioning hasn't run yet — `az` is not authenticated, the service
principal doesn't exist, and the DDNS daemon's env file has placeholder
values. Your job is to finish that.

There's a secondary task: a stand-alone public extraction of the DDNS code
now lives at `https://github.com/fnrhombus/azure-ddns` (renamed from
`metis-ddns`). The in-arch-setup copy at
`phase-3-arch-postinstall/metis-ddns/` is the still-deployed production
copy, but `fnrhombus/azure-ddns` is meant to become the upstream. Part of
your handoff is reporting whether they've drifted.

---

## What you can rely on (already in place)

- `azure-cli` is installed (`command -v az` works)
- `~/setup-azure-ddns.sh` exists and is executable (staged from
  `phase-3-arch-postinstall/setup-azure-ddns.sh` by install.sh §11)
- The systemd unit + timer + NM dispatcher hook for `metis-ddns` are
  installed and **enabled but not yet started cleanly** — the timer's
  first ticks have failed because `/etc/metis-ddns.env` is the template stub
- The DNS zone `rhombus.rocks` already exists in Azure resource group
  `rhombus`. You don't create zones; you create records inside one.

## Identity / configuration constants

These are hardcoded in `setup-azure-ddns.sh`. Do not change them:

| Field | Value |
|---|---|
| Subscription ID | `ab78414a-6bf4-4d87-b27c-954c41aa8081` |
| Resource group | `rhombus` |
| DNS zone | `rhombus.rocks` |
| Record name | `metis` (FQDN: `metis.rhombus.rocks`) |
| SP display name | `metis-ddns` |
| Role | `DNS Zone Contributor` (scoped to the zone) |

---

## Your tasks, in order

### 1. Cold-context read (don't skip)

Before doing anything, read these in this order:

1. `docs/decisions.md` — locked-in design decisions for the box you're on
2. `phase-3-arch-postinstall/setup-azure-ddns.sh` — the script you'll run
3. `phase-3-arch-postinstall/postinstall.sh` lines 511-553 — how the daemon
   is wired into the system (note: section is named `4d. metis-ddns`)
4. `phase-3-arch-postinstall/metis-ddns/` — the bash script + systemd units
   + NM hook that postinstall installs from
5. `runbook/phase-3-handoff.md` — broader context on the laptop's stack
6. The `fnrhombus/azure-ddns` repo (clone it to `/tmp/azure-ddns` and read
   every file, especially `bin/azure-ddns`, `systemd/`, `dispatcher.d/`,
   `PKGBUILD`, and `README.md`)

You should be able to answer these before moving on:
- What the daemon's update loop looks like (env file → token mint → IP detect
  → PUT-or-skip → write IP cache).
- Whether the in-arch-setup `metis-ddns` script and the upstream
  `azure-ddns` script have any non-cosmetic differences.

### 2. Compare the two implementations

Run a structural diff (don't expect it to be byte-clean — names differ):

```bash
diff -u \
  <(sed 's/metis-ddns/azure-ddns/g; s/metis\.rhombus\.rocks/<RECORD>.<ZONE>/g' \
       phase-3-arch-postinstall/metis-ddns/metis-ddns) \
  /tmp/azure-ddns/bin/azure-ddns
```

Note any logic differences (not just naming). Same exercise for the
`.service`, `.timer`, and `90-*` dispatcher hook files. Capture the result
for your handoff-back doc.

### 3. Authorize Azure CLI

Use device code flow — there is a browser on this machine but the device-code
path is more reliable for unattended scripting:

```bash
az login --use-device-code
```

Visit the URL it prints, enter the code, sign in. Then verify:

```bash
az account show --query id -o tsv
# Must equal: ab78414a-6bf4-4d87-b27c-954c41aa8081
```

If the user has multiple subscriptions, set it explicitly:

```bash
az account set --subscription ab78414a-6bf4-4d87-b27c-954c41aa8081
```

Confirm zone visibility (cheap read; fails loud if RBAC is wrong):

```bash
az network dns zone show -g rhombus -n rhombus.rocks --query name -o tsv
```

If that fails with a permission error, **stop**. The user's az identity
needs at minimum `Reader` on the zone, plus `Application.ReadWrite.OwnedBy`
in Entra ID for the SP creation, plus `Owner` or `User Access Administrator`
on the zone (or its RG/subscription) for the role assignment. Surface this
clearly in your handoff-back doc and let the user fix it.

### 4. Run the provisioning script

```bash
bash ~/setup-azure-ddns.sh
```

This is idempotent — re-runs rotate the SP secret rather than appending.
Expected output, in order:
1. `[+] azure-cli not authenticated` (skipped if step 3 worked) or `[+] Tenant: <guid>`
2. `[+] Reusing existing app …` or `[+] Creating app registration …`
3. `[+] Ensuring service principal exists for app...`
4. `[+] Rotating secret …`
5. `[+] Ensuring DNS Zone Contributor assignment on rhombus.rocks...`
6. `[+] Writing /etc/metis-ddns.env...`
7. `[+] Writing /etc/letsencrypt/azure.ini...`
8. `[+] Starting metis-ddns service...`

If any step fails, do **not** keep going — capture the failure verbatim in
your handoff-back doc.

### 5. Verify end-to-end

```bash
# Daemon status
systemctl status metis-ddns.service --no-pager
systemctl status metis-ddns.timer --no-pager
sudo journalctl -u metis-ddns -n 50 --no-pager

# DNS resolution (give Azure 30-60s after the service first runs cleanly)
dig +short A metis.rhombus.rocks
dig +short AAAA metis.rhombus.rocks

# What public IP did the daemon detect?
sudo cat /var/lib/metis-ddns/last-ipv4 2>/dev/null
sudo cat /var/lib/metis-ddns/last-ipv6 2>/dev/null

# What does ipify report from this host right now?
curl -s https://api.ipify.org
echo
curl -s https://api6.ipify.org
echo
```

Success criteria: `dig` returns at least one of A or AAAA, matching the
public IPs ipify reported. The journal shows a `PUT` succeeded (HTTP 200 or
201) for each address family that's enabled.

If only one family resolves, that's fine if the user's network is
single-stack. If neither, something's wrong — capture the journal and
ipify output in your handoff-back doc.

### 6. Cross-check the staged folder

The user wants `staged-azure-ddns/` (a sibling directory to the phase
folders in `arch-setup`) deleted, but only if nothing in
`install.sh` / `chroot.sh` / `postinstall.sh` references it. Verify:

```bash
grep -rn "staged-azure-ddns" /tmp/arch-setup/ \
    || echo "No references — safe to delete from arch-setup."
```

Whatever you find, note it in your handoff-back. **Do not delete anything
from `arch-setup` yourself** — the other session will do that based on
your report.

---

## Failure modes & what to do

| Symptom | Likely cause | Action |
|---|---|---|
| `az login` opens a browser anyway and hangs | DBUS session weirdness on Hyprland; device-code flag was honored but browser opened too | Cancel the browser tab; the device-code flow in the terminal still works. Don't restart `az login`. |
| `az ad app create` fails with `Insufficient privileges` | User is signed in to a tenant where they lack Entra ID app-creation rights | Stop. Note tenant ID + the user's role in Entra ID. They may need to switch tenants (`az login --tenant <other-tenant-id>`) or get rights granted. |
| `az role assignment create` fails with `Authorization_RequestDenied` | User lacks `Owner`/`UAA` on the zone scope | Same as above — note in handoff-back, don't try to work around. |
| `metis-ddns.service` keeps failing post-`setup-azure-ddns.sh` | `/etc/metis-ddns.env` mode wrong, or one of TENANT/CLIENT/SECRET/SUB is blank | `sudo cat /etc/metis-ddns.env` (mode 600 root:root); confirm all four AZ_* vars have values. If any are blank, re-run `setup-azure-ddns.sh`. |
| `dig` returns nothing after 5 minutes | Azure DNS NS propagation takes longer? No — record creation is sub-second. More likely the service hasn't fired yet (timer is `OnUnitActiveSec=10min`); kick it manually: `sudo systemctl start metis-ddns.service` and re-check. |
| AAAA-only on a dual-stack network | `DDNS_DISABLE_IPV4=1` left over in `/etc/metis-ddns.env` | Edit the env file, set to `0`, restart service. |

If you hit something not in this table: *don't keep poking*. Capture state
(journal + env file + `az` errors) and put it in your handoff-back doc.

---

## Rules of engagement

- **`fnrhombus/arch-setup` is read-only EXCEPT for the single handoff-back
  commit** described in the next section. Don't `git add` anything else,
  don't `git commit -a`. Stage explicitly by path.
- **Do not commit anything to `fnrhombus/azure-ddns`** unless you find an
  actual bug (e.g. logic divergence from the in-arch-setup copy that's a
  regression upstream). If you do commit, atomic commits, no force-push,
  push to a new branch and link it from your handoff-back rather than to
  `main` directly.
- **Do not run `tpm2_clear`, `pinutil delete`, or any other destructive
  TPM/PAM operation** to "investigate." The DDNS work has nothing to do
  with those subsystems.
- **Do not run `pacman -Syu` or `yay -Syu`.** This system is on whatever
  package versions postinstall left. If a package is broken, surface it;
  don't update.
- **Do not enable or modify Secure Boot** — it's deliberately off until
  the user runs through the sbctl handoff.

---

## Your output: a handoff-back document committed to arch-setup

When you're done — successful or not — write a markdown file at the **root
of the arch-setup checkout**:

```
HANDOFF-BACK-azure-ddns.md
```

This file is what the next `arch-setup` Claude session will read. It must
be self-contained: that session won't have your conversation context, only
the contents of this file.

You will commit and push it as the **single allowed write** to
`fnrhombus/arch-setup`. See "Cleanup" at the end for exactly how.

### Required sections

1. **Outcome** — one of: `success`, `partial`, `blocked`. One sentence.
2. **What was done** — every command you ran, in order, with truncated
   output where useful. Include the timestamps for `az` operations so the
   next session can correlate against Azure activity logs if anything looks
   off.
3. **Verification** — `dig` output, ipify output, `systemctl status` output,
   journal tail. Concrete evidence the daemon is or isn't working.
4. **Drift between `metis-ddns` (in arch-setup) and `azure-ddns` (upstream)** —
   structural diff results from task 2. List each non-cosmetic difference.
   Recommend: should arch-setup migrate to consuming the upstream package
   (PKGBUILD from AUR / git submodule / vendored copy)? Why or why not?
5. **`staged-azure-ddns/` deletion** — confirm whether install/chroot/post
   scripts reference it (they shouldn't), and recommend deletion.
6. **Anything else worth surfacing** — e.g. the user's az identity is
   tenant-bound in a way that complicates SP creation, or the upstream
   `azure-ddns` PKGBUILD is broken, or NetworkManager dispatcher isn't
   firing on link-up.
7. **Suggested next-session prompts** — bullet list of imperatives the
   next `arch-setup` session can act on (e.g. "delete `staged-azure-ddns/`
   directory", "update postinstall §4d to install from `fnrhombus/azure-ddns`
   AUR package", etc.).

### Format

```markdown
# Azure DDNS handoff-back — <YYYY-MM-DD>

## Outcome
<success | partial | blocked>: <one sentence>

## What was done
1. <step>: <command>
   <truncated output if relevant>
2. ...

## Verification
<dig / ipify / systemctl / journal blocks>

## Drift report
- <difference 1>
- <difference 2>
...
**Recommendation:** <migrate | keep both | other> — <one sentence why>

## staged-azure-ddns/ deletion
<grep result>
**Safe to delete: yes/no.**

## Other findings
- <bullet>

## Next-session prompts
- [ ] <imperative>
- [ ] <imperative>
```

Keep it tight — the next session does not need a narrative, it needs facts
and clear next steps.

---

## Cleanup — your single allowed push to arch-setup

Once `HANDOFF-BACK-azure-ddns.md` is written, commit and push it. In the
**same commit**, delete this file (`TODO-azure-ddns-handoff.md`) — your
input is consumed and the handoff-back supersedes it.

```bash
cd /tmp/arch-setup     # or wherever the checkout lives
git checkout main
git pull --ff-only origin main      # in case anything moved while you worked
git add HANDOFF-BACK-azure-ddns.md
git rm TODO-azure-ddns-handoff.md
git commit -m "azure-ddns: handoff-back report ($(date +%F))"
git push origin main
```

If the push fails because main moved while you were working, `git pull
--rebase origin main` and push again — but **do not** make a second
substantive commit. The rebase should only re-apply your one commit.

That's it. Don't open a PR, don't do "while I'm here" cleanup, don't
suggest a refactor. One task: get DDNS running on Metis and report back
in a single commit.
