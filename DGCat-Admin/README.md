# DGCat-Admin v3.0 — F5 BIG-IP Datagroup & URL Category Manager

![License](https://img.shields.io/badge/license-MIT-green)
![F5 Compatible](https://img.shields.io/badge/F5%20BIG--IP-compatible-orange)
![TMOS Version](https://img.shields.io/badge/TMOS-17.x%2B-red)

A menu-driven administration tool for managing LTM datagroups and custom URL categories on F5 BIG-IP systems. Designed for primarily for SSL Orchestrator (SSLO) policy management, but can be used for general purpose datagroup and URL category management.

## Why This Tool?

SSL Orchestrator (SSLO) policies rely heavily on datagroups and URL categories for traffic classification. While you can add sites directly to SSLO policies, this approach has limitations:

- SSLO uses iAppLX to generate APM per-request policies under the hood
- Each host or site added directly becomes an expression in the APM policy
- Large lists could degrade policy performance and are not easily manageable

**The recommended approach:** Use datagroups or URL categories for SSLO security policy rules. They're optimized for fast lookups, keep policies clean and are operationally easier to maintain.

DGCat-Admin makes managing those site lists very easy. 

- Need to export a few massive datagroups or custom url categories so you can precisely replicate existing SSLO business logic at another site in just minutes?
- Need to ingest a large number of subnets or hosts from an excel spreadsheet into a datagroup for SSLO security policy use?
- Want to take a custom URL category and convert it to a datagroup?
- Want to take a datagroup and convert it to a custom URL Category?

**This tool was designed specifically for those purposes.**

# DGCat-Admin v3.0 User Guide

## What This Tool Does

DGCat-Admin manages LTM datagroups and custom URL categories on F5 BIG-IP systems. If you're running SSL Orchestrator, you probably have a bunch of datagroups and URL categories driving your security policies. This tool makes them easier to manage.

You can run it directly on a BIG-IP (TMSH mode) or remotely from any Linux/Mac box with curl and jq (REST API mode). The REST API mode also lets you push changes to multiple BIG-IPs at once.

---

## Quick Start

Copy the script somewhere, make it executable, run it:

```bash
chmod +x dgcat-admin.sh
./dgcat-admin.sh
```

Pick TMSH or REST API mode. The tool checks dependencies and walks you through the rest.

Before first use, you might want to edit the config section at the top of the script:

```bash
BACKUP_DIR="/shared/tmp/dgcat-admin-backups"  # where backups go
MAX_BACKUPS=30                                  # how many to keep per object
PARTITIONS="Common"                             # which partitions to manage
```

---

## TMSH vs REST API Mode

**TMSH mode** runs locally on the BIG-IP. Full functionality, including external datagroups and URL category conversion.

**REST API mode** connects remotely. You get most features plus fleet deployment, but no external datagroups (those need filesystem access).

Pick REST API if you're managing multiple boxes or don't want to SSH into each one. Pick TMSH if you need external datagroups or URL category conversion.

---

## The Menus

Both modes are menu-driven. TMSH mode has 7 options, REST API has 5. The options do what they say — view, create, delete, export, edit.

A few things worth noting:

**Create/Update from CSV** can either create a new object or update an existing one. If the object exists, you choose overwrite (replace everything) or merge (add to what's there).

**Delete** requires typing DELETE to confirm. There's no undo, but the tool creates a backup first.

**Edit** opens an interactive editor where you can make multiple changes before applying them. More on that below.

---

## The Editor

The editor is where you'll spend most of your time if you're doing anything beyond simple imports.

```
  Path:  /Common/my-datagroup
  Class: internal  |  Type: string
  Entries: 150
  (Pending changes - not yet applied)
```

Navigation: `n`/`p` for next/previous page, `g` to jump to a page, `f` to filter, `c` to clear filter, `s` to change sort.

Editing: `a` to add, `d` to delete one entry, `x` to delete by pattern (bulk delete anything matching a string).

Nothing saves until you press `w`. You can add 50 entries, delete 20, change your mind, add 10 more — it's all staged in memory. When you're ready, `w` shows you a summary of what's about to change and asks for confirmation.

In REST API mode with a fleet configured, you also get `D` to deploy changes to multiple BIG-IPs at once.

Press `q` when you're done.

---

## Fleet Deployment

This is the headline feature for v3.0. Configure your BIG-IPs once, then push changes to all of them with a single operation.

### Setup

Create a file called `fleet.conf` in your backup directory:

```
# Format: SITE|HOSTNAME_OR_IP
DC1|10.1.1.10
DC1|10.1.1.11
DC2|10.2.1.10
DC2|10.2.1.11
DR|10.3.1.10
```

The SITE is just a label for grouping — use datacenter names, environments, whatever makes sense. When the tool starts in REST API mode, it'll show what it loaded:

```
  [ OK ]  Fleet loaded: 5 hosts across 3 sites
  [INFO]    DC1: 10.1.1.10, 10.1.1.11
  [INFO]    DC2: 10.2.1.10, 10.2.1.11
  [INFO]    DR: 10.3.1.10
```

### Using It

Connect to any BIG-IP, edit something, make your changes, press `D`.

The tool shows you what's about to change (additions/deletions), lets you pick scope (entire fleet or specific sites), then asks you to type DEPLOY to confirm.

It applies to the device you're connected to first, then hits each fleet member in sequence. Each one gets validated first (can we connect? does the object exist? backup created?) and the config is saved after each successful apply.

If something fails, you'll see it in the summary. If the same error happens 3 times in a row, it stops and tells you there's probably a systemic problem.

### What It Won't Do

Fleet deploy won't create objects that don't exist. If you're pushing changes to a datagroup and one of your fleet members doesn't have that datagroup, it gets skipped. The assumption is you're syncing existing objects, not bootstrapping new environments.

---

## CSV Formats

Datagroups are `key,value` — one per line. Values are optional.

```
example.com,Production
staging.example.com,Staging
dev.example.com
```

For address datagroups, keys are CIDR notation:

```
10.0.0.0/8,Internal
192.168.0.0/16,RFC1918
```

URL categories are just domains, one per line:

```
example.com
www.example.com
.example.org
```

The leading dot means wildcard (matches `*.example.org`). The tool handles the conversion to F5's internal format (`https://*.example.org/`) automatically.

Lines starting with `#` are ignored. Windows line endings are handled automatically.

---

## Backups

The tool creates backups automatically before any destructive operation. They go in your backup directory with timestamps in the filename:

```
Common_my-datagroup_internal_20260327_143052.csv
```

Fleet deployments create per-host backups organized by site:

```
DC1/10.1.1.10_Common_my-datagroup_20260327_143022.csv
```

Old backups are cleaned up automatically based on MAX_BACKUPS.

To restore, just use the Create/Update option and point it at the backup file.

---

## Troubleshooting

**Can't connect in REST API mode** — Check hostname, credentials, and that port 443 is reachable. The user needs API access (usually admin role).

**Partition not found** — The partition you configured doesn't exist on the target BIG-IP. Edit the PARTITIONS variable.

**External datagroups not supported** — These need filesystem access. Use TMSH mode.

**Fleet deploy skipping hosts** — Either the object doesn't exist on that host (expected in some cases) or connectivity/auth failed. Check the summary for details.

**Editor seems slow** — Large datasets (1000+ entries) take a moment to process. The tool shows status messages when it's working.


## License

MIT License - see [LICENSE](LICENSE) file for details.

## Disclaimer

- This solution is **NOT** officially endorsed, supported, or maintained by F5 Inc.
- F5 Inc. retains all rights to their trademarks, including but not limited to "F5", "BIG-IP", "TMOS", "SSL Orchestrator", and related marks
- This is an independent, community-developed solution that utilizes F5 products but is not affiliated with F5 Inc.
- For official F5 support and solutions, please contact F5 Inc. directly

**Technical Disclaimer:**

- This software is provided "AS IS" without warranty of any kind
- The authors and contributors are not responsible for any damages or issues that may arise from its use
- Always test thoroughly in non-production environments before deployment
- Backup your F5 configuration before implementing any changes
- Review and understand all code before deploying to production systems
