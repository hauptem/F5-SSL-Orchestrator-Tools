# SSLO-Replay User Guide

## Running the Tool

```powershell
.\sslo-replay.ps1
```

PowerShell 5.1 or later. No modules or dependencies required.

On launch you get a connection prompt. Enter the BIG-IP management IP and credentials. The tool validates connectivity, checks TMOS and SSLO versions, and drops you into the main menu. The connection uses iControl REST over HTTPS on port 443.

## Main Menu

```
1) Record SSLO Snapshot
2) Replay SSLO Snapshot
3) Redeploy SSLO Topology
4) Connect to a different BIG-IP
0) Exit
```

Option 1 records from the connected device. Option 2 reads a snapshot file and presents a sub-menu with three modes: full replay, single topology replay, or policy swap. Option 3 operates on the connected device without a snapshot file. Option 4 switches targets without restarting.

---

## Recording a Snapshot

Menu option 1. Pulls all iAppsLX blocks from the connected device, classifies them, captures dependencies, and writes a JSON file.

The tool captures every SSLO object on the device: SSL settings, services, service chains, security policies, and topologies. It also captures all external dependencies those objects reference such as datagroups with their records, custom URL categories, monitors, profiles, cipher groups, iRules, and cert/key names.

General Settings (`ssloGS_global`) are captured for reference but excluded from replay. They are environment-specific and must be configured on each device through the SSLO GUI.

The output file is saved to the current directory:

```
sslo-snapshot_{hostname}_{yyyyMMdd-HHmmss}.json
```

After capture, the tool displays a summary: block count, dependency count, and a grouped list of all external dependencies by type.

### What the snapshot contains

The snapshot has three sections. `metadata` identifies the source device and tool version. `blocks` contains the SSLO configuration — one entry per object with only the inputProperties that the gc processor needs. `dependencies` contains every external object referenced by those blocks, with full configuration where applicable.

Certs and keys are listed by name only. Their content is never captured.

See the release notes for the full snapshot format specification.

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

1. **SSLO installed and General Settings configured** — run through the SSLO guided config at least once
2. **Certificates and keys installed** — match the names in the snapshot (check the dependencies section)
3. **VLANs created** — the ingress and service-side VLANs referenced by topologies and services
4. **Network infrastructure** — self IPs, routes, anything the services need to reach inspection devices

The tool validates all of this before touching the blocks API. If something is missing, it tells you what and where it is referenced.

### Portable dependencies

Datagroups, custom URL categories, monitors, profiles, cipher groups, and iRules are portable. If any are missing on the target, the tool offers to create them automatically from the stored config. However this only works if the snapshot was taken with full dependency capture (snapshot format v1.0 or later).

### Replay modes

**Full replay** deploys every object in the snapshot in dependency order.

**Scoped replay** lets you pick a single topology. The tool resolves the dependency tree: the topology's SSL settings, security policy, service chains, and services, and replays only those objects. 

### What happens during replay

1. Snapshot file selection (lists all `sslo-snapshot_*.json` files in current directory)
2. Snapshot validation and summary display
3. Target compatibility check (hostname, TMOS version, SSLO version — warns on mismatch, does not block)
4. Scope selection (full or single topology)
5. Prerequisite validation walks every block and checks all external references on the target
6. Pre-replay analysis checks which objects already exist on the target and skips them, displays a plan of what will be deployed
7. Confirmation prompt
8. Block deployment each block is POSTed to `/mgmt/shared/iapp/blocks` as a CREATE operation with fresh passphrase tokens. The tool waits for each block to reach BOUND state before proceeding to the next
9. Configuration save; tmsh save and mcpBlockIO block database save

Deployment order: SSL settings → services → service chains → security policies → topologies. Each object waits up to 90 seconds for the gc processor to complete.

### After replay

After replay, the SSLO GUI may display a warning about a pending deployment or initilization; click the pulsing red icon in the top right of the SSLO main page GUI "resume upgrade" to reload the SSLO configuration and then wait 15 seconds and refresh the GUI. The message should clear.

<img width="408" height="168" alt="Image" src="https://github.com/user-attachments/assets/92446ab9-4cd2-4236-9146-ad2b027450d9" />

---

## Swapping a Security Policy

Sub-option 3 under Replay. Takes a security policy from the loaded snapshot and applies it to an existing topology on the connected device.

Use this when you want to push a policy from one environment to another without rebuilding the topology. The topology keeps its SSL settings, services, and network config. Only the policy and its service chains change.

### How it works

1. Select a source policy from the snapshot
2. Select a target topology on the connected device
3. The tool shows a pre-flight plan: what will be created, what will be renamed, what will be overwritten
4. Confirm to proceed

The tool creates any missing service chains referenced by the policy, renames the policy to match the target topology's naming convention, and pushes a MODIFY to the topology to bind the new policy.

Services and SSL settings must already exist on the target. The tool will not create them during a policy swap — if a service chain references a service that does not exist, the swap is blocked.

---

## Redeploying a Topology (experimental)

Menu option 3. Reads the current state of a topology from the connected device and pushes it back through the gc processor as a MODIFY operation.

Use this to:
- Clear "not initialized" warnings after a replay
- Force the gc processor to regenerate all APM policies, iRules, and profiles for a topology
- Recover from a partial deployment failure

The redeploy reads the existing block state, constructs a MODIFY operation block with the current inputProperties, and POSTs it. The gc processor runs a full deployment pass. No snapshot file is needed — this operates entirely on the live device.

Before the MODIFY, the tool scans for any blocks in a stuck state (BINDING, UNBINDING, ERROR) that match the topology name. Stuck blocks are transitioned to ERROR and then deleted to clear the way for the fresh deployment.

---

## Preparing a Target Device

This is the checklist for standing up a new device to receive a replay.

### Step 1: Network infrastructure

Create VLANs and self IPs for the inspection zone. If services use L3 inline inspection, create the to-service and from-service VLANs and assign self IPs. Create the ingress VLAN where client traffic enters.

The snapshot's dependency section lists every VLAN referenced by services and topologies.

### Step 2: Certificates and keys

Install the SSL intercept CA certificate and key. Match the names exactly — the snapshot references them by path (e.g., `/Common/my-intercept-ca`). If the names differ on the target, the prereq check will flag them.

The CA bundle (`/Common/ca-bundle.crt`) ships with TMOS. No action needed unless you use a custom bundle.

### Step 3: SSLO General Settings

Open the SSLO guided configuration and complete the General Settings wizard. This creates the base SSLO infrastructure: the default access profile, iAppsLX block framework, log publishers, and resolver config. Replay cannot proceed without it.

### Step 4: Replay

Run the tool, connect to the target, select option 2, pick the snapshot file. 

---

## Troubleshooting

### Replay fails with "block did not reach BOUND state"

The gc processor timed out. Check `/var/log/restnoded/restnoded.log` on the BIG-IP for the specific error. Common causes: missing VLAN, missing cert, service IP unreachable, APM provisioning issue.

### Prerequisite check reports missing objects

The tool lists every missing object with its type and which SSLO object references it. Create the missing objects and retry. For portable dependencies (datagroups, URL categories, monitors), the tool offers auto-creation if the snapshot has stored configs.

### Policy swap blocked on missing service

The policy references a service chain that references a service not present on the target. Services are not auto-created during policy swap because they require network infrastructure (VLANs, self IPs, pool members) that the tool cannot verify. Deploy the service first through a full replay or the SSLO GUI, then retry the policy swap.
