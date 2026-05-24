# Release Notes

## v1.2

- Replaced Kevin's boilerplate blocking-page-html with my own
 <img width="918" height="635" alt="Image" src="https://github.com/user-attachments/assets/e4ca1895-2ca9-450a-9200-c9ffe584492f" />
- Replaced Python rule converter with `jq -Rs` for JSON encoding of iRules
- Eliminated temporary `.in`/`.out` files during install
- Service virtual polling interval reduced from 10 seconds to 5 seconds
- Removed unnecessary 15-second wait on service chain creation
- Redundant REST existence checks removed from uninstaller phases
- Orphaned `f5-tenant-restrictions` iRules cleaned up after service creation for all extensions
- Discovery display alignment corrected in uninstaller

## v1.1

### Advanced Blocking Pages

- Split Kevin's single toggle-based iRule into two discrete SSLO inspection services:
  - `ssloS_Blocking_Page` — unconditional category block
  - `ssloS_CertError_Page` — conditional server certificate error block
- Added `ssloSC_Block_Page` service chain containing `ssloS_Blocking_Page`
- Renamed iRules to match their associated service names (`ssloS_Blocking_Page-rule`, `ssloS_CertError_Page-rule`)
- Uninstaller warns about MCP desync if services are still referenced by security policy rules
- Completion screen displays required SSL configuration changes for CertError_Page (Mask settings)

## v1.0

- Initial release based entirely on [Kevin Stewart's SSL Orchestrator service extensions](https://github.com/f5devcentral/sslo-service-extensions)
- Self-contained installer with all payloads embedded for closed network environments
- Advanced Blocking Pages and DoH Guardian extensions supported in 1.0
- Full uninstall support as long as this installer was used to install those extensions
