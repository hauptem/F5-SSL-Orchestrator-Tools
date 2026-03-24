#!/bin/bash
# =============================================================================
# DGCat-Admin - F5 BIG-IP DG/CAT Administration Tool
# =============================================================================
# Version:  1.0
# Created by: Eric Haupt
#
# Requirements: BIG-IP TMOS 17.x or higher
#
# PURPOSE:
#   Menu-driven tool for managing LTM datagroups and SWG URL  Categories used 
#   in SSL Orchestrator policies. Supports both INTERNAL and EXTERNAL 
#   datagroups, bulk import/export via CSV files, backup before modifications,
#   and type validation to prevent configuration errors.
#
# USAGE:
#   chmod +x dgcat-admin.sh
#   ./dgcat-admin.sh
#
# https://github.com/hauptem/F5-SSL-Orchestrator-Tools
#
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# Backup settings
BACKUP_DIR="/shared/tmp/dgcat-admin-backups"
MAX_BACKUPS=30

# External datagroup settings
# Temp directory for external datagroup files during import
EXTERNAL_TEMP_DIR="/var/tmp"
# Default separator for external datagroup files
EXTERNAL_SEPARATOR=":="

# Logging
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOGFILE="${BACKUP_DIR}/dgcat-admin-${TIMESTAMP}.log"

# Partitions to manage (comma-separated, no spaces)
# Add additional partitions as needed, e.g., "Common,SSLO_Partition,DMZ"
# WARNING: Only include partitions you intend to manage with this tool
PARTITIONS="Common"

# Protected system datagroups - DO NOT MODIFY
# These are pre-configured BIG-IP datagroups that must not be modified or deleted
# Attempting to change these can produce adverse system results
PROTECTED_DATAGROUPS=(
    "private_net"
    "images"
    "aol"
)

# CSV preview lines
PREVIEW_LINES=5

# Parsed partition array (populated at runtime)
declare -a PARTITION_LIST

# Datagroup class constants
DG_CLASS_INTERNAL="internal"
DG_CLASS_EXTERNAL="external"

# =============================================================================
# COLORS
# =============================================================================

CYAN='\033[36m'
YELLOW='\033[33m'
RED='\033[31m'
GREEN='\033[32m'
WHITE='\033[37m'
NC='\033[0m'

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log() {
    echo -e "$1" | tee -a "${LOGFILE}"
}

log_section() {
    log ""
    log "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    log "${WHITE}  $1${NC}"
    log "${CYAN}════════════════════════════════════════════════════════════════${NC}"
}

log_info() {
    log "${WHITE}  [INFO]  $1${NC}"
}

log_ok() {
    log "${GREEN}  [ OK ]${NC}  ${WHITE}$1${NC}"
}

log_warn() {
    log "${YELLOW}  [WARN]${NC}  ${WHITE}$1${NC}"
}

log_error() {
    log "${RED}  [FAIL]${NC}  ${WHITE}$1${NC}"
}

log_step() {
    log "${WHITE}  [....] $1${NC}"
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

press_enter_to_continue() {
    echo ""
    read -rp "  Press Enter to continue..."
}

# Validate if a string looks like an integer
is_integer_format() {
    local entry="$1"
    # Match digits only (optionally with leading minus for negative)
    if [[ "${entry}" =~ ^-?[0-9]+$ ]]; then
        return 0
    fi
    return 1
}

# Validate if a string looks like an IP address or CIDR subnet
is_address_format() {
    local entry="$1"
    # Match IPv4 address or CIDR notation
    if [[ "${entry}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        return 0
    fi
    # Match IPv6 (simplified check)
    if [[ "${entry}" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]] && [[ "${entry}" == *":"* ]]; then
        return 0
    fi
    return 1
}

# Check if a datagroup is a protected system datagroup
# Returns 0 (true) if protected, 1 (false) if safe to modify
is_protected_datagroup() {
    local dg_name="$1"
    for protected in "${PROTECTED_DATAGROUPS[@]}"; do
        if [ "${dg_name}" == "${protected}" ]; then
            return 0
        fi
    done
    return 1
}

# Convert Windows line endings (\r\n) to Unix (\n)
# This is critical for external datagroup files - BIG-IP won't import Windows-formatted files
convert_line_endings() {
    local filepath="$1"
    if file "${filepath}" | grep -q "CRLF"; then
        log_info "Converting Windows line endings (CRLF) to Unix (LF)..."
        tr -d '\r' < "${filepath}" > "${filepath}.tmp" && mv "${filepath}.tmp" "${filepath}"
        return 0
    fi
    return 0
}

# Check if file has Windows line endings
has_windows_line_endings() {
    local filepath="$1"
    if file "${filepath}" | grep -q "CRLF" || grep -q $'\r' "${filepath}" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Format data for external datagroup file (F5 external format)
# Input: key, value, type
# Output formats by type:
#   ip/address: "network 10.0.0.0/8," or "host 10.0.0.1,"
#   integer:    "12345,"
#   string:     "\"example.com\","
format_external_record() {
    local key="$1"
    local value="$2"
    local dg_type="$3"
    
    # Escape quotes in key and value
    key=$(echo "${key}" | sed 's/"/\\"/g')
    value=$(echo "${value}" | sed 's/"/\\"/g')
    
    if [ "${dg_type}" == "ip" ] || [ "${dg_type}" == "address" ]; then
        # Address type: requires network/host prefix, no quotes
        local prefix="host"
        if [[ "${key}" == *"/"* ]]; then
            prefix="network"
        fi
        if [ -n "${value}" ]; then
            echo "${prefix} ${key} := \"${value}\","
        else
            echo "${prefix} ${key},"
        fi
    elif [ "${dg_type}" == "integer" ]; then
        # Integer type: no quotes around key
        if [ -n "${value}" ]; then
            echo "${key} := \"${value}\","
        else
            echo "${key},"
        fi
    else
        # String type: quotes around key
        if [ -n "${value}" ]; then
            echo "\"${key}\" := \"${value}\","
        else
            echo "\"${key}\","
        fi
    fi
}

# Parse external datagroup file format back to key|value
# Input: line from external datagroup file
# Output: key|value
# Handles formats:
#   network 10.0.0.0/8,
#   host 10.0.0.1 := "value",
#   "example.com" := "value",
#   "example.com",
parse_external_record() {
    local line="$1"
    
    # Remove trailing comma and whitespace
    line=$(echo "${line}" | sed 's/,\s*$//; s/^\s*//; s/\s*$//')
    
    # Skip empty lines and comments
    [ -z "${line}" ] && return
    [[ "${line}" =~ ^# ]] && return
    
    # Strip network/host prefix for IP types
    line=$(echo "${line}" | sed 's/^network\s\+//; s/^host\s\+//')
    
    local key=""
    local value=""
    
    if [[ "${line}" == *":="* ]]; then
        # Has key := value format
        key=$(echo "${line}" | sed 's/\s*:=.*//; s/^"//; s/"$//')
        value=$(echo "${line}" | sed 's/.*:=\s*//; s/^"//; s/"$//')
    else
        # Key only
        key=$(echo "${line}" | sed 's/^"//; s/"$//')
        value=""
    fi
    
    echo "${key}|${value}"
}

# Ensure backup directory exists
ensure_backup_dir() {
    if [ ! -d "${BACKUP_DIR}" ]; then
        mkdir -p "${BACKUP_DIR}" 2>/dev/null || {
            log_error "Could not create backup directory: ${BACKUP_DIR}"
            return 1
        }
        log_ok "Created backup directory: ${BACKUP_DIR}"
    fi
}

# Cleanup old backups beyond retention limit
cleanup_old_backups() {
    local dg_name="$1"
    local backup_files
    backup_files=$(ls -1t "${BACKUP_DIR}/${dg_name}_"*.csv 2>/dev/null || true)
    
    if [ -n "${backup_files}" ]; then
        local count=0
        while IFS= read -r file; do
            count=$((count + 1))
            if [ ${count} -gt ${MAX_BACKUPS} ]; then
                rm -f "${file}" 2>/dev/null || true
            fi
        done <<< "${backup_files}"
    fi
}

# Strip partition prefix from datagroup name (e.g., /Common/mygroup -> mygroup)
strip_partition_prefix() {
    echo "$1" | sed 's/^\/[^/]*\///g'
}

# List datagroups in a partition with optional system marker
# Args: partition, show_system_marker (true/false)
# Returns: 0 if datagroups found, 1 if none
list_partition_datagroups() {
    local partition="$1"
    local show_system="${2:-false}"
    
    local datagroups
    datagroups=$(get_all_datagroup_list | grep "^${partition}|" || true)
    
    if [ -z "${datagroups}" ]; then
        log_info "No datagroups found in partition '${partition}'."
        return 1
    fi
    
    echo "" >&2
    echo -e "${WHITE}  [INFO]  Available datagroups in partition '${partition}':${NC}" >&2
    echo -e "  ${CYAN}────────────────────────────────────────────────────────────${NC}" >&2
    
    while IFS='|' read -r p name class; do
        [ -z "${name}" ] && continue
        local marker=""
        if [ "${show_system}" == "true" ] && is_protected_datagroup "${name}"; then
            marker="${YELLOW} [SYSTEM]${NC}"
        fi
        printf "    ${WHITE}%-35s${NC} ${WHITE}(%s)${NC}%b\n" "${name}" "${class}" "${marker}" >&2
    done <<< "${datagroups}"
    
    echo -e "  ${CYAN}────────────────────────────────────────────────────────────${NC}" >&2
    return 0
}

# Prompt user to select a datagroup from a partition
# Args: partition, prompt_text
# Outputs: name|class on success, empty on failure/cancel
# Returns: 0 on success, 1 on failure/cancel
select_datagroup() {
    local partition="$1"
    local prompt="${2:-Enter datagroup name}"
    
    # List available datagroups
    if ! list_partition_datagroups "${partition}" "true"; then
        return 1
    fi
    
    echo "" >&2
    local dg_name
    read -rp "  ${prompt}: " dg_name
    
    if [ -z "${dg_name}" ]; then
        echo -e "${YELLOW}  [WARN]${NC}  ${WHITE}No datagroup name provided.${NC}" >&2
        return 1
    fi
    
    # Strip partition prefix if included
    dg_name=$(strip_partition_prefix "${dg_name}")
    
    # Check if exists
    local dg_class
    dg_class=$(datagroup_exists "${partition}" "${dg_name}")
    if [ -z "${dg_class}" ]; then
        echo -e "${RED}  [FAIL]${NC}  ${WHITE}Datagroup '${dg_name}' does not exist in partition '${partition}'.${NC}" >&2
        return 1
    fi
    
    echo "${dg_name}|${dg_class}"
    return 0
}

# Prompt to save configuration
prompt_save_config() {
    echo ""
    local save_choice
    read -rp "  Save configuration? (yes/no) [yes]: " save_choice
    save_choice="${save_choice:-yes}"
    if [ "${save_choice}" == "yes" ]; then
        log_step "Saving configuration..."
        if tmsh save sys config 2>/dev/null; then
            log_ok "Configuration saved."
        else
            log_warn "Could not save configuration. Run 'tmsh save sys config' manually."
        fi
    fi
}

# =============================================================================
# PARTITION FUNCTIONS
# =============================================================================

# Parse the PARTITIONS config string into PARTITION_LIST array
parse_partitions() {
    PARTITION_LIST=()
    IFS=',' read -ra PARTITION_LIST <<< "${PARTITIONS}"
    
    # Trim whitespace from each partition name
    for i in "${!PARTITION_LIST[@]}"; do
        PARTITION_LIST[$i]=$(echo "${PARTITION_LIST[$i]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    done
}

# Check if a partition exists on the system
partition_exists() {
    local partition="$1"
    tmsh list auth partition "${partition}" &>/dev/null
    return $?
}

# Validate all configured partitions exist
validate_partitions() {
    local invalid_count=0
    for partition in "${PARTITION_LIST[@]}"; do
        if ! partition_exists "${partition}"; then
            log_warn "Partition '${partition}' does not exist on this system"
            invalid_count=$((invalid_count + 1))
        fi
    done
    
    if [ ${invalid_count} -gt 0 ]; then
        log_warn "${invalid_count} configured partition(s) not found. They will be skipped."
    fi
    
    return 0
}

# Display partition selection menu and return selected partition
# Returns partition name via echo, empty string if cancelled
select_partition() {
    local prompt="${1:-Select partition}"
    
    if [ ${#PARTITION_LIST[@]} -eq 1 ]; then
        # Only one partition configured, use it automatically
        echo "${PARTITION_LIST[0]}"
        return 0
    fi
    
    echo "" >&2
    echo -e "  ${WHITE}${prompt}:${NC}" >&2
    local i=1
    for partition in "${PARTITION_LIST[@]}"; do
        echo -e "    ${YELLOW}${i})${NC} ${WHITE}${partition}${NC}" >&2
        i=$((i + 1))
    done
    echo -e "    ${YELLOW}0)${NC} ${WHITE}Cancel${NC}" >&2
    echo "" >&2
    
    local choice
    read -rp "  Select [0-$((${#PARTITION_LIST[@]}))] : " choice
    
    if [ "${choice}" == "0" ] || [ -z "${choice}" ]; then
        echo ""
        return 0
    fi
    
    if [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le ${#PARTITION_LIST[@]} ]; then
        echo "${PARTITION_LIST[$((choice - 1))]}"
        return 0
    fi
    
    echo ""
    return 0
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

preflight_checks() {
    log_section "Pre-Flight Checks"

    # Check for root
    if [ "$(id -u)" != "0" ]; then
        log_error "This script must be run as root."
        exit 1
    fi
    log_ok "Running as root"

    # Check for tmsh
    if ! command -v tmsh &>/dev/null; then
        log_error "tmsh not found. This script must be run on a BIG-IP."
        exit 1
    fi
    log_ok "tmsh found"

    # Verify we can query datagroups
    if ! tmsh list ltm data-group internal one-line &>/dev/null; then
        log_error "Cannot query datagroups. Check tmsh access."
        exit 1
    fi
    log_ok "Datagroup access verified"

    # Get TMOS version for logging
    local tmos_version
    tmos_version=$(tmsh show sys version | grep "^\s*Version" | awk '{print $2}' | head -1 2>/dev/null || echo "unknown")
    log_ok "TMOS Version: ${tmos_version}"

    # Ensure backup directory exists
    ensure_backup_dir
    log_ok "Backup/Log directory: ${BACKUP_DIR}"

    # Parse and validate configured partitions
    parse_partitions
    if [ ${#PARTITION_LIST[@]} -eq 0 ]; then
        log_error "No partitions configured. Check PARTITIONS setting."
        exit 1
    fi
    log_ok "Configured partitions: ${PARTITIONS}"
    validate_partitions

    log ""
    log_info "Log file: ${LOGFILE}"
}

# =============================================================================
# DATAGROUP OPERATIONS
# =============================================================================

# Get list of all INTERNAL datagroups from configured partitions
# Returns: partition|name|internal lines
# Note: Excludes datagroups inside application services (.app folders) as those are system-managed
get_internal_datagroup_list() {
    for partition in "${PARTITION_LIST[@]}"; do
        if partition_exists "${partition}"; then
            tmsh list ltm data-group internal "/${partition}/*" one-line 2>/dev/null \
                | grep "^ltm data-group internal" \
                | awk '{print $4}' \
                | while read -r full_path; do
                    local name
                    name=$(echo "${full_path}" | sed "s/^\/${partition}\///g")
                    echo "${partition}|${name}|internal"
                done || true
        fi
    done | sort -t'|' -k1,1 -k2,2
}

# Get list of all EXTERNAL datagroups from configured partitions
# Returns: partition|name|external lines
# Note: Excludes datagroups inside application services (.app folders) as those are system-managed
get_external_datagroup_list() {
    for partition in "${PARTITION_LIST[@]}"; do
        if partition_exists "${partition}"; then
            tmsh list ltm data-group external "/${partition}/*" one-line 2>/dev/null \
                | grep "^ltm data-group external" \
                | awk '{print $4}' \
                | while read -r full_path; do
                    local name
                    name=$(echo "${full_path}" | sed "s/^\/${partition}\///g")
                    echo "${partition}|${name}|external"
                done || true
        fi
    done | sort -t'|' -k1,1 -k2,2
}

# Get combined list of all datagroups (internal and external)
# Returns: partition|name|class lines
get_all_datagroup_list() {
    {
        get_internal_datagroup_list
        get_external_datagroup_list
    } | sort -t'|' -k1,1 -k2,2
}

# Check if INTERNAL datagroup exists in specified partition
internal_datagroup_exists() {
    local partition="$1"
    local dg_name="$2"
    tmsh list ltm data-group internal "/${partition}/${dg_name}" 2>/dev/null | grep -q "data-group internal"
    return $?
}

# Check if EXTERNAL datagroup exists in specified partition
external_datagroup_exists() {
    local partition="$1"
    local dg_name="$2"
    tmsh list ltm data-group external "/${partition}/${dg_name}" 2>/dev/null | grep -q "data-group external"
    return $?
}

# Check if datagroup exists (either internal or external)
# Returns: "internal", "external", or empty string
datagroup_exists() {
    local partition="$1"
    local dg_name="$2"
    
    if internal_datagroup_exists "${partition}" "${dg_name}"; then
        echo "internal"
        return 0
    elif external_datagroup_exists "${partition}" "${dg_name}"; then
        echo "external"
        return 0
    fi
    echo ""
    return 0
}

# Get INTERNAL datagroup type (string, address, integer)
get_internal_datagroup_type() {
    local partition="$1"
    local dg_name="$2"
    tmsh list ltm data-group internal "/${partition}/${dg_name}" 2>/dev/null \
        | grep "^\s*type" \
        | awk '{print $2}' || true
}

# Get EXTERNAL datagroup type (string, ip, integer)
get_external_datagroup_type() {
    local partition="$1"
    local dg_name="$2"
    tmsh list ltm data-group external "/${partition}/${dg_name}" 2>/dev/null \
        | grep "^\s*type" \
        | awk '{print $2}' || true
}

# Get datagroup type for either internal or external
get_datagroup_type() {
    local partition="$1"
    local dg_name="$2"
    local dg_class="$3"
    
    if [ "${dg_class}" == "external" ]; then
        get_external_datagroup_type "${partition}" "${dg_name}"
    else
        get_internal_datagroup_type "${partition}" "${dg_name}"
    fi
}

# Get INTERNAL datagroup records as "key|value" lines
get_internal_datagroup_records() {
    local partition="$1"
    local dg_name="$2"
    local config
    config=$(tmsh list ltm data-group internal "/${partition}/${dg_name}" 2>/dev/null)
    
    # Parse the records section
    # Format is always: key { } or key { data "value" } or "key" { } etc.
    echo "${config}" | awk '
        /records \{/,/^    \}/ {
            # Skip records { and closing }
            if (/records \{/ || /^    \}/) next
            
            # Match lines with { }
            if (/\{.*\}/) {
                line = $0
                # Remove leading whitespace
                gsub(/^[[:space:]]+/, "", line)
                
                # Extract key (everything before { )
                key = line
                gsub(/[[:space:]]*\{.*/, "", key)
                gsub(/"/, "", key)
                
                # Extract value if present (between data and })
                value = ""
                if (line ~ /data /) {
                    value = line
                    gsub(/.*data[[:space:]]+/, "", value)
                    gsub(/[[:space:]]*\}.*/, "", value)
                    gsub(/"/, "", value)
                }
                
                print key "|" value
            }
        }
    '
}

# Get external datagroup file name
get_external_datagroup_file() {
    local partition="$1"
    local dg_name="$2"
    tmsh list ltm data-group external "/${partition}/${dg_name}" 2>/dev/null \
        | grep "external-file-name" \
        | awk '{print $2}' || true
}

# Get EXTERNAL datagroup records as "key|value" lines
# External datagroups store data in sys file data-group
get_external_datagroup_records() {
    local partition="$1"
    local dg_name="$2"
    
    # Get the associated file name
    local file_name
    file_name=$(get_external_datagroup_file "${partition}" "${dg_name}")
    
    if [ -z "${file_name}" ]; then
        return 1
    fi
    
    # The actual file location is in /config/filestore/files_d/{partition}_d/data_group_d/
    # Files have a version suffix (e.g., :Common:myfile_123456_1) so we need to glob
    local filestore_dir="/config/filestore/files_d/${partition}_d/data_group_d"
    local filestore_path
    filestore_path=$(ls -1 "${filestore_dir}/:${partition}:${file_name}"* 2>/dev/null | head -1)
    
    if [ -n "${filestore_path}" ] && [ -f "${filestore_path}" ]; then
        # Parse the external format file
        while IFS= read -r line || [ -n "${line}" ]; do
            [ -z "${line}" ] && continue
            [[ "${line}" =~ ^# ]] && continue
            parse_external_record "${line}"
        done < "${filestore_path}"
    else
        # Alternative: try to list via tmsh edit (this shows content)
        # For now, return empty if we can't find the file
        log_warn "Could not locate external datagroup file: ${file_name}"
        return 1
    fi
}

# Get datagroup records for either internal or external
get_datagroup_records() {
    local partition="$1"
    local dg_name="$2"
    local dg_class="${3:-internal}"
    
    if [ "${dg_class}" == "external" ]; then
        get_external_datagroup_records "${partition}" "${dg_name}"
    else
        get_internal_datagroup_records "${partition}" "${dg_name}"
    fi
}

# Backup a datagroup to CSV file (works for both internal and external)
backup_datagroup() {
    local partition="$1"
    local dg_name="$2"
    local dg_class="${3:-internal}"
    # Include partition and class in backup filename to avoid collisions
    local safe_partition
    safe_partition=$(echo "${partition}" | sed 's/\//_/g')
    local backup_file="${BACKUP_DIR}/${safe_partition}_${dg_name}_${dg_class}_${TIMESTAMP}.csv"
    local dg_type
    
    dg_type=$(get_datagroup_type "${partition}" "${dg_name}" "${dg_class}")
    
    {
        echo "# Datagroup Backup: /${partition}/${dg_name}"
        echo "# Partition: ${partition}"
        echo "# Class: ${dg_class}"
        echo "# Type: ${dg_type}"
        echo "# Created: $(date)"
        echo "# Format: key,value"
        echo "#"
        get_datagroup_records "${partition}" "${dg_name}" "${dg_class}" | while IFS='|' read -r key value; do
            echo "${key},${value}"
        done
    } > "${backup_file}"
    
    if [ -f "${backup_file}" ]; then
        cleanup_old_backups "${safe_partition}_${dg_name}_${dg_class}"
        echo "${backup_file}"
    fi
    return 0
}

# Sanitize a string for tmsh record key (URLs, domains, IPs, etc.)
# Keys are quoted so most special chars are safe, but we escape quotes
sanitize_key() {
    local input="$1"
    # Escape backslashes first, then double quotes
    echo "${input}" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Sanitize a string for tmsh record value
# Spaces MUST be converted to underscores or tmsh parsing fails
# Also escapes quotes and backslashes
sanitize_value() {
    local input="$1"
    # Escape backslashes first, then double quotes, then convert spaces to underscores
    echo "${input}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/ /_/g'
}

# Convert underscores back to spaces (for export)
underscore_to_space() {
    local input="$1"
    echo "${input}" | sed 's/_/ /g'
}

# Build tmsh record syntax from arrays
# Arguments: array name reference (keys), array name reference (values), datagroup type
# Handles special characters in URLs, CIDR notation, and values with spaces
# Note: tmsh requires different formatting per type:
#   - string:  keys are quoted    "example.com" { }
#   - integer: keys are unquoted  4322 { }
#   - ip:      keys are unquoted  10.1.1.0/24 { }
build_tmsh_records() {
    local keys_name=$1
    local values_name=$2
    local dg_type="$3"
    local records=""
    local space_conversions=0
    
    eval "local keys_count=\${#${keys_name}[@]}"
    
    for ((i=0; i<keys_count; i++)); do
        eval "local key=\"\${${keys_name}[$i]}\""
        eval "local value=\"\${${values_name}[$i]:-}\""
        local original_value="${value}"
        
        # Sanitize key (escape quotes, backslashes)
        key=$(sanitize_key "${key}")
        
        if [ -n "${value}" ]; then
            # Sanitize value (escape quotes, backslashes, convert spaces to underscores)
            value=$(sanitize_value "${value}")
            
            # Track if we converted spaces
            if [ "${value}" != "${original_value}" ] && [[ "${original_value}" == *" "* ]]; then
                space_conversions=$((space_conversions + 1))
            fi
            
            # Format based on type - string keys are quoted, ip/integer are not
            if [ "${dg_type}" == "string" ]; then
                records="${records} \"${key}\" { data \"${value}\" }"
            else
                # ip, address, integer - unquoted keys
                records="${records} ${key} { data \"${value}\" }"
            fi
        else
            # Format based on type - string keys are quoted, ip/integer are not
            if [ "${dg_type}" == "string" ]; then
                records="${records} \"${key}\" { }"
            else
                # ip, address, integer - unquoted keys
                records="${records} ${key} { }"
            fi
        fi
    done
    
    # Store space conversion count in global for reporting
    SPACE_CONVERSIONS=${space_conversions}
    
    echo "${records}"
}

# Global to track space conversions during build
SPACE_CONVERSIONS=0

# Apply records to INTERNAL datagroup (atomic replace-all-with operation)
apply_internal_datagroup_records() {
    local partition="$1"
    local dg_name="$2"
    local records="$3"
    
    local result
    if [ -z "${records}" ]; then
        # Empty datagroup - use empty records
        result=$(tmsh modify ltm data-group internal "/${partition}/${dg_name}" records none 2>&1)
    else
        result=$(tmsh modify ltm data-group internal "/${partition}/${dg_name}" records replace-all-with \{ ${records} \} 2>&1)
    fi
    local rc=$?
    if [ ${rc} -ne 0 ]; then
        log_error "tmsh error: ${result}"
    fi
    return ${rc}
}

# Create external datagroup file in temp directory
# Returns: path to created file
create_external_datagroup_file() {
    local file_name="$1"
    local dg_type="$2"
    local keys_name=$3
    local values_name=$4
    
    local temp_file="${EXTERNAL_TEMP_DIR}/${file_name}_${TIMESTAMP}.txt"
    
    eval "local keys_count=\${#${keys_name}[@]}"
    
    # Create the file in F5 external format
    {
        for ((i=0; i<keys_count; i++)); do
            eval "local key=\"\${${keys_name}[$i]}\""
            eval "local value=\"\${${values_name}[$i]:-}\""
            format_external_record "${key}" "${value}" "${dg_type}"
        done
    } > "${temp_file}"
    
    # Convert any Windows line endings
    convert_line_endings "${temp_file}"
    
    echo "${temp_file}"
}

# Import external datagroup file to sys file data-group
import_external_datagroup_file() {
    local partition="$1"
    local file_name="$2"
    local source_path="$3"
    local dg_type="$4"
    
    # Convert type names (address -> ip for external)
    local ext_type="${dg_type}"
    if [ "${dg_type}" == "address" ]; then
        ext_type="ip"
    fi
    
    # Create the sys file data-group
    local import_result
    import_result=$(tmsh create sys file data-group "/${partition}/${file_name}" \
        separator "${EXTERNAL_SEPARATOR}" \
        source-path "file:${source_path}" \
        type "${ext_type}" 2>&1)
    if [ $? -ne 0 ]; then
        log_error "Import failed: ${import_result}"
        return 1
    fi
    return 0
}

# Create new external datagroup
create_external_datagroup() {
    local partition="$1"
    local dg_name="$2"
    local dg_type="$3"
    local keys_name=$4
    local values_name=$5
    
    local file_name="${dg_name}_file"
    
    # Create the temp file with data
    local temp_file
    temp_file=$(create_external_datagroup_file "${dg_name}" "${dg_type}" "${keys_name}" "${values_name}")
    
    if [ ! -f "${temp_file}" ]; then
        log_error "Failed to create temp file for external datagroup"
        return 1
    fi
    
    # Import the file to sys file data-group
    log_step "Importing external file to BIG-IP..."
    if ! import_external_datagroup_file "${partition}" "${file_name}" "${temp_file}" "${dg_type}"; then
        log_error "Failed to import external datagroup file"
        rm -f "${temp_file}" 2>/dev/null
        return 1
    fi
    
    # Create the external datagroup referencing the file
    # Note: type is inherited from sys file data-group, not specified here
    log_step "Creating external datagroup..."
    local create_result
    create_result=$(tmsh create ltm data-group external "/${partition}/${dg_name}" \
        external-file-name "${file_name}" 2>&1)
    if [ $? -ne 0 ]; then
        log_error "Failed to create external datagroup: ${create_result}"
        # Clean up the sys file
        tmsh delete sys file data-group "/${partition}/${file_name}" 2>/dev/null
        rm -f "${temp_file}" 2>/dev/null
        return 1
    fi
    
    # Clean up temp file
    rm -f "${temp_file}" 2>/dev/null
    
    return 0
}

# Update external datagroup with new data
# This creates a new file, updates the reference, and cleans up the old file
update_external_datagroup() {
    local partition="$1"
    local dg_name="$2"
    local dg_type="$3"
    local keys_name=$4
    local values_name=$5
    
    # Get the current file name
    local old_file_name
    old_file_name=$(get_external_datagroup_file "${partition}" "${dg_name}")
    
    # Create new file name with timestamp to avoid conflicts
    local new_file_name="${dg_name}_file_${TIMESTAMP}"
    
    # Create the temp file with data
    local temp_file
    temp_file=$(create_external_datagroup_file "${dg_name}" "${dg_type}" "${keys_name}" "${values_name}")
    
    if [ ! -f "${temp_file}" ]; then
        log_error "Failed to create temp file for external datagroup update"
        return 1
    fi
    
    # Import the new file to sys file data-group
    log_step "Importing updated external file to BIG-IP..."
    if ! import_external_datagroup_file "${partition}" "${new_file_name}" "${temp_file}" "${dg_type}"; then
        log_error "Failed to import external datagroup file"
        rm -f "${temp_file}" 2>/dev/null
        return 1
    fi
    
    # Update the external datagroup to reference the new file
    log_step "Updating external datagroup reference..."
    if ! tmsh modify ltm data-group external "/${partition}/${dg_name}" \
        external-file-name "${new_file_name}" 2>/dev/null; then
        log_error "Failed to update external datagroup reference"
        # Clean up the new sys file
        tmsh delete sys file data-group "/${partition}/${new_file_name}" 2>/dev/null
        rm -f "${temp_file}" 2>/dev/null
        return 1
    fi
    
    # Delete the old sys file data-group (if it exists and is different)
    if [ -n "${old_file_name}" ] && [ "${old_file_name}" != "${new_file_name}" ]; then
        log_step "Cleaning up old file reference..."
        tmsh delete sys file data-group "/${partition}/${old_file_name}" 2>/dev/null || true
    fi
    
    # Clean up temp file
    rm -f "${temp_file}" 2>/dev/null
    
    return 0
}

# Wrapper function for backward compatibility
apply_datagroup_records() {
    local partition="$1"
    local dg_name="$2"
    local records="$3"
    
    # This is for internal datagroups only
    apply_internal_datagroup_records "${partition}" "${dg_name}" "${records}"
    return $?
}

# =============================================================================
# CSV PARSING AND VALIDATION
# =============================================================================

# Parse CSV file and validate format
# Returns: 0 if valid, 1 if invalid
# Sets global arrays: CSV_KEYS, CSV_VALUES
parse_csv_file() {
    local filepath="$1"
    local format="$2"  # "keys_only" or "keys_values"
    
    # Reset arrays
    CSV_KEYS=()
    CSV_VALUES=()
    
    local line_num=0
    local errors=0
    
    while IFS= read -r line || [ -n "${line}" ]; do
        line_num=$((line_num + 1))
        
        # Skip empty lines
        [ -z "${line}" ] && continue
        
        # Skip comment lines
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        
        # Trim whitespace
        line=$(echo "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Skip if still empty after trim
        [ -z "${line}" ] && continue
        
        # Parse based on format
        if [ "${format}" == "keys_only" ]; then
            # Take first column only, ignore the rest
            local key
            key=$(echo "${line}" | cut -d',' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            if [ -z "${key}" ]; then
                log_warn "Line ${line_num}: Empty key, skipping"
                continue
            fi
            
            CSV_KEYS+=("${key}")
            CSV_VALUES+=("")
        else
            # Keys and values format
            local key value
            key=$(echo "${line}" | cut -d',' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            value=$(echo "${line}" | cut -d',' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            if [ -z "${key}" ]; then
                log_warn "Line ${line_num}: Empty key, skipping"
                continue
            fi
            
            CSV_KEYS+=("${key}")
            CSV_VALUES+=("${value}")
        fi
    done < "${filepath}"
    
    if [ ${#CSV_KEYS[@]} -eq 0 ]; then
        log_error "No valid entries found in CSV file"
        return 1
    fi
    
    return 0
}

# Analyze entries for type mismatches
analyze_entry_types() {
    local expected_type="$1"
    local keys_name=$2
    
    local integer_count=0
    local address_count=0
    local other_count=0
    eval "local total=\${#${keys_name}[@]}"
    
    for ((i=0; i<total; i++)); do
        eval "local key=\"\${${keys_name}[$i]}\""
        if is_integer_format "${key}"; then
            integer_count=$((integer_count + 1))
        elif is_address_format "${key}"; then
            address_count=$((address_count + 1))
        else
            other_count=$((other_count + 1))
        fi
    done
    
    local mismatch_count=0
    local mismatch_type=""
    
    # String type - warn if entries look like IPs or integers (probably wrong type)
    if [ "${expected_type}" == "string" ]; then
        if [ ${address_count} -gt 0 ]; then
            mismatch_count=${address_count}
            mismatch_type="address"
        elif [ ${integer_count} -gt 0 ]; then
            mismatch_count=${integer_count}
            mismatch_type="integer"
        fi
    fi
    
    # Address type - warn if entries don't look like IPs
    if [ "${expected_type}" == "address" ]; then
        local non_address=$((integer_count + other_count))
        if [ ${non_address} -gt 0 ]; then
            mismatch_count=${non_address}
            mismatch_type="non-address"
        fi
    fi
    
    # Integer type - warn if entries aren't numbers
    if [ "${expected_type}" == "integer" ]; then
        local non_integer=$((address_count + other_count))
        if [ ${non_integer} -gt 0 ]; then
            mismatch_count=${non_integer}
            mismatch_type="non-integer"
        fi
    fi
    
    if [ ${mismatch_count} -gt 0 ]; then
        local mismatch_pct=$((mismatch_count * 100 / total))
        echo "${mismatch_count}|${mismatch_type}|${mismatch_pct}"
    else
        echo "0||0"
    fi
}

# Preview CSV file contents
preview_csv_file() {
    local filepath="$1"
    local total_lines
    local data_lines
    
    total_lines=$(wc -l < "${filepath}")
    data_lines=$(grep -cv '^\s*#\|^\s*$' "${filepath}" 2>/dev/null || echo "0")
    
    echo ""
    log "${WHITE}  Analyzing file: $(basename "${filepath}")${NC}"
    log "${CYAN}  ────────────────────────────────────────────────────────────${NC}"
    
    local count=0
    while IFS= read -r line; do
        # Skip empty and comment lines for preview
        [ -z "${line}" ] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        
        count=$((count + 1))
        if [ ${count} -le ${PREVIEW_LINES} ]; then
            log "${WHITE}    Row ${count}: ${line}${NC}"
        fi
    done < "${filepath}"
    
    log "${CYAN}  ────────────────────────────────────────────────────────────${NC}"
    log "${WHITE}  Showing first ${PREVIEW_LINES} of ${data_lines} data entries.${NC}"
    echo ""
}

# =============================================================================
# MENU FUNCTIONS
# =============================================================================

# Main menu display
show_main_menu() {
    clear
    echo ""
    echo -e "  ${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}║${NC}${WHITE}                    DGCAT-Admin v1.0                        ${NC}${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}${WHITE}               F5 BIG-IP Administration Tool                ${NC}${CYAN}║${NC}"
    echo -e "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}   ${YELLOW}1)${NC}  ${WHITE}List All Datagroups${NC}                                  ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}   ${YELLOW}2)${NC}  ${WHITE}View Datagroup Contents${NC}                              ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}   ${YELLOW}3)${NC}  ${WHITE}Create Datagroup/URL Category from CSV${NC}               ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}   ${YELLOW}4)${NC}  ${WHITE}Delete Datagroup${NC}                                     ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}   ${YELLOW}5)${NC}  ${WHITE}Export Datagroup/URL Category to CSV${NC}                 ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}   ${YELLOW}6)${NC}  ${WHITE}Convert URL Category to Datagroup${NC}                    ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}"
    echo -e "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "  ${CYAN}║${NC}   ${YELLOW}0)${NC}  ${WHITE}Exit${NC}                                                 ${CYAN}║${NC}"
    echo -e "  ${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Option 1: List all datagroups
menu_list_datagroups() {
    log_section "List All Datagroups"
    
    log_info "Configured partitions: ${PARTITIONS}"
    
    local datagroups
    datagroups=$(get_all_datagroup_list)
    
    if [ -z "${datagroups}" ]; then
        log_info "No datagroups found in configured partitions."
    else
        local count=0
        echo ""
        printf "  ${WHITE}%-15s %-30s %-10s %-10s %s${NC}\n" "PARTITION" "NAME" "CLASS" "TYPE" "RECORDS"
        echo -e "  ${CYAN}────────────────────────────────────────────────────────────────────────────────────${NC}"
        
        while IFS='|' read -r partition dg_name dg_class; do
            [ -z "${dg_name}" ] && continue
            local dg_type
            local record_count
            local protected_marker=""
            dg_type=$(get_datagroup_type "${partition}" "${dg_name}" "${dg_class}")
            record_count=$(get_datagroup_records "${partition}" "${dg_name}" "${dg_class}" 2>/dev/null | wc -l)
            
            # Mark protected system datagroups
            if is_protected_datagroup "${dg_name}"; then
                protected_marker="${YELLOW} [SYSTEM]${NC}"
            fi
            
            printf "  ${WHITE}%-15s %-30s %-10s %-10s %s${NC}%b\n" "${partition}" "${dg_name}" "${dg_class}" "${dg_type}" "${record_count}" "${protected_marker}"
            count=$((count + 1))
        done <<< "${datagroups}"
        
        echo -e "  ${CYAN}────────────────────────────────────────────────────────────────────────────────────${NC}"
        log_info "Total: ${count} datagroup(s) across ${#PARTITION_LIST[@]} partition(s)"
        log_info "Note: ${YELLOW}[SYSTEM]${NC} datagroups are protected and cannot be modified or deleted."
    fi
    
    press_enter_to_continue
}

# Option 2: View datagroup contents
menu_view_datagroup() {
    log_section "View Datagroup Contents"
    
    # Select partition
    local partition
    partition=$(select_partition "Select partition to view from")
    if [ -z "${partition}" ]; then
        log_info "Cancelled."
        press_enter_to_continue
        return
    fi
    
    # Select datagroup
    local selection dg_name dg_class
    selection=$(select_datagroup "${partition}" "Enter datagroup name")
    if [ -z "${selection}" ]; then
        press_enter_to_continue
        return
    fi
    IFS='|' read -r dg_name dg_class <<< "${selection}"
    
    local dg_type
    dg_type=$(get_datagroup_type "${partition}" "${dg_name}" "${dg_class}")
    
    echo ""
    log_info "Datagroup: /${partition}/${dg_name}"
    log_info "Class: ${dg_class}"
    log_info "Type: ${dg_type}"
    
    # For external datagroups, show the file reference
    if [ "${dg_class}" == "external" ]; then
        local ext_file
        ext_file=$(get_external_datagroup_file "${partition}" "${dg_name}")
        log_info "External File: ${ext_file}"
    fi
    
    echo -e "  ${CYAN}────────────────────────────────────────────────────────────${NC}"
    
    local records
    records=$(get_datagroup_records "${partition}" "${dg_name}" "${dg_class}")
    
    if [ -z "${records}" ]; then
        log_info "(empty - no records)"
    else
        local count=0
        printf "\n  ${WHITE}%-45s %s${NC}\n" "KEY" "VALUE"
        echo -e "  ${CYAN}────────────────────────────────────────────────────────────${NC}"
        while IFS='|' read -r key value; do
            if [ -n "${value}" ]; then
                printf "  ${WHITE}%-45s %s${NC}\n" "${key}" "${value}"
            else
                printf "  ${WHITE}%-45s ${NC}${YELLOW}%s${NC}\n" "${key}" "(no value)"
            fi
            count=$((count + 1))
        done <<< "${records}"
        echo -e "  ${CYAN}────────────────────────────────────────────────────────────${NC}"
        log_info "Total: ${count} record(s)"
    fi
    
    press_enter_to_continue
}

# Option 3: Create/Restore from CSV (Datagroup or URL Category)
menu_create_from_csv() {
    log_section "Create/Restore from CSV"
    
    echo ""
    echo -e "  ${WHITE}What would you like to create?${NC}"
    echo -e "    ${YELLOW}1)${NC} ${WHITE}Datagroup (LTM data-group for iRules/policies)${NC}"
    echo -e "    ${YELLOW}2)${NC} ${WHITE}URL Category (Custom URL category for SSLO/SWG)${NC}"
    echo -e "    ${YELLOW}0)${NC} ${WHITE}Cancel${NC}"
    echo ""
    read -rp "  Select [0-2]: " create_choice
    
    case "${create_choice}" in
        1) menu_create_datagroup ;;
        2) menu_create_url_category ;;
        0|"")
            log_info "Cancelled."
            press_enter_to_continue
            ;;
        *)
            log_warn "Invalid selection."
            press_enter_to_continue
            ;;
    esac
}

# Option 3a: Create/Restore datagroup from CSV
menu_create_datagroup() {
    log_section "Create/Restore Datagroup from CSV"
    
    # Select partition
    local partition
    partition=$(select_partition "Select partition")
    if [ -z "${partition}" ]; then
        log_info "Cancelled."
        press_enter_to_continue
        return
    fi
    
    # Get datagroup name
    echo ""
    read -rp "  Enter datagroup name: " dg_name
    
    if [ -z "${dg_name}" ]; then
        log_warn "No datagroup name provided."
        press_enter_to_continue
        return
    fi
    
    # Strip partition prefix if user included it
    dg_name=$(strip_partition_prefix "${dg_name}")
    
    # Check if this name matches a protected system datagroup
    if is_protected_datagroup "${dg_name}"; then
        log_error "The name '${dg_name}' is reserved for a BIG-IP system datagroup."
        log_error "Modifying this datagroup could cause adverse system behavior."
        press_enter_to_continue
        return
    fi
    
    # Check if already exists (either internal or external)
    local existing_class
    existing_class=$(datagroup_exists "${partition}" "${dg_name}")
    
    local dg_class
    local dg_type
    local restore_mode=""
    
    if [ -n "${existing_class}" ]; then
        # Datagroup exists - this is a restore operation
        dg_class="${existing_class}"
        dg_type=$(get_datagroup_type "${partition}" "${dg_name}" "${dg_class}")
        
        local current_count
        current_count=$(get_datagroup_records "${partition}" "${dg_name}" "${dg_class}" 2>/dev/null | wc -l)
        
        log_info "Datagroup '${dg_name}' exists in partition '${partition}'."
        log_info "  Class: ${dg_class}"
        log_info "  Type: ${dg_type}"
        log_info "  Current records: ${current_count}"
        echo ""
        echo -e "  ${WHITE}How do you want to proceed?${NC}"
        echo -e "    ${YELLOW}1)${NC} ${WHITE}Overwrite - Replace all existing entries with CSV contents${NC}"
        echo -e "    ${YELLOW}2)${NC} ${WHITE}Merge     - Add CSV entries to existing (deduplicated)${NC}"
        echo -e "    ${YELLOW}3)${NC} ${WHITE}Cancel${NC}"
        echo ""
        read -rp "  Select [1-3]: " exist_choice
        
        case "${exist_choice}" in
            1) restore_mode="overwrite" ;;
            2) restore_mode="merge" ;;
            *)
                log_info "Cancelled."
                press_enter_to_continue
                return
                ;;
        esac
        
        # Create backup before modification
        log_step "Creating backup of existing datagroup..."
        local backup_file
        backup_file=$(backup_datagroup "${partition}" "${dg_name}" "${dg_class}")
        if [ -n "${backup_file}" ]; then
            log_ok "Backup saved: ${backup_file}"
        else
            log_warn "Could not create backup."
            read -rp "  Continue without backup? (yes/no) [no]: " cont
            if [ "${cont}" != "yes" ]; then
                log_info "Aborted."
                press_enter_to_continue
                return
            fi
        fi
    else
        # New datagroup - ask for class and type
        
        # Select datagroup class (internal vs external)
        echo ""
        echo -e "  ${WHITE}Select datagroup class:${NC}"
        echo -e "    ${YELLOW}1)${NC} ${WHITE}Internal - Stored in bigip.conf (best for <1000 entries)${NC}"
        echo -e "    ${YELLOW}2)${NC} ${WHITE}External - Stored in separate file (best for large lists, 1000+ entries)${NC}"
        echo ""
        read -rp "  Select [1-2]: " class_choice
        
        case "${class_choice}" in
            1) dg_class="internal" ;;
            2) dg_class="external" ;;
            *)
                log_warn "Invalid selection."
                press_enter_to_continue
                return
                ;;
        esac
        
        # Get datagroup type
        echo ""
        echo -e "  ${WHITE}Select datagroup type:${NC}"
        echo -e "    ${YELLOW}1)${NC} ${WHITE}string  - For domains, hostnames, URLs${NC}"
        echo -e "    ${YELLOW}2)${NC} ${WHITE}address - For IP addresses, subnets (CIDR)${NC}"
        echo -e "    ${YELLOW}3)${NC} ${WHITE}integer - For port numbers, numeric values${NC}"
        echo ""
        read -rp "  Select [1-3]: " type_choice
        
        case "${type_choice}" in
            1) dg_type="string" ;;
            2) dg_type="address" ;;
            3) dg_type="integer" ;;
            *)
                log_warn "Invalid selection."
                press_enter_to_continue
                return
                ;;
        esac
    fi
    
    # Get CSV file path (loop until valid file or user cancels)
    local csv_path=""
    while true; do
        echo ""
        read -rp "  Enter path to CSV file (or 'q' to cancel): " csv_path
        
        if [ -z "${csv_path}" ]; then
            log_warn "No file path provided."
            continue
        fi
        
        if [ "${csv_path}" == "q" ] || [ "${csv_path}" == "Q" ]; then
            log_info "Cancelled."
            press_enter_to_continue
            return
        fi
        
        # If no path separator, assume current working directory
        if [[ "${csv_path}" != /* ]]; then
            csv_path="$(pwd)/${csv_path}"
        fi
        
        if [ ! -f "${csv_path}" ]; then
            log_error "File not found: ${csv_path}"
            continue
        fi
        
        # File found, break out of loop
        break
    done
    
    # Check for Windows line endings and convert if needed
    local temp_csv=""
    if has_windows_line_endings "${csv_path}"; then
        log_warn "File has Windows line endings (CRLF)."
        log_info "These will be converted to Unix format (LF) for compatibility."
        # Create a temp copy to avoid modifying original
        temp_csv="${EXTERNAL_TEMP_DIR}/import_${TIMESTAMP}.csv"
        cp "${csv_path}" "${temp_csv}"
        convert_line_endings "${temp_csv}"
        csv_path="${temp_csv}"
    fi
    
    # Preview the file
    preview_csv_file "${csv_path}"
    
    # Early type detection - scan first column for mismatches
    local detected_addresses=0
    local detected_integers=0
    local detected_other=0
    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        # Get first column only
        local first_col
        first_col=$(echo "${line}" | cut -d',' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "${first_col}" ] && continue
        
        if is_integer_format "${first_col}"; then
            detected_integers=$((detected_integers + 1))
        elif is_address_format "${first_col}"; then
            detected_addresses=$((detected_addresses + 1))
        else
            detected_other=$((detected_other + 1))
        fi
    done < "${csv_path}"
    
    local total_detected=$((detected_addresses + detected_integers + detected_other))
    
    # Warn if type doesn't match detected content
    if [ ${total_detected} -gt 0 ]; then
        local mismatch_warning=""
        if [ "${dg_type}" == "string" ] && [ ${detected_addresses} -eq ${total_detected} ]; then
            mismatch_warning="All entries appear to be IP addresses. Did you mean to select 'address' type?"
        elif [ "${dg_type}" == "string" ] && [ ${detected_integers} -eq ${total_detected} ]; then
            mismatch_warning="All entries appear to be integers. Did you mean to select 'integer' type?"
        elif [ "${dg_type}" == "address" ] && [ ${detected_addresses} -eq 0 ]; then
            mismatch_warning="No entries appear to be IP addresses. Did you mean to select a different type?"
        elif [ "${dg_type}" == "integer" ] && [ ${detected_integers} -eq 0 ]; then
            mismatch_warning="No entries appear to be integers. Did you mean to select a different type?"
        fi
        
        if [ -n "${mismatch_warning}" ]; then
            echo ""
            log_warn "${mismatch_warning}"
            read -rp "  Continue anyway? (yes/no) [no]: " continue_choice
            if [ "${continue_choice}" != "yes" ]; then
                log_info "Aborted by user."
                [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
                press_enter_to_continue
                return
            fi
            echo ""
        fi
    fi
    
    # Ask about format
    echo -e "  ${WHITE}What does this file contain?${NC}"
    echo -e "    ${YELLOW}1)${NC} ${WHITE}Keys only (e.g., domains, subnets)${NC}"
    echo -e "    ${YELLOW}2)${NC} ${WHITE}Keys and Values (e.g., domain,action)${NC}"
    echo ""
    read -rp "  Select [1-2]: " format_choice
    
    local csv_format
    case "${format_choice}" in
        1) csv_format="keys_only" ;;
        2) csv_format="keys_values" ;;
        *)
            log_warn "Invalid selection."
            [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
            press_enter_to_continue
            return
            ;;
    esac
    
    # Parse the CSV
    log_step "Parsing CSV file..."
    if ! parse_csv_file "${csv_path}" "${csv_format}"; then
        log_error "Failed to parse CSV file."
        [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
        press_enter_to_continue
        return
    fi
    log_ok "Parsed ${#CSV_KEYS[@]} entries"
    
    # Check for type mismatches
    local mismatch_result
    mismatch_result=$(analyze_entry_types "${dg_type}" CSV_KEYS)
    local mismatch_count mismatch_type mismatch_pct
    IFS='|' read -r mismatch_count mismatch_type mismatch_pct <<< "${mismatch_result}"
    
    if [ "${mismatch_count}" -gt 0 ]; then
        echo ""
        log_warn "Type mismatch detected!"
        log_warn "Datagroup type is '${dg_type}' but ${mismatch_count} entries (${mismatch_pct}%) appear to be '${mismatch_type}' format."
        echo ""
        read -rp "  Continue anyway? (yes/no) [no]: " continue_choice
        if [ "${continue_choice}" != "yes" ]; then
            log_info "Aborted by user."
            [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
            press_enter_to_continue
            return
        fi
    fi
    
    # Prepare final key/value arrays
    declare -a FINAL_KEYS
    declare -a FINAL_VALUES
    
    if [ "${restore_mode}" == "merge" ]; then
        # Merge: Start with existing entries
        log_step "Reading existing entries for merge..."
        
        # Use associative array for deduplication
        declare -A merged_data
        
        # Read existing entries
        while IFS='|' read -r key value; do
            [ -z "${key}" ] && continue
            merged_data["${key}"]="${value}"
        done < <(get_datagroup_records "${partition}" "${dg_name}" "${dg_class}")
        
        local existing_count=${#merged_data[@]}
        
        # Add new entries (overwrites duplicates)
        for i in "${!CSV_KEYS[@]}"; do
            merged_data["${CSV_KEYS[$i]}"]="${CSV_VALUES[$i]}"
        done
        
        local final_count=${#merged_data[@]}
        local new_entries=$((final_count - existing_count))
        
        log_info "Existing: ${existing_count}, New unique: ${new_entries}, Final: ${final_count}"
        
        # Convert to indexed arrays
        for key in "${!merged_data[@]}"; do
            FINAL_KEYS+=("${key}")
            FINAL_VALUES+=("${merged_data[$key]}")
        done
    else
        # Overwrite or new: Use CSV entries directly
        FINAL_KEYS=("${CSV_KEYS[@]}")
        FINAL_VALUES=("${CSV_VALUES[@]}")
    fi
    
    # Apply records based on datagroup class and whether it exists
    if [ "${dg_class}" == "external" ]; then
        if [ -n "${restore_mode}" ]; then
            # Update existing external datagroup
            log_step "Updating external datagroup '/${partition}/${dg_name}'..."
            if ! update_external_datagroup "${partition}" "${dg_name}" "${dg_type}" FINAL_KEYS FINAL_VALUES; then
                log_error "Failed to update external datagroup."
                [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
                press_enter_to_continue
                return
            fi
        else
            # Create new external datagroup
            log_step "Creating external datagroup '/${partition}/${dg_name}'..."
            if ! create_external_datagroup "${partition}" "${dg_name}" "${dg_type}" FINAL_KEYS FINAL_VALUES; then
                log_error "Failed to create external datagroup."
                [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
                press_enter_to_continue
                return
            fi
        fi
        log_ok "External datagroup '/${partition}/${dg_name}' saved with ${#FINAL_KEYS[@]} entries."
    else
        # Internal datagroup workflow
        log_step "Building datagroup records..."
        local records
        records=$(build_tmsh_records FINAL_KEYS FINAL_VALUES "${dg_type}")
        
        # Notify about space conversions
        if [ ${SPACE_CONVERSIONS} -gt 0 ]; then
            log_info "Note: ${SPACE_CONVERSIONS} value(s) contained spaces which were converted to underscores."
            log_info "This is required for tmsh compatibility. Spaces can be restored on export."
        fi
        
        # Convert type names for tmsh (address -> ip)
        local tmsh_type="${dg_type}"
        if [ "${dg_type}" == "address" ]; then
            tmsh_type="ip"
        fi
        
        if [ -z "${restore_mode}" ]; then
            # Create new internal datagroup
            log_step "Creating internal datagroup '/${partition}/${dg_name}'..."
            local create_error
            if ! create_error=$(tmsh create ltm data-group internal "/${partition}/${dg_name}" type "${tmsh_type}" 2>&1); then
                log_error "Failed to create datagroup: ${create_error}"
                [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
                press_enter_to_continue
                return
            fi
        fi
        
        # Apply records
        log_step "Applying ${#FINAL_KEYS[@]} entries to datagroup..."
        if ! apply_datagroup_records "${partition}" "${dg_name}" "${records}" "${dg_type}"; then
            log_error "Failed to apply records to datagroup."
            [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
            press_enter_to_continue
            return
        fi
        
        log_ok "Internal datagroup '/${partition}/${dg_name}' saved with ${#FINAL_KEYS[@]} entries."
    fi
    
    prompt_save_config
    
    # Cleanup temp file if created
    [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
    
    press_enter_to_continue
}

# Option 4: Delete datagroup
menu_delete_datagroup() {
    log_section "Delete Datagroup"
    
    # Select partition
    local partition
    partition=$(select_partition "Select partition containing datagroup to delete")
    if [ -z "${partition}" ]; then
        log_info "Cancelled."
        press_enter_to_continue
        return
    fi
    
    # List available datagroups
    if ! list_partition_datagroups "${partition}" "true"; then
        press_enter_to_continue
        return
    fi
    
    echo ""
    local dg_name
    read -rp "  Enter datagroup name to delete: " dg_name
    
    if [ -z "${dg_name}" ]; then
        log_warn "No datagroup name provided."
        press_enter_to_continue
        return
    fi
    
    # Strip partition prefix if included
    dg_name=$(strip_partition_prefix "${dg_name}")
    
    # Check if datagroup exists and get its class
    local dg_class
    dg_class=$(datagroup_exists "${partition}" "${dg_name}")
    if [ -z "${dg_class}" ]; then
        log_error "Datagroup '${dg_name}' does not exist in partition '${partition}'."
        press_enter_to_continue
        return
    fi
    
    # Check if this is a protected system datagroup
    if is_protected_datagroup "${dg_name}"; then
        log_error "Datagroup '${dg_name}' is a protected BIG-IP system datagroup."
        log_error "Deleting this datagroup can cause adverse system behavior."
        log_error "This operation is blocked for safety."
        press_enter_to_continue
        return
    fi
    
    # Show current contents
    local dg_type record_count
    dg_type=$(get_datagroup_type "${partition}" "${dg_name}" "${dg_class}")
    record_count=$(get_datagroup_records "${partition}" "${dg_name}" "${dg_class}" 2>/dev/null | wc -l)
    
    # For external, get the file reference
    local ext_file=""
    if [ "${dg_class}" == "external" ]; then
        ext_file=$(get_external_datagroup_file "${partition}" "${dg_name}")
    fi
    
    echo ""
    log_warn "You are about to delete the following datagroup:"
    log_info "  Path:    /${partition}/${dg_name}"
    log_info "  Class:   ${dg_class}"
    log_info "  Type:    ${dg_type}"
    log_info "  Records: ${record_count}"
    if [ -n "${ext_file}" ]; then
        log_info "  File:    ${ext_file} (will also be deleted)"
    fi
    echo ""
    
    # Backup before delete
    log_step "Creating backup before deletion..."
    local backup_file
    backup_file=$(backup_datagroup "${partition}" "${dg_name}" "${dg_class}")
    if [ -n "${backup_file}" ]; then
        log_ok "Backup saved: ${backup_file}"
    else
        log_warn "Could not create backup."
        read -rp "  Continue without backup? (yes/no) [no]: " continue_choice
        if [ "${continue_choice}" != "yes" ]; then
            log_info "Aborted by user."
            press_enter_to_continue
            return
        fi
    fi
    
    # Confirm deletion
    echo ""
    read -rp "  Type DELETE to confirm: " confirm
    if [ "${confirm}" != "DELETE" ]; then
        log_info "Aborted by user."
        press_enter_to_continue
        return
    fi
    
    # Delete the datagroup based on class
    if [ "${dg_class}" == "external" ]; then
        # Delete external datagroup
        log_step "Deleting external datagroup '/${partition}/${dg_name}'..."
        if tmsh delete ltm data-group external "/${partition}/${dg_name}" 2>/dev/null; then
            log_ok "External datagroup deleted."
        else
            log_error "Failed to delete external datagroup."
            press_enter_to_continue
            return
        fi
        
        # Delete the associated sys file data-group
        if [ -n "${ext_file}" ]; then
            log_step "Deleting associated file '${ext_file}'..."
            if tmsh delete sys file data-group "/${partition}/${ext_file}" 2>/dev/null; then
                log_ok "File reference deleted."
            else
                log_warn "Could not delete file reference. It may need manual cleanup."
            fi
        fi
    else
        # Delete internal datagroup
        log_step "Deleting internal datagroup '/${partition}/${dg_name}'..."
        if tmsh delete ltm data-group internal "/${partition}/${dg_name}" 2>/dev/null; then
            log_ok "Datagroup '/${partition}/${dg_name}' deleted successfully."
        else
            log_error "Failed to delete datagroup."
            press_enter_to_continue
            return
        fi
    fi
    
    prompt_save_config
    press_enter_to_continue
}

# Option 5: Export to CSV (Datagroup or URL Category)
menu_export_to_csv() {
    log_section "Export to CSV"
    
    echo ""
    echo -e "  ${WHITE}What would you like to export?${NC}"
    echo -e "    ${YELLOW}1)${NC} ${WHITE}Datagroup${NC}"
    echo -e "    ${YELLOW}2)${NC} ${WHITE}URL Category${NC}"
    echo -e "    ${YELLOW}0)${NC} ${WHITE}Cancel${NC}"
    echo ""
    read -rp "  Select [0-2]: " export_choice
    
    case "${export_choice}" in
        1) menu_export_datagroup ;;
        2) menu_export_url_category ;;
        0|"")
            log_info "Cancelled."
            press_enter_to_continue
            ;;
        *)
            log_warn "Invalid selection."
            press_enter_to_continue
            ;;
    esac
}

# Option 5a: Export datagroup to CSV
menu_export_datagroup() {
    log_section "Export Datagroup to CSV"
    
    # Select partition
    local partition
    partition=$(select_partition "Select partition containing datagroup to export")
    if [ -z "${partition}" ]; then
        log_info "Cancelled."
        press_enter_to_continue
        return
    fi
    
    # Select datagroup
    local selection dg_name dg_class
    selection=$(select_datagroup "${partition}" "Enter datagroup name to export")
    if [ -z "${selection}" ]; then
        press_enter_to_continue
        return
    fi
    IFS='|' read -r dg_name dg_class <<< "${selection}"
    
    # Default export path (include partition and class in filename)
    local safe_partition
    safe_partition=$(echo "${partition}" | sed 's/\//_/g')
    local default_path="${BACKUP_DIR}/${safe_partition}_${dg_name}_${dg_class}_${TIMESTAMP}.csv"
    echo ""
    read -rp "  Export path [${default_path}]: " export_path
    export_path="${export_path:-${default_path}}"
    
    # Ask about underscore-to-space conversion for values
    echo ""
    log_info "Datagroup values may contain underscores that were originally spaces."
    log_info "(Spaces are stored as underscores for tmsh compatibility)"
    echo ""
    echo -e "  ${WHITE}How should underscores in VALUES be handled?${NC}"
    echo -e "    ${YELLOW}1)${NC} ${WHITE}Keep as-is (underscores remain underscores)${NC}"
    echo -e "    ${YELLOW}2)${NC} ${WHITE}Convert to spaces (restore original formatting)${NC}"
    echo ""
    read -rp "  Select [1-2] [1]: " underscore_choice
    underscore_choice="${underscore_choice:-1}"
    
    local convert_underscores=false
    if [ "${underscore_choice}" == "2" ]; then
        convert_underscores=true
        log_info "Underscores in values will be converted to spaces."
    fi
    
    # Ensure directory exists
    local export_dir
    export_dir=$(dirname "${export_path}")
    if [ ! -d "${export_dir}" ]; then
        mkdir -p "${export_dir}" 2>/dev/null || {
            log_error "Could not create directory: ${export_dir}"
            press_enter_to_continue
            return
        }
    fi
    
    # Export
    log_step "Exporting ${dg_class} datagroup..."
    local dg_type
    dg_type=$(get_datagroup_type "${partition}" "${dg_name}" "${dg_class}")
    
    {
        echo "# Datagroup Export: /${partition}/${dg_name}"
        echo "# Partition: ${partition}"
        echo "# Class: ${dg_class}"
        echo "# Type: ${dg_type}"
        echo "# Exported: $(date)"
        echo "# Format: key,value"
        if [ "${convert_underscores}" == "true" ]; then
            echo "# Note: Underscores in values were converted to spaces"
        fi
        echo "#"
        get_datagroup_records "${partition}" "${dg_name}" "${dg_class}" | while IFS='|' read -r key value; do
            if [ "${convert_underscores}" == "true" ] && [ -n "${value}" ]; then
                value=$(underscore_to_space "${value}")
            fi
            echo "${key},${value}"
        done
    } > "${export_path}"
    
    if [ -f "${export_path}" ]; then
        local record_count
        record_count=$(grep -cv '^\s*#\|^\s*$' "${export_path}" 2>/dev/null || echo "0")
        log_ok "Exported ${record_count} records to: ${export_path}"
    else
        log_error "Export failed."
    fi
    
    press_enter_to_continue
}

# Option 5b: Export URL category to CSV
menu_export_url_category() {
    log_section "Export URL Category to CSV"
    
    # Check if URL database is available
    if ! tmsh list sys url-db url-category one-line &>/dev/null; then
        log_error "URL database not available or accessible."
        log_info "This feature requires the URL filtering module."
        press_enter_to_continue
        return
    fi
    
    # Offer choice: enter name directly or list all
    echo ""
    echo -e "  ${WHITE}How would you like to select a URL category?${NC}"
    echo -e "    ${YELLOW}1)${NC} ${WHITE}Enter category name directly${NC}"
    echo -e "    ${YELLOW}2)${NC} ${WHITE}List all categories${NC}"
    echo -e "    ${YELLOW}0)${NC} ${WHITE}Cancel${NC}"
    echo ""
    read -rp "  Select [0-2]: " method_choice
    
    local selected_category=""
    
    case "${method_choice}" in
        0|"")
            log_info "Cancelled."
            press_enter_to_continue
            return
            ;;
        1)
            # Direct entry
            while true; do
                echo ""
                read -rp "  Enter URL category name (or 'q' to cancel): " selected_category
                
                if [ -z "${selected_category}" ]; then
                    log_warn "No category name provided."
                    continue
                fi
                
                if [ "${selected_category}" == "q" ] || [ "${selected_category}" == "Q" ]; then
                    log_info "Cancelled."
                    press_enter_to_continue
                    return
                fi
                
                # Verify category exists
                if url_category_exists "${selected_category}"; then
                    break
                fi
                
                # Try with sslo-urlCat prefix
                local sslo_name="sslo-urlCat${selected_category}"
                if url_category_exists "${sslo_name}"; then
                    log_info "Found as SSLO category: ${sslo_name}"
                    selected_category="${sslo_name}"
                    break
                fi
                
                log_error "Category '${selected_category}' not found."
                continue
            done
            ;;
        2)
            # List all categories
            log_step "Retrieving URL categories..."
            local categories
            categories=$(get_url_category_list)
            
            if [ -z "${categories}" ]; then
                log_error "No URL categories found."
                press_enter_to_continue
                return
            fi
            
            # Display available categories
            echo ""
            echo -e "  ${WHITE}Available URL Categories:${NC}"
            echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
            local i=1
            local cat_array=()
            while IFS= read -r cat; do
                printf "    ${YELLOW}%3d)${NC} ${WHITE}%s${NC}\n" "${i}" "${cat}" >&2
                cat_array+=("${cat}")
                i=$((i + 1))
            done <<< "${categories}"
            echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
            echo -e "      ${YELLOW}0)${NC} ${WHITE}Cancel${NC}"
            echo ""
            
            # Select category
            read -rp "  Select URL category [0-$((${#cat_array[@]}))] : " cat_choice
            
            if [ "${cat_choice}" == "0" ] || [ -z "${cat_choice}" ]; then
                log_info "Cancelled."
                press_enter_to_continue
                return
            fi
            
            if ! [[ "${cat_choice}" =~ ^[0-9]+$ ]] || [ "${cat_choice}" -lt 1 ] || [ "${cat_choice}" -gt ${#cat_array[@]} ]; then
                log_warn "Invalid selection."
                press_enter_to_continue
                return
            fi
            
            selected_category="${cat_array[$((cat_choice - 1))]}"
            ;;
        *)
            log_warn "Invalid selection."
            press_enter_to_continue
            return
            ;;
    esac
    
    log_info "Selected category: ${selected_category}"
    
    # Get category details
    local url_count
    url_count=$(get_url_category_count "${selected_category}")
    
    if [ "${url_count}" -eq 0 ]; then
        log_warn "Category '${selected_category}' has no URLs."
        press_enter_to_continue
        return
    fi
    
    log_info "URLs in category: ${url_count}"
    
    # Default export path
    local safe_name
    safe_name=$(echo "${selected_category}" | sed 's/[^a-zA-Z0-9_-]/_/g')
    local default_path="${BACKUP_DIR}/urlcat_${safe_name}_${TIMESTAMP}.csv"
    echo ""
    read -rp "  Export path [${default_path}]: " export_path
    export_path="${export_path:-${default_path}}"
    
    # Ask about format
    echo ""
    echo -e "  ${WHITE}Export format:${NC}"
    echo -e "    ${YELLOW}1)${NC} ${WHITE}Domain only (e.g., example.com)${NC}"
    echo -e "    ${YELLOW}2)${NC} ${WHITE}Full URL format (e.g., https://example.com/)${NC}"
    echo ""
    read -rp "  Select [1-2] [1]: " format_choice
    format_choice="${format_choice:-1}"
    
    local strip_protocol=true
    if [ "${format_choice}" == "2" ]; then
        strip_protocol=false
    fi
    
    # Ensure directory exists
    local export_dir
    export_dir=$(dirname "${export_path}")
    if [ ! -d "${export_dir}" ]; then
        mkdir -p "${export_dir}" 2>/dev/null || {
            log_error "Could not create directory: ${export_dir}"
            press_enter_to_continue
            return
        }
    fi
    
    # Export
    log_step "Exporting URL category..."
    local url_entries
    url_entries=$(get_url_category_entries "${selected_category}")
    
    {
        echo "# URL Category Export: ${selected_category}"
        echo "# Exported: $(date)"
        echo "# Format: one URL per line"
        echo "#"
        while IFS= read -r url; do
            [ -z "${url}" ] && continue
            if [ "${strip_protocol}" == "true" ]; then
                # Convert to domain format - strip protocol and path
                # Convert wildcard prefix (\*. or *.) to leading dot for reimport compatibility
                echo "${url}" | sed -E 's|^https?://||; s|/.*$||; s|^\\\*\.|.|; s|^\*\.|.|'
            else
                echo "${url}"
            fi
        done <<< "${url_entries}"
    } > "${export_path}"
    
    if [ -f "${export_path}" ]; then
        local record_count
        record_count=$(grep -cv '^\s*#\|^\s*$' "${export_path}" 2>/dev/null || echo "0")
        log_ok "Exported ${record_count} URLs to: ${export_path}"
    else
        log_error "Export failed."
    fi
    
    press_enter_to_continue
}

# =============================================================================
# URL CATEGORY CONVERSION
# =============================================================================

# Get list of custom URL categories
# Returns: category names, one per line
get_url_category_list() {
    tmsh list sys url-db url-category one-line 2>/dev/null \
        | grep "^sys url-db url-category" \
        | awk '{print $4}' \
        | sort || true
}

# Get URL entries from a URL category
# Returns: raw URL entries, one per line
get_url_category_entries() {
    local category="$1"
    tmsh list sys url-db url-category "${category}" urls 2>/dev/null \
        | grep -E '^\s*http' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*{.*$//' || true
}

# Format URL for SSLO datagroup (domain-only format)
# Strips protocol, converts wildcard to leading dot, removes path
# Input: https://\*.example.com/ or https://www.example.com/path
# Output: .example.com or www.example.com
format_url_for_sslo() {
    local url="$1"
    local domain
    
    # Remove protocol
    domain=$(echo "${url}" | sed -E 's|^https?://||')
    
    # Handle wildcards: \* at start becomes leading dot (for wildcard matching)
    domain=$(echo "${domain}" | sed -E 's|^\\\*\.?|.|')
    
    # Remove path (everything after first /)
    domain=$(echo "${domain}" | sed -E 's|/.*$||')
    
    # Remove port if present
    domain=$(echo "${domain}" | sed -E 's|:[0-9]+$||')
    
    # Remove any trailing dots
    domain=$(echo "${domain}" | sed 's/\.$//')
    
    echo "${domain}"
}

# Option 7: Convert URL Category to Datagroup
menu_convert_url_category() {
    log_section "Convert URL Category to Datagroup"
    
    # Check if URL database is available
    if ! tmsh list sys url-db url-category one-line &>/dev/null; then
        log_error "URL database not available or accessible."
        log_info "This feature requires the URL filtering module."
        press_enter_to_continue
        return
    fi
    
    # Offer choice: enter name directly or list all
    echo ""
    echo -e "  ${WHITE}How would you like to select a URL category?${NC}"
    echo -e "    ${YELLOW}1)${NC} ${WHITE}Enter category name directly${NC}"
    echo -e "    ${YELLOW}2)${NC} ${WHITE}List all categories (may take a while)${NC}"
    echo -e "    ${YELLOW}0)${NC} ${WHITE}Cancel${NC}"
    echo ""
    read -rp "  Select [0-2]: " method_choice
    
    local selected_category=""
    
    case "${method_choice}" in
        0|"")
            log_info "Cancelled."
            press_enter_to_continue
            return
            ;;
        1)
            # Direct entry with retry loop
            while true; do
                echo ""
                read -rp "  Enter URL category name (or 'q' to cancel): " selected_category
                
                if [ -z "${selected_category}" ]; then
                    log_warn "No category name provided."
                    continue
                fi
                
                if [ "${selected_category}" == "q" ] || [ "${selected_category}" == "Q" ]; then
                    log_info "Cancelled."
                    press_enter_to_continue
                    return
                fi
                
                # Verify category exists - try exact name first
                if tmsh list sys url-db url-category "${selected_category}" &>/dev/null; then
                    # Found with exact name
                    break
                fi
                
                # Try with sslo-urlCat prefix (SSLO custom categories)
                local sslo_name="sslo-urlCat${selected_category}"
                if tmsh list sys url-db url-category "${sslo_name}" &>/dev/null; then
                    log_info "Found as SSLO category: ${sslo_name}"
                    selected_category="${sslo_name}"
                    break
                fi
                
                # Neither found
                log_error "Category '${selected_category}' not found."
                continue
            done
            ;;
        2)
            # List all categories
            log_step "Retrieving URL categories..."
            local categories
            categories=$(get_url_category_list)
            
            if [ -z "${categories}" ]; then
                log_error "No URL categories found."
                press_enter_to_continue
                return
            fi
            
            # Display available categories
            echo ""
            echo -e "  ${WHITE}Available URL Categories:${NC}"
            echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
            local i=1
            local cat_array=()
            while IFS= read -r cat; do
                printf "    ${YELLOW}%3d)${NC} ${WHITE}%s${NC}\n" "${i}" "${cat}" >&2
                cat_array+=("${cat}")
                i=$((i + 1))
            done <<< "${categories}"
            echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
            echo -e "      ${YELLOW}0)${NC} ${WHITE}Cancel${NC}"
            echo ""
            
            # Select category
            read -rp "  Select URL category [0-$((${#cat_array[@]}))] : " cat_choice
            
            if [ "${cat_choice}" == "0" ] || [ -z "${cat_choice}" ]; then
                log_info "Cancelled."
                press_enter_to_continue
                return
            fi
            
            if ! [[ "${cat_choice}" =~ ^[0-9]+$ ]] || [ "${cat_choice}" -lt 1 ] || [ "${cat_choice}" -gt ${#cat_array[@]} ]; then
                log_warn "Invalid selection."
                press_enter_to_continue
                return
            fi
            
            selected_category="${cat_array[$((cat_choice - 1))]}"
            ;;
        *)
            log_warn "Invalid selection."
            press_enter_to_continue
            return
            ;;
    esac
    
    log_info "Selected category: ${selected_category}"
    
    # Get and preview entries
    log_step "Extracting URLs from category..."
    local url_entries
    url_entries=$(get_url_category_entries "${selected_category}")
    
    if [ -z "${url_entries}" ]; then
        log_error "No URL entries found in category '${selected_category}'."
        press_enter_to_continue
        return
    fi
    
    local url_count
    url_count=$(echo "${url_entries}" | wc -l)
    log_ok "Found ${url_count} URL entries"
    
    # Parse URLs and preview
    echo ""
    echo -e "  ${WHITE}Preview of conversion (first ${PREVIEW_LINES} entries):${NC}"
    echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
    printf "  ${WHITE}%-45s  →  %s${NC}\n" "URL CATEGORY ENTRY" "SSLO DOMAIN"
    echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
    
    local preview_count=0
    local converted_entries=()
    while IFS= read -r url; do
        [ -z "${url}" ] && continue
        local converted
        converted=$(format_url_for_sslo "${url}")
        converted_entries+=("${converted}")
        
        preview_count=$((preview_count + 1))
        if [ ${preview_count} -le ${PREVIEW_LINES} ]; then
            printf "  ${WHITE}%-45s${NC}  →  ${WHITE}%s${NC}\n" "${url:0:45}" "${converted}"
        fi
    done <<< "${url_entries}"
    
    echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
    log_info "Total: ${#converted_entries[@]} entries extracted"
    echo ""
    
    # Check for duplicates after parsing
    local unique_entries
    unique_entries=$(printf '%s\n' "${converted_entries[@]}" | sort -u)
    local unique_count
    unique_count=$(echo "${unique_entries}" | wc -l)
    
    if [ "${unique_count}" -lt "${#converted_entries[@]}" ]; then
        local dup_count=$((${#converted_entries[@]} - unique_count))
        log_info "Note: ${dup_count} duplicate(s) will be deduplicated."
    fi
    
    # Select partition
    local partition
    partition=$(select_partition "Select partition for new datagroup")
    if [ -z "${partition}" ]; then
        log_info "Cancelled."
        press_enter_to_continue
        return
    fi
    
    # Get datagroup name (default to category name)
    local default_name
    default_name=$(echo "${selected_category}" | sed 's/[^a-zA-Z0-9_-]/_/g')
    echo ""
    read -rp "  Enter datagroup name [${default_name}]: " dg_name
    dg_name="${dg_name:-${default_name}}"
    
    # Sanitize name
    dg_name=$(echo "${dg_name}" | sed 's/[^a-zA-Z0-9_-]/_/g')
    
    # Check if name is protected
    if is_protected_datagroup "${dg_name}"; then
        log_error "The name '${dg_name}' is reserved for a BIG-IP system datagroup."
        press_enter_to_continue
        return
    fi
    
    # Check if datagroup already exists
    local existing_class
    existing_class=$(datagroup_exists "${partition}" "${dg_name}")
    
    if [ -n "${existing_class}" ]; then
        log_warn "Datagroup '${dg_name}' already exists as ${existing_class} in partition '${partition}'."
        echo ""
        echo -e "  ${WHITE}How do you want to proceed?${NC}"
        echo -e "    ${YELLOW}1)${NC} ${WHITE}Overwrite - Replace existing datagroup contents${NC}"
        echo -e "    ${YELLOW}2)${NC} ${WHITE}Merge     - Add new entries to existing (deduplicated)${NC}"
        echo -e "    ${YELLOW}3)${NC} ${WHITE}Cancel${NC}"
        echo ""
        read -rp "  Select [1-3]: " exist_choice
        
        case "${exist_choice}" in
            1) 
                # Backup before overwrite
                log_step "Creating backup of existing datagroup..."
                local backup_file
                backup_file=$(backup_datagroup "${partition}" "${dg_name}" "${existing_class}")
                if [ -n "${backup_file}" ]; then
                    log_ok "Backup saved: ${backup_file}"
                else
                    log_warn "Could not create backup."
                    read -rp "  Continue without backup? (yes/no) [no]: " cont
                    if [ "${cont}" != "yes" ]; then
                        log_info "Aborted."
                        press_enter_to_continue
                        return
                    fi
                fi
                ;;
            2)
                # Merge mode - get existing entries first
                log_step "Reading existing entries for merge..."
                local backup_file
                backup_file=$(backup_datagroup "${partition}" "${dg_name}" "${existing_class}")
                if [ -n "${backup_file}" ]; then
                    log_ok "Backup saved: ${backup_file}"
                fi
                
                # Use associative array for deduplication
                declare -A merged_entries
                
                # Add existing entries
                while IFS='|' read -r key value; do
                    [ -z "${key}" ] && continue
                    merged_entries["${key}"]="${value}"
                done < <(get_datagroup_records "${partition}" "${dg_name}" "${existing_class}")
                
                local existing_count=${#merged_entries[@]}
                
                # Add new entries
                while IFS= read -r entry; do
                    [ -z "${entry}" ] && continue
                    merged_entries["${entry}"]=""
                done <<< "${unique_entries}"
                
                local final_count=${#merged_entries[@]}
                local new_added=$((final_count - existing_count))
                
                log_info "Existing: ${existing_count}, New unique: ${new_added}, Final: ${final_count}"
                
                # Convert back to list
                unique_entries=""
                for key in "${!merged_entries[@]}"; do
                    unique_entries="${unique_entries}${key}"$'\n'
                done
                unique_entries=$(echo "${unique_entries}" | sed '/^$/d')
                unique_count=${final_count}
                ;;
            *)
                log_info "Cancelled."
                press_enter_to_continue
                return
                ;;
        esac
    fi
    
    # Select datagroup class (internal vs external)
    echo ""
    echo -e "  ${WHITE}Select datagroup class:${NC}"
    echo -e "    ${YELLOW}1)${NC} ${WHITE}Internal - Stored in bigip.conf (best for <1000 entries)${NC}"
    echo -e "    ${YELLOW}2)${NC} ${WHITE}External - Stored in separate file (best for large lists)${NC}"
    echo ""
    
    local recommended=""
    if [ ${unique_count} -gt 1000 ]; then
        recommended=" (recommended for ${unique_count} entries)"
    fi
    
    read -rp "  Select [1-2]: " class_choice
    
    local dg_class
    case "${class_choice}" in
        1) dg_class="internal" ;;
        2) dg_class="external" ;;
        *)
            log_warn "Invalid selection."
            press_enter_to_continue
            return
            ;;
    esac
    
    if [ ${unique_count} -gt 1000 ] && [ "${dg_class}" == "internal" ]; then
        log_warn "You have ${unique_count} entries. Internal datagroups work best with <1000 entries."
        read -rp "  Continue with internal? (yes/no) [no]: " cont
        if [ "${cont}" != "yes" ]; then
            log_info "Aborted."
            press_enter_to_continue
            return
        fi
    fi
    
    # Confirm
    echo ""
    log_info "Ready to create datagroup:"
    log_info "  Source:    URL Category '${selected_category}'"
    log_info "  Target:    /${partition}/${dg_name}"
    log_info "  Class:     ${dg_class}"
    log_info "  Type:      string"
    log_info "  Entries:   ${unique_count}"
    echo ""
    read -rp "  Proceed? (yes/no) [no]: " confirm
    
    if [ "${confirm}" != "yes" ]; then
        log_info "Aborted."
        press_enter_to_continue
        return
    fi
    
    # Build arrays for datagroup creation
    local -a DG_KEYS=()
    local -a DG_VALUES=()
    
    while IFS= read -r entry; do
        [ -z "${entry}" ] && continue
        DG_KEYS+=("${entry}")
        DG_VALUES+=("")
    done <<< "${unique_entries}"
    
    # Create or update the datagroup
    if [ "${dg_class}" == "external" ]; then
        # External datagroup
        if [ -n "${existing_class}" ]; then
            log_step "Updating external datagroup..."
            if ! update_external_datagroup "${partition}" "${dg_name}" "string" DG_KEYS DG_VALUES; then
                log_error "Failed to update external datagroup."
                press_enter_to_continue
                return
            fi
        else
            log_step "Creating external datagroup..."
            if ! create_external_datagroup "${partition}" "${dg_name}" "string" DG_KEYS DG_VALUES; then
                log_error "Failed to create external datagroup."
                press_enter_to_continue
                return
            fi
        fi
    else
        # Internal datagroup
        log_step "Building datagroup records..."
        local records
        records=$(build_tmsh_records DG_KEYS DG_VALUES "string")
        
        if [ -z "${existing_class}" ]; then
            # Create new internal datagroup
            log_step "Creating internal datagroup..."
            if ! tmsh create ltm data-group internal "/${partition}/${dg_name}" type string 2>&1; then
                log_error "Failed to create datagroup."
                press_enter_to_continue
                return
            fi
        fi
        
        log_step "Populating datagroup with ${#DG_KEYS[@]} entries..."
        if ! apply_datagroup_records "${partition}" "${dg_name}" "${records}"; then
            log_error "Failed to populate datagroup."
            press_enter_to_continue
            return
        fi
    fi
    
    log_ok "Datagroup '/${partition}/${dg_name}' created successfully with ${#DG_KEYS[@]} entries."
    log_info "Source: URL Category '${selected_category}'"
    
    prompt_save_config
    press_enter_to_continue
}

# =============================================================================
# URL CATEGORY CREATION FROM CSV
# =============================================================================

# Check if URL category exists
# Returns: 0 if exists, 1 if not
url_category_exists() {
    local cat_name="$1"
    tmsh list sys url-db url-category "${cat_name}" &>/dev/null
    return $?
}

# Get URL entries from an existing URL category
# Returns: count of URLs
get_url_category_count() {
    local cat_name="$1"
    tmsh list sys url-db url-category "${cat_name}" urls 2>/dev/null \
        | grep -cE '^\s*http' || echo "0"
}

# Format domain/URL for URL category (F5 URL category format)
# Input: domain like "example.com" or ".example.com" or "www.example.com"
# Output: https://example.com/ or https://*.example.com/
format_domain_for_url_category() {
    local domain="$1"
    
    # Remove any existing protocol
    domain=$(echo "${domain}" | sed -E 's|^https?://||')
    
    # Remove trailing slashes
    domain=$(echo "${domain}" | sed 's|/.*$||')
    
    # Handle leading dot (wildcard) - convert to *. format
    if [[ "${domain}" == .* ]]; then
        domain="*${domain}"
    fi
    
    # Add https:// prefix and trailing /
    echo "https://${domain}/"
}

# Option 3b: Create URL Category from CSV
menu_create_url_category() {
    log_section "Create URL Category from CSV"
    
    # Check if URL database is available
    if ! tmsh list sys url-db url-category one-line &>/dev/null; then
        log_error "URL database not available or accessible."
        log_info "This feature requires the URL filtering module."
        press_enter_to_continue
        return
    fi
    
    # Get category name
    echo ""
    read -rp "  Enter URL category name: " cat_name
    
    if [ -z "${cat_name}" ]; then
        log_warn "No category name provided."
        press_enter_to_continue
        return
    fi
    
    # Sanitize name (URL categories typically use sslo-urlCat prefix for SSLO)
    local original_name="${cat_name}"
    cat_name=$(echo "${cat_name}" | sed 's/[^a-zA-Z0-9_-]/_/g')
    
    if [ "${cat_name}" != "${original_name}" ]; then
        log_info "Category name sanitized to: ${cat_name}"
    fi
    
    # Check if category already exists
    local restore_mode=""
    if url_category_exists "${cat_name}"; then
        local current_count
        current_count=$(get_url_category_count "${cat_name}")
        
        log_info "URL category '${cat_name}' already exists with ${current_count} URLs."
        echo ""
        echo -e "  ${WHITE}How do you want to proceed?${NC}"
        echo -e "    ${YELLOW}1)${NC} ${WHITE}Overwrite - Replace all existing URLs${NC}"
        echo -e "    ${YELLOW}2)${NC} ${WHITE}Merge     - Add new URLs to existing (deduplicated)${NC}"
        echo -e "    ${YELLOW}3)${NC} ${WHITE}Cancel${NC}"
        echo ""
        read -rp "  Select [1-3]: " exist_choice
        
        case "${exist_choice}" in
            1) restore_mode="overwrite" ;;
            2) restore_mode="merge" ;;
            *)
                log_info "Cancelled."
                press_enter_to_continue
                return
                ;;
        esac
    fi
    
    # Get CSV file path
    local csv_path=""
    while true; do
        echo ""
        read -rp "  Enter path to CSV file (or 'q' to cancel): " csv_path
        
        if [ -z "${csv_path}" ]; then
            log_warn "No file path provided."
            continue
        fi
        
        if [ "${csv_path}" == "q" ] || [ "${csv_path}" == "Q" ]; then
            log_info "Cancelled."
            press_enter_to_continue
            return
        fi
        
        # If no path separator, assume current working directory
        if [[ "${csv_path}" != /* ]]; then
            csv_path="$(pwd)/${csv_path}"
        fi
        
        if [ ! -f "${csv_path}" ]; then
            log_error "File not found: ${csv_path}"
            continue
        fi
        
        break
    done
    
    # Check for Windows line endings
    local temp_csv=""
    if has_windows_line_endings "${csv_path}"; then
        log_warn "File has Windows line endings (CRLF). Converting..."
        temp_csv="${EXTERNAL_TEMP_DIR}/import_cat_${TIMESTAMP}.csv"
        cp "${csv_path}" "${temp_csv}"
        convert_line_endings "${temp_csv}"
        csv_path="${temp_csv}"
    fi
    
    # Preview the file
    preview_csv_file "${csv_path}"
    
    # Parse CSV - keys only (domains)
    log_step "Parsing CSV file..."
    if ! parse_csv_file "${csv_path}" "keys_only"; then
        log_error "Failed to parse CSV file."
        [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
        press_enter_to_continue
        return
    fi
    log_ok "Parsed ${#CSV_KEYS[@]} entries"
    
    # Convert domains to URL category format and preview
    echo ""
    echo -e "  ${WHITE}Preview of URL conversion (first ${PREVIEW_LINES} entries):${NC}"
    echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
    printf "  ${WHITE}%-35s  →  %s${NC}\n" "CSV ENTRY" "URL CATEGORY FORMAT"
    echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
    
    local -a converted_urls=()
    local preview_count=0
    for domain in "${CSV_KEYS[@]}"; do
        local url
        url=$(format_domain_for_url_category "${domain}")
        converted_urls+=("${url}")
        
        preview_count=$((preview_count + 1))
        if [ ${preview_count} -le ${PREVIEW_LINES} ]; then
            printf "  ${WHITE}%-35s${NC}  →  ${WHITE}%s${NC}\n" "${domain:0:35}" "${url}"
        fi
    done
    echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
    
    # Handle merge mode - get existing URLs
    if [ "${restore_mode}" == "merge" ]; then
        log_step "Reading existing URLs for merge..."
        local existing_urls
        existing_urls=$(get_url_category_entries "${cat_name}")
        
        # Use associative array for deduplication
        declare -A url_set
        
        # Add existing URLs
        while IFS= read -r url; do
            [ -z "${url}" ] && continue
            url_set["${url}"]=1
        done <<< "${existing_urls}"
        
        local existing_count=${#url_set[@]}
        
        # Add new URLs
        for url in "${converted_urls[@]}"; do
            url_set["${url}"]=1
        done
        
        local final_count=${#url_set[@]}
        local new_added=$((final_count - existing_count))
        
        log_info "Existing: ${existing_count}, New unique: ${new_added}, Final: ${final_count}"
        
        # Convert back to array
        converted_urls=()
        for url in "${!url_set[@]}"; do
            converted_urls+=("${url}")
        done
    fi
    
    # Variables for category settings
    local default_action=""
    
    # Only ask for settings if creating new or overwriting (not merge)
    if [ "${restore_mode}" != "merge" ]; then
        # Select default action
        echo ""
        echo -e "  ${WHITE}Select default action for this category:${NC}"
        echo -e "    ${YELLOW}1)${NC} ${WHITE}allow   - Allow traffic (use for bypass lists)${NC}"
        echo -e "    ${YELLOW}2)${NC} ${WHITE}block   - Block traffic${NC}"
        echo -e "    ${YELLOW}3)${NC} ${WHITE}confirm - Prompt user for confirmation${NC}"
        echo ""
        read -rp "  Select [1-3] [1]: " action_choice
        action_choice="${action_choice:-1}"
        
        case "${action_choice}" in
            1) default_action="allow" ;;
            2) default_action="block" ;;
            3) default_action="confirm" ;;
            *)
                log_warn "Invalid selection, defaulting to 'allow'."
                default_action="allow"
                ;;
        esac
    fi
    
    # Confirm
    echo ""
    log_info "Ready to create URL category:"
    log_info "  Name:         ${cat_name}"
    log_info "  URLs:         ${#converted_urls[@]}"
    if [ -n "${default_action}" ]; then
        log_info "  Action:       ${default_action}"
    fi
    if [ -n "${restore_mode}" ]; then
        log_info "  Mode:         ${restore_mode}"
    fi
    echo ""
    read -rp "  Proceed? (yes/no) [no]: " confirm
    
    if [ "${confirm}" != "yes" ]; then
        log_info "Aborted."
        [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
        press_enter_to_continue
        return
    fi
    
    # Build URLs block for tmsh
    local urls_block=""
    for url in "${converted_urls[@]}"; do
        urls_block="${urls_block} ${url} { }"
    done
    
    # Create or update the URL category
    if [ "${restore_mode}" == "overwrite" ]; then
        # Delete and recreate
        log_step "Removing existing URL category..."
        if ! tmsh delete sys url-db url-category "${cat_name}" 2>/dev/null; then
            log_warn "Could not delete existing category (may not exist)."
        fi
    fi
    
    if [ -z "${restore_mode}" ] || [ "${restore_mode}" == "overwrite" ]; then
        # Create new category
        log_step "Creating URL category '${cat_name}'..."
        if ! tmsh create sys url-db url-category "${cat_name}" display-name "${cat_name}" default-action "${default_action}" urls add \{ ${urls_block} \} 2>&1; then
            log_error "Failed to create URL category."
            [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
            press_enter_to_continue
            return
        fi
    else
        # Merge - modify existing
        log_step "Adding URLs to existing category '${cat_name}'..."
        if ! tmsh modify sys url-db url-category "${cat_name}" urls add \{ ${urls_block} \} 2>&1; then
            log_error "Failed to update URL category."
            [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
            press_enter_to_continue
            return
        fi
    fi
    
    log_ok "URL category '${cat_name}' created successfully with ${#converted_urls[@]} URLs."
    
    prompt_save_config
    
    # Cleanup
    [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
    
    press_enter_to_continue
}

main() {
    # Clear screen on start
    clear
    
    # Ensure backup/log directory exists
    mkdir -p "${BACKUP_DIR}" 2>/dev/null
    
    # Initialize log
    echo "DGCat-Admin v1.0 - F5 BIG-IP Administration Tool" > "${LOGFILE}"
    echo "Started: $(date)" >> "${LOGFILE}"
    
    # Run pre-flight checks
    preflight_checks
    
    press_enter_to_continue
    
    # Main menu loop
    while true; do
        show_main_menu
        read -rp "  Select option [0-6]: " choice
        
        case "${choice}" in
            1) menu_list_datagroups ;;
            2) menu_view_datagroup ;;
            3) menu_create_from_csv ;;
            4) menu_delete_datagroup ;;
            5) menu_export_to_csv ;;
            6) menu_convert_url_category ;;
            0)
                log_section "Exit"
                log_info "Session ended: $(date)"
                log_info "Log file: ${LOGFILE}"
                echo ""
                exit 0
                ;;
            *)
                log_warn "Invalid selection. Please choose 0-6."
                press_enter_to_continue
                ;;
        esac
    done
}

# Global arrays for CSV parsing
declare -a CSV_KEYS
declare -a CSV_VALUES

main "$@"
