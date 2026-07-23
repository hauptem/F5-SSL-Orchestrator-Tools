# F5 SSL Orchestrator Tools

![License](https://img.shields.io/badge/license-MIT-green)
![TMOS Version](https://img.shields.io/badge/TMOS-17.x%20%7C%2021.x-red)
![SSLO Version](https://img.shields.io/badge/SSLO-12.x%20%7C%2013.x-blue)

Useful scripts and tools for F5's SSL Orchestrator product. Some of these are modifications of existing F5 tools rebuilt for customers who have 'closed network' or other operational considerations.

## Tools

| Tool | Description |
|------|-------------|
| [Clean Slate](https://github.com/hauptem/F5-SSL-Orchestrator-Tools/tree/main/Clean-Slate) | Removes all SSLO configuration and restores to a 'clean slate' |
| [TLS Recon](https://github.com/hauptem/F5-SSL-Orchestrator-Tools/tree/main/TLS-Recon) | Discover TLS traffic on non-standard ports during SSLO deployments |
| [DGCat Admin](https://github.com/hauptem/F5-SSL-Orchestrator-Tools/tree/main/DGCat-Admin) | Menu-driven tool for LTM datagroup and URL category management |
| [SSLO Replay](https://github.com/hauptem/F5-SSL-Orchestrator-Tools/tree/main/SSLO-Replay) | SSLO configuration backup and restore via REST API |
| [SSLO Extension Installer](https://github.com/hauptem/F5-SSL-Orchestrator-Tools/tree/main/SSLO-Extension-Installer) | An offline installer/uninstaller for SSLO service extensions |


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
