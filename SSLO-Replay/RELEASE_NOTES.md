# Release Notes

## v0.3.15-devel (Beta 1 - May 28 2026)

- Initial beta release — snapshot and replay of SSLO iAppsLX configuration across BIG-IP devices
- Captures all SSLO deployment types: SSL settings, services, service chains, security policies, topologies
- State-to-CREATE transformation with per-type inputProperties from F5 Ansible collection `f5networks.f5_bigip 3.15.0-devel`
- Scoped replay — select a single topology and the tool resolves its full dependency tree
- Policy swap — apply a snapshot policy to an existing topology with rename and overwrite support
- External dependencies (iRules, monitors, cipher groups, profiles) captured as raw API JSON for auto-creation on target
- Prerequisite validation expanded to all service types (L3, HTTP, ICAP, Layer 2, TAP) with interactive resolution
- Version-locked snapshots — can only be replayed by the tool version that created them
- MODIFY operation blocks excluded from capture — only CREATE blocks are portable
