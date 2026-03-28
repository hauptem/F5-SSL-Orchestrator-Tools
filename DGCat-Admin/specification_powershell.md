# DGCat-Admin v4.0 (PowerShell) — Technical Specification

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Communication Model](#2-communication-model)
3. [Session Lifecycle](#3-session-lifecycle)
4. [Input Data Processing](#4-input-data-processing)
5. [Datagroup Operations](#5-datagroup-operations)
6. [URL Category Operations](#6-url-category-operations)
7. [Editor Data Model](#7-editor-data-model)
8. [Fleet Deployment](#8-fleet-deployment)
9. [Backup System](#9-backup-system)
10. [Object Protection](#10-object-protection)
11. [Error Handling](#11-error-handling)
12. [Credential Handling](#12-credential-handling)
13. [API Efficiency](#13-api-efficiency)
14. [API Endpoint Reference](#14-api-endpoint-reference)
15. [Platform Differences from Bash Version](#15-platform-differences-from-bash-version)

---

## 1. System Overview

DGCat-Admin (PowerShell) is a PowerShell script that manages LTM internal datagroups and custom URL categories on F5 BIG-IP systems. It communicates exclusively through the iControl REST API over HTTPS. All operations are performed through a menu-driven interactive interface. 

### Requirements

The script requires PowerShell 5.1 or later. 

No external dependencies are required. The script uses built-in PowerShell cmdlets and .NET Framework classes:

- **Invoke-RestMethod** — HTTP client for REST API communication
- **ConvertTo-Json / ConvertFrom-Json** — JSON serialization (handled natively by Invoke-RestMethod for responses)
- **System.Net.ServicePointManager** — TLS configuration and certificate validation bypass

### Execution Environment

The script uses `#Requires -Version 5.1` to enforce the minimum PowerShell version. Error handling uses try/catch blocks with `$ErrorAction = "Stop"` on API calls to convert non-terminating errors into catchable exceptions.

The script runs as a single `.ps1` file from any directory. All state is held in `$script:` scoped variables for the session duration. No modules, no installation, no registry changes.

---

## 2. Communication Model

### API Request Handling

All API communication passes through a single base function (`Invoke-F5Api`) which constructs and executes REST requests. This function:

- Builds the request URI from the configured host and the endpoint path.
- Authenticates using a pre-computed Base64-encoded Authorization header (HTTP Basic Authentication).
- Sets `Content-Type: application/json` on all requests.
- Applies a configurable timeout (`$script:API_TIMEOUT`, default 10 seconds) via the `-TimeoutSec` parameter.
- Serializes request bodies to JSON using `ConvertTo-Json -Depth 20 -Compress`.
- Returns a hashtable containing `Success` (boolean), `Response` (parsed object or null), and `StatusCode` (integer).
- Returns success for HTTP 2xx responses. All other status codes return failure with the status code captured from the exception response.

Four wrapper functions provide shorthand for specific HTTP methods: `Invoke-F5Get`, `Invoke-F5Post`, `Invoke-F5Patch`, `Invoke-F5Delete`. All route through `Invoke-F5Api`.

### SSL Certificate Handling

BIG-IP management interfaces typically use self-signed SSL certificates. The script bypasses certificate validation at startup by registering a custom `ICertificatePolicy` implementation (`TrustAllCertsPolicy`) via `Add-Type` and assigning it to `[System.Net.ServicePointManager]::CertificatePolicy`. TLS 1.2 is explicitly enabled via `[System.Net.SecurityProtocolType]::Tls12`.

The `Add-Type` call is guarded by a type existence check (`[System.Management.Automation.PSTypeName]'TrustAllCertsPolicy'`) to prevent errors on repeated invocations within the same PowerShell session.

### API Endpoints Used

The tool accesses eight distinct API endpoints. A complete reference including HTTP methods, calling functions, request/response formats, and caching behavior is provided in [Section 14: API Endpoint Reference](#14-api-endpoint-reference).

---

## 3. Session Lifecycle

### Startup Sequence

1. SSL certificate bypass is initialized via `Initialize-SslBypass`.
2. Welcome screen displayed. User selects connect or exit.
3. Backup directory created if it does not exist.
4. Session timestamp and log file initialized.
5. Pre-flight checks execute in this order:
   a. Partition list validated (from configuration array).
   b. Fleet configuration loaded from `fleet.conf` (if file exists).
   c. Connection established (host selection, credential entry, connection test).
   d. Each configured partition validated against the target BIG-IP via API. Results cached.
   e. Backup directory write access verified.
   f. URL category database availability checked via API. Result cached.
6. Main menu loop begins.

### Session Termination

Selecting exit from the main menu logs the session end timestamp and returns to the startup sequence. The user can connect to a different device or exit the tool entirely.

### Host Selection

If a fleet configuration is loaded, fleet hosts are displayed as numbered options at the connection prompt. The input field accepts either a fleet host number or a manually entered hostname/IP address. Entering `0` exits the tool.

---

## 4. Input Data Processing

### CSV Parsing

CSV files are parsed line by line using `Get-Content` with the following processing:

1. **Blank lines** are skipped.
2. **Comment lines** (lines where the first non-whitespace character is `#`) are skipped.
3. **Leading and trailing whitespace** is trimmed from each line via the `.Trim()` method.
4. Lines are split on the first comma using `-split ',', 2`. The first field becomes the key; everything after the first comma becomes the value.
5. Lines with empty keys after trimming are skipped with a warning.

Two parsing modes are supported:

- **Keys only**: The first column is extracted as the key. Values are set to empty strings.
- **Keys and values**: The first column is the key. Everything after the first comma is the value.

### Line Ending Handling

Before parsing, CSV files are checked for Windows line endings (CRLF) using `[System.IO.File]::ReadAllText()` with a `.Contains("`r`n")` check. File paths are resolved to absolute paths via `Resolve-Path` before any .NET method calls to prevent working directory mismatch between PowerShell and the .NET runtime.

If Windows line endings are detected, they are converted to Unix line endings (LF) by replacing `"`r`n"` with `"`n"` in memory and writing the result back to the file. On Windows, CSV files with CRLF are common and this conversion ensures consistent parsing.

### Type Validation

After parsing, the tool analyzes all keys against the target datagroup type:

- **Address validation**: Keys are tested against regex patterns for IPv4 addresses, IPv4 CIDR notation, and IPv6 addresses.
- **Integer validation**: Keys are tested for digits only, with optional leading minus.
- **String validation**: No format restrictions.

The analysis produces a mismatch count and percentage. If mismatches are detected, the tool displays a warning and prompts the operator to continue or abort.

### File Preview

Before parsing, the tool displays the first 5 data lines (configurable via `$script:PREVIEW_LINES`) of the CSV file along with the total data line count. Comment and blank lines are excluded from the preview.

---

## 5. Datagroup Operations

### Data Model

Datagroups contain records consisting of a key and an optional value. The BIG-IP API represents records as a JSON array:

```json
{"records": [{"name": "key1", "data": "value1"}, {"name": "key2"}]}
```

Records without values omit the `data` field. In PowerShell, records are represented as arrays of hashtables with `name` and optionally `data` keys, serialized to JSON via `ConvertTo-Json`.

### Record Serialization

The `ConvertTo-RecordsJson` function iterates over parallel key and value arrays, building an array of hashtables. Each hashtable contains a `name` key and optionally a `data` key if the value is non-empty. The resulting array is passed to `Invoke-F5Patch` which serializes it to JSON via `ConvertTo-Json -Depth 20 -Compress`.

### Write Operations — Full Replace

All datagroup write operations use the `PATCH` method against the datagroup endpoint with a complete `records` array. This is an atomic replace-all operation. This applies to:

- **CSV Import (overwrite mode)**: The parsed CSV contents become the complete record set.
- **CSV Import (merge mode)**: Existing records are read from the BIG-IP, merged with CSV records in a hashtable (deduplicating by key), and the merged result is written as a full replace.
- **Editor apply (`w`)**: The working array contents become the complete record set.
- **Fleet deploy (full replace mode)**: The source device's record set is written to each target as a full replace.

### Write Operations — Fleet Deploy Merge

In merge mode, fleet deployment performs the following per target host:

1. Read current records from the target via `GET`.
2. Build a hashtable from target records.
3. Remove entries whose keys appear in the deletions list.
4. Add entries from the additions list, overwriting existing keys.
5. Convert the merged hashtable back to an array of record objects.
6. Write the merged result as a full replace via `PATCH`.

### Datagroup Name Retry

When selecting a datagroup by name, the tool loops on invalid input. If the entered name does not match an existing datagroup on the target BIG-IP (case-sensitive match by the API), the tool displays an error and re-prompts. The operator can enter `q` to cancel and return to the menu.

---

## 6. URL Category Operations

### Data Model

URL categories contain URL entries, each with a name and a type. The BIG-IP API represents entries as a JSON array:

```json
{"urls": [{"name": "https://example.com/", "type": "exact-match"}]}
```

The type field is either `exact-match` or `glob-match`. Entries containing the `*` character are classified as `glob-match`; all others are classified as `exact-match`. The `ConvertTo-UrlObjects` function builds these typed hashtables from a string array of URLs.

### Domain-to-URL Conversion

Input domains are converted to F5 URL category format by the `Format-DomainForUrlCategory` function:

1. Any existing `http://` or `https://` protocol prefix is stripped.
2. Trailing path components after the first `/` are stripped.
3. A leading dot (`.example.com`) is converted to a wildcard prefix (`*.example.com`).
4. The `https://` prefix and trailing `/` are added, producing the final format: `https://example.com/` or `https://*.example.com/`.

### Write Operations — Full Replace

The `PATCH` method with a complete `urls` array replaces all entries atomically. This is used for CSV import (overwrite mode) and fleet deploy (full replace mode).

### Write Operations — Record-Level

**Addition** (`Add-UrlCategoryEntriesRemote`): The current URL list is read via `GET`. New entries are merged into a hashtable keyed by URL name (deduplicating). The merged result is written via `PATCH`.

**Deletion** (`Remove-UrlCategoryEntriesRemote`): The current URL list is read via `GET`. Entries matching the deletion list are filtered out using `Where-Object`. The filtered result is written via `PATCH`.

Record-level operations are used for editor apply (`w`) and fleet deploy (merge mode).

---

## 7. Editor Data Model

### State Management

When the editor opens, the current state of the target object is fetched from the BIG-IP and loaded into two pairs of `ArrayList` objects:

- **Working arrays** (`$workingKeys`, `$workingValues`): Modified by the operator during the session.
- **Original arrays** (`$originalKeys`, `$originalValues`): Snapshot of the state at load time. Used for change detection.

`ArrayList` is used instead of standard PowerShell arrays because it supports efficient in-place `Add`, `RemoveAt`, and `IndexOf` operations without array rebuilding.

All editor operations (add, delete, pattern delete) modify the working arrays only. The original arrays are read-only until changes are successfully applied, at which point the original arrays are updated to match the working arrays.

### Change Detection

The `Test-PendingChanges` nested function compares working and original arrays. It returns true if the arrays differ in length or any element at the same index differs.

### Change Analysis

The `Get-ChangeAnalysis` nested function computes additions and deletions using hashtable lookups for O(n) performance:

- **Additions**: Keys present in the working arrays but not in the original arrays.
- **Deletions**: Keys present in the original arrays but not in the working arrays.

### Apply Behavior

**Datagroups**: The complete working array is serialized to a records array via `ConvertTo-RecordsJson` and sent as a full replace via `PATCH`.

**URL categories**: Only the computed additions and deletions are sent. Deletions are applied first via `Remove-UrlCategoryEntriesRemote`, followed by additions via `Add-UrlCategoryEntriesRemote`. Entries that were not modified are not transmitted.

### Deploy Without Pending Changes

If the operator initiates a fleet deploy with no pending changes, the tool prompts for confirmation and proceeds with full replace mode.

### Case Sensitivity

The editor command switch uses `-CaseSensitive` to distinguish lowercase commands (`d` for delete, `w` for write, `q` for quit) from uppercase commands (`D` for deploy). PowerShell's `switch` statement is case-insensitive by default.

---

## 8. Fleet Deployment

### Configuration

Fleet hosts are defined in a plain text file (`fleet.conf`) located in the backup directory. Each line contains a site identifier and hostname or IP address separated by a pipe character. Site identifiers must match `^[a-zA-Z0-9_-]+$`. Comment lines and blank lines are ignored.

The file is parsed once at session start by `Import-FleetConfig` into three arrays: `$script:FleetSites`, `$script:FleetHosts`, and `$script:FleetUniqueSites`.

### Deployment Execution Order

Fleet deployment proceeds in three sequential phases, identical to the Bash version:

**Phase 1: Pre-deploy validation.** The tool connects to each target host using the current session credentials and verifies object existence, creates backups. Hosts are marked `OK`, `SKIP`, or `FAIL`. The operator reviews results and decides whether to proceed. No changes have been made to any device at this point.

**Phase 2: Apply to current device.** Changes are applied to the connected device first. If this fails, the operator is prompted to continue or abort.

**Phase 3: Deploy to fleet.** Changes are applied to each validated host in sequence via the `Invoke-FleetDeploy` function, which accepts a scriptblock (`$DeployAction`) that encapsulates the deploy logic for the specific object type and mode.

### Deployment Modes

**Full Replace**: The complete record set or URL list from the source device is sent via `PATCH`. The target's existing data is completely overwritten.

**Merge**: For datagroups, current records are read from each target, deletions removed, additions appended, deduplicated by key, and the result written as a full replace. For URL categories, deletions and additions are applied via separate record-level operations.

### Systemic Failure Detection

During fleet deployment, consecutive identical error messages are tracked. At three consecutive identical errors, the operator is prompted to continue or stop. The counter resets if the operator continues.

### Confirmation Requirements

The `DEPLOY` keyword confirmation uses case-sensitive comparison (`-cne "DEPLOY"`) to require exact case. PowerShell's `-ne` operator is case-insensitive by default.

---

## 9. Backup System

### Trigger Points

Backups are created automatically before:

- Overwriting or merging entries during CSV import
- Deleting a datagroup or URL category
- Applying changes from the editor
- Deploying to the current device
- Deploying to each fleet host (per-host backups during pre-deploy validation)

### Backup Format

Backup files are CSV with UTF-8 encoding and a comment header containing metadata. All file writes use `Out-File -Encoding UTF8` to prevent PowerShell's default UTF-16LE encoding.

### File Naming

Local backups: `{partition}_{name}_internal_{timestamp}.csv`

URL category backups: `urlcat_{name}_{timestamp}.csv`

Fleet backups are stored in site subdirectories: `{site}\{hostname}_{partition}_{name}_{timestamp}.csv`

### Retention

Backup files are grouped by object name. When the count exceeds `$script:MAX_BACKUPS` (default: 30), the oldest files are deleted. Files are sorted by `LastWriteTime` in descending order via `Get-ChildItem | Sort-Object`.

### Backup Location

The backup directory defaults to `$PSScriptRoot\dgcat-admin-backups` — a subdirectory alongside the script file. This ensures backups, logs, and the fleet configuration file are co-located with the script regardless of the PowerShell working directory.

---

## 10. Object Protection

### Protected Datagroups

Three system datagroups are designated as protected: `private_net`, `images`, `aol`.

Protection is enforced at CSV import, editor entry, and deletion. Protected datagroups are marked with a `[SYSTEM]` label in listing displays.

### Confirmation Requirements

| Operation | Confirmation Required |
|-----------|----------------------|
| Overwrite existing object (CSV import) | Selection of "Overwrite" option |
| Delete datagroup or URL category | Type `DELETE` (case-sensitive via `-cne`) |
| Apply editor changes | Type `yes` |
| Fleet deploy | Type `DEPLOY` (case-sensitive via `-cne`) |
| Continue without backup | Type `yes` (default: no) |
| Continue after current device apply failure | Type `yes` (default: no) |
| Continue after systemic fleet failure | Type `yes` (default: no) |
| Deploy with no pending changes | Type `yes` (default: no) |

All confirmation prompts default to the safe action when the operator presses Enter without input.

---

## 11. Error Handling

### API-Level

The `Invoke-F5Api` function wraps `Invoke-RestMethod` in a try/catch block with `-ErrorAction Stop`. Non-2xx responses throw exceptions which are caught. The HTTP status code is extracted from the exception's `Response.StatusCode` property. Callers check the returned `Success` boolean and `StatusCode` integer.

Specific HTTP codes trigger specific messages:

- `401`: Authentication failure
- `0`: Connection failure (timeout or unreachable host)
- `404`: Object not found
- All others: Generic failure with HTTP code displayed

### Timeout Handling

All API requests use `-TimeoutSec $script:API_TIMEOUT` (default: 10 seconds). Unlike the Bash version which separates connection timeout (`--connect-timeout`) from total request timeout (`--max-time`), PowerShell's `Invoke-RestMethod` provides a single timeout parameter covering the entire request lifecycle. Unreachable hosts fail within the configured timeout rather than the .NET default of 100 seconds.

### Deployment Error Tracking

Fleet deployment tracks success, failure, skip, and consecutive same-error counts, identical to the Bash version.

---

## 12. Credential Handling

### Input

Credentials are entered interactively at session start:

- Username: Standard terminal input via `Read-Host`
- Password: Masked input via `Read-Host -AsSecureString` (displays asterisks, never echoes plaintext)

### Conversion

The `SecureString` password is converted to plaintext using `[System.Runtime.InteropServices.Marshal]::SecureStringToBSTR` and `PtrToStringAuto`. The BSTR is explicitly freed via `ZeroFreeBSTR` after extraction.

### Storage

The plaintext password is stored in `$script:RemotePass` for the session duration. A Base64-encoded `Authorization` header is pre-computed and stored in `$script:AuthHeader`. Neither value is written to any file, log, backup, or temporary storage.

### Usage

Credentials are used exclusively in the `Invoke-F5Api` function via the pre-computed `Authorization` header. The password never appears in the process command line (unlike the Bash version's `curl -u` argument), as `Invoke-RestMethod` transmits credentials via HTTP headers within the .NET runtime.

### Reset

On session end, `$script:RemoteUser`, `$script:RemotePass`, and `$script:AuthHeader` are set to empty strings.

### Logging

The session log records the target hostname, operation timestamps, and operation outcomes. Credentials, usernames, API response bodies, and the Authorization header are not written to the log.

---

## 13. API Efficiency

### Session Caching

Two caches are populated during pre-flight checks and persist for the session duration:

**Partition cache** (`$script:PartitionCache`): A hashtable mapping partition names to `valid` or `invalid`. The `Test-PartitionExists` function checks this cache before making an API call.

**URL category database cache** (`$script:UrlCategoryDbCached`): A string variable set to `yes` or `no`. The `Test-UrlCategoryDbAvailable` function returns the cached value without an API call after the initial check.

### Cache Reset

Both caches are cleared when the session ends and the operator returns to the welcome screen.

### File Encoding

All file output operations use `-Encoding UTF8` to prevent PowerShell 5.1's default UTF-16LE encoding. This applies to log files, backup files, and CSV exports.

---

## 14. API Endpoint Reference

The PowerShell version calls the same eight API endpoints as the Bash version with identical request/response formats. The endpoints, HTTP methods, and semantics are documented in the Bash version's Technical Specification, Section 14. This section documents only the PowerShell-specific calling functions.

---

### 14.1 `/mgmt/tm/sys/version`

**Method:** GET

**Called by:**

| Function | Context |
|----------|---------|
| `Initialize-RemoteConnection` | Initial connection test during session setup |
| `Test-HostConnection` | Fleet pre-deploy validation per host |

**Response handling:** The response object's `entries` property is enumerated via `.PSObject.Properties` to extract the `Version.description` nested value.

---

### 14.2 `/mgmt/tm/sys/config`

**Method:** POST

**Called by:**

| Function | Context |
|----------|---------|
| `Save-F5Config` | After any successful write operation when the operator confirms save |

**Request body:** `@{ command = "save" }` — serialized to `{"command":"save"}` by `ConvertTo-Json`.

---

### 14.3 `/mgmt/tm/auth/partition/{partition}`

**Method:** GET

**Called by:**

| Function | Context |
|----------|---------|
| `Test-PartitionRemote` | Called through `Test-PartitionExists` during preflight and datagroup listing |

**Caching:** Results are cached in `$script:PartitionCache` for the session duration.

---

### 14.4 `/mgmt/tm/ltm/data-group/internal?$filter=partition eq {partition}`

**Method:** GET

**Called by:**

| Function | Context |
|----------|---------|
| `Get-DatagroupListRemote` | Populating datagroup selection lists |

**Response handling:** The `.items` array is filtered to exclude datagroups inside application service folders (paths matching `.app/`). Each item's `.partition` and `.name` properties are extracted into hashtables.

---

### 14.5 `/mgmt/tm/ltm/data-group/internal/~{partition}~{name}`

**Methods:** GET, PATCH, DELETE

**Called by:**

| Function | Method | Context |
|----------|--------|---------|
| `Test-DatagroupExistsRemote` | GET | Check existence |
| `Get-DatagroupTypeRemote` | GET | Retrieve type |
| `Get-DatagroupRecordsRemote` | GET | Read records |
| `Set-DatagroupRecordsRemote` | PATCH | Replace all records |
| `Remove-DatagroupRemote` | DELETE | Delete datagroup |

**PATCH request body:** `@{ records = $Records }` where `$Records` is an array of hashtables with `name` and optionally `data` keys. Serialized by `ConvertTo-Json -Depth 20 -Compress`.

---

### 14.6 `/mgmt/tm/ltm/data-group/internal`

**Method:** POST

**Called by:**

| Function | Context |
|----------|---------|
| `New-DatagroupRemote` | Creating a new datagroup during CSV import |

**Request body:** `@{ name = $Name; partition = $Partition; type = $Type }`.

---

### 14.7 `/mgmt/tm/sys/url-db/url-category`

**Methods:** GET, POST

**Called by:**

| Function | Method | Context |
|----------|--------|---------|
| `Get-UrlCategoryListRemote` | GET | Populating category selection lists |
| `Test-UrlCategoryDbAvailable` | GET | Pre-flight availability check |
| `New-UrlCategoryRemote` | POST | Creating a new URL category |

**Caching:** The GET result for availability checking is cached in `$script:UrlCategoryDbCached`. Category list queries are not cached.

---

### 14.8 `/mgmt/tm/sys/url-db/url-category/~Common~{name}`

**Methods:** GET, PATCH, DELETE

**Called by:**

| Function | Method | Context |
|----------|--------|---------|
| `Test-UrlCategoryExistsRemote` | GET | Check existence |
| `Get-UrlCategoryEntriesRemote` | GET | Read URL entries |
| `Get-UrlCategoryCountRemote` | GET | Count entries |
| `Add-UrlCategoryEntriesRemote` | GET + PATCH | Read, merge, write |
| `Remove-UrlCategoryEntriesRemote` | GET + PATCH | Read, filter, write |
| `Set-UrlCategoryEntriesRemote` | PATCH | Replace all URLs |
| `Remove-UrlCategoryRemote` | DELETE | Delete category |

**Note on record-level operations:** The BIG-IP URL category API does not support native add or delete operations for individual URL entries. Both `Add-UrlCategoryEntriesRemote` and `Remove-UrlCategoryEntriesRemote` implement record-level semantics by performing a read-modify-write cycle: GET the current state, transform it in memory, and PATCH the result.

---

## 15. Platform Differences from Bash Version

This section documents the implementation differences between the Bash and PowerShell versions. Both versions produce identical operator-facing behavior and identical API interactions with the BIG-IP.

### HTTP Client

| Aspect | Bash | PowerShell |
|--------|------|------------|
| HTTP client | curl | Invoke-RestMethod |
| JSON parsing | jq (external) | Native (automatic deserialization) |
| SSL bypass | curl `-sk` flag | Add-Type ICertificatePolicy + ServicePointManager |
| Connect timeout | `--connect-timeout 10` (TCP only) | `-TimeoutSec 10` (entire request) |
| Request timeout | `--max-time 30` (total) | `-TimeoutSec 10` (single parameter) |
| Auth mechanism | `curl -u user:pass` (visible in process list) | Authorization header in .NET runtime (not in process list) |

### Password Input

| Aspect | Bash | PowerShell |
|--------|------|------------|
| Input method | `read -srp` (silent, no echo) | `Read-Host -AsSecureString` (masked with asterisks) |
| Storage | Plain string in shell variable | SecureString converted to plain string, BSTR freed |
| Process visibility | Password in curl argument list (`ps` visible) | Password never in process argument list |

### Data Structures

| Aspect | Bash | PowerShell |
|--------|------|------------|
| Editor arrays | Bash indexed arrays | System.Collections.ArrayList |
| Cache | Bash associative arrays | PowerShell hashtables |
| Records | Pipe-delimited strings (`key\|value`) | Hashtables (`@{ name = ...; data = ... }`) |
| Fleet config | Parallel indexed arrays | Parallel standard arrays |

### File Operations

| Aspect | Bash | PowerShell |
|--------|------|------------|
| CSV parsing | Line-by-line with IFS splitting | Get-Content with `-split` operator |
| Line ending detection | `file` command + `grep` for `\r` | `[System.IO.File]::ReadAllText()` + `.Contains()` |
| Path resolution | Not required (bash resolves naturally) | `Resolve-Path` required before .NET method calls |
| Default file encoding | UTF-8 (OS default) | UTF-16LE (PowerShell default) — forced to UTF-8 via `-Encoding UTF8` |
| Backup directory | `/shared/tmp/dgcat-admin-backups` | `$PSScriptRoot\dgcat-admin-backups` |

### Case Sensitivity

| Aspect | Bash | PowerShell |
|--------|------|------------|
| switch/case | Case-sensitive by default | Case-insensitive by default; `-CaseSensitive` flag added to editor switch |
| String comparison `-eq` | Case-sensitive | Case-insensitive by default; `-ceq`/`-cne` used for DELETE and DEPLOY confirmations |
| API endpoint paths | Case-sensitive (BIG-IP enforces) | Case-sensitive (BIG-IP enforces) |

### Error Handling

| Aspect | Bash | PowerShell |
|--------|------|------------|
| Global mode | `set -euo pipefail` | Per-call `-ErrorAction Stop` with try/catch |
| Safe fallback | `\|\| true` on handled operations | try/catch blocks with explicit error returns |
| HTTP code extraction | curl `-w "%{http_code}"` with response splitting | Exception `.Response.StatusCode` property |

### Script Structure

| Aspect | Bash | PowerShell |
|--------|------|------------|
| Lines | ~5,070 | ~3,230 |
| Functions | 111 | 87 |
| Inline if expressions | `if [...]; then ...; fi` (statement) | `$(if (...) {...} else {...})` (subexpression, required for PS 5.1) |
| Function output | stdout echo with pipe/capture | Return values (hashtables, arrays, booleans) |
| Color output | ANSI escape sequences | `Write-Host -ForegroundColor` |
