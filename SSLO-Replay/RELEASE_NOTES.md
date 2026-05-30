# Release Notes

## vb2.3.15.0-devel (Beta 2 - May 29 2026)
 
- New feature: Redeploy SSLO Topology — reads device state into memory, pushes selected topology back through the gc processor as a MODIFY to force a fresh deployment pass. Resolves "not initialized" warnings after replay. Does not clear GUI-level "pending" drafts (Those can only be cleared by deleting via the SSLO GUI).
- Security policy prereq validation for datagroups (existence and type match) and custom URL categories
- Built-in F5 URL category filter (168 entries from Ansible `condition_category_list`) — built-ins skipped in both capture and validation
- Policy swap pre-flight plan shows all actions before touching the target
- MODIFY operation blocks excluded from replayable category ... fixes duplicate policy on replay after policy swap
- mcpBlockIO block database save added alongside tmsh save (undocumented feature pulled from F5's sslofix script)

## vb1.3.15.0-devel (Beta 1 - May 28 2026)

- Initial beta release — snapshot and replay of SSLO iAppsLX configuration across BIG-IP devices
- Captures all SSLO deployment types: SSL settings, services, service chains, security policies, topologies
- State-to-CREATE transformation with per-type inputProperties from F5 Ansible collection `f5networks.f5_bigip 3.15.0-devel`
- Scoped replay feature: select a single topology and the tool resolves its full dependency tree
- Policy swap feature: apply a snapshot policy to an existing topology with rename and overwrite support
- Prerequisite validation expanded to all service types (L3, HTTP, ICAP, Layer 2, TAP) 
- Version-locked snapshots can only be replayed by the SSLO-Replay script version that created them due to the f5 Ansible module mapping dependency requirement
- MODIFY operation blocks are excluded from capture... only the CREATE blocks are replayable
