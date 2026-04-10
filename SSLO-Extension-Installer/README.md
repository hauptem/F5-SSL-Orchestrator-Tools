# SSL Orchestrator Service Extensions Installer

Unified installer and uninstaller for Kevin Stewart's F5 SSL Orchestrator service extensions which have been directly incorporated into this tool.

![License](https://img.shields.io/badge/license-MIT-green)
![F5 Compatible](https://img.shields.io/badge/F5%20BIG--IP-compatible-orange)
![TMOS Version](https://img.shields.io/badge/TMOS-17.x%2B-red)
![TMOS Version](https://img.shields.io/badge/TMOS-21.x%2B-red)
![SSLO Version](https://img.shields.io/badge/SSLO-12.x%2B-blue)
![SSLO Version](https://img.shields.io/badge/SSLO-13.x%2B-blue)

This was built for 'closed network' organizations that cannot use Kevin's GitHub-dependent installers. Single self-contained script with no runtime network dependencies and full extension uninstall support. The blocking-page-html was kept separate for ease of editing. The only change I have made to Kevin's extensions was to change "F5-Advanced-Blocking-Pages" to simply "Blocking_Page" so the name would not be truncated in the SSLO GUI. No functional changes were made to Kevin's code.

## Currently Supported Extensions

| Extension | Description |
|-----------|-------------|
| [Advanced Blocking Pages](https://github.com/f5devcentral/sslo-service-extensions/tree/main/advanced-blocking-pages) | Adds a blocking page service to SSLO for use in a Service Chain |
| [DoH Guardian](https://github.com/f5devcentral/sslo-service-extensions/tree/main/doh-guardian) | DNS-over-HTTPS inspection, blackhole, and sinkhole service for SSLO |

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Disclaimer

- This installer is **NOT** officially endorsed, supported, or maintained by F5 Inc.
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
