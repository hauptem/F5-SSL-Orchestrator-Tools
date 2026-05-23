# Release Notes

## v1.2

- Replaced Python rule converter with `jq -Rs` for JSON encoding of iRules
- Removed Python 3 runtime dependency from the installer
- Eliminated temporary `.in`/`.out` files during install

## v1.1

### Advanced Blocking Pages

- Split Kevin's single toggle-based iRule into two discrete SSLO inspection services:
  - `ssloS_Blocking_Page` — unconditional category block
  - `ssloS_CertError_Page` — conditional server certificate error block
- Added `ssloSC_Block_Page` service chain containing `ssloS_Blocking_Page`
- Renamed iRules to match their associated service names (`ssloS_Blocking_Page-rule`, `ssloS_CertError_Page-rule`)
- Unique proc names per iRule to prevent global namespace collision
- Installer cleans up orphaned `f5-tenant-restrictions` iRules after service creation
- Uninstaller warns about MCP desync if services are still referenced by security policy rules
- Completion screen displays required SSL configuration changes for CertError_Page (Mask settings)

### General

- Full discovery before install and uninstall to detect existing objects
- Polling with timeout replaces blind `sleep` for service readiness
- REST helper functions with HTTP status validation
- Trap handler for unexpected exits with recovery guidance

## v1.0

- Initial release based on [Kevin Stewart's SSL Orchestrator service extensions](https://github.com/f5devcentral/sslo-service-extensions)
- Self-contained installer with all payloads embedded for closed network environments
- Advanced Blocking Pages and DoH Guardian extensions
- Full uninstall support with dependency-ordered teardown
