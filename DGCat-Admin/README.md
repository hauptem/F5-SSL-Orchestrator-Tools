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

MIT License — see [LICENSE](LICENSE) file.

## Disclaimer

This is an independent, community-developed tool. **NOT** officially endorsed, supported, or maintained by F5 Inc. F5, BIG-IP, TMOS, and SSL Orchestrator are trademarks of F5 Inc.

Provided "AS IS" without warranty. Always test in non-production environments first. Backup your configuration before making changes.
