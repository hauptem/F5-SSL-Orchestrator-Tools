# DGCat-Admin v5.x — User Guide

## Table of Contents

1. [Introduction](#introduction)
2. [How It Works](#how-it-works)
3. [Getting Started](#getting-started)
4. [Connecting to a BIG-IP](#connecting-to-a-big-ip)
5. [The Main Menu](#the-main-menu)
6. [Creating Datagroups and URL Categories](#creating-datagroups-and-url-categories)
7. [Creating and Updating from CSV](#creating-and-updating-from-csv)
8. [Deleting Datagroups and URL Categories](#deleting-datagroups-and-url-categories)
9. [Exporting to CSV](#exporting-to-csv)
10. [The Interactive Editor](#the-interactive-editor)
11. [Fleet Deployment](#fleet-deployment)
12. [Fleet Search](#fleet-search)
13. [Fleet Backup](#fleet-backup)
14. [Bootstrap](#bootstrap)
15. [CSV File Formats](#csv-file-formats)
16. [Backup System](#backup-system)
17. [Configuration Reference](#configuration-reference)
18. [Troubleshooting](#troubleshooting)

---

## Introduction

DGCat-Admin is a menu-driven administration tool for managing LTM datagroups and custom URL categories on F5 BIG-IP systems. It connects to BIG-IP devices via the iControl REST API and is available in two versions with identical functionality:

- **Bash** (`dgcat-admin.sh`) — Requires `curl` and `jq`. Runs from any Linux or macOS machine, a BIG-IP, or Big-IQ.
- **PowerShell** (`dgcat-admin.ps1`) — Requires PowerShell 5.1 or later. Runs from any Windows workstation.

Both versions require network access to the BIG-IP management interface on port 443 and an account with administrative API access.

The tool was designed for environments running SSL Orchestrator (SSLO), where datagroups and URL categories are the primary mechanism for classifying traffic in security policies. However, it works equally well for any BIG-IP deployment that uses datagroups or custom URL categories.

DGCat-Admin supports managing a single device or an entire fleet of BIG-IPs. Changes can be made interactively through a built-in editor and pushed to multiple devices in a single operation, with pre-deployment validation and automatic backups at every step.

---

### The Datagroup and URL Category Approach

F5's recommended approach is to reference datagroups or custom URL categories in your SSLO security policy rules instead of adding entries directly. Datagroups and URL categories are optimized for fast lookups, can hold thousands of entries without impacting policy performance, and are independent objects that can be managed, exported, and replicated separately from the policies that reference them.

The challenge is that BIG-IP provides limited tooling for bulk management of these objects when an orchestration tool such as Ansible is not available. Adding 500 networks to a datagroup through the GUI is tedious. Exporting a URL category to replicate it at another site requires manual work. Keeping six BIG-IP SSLO's in sync across three datacenters is operationally expensive. No one wants to mess with tmsh scripts in 2026.

### What DGCat-Admin Solves

DGCat-Admin provides a single interface for all of these operations. You can import thousands of entries from a CSV file in seconds, export existing objects for backup or replication, edit entries interactively with search and bulk operations, and push the result to every BIG-IP in your fleet with a single command.

The tool handles the details that make these operations error-prone when done manually: type validation, backup before modification, format conversion between CSV and BIG-IP native formats, and atomic application of changes.

---

## How It Works

### REST API Architecture

DGCat-Admin communicates with BIG-IP exclusively through the iControl REST API over HTTPS. Every operation — listing datagroups, reading records, applying changes, saving configuration — is an API call. This means the tool can run from anywhere with network access to the BIG-IP management interface.

When you connect, the tool authenticates with the credentials you provide and validates the connection by querying the BIG-IP system. All subsequent operations use the same authenticated session.

### Fleet Model

If you have multiple BIG-IPs, you can define them in a fleet configuration file organized by site. The tool uses the fleet list for two purposes: presenting hosts for quick selection at connection time, and as targets for fleet deployment operations.

Fleet deployment uses a validate-then-apply model. Before any changes are made to any device, the tool validates connectivity and object existence on every target host during pre-deploy checks. If all pre-deploy checks pass, the tool begins sequentially deploying first to the device you're connected to, then to each fleet member defined in the deployment scope i.e. full topology or specific site deployment.

### Editor Model

The interactive editor loads the current state of a datagroup or URL category into memory and lets you make changes — adding entries, deleting entries, bulk-deleting by pattern — without touching the actual Big-IP configuration. All edits are staged in a candidate configuration. When you're ready, you apply the changes atomically, or deploy them to the fleet. If you change your mind and quit out of DGCat-Admin without writing to the connected host or deploying to remote hosts, nothing changes on your Big-IP's at all.

---

## Getting Started

### Requirements

**Bash version:** `curl` and `jq` must be available on the machine where you run the script. Both are available in the default package repositories for most Linux distributions and macOS. The tool checks for these at startup and will not proceed without them.

**PowerShell version:** PowerShell 5.1 or later, which ships with Windows 10 and 11. No additional modules or packages are required.

On the BIG-IP side, you need a user account with administrative API access (typically the `admin` role) and network reachability to the management interface on port 443.

### Installation

**Bash:**

```bash
chmod +x dgcat-admin.sh
./dgcat-admin.sh
```

**PowerShell:**

```powershell
.\dgcat-admin.ps1
```

There is no installation process, no dependencies beyond the above, and no configuration files required to get started. The tool creates its backup directory automatically on first run.

### Initial Configuration

The top of the script contains a configuration section with three settings you may want to adjust:

```bash
BACKUP_DIR="/shared/tmp/dgcat-admin-backups"
MAX_BACKUPS=30
BACKUPS_ENABLED=0
PARTITIONS="Common"
```

**BACKUP_DIR** is where backups, logs, and the fleet configuration file are stored. The default path works well when running on a BIG-IP. If you're running from a different machine, change this to a local path.

**MAX_BACKUPS** controls how many backup files are retained per object. When the limit is exceeded, the oldest backups are removed automatically.

**BACKUPS_ENABLED** controls whether automatic pre-change backups are created. Set to `1` to enable. 

**PARTITIONS** is a comma-separated list of BIG-IP partitions to manage. Most SSLO deployments use the `Common` partition, but if your environment uses additional partitions, add them here. Only datagroups in listed partitions will be visible to the tool.

---

## Connecting to a BIG-IP

When you start the tool, it displays a welcome banner and runs pre-flight checks (dependency validation, partition configuration, and fleet loading). After pre-flight completes, the connection prompt appears.

If you have a fleet configuration file, the tool displays your fleet hosts as numbered options:

```
  Fleet hosts:
  ────────────────────────────────────────────────────────────
     1) bigip01-mgmt.dc1.example.com (DC1)
     2) bigip02-mgmt.dc1.example.com (DC1)
     3) bigip01-mgmt.dc2.example.com (DC2)
     4) bigip02-mgmt.dc2.example.com (DC2)
  ────────────────────────────────────────────────────────────
     0) Exit

  Select [0-4] or enter hostname/IP:
```

Type a number to select a fleet host, or type any hostname or IP address to connect to a device that isn't in your fleet. Type `0` to exit.

After selecting a host, you're prompted for a username and password. 

```
  [....]  Connecting to bigip01-mgmt.dc1.example.com...
  [ OK ]  Connected to BIG-IP: bigip01.dc1.example.com
  [ OK ]  TMOS version 17.5.1.5
```

If the connection fails, you're given the option to retry or exit. Common failure causes are incorrect credentials (HTTP 401), unreachable host (connection timeout), or a hostname that doesn't resolve.

---

## The Main Menu

After a successful connection, you see the main menu:

<img width="642" height="412" alt="Image" src="https://github.com/user-attachments/assets/9961997a-15a3-4ce6-8cb3-5049a6c33c89" />

Each option is described in detail in the following sections. Option 0 returns to the host selection screen where you can connect to a different BIG-IP without restarting the tool or re-running pre-flight checks.

---

## Creating Datagroups and URL Categories

**Menu option 1** creates an empty datagroup or URL category on the BIG-IP. This is useful for preparing objects that will be populated later through the editor, CSV import, or fleet deployment.

For datagroups, you select a partition and the tool displays existing datagroups for reference. Type a name for the new datagroup and choose a type (string, address, or integer). If the name matches an existing datagroup, the tool rejects it immediately without an API call — the list is already in memory. Protected system datagroups are hidden from the list.

For URL categories, you provide a name and select a default action (allow, block, or confirm). The tool sanitizes the name to remove characters that aren't valid in F5 object names.

After creation, the tool offers to save the BIG-IP configuration.

---

## Creating and Updating from CSV

**Menu option 2** imports a CSV file into a datagroup or URL category. The tool first asks whether you want to create a datagroup or a URL category.

### Creating or Updating a Datagroup

You provide a datagroup name and partition. If the datagroup already exists, the tool shows its current state and asks how you want to proceed:

- **Overwrite** — Replace all existing entries with the contents of the CSV file
- **Merge** — Add the CSV entries to the existing entries, deduplicating by key

If the datagroup doesn't exist, you select a type:

- **string** — For domains, hostnames, URLs, or any text keys
- **address** — For IP addresses and CIDR subnets
- **integer** — For port numbers or other numeric keys

The tool validates your CSV against the selected type. If you select `address` but your CSV contains domain names, you'll get a warning with the option to abort or continue.

Before applying, the tool previews the file contents and asks you to confirm the key/value format.

### Creating or Updating a URL Category

The workflow is similar but simpler. URL categories are always string-based and always in the `Common` partition. You provide a category name, point to a CSV file containing domains (one per line), and the tool converts them to the F5 URL category format automatically.

Domains with a leading dot (`.example.com`) are converted to wildcard entries (`https://*.example.com/`). Plain domains (`example.com`) become exact-match entries (`https://example.com/`).

If the category already exists, you choose overwrite or merge, just like datagroups.

---

## Deleting Datagroups and URL Categories

**Menu option 3** deletes a datagroup or URL category. The tool shows the object's details (type, record count) and creates a backup before deletion. You must type `DELETE` (case-sensitive) to confirm.

Deletion is permanent. The backup file can be used to recreate the object using the Create/Update from CSV option if needed.

Protected system datagroups cannot be deleted. The tool blocks the operation and explains why.

---

## Exporting to CSV

**Menu option 4** exports a datagroup or URL category to a CSV file.

For datagroups, the export includes a comment header with metadata (partition, type, export date) followed by `key,value` lines. The default export path is in the backup directory with a timestamped filename, but you can specify any path.

For URL categories, you choose between domain-only format (stripped of protocol and path) or full URL format (as stored by BIG-IP). 

Exported files can be used directly as input for the Create/Update option, making it easy to replicate objects between BIG-IPs that aren't in the same fleet.

---

## The Interactive Editor

**Menu option 5** opens the interactive editor for a datagroup or URL category. This is where you view contents and make changes. The editor supports browsing, searching, and modifying entries with full pagination.

### How It Works

When you open a datagroup or URL category in the editor, the tool fetches the current state from the BIG-IP and loads it into memory. All changes you make happen in memory only — the live object is not modified until you explicitly apply.

The editor displays a full paginated view with all available commands:

<img width="693" height="734" alt="Image" src="https://github.com/user-attachments/assets/4d1dc329-b1f0-413f-9bb7-80db3480e7e8" />

### Navigation

The editor shows 20 entries per page. Use `n` and `p` to move between pages, or `g` to jump directly to a specific page number.

Use `f` to filter entries by a case-insensitive search pattern. Only matching entries are shown, and deletion operations work against the filtered view. Use `c` to clear the filter and return to the full list.

Use `s` to change the sort order between original (as stored), ascending (A-Z), or descending (Z-A).

### Adding Entries

Press `a` to add an entry. For datagroups, you enter a key and optionally a value. For URL categories, you enter a domain or URL and the tool converts it to the proper format automatically. The tool checks for duplicates and warns you if the entry already exists.

### Deleting Entries

Press `d` to delete a single entry. You can specify the entry by its line number (as shown in the current view) or by typing the key directly.

Press `x` to delete by pattern. Enter a search string and the tool shows all matching entries with a count. Confirm to delete all matches at once. This is useful for removing all entries from a specific domain or subnet range.

### Applying Changes

Press `w` to apply your changes to the current device. The tool shows a summary of all additions and deletions, creates a backup of the current state, and asks for confirmation before applying. After a successful apply, the tool offers to save the BIG-IP configuration.

For URL categories, the tool applies changes incrementally — only the specific additions and deletions are sent, not a full replacement. This minimizes the API impact and preserves any entries that weren't part of your edit session.

### Deploying to Fleet

Press `D` to deploy changes to multiple BIG-IPs. This option is available when a fleet configuration is loaded. The full deployment workflow is described in the next section.

### Quitting

Press `q` to return to the main menu. If you have unapplied changes, the tool warns you and asks for confirmation before discarding them.

---

## Fleet Deployment

Fleet deployment lets you push the current state of a datagroup or URL category from the device you're connected to out to other BIG-IPs in your fleet.

### Fleet Configuration

A file called `fleet.conf` is created by the script in your backup directory at first execution if the script does not already exist. The format is one entry per line, with a site label and hostname or IP separated by a pipe character:

```
# DGCat-Admin Fleet Configuration File
# This file defines BIG-IPs within an enterprise that will be managed by DGCat-Admin
# https://github.com/hauptem/F5-SSL-Orchestrator-Tools
#
# Format: SITE|HOSTNAME_OR_IP
#
# Examples:
# DC1|bigip01.lab.local
# DC1|bigip02.lab.local
# DC2|bigip01.lab.local
# DC2|bigip02.lab.local
#
# Site names: letters, numbers, dashes, underscores only
East|sslo-e1.company.com
East|sslo-e2.company.com
West|sslo-w1.company.com
West|sslo-w2.company.com
```

Site labels are used for grouping in the deployment scope selection and in the deployment summary. Use datacenter names, environment names, or whatever labeling scheme makes sense for your topology.

The fleet is loaded once at session start. The tool displays a summary during pre-flight checks:

```
  [ OK ]  Fleet loaded: 4 hosts across 2 sites
```

### Fleet Configuration File

The fleet configuration file is located at `${BACKUP_DIR}/fleet.conf`. If no fleet configuration exists on first run, the tool creates a boilerplate template with format documentation and examples. It is a plain text file with one entry per line:

```
SITE|HOSTNAME_OR_IP
```

Site identifiers must contain only alphanumeric characters, dashes, and underscores. Lines starting with `#` are treated as comments. Blank lines are ignored.

### Initiating a Deploy

From the editor, press `D`. The tool first checks whether you have pending changes (additions or deletions that haven't been applied yet).

If there are pending changes, the tool analyzes and displays them, then asks you to continue to deployment options.

If there are no pending changes — for example, you already applied changes via `w` and now want to push that state to the fleet, or you loaded the datagroup from a CSV and want to replicate it — the tool asks whether you want to deploy the current state anyway. This is the typical workflow for replication: load or update an object on one BIG-IP, then deploy it to the rest.

### Deployment Modes

After confirming your intent to deploy, you select a deployment mode:

**Full Replace** overwrites the target object on each fleet host with the exact state from the current device. After deployment, every device has an identical copy. This is the right choice when you want strict parity across your fleet.

**Merge** applies only your additions and deletions to each target, preserving any entries that are specific to that device. For datagroups, the tool pulls the current records from each target, applies the changes in memory, and writes the merged result. For URL categories, the tool uses the API's native add and delete operations. This is the right choice when different sites have intentional differences — such as site-specific bypass entries or local address ranges — and you only want to propagate the changes you made, not overwrite everything.

### Deployment Scope

Next, you select which devices to deploy to:

- **All fleet hosts** — Every host in your fleet except the one you're currently connected to
- **Select by site** — Choose one or more sites by number (comma-separated for multiple)
- **Select by host** — Choose individual hosts by number (comma-separated for multiple)

The device you're connected to is automatically excluded from the fleet target list since it's handled separately.

### Deployment Preview

Before anything changes, the tool displays a deployment preview showing the object, the change summary, the deployment mode, and the ordered list of target devices. You must type `DEPLOY` (case-sensitive) to proceed.

### Deployment Execution

Deployment proceeds in up to three steps:

**Step 1: Pre-deploy validation.** The tool connects to every target host using the same credentials, verifies the object exists, and creates a backup. Hosts that fail connectivity or don't have the object are flagged. The tool shows the validation results and asks whether you want to proceed. If too many hosts are unreachable, you can abort here — nothing has changed on any device.

**Step 2: Apply to current device.** If there are pending changes, the tool applies them to the connected device first. If there are no pending changes (replication deploy), this step is skipped entirely — the current device already has the correct state.

**Step 3: Deploy to fleet.** The tool applies changes to each validated host in sequence. Each host's result is shown in real time. If the same error occurs on three consecutive hosts (indicating a systemic problem rather than an isolated failure), the tool warns you and asks whether to continue or stop.

After all hosts have been processed, a summary table shows the status of every device:

```
  DEPLOY SUMMARY
  ──────────────────────────────────────────────────────────────
  HOST                                SITE       STATUS   MESSAGE
  ──────────────────────────────────────────────────────────────
  bigip01-mgmt.dc1.example.com       (current)  OK       No changes needed
  bigip02-mgmt.dc1.example.com       DC1        OK       Deployed and saved
  bigip01-mgmt.dc2.example.com       DC2        OK       Deployed and saved
  bigip02-mgmt.dc2.example.com       DC2        SKIP     Connection failed
  ──────────────────────────────────────────────────────────────
  Total: 3 succeeded, 0 failed, 1 skipped
```

Status meanings in the deploy summary: **OK** means the deployment succeeded. **SKIP** means the host was never attempted — it failed pre-deploy validation (unreachable, object not found, or backup failed). **FAIL** means the host passed validation but the actual deployment failed. This distinction lets you quickly identify hosts that need attention versus hosts that were simply unavailable.

### What Fleet Deploy Will Not Do

Fleet deployment does not create objects that don't exist on target hosts. If you're deploying a datagroup and one of your fleet members doesn't have that datagroup, it is skipped with a status of `SKIP`. The assumption is that you're synchronizing existing objects across devices that are already configured. To provision new environments with the required datagroups and URL categories, use the Bootstrap feature (menu option 8).

Note: All fleet operations use the same cached credentials you used to connect to the initial Big-IP. If a fleet Big-IP requires different credentials, it will show as a connection failure during validation.

---

## Fleet Search

**Menu option 6** queries a datagroup or URL category across your fleet and provides tools to search within the results and identify configuration drift between devices.

### Selecting an Object

You choose whether to inspect a datagroup or a URL category, then provide the object name. For datagroups, you also select a partition if more than one is configured.

### Selecting a Scope

Next, you choose which fleet hosts to query:

- **All fleet hosts** — Every host in `fleet.conf`
- **Select by site** — All hosts at one or more specific sites
- **Select by host** — Individual hosts by number

### Pulling Data

The tool connects to each selected host, retrieves the object's entries, and builds a consolidated view. Hosts that are unreachable or don't have the object are flagged and skipped. After the pull completes, the tool shows a summary:

<img width="754" height="344" alt="Image" src="https://github.com/user-attachments/assets/9ac7334c-281b-4783-80d7-1d46b6c4a84e" />

The "unique entries across fleet" count is the deduplicated total — the union of all entries across every pulled host. Per-host counts let you spot imbalances at a glance before running a diff.

### Searching

Press `s` and enter a case-insensitive search pattern. The tool finds every entry that contains the pattern and classifies the results by consistency:

**Entries found on all pulled hosts** are listed once under a single header. There is no need to repeat them per host since every device has the same data.

**Entries found on only some hosts** are listed individually with per-host detail showing which hosts have the entry and which are missing it. This immediately surfaces drift without requiring a separate diff operation.

<img width="753" height="380" alt="Image" src="https://github.com/user-attachments/assets/74f083d4-67f8-4f7e-b816-039296e0e4d0" />

### Diffing

Press `d` to run a full diff across all pulled hosts. The diff shows every entry that is not present on every host, with per-host presence detail for each one. Entries that are consistent across the entire fleet are counted but not displayed — if everything matches, the tool reports that all entries are consistent.

```
  All 312 entries consistent across all 4 hosts.
```

When drift exists, only the inconsistent entries are shown:

```
  10.99.0.0/16
  ──────────────────────────────────────────────────────────────
    bigip01-mgmt.dc1.example.com (DC1)
    bigip02-mgmt.dc1.example.com (DC1)
    bigip01-mgmt.dc2.example.com (DC2) - missing
    bigip02-mgmt.dc2.example.com (DC2) - missing

  ══════════════════════════════════════════════════════════════
  1 inconsistent | 311 consistent across all hosts
```

This tells you exactly which entries need attention and where. To remediate drift, return to the main menu, open the object in the editor, and deploy it to the fleet using full replace mode.

---

## Fleet Backup

**Menu option 7** pulls a backup of a datagroup or URL category from fleet hosts and saves each one locally. This is useful for capturing the current state of a policy object across your entire topology before a change window, or for auditing what each device has without modifying anything.

### Selecting an Object

You choose whether to back up a datagroup or a URL category, then provide the object name. For datagroups, you also select a partition if more than one is configured. 

### Selecting a Scope

The scope selection is identical to Fleet Search:

- **All fleet hosts** — Every host in `fleet.conf`
- **Select by site** — One or more sites by number (comma-separated for multiple)
- **Select by host** — Individual hosts by number (comma-separated for multiple)

### Execution

The tool connects to each selected host, pulls the object's current state, and writes a timestamped backup CSV into the site's subdirectory within the backup directory. Hosts that are unreachable or don't have the object are flagged and skipped.

```
  ══════════════════════════════════════════════════════════════
    BACKUP: sslo-urlCatPinners
  ══════════════════════════════════════════════════════════════
  [ OK ] bigip01-mgmt.dc1.example.com (DC1)
  [ OK ] bigip02-mgmt.dc1.example.com (DC1)
  [ OK ] bigip01-mgmt.dc2.example.com (DC2)
  [FAIL] bigip02-mgmt.dc2.example.com (DC2) - Connection failed
  ══════════════════════════════════════════════════════════════

  Backup complete: 3 saved, 1 failed of 4 hosts
```

Backup files are organized by site in the backup directory and follow the same naming convention as pre-deploy backups.

---

## Bootstrap

**Menu option 8** creates datagroups and URL categories in bulk from a configuration manifest. This is designed for standing up new environments, rebuilding after a migration, or ensuring a standard set of objects exists across your fleet. 

### Bootstrap Configuration

The bootstrap manifest is a file called `bootstrap.conf` stored in the backup directory. It uses pipe-delimited format with three fields per line:

```
object|name|attribute
```

- **object** — `dg` for datagroup, `cat` for URL category
- **name** — must start with a letter, no spaces allowed
- **attribute** — `string`, `address`, or `integer` for datagroups; `allow`, `block`, or `confirm` for URL categories

Lines starting with `#` are comments. Example:

```
dg|bypass-clients|address
dg|bypass-servers|address
dg|troubleshoot|address
cat|Bypass-hosts|allow
cat|Pinners|allow
cat|IPS-Only|allow
```

### Creating the Config

Select option 1 from the Bootstrap submenu to generate a boilerplate `bootstrap.conf` with format instructions and examples. If the file already exists, the tool warns you and does not overwrite it.

### Importing and Deploying

Select option 2 to import. The tool validates every line — object type, name format, attribute match, and duplicate detection. If any line fails validation, the entire file is rejected with line-specific error messages.

After validation, the tool displays a plan summary showing all datagroups and URL categories that will be created, with their types and actions.

You then select a partition for the datagroups, followed by deployment scope using the standard scope selection (all hosts, by site, or by host). The connected host is included as a selectable target — bootstrap does not auto-apply to any host. Objects that already exist on a target are skipped.

---

## CSV File Formats

### Datagroup CSV

Datagroup CSV files use `key,value` format with one entry per line. Values are optional.

For string datagroups (domains, hostnames, URLs):

```
example.com,Production
staging.example.com,Staging
dev.example.com
```

For address datagroups (IP addresses, CIDR subnets):

```
10.0.0.0/8,Internal
172.16.0.0/12,RFC1918
192.168.1.0/24,Lab
```

For integer datagroups (port numbers, numeric values):

```
443,HTTPS
80,HTTP
8443,Alt-HTTPS
```

### URL Category CSV

URL category CSV files contain one domain or URL per line:

```
example.com
www.example.com
.example.org
```

A leading dot indicates a wildcard match. The entry `.example.org` will be converted to `https://*.example.org/` which matches all subdomains of `example.org`.

### General CSV Rules

Lines starting with `#` are treated as comments and ignored during import. Blank lines are also ignored. Windows line endings (CRLF) are detected and converted automatically.

When exporting, the tool includes a comment header with metadata about the source object:

```
# Datagroup Export: /Common/bypass-domains
# Partition: Common
# Type: string
# Exported: Thu Mar 27 14:30:52 UTC 2026
# Format: key,value
#
.microsoft.com,
.office365.com,
.windowsupdate.com,
```

These comment headers are preserved during reimport, making export files directly usable as import files.

---

## Backup System

If you prefer to have the tool automatically backup before every apply action you can enable automatic pre-change backups by setting `BACKUPS_ENABLED` to `1` in the script configuration. The default is `0` (disabled).

### When Backups Are Created

- Before overwriting or merging entries during CSV import
- Before deleting a datagroup or URL category
- Before applying changes in the editor
- Before deploying to each fleet host

### Backup Location and Naming

Backups are stored in the configured backup directory with timestamped filenames. When the connected host is part of a fleet site, backups are organized into the site's subdirectory alongside fleet deployment backups:

```
DC1/Common_bypass-domains_internal_20260327_143052.csv
```

When connected to a host that is not part of any fleet site, backups go to the root backup directory:

```
Common_bypass-domains_internal_20260327_143052.csv
```

Fleet deployment backups for remote hosts are always organized by site:

```
DC1/bigip02-mgmt_dc1_example_com_Common_bypass-domains_20260327_143022.csv
```

### Retention

The tool retains up to `MAX_BACKUPS` files per object (default: 10). When the limit is exceeded, the oldest backup files are removed automatically.

### Restoring from Backup

To restore from a backup, use the Create/Update from CSV option (menu option 2) and point it at the backup file. Select overwrite mode to replace the current contents with the backup.

---

## Configuration Reference

### Script Variables

| Variable | Bash Default | PowerShell Default | Description |
|----------|-------------|-------------------|-------------|
| `BACKUP_DIR` | `/shared/tmp/dgcat-admin-backups` | `$PSScriptRoot\dgcat-admin-backups` | Storage for backups, logs, and fleet config |
| `MAX_BACKUPS` | `10` | `10` | Maximum backup files retained per object |
| `BACKUPS_ENABLED` | `0` | `0` | Set to `1` to enable automatic pre-change backups |
| `LOGGING_ENABLED` | `0` | `0` | Set to `1` to enable session log file creation |
| `PARTITIONS` | `Common` | `Common` | Comma-separated list of BIG-IP partitions to manage |
| `PREVIEW_LINES` | `5` | `5` | Number of lines shown in CSV file previews |
| `API_CONNECT_TIMEOUT` | `10` | — | TCP connection timeout in seconds |
| `API_REQUEST_TIMEOUT` | `60` | — | Total request timeout in seconds |
| `API_TIMEOUT` | — | `60` | Request timeout in seconds |

### Protected Datagroups

The following system datagroups are protected and cannot be modified or deleted through the tool and are hidden from view when viewing available datagroups.

- `private_net`
- `images`
- `aol`
- `sys_APM_MS_Office_OFBA_DG`

Attempting to modify or delete these datagroups will produce an error message.

### Log Files

Each session creates a log file in the backup directory:

```
dgcat-admin-20260327_143052.log
```

The log captures all operations performed during the session, including timestamps, success/failure status, and error details. Log files are useful for auditing changes and troubleshooting issues that occurred during a session.

To enable log file creation, set `LOGGING_ENABLED` to `1` in the script configuration.

---
## Troubleshooting

### Connection Issues

**"Connection failed. Check hostname and network connectivity."**
The tool could not reach the BIG-IP management interface. Verify that the hostname or IP is correct, that port 443 is open between your machine and the BIG-IP, and that the management interface is configured and accessible.

**"Connection failed. HTTP 503"**
The BIG-IP is reachable but the REST API service (restjavad) is unavailable. The GUI may still work because it runs through a separate service (httpd/tmui). Restart restjavad via SSH: `bigstart restart restjavad` and allow 30-60 seconds for it to initialize. Monitor with `bigstart status restjavad` until it shows `run`.

**"Authentication failed. Check username/password."**
The BIG-IP rejected the credentials. Verify the username and password. The account needs administrative API access — typically the `admin` role. Accounts with limited roles may not have permission to query or modify datagroups.

### Import Issues

**"CIDR alignment errors detected"**
One or more CIDR entries in your CSV have non-zero host bits for their prefix length (e.g., `10.159.55.0/16` should be `10.159.0.0/16`). The tool shows up to five examples with corrected values. Fix the entries in your CSV and reimport. BIG-IP will reject misaligned CIDRs so the import is blocked before the API call.

**"X duplicate entries removed, Y unique entries"**
Your CSV contained duplicate keys or URLs. The tool automatically removes duplicates before applying. The reported count reflects what will land in the datagroup or URL category. No action needed.

**"Failed to populate URL category"**
The URL category was created but the API timed out while applying URLs. This can happen with very large URL categories (>10000 records). The category likely contains the data — verify in the GUI or by viewing it in the tool. If it is empty, retry using overwrite mode. If timeouts persist, increase `API_REQUEST_TIMEOUT` (bash) or `$script:API_TIMEOUT` (PowerShell) in the script header. The default is 60 seconds.

### Partition Issues

**"Partition 'X' not found on target system."**
The partition listed in your `PARTITIONS` configuration does not exist on the BIG-IP you connected to. Either add the partition on the BIG-IP, remove it from your configuration, or accept that it will be skipped. The tool logs a warning but continues with the partitions that do exist.

### Fleet Issues

**"Duplicate hosts detected in fleet.conf"**
The tool found the same hostname or IP listed more than once in `fleet.conf`. Both conflicting entries are displayed in `fleet.conf` format so you can locate them. The script halts until `fleet.conf` is corrected or deleted. This check prevents a host from receiving duplicate deployments or being counted twice in search results.

**"No fleet hosts passed validation. No changes have been made."**
Every target host either failed to connect or didn't have the target object. Verify network connectivity and credentials. Remember that fleet deployment uses the same credentials you used to connect to the primary device.

**Hosts showing "Object not found" during validation.**
The host is reachable and credentials are valid, but the target datagroup or URL category does not exist on that host. Create the object on the target host first, then redeploy.

**Hosts showing "Connection failed" during validation.**
The host is unreachable or restjavad is down. Verify network connectivity and REST API availability on the target. See the 503 guidance above.

**Hosts showing as SKIP in the deploy summary.**
The host failed pre-deploy validation — either it was unreachable, the target object doesn't exist, or the backup failed. SKIP means deployment was never attempted on that host.

### Editor Issues

**"No changes to apply" when you expected changes.**
The editor compares your working state against the state that was loaded when you opened it (or last applied). If you applied changes with `w` and then didn't make further edits, the tool correctly reports no pending changes. Use `D` to deploy the current state to the fleet even without pending changes.

**Bash editor warning: "This dataset has X entries"**
Datasets over 8,000 entries will cause the bash editor to become very slow or unresponsive due to interpreter limitations. Import, export, and deploy operations are unaffected. Use the PowerShell version for interactive editing of large datasets. PowerShell has been tested with 20,000 entries without performance issues.

### General Issues

**Slow API responses with large datasets.**
Operations on URL categories with thousands of entries may take longer due to BIG-IP management plane processing time. The default API timeout is 60 seconds. For very large categories (10,000+ entries), you may need to increase this value in the script header. If performance is consistently poor, check the BIG-IP management plane utilization — other automation or monitoring tools competing for API access can slow things down.
