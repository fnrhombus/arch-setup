---
name: Azure DDNS — config lives in the setup script
description: rhombus.rocks DDNS uses a non-default Azure tenant; setup-azure-ddns.sh hardcodes `--tenant` to skip multi-tenant fan-out. Specific tenant / subscription / owning-account values are in the script, not duplicated in memory.
type: project
originSessionId: 1f608502-800c-4723-a701-24396c206988
---
The Azure resources for `rhombus.rocks` DDNS are configured in `phase-3-arch-postinstall/setup-azure-ddns.sh` §1 (the `# ---- Locked config from project memory ----` block). That block is the source of truth for:

- `TENANT_ID`
- `SUBSCRIPTION_ID`
- `RESOURCE_GROUP` (`rhombus`)
- `DNS_ZONE` (`rhombus.rocks`)
- `RECORD_NAME` (`metis`)
- `SP_DISPLAY_NAME` (`metis-ddns`)

Owning Azure account email and tenant display name are also referenced inline in that script's comments.

**Why:** The user has multiple Azure tenants. `az login` without `--tenant` defaults to the user's home tenant where the `rhombus.rocks` subscription does NOT exist — the script would then error with "No subscriptions found." MFA was required for the non-default tenant but not surfaced cleanly. `setup-azure-ddns.sh` hardcodes the `--tenant` flag to skip the multi-tenant fan-out.

**How to apply:**
- When editing `setup-azure-ddns.sh` or related Azure code, read IDs directly from the script's §1 block — don't re-derive them from anywhere else.
- For a fresh interactive `az login`, recommend `az login --tenant <TENANT_ID>` where `<TENANT_ID>` comes from the script's §1.
- The DNS zone resource path follows: `/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rhombus/providers/Microsoft.Network/dnszones/rhombus.rocks`.
- `lego` (cert renewal) reads the same values from `/etc/lego/lego.env`, which `setup-azure-ddns.sh` writes alongside `/etc/azure-ddns.env`.

**Don't:** duplicate the tenant / subscription / email values in this memory file or anywhere else in the repo. The script is the single source of truth — keeps redaction trivial if a future repo move (rhombu5 vs fnrhombus) requires re-evaluating sensitivity.
