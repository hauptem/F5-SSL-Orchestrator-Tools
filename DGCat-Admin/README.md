# DGCat-Admin v3.0 — F5 BIG-IP Datagroup & URL Category Manager

![License](https://img.shields.io/badge/license-MIT-green)
![F5 Compatible](https://img.shields.io/badge/F5%20BIG--IP-compatible-orange)
![TMOS Version](https://img.shields.io/badge/TMOS-17.x%2B-red)

A menu-driven administration tool for managing LTM datagroups and custom URL categories on F5 BIG-IP systems. Designed for SSL Orchestrator (SSLO) policy management.

## Features

- **Dual Mode Operation** — Local TMSH or remote REST API
- **Datagroup Management** — Create, view, edit, delete, import/export
- **URL Category Management** — Create, view, edit, delete, import/export
- **Fleet Deployment** — Push changes to multiple BIG-IPs simultaneously
- **Interactive Editor** — Staged editing with add, delete, filter, sort
- **Automatic Backups** — Pre-change backups with configurable retention
- **CSV Import/Export** — Bulk operations via standard CSV files

## Requirements

**TMSH Mode (on BIG-IP):**
- TMOS 17.x or later
- Root or admin shell access

**REST API Mode (remote):**
- curl
- jq
- Network access to BIG-IP management interface (port 443)
- Valid BIG-IP credentials

## Installation

```bash
# Copy to BIG-IP or management host
scp dgcat-admin.sh root@<host>:/shared/scripts/

# Make executable
chmod +x /shared/scripts/dgcat-admin.sh

# Run
/shared/scripts/dgcat-admin.sh
```

## Configuration

Edit these variables at the top of the script:

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_DIR` | `/shared/tmp/dgcat-admin-backups` | Backup and log storage |
| `MAX_BACKUPS` | `30` | Backups retained per object |
| `PARTITIONS` | `Common` | Comma-separated partition list |

### Fleet Configuration

For multi-device deployment, create `${BACKUP_DIR}/fleet.conf`:

```
# Format: SITE|HOSTNAME_OR_IP
DC1|sslo-dc1-primary.example.com
DC1|sslo-dc1-secondary.example.com
DC2|sslo-dc2-primary.example.com
```

## Quick Reference

| Mode | Capabilities |
|------|--------------|
| TMSH | Full functionality including external datagroups and URL category conversion |
| REST API | Internal datagroups, URL categories, fleet deployment |

## License
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
