# Release Notes

## b5.3.15.0-devel (Beta 5 - June 12 2026)

- Replay aborts when the target inventory cannot be read. A failed read previously disabled collision detection and the full snapshot would deploy onto a populated device
- Key passphrase prompt for SSL settings replay. Passphrases are not recoverable from state blocks and were restored blank. One prompt per unique key
- Gateway pool prerequisite check read egressNetwork.gatewayPool, which does not exist. Correct field is outboundGateways.referredObj per the F5 Ansible module source. Gateway pools were never validated
- Existing objects in ERROR or stuck state are flagged in the replay plan with a warning to remove them before re-replay
- Policy swap failures list the changes completed before the failure, including policy content already live on the target
- Replay halts for confirmation after 3 consecutive object failures
- Objects posted without a returned block ID are reported as unverified. "Replay complete" requires zero failed and zero unverified
- ERROR-state failures include the block error detail in the output
- Stuck-block cleanup during redeploy uses anchored name matching. The previous substring match could clear blocks of a topology whose name contains the selected one
- Snapshots are verified after writing: round-trip parse and block count check. Import warns when metadata blockCount does not match contents

## b4.3.15.0-devel (Beta 4 - June 1 2026)

- Project scope refined to SSLO configuration backup and replay. Removed the ability to install LTM dependencies
- Dependencies removed from snapshot JSON. The .json file is now pure SSLO blocks and metadata
- Dependency manifest exported as a separate human-readable .txt file alongside the snapshot, grouped by type with full configs for reference
- Dead code removed: New-DependencyOnTarget, Apply-SubstitutionMap, Get-DependencyObject, Get-CipherRuleDependencies, DEP_TYPE_ENDPOINTS, DEP_CREATE_ORDER

## b3.3.15.0-devel (Beta 3 - May 31 2026)

- Snapshot format v1.0 specification finalized. Defines the JSON structure as a contract independent of script changes
- snapshotVersion field added (string, currently "1.0"). The script rejects newer formats it cannot parse
- Fixed duplicate component blocks during full replay. Embedded dependent objects in replayable topology blocks collided with standalone blocks deployed earlier. Topology blocks now always go through CREATE conversion
- Metadata restructured: source device info moved to source sub-object, toolVersion replaces version, repository replaces url
- Full dependency config capture: datagroups with all records, custom URL categories, monitors, profiles, iRules, cipher groups, log publishers, and all other portable types
- Cert/key/CA bundle references captured by name only. Content is never stored in a snapshot
- Dependency configs cleaned at capture: REST metadata, app service bindings, and *Reference link objects stripped
- Dependencies sorted by type group (PKI, network, monitors, profiles, crypto, data, categories), then alphabetically
- Dedup key changed from path to type:path. Certs and keys with the same name no longer collide
- Version-lock removed. Snapshots are rejected only for snapshot format incompatibility, not tool version mismatch

## SSLO Replay Snapshot Format v1.0

```
{
  metadata
    snapshotVersion     "1.0"
    tool                "sslo-replay"
    toolVersion         "0.3.15-devel"
    repository          github URL
    source
      hostname          source device hostname
      tmosVersion       TMOS version
      ssloVersion       SSLO RPM version
    timestamp           ISO 8601
    blockCount          number of blocks

  blocks[]
    deploymentType      SERVICE | SERVICE_CHAIN | SECURITY_POLICY | SSL_SETTINGS | TOPOLOGY
    deploymentName      object name (ssloS_, ssloSC_, ssloP_, ssloT_, sslo_)
    backupType          "replayable" | "state"
    block               cleaned iAppsLX block (inputProperties only, runtime fields stripped)

}
```

### Block fields stripped at capture

id, existingBlockId, selfLink, generation, lastUpdateMicros, restrictedId, restrictedHash, obRestrictedAttribute, state, dataProperties, audit

### File naming

sslo-snapshot_{hostname}_{yyyyMMdd-HHmmss}.json

sslo-dependencies_{hostname}_{yyyyMMdd-HHmmss}.txt

## b2.3.15.0-devel (Beta 2 - May 29 2026)

- New feature: Redeploy SSLO Topology. Pushes a selected topology back through the gc processor as a MODIFY to force a fresh deployment pass. Resolves "not initialized" warnings after replay. Does not clear GUI-level pending drafts
- Security policy prereq validation for datagroups (existence and type match) and custom URL categories
- Built-in F5 URL category filter, 168 entries based on Ansible condition_category_list. Built-ins skipped in capture and validation
- Policy swap pre-flight plan shows all actions before touching the target
- MODIFY operation blocks excluded from replayable category. Fixes duplicate policy on replay after policy swap
- mcpBlockIO block database save added alongside tmsh save, an undocumented feature pulled from F5's sslofix script

## b1.3.15.0-devel (Beta 1 - May 28 2026)

- Initial beta release. Snapshot and replay of SSLO iAppsLX configuration across BIG-IP devices
- Captures all SSLO deployment types: SSL settings, services, service chains, security policies, topologies
- State-to-CREATE transformation with per-type inputProperties from F5 Ansible collection f5networks.f5_bigip 3.15.0-devel
- Scoped replay: select a single topology and the tool resolves its full dependency tree
- Policy swap: apply a snapshot policy to an existing topology with rename and overwrite support
- Prerequisite validation for all service types (L3, HTTP, ICAP, Layer 2, TAP)
- Version-locked snapshots: replayable only by the script version that created them, due to the Ansible module mapping dependency
- MODIFY operation blocks excluded from capture. Only CREATE blocks are replayable
