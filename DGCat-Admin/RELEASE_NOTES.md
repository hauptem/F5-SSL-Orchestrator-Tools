# DGCat-Admin v5.7 Release Notes

- tmsh Modify and fleet Merge now send datagroup records in batches. The record list rides in the request URI, and a change set of a few thousand records produced a URI long enough to be rejected with a generic HTTP error. New TMSH_CHUNK_SIZE configuration (default: 500) sets the batch size; each batch that reports an error is read back and verified independently
- Datagroup export verifies the read succeeded before writing. A failed or timed-out GET produced a header-only file reporting 0 records in PowerShell; in bash the failed pipeline inside the redirected block tripped errexit and exited the tool mid-export. The tool now reports the HTTP error and writes nothing. URL category export was already protected by its count check
- Exports get their own timestamp. The default export filename used the session start time, so exporting the same object twice in one session overwrote the first file. Backups have been stamped per file since v5.3; exports now match
- Editor: applying URL category changes no longer resets the pending change set when one of the two requests (delete, add) fails. The failed half stays pending for retry; previously it was reported as applied with errors and the delta was lost. Datagroup apply already behaved this way
- Editor: an entry that exactly matches an existing key is selected by key before the input is read as a row number. In an integer datagroup, typing 8080 previously selected row 8080 and the key 8080 was unreachable by name
- Editor: pressing Enter at the URL prompt of e) Edit entry keeps the stored URL verbatim. The current URL was re-normalized, which stripped a path or rewrote http:// to https:// and staged a rename the operator did not ask for. Only a new value is normalized now
- The URL category availability check no longer caches a transient failure. A timeout or 5xx on the first probe disabled URL category features for the whole session; only a definitive 4xx (module not provisioned) is cached now
- PowerShell: Search compared entries case-insensitively. The entry maps were hashtable literals, which fold case, so Foo on one host and foo on another reported as one entry present everywhere; they now use ordinal hashtables like the rest of the tool. Bash associative arrays were already case-sensitive
- PowerShell: editor row numbers resolve to the record directly instead of splitting the displayed key|value text, so a string key containing '|' is no longer mis-selected by number. In bash the '|' delimiter is structural to the record list and this remains a limitation
- README and User Guide corrected: the PowerShell version requires Windows PowerShell 5.1 (Desktop edition), not "5.1 or later", since PowerShell 7 has been rejected at startup since v5.4

# DGCat-Admin v5.6 Release Notes

- Datagroups in TMOS folders are now fully supported. REST paths previously omitted the folder segment, so a datagroup like /Common/dashboard/mygroup listed normally but read as empty and could not be edited; folder objects now work across listing, selection, the editor, create, delete, export, backup, Search, Fleet Backup, and deploy. Listings show folder-qualified names (dashboard/mygroup); a bare name that exists in exactly one folder resolves to it, and an ambiguous name lists the candidates. New datagroups can be created into a folder as folder/name. The folder itself must already exist, as this tool creates objects, not folders
- Backups of folder datagroups fold the folder into the filename so same-named datagroups in different folders keep separate files and rotation pools, and record the location in a # Folder: header
- New PROTECTED_FOLDERS configuration (default: appsvcs, ServiceDiscovery). Datagroups in these folders belong to AS3 and Service Discovery; they are tagged "externally managed" in listings and blocked from create, edit, and delete. Remove entries from the list to disable the guard
- Editor: new e) Edit entry command changes a record's key and/or value in place at its original position; previously a record could only be changed by deleting and re-adding it, which also moved it to the end of the set. Enter keeps the current key or value, '-' clears a value. Edits stage in memory like every other editor change; the single confirmation is at apply, so bulk editing is not interrupted per record
- Change previews now show the value being applied for edited records (key : value, or old -> new when replacing an existing value); previously only the key was listed
- The apply and deploy mode menus now offer only the modes that can apply the change set. tmsh Modify and Merge cannot apply edited values, or keys and values containing tmsh syntax characters, so for those change sets the menu shows Full Replace as the only mode; previously the ineligible mode was offered and then refused after selection. Selecting Merge by number when it is not shown is refused rather than silently converted, since Full Replace would overwrite target-specific entries
- tmsh passthrough results are verified by read-back. TMOS occasionally applies a records add/delete while the client-side transport reports an error; the tool now reads the datagroup back and treats the change as applied when the records are present (or gone), with a warning. A blind retry would be unsafe, since tmsh refuses to add an existing record or delete a missing one
- New DEBUG_ENABLED configuration (default: off). Set to 1 to trace every API request and response: method, URL, decoded tmsh options, request body, HTTP status, and the BIG-IP error body on failures. Credentials are never traced
- Rejected requests now show the BIG-IP JSON error message (e.g. the folder-not-found reason on a failed create) instead of only the generic HTTP status. PowerShell previously lost the response body on Windows PowerShell 5.1 because Invoke-RestMethod drains the stream into ErrorDetails; the body is now taken from ErrorDetails first
- PowerShell: fleet deploy from the editor failed with CommandNotFoundException on Windows PowerShell 5.1. The closure binding introduced in v5.4 runs in a dynamic module whose command lookup skips the running script's scope, so the deploy function could not be resolved by name; it is now captured into the closure as a variable
- PowerShell: deploy Step 2 now honors the selected mode on the current device. A Merge deploy applies only the staged delta to the connected host, through the same per-host deploy path as the fleet. Previously Step 2 always full-replaced the connected host regardless of mode; the bash version already honored the mode
- PowerShell: the deploy summary row for the current device now carries the same error detail as fleet rows
- Housekeeping: datagroup key and URL entry validation is shared between the editor's add and edit commands (PowerShell also shares it with CSV import validation)
- The bash version returns to full feature parity with this release. Everything above is in both versions unless marked PowerShell

# DGCat-Admin v5.5 Release Notes

- Search drift detection now also compares datagroup values, not just keys. Entries present on every host but holding different values are flagged as a value mismatch, with per-host values shown in both Diff and Search results; previously the same key with different data on two hosts reported as consistent. Each entry is classified once after the fleet pull, so Diff and Search always agree. Search patterns still match keys only. URL categories are unaffected, as they have no values
- PowerShell: section headers now reach the session log. Write-LogSection wrote its banner to the console only, so LOGGING_ENABLED audit logs were a flat stream of status lines with no record of which operation produced them

# DGCat-Admin v5.4 Release Notes

- Bootstrap no longer discards per-host save results. Objects created but not saved to disk now count as a host failure with a warning to save manually
- Fleet backups now rotate under MAX_BACKUPS like connected-host backups. Fleet datagroup backup filenames gain the internal class segment so both paths share one rotation pool per host and object; fleet backups from earlier versions use the old name shape and are not managed. Remove them manually if desired
- PowerShell: config save verification is locale-independent and no longer takes the BIG-IP close-after-save quirk on faith. A connection drop is confirmed with a reachability check and an idempotent save retry, so a genuine network failure during save is reported as a failure; the previous detection matched localized .NET exception text and never fired on non-English Windows. The bash version never had this defect, since curl accepts a post-response connection close
- PowerShell: requires Windows PowerShell 5.1. PowerShell 7 ignores the certificate policy used for self-signed management certs; the script now exits immediately with the correct invocation instead of failing later with TLS errors
- PowerShell: fleet deploy scriptblocks are bound as closures at creation. They previously resolved editor variables through the dynamic call stack at invocation, which worked only because Invoke-FleetDeploy's parameter names carried the same values, a latent break on any parameter rename
- PowerShell: the search viewer no longer assigns to the $input automatic variable
- PowerShell housekeeping: Wait-EnterKey replaces Press-EnterToContinue, the unused DgType parameter is removed from Deploy-DatagroupToHost, bare catch blocks are normalized
- The bash version number now tracks the suite for consistency and receives targeted bugfixes only (the first two items above)

# DGCat-Admin v5.3 Release Notes

- tmsh Modify and fleet Merge deploys now reject keys and values containing whitespace, braces, quotes, backslash, ';', or '#'. These are embedded unquoted in the tmsh options string and can corrupt the parse or delete unintended records; Full Replace is unaffected
- Value changes to existing records are now detected, shown in change previews, and rejected by tmsh Modify and Merge deploys, since tmsh records add/delete cannot apply them. Previously these reported success while applying nothing
- Backups verify the read succeeded before writing. A failed or timed-out GET no longer produces a valid-looking empty backup file
- Each backup gets its own timestamp. Repeated backups of the same object in a session no longer overwrite each other
- Backup rotation fixed. MAX_BACKUPS was never enforced due to a filename pattern mismatch; URL category backups now rotate as well
- URL category backups consolidated into a single backup function. Delete, editor apply, and fleet deploy previously used three inline copies
- Fixed a latent set -e exit when a remote backup write failed during fleet deploy
- Malformed fleet.conf lines (missing or extra '|', empty site or host field) are now hard validation errors with line numbers. A line without a delimiter previously registered the hostname as its own site
- The username prompt defaults to admin when left blank, matching suite convention

# DGCat-Admin v5.2 Release Notes

- Input validation for fleet.conf, bootstrap.conf, and CSV import. Bad data is rejected locally before it reaches the API instead of being sent and refused
- Bash backups location is now relative, matching the PowerShell version

# DGCat-Admin v5.1 Release Notes

- Deploy Merge uses incremental API calls instead of pull-modify-push
- Deploy Step 2 (current device) respects the deploy mode selection
- System datagroup sys_APM_MS_Office_OFBA_DG added to the protected/filter list
- MAX_BACKUPS reduced from 30 to 10
- bootstrap.conf boilerplate reformatted with updated examples

# DGCat-Admin v5.0 Release Notes

- New Bootstrap (option 8) creates datagroups and URL categories across the entire fleet from bootstrap.conf entries, for multi-site initial configuration. Selecting Bootstrap, then Create bootstrap.conf, writes the file to the dgcat-admin-backups folder
- Editor: the w) write and D) deploy commands gain a second mode. The tool previously applied every edit atomically: pull the whole datagroup, edit in memory, and PATCH the complete record set back (a replace-all REST action). TMOS also accepts tmsh commands in an options parameter, which leaves the datagroup contents alone and adds or replaces individual entries. The editor now supports both: Full Replace (REST PATCH) and tmsh Modify (options parameter). Background: https://community.f5.com/discussions/technicalforum/update-an-internal-data-group-via-api/306520 and https://community.f5.com/discussions/technicalforum/add-new-key-into-data-group-without-updating-entire-list-using-the-api/272699
- Datagroup selection now displays numbered lists across all operations
- System datagroups are hidden from the selection list
- Removed the legacy Connect to BIG-IP startup menu
- Housekeeping: removed 8 orphaned functions

# DGCat-Admin v4.6 Release Notes

- New Fleet Backup (option 7) pulls and saves backups of a datagroup or URL category across the fleet, scoped to all hosts, a site, or individual hosts
- New BACKUPS_ENABLED configuration (default: off). Set to 1 to enable automatic pre-change backups
- Deploy scope selection now matches Search and Fleet Backup, with comma-separated site and host selection
- Bash: all editor array operations converted to index-based loops to prevent unbound variable errors under set -u on empty datagroups

# DGCat-Admin v4.5 Release Notes

- New Fleet Search (option 6) queries and compares datagroups or URL categories across fleet hosts from a single read-only session. Pull retrieves entries from all fleet hosts, a site, or individual hosts; Search finds entries by pattern across the fleet, with results deduplicated before presentation; Diff identifies configuration drift, flagging entries missing from one or more hosts with per-host details
- URL category functions now retry a name the user typed (e.g. Pinners) with the sslo-urlCat prefix when it is not found, since some categories appear as Pinners in the GUI but are named sslo-urlCatPinners
- PowerShell: Save-F5Config rebuilt on the Invoke-F5Post framework. The previous version silently failed on a .NET restricted header exception

# DGCat-Admin v4.3 Release Notes

- Large dataset support, tested with 20000-entry URL categories and 1000-entry address datagroups. Bash slows noticeably in the editor above roughly 6000 to 7000 URL records because of its arrays, so a warning and confirmation are shown when records are pulled. PowerShell stays fast at 20k records in the editor but needs a longer API_TIMEOUT, which varies by environment
- API_TIMEOUT default raised to 60s to accommodate large dataset publishing out of the box
- URL category creation split into a create-then-populate sequence
- Bash: fixed argument overflow on large list imports
- Bash: CSV parsing and URL conversion rewritten with shell builtins; large dataset processing now takes about 2s instead of 10 to 20s
- Editor apply path optimized from O(n²) to O(n)
- CIDR alignment check on import prevents an HTTP 400 when installing entries with misaligned subnets via the API
- CSV duplicates are removed before applying, and the reported count is corrected
- Fixed a few more minor color discrepancies between the PowerShell and bash UI
- Housekeeping: removed some dead code

# DGCat-Admin v4.2 Release Notes

- Deploy now shows the same three steps for every host: Creating backup, Applying changes, Saving configuration. The current device and fleet hosts display their statuses identically
- Backup file paths are no longer shown in deploy output, but are still written to the log
- Backups moved from pre-deploy validation to the deploy execution stage, since a deployment can be cancelled by the operator after pre-deployment failures
- Data preparation progress lines (Building records, Building URL list) are suppressed
- If all hosts pass pre-deploy validation, deployment proceeds without a second confirmation prompt; if some hosts fail, the operator is prompted before continuing with a partial deployment
- SKIP entries no longer echo the pre-check reason in the deployment summary, since it was shown in the pre-deploy summary
- Connected host backups now include the hostname in the filename, matching the fleet backup naming convention

# DGCat-Admin v4.1 Release Notes

- New Create an Empty Datagroup or URL Category menu option
- New LOGGING_ENABLED configuration to enable or disable tool logging
- Deploy skips the current device when it has no pending changes (when the write feature was used before deployment), and step numbering adjusts dynamically
- Pre-check failures now show as SKIP in the deploy summary; FAIL is reserved for actual deploy failures
- Connected host backups are saved within a site subfolder when the host is in a fleet
- Menu restructured: View removed, Edit renamed to View/Edit
- Editor commands spaced into visual groups with matched colors across both versions, and section headers and dividers use consistent display widths
- PowerShell: fixed a save config false positive caused by BIG-IP closing the connection after save
- PowerShell: fixed single-result array unwrapping across all pipelines
- PowerShell: fixed a duplicate deploy header and carriage return display artifacts

# DGCat-Admin v4.0 Release Notes

- Initial public release
