# DGCat-Admin — F5 BIG-IP Datagroup & URL Category Manager

![License](https://img.shields.io/badge/license-MIT-green)
![F5 Compatible](https://img.shields.io/badge/F5%20BIG--IP-compatible-orange)
![TMOS Version](https://img.shields.io/badge/TMOS-17.x%2B-red)

A menu-driven administration tool for managing LTM datagroups and custom URL categories on F5 BIG-IP systems via the iControl REST API. Designed primarily for SSL Orchestrator (SSLO) policy management, but can be used for general purpose datagroup and URL category management.

## Why This Tool?

SSL Orchestrator (SSLO) policies rely heavily on datagroups and URL categories for traffic classification. While you can add sites directly to SSLO policies, this approach has limitations:

- SSLO uses iAppLX to generate APM per-request policies under the hood
- Each host or site added directly becomes an expression in the APM policy
- Large lists could degrade policy performance and are not easily manageable

**The recommended approach:** Use datagroups or URL categories for SSLO security policy rules. They're optimized for fast lookups, keep policies clean and are operationally easier to maintain.

DGCat-Admin makes managing those site lists very easy.

- Need to export a few massive datagroups or custom URL categories so you can precisely replicate existing SSLO business logic at another site in just minutes?
- Need to ingest a large number of subnets or hosts from an Excel spreadsheet into a datagroup for SSLO security policy use?
- Want to take a custom URL category and convert it to a datagroup?
- Want to take a datagroup and convert it to a custom URL category?

**This tool was designed specifically for those purposes.**

## Features

- **REST API Driven** — Connects to any BIG-IP via iControl REST from any machine with curl and jq
- **Datagroup Management** — Create, view, edit, delete, import/export
- **URL Category Management** — Create, view, edit, delete, import/export
- **Fleet Deployment** — Push changes to multiple BIG-IPs with pre-deploy validation, backup, and full replace or merge modes
- **Interactive Editor** — Staged editing with add, delete, pattern delete, filter, sort, and paginated browsing
- **Automatic Backups** — Pre-change backups with configurable retention
- **CSV Import/Export** — Bulk operations via standard CSV files
- **API Efficiency** — Partition and URL category DB availability are cached at session start to minimize management plane impact

## Requirements

- curl
- jq
- Network access to BIG-IP management interface (port 443)
- BIG-IP running TMOS 17.x or later

## Installation

```bash
# Copy to a management host or directly to BIG-IP
scp dgcat-admin.sh root@<host>:/shared/scripts/

# Make executable
chmod +x /shared/scripts/dgcat-admin.sh

# Run
/shared/scripts/dgcat-admin.sh
```
## Documentation

See the [USERGUIDE](USERGUIDE.md) for detailed operation instructions.

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
