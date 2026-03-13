# TLS Recon for SSL Orchestrator

![License](https://img.shields.io/badge/license-MIT-green)
![F5 Compatible](https://img.shields.io/badge/F5%20BIG--IP-compatible-orange)
![TMOS Version](https://img.shields.io/badge/TMOS-17.x%2B-red)
![TMOS Version](https://img.shields.io/badge/TMOS-21.x%2B-red)

A lightweight F5 BIG-IP iRule for discovering TLS traffic on non-standard ports during SSL Orchestrator deployments.

## Overview

SSL Orchestrator (SSLO) does not natively identify TLS traffic on arbitrary ports. When deploying SSLO with an all-port TCP interception topology, organizations need visibility into which ports are carrying TLS traffic that may be candidates for decryption and inspection.

TLS Recon attaches to an SSLO TCP intercept virtual server and logs destination ports where valid TLS ClientHello messages are detected. It provides actionable intelligence for building SSLO interception rules.

## Features

- Inline detection without impacting traffic flow
- TLS ClientHello validation to minimize false positives
- Configurable rate limiting to control log volume

## Requirements

- F5 BIG-IP with SSLO deployed
- TMOS 17.1 or later

## Quick Start

1. Create the iRule on your BIG-IP
2  Deployment:   Attach to SSLO TCP intercept virtual server - Example: sslo_<topology>_tcp.app/sslo_<topology>_tcp-in-t-4
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
TLS-RECON: TLS Spotted on port 8443
TLS-RECON: TLS Spotted on port 9443
TLS-RECON: TLS Spotted on port 8080
```

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
