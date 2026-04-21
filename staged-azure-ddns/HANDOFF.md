# HANDOFF: `staged-azure-ddns/` → `fnrhombus/azure-ddns`

You (a fresh Claude session in the `fnrhombus/azure-ddns` repo) have just inherited the contents of this directory as your new working tree. This doc exists to brief you cold — no shared context with the session that produced these files.

## What this is

A small bash + systemd utility that keeps Azure DNS A/AAAA records in sync with the host's current public IP(s). Fills a real gap: `ddclient` has no Azure provider ([ddclient#517](https://github.com/ddclient/ddclient/issues/517), open since 2022), `inadyn`'s basic-auth model doesn't fit Azure's bearer-token flow, and every `azure-ddns` project on GitHub/AUR that I could find had been abandoned for 12+ months.

~100 lines of bash + systemd service + timer + NetworkManager dispatcher hook. Deps: `bash curl jq systemd`. MIT-licensed.

## Where it came from

Extracted from [fnrhombus/arch-setup](https://github.com/fnrhombus/arch-setup) (branch `claude/fix-linux-boot-issue-9ps2s`, as of 2026-04-21). The original working copy still lives in that repo at `phase-3-arch-postinstall/metis-ddns/` under Metis-specific naming (Metis = user's Dell Inspiron 7786 laptop; rhombus.rocks = user's domain on Azure DNS).

The extraction generalized:
- `metis-ddns` → `azure-ddns` (binary name, service name, timer name, NM hook name, paths)
- `/etc/metis-ddns.env` → `/etc/azure-ddns.env`
- `/var/lib/metis-ddns/` → `/var/lib/azure-ddns/`
- `/run/metis-ddns-token.json` → `/run/azure-ddns-token.json`
- Hardcoded zone "rhombus.rocks" and record "metis" → always read from env vars (they already were in the original, but the defaults pointed at rhombus.rocks in the Metis template)
- `DDNS_DISABLE_IPV4=1` (IPv6-only default for Metis's NAT'd network) → `DDNS_DISABLE_IPV4=0` (both stacks enabled by default; users disable per their topology)

If you need to cross-reference or back-port a bug fix, the fnrhombus/arch-setup copy at `phase-3-arch-postinstall/metis-ddns/` is the still-running production instance.

## Repo visibility

**User directive: keep this repo private until the PKGBUILD has been verified on a fresh Arch VM and at least one external user reports success.** The plan is to flip public once there's some confidence it actually works outside the author's laptop.

## Files in this tree (and their destinations)

```
staged-azure-ddns/
├── HANDOFF.md                        ← you are here (drop when moving to real repo)
├── README.md                         → repo root, user-facing docs
├── LICENSE                           → repo root, MIT
├── PKGBUILD                          → repo root, AUR recipe
├── azure-ddns.env.template           → /etc/azure-ddns.env (mode 600)
├── bin/
│   └── azure-ddns                    → /usr/bin/azure-ddns (mode 755)
├── systemd/
│   ├── azure-ddns.service            → /usr/lib/systemd/system/azure-ddns.service
│   └── azure-ddns.timer              → /usr/lib/systemd/system/azure-ddns.timer
└── dispatcher.d/
    └── 90-azure-ddns                 → /usr/lib/NetworkManager/dispatcher.d/90-azure-ddns (mode 755)
```

The PKGBUILD already encodes these install paths.

## What's expected of you (ranked)

1. **Delete this HANDOFF.md** from the new repo's working tree once you've read it — it exists only for the cold-start briefing and clutters a public repo root. Commit the deletion separately from any other work.
2. **Verify the PKGBUILD on a fresh Arch box.** Clean container or VM, `makepkg -si`, confirm all files land at the install paths above with the right modes. Run `namcap PKGBUILD` to catch obvious lint.
3. **Tag `v0.1.0`.** The PKGBUILD's `source` URL points at `https://github.com/fnrhombus/$pkgname/archive/refs/tags/v$pkgver.tar.gz`, so the tag must exist before the PKGBUILD will resolve.
4. **End-to-end smoke test** against a real Azure DNS zone (or a throwaway subscription with a test zone). Confirm: first run creates the record, token is cached at `/run/azure-ddns-token.json`, subsequent no-change runs exit cheaply, timer + dispatcher hook both fire.
5. **AUR submission.** PKGBUILD is ready. `makepkg --printsrcinfo > .SRCINFO` before pushing to AUR.
6. **(Optional) Post a brief intro on r/AZURE or r/archlinux** for discovery once the repo is public.

Track these as GitHub issues once the repo is created so you don't have to remember them.

## Known gaps (file as issues after repo creation)

- **Multi-record-per-host**: would need `azure-ddns@.service` templated unit + per-instance `/etc/azure-ddns/<instance>.env`. Current design is single-record per host. Don't block v0.1.0 on this.
- **No `--dry-run` / `--test` flag.** Useful for config validation without minting a token.
- **No MX / TXT / CNAME record types.** A+AAAA only. Scope for v0.1.0.
- **PKGBUILD assumes a release tarball.** A `-git` variant that builds from HEAD would cover early adopters.
- **No tests.** A mock-Azure end-to-end harness is overkill for v0.1.0, but consider a shellcheck pass in CI. `shellcheck bin/azure-ddns` should be clean.

## Design choices worth preserving

- **ipify for IP detection, with stack-specific hostnames.** `api.ipify.org` is dual-stack and returns whichever family `curl` routes first; `api6.ipify.org` forces v6. Don't "simplify" by falling back to the dual-stack endpoint.
- **PUT (CreateOrUpdate), not PATCH.** PATCH on Azure DNS record sets only updates metadata (TTL, tags) — not the IP set. This took me a minute to find and it's not obvious from the error you'd get if you picked PATCH.
- **Env file read inside the script, not via `EnvironmentFile=`.** If `EnvironmentFile=` fails, systemd journals the failure with the filename — but if the file IS readable and has an empty variable, some older systemd versions logged the variable name and value at debug level. Safer to keep secrets out of systemd's hands entirely.
- **Service hardening.** `NoNewPrivileges`, `ProtectSystem=strict`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, `MemoryDenyWriteExecute`, etc. — audited against the actual syscall needs of the script. Don't relax without a reason.
- **Token cache in `/run` (tmpfs), IP cache in `/var/lib` (persistent).** The token is short-lived (~1h) and can always be re-minted; the IP cache is the "nothing changed, skip the Azure call" short-circuit.

## Non-goals

- Multi-distro packaging (deb/rpm). Systemd is a hard dep; Arch is the first-class target.
- A config DSL or hostfile schema — one record per env file, stay simple.
- Replacing bash with Go/Rust. The dep set is tiny (curl, jq, systemd) and everyone already has them. Bash is the right call here.

## Security notes (carried forward to README)

- Credentials file is `mode 600 root:root`. README nags users about this.
- Service principal is scoped to a single DNS zone — compromise limits blast radius to record churn on that one zone.
- One maintainer, no formal security audit. README says so explicitly. Appropriate for home/lab single-host use; production deployments should review.

## If you get stuck

The arch-setup repo has richer context: `docs/decisions.md` and `docs/remaining-work.md` there explain why this was extracted and what the original production instance is doing. If anything in this staging tree looks wrong, cross-check against `phase-3-arch-postinstall/metis-ddns/` in that repo — the post-extraction source of truth until this repo goes public.
