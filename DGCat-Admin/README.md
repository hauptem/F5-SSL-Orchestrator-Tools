# DGCat-Admin - F5 BIG-IP Datagroup / URL Category Manager

![License](https://img.shields.io/badge/license-MIT-green)
![F5 Compatible](https://img.shields.io/badge/F5%20BIG--IP-compatible-orange)
![TMOS Version](https://img.shields.io/badge/TMOS-17.x%2B-red)
![TMOS Version](https://img.shields.io/badge/TMOS-21.x%2B-red)

A menu-driven administration tool for managing LTM datagroups and URL categories on F5 BIG-IP systems. Supports both local TMSH and remote REST API operation.

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

---

## What's New in v2.0

### REST API Mode

Version 2.0 adds the ability to manage BIG-IP datagroups and URL categories remotely using the iControl REST API. This means you can:

- Run the tool from any Linux/Mac system with network access to your BIG-IP
- Manage multiple BIG-IP devices without copying the script to each one
- Use the same familiar interface whether local or remote

### Mode Selection

When you start the tool, you'll choose your operation mode:

```
  ╔════════════════════════════════════════════════════════════╗
  ║                    DGCAT-Admin v2.0                        ║
  ║               F5 BIG-IP Administration Tool                ║
  ╠════════════════════════════════════════════════════════════╣
  ║   Select operating mode:                                   ║
  ║                                                            ║
  ║    1)  TMSH     - Use tmsh commands                        ║
  ║    2)  REST API - Use iControl REST API                    ║
  ║                                                            ║
  ╠════════════════════════════════════════════════════════════╣
  ║    0)  Exit                                                ║
  ╚════════════════════════════════════════════════════════════╝
```

| Mode | Use When |
|------|----------|
| **TMSH** | Running directly on a BIG-IP, or have tmsh access |
| **REST API** | Managing a remote BIG-IP over the network |

---

## Installation

### For TMSH Mode (on BIG-IP)

1. Copy the script to your BIG-IP:
   ```bash
   scp dgcat-admin.sh root@<bigip-ip>:/shared/scripts/
   ```

2. Make it executable:
   ```bash
   chmod +x /shared/scripts/dgcat-admin.sh
   ```

3. Run the tool:
   ```bash
   /shared/scripts/dgcat-admin.sh
   ```

### For REST API Mode (remote management)

1. Copy the script to any Linux/Mac system
2. Ensure prerequisites are installed:
   ```bash
   # Check for curl
   curl --version
   
   # Check for jq
   jq --version
   ```
3. Make it executable and run:
   ```bash
   chmod +x dgcat-admin.sh
   ./dgcat-admin.sh
   ```

---

## Configuration

Configuration options are set at the top of the script. Edit these before first use if needed.

### Backup Settings

```bash
BACKUP_DIR="/shared/tmp/dgcat-admin-backups"
MAX_BACKUPS=30
```

- **BACKUP_DIR**: Where backups and logs are stored
- **MAX_BACKUPS**: Number of backups to retain per datagroup (oldest are automatically deleted)

> **Note:** In REST API mode, backups are stored locally on the machine running the script.

### Partition Management

```bash
PARTITIONS="Common"
```

Add additional partitions as comma-separated values:
```bash
PARTITIONS="Common,SSLO_Partition,DMZ"
```

> **Warning:** Only include partitions you intend to manage with this tool.

### Protected System Datagroups

```bash
PROTECTED_DATAGROUPS=(
    "private_net"
    "images"
    "aol"
)
```

These are pre-configured BIG-IP datagroups that cannot be modified or deleted. Attempting to change these can cause adverse system behavior.

---

## REST API Mode

### Requirements

- **curl** - For making HTTP requests
- **jq** - For JSON parsing
- Network access to the BIG-IP management interface (typically port 443)
- Valid BIG-IP credentials with appropriate permissions

### Connection Setup

When you select REST API mode, you'll be prompted for connection details:

```
════════════════════════════════════════════════════════════════
  REST API Connection Setup
════════════════════════════════════════════════════════════════

  Enter BIG-IP hostname or IP: 192.168.1.245
  Enter username: admin
  Enter password: ********

  [....] Connecting to 192.168.1.245...
  [ OK ]  Connected successfully
  [ OK ]  TMOS Version: 17.5.1.5
  [ OK ]  All partitions validated
```

### REST API Mode Menu

REST API mode provides a streamlined menu with the most common operations:

```
  ╔════════════════════════════════════════════════════════════╗
  ║                    DGCAT-Admin v2.0                        ║
  ║               F5 BIG-IP Administration Tool                ║
  ╠════════════════════════════════════════════════════════════╣
    Mode: REST API - 192.168.1.245
  ╠════════════════════════════════════════════════════════════╣
  ║                                                            ║
  ║   1)  View Datagroup                                       ║
  ║   2)  Create/Update Datagroup or URL Category from CSV     ║
  ║   3)  Export Datagroup or URL Category to CSV              ║
  ║   4)  Edit a Datagroup or URL Category                     ║
  ║                                                            ║
  ╠════════════════════════════════════════════════════════════╣
  ║   0)  Exit                                                 ║
  ╚════════════════════════════════════════════════════════════╝
```

### REST API Limitations

Some operations are only available in TMSH mode:

| Feature | TMSH | REST API |
|---------|:----:|:--------:|
| View Datagroups | ✓ | ✓ |
| Create/Update from CSV | ✓ | ✓ |
| Export to CSV | ✓ | ✓ |
| Edit Datagroups | ✓ | ✓ |
| List All Datagroups | ✓ | — |
| Delete Datagroups | ✓ | — |
| Convert URL Category | ✓ | — |
| External Datagroups | ✓ | — |

> **Note:** REST API mode supports **internal datagroups only**. External datagroups require filesystem access and must be managed via TMSH mode.

---

## TMSH Mode Menu

```
  ╔════════════════════════════════════════════════════════════╗
  ║                    DGCAT-Admin v2.0                        ║
  ║               F5 BIG-IP Administration Tool                ║
  ╠════════════════════════════════════════════════════════════╣
    Mode: TMSH
  ╠════════════════════════════════════════════════════════════╣
  ║                                                            ║
  ║   1)  List All Datagroups                                  ║
  ║   2)  View Datagroup Contents                              ║
  ║   3)  Create/Update Datagroup or URL Category from CSV     ║
  ║   4)  Delete Datagroup or URL Category                     ║
  ║   5)  Export Datagroup or URL Category to CSV              ║
  ║   6)  Convert URL Category to Datagroup                    ║
  ║   7)  Edit a Datagroup or URL Category                     ║
  ║                                                            ║
  ╠════════════════════════════════════════════════════════════╣
  ║   0)  Exit                                                 ║
  ╚════════════════════════════════════════════════════════════╝
```

---

## Option 1: List All Datagroups 

Displays all datagroups across configured partitions with details:

| Column | Description |
|--------|-------------|
| PARTITION | The partition containing the datagroup |
| NAME | Datagroup name |
| CLASS | `internal` or `external` |
| TYPE | `string`, `address`, or `integer` |
| RECORDS | Number of entries |

System datagroups are marked with `[SYSTEM]` and cannot be modified.

---

## Option 2: View Datagroup Contents

View all entries in a specific datagroup.

1. Select partition (if multiple configured)
2. Enter datagroup name
3. View displays key/value pairs

For external datagroups (TMSH mode), the associated file reference is also shown.

---

## Option 3: Create Datagroup or URL Category from CSV

Create a new datagroup or URL category from a CSV file, or restore/merge into an existing one.

### Creating a Datagroup

1. Select **Datagroup**
2. Select partition
3. Enter datagroup name
4. If exists: choose **Overwrite** or **Merge**
5. Select class (TMSH mode only):
   - **Internal** - Stored in bigip.conf (best for <1000 entries)
   - **External** - Stored in separate file (best for 1000+ entries)
6. Select type:
   - **string** - For domains, hostnames, URLs
   - **address** - For IP addresses, subnets (CIDR)
   - **integer** - For port numbers, numeric values
7. Enter path to CSV file
8. Select format:
   - **Keys only** - Single column (e.g., list of domains)
   - **Keys and Values** - Two columns (e.g., domain,action)

> **Note:** In REST API mode, only internal datagroups can be created.

### Creating a URL Category

1. Select **URL Category**
2. Enter category name
3. If exists: choose **Overwrite** or **Merge**
4. Enter path to CSV file (domains or URLs, one per line)
5. Select default action: `allow`, `block`, or `confirm`

---

## Option 4: Delete Datagroup or URL Category

Permanently delete a datagroup or URL category.

### Deleting a Datagroup

1. Select **Datagroup**
2. Select partition
3. Enter datagroup name
4. Review details (class, type, record count)
5. Backup is created automatically
6. Type `DELETE` to confirm

For external datagroups, the associated sys file is also deleted.

### Deleting a URL Category

1. Select **URL Category**
2. Enter name or select from list
3. Review details (URL count)
4. Backup is created automatically
5. Type `DELETE` to confirm

> **Note:** System datagroups marked `[SYSTEM]` cannot be deleted.

---

## Option 5: Export Datagroup or URL Category to CSV

Export contents to a CSV file for backup or transfer.

### Exporting a Datagroup

1. Select **Datagroup**
2. Select partition
3. Enter datagroup name
4. Enter export path (default provided)
5. Choose underscore handling for values:
   - **Keep as-is** - Underscores remain underscores
   - **Convert to spaces** - Restore original formatting

### Exporting a URL Category

1. Select **URL Category**
2. Enter name or select from list
3. Enter export path
4. Choose format:
   - **Domain only** - e.g., `example.com`
   - **Full URL format** - e.g., `https://example.com/`

---

## Option 6: Convert URL Category to Datagroup

Convert URLs from a URL category into a string datagroup for use with SSLO or iRules.

1. Enter category name or select from list
2. Preview conversion (URL format → domain format)
3. Select partition for new datagroup
4. Enter datagroup name
5. If exists: choose **Overwrite** or **Merge**
6. Select class (internal/external)
7. Confirm and apply

### Format Conversion

| URL Category Format | Datagroup Format |
|---------------------|------------------|
| `https://www.example.com/` | `www.example.com` |
| `https://*.example.com/` | `.example.com` |

---

## Option 7: Edit a Datagroup or URL Category

Interactive editor for making multiple changes before applying.

### Editor Interface

```
  ╔══════════════════════════════════════════════════════════════════════════╗
  ║                        DGCat-Admin Editor                                ║
  ╚══════════════════════════════════════════════════════════════════════════╝
  Path:  /Common/my-datagroup
  Class: internal  |  Type: string
  Entries: 150
  (Pending changes - not yet applied)
```

### Navigation

| Key | Action |
|-----|--------|
| `n` | Next page |
| `p` | Previous page |
| `g` | Go to specific page |
| `f` | Filter entries (case-insensitive search) |
| `c` | Clear filter |
| `s` | Change sort order (Original, A-Z, Z-A) |

### Editing

| Key | Action |
|-----|--------|
| `a` | Add new entry |
| `d` | Delete entry (by number or name) |
| `x` | Delete by pattern (bulk delete matching entries) |
| `w` | **Apply changes** (write to system) |
| `q` | Done (return to main menu) |

### Staged Editing

All changes are staged in memory until you press `w` to apply:

- Add multiple entries
- Delete multiple entries
- Filter/search to find specific entries
- Review all changes before committing

When you press `w`:

1. Review of all additions and deletions is displayed
2. Confirm to proceed
3. **One backup** is created
4. **One atomic operation** applies all changes
5. Prompt to save configuration

### Example Apply Screen

```
  [INFO]  Pending changes:
  ──────────────────────────────────────────────────────────────────────────
  Additions (2):
    + newdomain.com
    + another.example.org

  Deletions (1):
    - olddomain.com
  ──────────────────────────────────────────────────────────────────────────
  Final count: 151 entries

  Apply these changes? (yes/no) [no]:
```

---

## Internal vs External Datagroups

### Internal Datagroups

- Stored directly in `bigip.conf`
- Best for smaller datasets (<1000 entries)
- Loaded into memory at config load time
- Backed up with standard UCS backups
- **Supported in both TMSH and REST API modes**

### External Datagroups

- Stored in separate files under `/config/filestore/`
- Best for large datasets (1000+ entries)
- Referenced by the datagroup, loaded on demand
- **TMSH mode only** (requires filesystem access)

---

## Backup System

### Automatic Backups

Backups are created automatically before:

- Modifying an existing datagroup (overwrite/merge)
- Deleting a datagroup
- Deleting a URL category
- Applying changes in the editor

### Backup Location

**TMSH mode:**
```
/shared/tmp/dgcat-admin-backups/
```

**REST API mode:**
```
/shared/tmp/dgcat-admin-backups/   (or configured BACKUP_DIR on local system)
```

### Backup Naming

```
{partition}_{datagroup}_{class}_{timestamp}.csv
```

Example: `Common_my-datagroup_internal_20260325_143052.csv`

### Backup Retention

The tool automatically removes old backups beyond the `MAX_BACKUPS` limit (default: 30 per datagroup).

---

## URL Category Format

### Automatic Conversion

The tool handles conversion automatically:

| Direction | From | To |
|-----------|------|----|
| Import to URL Category | `example.com` | `https://example.com/` |
| Import to URL Category | `.example.com` | `https://*.example.com/` |
| Export from URL Category | `https://example.com/` | `example.com` |
| Export from URL Category | `https://*.example.com/` | `.example.com` |

---

## Troubleshooting

#### "Cannot query datagroups"

**Cause:** Insufficient tmsh privileges  
**Solution:** Run as root or a user with LTM datagroup permissions

#### "Partition does not exist"

**Cause:** Configured partition not found on system  
**Solution:** Edit `PARTITIONS` in the script configuration

#### "Could not create backup directory"

**Cause:** Permissions issue or disk full  
**Solution:** Check `/shared/tmp/` permissions and available space

#### External datagroup file not found

**Cause:** File reference exists but actual file missing  
**Solution:** Check `/config/filestore/files_d/{partition}_d/data_group_d/`

#### "curl not found"

**Cause:** curl is not installed  
**Solution:** Install curl (`apt install curl`, `yum install curl`, or `brew install curl`)

#### "jq not found"

**Cause:** jq is not installed  
**Solution:** Install jq (`apt install jq`, `yum install jq`, or `brew install jq`)

#### "Connection failed" or "401 Unauthorized"

**Cause:** Wrong hostname, credentials, or network issue  
**Solution:** Verify BIG-IP is reachable, credentials are correct, and user has API access

#### "Partition not found on target system"

**Cause:** Configured partition doesn't exist on the remote BIG-IP  
**Solution:** Edit `PARTITIONS` in the script or verify the partition exists on the target

#### "External datagroups are not supported in REST API mode"

**Cause:** Attempting to work with external datagroups remotely  
**Solution:** Use TMSH mode for external datagroup operations

#### Windows line endings warning

**Cause:** CSV file created on Windows with CRLF line endings  
**Solution:** Tool automatically converts to Unix format (LF)

---

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
