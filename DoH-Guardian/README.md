# SSL Orchestrator Service Extension - DoH Guardian

![License](https://img.shields.io/badge/license-MIT-green)
![F5 Compatible](https://img.shields.io/badge/F5%20BIG--IP-compatible-orange)
![TMOS Version](https://img.shields.io/badge/TMOS-17.x%2B-red)
![TMOS Version](https://img.shields.io/badge/TMOS-21.x%2B-red)
![SSLO Version](https://img.shields.io/badge/SSLO-12.x%2B-blue)
![SSLO Version](https://img.shields.io/badge/SSLO-13.x%2B-blue)

Based entirely on Kevin Stewart's SSLO Service Extension: [DoH Guardian](https://github.com/f5devcentral/sslo-service-extensions/tree/main/doh-guardian)

DoH Guardian is an F5 SSL Orchestrator service extension function for monitoring/managing DNS-over-HTTPS traffic flows and detecting potentially malicious DoH exfiltration. This SSL Orchestrator service extension is invoked at a detected (and decrypted) DNS-over-HTTPS request and has several options for logging, management, and anomaly detection. 

Kevin's script makes curl calls from a Big-IP to GITHUB to retrieve and process installation artifacts. This is not viable for many "closed network" customers. This script removes the GITHUB and curl dependency and rolls all of the artifacts into a single installer script that also includes a full uninstaller. No other functionality was changed. 

[Kevin's DoH Guardian configuration guide](https://github.com/f5devcentral/sslo-service-extensions/blob/main/doh-guardian/README.md)

## Requirements

- BIG-IP running TMOS 17.x or higher
- SSL Orchestrator 11.x or higher


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
