# SSL Orchestrator Service Extensions Installer

Unified installer and uninstaller for F5 SSL Orchestrator service extensions, based on Kevin Stewart's original 1.0 work. These extensions have been directly incorporated into this tool and modified to provide additional functionality.

![License](https://img.shields.io/badge/license-MIT-green)
![F5 Compatible](https://img.shields.io/badge/F5%20BIG--IP-compatible-orange)
![TMOS Version](https://img.shields.io/badge/TMOS-17.x%2B-red)
![TMOS Version](https://img.shields.io/badge/TMOS-21.x%2B-red)
![SSLO Version](https://img.shields.io/badge/SSLO-12.x%2B-blue)
![SSLO Version](https://img.shields.io/badge/SSLO-13.x%2B-blue)

## Why This Exists

This tool was built for two reasons:

**Closed network support.** Kevin's original installers pull iRules, iFiles, and service definitions from GitHub at runtime. Organizations operating in closed or air-gapped networks cannot use them. This installer is fully self-contained with all payloads embedded directly in the script. The only external file is `blocking-page-html`, kept separate for ease of editing.

**Architectural changes.** Kevin's Advanced Blocking Pages extension used a single iRule with a static boolean toggle (`GLOBAL_BLOCK`) to switch between two distinct functions: unconditional category blocking and conditional server certificate error blocking. Because the toggle is global, the two functions are mutually exclusive - you cannot use both simultaneously across different service chains. This installer splits them into discrete SSLO services, each with a single clearly defined role, managed entirely through the SSLO GUI.

## What Changed From Kevin's 1.0

The original Advanced Blocking Pages extension creates one service (`ssloS_F5_Advanced-Blocking-Pages`) with one iRule that handles both category blocking and TLS verify blocking via a toggle. The user must choose one or the other.

This installer replaces that with three objects:

| Object | Type | Purpose |
|--------|------|---------|
| `ssloS_Blocking_Page` | Inspection Service | Unconditional block page. Every request that reaches this service is blocked. |
| `ssloS_CertError_Page` | Inspection Service | Conditional block page. Only blocks when the server-side TLS certificate fails verification. Passes traffic through unmodified when the certificate is valid. |
| `ssloSC_Block_Page` | Service Chain | Pre-built service chain containing only `ssloS_Blocking_Page`, ready to assign to any security policy rule. |

The `sslo-tls-verify-rule` iRule is unchanged from Kevin's original. It captures the server certificate verification result into a sharedvar and is added to the SSLO topology Resources - not to a service.

## How To Use the Services

**Category blocking (URLDB, custom rules, etc.):**
Assign `ssloSC_Block_Page` as the service chain on any security policy rule where traffic should be blocked. The `ssloS_Blocking_Page` service is the only member of this chain and will unconditionally serve a block page to the client.

**Server certificate error blocking:**
Add `ssloS_CertError_Page` to any inspection service chain where TLS intercept is enabled. When the origin server presents an invalid certificate, the client receives a block page instead of a browser certificate warning. When the certificate is valid, traffic passes through normally.

For `ssloS_CertError_Page` to function, the SSLO SSL configuration must be updated:
- Set **Expire Certificate Response** to **Mask**
- Set **Untrusted Certificate Authority** to **Mask**
- Add **sslo-tls-verify-rule** to the topology virtualserver **Resources**

The Mask setting tells SSLO to present a valid forged certificate to the client even when the server certificate has errors, allowing the block page to be delivered over the established HTTPS session.

## Currently Supported Extensions

| Extension | Original Source | Description |
|-----------|----------------|-------------|
| Advanced Blocking Pages | [Kevin Stewart - f5devcentral](https://github.com/f5devcentral/sslo-service-extensions/tree/main/advanced-blocking-pages) | Split into discrete category block and certificate error services with a pre-built blocking service chain |
| DoH Guardian | [Kevin Stewart - f5devcentral](https://github.com/f5devcentral/sslo-service-extensions/tree/main/doh-guardian) | DNS-over-HTTPS inspection, blackhole, and sinkhole service for SSLO |

## Additional Notes

- The installer cleans up orphaned `f5-tenant-restrictions` iRules that SSLO auto-creates when the service type is repurposed. These are not needed and are removed after the service virtual is patched with the correct iRule.
- Before uninstalling, ensure that all services and service chains are removed from security policy rules. Uninstalling while objects are still referenced by a policy will cause MCP desync.
- If you install any service extensions and then run F5's `sslofix` script, it will always report duplicate blocks in diagnostic mode. This is because the extension technique repurposes the "F5 Tenant Restrictions" service type within SSLO.

[Release Notes](RELEASE_NOTES.md) — Service Extension Installer 

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
