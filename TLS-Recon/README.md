# TLS Recon for SSL Orchestrator

![License](https://img.shields.io/badge/license-MIT-green)
![F5 Compatible](https://img.shields.io/badge/F5%20BIG--IP-compatible-orange)
![TMOS Version](https://img.shields.io/badge/TMOS-17.x%2B-red)
![TMOS Version](https://img.shields.io/badge/TMOS-21.x%2B-red)
![SSLO Version](https://img.shields.io/badge/SSLO-12.x%2B-blue)
![SSLO Version](https://img.shields.io/badge/SSLO-13.x%2B-blue)

A lightweight F5 BIG-IP iRule for discovering TLS traffic on non-standard ports during SSL Orchestrator deployments.

## Overview

SSL Orchestrator (SSLO) does not natively identify TLS traffic on arbitrary ports. When deploying SSLO with an all-port TCP interception topology, organizations need visibility into which ports are carrying TLS traffic that may be candidates for decryption and inspection.

TLS Recon attaches to an SSLO TCP intercept virtual server and logs destination ports where valid TLS ClientHello messages are detected. It provides actionable intelligence for building SSLO interception rules.

## Requirements

- F5 BIG-IP with SSLO deployed
- BIG-IP running TMOS 17.x or 21.x
- SSL Orchestrator 12.0 or higher

## Quick Start

1. Create the iRule on your BIG-IP
2. Deployment: Attach to SSLO TCP intercept virtual server - Example: sslo_<topology>_tcp.app/sslo_<topology>_tcp-in-t-4
3. Monitor `/var/log/ltm` for `TLS-RECON` entries
4. Use discovered ports to refine SSLO interception rules
```bash
tail -f /var/log/ltm | grep TLS-RECON
```

## Configuration

**Rate Limiting**

Adjust the `timeout` variable to control how often each port is logged (in seconds):
```tcl
set timeout 300
```

**Port Exclusions**

Create a datagroup to exclude ports you no longer want logged:
```bash
tmsh create ltm data-group internal datagroup-tls-recon type integer records add { 8443 { } }
```

## Output
```
TLS-RECON: TLS spotted on port 4353 to 10.61.54.2 from 192.168.1.100
TLS-RECON: TLS spotted on port 7889 to 172.16.1.3 from 192.168.1.105
TLS-RECON: TLS spotted on port 14656 to 10.20.20.50 from 10.10.20.50
TLS-RECON: TLS spotted on port 33712 to 192.168.55.33 from 172.16.50.23
TLS-RECON: TLS spotted on port 45654 to 10.4.254.48 from 192.168.1.100
TLS-RECON: TLS spotted on port 55551 to 172.16.45.28 from 10.10.20.88
```

---

### Bash Version

**Requirements:** bash 4.0+, netcat (nc), openssl
```bash
chmod +x tls-recon-tester.sh
./tls-recon-tester.sh
```

### PowerShell Version

**Requirements:** PowerShell 5.1+ or PowerShell Core 7+

Note: if on an older version of PowerShell the "legacy" script was provided. Try to use the non-legacy version first.

```powershell
.\tls-recon-tester.ps1
```

Or bypass execution policy:
```powershell
powershell -ExecutionPolicy Bypass -File .\tls-recon-tester.ps1
```

### Usage

1. Enter target IP or hostname
2. Enter SNI hostname for TLS tests
3. Select test type: TCP only, TLS only, or Both
4. Enter ports interactively or as a batch list
5. Review results and optionally run another test

---

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
