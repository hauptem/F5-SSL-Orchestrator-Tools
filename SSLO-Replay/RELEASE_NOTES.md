## b10.3.15.0-devel (Beta 10 - September 29 2026)

- **The API reference moved from F5 Ansible collection f5networks.f5_bigip 3.14.0 to 3.15.0 (released September 29 2026)**. 3.15.0 extends SSLO support from 12.0 to versions below 15.0 and documents the SSLO 13 and 14 schema fields; 3.14.0 capped at 12.0. Operation block templates, per-type inputProperty sets, and pfId token format are unchanged between the two collections, so snapshots recorded by earlier betas remain valid
- IP reputation conditions no longer block replay. Client/Server IP Reputation conditions store reputation categories (Spam Sources, BotNets, Tor Proxy) in options.category; they were captured and validated as custom URL categories and reported missing on every target
- Layer 2 service VLANs are captured and validated from customService.connectionInformation.interfaces[], the path the collection reads in 3.14.0 and 3.15.0. The previous serviceSpecific.devices[] path does not exist, so Layer 2 VLANs were never checked
- Service SNAT pools are read from customService.snatConfiguration. The previous top-level path does not exist, so service SNAT pools were never checked
- Datagroups referenced by match-pattern conditions (server certificate subject DN, issuer DN, SANs, TLS ClientHello server name, URL branching) and entries in Client VLAN conditions are captured and validated. Client VLAN entries are resolved as VLAN or datagroup on each device
- New service references captured and validated: egress iRules (iRuleListEgress, SSLO 13+), default persistence profile (SSLO 14+), service entry and return SSL profiles, off-box AWAF HTTP profile, and on-box WAF iRules, security policy, DoS, bot defense, and security log profiles
- New topology references captured and validated: log publisher, DNS resolver, and the inbound application-mode pool. SSL settings OCSP and CRL validators are captured and validated
- Built-in URL category list extended from 168 to 221 entries: the Ansible condition_category_list plus the TMOS 17.5 and 21.1 URL databases. TMOS 21.1 no longer has five 17.5 categories (Illegal or Questionable, Gay or Lesbian or Bisexual Interest, Non-Traditional Religions, Traditional Religions, Society and Lifestyles) and adds 53, including Generative AI, DNS Over HTTPS, and LGBTQIA. 
- Replay checks every URL category a policy uses, built-in or custom, against the target's URL database. A built-in category that does not exist on the target TMOS version (a 17.5 snapshot replayed to 21.1) is reported as missing instead of failing at deploy. When the URL database cannot be read, built-ins are assumed present and custom categories are checked individually
- Record prefers the component (state) block over a CREATE operation block when both exist for an object. A record taken within the operation block's BOUND window previously captured the transient request instead of the deployed configuration
- Supported replay direction documented: same or newer SSLO version. Verified 17.5 (SSLO 12.4.2) to 21.1 (SSLO 14.1.5) full replay
- Record and replay prerequisite validation share one reference walker. The two copies had drifted, which is how the Layer 2 and SNAT paths stayed wrong in both
- Replayable SSL settings blocks go through CREATE conversion like state blocks. A CREATE operation block captured inside its 120-second BOUND window previously replayed with the source pfId tokens and no passphrase prompt
- Record lists SSLO objects whose component block is not UNBOUND (ERROR, stuck BINDING/UNBINDING) and requires confirmation before writing a snapshot without them. They were previously dropped silently
- Record refuses blocks nested too deep for ConvertTo-Json, and snapshot verification compares each block's nesting depth after the round trip. PS 5.1 truncation replaces deep objects with strings, which the previous count check could not detect
- Redeploy stuck-block cleanup touches only operation blocks for the selected topology, matched by the operation context's deploymentName. The topology's own component block is never deleted; if it left UNBOUND since selection, redeploy aborts with no changes
- Dynamic naming substitutes names at identifier boundaries. Renaming sslo_web no longer rewrites a chain named ssloSC_sslo_web_bypass or a topology named sslo_web2. Each renamed block is verified: no other SSLO object reference and no external /Common/ dependency may change, and the new base name must not collide with existing content
- Monitor capture probes gateway-icmp, icmp, udp, tcp-half-open, and external monitors in addition to tcp, http, and https. Gateway ICMP monitors are recorded as monitor_gateway_icmp; monitor_icmp now means /ltm/monitor/icmp
- Custom access profiles referenced by a topology are validated during replay prerequisites. The user guide already listed them; the check was missing

## b9.3.14.0-devel (Beta 9 - September 2 2026)

- Dependency config cleaning is now recursive. The *Reference link strip and instance-field strip previously applied at the top level only, so nested collection members (cipher group allow[], log publisher destinations[]) kept nameReference links carrying the source TMOS version in the query string
- Script header corrected to describe the current design: dependency configs go to the companion text manifest, which the tool does not read, and replay re-derives dependencies from the snapshot blocks.

## b8.3.14.0-devel (Beta 8 - August 2026)

- Corrected all F5 Ansible references to 3.14.0

## b7.3.14.0-devel (Beta 7 - July 19 2026)

- Poll timeout no longer reports a deployment as failed without checking for it. The gc processor does not stop when the poll gives up, and a completed operation block self-destructs 120 seconds after BOUND - so re-checking the operation block later is ambiguous (absent means succeeded-and-gone or never-bound). On timeout the tool now checks for the deployment's component block, the durable evidence that the deployment landed. Applies to CREATE operations only; a component block that predates a MODIFY or DELETE proves nothing. Late-verified objects count as replayed and reset the circuit breaker, so slow deployments can no longer trip the systemic-failure prompt
- Timed-out objects that cannot be verified now report that the gc processor may still complete, and that a re-replay will safely skip anything that lands
- Policy swap validates the target policy name with the same rule as replay-time renaming: 1-20 characters after ssloP_, letters, numbers, underscores. An unvalidated name previously flowed into OData filter queries, operation block names, and gc processor config data

## b6.3.14.0-devel (Beta 6 - July 17 2026)

- Snapshot block field backupType renamed to captureType. **SSLO Snapshots recorded by Beta 5 and earlier will fail import validation using Beta 6 - re-record your SSLO's using Beta 6**. The updated snapshot format version remains at 1.0 since we are still in beta.
- Windows PowerShell 5.1 is enforced at startup. PowerShell 7+ ignores the ServicePointManager certificate bypass, so every connection would fail with opaque TLS errors. The tool now exits with the correct powershell.exe invocation instead
- Config save connection-drop detection uses locale-invariant WebException status enums instead of matching the exception message, which .NET localizes per Windows display language. On a drop signature the tool confirms the management plane is reachable and re-issues the idempotent save before reporting success
- Topology detection excludes operation blocks by their exact prefixes (sslo_ob_, sslo_obj_) instead of the bare sslo_ob stem. The stem match also swallowed legitimate topology names like sslo_observability, silently dropping them from snapshots, redeploy, and delete accounting
- Replay circuit breaker consolidated into a single function. 
- Terminology aligned across functions, prompts, and output: record/snapshot/replay replaces dump/backup/restore

## SSLO Replay Snapshot Format v1.0 (updated in beta 10)

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
    captureType         "replayable" | "state"
    block               cleaned iAppsLX block (inputProperties only, runtime fields stripped)

}
```

### Block fields stripped at capture

Top level: id, selfLink, generation, lastUpdateMicros, kind, state, restrictedId, restrictedHash, restrictedProperties, dataProperties, audit

inputProperties values: existingBlockId, deploymentReference, obRestrictedAttribute

### File naming

sslo-snapshot_{hostname}_{yyyyMMdd-HHmmss}.json

sslo-dependencies_{hostname}_{yyyyMMdd-HHmmss}.txt

## b5.3.14.0-devel (Beta 5 - June 12 2026)

- Replay aborts when the target inventory cannot be read. A failed read previously disabled collision detection and the full snapshot would deploy onto a populated device
- Key passphrase prompt for SSL settings replay. Passphrases are not recoverable from state blocks and were restored blank. 
- Existing objects in ERROR or stuck state are flagged in the replay plan with a warning to remove them before re-replay
- Policy swap failures list the changes completed before the failure, including policy content already live on the target
- Replay halts for confirmation after 3 consecutive object failures
- Objects posted without a returned block ID are reported as unverified. "Replay complete" requires zero failed and zero unverified
- ERROR-state failures include the block error detail in the output
- Stuck-block cleanup during redeploy uses anchored name matching. The previous substring match could clear blocks of a topology whose name contains the selected one
- Snapshots are verified after writing: round-trip parse and block count check. Import warns when metadata blockCount does not match contents
- Dynamic naming on scoped topology replay. The detected base name can be replaced at replay time. Renaming applies to the topology, its SSL settings, and its security policy. New base names can contain 1-20 characters, letters, numbers, underscores. 

## b4.3.14.0-devel (Beta 4 - June 1 2026)

- Project scope refined to SSLO configuration backup and replay. Removed the ability to install LTM dependencies
- Dependencies removed from snapshot JSON. The .json file is now pure SSLO blocks and metadata
- Dependency manifest exported as a separate human-readable .txt file alongside the snapshot, grouped by type with full configs for reference
- Dead code removed: New-DependencyOnTarget, Apply-SubstitutionMap, Get-DependencyObject, Get-CipherRuleDependencies, DEP_TYPE_ENDPOINTS, DEP_CREATE_ORDER

## b3.3.14.0-devel (Beta 3 - May 31 2026)

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

## b2.3.14.0-devel (Beta 2 - May 29 2026)

- New feature: Redeploy SSLO Topology. Pushes a selected topology back through the gc processor as a MODIFY to force a fresh deployment pass. Resolves "not initialized" warnings after replay. Does not clear GUI-level pending drafts
- Security policy prereq validation for datagroups (existence and type match) and custom URL categories
- Built-in F5 URL category filter, 168 entries based on Ansible condition_category_list. Built-ins skipped in capture and validation
- Policy swap pre-flight plan shows all actions before touching the target
- MODIFY operation blocks excluded from replayable category. Fixes duplicate policy on replay after policy swap
- mcpBlockIO block database save added alongside tmsh save, an undocumented feature pulled from F5's sslofix script

## b1.3.14.0-devel (Beta 1 - May 28 2026)

- Initial beta release. Snapshot and replay of SSLO iAppsLX configuration across BIG-IP devices
- Captures all SSLO deployment types: SSL settings, services, service chains, security policies, topologies
- State-to-CREATE transformation with per-type inputProperties from F5 Ansible collection f5networks.f5_bigip 3.14.0-devel
- Scoped replay: select a single topology and the tool resolves its full dependency tree
- Policy swap: apply a snapshot policy to an existing topology with rename and overwrite support
- Prerequisite validation for all service types (L3, HTTP, ICAP, Layer 2, TAP)
- Version-locked snapshots: replayable only by the script version that created them, due to the Ansible module mapping dependency
- MODIFY operation blocks excluded from capture. Only CREATE blocks are replayable
