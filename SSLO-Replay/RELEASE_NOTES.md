# Release Notes

# vb5.3.15.0-devel (Beta 5 - June 12 2026)

- Replay aborts if the target inventory cannot be retrieved - a failed read previously disabled existing-object detection silently, allowing a full snapshot to deploy onto an already-populated device
- Key passphrase prompt added to SSL settings replay - passphrases are not recoverable from state blocks and were previously restored blank; prompts once per unique key and asks neutrally, since a pfId is present whether or not the key has a passphrase
- Gateway pool prerequisite check fixed - it read egressNetwork.gatewayPool, which does not exist (correct field is outboundGateways.referredObj per the F5 Ansible module source), so gateway pools were never validated before replay
- Existing objects in ERROR or stuck state are now flagged in the replay plan with a warning to remove them before re-replaying; previously shown as a plain "exists" and silently skipped on every retry
- Policy swap failures now list the changes completed before the failure, including policy content already live on the target
- Replay halts for confirmation after 3 consecutive object failures instead of grinding through the remainder
- Objects posted without a returned block ID are reported as unverified instead of replayed; "Replay complete" requires zero failed and zero unverified
- ERROR-state failures now include the block's error detail in the output
- Stuck-block cleanup during redeploy uses anchored name matching - the previous substring match could clear blocks belonging to a topology whose name contains the selected one
- Snapshots are verified after writing (round-trip parse and block count check); import warns when metadata blockCount does not match file contents
- Typed replay confirmation changed from CONFIRM to REPLAY and is now case-sensitive
- #Requires -Version 5.1 directive was inert due to a stray space and is now enforced
- Comment normalization pass

## vb4.3.15.0-devel (Beta 4 - June 1 2026)

- Refined scope of the project back to just SSLO configuration backup and replay. Removed the ability to install LTM dependencies
- Dependencies removed from snapshot JSON; the `.json` file is now pure SSLO blocks and metadata
- Dependency manifest exported as a separate human-readable `.txt` file alongside the snapshot, grouped by type with full configs for reference
- Dead code removed: `New-DependencyOnTarget`, `Apply-SubstitutionMap`, `Get-DependencyObject`, `Get-CipherRuleDependencies`, `DEP_TYPE_ENDPOINTS`, `DEP_CREATE_ORDER`

## vb3.3.15.0-devel (Beta 3 - May 31 2026)

- Replay Snapshot format v1.0 specification finalized defines the JSON structure as a contract independent of sslo-replay script changes
- `snapshotVersion` field (string, currently `"1.0"`) format changes tracked independently, the script rejects newer formats it cannot parse
- Fixed: replayable topology blocks caused duplicate component blocks (policies, service chains, SSL settings) during full replay — the embedded dependent objects in the operation block collided with standalone blocks deployed earlier in the sequence. Topology blocks now always go through CREATE conversion regardless of backupType which will prevent duplicate object creation during replay
- Metadata restructured: source device info moved to `source` sub-object, `toolVersion` replaces `version`, `repository` replaces `url`, `dependencyCount` added
- Full dependency config capture datagroups with all records, custom URL categories, monitors, profiles, iRules, cipher groups, log publishers, and all other portable types now stored with complete configuration from source device
- Cert/key/CA bundle name-only references added to dependency manifest. Paths are captured for the prereq checklist, cert/key content is never stored in a snapshot
- Dependency configs cleaned at capture time REST metadata, app service bindings, and `*Reference` link objects stripped
- Dependencies sorted by type group (PKI → network → monitors → profiles → crypto → data → categories), then alphabetically within each group
- Dedup key changed from path-only to type:path composite which prevents certs and keys for the same name from colliding
- Version-lock removed snapshots are no longer rejected for tool version mismatch, only for snapshot format version incompatibility

 # SSLO Replay Snapshot Format v1.0

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
    dependencyCount     number of dependencies

  blocks[]
    deploymentType      SERVICE | SERVICE_CHAIN | SECURITY_POLICY | SSL_SETTINGS | TOPOLOGY
    deploymentName      object name (ssloS_, ssloSC_, ssloP_, ssloT_, sslo_)
    backupType          "replayable" | "state"
    block               cleaned iAppsLX block (inputProperties only, runtime fields stripped)

}
```

## Block fields stripped at capture

`id`, `existingBlockId`, `selfLink`, `generation`, `lastUpdateMicros`, `restrictedId`, `restrictedHash`, `obRestrictedAttribute`, `state`, `dataProperties`, `audit`

## File naming

`sslo-snapshot_{hostname}_{yyyyMMdd-HHmmss}.json`

`sslo-dependencies_{hostname}_{yyyyMMdd-HHmmss}.txt`

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
