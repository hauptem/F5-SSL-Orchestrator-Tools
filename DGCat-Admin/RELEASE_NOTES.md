# DGCat-Admin v4.2 Release Notes

**Deploy Output**
- Consistent three-step visibility for every host: Creating backup, Applying changes, Saving configuration
- Each step shows [ OK ] or [FAIL] individually — failures stop at the step that broke
- Current device and fleet hosts display identically
- Blank line between each host block for readability
- Backup file paths no longer shown in deploy output (still written to log)
- Backups moved from pre-deploy validation to deploy execution for honest per-host reporting
- Suppressed data preparation progress lines (Building records, Building URL list)

**Deploy Flow**
- All hosts pass validation: proceeds directly to deployment without second prompt
- Some hosts fail validation: prompts operator before continuing with partial deploy
- Validation is now lighter — checks connectivity and object existence only
- Deploy scope selection shows true topology counts including connected host

**Deploy Summary**
- SKIP entries no longer echo the pre-check reason — the reason was already shown during validation
- Error messages in summary reserved for FAIL status only (actual deploy failures)

**Backups**
- Connected host backups now include hostname in filename, matching fleet backup naming convention

**Preflight**
- Press Enter prompt after preflight replaced with 2-second pause

# DGCat-Admin v4.1 Release Notes - March 28 2026

**New Features**
- Create Empty Datagroup or URL Category menu option
- Logging toggle (LOGGING_ENABLED)

**Deploy**
- Skips current device when no pending changes exist
- Step numbering adjusts dynamically
- Prompt and preview reflect actual scope
- Pre-check failures show as SKIP in summary; FAIL reserved for actual deploy failures
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

