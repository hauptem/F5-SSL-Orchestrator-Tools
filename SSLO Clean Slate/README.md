# F5 SSL Orchestrator Clean Slate

![License](https://img.shields.io/badge/license-MIT-green)
![F5 Compatible](https://img.shields.io/badge/F5%20BIG--IP-compatible-orange)
![TMOS Version](https://img.shields.io/badge/TMOS-17.x%2B-red)
![TMOS Version](https://img.shields.io/badge/TMOS-21.x%2B-red)

Removes all SSL Orchestrator configurations and restores SSLO to a clean state.

Based on Kevin Stewart's [sslo-nuke-delete](https://github.com/f5devcentral/sslo-script-tools/tree/main/sslo-nuke-delete) script (F5, October 2020).

## Requirements

- BIG-IP running TMOS 17.x or 21.x
- SSL Orchestrator 12.0 or higher

## What It Does

1. Backs up the installed SSLO RPM to `/var/tmp/`
2. Deletes iApp blocks and packages
3. Removes SSLO application services (two passes)
4. Unbinds and deletes SSLO iApp blocks (two passes)
5. Deletes all SSLO tmsh objects
6. Clears REST storage
7. Verifies cleanup and reports results

A log file is written to `/var/log/sslo-clean-<timestamp>.log`.

## Usage

```bash
chmod +x sslo-clean-slate.sh
./sslo-clean-slate.sh
```

The script will prompt for admin credentials and require you to type `CONFIRM` before making any changes.

After the script completes, reinstall the SSLO RPM manually via the GUI:
**iApps > Package Management LX > Import** using the backup from `/var/tmp/`.

## Operational Enhancements

- Prompts for credentials instead of hardcoding them
- Requires explicit confirmation before executing
- Pre-flight checks (root, tmsh, restcurl, jq)
- Backs up the SSLO RPM before deleting anything
- Step-by-step logging with full log file output
- Post-run verification of cleanup
- Credentials are never written to the log file

## Warning

**This script is destructive.** It will permanently delete all SSLO configuration on the device. Do not run on a system with active production SSLO traffic or on a system that you do not have backup configurations for.

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

