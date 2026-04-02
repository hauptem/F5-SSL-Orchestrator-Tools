# DGCat-Admin v5.0 — F5 BIG-IP Datagroup & URL Category Manager

![License](https://img.shields.io/badge/license-MIT-green)
![F5 Compatible](https://img.shields.io/badge/F5%20BIG--IP-compatible-orange)
![TMOS Version](https://img.shields.io/badge/TMOS-17.x%2B-red)
![TMOS Version](https://img.shields.io/badge/TMOS-21.x%2B-red)


A menu-driven administration tool for managing LTM datagroups and custom URL categories on F5 BIG-IP systems via the iControl REST API. Designed primarily for SSL Orchestrator (SSLO) policy management, but can be used for general purpose datagroup and URL category management.

Available in two versions with identical functionality:

- **Bash** (`dgcat-admin.sh`) — For Linux, macOS, or directly on BIG-IP/Big-IQ
- **PowerShell** (`dgcat-admin.ps1`) — For Windows

### The Datagroup and URL Category Approach

F5's recommended approach is to reference datagroups or custom URL categories in your SSLO security policy rules instead of adding entries directly. Datagroups and URL categories are optimized for fast lookups, can hold thousands of entries without impacting policy performance, and are independent objects that can be managed, exported, and replicated separately from the policies that reference them.

The challenge is that BIG-IP provides limited tooling for bulk management of these objects when an orchestration tool such as Ansible is not available. Adding 500 domains to a datagroup through the GUI is tedious. Exporting a URL category to replicate it at another site requires manual work. Keeping six BIG-IP SSLO's in sync across three datacenters is operationally expensive.

### What DGCat-Admin Solves

DGCat-Admin provides a single interface for all of these operations. You can import thousands of entries from a CSV file in seconds, export existing objects for backup or replication, edit entries interactively with search and bulk operations, and push the result to every BIG-IP in your fleet with a single command.

The tool handles the details that make these operations error-prone when done manually: type validation, backup before modification, format conversion between CSV and BIG-IP native formats, and atomic application of changes.

DGCat-Admin makes managing those site lists very easy.

- Need to export a few massive datagroups or custom URL categories so you can precisely replicate existing SSLO business logic at another site in just minutes?
- Need to ingest a large number of subnets or hosts from an Excel spreadsheet into a datagroup for SSLO security policy use?
- Want to take a custom URL category and convert it to a datagroup?
- Want to take a datagroup and convert it to a custom URL category?
- Want to search your entire fleet non-destructively and find a needle in a stack of needles?
- Backup datagroups or URL categories from your entire topology
**New in 5.0**
- Bootstrap an entire fleet with datagroups and URL categories from a single config file
- Make edits to datagroups without having to replace the entire datagroup contents (Option 5 Editor enhancement for writes and deploys)
  https://community.f5.com/discussions/technicalforum/update-an-internal-data-group-via-api/306520 

**This tool was designed specifically for those purposes.**

<img width="636" height="396" alt="Image" src="https://github.com/user-attachments/assets/0899bdbb-4d23-45f7-a396-13b1a73fd11e" />

## Requirements

### Bash Version

- curl
- jq
- Network access to BIG-IP management interface (port 443)
- BIG-IP running TMOS 17.x or later
- Note: DGCat's editor in bash gets pretty sluggish when there are more than 6k-7k records, but the create/deploy functions work fine
  
### PowerShell Version

- PowerShell 5.1 or later
- Network access to BIG-IP management interface (port 443)
- BIG-IP running TMOS 17.x or later
- Note: Powershell works fast even with 20k URL records - just set API_TIMEOUT accordingly for large datasets

## Installation

### Bash

```bash
# Copy to a management host or directly to BIG-IP
scp dgcat-admin.sh root@<host>:/shared/scripts/

# Make executable
chmod +x /shared/scripts/dgcat-admin.sh

# Run
/shared/scripts/dgcat-admin.sh
```

### PowerShell

```powershell
# Copy to a directory on your Windows management host
# Run
.\dgcat-admin.ps1
```

## Documentation

- [Release Notes](RELEASE_NOTES.md) — DGCat Release notes
- [User Guide](USERGUIDE.md) — Detailed operating instructions

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

By using this software, you acknowledge that you have read and understood these disclaimers and agree to use this solution at your own risk.
