# DGCat-Admin v5.5 Release Notes 

- Search drift detection now also compares datagroup values, not just keys. Entries present on every host but holding different values are flagged as a value mismatch, with per-host values shown in both Diff and Search results; previously the same key with different data on two hosts reported as consistent. Each entry is classified once after the fleet pull, so Diff and Search always agree. Search patterns still match keys only. URL categories are unaffected - they have no values. 
- PowerShell: section headers now reach the session log. Write-LogSection wrote its banner to the console only, so LOGGING_ENABLED audit logs were a flat stream of status lines with no record of which operation produced them. 

# DGCat-Admin v5.4 Release Notes 

- Bootstrap no longer discards per-host save results. Objects created but not saved to disk now count as a host failure with a warning to save manually
- Fleet backups now rotate under MAX_BACKUPS like connected-host backups. Fleet datagroup backup filenames gain the internal class segment so both paths share one rotation pool per host and object; fleet backups from earlier versions use the old name shape and are not managed - remove manually if desired
- PowerShell: config save verification is locale-independent and no longer takes the BIG-IP close-after-save quirk on faith. A connection drop is confirmed with a reachability check and an idempotent save retry, so a genuine network failure during save is reported as a failure; the previous detection matched localized .NET exception text and never fired on non-English Windows. The bash version never had this defect - curl accepts a post-response connection close
- PowerShell: requires Windows PowerShell 5.1. ... PowerShell 7 ignores the certificate policy used for self-signed management certs; the script now exits immediately with the correct invocation instead of failing later with TLS errors
- PowerShell: fleet deploy scriptblocks are bound as closures at creation. They previously resolved editor variables through the dynamic call stack at invocation, which worked only because Invoke-FleetDeploy's parameter names carried the same values - a latent break on any parameter rename
- PowerShell: search viewer no longer assigns to the $input automatic variable
- PowerShell housekeeping: Wait-EnterKey replaces Press-EnterToContinue, unused DgType parameter removed from Deploy-DatagroupToHost, bare catch blocks normalized
- The bash version number now tracks the suite for consistency and receives targeted bugfixes only (first two fixes above)

# DGCat-Admin v5.3 Release Notes 

- tmsh Modify and fleet merge deploys now reject keys/values containing whitespace, braces, quotes, backslash, ';', or '#' since these are embedded unquoted in the tmsh options string and can corrupt the parse or delete unintended records; Full Replace is unaffected
- Value changes to existing records are now detected, shown in change previews, and rejected by tmsh Modify and merge deploys (tmsh records add/delete cannot apply them); previously these reported success while applying nothing
- Backups verify the read succeeded before writing - a failed or timed-out GET no longer produces a valid-looking empty backup file
- Each backup gets its own timestamp; repeated backups of the same object in a session no longer overwrite each other
- Backup rotation fixed - MAX_BACKUPS was never enforced due to a filename pattern mismatch; URL category backups now rotate as well
- URL category backups consolidated into a single backup function; delete, editor apply, and fleet deploy previously used three inline copies
- Fixed a latent set -e exit when a remote backup write failed during fleet deploy
- Malformed fleet.conf lines (missing or extra '|', empty site or host field) are now hard validation errors with line numbers; a line without a delimiter previously registered the hostname as its own site
- Username prompt defaults to admin when left blank, matching suite convention

# DGCat-Admin v5.2 Release Notes 

- This release was focused on file input validation for fleet.conf, bootstrap.conf, and csv file import
- Tried to incorporate as much input validation as possible to prevent the user being able to send bad data to the API only to get rejected 
- Changed the bash backups location to be relative - matching the powershell version

# DGCat-Admin v5.1 Release Notes 

- Deploy merge uses incremental API calls instead of pull-modify-push
- Deploy Step 2 (current device) respects deploy mode selection
- System datagroup sys_APM_MS_Office_OFBA_DG added to protected/filter list
- MAX_BACKUPS reduced from 30 to 10
- Bootstrap.conf boilerplate reformatted with updated examples

# DGCat-Admin v5.0 Release Notes 

**Bootstrap (Option 8)**
- Bootstrap will create datagroups and URL Categories across your entire fleet based on bootstrap.conf entries; useful for multi-site initial configuration
- Look in bootstrap.conf in the dgcat-admin-backups folder after selecting bootstrap - create bootstrap.conf

**UI**  
- Datagroup selection now displays numbered lists across all operations for ease of selection
- System datagroups are now hidden from selection list view
- Removed legacy Connect to BIG-IP startup menu

**Datagroup Editor and Deploy**
- Added a second mode to the datagroup editor 'w' write function and 'D' deploy function. Originally this tool made atomic edits to datagroups in that when a datagroup was edited, entries added... entries deleted... the tool would pull the entire datagroup - do the edits in memory and then PATCH the entire datagroup in a "replace-all-with" REST equivalent action. There is another way to send tmsh commands in an options parameter to leave the contents of a datagroup alone and simply add or replace individual entries within.  DGCat-Admin Editor now supports both modes "Full Replace" i.e. REST PATCH, and "tmsh Modify" via the option parameter technique.
- Described here: https://community.f5.com/discussions/technicalforum/update-an-internal-data-group-via-api/306520

**Cleanup**
- Removed 8 orphaned functions

# DGCat-Admin v4.6 Release Notes 

**Fleet Backup (Option 7)**
- Pull and save backups of a datagroup or URL category across the fleet. Supports scoping by all hosts, site, or individual host selection.
- Backups Disabled — `BACKUPS_ENABLED` config variable (default: off). Set to 1 to enable automatic pre-change backups. 
- Deploy scope selection now matches Search and Fleet Backup with comma-separated site and host selection.

**Bug Fixes**
- **Bash Empty Array Handling** — All editor array operations converted to index-based loops to prevent unbound variable errors with `set -u` on empty datagroups.

# DGCat-Admin v4.5 Release Notes 

**Fleet Search (option 6)**
- Query and compare datagroups or URL categories across fleet hosts from a single read-only session.
- **Pull** — Retrieve entries from all fleet hosts, a specific site, or individual hosts
- **Search** — Find entries by pattern across the fleet; results are deduplicated before presentation
- **Diff** — Identify configuration drift; entries missing from one or more hosts are flagged with per-host details

**URL Category enhancement**
- Added a check for all URL category functions that take what the user types i.e. "Pinners" and if this value is not found, prepend sslo-urlCat and retry. This is for some special categories that show as "Pinners" in the GUI but are really named sslo-urlCatPinners

**Bug Fixes**
- **PowerShell Save-F5Config** — Rebuilt on the Invoke-F5Post framework. Previous version silently failed due to a .NET restricted header exception.

# DGCat-Admin v4.3 Release Notes 

**Large Dataset Support**
- Tested with 20000-entry URL categories and 1000-entry address datagroups
- Bash appears to have a limit of 6000-7000 URL records before the editor gets really slow due to the arrays - added a warning and confirmation to continue when records are pulled
- Powershell is fast even with 20k records in the editor - though needs a longer API_TIMEOUT set in the configuration but this will vary by environment
- set API timeout to 60s default to accomodate large dataset publishing out of box
- URL category creation split into create-then-populate sequence 
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


# DGCat-Admin v4.2 Release Notes 

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

# DGCat-Admin v4.1 Release Notes 

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

# DGCat-Admin v4.0 Release Notes 

- Initial public release

