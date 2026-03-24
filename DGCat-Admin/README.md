# DGCat-Admin F5 Big-IP Datagroup Manager

![License](https://img.shields.io/badge/license-MIT-green)
![F5 Compatible](https://img.shields.io/badge/F5%20BIG--IP-compatible-orange)
![TMOS Version](https://img.shields.io/badge/TMOS-17.x%2B-red)
![TMOS Version](https://img.shields.io/badge/TMOS-21.x%2B-red)

A menu-driven administration tool for managing LTM datagroups and URL categories on F5 BIG-IP systems.

## Features

- **Datagroup Management** - Create, view, export, and delete internal and external datagroups
- **URL Category Management** - Create and export custom URL categories
- **Bulk Import/Export** - CSV-based import and export for easy data management
- **Bidirectional Conversion** - Convert between URL categories and datagroups
- **Automatic Backups** - Creates backups before any destructive operation
- **Type Validation** - Validates entries match the datagroup type (string, address, integer)
- **Protected Datagroups** - Prevents modification of system datagroups

## Requirements

- F5 BIG-IP TMOS 17.x or higher
- Root access
- URL filtering module (for URL category features)

## Installation

```bash
# Copy to BIG-IP
scp dgcat-admin.sh root@<bigip-ip>:/shared/tmp/

# On BIG-IP
chmod +x /shared/tmp/dgcat-admin.sh
```

## Usage

```bash
./dgcat-admin.sh
```

## Menu Options

| Option | Description |
|--------|-------------|
| 1 | List all datagroups with type, class, and record count |
| 2 | View datagroup contents |
| 3 | Create datagroup or URL category from CSV |
| 4 | Delete datagroup |
| 5 | Export datagroup or URL category to CSV |
| 6 | Convert URL category to datagroup |

## CSV Format

### Datagroups

Keys only (domains, IPs, subnets):
```csv
example.com
google.com
10.0.0.0/8
```

Keys and values:
```csv
example.com,bypass
google.com,intercept
```

### URL Categories

Domain format (automatically converted to F5 URL format on import):
```csv
example.com
.wildcard-domain.com
```

## Configuration

Edit the script header to customize:

```bash
# Backup location
BACKUP_DIR="/shared/tmp/dgcat-admin-backups"

# Partitions to manage
PARTITIONS="Common"

# Protected system datagroups
PROTECTED_DATAGROUPS=(
    "private_net"
    "images"
    "aol"
)
```

## Datagroup Types

| Type | Class | Best For |
|------|-------|----------|
| Internal | string | Domains, URLs (<1000 entries) |
| Internal | address | IP addresses, subnets |
| Internal | integer | Port numbers |
| External | any | Large lists (1000+ entries) |

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Disclaimer

- This solution is **NOT** officially endorsed, supported, or maintained by F5 Inc.
- F5 Inc. retains all rights to their trademarks, including but not limited to "F5", "BIG-IP", "LTM", "APM", and related marks
- This is an independent, community-developed solution that utilizes F5 products but is not affiliated with F5 Inc.
- For official F5 support and solutions, please contact F5 Inc. directly

**Technical Disclaimer:**

- This software is provided "AS IS" without warranty of any kind
- The authors and contributors are not responsible for any damages or issues that may arise from its use
- Always test thoroughly in non-production environments before deployment
- Backup your F5 configuration before implementing any changes
- Review and understand all code before deploying to production systems
