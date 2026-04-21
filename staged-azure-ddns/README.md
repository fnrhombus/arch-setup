# azure-ddns

Dynamic DNS updater for [Azure DNS](https://learn.microsoft.com/azure/dns/) — keeps an A and/or AAAA record in sync with the host's current public IP(s).

Fills a real gap: `ddclient` has no Azure protocol ([ddclient#517](https://github.com/ddclient/ddclient/issues/517), open since 2022), `inadyn`'s basic-auth model doesn't fit Azure's bearer-token flow, and every `azure-ddns` project on GitHub/AUR I could find had been abandoned for at least 12 months.

~100 lines of bash + a systemd timer + a NetworkManager dispatcher hook. Deps: `bash curl jq systemd`.

## Install

### Arch / AUR

```
yay -S azure-ddns
```

### From source (any systemd distro)

```
git clone https://github.com/fnrhombus/azure-ddns
cd azure-ddns
sudo install -Dm755 bin/azure-ddns /usr/local/bin/azure-ddns
sudo install -Dm644 systemd/azure-ddns.service /etc/systemd/system/azure-ddns.service
sudo install -Dm644 systemd/azure-ddns.timer   /etc/systemd/system/azure-ddns.timer
sudo install -Dm755 dispatcher.d/90-azure-ddns /etc/NetworkManager/dispatcher.d/90-azure-ddns
sudo install -Dm600 azure-ddns.env.template    /etc/azure-ddns.env
sudo install -d -m 755 /var/lib/azure-ddns
sudo systemctl daemon-reload
sudo systemctl enable azure-ddns.timer
```

## One-time setup

### 1. Create a service principal scoped to the DNS zone

You'll need the [`az` CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) and an Azure subscription that already hosts the DNS zone.

```bash
az login                                 # device-code flow

SUB=$(az account show --query id -o tsv)
RG=<resource-group-with-the-DNS-zone>
ZONE=<your-zone-name>                    # e.g. example.com
ZONE_ID=$(az network dns zone show -g "$RG" -n "$ZONE" --query id -o tsv)

az ad sp create-for-rbac \
    --name azure-ddns \
    --role "DNS Zone Contributor" \
    --scopes "$ZONE_ID" \
    --years 2
```

The last command prints `appId`, `password`, `tenant` — save these, `password` is shown exactly once.

**Why "DNS Zone Contributor":** it's the built-in Azure role with the minimum privileges required to update record sets on a single zone. Don't grant `Contributor` — that would scope to the whole RG.

**Secret rotation:** the default lifetime is 2 years with `--years 2` (1 year without). Azure does not auto-rotate SP secrets. Calendar yourself a reminder.

### 2. Fill in `/etc/azure-ddns.env`

```ini
AZ_TENANT_ID=<tenant>
AZ_CLIENT_ID=<appId>
AZ_CLIENT_SECRET=<password>
AZ_SUBSCRIPTION_ID=<SUB>
AZ_RESOURCE_GROUP=<RG>
AZ_DNS_ZONE=example.com
AZ_DNS_RECORD=myhost           # becomes myhost.example.com

# Optional:
# AZ_DNS_TTL=300               # default 300s
# DDNS_DISABLE_IPV4=1          # IPv6-only mode
# DDNS_DISABLE_IPV6=1          # IPv4-only mode
```

### 3. Kick the first run

```bash
sudo systemctl start azure-ddns.service
sudo journalctl -u azure-ddns -n 20
```

First call may return `403 AuthorizationFailed` — Azure role assignments propagate in 30s–5min. Wait and retry.

### 4. Verify externally

From any host (or your phone):

```bash
dig A myhost.example.com +short
dig AAAA myhost.example.com +short
```

## How it works

- Detects public IPs via `api.ipify.org` (v4) and `api6.ipify.org` (v6). The stack-specific hostnames force which family `curl` uses; the plain dual-stack host would otherwise return whichever family routes first.
- Caches last-pushed values at `/var/lib/azure-ddns/{a,aaaa}.last`. If nothing changed, the run exits early with no Azure traffic (one cheap ipify probe per enabled stack).
- Caches the OAuth2 client-credentials token at `/run/azure-ddns-token.json` (1h TTL). Minted lazily on first IP change after a reboot.
- Uses `PUT` (CreateOrUpdate) against `api-version=2018-05-01`, so first run creates the record if it doesn't exist.
- `OnBootSec=2min`, `OnUnitActiveSec=10min` — timer cadence. NetworkManager dispatcher also fires on interface-up so link reconnects don't wait for the next tick.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `403 AuthorizationFailed` on first run | Role not yet propagated | Wait 5 min, retry |
| `AADSTS530034` from token endpoint | Conditional Access blocks SPs | Ask tenant admin for exclusion |
| `AADSTS7000215` invalid client secret | Typo in env file, or secret expired | Regenerate: `az ad sp credential reset --id <appId>` |
| `400 BadRequest` on PUT | Record name or zone typo | `az network dns zone show -g $RG -n $ZONE` to confirm |
| Service runs but DNS doesn't update | TTL still valid at resolver | Wait for TTL, or `dig @ns1-01.azure-dns.com ...` to check the authoritative side |

## Security notes

- Credentials file is `mode 600 root:root`. Don't world-read it.
- Service principal is scoped to a single DNS zone — compromise limits blast radius to DNS record churn on that one zone.
- systemd unit ships with hardening (NoNewPrivileges, ProtectSystem=strict, RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX, MemoryDenyWriteExecute, etc.).
- This project has one maintainer and no formal security audit. Appropriate for home/lab single-host use. If you're running it in production for an org, do your own review.

## Non-goals

- Multiple records per host (run multiple `azure-ddns@.service` instances with per-instance env files — not yet wired, see issues).
- Non-Azure DNS backends (use `ddclient` or `inadyn` — they cover everything else).
- Windows host support (systemd is a hard dep).

## License

MIT. See [LICENSE](LICENSE).

## Related

- [ddclient](https://github.com/ddclient/ddclient) — dynamic DNS client for ~30 other providers.
- [inadyn](https://github.com/troglobit/inadyn) — dynamic DNS client, C.
- [Azure DNS REST API docs](https://learn.microsoft.com/rest/api/dns/).
