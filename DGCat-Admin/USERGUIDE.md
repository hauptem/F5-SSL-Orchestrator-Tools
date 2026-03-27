# DGCat-Admin v3.0 User Guide

## Table of Contents

1. [Introduction](#introduction)
2. [Getting Started](#getting-started)
3. [Mode Selection](#mode-selection)
4. [TMSH Mode](#tmsh-mode)
5. [REST API Mode](#rest-api-mode)
6. [Fleet Deployment](#fleet-deployment)
7. [Interactive Editor](#interactive-editor)
8. [CSV File Formats](#csv-file-formats)
9. [Backup System](#backup-system)
10. [Troubleshooting](#troubleshooting)

---

## Introduction

DGCat-Admin is a menu-driven administration tool for managing LTM datagroups and custom URL categories on F5 BIG-IP systems.

### Why This Tool?

SSL Orchestrator (SSLO) policies rely heavily on datagroups and URL categories for traffic classification. While you can add sites directly to SSLO policies, this approach has limitations:

- SSLO uses iAppLX to generate APM per-request policies under the hood
- Each host or site added directly becomes an expression in the APM policy
- Large lists degrade policy performance and are difficult to maintain

**The recommended approach:** Use datagroups or URL categories for SSLO security policy rules. They're optimized for fast lookups and keep policies clean.

### Use Cases

- Export datagroups or URL categories to replicate SSLO business logic at another site
- Import large lists of subnets or hosts from CSV files
- Convert between URL categories and datagroups
- Bulk edit entries with filtering and pattern matching
- Deploy changes across multiple BIG-IP devices simultaneously

---

## Getting Started

### First Run

1. Launch the script:
   ```bash
   /shared/scripts/dgcat-admin.sh
   ```

2. Select your operating mode (TMSH or REST API)

3. The tool performs pre-flight checks:
   - Validates dependencies (tmsh, curl, jq)
   - Verifies configured partitions exist
   - Creates backup directory if needed
   - Loads fleet configuration (REST API mode)

### Configuration

Edit these variables at the top of the script before first use:

```bash
# Backup directory - where backups and logs are stored
BACKUP_DIR="/shared/tmp/dgcat-admin-backups"

# Maximum backups to retain per datagroup
MAX_BACKUPS=30

# Partitions to manage (comma-separated)
PARTITIONS="Common"

# Protected system datagroups (cannot be modified)
PROTECTED_DATAGROUPS=(
    "private_net"
    "images"
    "aol"
)
```

---

## Mode Selection

When you start the tool, choose your operating mode:

```
  ╔════════════════════════════════════════════════════════════╗
  ║                    DGCAT-Admin v3.0                        ║
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

### Mode Comparison

| Feature | TMSH | REST API |
|---------|:----:|:--------:|
| View Datagroups | ✓ | ✓ |
| Create/Update from CSV | ✓ | ✓ |
| Delete Datagroups | ✓ | ✓ |
| Export to CSV | ✓ | ✓ |
| Edit Datagroups | ✓ | ✓ |
| Edit URL Categories | ✓ | ✓ |
| List All Datagroups | ✓ | — |
| Convert URL Category | ✓ | — |
| External Datagroups | ✓ | — |
| Fleet Deployment | — | ✓ |

---

## TMSH Mode

TMSH mode runs locally on a BIG-IP and provides full functionality.

### Main Menu

```
  ╔════════════════════════════════════════════════════════════╗
  ║                    DGCAT-Admin v3.0                        ║
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

### Option 1: List All Datagroups

Displays all datagroups across configured partitions:

| Column | Description |
|--------|-------------|
| PARTITION | The partition containing the datagroup |
| NAME | Datagroup name |
| CLASS | `internal` or `external` |
| TYPE | `string`, `address`, or `integer` |
| RECORDS | Number of entries |

System datagroups are marked with `[SYSTEM]` and cannot be modified.

### Option 2: View Datagroup Contents

View all entries in a specific datagroup:

1. Select partition (if multiple configured)
2. Enter datagroup name
3. View displays key/value pairs

For external datagroups, the associated file reference is also shown.

### Option 3: Create/Update from CSV

Create a new datagroup or URL category from a CSV file, or update an existing one.

**Workflow:**
1. Select object type (Datagroup or URL Category)
2. Enter the CSV file path
3. For datagroups: select partition, name, class (internal/external), type (string/address/integer)
4. If object exists: choose **Overwrite** or **Merge**
5. Confirm and apply

### Option 4: Delete Datagroup or URL Category

**Deleting a Datagroup:**
1. Select partition
2. Enter datagroup name
3. Review details (class, type, record count)
4. Backup is created automatically
5. Type `DELETE` to confirm

For external datagroups, the associated sys file is also deleted.

**Deleting a URL Category:**
1. Enter name or select from list
2. Review details (URL count)
3. Backup is created automatically
4. Type `DELETE` to confirm

### Option 5: Export to CSV

Export contents to a CSV file for backup or transfer.

**Exporting a Datagroup:**
1. Select partition
2. Enter datagroup name
3. Enter export path (default provided)
4. Choose underscore handling for values:
   - **Keep as-is** — Underscores remain underscores
   - **Convert to spaces** — Restore original formatting

**Exporting a URL Category:**
1. Enter name or select from list
2. Enter export path
3. Choose format:
   - **Domain only** — e.g., `example.com`
   - **Full URL format** — e.g., `https://example.com/`

### Option 6: Convert URL Category to Datagroup

Convert URLs from a URL category into a string datagroup.

1. Enter category name or select from list
2. Preview conversion
3. Select partition for new datagroup
4. Enter datagroup name
5. If exists: choose **Overwrite** or **Merge**
6. Select class (internal/external)
7. Confirm and apply

**Format Conversion:**

| URL Category Format | Datagroup Format |
|---------------------|------------------|
| `https://www.example.com/` | `www.example.com` |
| `https://*.example.com/` | `.example.com` |

### Option 7: Edit a Datagroup or URL Category

Opens the interactive editor. See [Interactive Editor](#interactive-editor) section.

---

## REST API Mode

REST API mode connects remotely to a BIG-IP using iControl REST.

### Connection Setup

When you select REST API mode:

```
════════════════════════════════════════════════════════════════
  REST API Connection Setup
════════════════════════════════════════════════════════════════

  BIG-IP hostname or IP: 192.168.1.245
  Username: admin
  Password: ********

  [....] Connecting to 192.168.1.245...
  [ OK ]  Connected to BIG-IP version 17.5.1.5
  [....] Validating partitions on target system...
  [ OK ]  All partitions validated
  [ OK ]  Local backup directory: /shared/tmp/dgcat-admin-backups
  [ OK ]  Fleet loaded: 4 hosts across 2 sites
  [INFO]    DC1: 10.1.1.10, 10.1.1.11
  [INFO]    DC2: 10.2.1.10, 10.2.1.11
```

### Main Menu

```
  ╔════════════════════════════════════════════════════════════╗
  ║                    DGCAT-Admin v3.0                        ║
  ║               F5 BIG-IP Administration Tool                ║
  ╠════════════════════════════════════════════════════════════╣
    Mode: REST API - 192.168.1.245
  ╠════════════════════════════════════════════════════════════╣
  ║                                                            ║
  ║   1)  View Datagroup                                       ║
  ║   2)  Create/Update Datagroup or URL Category from CSV     ║
  ║   3)  Delete Datagroup or URL Category                     ║
  ║   4)  Export Datagroup or URL Category to CSV              ║
  ║   5)  Edit a Datagroup or URL Category                     ║
  ║                                                            ║
  ╠════════════════════════════════════════════════════════════╣
  ║   0)  Exit                                                 ║
  ╚════════════════════════════════════════════════════════════╝
```

### REST API Limitations

- **Internal datagroups only** — External datagroups require filesystem access
- **No URL category conversion** — Use TMSH mode for this operation
- **No datagroup listing** — Use View to check specific datagroups

---

## Fleet Deployment

Fleet deployment allows you to push changes to multiple BIG-IP devices simultaneously. This feature is only available in REST API mode.

### Fleet Configuration

Create a fleet configuration file at `${BACKUP_DIR}/fleet.conf`:

```
# DGCat-Admin Fleet Configuration
# Format: SITE|HOSTNAME_OR_IP
# Site IDs: alphanumeric, dashes, underscores (no spaces)
#
DC1|sslo-dc1-primary.example.com
DC1|sslo-dc1-secondary.example.com
DC2|sslo-dc2-primary.example.com
DC2|sslo-dc2-secondary.example.com
DR|sslo-dr-primary.example.com
DR|sslo-dr-secondary.example.com
```

**Format Rules:**
- One entry per line
- Format: `SITE_ID|HOSTNAME_OR_IP`
- Site IDs: alphanumeric characters, dashes, and underscores only
- Lines starting with `#` are comments
- Empty lines are ignored

### Using Fleet Deployment

1. Connect to any BIG-IP in REST API mode
2. Edit a datagroup or URL category
3. Make your changes (add, delete entries)
4. Press `D` to deploy

### Deploy Workflow

**Step 1: Review Pending Changes**
```
  ══════════════════════════════════════════════════════════════
    PENDING CHANGES TO DEPLOY
  ══════════════════════════════════════════════════════════════

  Additions (3):
    + newdomain.com
    + another.example.org
    + third.example.net

  Deletions (1):
    - olddomain.com

  ──────────────────────────────────────────────────────────────
  Final entry count: 152

  Continue to scope selection? (yes/no) [no]:
```

**Step 2: Select Deploy Scope**
```
  ══════════════════════════════════════════════════════════════
    DEPLOY SCOPE SELECTION
  ══════════════════════════════════════════════════════════════

  Object: /Common/my-datagroup
  Type:   datagroup

  Select deployment scope:

    1) Entire topology (5 hosts across 3 sites)
    2) Site: DC1 (2 hosts)
    3) Site: DC2 (2 hosts)
    4) Site: DR (1 host)

    0) Cancel

  Select [0-4]:
```

**Step 3: Confirm Deployment**
```
  ══════════════════════════════════════════════════════════════
    DEPLOY PREVIEW
  ══════════════════════════════════════════════════════════════

  Object:  /Common/my-datagroup (string)
  Changes: +3 / -1

  Deployment order:
    1. 10.1.1.10 (current device)
    2. 10.1.1.11 (DC1)
    3. 10.2.1.10 (DC2)
    4. 10.2.1.11 (DC2)
    5. 10.3.1.10 (DR)

  Total: 5 device(s)

  WARNING: This will overwrite the object on all listed devices.

  Type DEPLOY to confirm:
```

**Step 4: Deployment Execution**

The tool will:
1. Apply changes to the current device first
2. Run pre-deployment validation on fleet targets (connectivity, object exists, backup)
3. Deploy to each fleet target sequentially
4. Save configuration on each device after successful apply
5. Display summary

```
  ══════════════════════════════════════════════════════════════
    DEPLOY SUMMARY
  ══════════════════════════════════════════════════════════════

  HOST                                SITE       STATUS   MESSAGE
  ──────────────────────────────────────────────────────────────
  10.1.1.10                           (current)  OK       Deployed and saved
  10.1.1.11                           DC1        OK       Deployed and saved
  10.2.1.10                           DC2        OK       Deployed and saved
  10.2.1.11                           DC2        OK       Deployed and saved
  10.3.1.10                           DR         OK       Deployed and saved
  ──────────────────────────────────────────────────────────────
  Total: 5 succeeded, 0 failed, 0 skipped
```

### Pre-Deployment Validation

Before any changes are made, the tool validates each target:

1. **Connectivity** — Can connect with current credentials
2. **Object exists** — The datagroup/URL category exists on the target
3. **Backup** — Creates a backup on the local machine

Hosts that fail validation are skipped. If an object doesn't exist on a target, that target is skipped (not created).

### Systemic Failure Detection

If the same error occurs on 3 consecutive hosts, the tool aborts remaining deployments and reports a systemic issue. This prevents wasting time when there's a fundamental problem (e.g., wrong credentials, network issue).

### Fleet Logging

Deployment logs are organized by site:

```
${BACKUP_DIR}/
├── fleet.conf
├── DC1/
│   ├── sslo-dc1-primary_20260327_143022.log
│   └── sslo-dc1-secondary_20260327_143045.log
├── DC2/
│   └── ...
└── DR/
    └── ...
```

---

## Interactive Editor

The editor provides a powerful interface for making multiple changes before applying them.

### Editor Interface

```
  ╔══════════════════════════════════════════════════════════════════════════╗
  ║                        DGCat-Admin Editor                                ║
  ╚══════════════════════════════════════════════════════════════════════════╝
  Path:  /Common/my-datagroup
  Class: internal  |  Type: string
  Entries: 150
  (Pending changes - not yet applied)

  ──────────────────────────────────────────────────────────────────────────
    #    KEY                                          VALUE
  ──────────────────────────────────────────────────────────────────────────
    1    example.com                                  Production
    2    test.example.com                             Testing
    3    dev.example.com                              Development
  ...
  ──────────────────────────────────────────────────────────────────────────
  Page 1 of 15 | Showing 1-10 of 150 entries
```

### Navigation Commands

| Key | Action |
|-----|--------|
| `n` | Next page |
| `p` | Previous page |
| `g` | Go to specific page |
| `f` | Filter entries (case-insensitive search) |
| `c` | Clear filter |
| `s` | Change sort order (Original, A-Z, Z-A) |

### Editing Commands

| Key | Action |
|-----|--------|
| `a` | Add new entry |
| `d` | Delete entry (by number or key) |
| `x` | Delete by pattern (bulk delete matching entries) |
| `w` | Apply changes (write to current device) |
| `D` | Deploy to fleet (REST API mode only) |
| `q` | Done (return to main menu) |

### Staged Editing

All changes are staged in memory until you apply them:

- Add multiple entries
- Delete multiple entries
- Use filter to find specific entries
- Review all changes before committing

The header shows `(Pending changes - not yet applied)` when you have uncommitted changes.

### Applying Changes (w)

When you press `w`:

1. Review of additions and deletions is displayed
2. Confirm to proceed
3. Backup is created
4. Changes are applied in one atomic operation
5. Prompt to save configuration

```
  Pending changes:
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

### Pattern Delete (x)

Bulk delete entries matching a pattern:

```
  Enter pattern to match for deletion: *.test.com
  
  Matching entries (3):
    - app1.test.com
    - app2.test.com
    - api.test.com
  
  Delete all 3 matching entries? (yes/no) [no]:
```

---

## CSV File Formats

### Datagroup CSV Format

**String datagroup:**
```csv
key1,value1
key2,value2
example.com,Production Site
```

**Address datagroup:**
```csv
10.0.0.0/8,Internal
192.168.1.0/24,DMZ
172.16.0.0/16,VPN
```

**Integer datagroup:**
```csv
80,HTTP
443,HTTPS
8080,Proxy
```

**Notes:**
- First column is the key, second column is the value
- Values are optional (can have key-only entries)
- Lines starting with `#` are treated as comments
- Empty lines are ignored
- Windows line endings (CRLF) are automatically converted

### URL Category CSV Format

**Simple format (recommended):**
```csv
example.com
www.example.com
.example.org
```

**Full URL format (also accepted):**
```csv
https://example.com/
https://www.example.com/
https://*.example.org/
```

**Automatic conversions on import:**

| Input | Stored As |
|-------|-----------|
| `example.com` | `https://example.com/` |
| `.example.com` | `https://*.example.com/` |
| `https://example.com/` | `https://example.com/` |

---

## Backup System

### Automatic Backups

Backups are created automatically before:

- Modifying an existing datagroup (overwrite/merge)
- Deleting a datagroup or URL category
- Applying changes in the editor
- Deploying to fleet targets

### Backup Location

```
${BACKUP_DIR}/
├── dgcat-admin-20260327_143022.log
├── Common_my-datagroup_internal_20260327_143052.csv
├── urlcat_my-category_20260327_143105.csv
├── fleet.conf
├── DC1/
│   ├── 10.1.1.10_Common_my-datagroup_20260327_143022.csv
│   └── 10.1.1.11_Common_my-datagroup_20260327_143045.csv
└── DC2/
    └── ...
```

### Backup Naming

**Datagroups:**
```
{partition}_{datagroup}_{class}_{timestamp}.csv
```

**URL Categories:**
```
urlcat_{category}_{timestamp}.csv
```

**Fleet backups:**
```
{site}/{hostname}_{partition}_{datagroup}_{timestamp}.csv
```

### Backup Retention

The tool automatically removes old backups beyond the `MAX_BACKUPS` limit (default: 30 per object).

### Restoring from Backup

Use Option 3 (Create/Update from CSV) to restore from a backup file:

1. Select Datagroup or URL Category
2. Enter the backup file path
3. Choose **Overwrite** to restore completely

---

## Troubleshooting

### TMSH Mode Issues

**"Cannot query datagroups"**
- **Cause:** Insufficient tmsh privileges
- **Solution:** Run as root or a user with LTM datagroup permissions

**"Partition does not exist"**
- **Cause:** Configured partition not found on system
- **Solution:** Edit `PARTITIONS` in the script configuration

**"Could not create backup directory"**
- **Cause:** Permissions issue or disk full
- **Solution:** Check `/shared/tmp/` permissions and available space

**"External datagroup file not found"**
- **Cause:** File reference exists but actual file missing
- **Solution:** Check `/config/filestore/files_d/{partition}_d/data_group_d/`

### REST API Mode Issues

**"curl not found"**
- **Cause:** curl is not installed
- **Solution:** Install curl (`apt install curl`, `yum install curl`, `brew install curl`)

**"jq not found"**
- **Cause:** jq is not installed
- **Solution:** Install jq (`apt install jq`, `yum install jq`, `brew install jq`)

**"Connection failed" or "401 Unauthorized"**
- **Cause:** Wrong hostname, credentials, or network issue
- **Solution:** Verify BIG-IP is reachable, credentials are correct, and user has API access

**"Partition not found on target system"**
- **Cause:** Configured partition doesn't exist on the remote BIG-IP
- **Solution:** Edit `PARTITIONS` or verify the partition exists on the target

**"External datagroups are not supported in REST API mode"**
- **Cause:** Attempting to work with external datagroups remotely
- **Solution:** Use TMSH mode for external datagroup operations

### Fleet Deployment Issues

**"No fleet configured"**
- **Cause:** fleet.conf file doesn't exist or is empty
- **Solution:** Create `${BACKUP_DIR}/fleet.conf` with your BIG-IP hosts

**"Connection failed" during validation**
- **Cause:** Fleet host is unreachable or credentials don't work
- **Solution:** Verify network connectivity and that credentials work on all fleet members

**"Datagroup/Category not found" (SKIP)**
- **Cause:** The object doesn't exist on that fleet member
- **Solution:** Create the object manually first, or this is expected if not all devices have the object

**"Systemic failure detected"**
- **Cause:** Same error on 3+ consecutive hosts
- **Solution:** Check credentials, network, and that the operation is valid

### General Issues

**"Windows line endings" warning**
- **Cause:** CSV file created on Windows with CRLF line endings
- **Solution:** Tool automatically converts; no action needed

**Editor hangs when pressing a key**
- **Cause:** Large dataset being processed
- **Solution:** Wait for processing; tool shows `[....] Analyzing changes...` for large operations

---

## Support

This is a community-developed tool. For issues or feature requests, contact the maintainer or submit an issue to the project repository.

For official F5 support, contact F5 Inc. directly.

