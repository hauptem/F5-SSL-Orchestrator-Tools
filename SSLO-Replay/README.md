# SSLO-Replay 0.3.15.0-devel (Beta) - F5 SSLO Configuration Snapshot and Replay Tool

![License](https://img.shields.io/badge/license-MIT-green)
![F5 Compatible](https://img.shields.io/badge/F5%20BIG--IP-compatible-orange)
![TMOS Version](https://img.shields.io/badge/TMOS-17.x%2B-red)
![SSLO Version](https://img.shields.io/badge/SSLO-12.x%2B-blue)

### Note that this is presented as a proof-of-concept still in beta version.
A menu-driven tool used for capturing F5 SSL Orchestrator configuration as a portable JSON STATE snapshot and replaying it to the same or different BIG-IP via the iControl REST API. Designed for disaster recovery, migration, and policy management in environments where Ansible is not available.

Available as a single PowerShell script:

- **PowerShell** (`sslo-replay.ps1`) - For Windows

### The SSLO Backup Problem

F5 does not provide a native mechanism to back up and restore SSL Orchestrator configuration across devices. UCS restore might have issues because iAppsLX block UUIDs are instance-specific. F5's own SSLO snapshots are internal checkpoints that cannot be exported or imported. The SSLO iFile representation carries the same UUID binding and would be useless to export and import. All three mechanisms are tied to the device that created them through the REST stack.

F5 provides a script to delete an SSLO deployment, but no way to easily recreate it outside of ansible orchestration. The only recovery path is manual recreation through the GUI: clicking through every SSL setting, every service, every service chain, every security policy rule, and every topology. For a deployment with 10 topologies and complex security policies, this could be hours of careful manual administrative work - prone to human error.

### What SSLO-Replay Solves

SSLO-Replay captures the logical configuration of an SSLO deployment, strips all instance-specific data, and replays it through the gc processor, the same API engine the SSLO iAppsLX GUI and Ansible use. The gc processor generates fresh UUIDs, builds the TMOS objects, and binds the blocks. The result is indistinguishable from having built it by hand.

The snapshot is a single JSON file containing every SSLO object. External dependencies are exported alongside it as a human-readable manifest. The replay is deterministic, repeatable, and error-free.

### Features

- **Record** - Captures all SSLO objects (SSL settings, services, service chains, security policies, topologies) in a single portable JSON file
- **Full Replay** - Deterministic recreation of an entire SSLO deployment in dependency order
- **Scoped Replay** - Replay a single topology with automatic dependency resolution, with optional renaming of the topology stack at replay time
- **Policy Swap** - Apply a security policy from a snapshot to an existing topology on the target, with rename and overwrite support
- **Redeploy** - Push an existing topology back through the gc processor to force a fresh deployment pass, no snapshot file needed
- **Delete** - Remove a topology and its unreferenced dependents from the live device, with reference counting so shared objects are retained
- **Dependency Capture** - Records external BIG-IP objects (iRules, monitors, cipher groups, profiles, SNAT pools, datagroups, URL categories) as a .txt manifest for reference

### How It Works

SSLO-Replay does not try to restore state. It replays intent.

1. **Record** connects to a BIG-IP, retrieves all iAppsLX blocks, classifies the SSLO objects, strips instance-specific fields (UUIDs, block IDs, restricted hashes), captures external dependencies, and writes a portable JSON snapshot
2. **Replay** reads the snapshot, validates prerequisites on the target, transforms state blocks into gc processor CREATE format with correct per-type inputProperties, and replays objects in dependency order: SSL settings → services → service chains → security policies → topologies
3. The gc processor does what it was designed to do which generates fresh UUIDs, builds app folders, wires profiles, creates access policies, and binds each block

The transformation logic, per-type inputProperty templates, and prerequisite field paths are traced to the F5 Ansible SSLO collection module source code. The tool uses F5's own automation modules as the authoritative reference for the gc processor's input contract.

<img width="771" height="345" alt="Image" src="https://github.com/user-attachments/assets/0b5a82c8-417e-4b8a-b003-25d8d9877ddc" />
<img width="771" height="521" alt="Image" src="https://github.com/user-attachments/assets/c7f555d5-534e-43b8-a0ca-7b85877917c4" />


### Current Limitations

- Replay was not designed to install the LTM prerequisites, those will be present in a UCS restore. Replay was designed for quick SSLO restoration when you need to "nuke" your entire SSLO because of an sgc issue or when you want some SSLO config portability.
- Certs and keys will never be captured during a snapshot in the JSON manifest for obvious security reasons. Install them on the target before replay.
- General Settings (`ssloGS_global`) are environment-specific; configure via the SSLO GUI on the target before replay
- Per-request policy modifications made outside SSLO with strict updates disabled will not survive replay
- Extension services (blocking page, DoH guard) must be installed separately
- SSLO-Replay is slow, because the REST API stack in a Big-IP is slow. It is not possible to get faster performance until F5 updates the internal processing pipeline. The benefit, however, is accuracy and the removal of human error.

## Requirements

- Windows PowerShell 5.1 (Desktop edition). PowerShell 7+ (pwsh) is not supported and the tool will exit at startup if launched under it
- Network access to BIG-IP management interface (port 443)
- BIG-IP running TMOS 17.x or later with SSLO 12.x or later

## Installation

```powershell
# Copy to a directory on your Windows management host
# Run
powershell.exe -File .\sslo-replay.ps1
```

Snapshots and dependency manifests are written to a `sslo-replay-snapshots` folder created next to the script.

## Documentation

- [Release Notes](RELEASE_NOTES.md) - Version history and the snapshot format specification
- [User Guide](USERGUIDE.md) - Full walkthrough of every menu option, target preparation, and troubleshooting

## API Reference

The gc processor input/output contract, per-type inputProperty templates, passphrase token handling, and prerequisite field paths are derived from the F5 Ansible SSLO collection:

- **Collection:** f5networks.f5_bigip 3.15.0-devel
- **Repository:** https://github.com/F5Networks/f5-ansible-bigip

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Disclaimer

- This solution is **NOT** officially endorsed, supported, or maintained by F5 Inc.
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
