# SSLO-Replay User Guide

## Running the Tool

```powershell
powershell.exe -File .\sslo-replay.ps1
```

Windows PowerShell 5.1 (Desktop edition) only. PowerShell 7+ (pwsh) is not supported because it ignores the certificate bypass the tool uses for self-signed BIG-IP management certs. If launched under pwsh the tool exits at startup and prints the correct invocation. No modules or dependencies required.

On launch you get a connection prompt. Enter the BIG-IP management IP and credentials. The tool validates connectivity, checks TMOS and SSLO versions, and drops you into the main menu. The connection uses iControl REST over HTTPS on port 443.

## Main Menu

```
1) Record SSLO Snapshot
2) Replay SSLO Snapshot
3) Redeploy SSLO Topology
4) Delete SSLO Topology
5) Connect to a different BIG-IP
0) Exit
```

Option 1 records from the connected device. Option 2 reads a snapshot file and presents a sub-menu with three modes: full replay, single topology replay, or policy swap. Options 3 and 4 operate on the connected device without a snapshot file. Option 5 switches targets without restarting; credentials are kept.

---

## Recording a Snapshot

Menu option 1. Pulls all iAppsLX blocks from the connected device, classifies them, captures dependencies, and writes a JSON file.

The tool captures every SSLO object on the device: SSL settings, services, service chains, security policies, and topologies. It also captures all external dependencies those objects reference such as datagroups with their records, custom URL categories, monitors, profiles, cipher groups, iRules, and cert/key names.

General Settings (`ssloGS_global`) are not captured. They are environment-specific and must be configured on each device through the SSLO GUI.

Output is written to a `sslo-replay-snapshots` folder next to the script. Two files per capture:

```
sslo-replay-snapshots\sslo-snapshot_{hostname}_{yyyyMMdd-HHmmss}.json
sslo-replay-snapshots\sslo-dependencies_{hostname}_{yyyyMMdd-HHmmss}.txt
```

The `.json` file is the snapshot the tool replays. The `.txt` file is a human-readable dependency manifest: every external object referenced by the snapshot, grouped by type, with full configuration included where applicable for reference when recreating objects on a target. The tool never reads the manifest. It exists for you.

After capture, the snapshot is verified (re-parsed and block-counted) and the tool displays a summary: the captured objects by type and the dependency list.

### What the snapshot contains

The snapshot has two sections. `metadata` identifies the source device and tool version. `blocks` contains the SSLO configuration, one entry per object with only the inputProperties that the gc processor needs.

Certs and keys are listed by name only, in the dependency manifest. Their content is never captured.

See the release notes for the full snapshot format specification.

Note for anyone upgrading from Beta 5 or earlier: the snapshot block field `backupType` was renamed to `captureType` in Beta 6. Snapshots recorded by earlier betas fail import validation ("No valid blocks found in snapshot"). Re-record them with Beta 6.

---

## Replaying a Snapshot

Menu option 2. After loading and validating the snapshot, the tool presents a sub-menu:

```
1) Replay entire snapshot
2) Replay a single topology
3) Apply a security policy to an existing topology
```

### Before you replay

The target device needs:

1. **SSLO installed and General Settings configured** - run through the SSLO guided config at least once
2. **Certificates and keys installed** - match the names in the snapshot (check the dependency manifest `.txt` file)
3. **VLANs created** - the ingress and service-side VLANs referenced by topologies and services
4. **Network infrastructure** - self IPs, routes, anything the services need to reach inspection devices

The tool validates all of this before touching the blocks API. If something is missing, it tells you what and where it is referenced.

### Replay modes

**Full replay** deploys every object in the snapshot in dependency order.

**Scoped replay** lets you pick a single topology. The tool resolves the dependency tree: the topology's SSL settings, security policy, service chains, and services, and replays only those objects.

Scoped replay also offers dynamic renaming. If the topology, its SSL settings, and its security policy share a common base name, the tool detects it and lets you supply a new one at replay time. New base names can be 1-20 characters: letters, numbers, underscores. Renaming applies only to those three objects. Services, service chains, and `/Common/` dependencies keep their names. Press Enter at the prompt to keep the original name.

### What happens during replay

1. Snapshot file selection (lists all `sslo-snapshot_*.json` files in the `sslo-replay-snapshots` folder; a full path can also be entered)
2. Snapshot validation and summary display
3. Target compatibility check (hostname, TMOS version, SSLO version)
4. Scope selection (full or single topology), with optional rename for scoped replay
5. Prerequisite validation walks every block and checks all external references on the target
6. Pre-replay analysis checks which objects already exist on the target and skips them, displays a plan of what will be deployed. Existing objects in a failed or stuck state are flagged. Remove them on the target before re-replaying those objects
7. Confirmation prompt. Type `REPLAY` to proceed; anything else cancels
8. Block deployment. Each block is POSTed to `/mgmt/shared/iapp/blocks` as a CREATE operation. The tool waits for each block to reach BOUND state before proceeding to the next. If SSL settings reference private keys, you are prompted for each key's passphrase (press Enter if the key has none); each key is asked once per replay run
9. Configuration save; tmsh save and mcpBlockIO block database save

Deployment order: SSL settings, then services, service chains, security policies, and topologies last. Each object waits up to 120 seconds for the gc processor to complete; topologies get 180 seconds.

If 3 objects fail in a row, the replay halts and asks whether to continue with the remaining objects. Objects that post without a returned block ID are reported as unverified, so confirm their state in the SSLO GUI. "Replay complete" is only reported with zero failed and zero unverified objects.

### After replay

After replay, the SSLO GUI may display a warning about a pending deployment or initialization; click the pulsing red icon in the top right of the SSLO main page GUI "resume upgrade" to reload the SSLO configuration and then wait 15 seconds and refresh the GUI. The message should clear.

<img width="408" height="168" alt="Image" src="https://github.com/user-attachments/assets/92446ab9-4cd2-4236-9146-ad2b027450d9" />

---

## Swapping a Security Policy

Sub-option 3 under Replay. Takes a security policy from the loaded snapshot and applies it to an existing topology on the connected device.

Use this when you want to push a policy from one environment to another without rebuilding the topology. The topology keeps its SSL settings, services, and network config. Only the policy and its service chains change.

### How it works

1. Select a source policy from the snapshot
2. Select a target topology on the connected device
3. Name the policy on the target (defaults to the target topology's naming convention)
4. The tool shows a pre-flight plan: what will be created, what will be overwritten, what already exists
5. Confirm to proceed

The tool creates any missing service chains referenced by the policy, renames the policy to the name you chose, and pushes a MODIFY to the topology to bind the new policy. If the target policy name already exists, it is overwritten with the snapshot's content. The plan warns you before anything runs.

If the operation fails partway, the tool lists exactly which changes completed before the failure, including any policy content already live on the target.

Services and SSL settings must already exist on the target. The tool will not create them during a policy swap. If a service chain references a service that does not exist, the swap is blocked.

---

## Redeploying a Topology (experimental)

Menu option 3. Reads the current state of a topology from the connected device and pushes it back through the gc processor as a MODIFY operation.

Use this to:
- Clear "not initialized" warnings after a replay
- Force the gc processor to regenerate all APM policies, iRules, and profiles for a topology
- Recover from a partial deployment failure

The redeploy reads the existing block state, constructs a MODIFY operation block with the current inputProperties, and POSTs it. The gc processor runs a full deployment pass. No snapshot file is needed. This operates entirely on the live device.

Before the MODIFY, the tool scans for any blocks in a stuck state (BINDING, UNBINDING, ERROR) belonging to the selected topology. Stuck blocks are transitioned to ERROR and then deleted to clear the way for the fresh deployment. Matching is exact, so blocks of a sibling topology whose name merely contains the selected one are never touched.

---

## Deleting a Topology

Menu option 4. Deletes a topology and its now-unreferenced dependents from the connected device, through the gc processor. No snapshot file is needed.

The tool reads the live SSLO configuration, resolves the selected topology's stack (its SSL settings, security policy, the policy's service chains, and the chains' services) and reference-counts every object against the surviving configuration. Objects still referenced by another topology, policy, or chain are retained. Only objects that would be orphaned by the delete are removed.

### How it works

1. Select a topology from the live device
2. The tool shows a delete plan: every object marked DELETE, and every shared object marked RETAIN with the names of the objects that still reference it
3. Type `DELETE` to proceed; anything else cancels

Deletion runs in reverse deployment order: topology first, then security policy, service chains, services, and SSL settings. Each delete is verified. The tool confirms the block is actually gone before moving to the next object. On the first failure the operation stops immediately and lists what was already deleted; nothing further is touched.

After a successful delete you are offered a configuration save (tmsh save and mcpBlockIO block database save).

External objects such as VLANs, certs, datagroups, and monitors are never deleted. Only SSLO iAppsLX objects are in scope.

---

## Preparing a Target Device

This is the checklist for standing up a new device to receive a replay.

### Step 1: Network infrastructure

Create VLANs and self IPs for the inspection zone. If services use L3 inline inspection, create the to-service and from-service VLANs and assign self IPs. Create the ingress VLAN where client traffic enters.

The dependency manifest (`sslo-dependencies_*.txt`) lists every VLAN referenced by services and topologies, with tags and interfaces for reference.

### Step 2: Certificates and keys

Install the SSL intercept CA certificate and key. Match the names exactly. The snapshot references them by path (e.g., `/Common/my-intercept-ca`), and if the names differ on the target the prereq check will flag them.

The CA bundle (`/Common/ca-bundle.crt`) ships with TMOS. No action needed unless you use a custom bundle.

### Step 3: SSLO General Settings

Open the SSLO guided configuration and complete the General Settings wizard. This creates the base SSLO infrastructure: the default access profile, iAppsLX block framework, log publishers, and resolver config. Replay cannot proceed without it.

### Step 4: Replay

Run the tool, connect to the target, select option 2, pick the snapshot file.

---

## Troubleshooting

### Replay fails with "block did not reach BOUND state"

The gc processor timed out. Check `/var/log/restnoded/restnoded.log` on the BIG-IP for the specific error. Common causes: missing VLAN, missing cert, service IP unreachable, APM provisioning issue.

### Replay fails with "ERROR state"

The gc processor rejected the deployment. The tool prints the block's error detail with the failure. Check `/var/log/restnoded/restnoded.log` for the full context.

### Import fails with "No valid blocks found in snapshot"

The snapshot was most likely recorded by Beta 5 or earlier. The block field `backupType` was renamed to `captureType` in Beta 6 and old snapshots fail validation. Re-record the snapshot with Beta 6.

### Prerequisite check reports missing objects

The tool lists every missing object with its type and which SSLO object references it. Create the missing objects and retry. The dependency manifest contains their full source configurations for reference.

### Policy swap blocked on missing service

The policy references a service chain that references a service not present on the target. Services are not auto-created during policy swap because they require network infrastructure (VLANs, self IPs, pool members) that the tool cannot verify. Deploy the service first through a full replay or the SSLO GUI, then retry the policy swap.
