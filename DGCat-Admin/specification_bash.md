# DGCat-Admin v4.0 — Technical Specification

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

---

## 1. System Overview

DGCat-Admin is a Bash script (approximately 5,000 lines) that manages LTM internal datagroups and custom URL categories on F5 BIG-IP systems. It communicates exclusively through the iControl REST API over HTTPS. All operations are performed through a menu-driven interactive interface.

### Dependencies

The tool requires two external utilities:

- **curl** — HTTP client for REST API communication
- **jq** — JSON parser for API response processing

Both are validated at startup. The tool exits if either is unavailable.

### Execution Environment

The script runs with `set -euo pipefail`:

- `-e`: Exits on any unhandled non-zero return code
- `-u`: Exits on use of undefined variables
- `-o pipefail`: Pipeline return code reflects the last non-zero exit in the chain

Critical operations that may return non-zero under normal conditions (pre-deploy validation, deploy execution) are explicitly handled with `|| true` to prevent unintended script termination.

---

## 2. Communication Model

### API Request Handling

All API communication passes through a single base function (`api_request`) which constructs and executes curl commands. This function:

- Builds the request URL from the configured host and the endpoint path
- Authenticates using HTTP Basic Authentication via curl's `-u` flag
- Sets `Content-Type: application/json` on all requests
- Appends `-w "\n%{http_code}"` to capture the HTTP response code
- Suppresses SSL certificate verification (`-sk`)
- Redirects curl stderr to `/dev/null`
- Splits the response into body (`API_RESPONSE`) and status code (`API_HTTP_CODE`)
- Returns 0 for HTTP 2xx responses, 1 for all others

Four wrapper functions provide shorthand for specific HTTP methods: `api_get`, `api_post`, `api_patch`, `api_delete`. All route through `api_request`.

### API Endpoints Used

The tool accesses eight distinct API endpoints. A complete reference including HTTP methods, calling functions, request/response formats, and caching behavior is provided in [Section 14: API Endpoint Reference](#14-api-endpoint-reference).

---

## 3. Session Lifecycle

### Startup Sequence

1. Welcome screen displayed. User selects connect or exit.
2. Backup directory created if it does not exist.
3. Session timestamp and log file initialized.
4. Pre-flight checks execute in this order:
   a. curl and jq availability verified.
   b. Partition list parsed from configuration.
   c. Fleet configuration loaded from `fleet.conf` (if file exists).
   d. Connection established (host selection, credential entry, connection test).
   e. Each configured partition validated against the target BIG-IP via API. Results cached.
   f. Backup directory write access verified.
   g. URL category database availability checked via API. Result cached.
5. Main menu loop begins.

### Session Termination

Selecting exit from the main menu logs the session end timestamp and returns to the startup sequence. The user can connect to a different device or exit the tool entirely.

### Host Selection

If a fleet configuration is loaded, fleet hosts are displayed as numbered options at the connection prompt. The input field accepts either a fleet host number or a manually entered hostname/IP address. Entering `0` exits the tool. This is a single-prompt interface — there is no separate menu for manual entry.

---

## 4. Input Data Processing

### CSV Parsing

CSV files are parsed line by line with the following processing:

1. **Blank lines** are skipped.
2. **Comment lines** (lines where the first non-whitespace character is `#`) are skipped.
3. **Leading and trailing whitespace** is trimmed from each line.
4. Lines are split on the first comma. The first field becomes the key; everything after the first comma becomes the value.
5. Lines with empty keys after trimming are skipped with a warning.

Two parsing modes are supported:

- **Keys only**: The first column is extracted as the key. Remaining columns are discarded. Values are set to empty strings.
- **Keys and values**: The first column is the key. Everything after the first comma is the value.

### Line Ending Conversion

Before parsing, CSV files are checked for Windows line endings (CRLF). Detection uses two methods: the `file` command's CRLF detection and a direct `grep` for `\r` bytes.

If Windows line endings are detected:

1. A temporary copy of the file is created in `/var/tmp`.
2. Carriage return bytes (`\r`) are stripped using `tr -d '\r'`.
3. Parsing proceeds on the converted copy.
4. The temporary file is deleted after processing.

The original file is never modified.

### Type Validation

After parsing, the tool analyzes all keys against the target datagroup type:

- **Address validation**: Keys are tested against regex patterns for IPv4 addresses, IPv4 CIDR notation, and IPv6 addresses.
- **Integer validation**: Keys are tested for digits only, with optional leading minus.
- **String validation**: No format restrictions.

The analysis produces a mismatch count and percentage. If mismatches are detected, the tool displays a warning identifying the expected type, the detected type of the mismatched entries, and the mismatch percentage. The operator is prompted to continue or abort. Proceeding with mismatched types may result in API errors from the BIG-IP.

### Early Type Detection

Before asking the operator to select a parsing mode (keys only vs keys and values), the tool scans the first column of the CSV and classifies each entry as address, integer, or other. If all entries are of a type that contradicts the selected datagroup type (for example, all entries are IP addresses but the datagroup type is string), a warning is displayed before parsing begins.

### File Preview

Before parsing, the tool displays the first 5 data lines (configurable via `PREVIEW_LINES`) of the CSV file along with the total data line count. Comment and blank lines are excluded from the preview.

---

## 5. Datagroup Operations

### Data Model

Datagroups contain records consisting of a key and an optional value. The BIG-IP API represents records as a JSON array:

```json
{"records": [{"name": "key1", "data": "value1"}, {"name": "key2"}]}
```

Records without values omit the `data` field.

### Record Serialization

Internal arrays of keys and values are serialized to JSON using jq. Each key-value pair is output as a pipe-delimited line (`key|value`), which jq parses into JSON objects. Empty values result in objects with only the `name` field.

### Write Operations — Full Replace

All datagroup write operations use the `PATCH` method against the datagroup endpoint with a complete `records` array. This is an atomic replace-all operation — the BIG-IP replaces the entire record set with the provided array in a single transaction. There is no incremental add or delete API for internal datagroup records.

This applies to:

- **CSV Import (overwrite mode)**: The parsed CSV contents become the complete record set.
- **CSV Import (merge mode)**: Existing records are read from the BIG-IP, merged with CSV records in memory (deduplicating by key, with CSV values overwriting existing values for matching keys), and the merged result is written as a full replace.
- **Editor apply (`w`)**: The working array contents become the complete record set.
- **Fleet deploy (full replace mode)**: The source device's record set is written to each target as a full replace.

### Write Operations — Fleet Deploy Merge

In merge mode, fleet deployment performs the following per target host:

1. Read current records from the target via `GET`.
2. Parse the response into a JSON array.
3. Remove records whose keys appear in the deletions list using jq's `map(select(...))`.
4. Append records from the additions list.
5. Deduplicate by key using jq's `unique_by(.name)`.
6. Write the merged result as a full replace via `PATCH`.

The merge is computed independently per target host. Each target's existing records are preserved except for explicit deletions and additions.

### Creation

New datagroups are created via `POST` with a name, partition, and type. The type must be one of: `string`, `ip` (address), or `integer`. After creation, records are applied via a separate `PATCH` operation.

### Deletion

Datagroup deletion uses the `DELETE` method. A backup is created before deletion. The operator must type `DELETE` (case-sensitive) to confirm.

---

## 6. URL Category Operations

### Data Model

URL categories contain URL entries, each with a name and a type. The BIG-IP API represents entries as a JSON array:

```json
{"urls": [{"name": "https://example.com/", "type": "exact-match"}]}
```

The type field is either `exact-match` or `glob-match`. Entries containing the `*` character are classified as `glob-match`; all others are classified as `exact-match`.

### Domain-to-URL Conversion

Input domains are converted to F5 URL category format:

1. Any existing `http://` or `https://` protocol prefix is stripped.
2. Trailing path components after the first `/` are stripped.
3. A leading dot (`.example.com`) is converted to a wildcard prefix (`*.example.com`).
4. The `https://` prefix and trailing `/` are added, producing the final format: `https://example.com/` or `https://*.example.com/`.

### Write Operations — Full Replace

The `PATCH` method with a complete `urls` array replaces all entries atomically. This is used for:

- **CSV Import (overwrite mode)**
- **Fleet deploy (full replace mode)**

### Write Operations — Record-Level

For operations where only specific entries change, the tool uses record-level operations:

**Addition**: The current URL list is read via `GET`. New entries are appended to the existing array. The combined array is deduplicated by name using jq's `unique_by(.name)`. The result is written via `PATCH`.

**Deletion**: The current URL list is read via `GET`. Entries matching the deletion list are filtered out using jq's `map(select(...))`. The filtered result is written via `PATCH`.

Record-level operations are used for:

- **Editor apply (`w`)**: Additions and deletions computed from the diff between the original state and the working state are applied independently. Only changed entries are sent.
- **Fleet deploy (merge mode)**: Deletions are applied first via the delete operation, then additions are applied via the add operation.

### CSV Import Merge

For URL category CSV import in merge mode, the tool:

1. Reads the existing URL list from the BIG-IP.
2. Converts each CSV domain to URL format.
3. Filters the converted list to exclude entries that already exist on the BIG-IP.
4. If no new entries remain, reports this and exits.
5. Adds only the new entries via the record-level add operation.

### Creation

New URL categories are created via `POST` with a name, display name, default action (`allow`, `block`, or `confirm`), and initial URL array.

### Deletion

URL category deletion uses the `DELETE` method. A backup is created before deletion. The operator must type `DELETE` (case-sensitive) to confirm.

---

## 7. Editor Data Model

### State Management

When the editor opens, the current state of the target object is fetched from the BIG-IP and loaded into two parallel arrays:

- **Working arrays** (`working_keys`, `working_values`): Modified by the operator during the session.
- **Original arrays** (`original_keys`, `original_values`): Snapshot of the state at load time. Used for change detection.

All editor operations (add, delete, pattern delete) modify the working arrays only. The original arrays are read-only until changes are successfully applied, at which point the original arrays are updated to match the working arrays.

### Change Detection

The `has_pending_changes` function compares working and original arrays. It returns true if:

- The arrays differ in length, or
- Any element at the same index differs between working and original.

### Change Analysis

When applying changes or deploying, the tool computes additions and deletions:

- **Additions**: Keys present in the working arrays but not in the original arrays.
- **Deletions**: Keys present in the original arrays but not in the working arrays.

For fleet deployment, these lists are computed using associative array lookups for O(n) performance.

### Apply Behavior

**Datagroups**: The complete working array is serialized to JSON and sent as a full replace via `PATCH`. This is the same atomic replace-all operation used by CSV import.

**URL categories**: Only the computed additions and deletions are sent. Deletions are applied first via the record-level delete operation, followed by additions via the record-level add operation. Entries that were not modified are not transmitted.

### Deploy Without Pending Changes

If the operator initiates a fleet deploy with no pending changes (working arrays match original arrays), the tool prompts for confirmation and proceeds with full replace mode. This supports the use case where the operator has already applied changes to the current device and wants to replicate the current state to the fleet.

---

## 8. Fleet Deployment

### Configuration

Fleet hosts are defined in a plain text file (`fleet.conf`) located in the backup directory. Each line contains a site identifier and hostname or IP address separated by a pipe character. Site identifiers must match `^[a-zA-Z0-9_-]+$`. Comment lines and blank lines are ignored.

The file is parsed once at session start into three parallel arrays: `FLEET_SITES`, `FLEET_HOSTS`, and `FLEET_UNIQUE_SITES`.

### Deployment Execution Order

Fleet deployment proceeds in three sequential phases:

**Phase 1: Pre-deploy validation.** Before any changes are made to any device, the tool connects to each target host and performs the following checks:

1. Test API connectivity using the current session credentials.
2. Verify the target object (datagroup or URL category) exists on the host.
3. Create a backup of the target object's current state.

Hosts that fail connectivity are marked as `FAIL`. Hosts where the target object does not exist are marked as `SKIP`. Hosts that pass all checks are marked as `OK`.

Results are displayed to the operator with counts of ready, skipped, and failed hosts. The operator is prompted to proceed or abort. If the operator aborts, no changes have been made to any device.

**Phase 2: Apply to current device.** The tool applies changes to the device the operator is connected to. A backup is created first. If the apply fails, the operator is prompted to continue to fleet deployment or abort.

**Phase 3: Deploy to fleet.** The tool iterates through validated fleet hosts and applies changes to each one. Results are displayed in real time.

### Deployment Modes

**Full Replace (datagroups):** The complete record set from the source device is sent as a `PATCH` with the full `records` array. The target's existing records are completely overwritten.

**Full Replace (URL categories):** The complete URL list from the source device is sent as a `PATCH` with the full `urls` array. The target's existing URLs are completely overwritten.

**Merge (datagroups):** For each target host:
1. Current records are read from the target via `GET`.
2. Records matching the deletions list are removed from the target's record set.
3. Records from the additions list are appended.
4. The result is deduplicated by key.
5. The merged result is written via `PATCH` as a full replace.

**Merge (URL categories):** For each target host:
1. Deletions are applied via the record-level delete operation (read current state, filter out deletions, write back).
2. Additions are applied via the record-level add operation (read current state, append additions, deduplicate, write back).

### Systemic Failure Detection

During fleet deployment, the tool tracks consecutive errors with identical error messages. If the same error occurs on three consecutive hosts, the tool displays a warning and prompts the operator to continue or stop. If the operator chooses to continue, the consecutive error counter resets. If the operator chooses to stop, remaining hosts are not processed.

### Configuration Save

After each successful apply (both current device and each fleet host), the tool sends a `POST` to `/mgmt/tm/sys/config` with `{"command":"save"}` to persist the running configuration to disk.

### Deploy Scope

The operator selects deployment scope after the deployment mode:

- **Entire topology**: All fleet hosts except the currently connected host.
- **Specific site**: All fleet hosts at a selected site, excluding the currently connected host.

The currently connected device is always excluded from the fleet target list and handled separately in Phase 2.

### Deploy Summary

After all hosts are processed, a summary table displays each host's status:

- `OK`: Changes applied and configuration saved.
- `FAIL`: An error occurred during validation, apply, or save.
- `SKIP`: The target object does not exist on the host.
- `CURRENT`: The currently connected device (shown with its Phase 2 result).

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

Backup files are CSV with a comment header containing metadata:

```
# Datagroup Backup: /Common/my-datagroup
# Partition: Common
# Type: string
# Created: Thu Mar 27 14:30:52 UTC 2026
# Format: key,value
#
example.com,Production
staging.example.com,Staging
```

URL category backups contain one URL per line with a comment header.

### File Naming

Local backups: `{partition}_{name}_internal_{timestamp}.csv`

URL category backups: `urlcat_{name}_{timestamp}.csv`

Fleet backups are stored in site subdirectories: `{site}/{hostname}_{partition}_{name}_{timestamp}.csv`

### Retention

Backup files are grouped by object name. When the count for a given object exceeds the configured `MAX_BACKUPS` limit (default: 30), the oldest files are deleted. Files are sorted by modification time in descending order; those beyond the limit are removed.

### Restoration

Backup files are standard CSV files compatible with the tool's CSV import function. To restore, the operator uses the Create/Update from CSV option and selects overwrite mode. The comment header is ignored during import.

---

## 10. Object Protection

### Protected Datagroups

Three system datagroups are designated as protected:

- `private_net`
- `images`
- `aol`

The `is_protected_datagroup` function checks the datagroup name against this list. Protection is enforced at four points:

1. **CSV import**: If the name matches a protected datagroup, the operation is blocked with an error message.
2. **Editor entry**: If the name matches a protected datagroup, the editor refuses to open.
3. **Delete**: If the name matches a protected datagroup, deletion is blocked with an error message.
4. **Datagroup listing**: Protected datagroups are marked with a `[SYSTEM]` label in listing displays.

### Confirmation Requirements

| Operation | Confirmation Required |
|-----------|----------------------|
| Overwrite existing object (CSV import) | Selection of "Overwrite" option |
| Delete datagroup or URL category | Type `DELETE` (case-sensitive) |
| Apply editor changes | Type `yes` |
| Fleet deploy | Type `DEPLOY` (case-sensitive) |
| Continue without backup | Type `yes` (default: no) |
| Continue after current device apply failure | Type `yes` (default: no) |
| Continue after systemic fleet failure | Type `yes` (default: no) |
| Deploy with no pending changes | Type `yes` (default: no) |

All confirmation prompts default to the safe action (no/cancel) when the operator presses Enter without input.

### Object Existence Validation

Fleet deployment does not create objects on target hosts. During pre-deploy validation, the tool checks whether the target datagroup or URL category exists on each host. Hosts where the object does not exist receive a `SKIP` status and are not processed during deployment.

---

## 11. Error Handling

### Script-Level

The `set -euo pipefail` directive causes the script to exit on unhandled errors. Operations that may return non-zero under normal conditions are explicitly handled:

- Pre-deploy validation calls: `|| true` (validation failures are expected when hosts are unreachable)
- Deploy execution calls: `|| true` (partial fleet failures are handled by the summary)
- Backup cleanup: `|| true` (cleanup failure is non-critical)
- Partition checks during listing: `|| true` (missing partitions are logged and skipped)

### API-Level

The `api_request` function captures the HTTP status code from every API call. Non-2xx responses return non-zero. Callers check the return code and the `API_HTTP_CODE` variable to determine the failure type. Specific HTTP codes trigger specific messages:

- `401`: Authentication failure
- `000`: Connection failure (curl could not reach the host)
- `404`: Object not found
- All others: Generic failure with HTTP code displayed

### Deployment Error Tracking

Fleet deployment tracks:

- **Success count**: Hosts where changes were applied and configuration was saved.
- **Failure count**: Hosts where any step failed (connectivity, apply, or save).
- **Skip count**: Hosts where the target object does not exist.
- **Consecutive same-error count**: Incremented when the same error message occurs on consecutive hosts. Reset when a different error occurs or when a host succeeds. At three consecutive identical errors, the operator is prompted.

---

## 12. Credential Handling

### Input

Credentials are entered interactively at session start:

- Username: Standard terminal input via `read -rp`
- Password: Silent input via `read -srp` (no terminal echo)

### Storage

Credentials are stored in shell variables (`REMOTE_USER`, `REMOTE_PASS`) for the duration of the session. They are not written to any file, log, backup, or temporary storage.

### Usage

Credentials are used exclusively in the `api_request` function, where they are passed to curl's `-u` flag as a local variable (`auth`). The `auth` variable is scoped to the function and does not persist after the function returns.

### Reset

On session end (return to welcome screen), `REMOTE_USER` and `REMOTE_PASS` are set to empty strings.

### Logging

The session log records the target hostname, operation timestamps, and operation outcomes. Credentials, usernames, and API response bodies are not written to the log.

---

## 13. API Efficiency

### Session Caching

Two caches are populated during pre-flight checks and persist for the session duration:

**Partition cache** (`PARTITION_CACHE`): An associative array mapping partition names to `valid` or `invalid`. The `partition_exists` function checks this cache before making an API call. On a cache miss, the API is queried and the result is stored. Since every datagroup listing operation calls `partition_exists` for each configured partition, this eliminates repeated `GET /mgmt/tm/auth/partition/{name}` calls throughout the session.

**URL category database cache** (`URL_CATEGORY_DB_CACHED`): A string variable set to `yes` or `no`. The `url_category_db_available` function returns the cached value without an API call. Without caching, this check would issue a `GET /mgmt/tm/sys/url-db/url-category` (which returns the full category list) every time the operator enters a URL category menu option.

### Cache Reset

Both caches are cleared when the session ends and the operator returns to the welcome screen. A new connection to a different BIG-IP starts with empty caches.

### Fleet Deployment API Calls

Per fleet host, the minimum API call count for a deployment is:

**Pre-deploy validation (Phase 1):**

| Call | Purpose |
|------|---------|
| `GET /mgmt/tm/sys/version` | Connectivity test |
| `GET /mgmt/tm/ltm/data-group/internal/~{p}~{n}` or `GET /mgmt/tm/sys/url-db/url-category/~Common~{n}` | Object existence |
| `GET` (same endpoint) | Read current state for backup |

**Deploy (Phase 3, full replace):**

| Call | Purpose |
|------|---------|
| `PATCH` (object endpoint) | Apply records/URLs |
| `POST /mgmt/tm/sys/config` | Save configuration |

**Deploy (Phase 3, merge for datagroups):**

| Call | Purpose |
|------|---------|
| `GET` (object endpoint) | Read current target state |
| `PATCH` (object endpoint) | Apply merged records |
| `POST /mgmt/tm/sys/config` | Save configuration |

**Deploy (Phase 3, merge for URL categories):**

| Call | Purpose |
|------|---------|
| `GET` (object endpoint) | Read current state for delete filtering |
| `PATCH` (object endpoint) | Apply filtered (deletions removed) |
| `GET` (object endpoint) | Read current state for add merging |
| `PATCH` (object endpoint) | Apply merged (additions added) |
| `POST /mgmt/tm/sys/config` | Save configuration |

---

## 14. API Endpoint Reference

This section documents every iControl REST API endpoint the tool calls, including the HTTP methods used, the functions that make the call, the request and response formats, and any caching behavior.

---

### 14.1 `/mgmt/tm/sys/version`

**Method:** GET

**Purpose:** Connection testing and BIG-IP version detection.

**Called by:**

| Function | Context |
|----------|---------|
| `setup_remote_connection` | Initial connection test during session setup |
| `get_version_remote` | Version retrieval for logging |
| `test_host_connection` | Fleet pre-deploy validation per host |

**Request body:** None.

**Response fields used:** `.entries[].nestedStats.entries.Version.description` — extracted via jq to obtain the TMOS version string.

**Failure handling:** HTTP 401 is reported as authentication failure. HTTP 000 (curl connection failure) is reported as a connectivity error. All other non-2xx codes are reported with the HTTP status code.

**Caching:** None. This endpoint is called once per connection and once per fleet host during validation. Each call serves as a live connectivity test.

---

### 14.2 `/mgmt/tm/sys/config`

**Method:** POST

**Purpose:** Persist the running configuration to disk.

**Called by:**

| Function | Context |
|----------|---------|
| `save_config_remote` | After any successful write operation when the operator confirms save |

**Request body:**

```json
{"command": "save"}
```

**Response fields used:** None. Success is determined by HTTP 2xx response.

**Caching:** None. Each call triggers a configuration save.

---

### 14.3 `/mgmt/tm/auth/partition/{partition}`

**Method:** GET

**Purpose:** Validate that a configured partition exists on the target BIG-IP.

**Called by:**

| Function | Context |
|----------|---------|
| `partition_exists_remote` | Called through the `partition_exists` dispatcher during preflight and datagroup listing |

**Request body:** None.

**Response fields used:** None. Existence is determined by HTTP 2xx (exists) vs 404 (does not exist).

**Caching:** Results are cached in the `PARTITION_CACHE` associative array for the session duration. The API is queried only on cache miss. During a typical session, each partition is queried once during preflight. All subsequent calls return the cached result.

---

### 14.4 `/mgmt/tm/ltm/data-group/internal?$filter=partition eq {partition}`

**Method:** GET

**Purpose:** List all internal datagroups in a specific partition.

**Called by:**

| Function | Context |
|----------|---------|
| `get_internal_datagroup_list_remote` | Populating datagroup selection lists for view, edit, export, and delete operations |

**Request body:** None.

**Response fields used:** `.items[]` — filtered to exclude datagroups inside application service folders (paths containing `.app/`). Each item's `.partition` and `.name` fields are extracted.

**Caching:** None. This endpoint is called each time a datagroup list is displayed.

---

### 14.5 `/mgmt/tm/ltm/data-group/internal/~{partition}~{name}`

**Methods:** GET, PATCH, DELETE

**Purpose:** Read, modify, or delete a specific internal datagroup.

**Called by:**

| Function | Method | Context |
|----------|--------|---------|
| `internal_datagroup_exists_remote` | GET | Check if a datagroup exists by name |
| `get_internal_datagroup_type_remote` | GET | Retrieve the datagroup type (string, ip, integer) |
| `get_internal_datagroup_records_remote` | GET | Read all records as key/value pairs |
| `apply_internal_datagroup_records_remote` | PATCH | Replace all records (atomic full replace) |
| `delete_internal_datagroup_remote` | DELETE | Delete the datagroup |

**GET response fields used:**

- `.type` — datagroup type (string, ip, integer)
- `.records[].name` — record key
- `.records[].data` — record value (optional, absent for key-only records)

**PATCH request body:**

```json
{"records": [{"name": "key1", "data": "value1"}, {"name": "key2"}]}
```

The `records` array replaces the entire record set atomically. Records without values omit the `data` field.

**DELETE request body:** None.

**Caching:** None. Each operation queries or modifies the live object.

---

### 14.6 `/mgmt/tm/ltm/data-group/internal`

**Method:** POST

**Purpose:** Create a new internal datagroup.

**Called by:**

| Function | Context |
|----------|---------|
| `create_internal_datagroup_remote` | Creating a new datagroup during CSV import when the object does not exist |

**Request body:**

```json
{"name": "dg-name", "partition": "Common", "type": "string"}
```

The `type` field accepts `string`, `ip`, or `integer`.

**Response fields used:** None. Success is determined by HTTP 2xx response.

**Caching:** None.

---

### 14.7 `/mgmt/tm/sys/url-db/url-category`

**Method:** GET, POST

**Purpose:** List all URL categories (GET), check URL database availability (GET), or create a new URL category (POST).

**Called by:**

| Function | Method | Context |
|----------|--------|---------|
| `get_url_category_list_remote` | GET | Populating category selection lists for edit, export, and delete operations |
| `url_category_db_available` | GET | Pre-flight check to determine if the URL filtering module is provisioned |
| `create_url_category_remote` | POST | Creating a new URL category during CSV import |

**GET response fields used:** `.items[].name` — extracted and sorted to produce the category list.

**POST request body:**

```json
{
  "name": "category-name",
  "displayName": "category-name",
  "defaultAction": "allow",
  "urls": [
    {"name": "https://example.com/", "type": "exact-match"},
    {"name": "https://*.example.com/", "type": "glob-match"}
  ]
}
```

The `defaultAction` field accepts `allow`, `block`, or `confirm`. The `type` field for each URL is `exact-match` for URLs without wildcards and `glob-match` for URLs containing the `*` character.

**Caching:** The GET result for availability checking is cached in `URL_CATEGORY_DB_CACHED` for the session duration. The API is queried once during preflight. All subsequent `url_category_db_available` calls return the cached result. Category list queries (for selection menus) are not cached and query the API each time.

---

### 14.8 `/mgmt/tm/sys/url-db/url-category/~Common~{name}`

**Methods:** GET, PATCH, DELETE

**Purpose:** Read, modify, or delete a specific URL category.

**Called by:**

| Function | Method | Context |
|----------|--------|---------|
| `url_category_exists_remote` | GET | Check if a URL category exists by name |
| `get_url_category_entries_remote` | GET | Read all URL entries |
| `get_url_category_count_remote` | GET | Count URL entries |
| `modify_url_category_add_remote` | GET + PATCH | Read current URLs, merge new entries, write back |
| `modify_url_category_delete_remote` | GET + PATCH | Read current URLs, filter out deletions, write back |
| `modify_url_category_replace_remote` | PATCH | Replace all URLs (atomic full replace) |
| `delete_url_category_remote` | DELETE | Delete the URL category |

**GET response fields used:**

- `.urls[].name` — URL entry name (e.g., `https://example.com/`)
- `.urls[]` — full URL array used as input for merge and filter operations

**PATCH request body (full replace):**

```json
{"urls": [{"name": "https://example.com/", "type": "exact-match"}]}
```

The `urls` array replaces the entire URL set atomically.

**PATCH request body (add — merge operation):**

The function reads the current `.urls` array via GET, appends new entries, deduplicates by name using `unique_by(.name)`, and sends the merged array via PATCH.

**PATCH request body (delete — filter operation):**

The function reads the current `.urls` array via GET, filters out entries whose names appear in the deletion list, and sends the filtered array via PATCH.

**DELETE request body:** None.

**Caching:** None. Each operation queries or modifies the live object.

**Note on record-level operations:** The BIG-IP URL category API does not support native add or delete operations for individual URL entries. Both `modify_url_category_add_remote` and `modify_url_category_delete_remote` implement record-level semantics by performing a read-modify-write cycle: GET the current state, transform it in memory, and PATCH the result. Each record-level operation therefore consists of two API calls (one GET and one PATCH).
