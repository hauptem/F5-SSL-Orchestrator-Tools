# F5 SSL Orchestrator Clean Slate

![License](https://img.shields.io/badge/license-MIT-green)
![F5 Compatible](https://img.shields.io/badge/F5%20BIG--IP-compatible-orange)
![TMOS Version](https://img.shields.io/badge/TMOS-17.x%2B-red)
![TMOS Version](https://img.shields.io/badge/TMOS-21.x%2B-red)

This script will remove all SSL Orchestrator configurations and restore the SSLO to a "clean slate"

The base logic for this script was provided by Kevin Stewart at F5 via his "SSLO Nuclear Delete" October 2020.

[https://github.com/f5devcentral/sslo-script-tools/tree/main/sslo-nuke-delete](https://github.com/f5devcentral/sslo-script-tools/tree/main/sslo-nuke-delete)

The F5 SSL Orchestrator Clean Slate script provides additional operational safety nets, prompts for credentials instead of hard codes them, provides step by step feedback of script operation, and also performs RPM backup of the main sslo rpm package for reinstallation after the script exits.

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

