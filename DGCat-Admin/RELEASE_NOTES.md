# DGCat-Admin v5.7 Release Notes 

- tmsh Modify and fleet Merge now send datagroup records in batches. The record list rides in the request URI, and a change set of a few thousand records produced a URI long enough to be rejected with a generic HTTP error. New TMSH_CHUNK_SIZE configuration (default: 500) sets the batch size; each batch that reports an error is read back and verified independently 
- Datagroup export verifies the read succeeded before writing. A failed or timed-out GET produced a header-only file reporting 0 records in PowerShell; in bash the failed pipeline inside the redirected block tripped errexit and exited the tool mid-export. The tool now reports the HTTP error and writes nothing. URL category export was already protected by its count check 
- Exports get their own timestamp. The default export filename used the session start time, so exporting the same object twice in one session overwrote the first file. Backups have stamped per file since v5.3; exports now match 
- Editor: applying URL category changes no longer resets the pending change set when one of the two requests (delete, add) fails. The failed half stays pending for retry; previously it was reported as applied with errors and the delta was lost. Datagroup apply already behaved this way 
- Editor: an entry that exactly matches an existing key is selected by key before the input is read as a row number. In an integer datagroup, typing 8080 previously selected row 8080 and the key 8080 was unreachable by name 
- Editor: pressing Enter at the URL prompt of e) Edit entry keeps the stored URL verbatim. The current URL was re-normalized, which stripped a path or rewrote http:// to https:// and staged a rename the operator did not ask for. Only a new value is normalized now 
- PowerShell: Search compared entries case-insensitively. The entry maps were hashtable literals, which fold case, so Foo on one host and foo on another reported as one entry present everywhere; they now use ordinal hashtables like the rest of the tool. Bash associative arrays were already case-sensitive 
- PowerShell: editor row numbers resolve to the record directly instead of splitting the displayed key|value text, so a string key containing '|' is no longer mis-selected by number. In bash the '|' delimiter is structural to the record list and this remains a limitation 
- The URL category availability check no longer caches a transient failure. A timeout or 5xx on the first probe disabled URL category features for the whole session; only a definitive 4xx (module not provisioned) is cached now 
- README and User Guide corrected: the PowerShell version requires Windows PowerShell 5.1 (Desktop edition), not "5.1 or later", since PowerShell 7 has been rejected at startup since v5.4 

# DGCat-Admin v5.6 Release Notes 

- Datagroups in TMOS folders are now fully supported. REST paths previously omitted the folder segment, so a datagroup like /Common/dashboard/mygroup listed normally but read as empty and could not be edited; folder objects now work across listing, selection, the editor, create, delete, export, backup, Search, Fleet Backup, and deploy. Listings show folder-qualified names (dashboard/mygroup); a bare name that exists in exactly one folder resolves to it, and an ambiguous name lists the candidates. New datagroups can be created into a folder as folder/name - the folder itself must already exist, as this tool creates objects, not folders 
- Backups of folder datagroups fold the folder into the filename so same-named datagroups in different folders keep separate files and rotation pools, and record the location in a # Folder: header 
- New PROTECTED_FOLDERS configuration (default: appsvcs, ServiceDiscovery). Datagroups in these folders belong to AS3 and Service Discovery; they are tagged "externally managed" in listings and blocked from create, edit, and delete. Remove entries from the list to disable the guard 
- Editor: new e) Edit entry command changes a record's key and/or value in place at its original position; previously a record could only be changed by deleting and re-adding it, which also moved it to the end of the set. Enter keeps the current key or value, '-' clears a value. Edits stage in memory like every other editor change - the single confirmation is at apply, so bulk editing is not interrupted per record 
- Change previews now show the value being applied for edited records (key : value, or old -> new when replacing an existing value); previously only the key was listed 
- The apply and deploy mode menus now offer only the modes that can apply the change set. tmsh Modify and Merge cannot apply edited values, or keys and values containing tmsh syntax characters, so for those change sets the menu shows Full Replace as the only mode; previously the ineligible mode was offered and then refused after selection. Selecting Merge by number when it is not shown is refused rather than silently converted, since Full Replace would overwrite target-specific entries 
- tmsh passthrough results are verified by read-back. TMOS occasionally applies a records add/delete while the client-side transport reports an error; the tool now reads the datagroup back and treats the change as applied when the records are present (or gone), with a warning. A blind retry would be unsafe - tmsh refuses to add an existing record or delete a missing one 
- New DEBUG_ENABLED configuration variable (default: off). Set to 1 to trace every API request and response - method, URL, decoded tmsh options, request body, HTTP status, and the BIG-IP error body on failures. Credentials are never traced 
- Rejected requests now show the BIG-IP JSON error message (e.g. the folder-not-found reason on a failed create) instead of only the generic HTTP status. PowerShell previously lost the response body on Windows PowerShell 5.1 because Invoke-RestMethod drains the stream into ErrorDetails; the body is now taken from ErrorDetails first 
- PowerShell: fleet deploy from the editor failed with CommandNotFoundException on Windows PowerShell 5.1. The closure binding introduced in v5.4 runs in a dynamic module whose command lookup skips the running script's scope, so the deploy function could not be resolved by name; it is now captured into the closure as a variable 
- PowerShell: deploy Step 2 now honors the selected mode on the current device - a Merge deploy applies only the staged delta to the connected host, through the same per-host deploy path as the fleet. Previously Step 2 always full-replaced the connected host regardless of mode; the bash version already honored the mode 
- PowerShell: the deploy summary row for the current device now carries the same error detail as fleet rows 
- Housekeeping: datagroup key and URL entry validation is shared between the editor's add and edit commands (PowerShell also shares it with CSV import validation) 
- The bash version returns to full feature parity with this release - everything above is in both versions unless marked PowerShell 

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
- and here        https://community.f5.com/discussions/technicalforum/add-new-key-into-data-group-without-updating-entire-list-using-the-api/272699

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

