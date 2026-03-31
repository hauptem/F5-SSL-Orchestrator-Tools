# DGCat-Admin v4.5 Release Notes - March 31 2026

**Search**
- Query and compare datagroups or URL categories across fleet hosts from a single session.
- **Pull** — Retrieve entries from all fleet hosts, a specific site, or individual hosts
- **Search** — Find entries by pattern across the fleet; results are deduplicated 
- **Diff** — Identify configuration drift; entries missing from one or more hosts are flagged with per-host detail

# DGCat-Admin v4.3 Release Notes - March 30 2026

**Large Dataset Support**
- Tested with 20000-entry URL categories and 1000-entry address datagroups
- Bash appears to have a limit of 6000-7000 URL records before the editor gets really slow due to the arrays - added a warning and confirmation to continue when records are pulled
- Powershell is fast even with 20k records in the editor - though needs a longer API_TIMEOUT set in the configuration but this will vary by environment
- set API timeout to 60s default to accomodate large dataset publishing out of box
- URL category creation split into create-then-populate sequence to avoid ghost objects
- Fixed bash argument overflow on large list imports

**UI**  
- Fixed a few more minor color discrepancies between powershell and bash UI

**Import Validation**
- CIDR alignment check prevents HTTP 400 response if trying to install entries with misaligned subnets via API
- CSV duplicates removed via dedup function before applying with reported count corrected

**Performance**
- Bash CSV parsing and URL conversion rewritten with shell builtins (large dataset processing is now ~2s vs 10-20s)
- Editor apply path optimized from O(n²) to O(n)

**Cleanup**
- Removed some dead code


# DGCat-Admin v4.2 Release Notes - March 29 2026

**Deployment**
- Implemented consistent three-step visibility for every host: Creating backup, Applying changes, Saving configuration
- Current device and fleet hosts display their statuses identically during deployment
- Backup file paths are no longer shown in deploy output (but still written to log)
- Backups moved from pre-deploy validation to deploy execution stage since deployments can be cancelled by the user following pre-deployment failures
- Suppressed data preparation progress lines (Building records, Building URL list)
- If all hosts pass a pre-deploy validation then proceed directly to deployment without a second confirmation prompt
- If some hosts fail pre-deploy validation  then prompt operator before continuing with a partial deployment
- SKIP entries no longer echo the pre-check reason in the deployment summary since it was shown in the pre-deploy summary

**Backups**
- Connected host backups now include hostname in filename, matching fleet backup naming convention

# DGCat-Admin v4.1 Release Notes - March 28 2026

**New Features**
- Create an Empty Datagroup or URL Category menu option
- Logging toggle variable to disable/enable tool logging via configuration

**Deployment**
- Skips current device when no pending changes exist on that device (if a user used the write feature prior to deployment)
- Deployment Step numbering adjusts dynamically
- Pre-check failures now show as SKIP in summary; FAIL status is reserved for actual deploy failures
- Connected host backups are saved within a site subfolder when the host is in a fleet

**UI**
- Menu restructured: View removed, Edit renamed to View/Edit
- Editor commands spaced into visual groups with matched colors across both versions
- Consistent display widths across all section headers and dividers

**Bug Fixes**
- Fixed PowerShell save config failure false positive caused by BIG-IP closing connection after save
- Fixed PowerShell single-result array unwrapping across all pipelines
- Fixed PowerShell duplicate deploy header and carriage return display artifacts

# DGCat-Admin v4.0 Release Notes - March 27 2026

- Initial public release

