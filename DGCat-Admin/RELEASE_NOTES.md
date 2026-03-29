# DGCat-Admin v4.0 Release Notes - March 27 2026

- Initial public release

# DGCat-Admin v4.1 Release Notes - March 29 2026

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
- Fixed PowerShell save config failure caused by BIG-IP closing connection after save
- Fixed PowerShell single-result array unwrapping across all pipelines
- Fixed duplicate deploy header and carriage return display artifacts
