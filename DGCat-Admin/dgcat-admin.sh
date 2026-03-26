#!/bin/bash
# =============================================================================
# DGCat-Admin - F5 BIG-IP Datagroup and URL Category Administration Tool
# =============================================================================
# Version:  2.0
# Author:   Eric Haupt
#
# Requirements: BIG-IP TMOS 17.x or higher
#
# PURPOSE:
#   Menu-driven tool for managing LTM datagroups and URL categories used in 
#   SSL Orchestrator policies. Supports both INTERNAL and EXTERNAL datagroups 
#   with bulk import/export via CSV files, backup before modifications, type 
#   validation, and bidirectional conversion between datagroups and URL 
#   categories.
#
# USAGE:
#   chmod +x dgcat-admin.sh
#   ./dgcat-admin.sh
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

# =============================================================================
# SESSION MODE VARIABLES
# =============================================================================

# Session mode: "tmsh" or "rest-api"
# - tmsh:     Uses tmsh commands directly (must run on BIG-IP or have tmsh access)
# - rest-api: Uses REST API via curl (can run from any machine with network access)
SESSION_MODE=""

# REST API connection settings (used only in rest-api mode)
REMOTE_HOST=""
REMOTE_USER=""
REMOTE_PASS=""

# API response storage (used only in REST API mode)
API_RESPONSE=""
API_HTTP_CODE=""

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
    echo -e "$1" | tee -a "${LOGFILE}" 2>/dev/null
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
        if ! mkdir -p "${BACKUP_DIR}" 2>/dev/null; then
            return 1
        fi
    fi
    
    # Verify write access
    if ! touch "${BACKUP_DIR}/.write_test" 2>/dev/null; then
        return 1
    fi
    rm -f "${BACKUP_DIR}/.write_test" 2>/dev/null
    return 0
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
    
    echo -e "${WHITE}  [....] Retrieving datagroups...${NC}" >&2
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
    read -rp "  ${prompt} (or 'q' to cancel): " dg_name
    
    if [ -z "${dg_name}" ] || [ "${dg_name}" == "q" ] || [ "${dg_name}" == "Q" ]; then
        echo -e "${WHITE}  [INFO]  Cancelled.${NC}" >&2
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
        if save_config; then
            log_ok "Configuration saved."
        else
            if [ "${SESSION_MODE}" == "rest-api" ]; then
                log_warn "Could not save configuration. Save manually via BIG-IP GUI or tmsh."
            else
                log_warn "Could not save configuration. Run 'tmsh save sys config' manually."
            fi
        fi
    fi
}

# =============================================================================
# REST API MODE FUNCTIONS
# =============================================================================
# These functions provide REST API access to BIG-IP for REST API operations.
# Used only when SESSION_MODE="rest-api"

# -----------------------------------------------------------------------------
# API Helper Functions
# -----------------------------------------------------------------------------

# Base API request function
# Args: method, endpoint, [data]
# Sets: API_RESPONSE, API_HTTP_CODE
# Returns: 0 on success (2xx), 1 on failure
api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    local url="https://${REMOTE_HOST}${endpoint}"
    local auth="${REMOTE_USER}:${REMOTE_PASS}"
    
    local curl_opts=(
        -sk
        -u "${auth}"
        -H "Content-Type: application/json"
        -X "${method}"
        -w "\n%{http_code}"
    )
    
    if [ -n "${data}" ]; then
        curl_opts+=(-d "${data}")
    fi
    
    local response
    response=$(curl "${curl_opts[@]}" "${url}" 2>/dev/null) || {
        API_RESPONSE=""
        API_HTTP_CODE="000"
        return 1
    }
    
    # Split response body and HTTP code
    API_HTTP_CODE=$(echo "${response}" | tail -1)
    API_RESPONSE=$(echo "${response}" | sed '$d')
    
    # Check for success (2xx codes)
    if [[ "${API_HTTP_CODE}" =~ ^2[0-9]{2}$ ]]; then
        return 0
    fi
    
    return 1
}

# GET request wrapper
api_get() {
    local endpoint="$1"
    api_request "GET" "${endpoint}"
    return $?
}

# POST request wrapper
api_post() {
    local endpoint="$1"
    local data="$2"
    api_request "POST" "${endpoint}" "${data}"
    return $?
}

# PATCH request wrapper
api_patch() {
    local endpoint="$1"
    local data="$2"
    api_request "PATCH" "${endpoint}" "${data}"
    return $?
}

# DELETE request wrapper
api_delete() {
    local endpoint="$1"
    api_request "DELETE" "${endpoint}"
    return $?
}

# -----------------------------------------------------------------------------
# REST API Connection Functions
# -----------------------------------------------------------------------------

# Prompt for REST API connection details and test connection
# Returns: 0 on successful connection, 1 on failure
setup_remote_connection() {
    log_section "REST API Connection Setup"
    
    echo ""
    read -rp "  BIG-IP hostname or IP: " REMOTE_HOST
    
    if [ -z "${REMOTE_HOST}" ]; then
        log_error "No hostname provided."
        return 1
    fi
    
    read -rp "  Username: " REMOTE_USER
    
    if [ -z "${REMOTE_USER}" ]; then
        log_error "No username provided."
        return 1
    fi
    
    read -srp "  Password: " REMOTE_PASS
    echo ""
    
    if [ -z "${REMOTE_PASS}" ]; then
        log_error "No password provided."
        return 1
    fi
    
    # Test connection
    log_step "Connecting to ${REMOTE_HOST}..."
    if api_get "/mgmt/tm/sys/version"; then
        local version
        version=$(echo "${API_RESPONSE}" | jq -r '.entries[].nestedStats.entries.Version.description // empty' 2>/dev/null | head -1)
        if [ -n "${version}" ]; then
            log_ok "Connected to BIG-IP version ${version}"
        else
            log_ok "Connected to ${REMOTE_HOST}"
        fi
        return 0
    else
        if [ "${API_HTTP_CODE}" == "401" ]; then
            log_error "Authentication failed. Check username/password."
        elif [ "${API_HTTP_CODE}" == "000" ]; then
            log_error "Connection failed. Check hostname and network connectivity."
        else
            log_error "Connection failed. HTTP ${API_HTTP_CODE}"
        fi
        return 1
    fi
}

# Display mode selection menu
# Sets: SESSION_MODE
# Returns: 0 always
select_session_mode() {
    clear
    echo ""
    echo -e "  ${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}║${NC}${WHITE}                    DGCAT-Admin v2.0                        ${NC}${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}${WHITE}               F5 BIG-IP Administration Tool                ${NC}${CYAN}║${NC}"
    echo -e "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}   ${WHITE}Select operating mode:${NC}                                   ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}    ${YELLOW}1)${NC}  ${WHITE}TMSH     - Use tmsh commands locally${NC}                ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}    ${YELLOW}2)${NC}  ${WHITE}REST API - Use iControl REST API${NC}                    ${CYAN}║${NC}"
	echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}"
    echo -e "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"  
    echo -e "  ${CYAN}║${NC}    ${YELLOW}0)${NC}  ${WHITE}Exit${NC}                                                ${CYAN}║${NC}"
    echo -e "  ${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    while true; do
        read -rp "  Select [0-2]: " mode_choice
        
        case "${mode_choice}" in
            1)
                SESSION_MODE="tmsh"
                return 0
                ;;
            2)
                SESSION_MODE="rest-api"
                return 0
                ;;
            0)
                echo ""
                echo -e "  ${WHITE}Exiting.${NC}"
                echo ""
                exit 0
                ;;
            *)
                log_warn "Invalid selection. Please choose 0, 1, or 2."
                ;;
        esac
    done
}

# Pre-flight checks for REST API mode
# Validates dependencies and establishes connection
# Returns: 0 on success, exits on critical failure
preflight_checks_rest_api() {
    log_section "Pre-Flight Checks (REST API Mode)"
    
    # Check for curl
    if ! command -v curl &>/dev/null; then
        log_error "curl not found. Required for REST API operations."
        log_error "Install curl and try again."
        exit 1
    fi
    log_ok "curl found"
    
    # Check for jq
    if ! command -v jq &>/dev/null; then
        log_error "jq not found. Required for JSON parsing."
        log_error "Install jq and try again."
        exit 1
    fi
    log_ok "jq found"
    
    # Parse partitions
    parse_partitions
    if [ ${#PARTITION_LIST[@]} -eq 0 ]; then
        log_error "No partitions configured. Check PARTITIONS setting."
        exit 1
    fi
    log_ok "Configured partitions: ${PARTITIONS}"
    
    # Establish REST API connection (with retry loop)
    while true; do
        if setup_remote_connection; then
            break
        fi
        echo ""
        read -rp "  Retry connection? (yes/no) [yes]: " retry
        retry="${retry:-yes}"
        if [ "${retry}" != "yes" ]; then
            log_info "Exiting."
            exit 0
        fi
    done
    
    # Validate partitions exist on target system
    log_step "Validating partitions on target system..."
    local invalid_count=0
    for partition in "${PARTITION_LIST[@]}"; do
        if ! partition_exists_remote "${partition}"; then
            log_warn "Partition '${partition}' not found on ${REMOTE_HOST}"
            invalid_count=$((invalid_count + 1))
        fi
    done
    
    if [ ${invalid_count} -gt 0 ]; then
        log_warn "${invalid_count} configured partition(s) not found. They will be skipped."
    else
        log_ok "All partitions validated"
    fi
    
    # Setup backup directory on local machine
    if ! ensure_backup_dir; then
        log_warn "Cannot create or access backup directory: ${BACKUP_DIR}"
        log_warn "Backups will be disabled. Proceed with caution."
    else
        log_ok "Local backup directory: ${BACKUP_DIR}"
    fi
    
    log ""
    log_info "REST API mode ready. Connected to: ${REMOTE_HOST}"
    log_info "Log file: ${LOGFILE}"
}

# Pre-flight checks for local mode (existing logic, renamed for clarity)
preflight_checks_tmsh() {
    log_section "Pre-Flight Checks (TMSH Mode)"

    # Check for tmsh
    if ! command -v tmsh &>/dev/null; then
        log_error "tmsh not found. This script must be run on a BIG-IP."
        log_error "Use REST API mode to connect to a BIG-IP from another machine."
        exit 1
    fi
    log_ok "tmsh found"

    # Verify we can query datagroups (this confirms sufficient privileges)
    if ! tmsh list ltm data-group internal one-line &>/dev/null; then
        log_error "Cannot query datagroups. Check tmsh access and privileges."
        exit 1
    fi
    log_ok "Datagroup access verified"

    # Get current user for logging
    local current_user
    current_user=$(whoami 2>/dev/null || echo "unknown")
    log_ok "Running as: ${current_user}"

    # Get TMOS version for logging
    local tmos_version
    tmos_version=$(tmsh show sys version | grep "^\s*Version" | awk '{print $2}' | head -1 2>/dev/null || echo "unknown")
    log_ok "TMOS Version: ${tmos_version}"

    # Ensure backup directory exists
    if ! ensure_backup_dir; then
        log_warn "Cannot create or access backup directory: ${BACKUP_DIR}"
        log_warn "Backups will be disabled. Proceed with caution."
    else
        log_ok "Backup/Log directory: ${BACKUP_DIR}"
    fi

    # Parse and validate configured partitions
    parse_partitions
    if [ ${#PARTITION_LIST[@]} -eq 0 ]; then
        log_error "No partitions configured. Check PARTITIONS setting."
        exit 1
    fi
    log_ok "Configured partitions: ${PARTITIONS}"
    validate_partitions

    log ""
    log_info "TMSH mode ready."
    log_info "Log file: ${LOGFILE}"
}

# -----------------------------------------------------------------------------
# REST API System Functions
# -----------------------------------------------------------------------------

# Get BIG-IP version via REST API
get_version_remote() {
    if api_get "/mgmt/tm/sys/version"; then
        echo "${API_RESPONSE}" | jq -r '.entries[].nestedStats.entries.Version.description // "unknown"' 2>/dev/null | head -1
        return 0
    fi
    echo "unknown"
    return 1
}

# Save configuration via REST API
save_config_remote() {
    local data='{"command":"save"}'
    if api_post "/mgmt/tm/sys/config" "${data}"; then
        return 0
    fi
    return 1
}

# Check if partition exists via REST API
partition_exists_remote() {
    local partition="$1"
    if api_get "/mgmt/tm/auth/partition/${partition}"; then
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# REST API Internal Datagroup Functions
# -----------------------------------------------------------------------------

# Get list of internal datagroups in a partition via REST API
# Returns: partition|name|internal lines
get_internal_datagroup_list_remote() {
    local partition="$1"
    
    if ! api_get "/mgmt/tm/ltm/data-group/internal?\$filter=partition%20eq%20${partition}"; then
        return 1
    fi
    
    # Parse JSON response - exclude app service datagroups
    echo "${API_RESPONSE}" | jq -r --arg p "${partition}" '
        .items // [] | .[] | 
        select(.partition == $p) |
        select(.fullPath | contains(".app/") | not) |
        "\($p)|\(.name)|internal"
    ' 2>/dev/null || true
}

# Check if internal datagroup exists via REST API
internal_datagroup_exists_remote() {
    local partition="$1"
    local dg_name="$2"
    
    if api_get "/mgmt/tm/ltm/data-group/internal/~${partition}~${dg_name}"; then
        return 0
    fi
    return 1
}

# Get internal datagroup type via REST API
get_internal_datagroup_type_remote() {
    local partition="$1"
    local dg_name="$2"
    
    if api_get "/mgmt/tm/ltm/data-group/internal/~${partition}~${dg_name}"; then
        echo "${API_RESPONSE}" | jq -r '.type // empty' 2>/dev/null
        return 0
    fi
    return 1
}

# Get internal datagroup records as key|value lines via REST API
get_internal_datagroup_records_remote() {
    local partition="$1"
    local dg_name="$2"
    
    if ! api_get "/mgmt/tm/ltm/data-group/internal/~${partition}~${dg_name}"; then
        return 1
    fi
    
    # Parse records from JSON
    echo "${API_RESPONSE}" | jq -r '
        .records // [] | .[] |
        "\(.name)|\(.data // "")"
    ' 2>/dev/null || true
}

# Create internal datagroup via REST API
# Args: partition, name, type
create_internal_datagroup_remote() {
    local partition="$1"
    local dg_name="$2"
    local dg_type="$3"
    
    local data
    data=$(jq -n \
        --arg name "${dg_name}" \
        --arg partition "${partition}" \
        --arg type "${dg_type}" \
        '{name: $name, partition: $partition, type: $type}')
    
    if api_post "/mgmt/tm/ltm/data-group/internal" "${data}"; then
        return 0
    fi
    return 1
}

# Apply records to internal datagroup (replace all) via REST API
# Args: partition, name, records_json
# records_json format: [{"name":"key1","data":"value1"},{"name":"key2"}]
apply_internal_datagroup_records_remote() {
    local partition="$1"
    local dg_name="$2"
    local records_json="$3"
    
    local data
    data=$(jq -n --argjson records "${records_json}" '{records: $records}')
    
    if api_patch "/mgmt/tm/ltm/data-group/internal/~${partition}~${dg_name}" "${data}"; then
        return 0
    fi
    return 1
}

# Build JSON records array from key|value lines
# Input: key|value lines via stdin
# Output: JSON array suitable for REST API
# Args: dg_type (for reference, not currently used in output format)
build_records_json_remote() {
    local dg_type="$1"
    
    jq -Rn '
        [inputs | select(length > 0) | split("|") | 
        if .[1] and .[1] != "" then
            {name: .[0], data: .[1]}
        else
            {name: .[0]}
        end]
    '
}

# -----------------------------------------------------------------------------
# REST API URL Category Functions
# -----------------------------------------------------------------------------

# Check if URL category exists via REST API
url_category_exists_remote() {
    local cat_name="$1"
    
    if api_get "/mgmt/tm/sys/url-db/url-category/~Common~${cat_name}"; then
        return 0
    fi
    return 1
}

# Get list of URL categories via REST API
get_url_category_list_remote() {
    if ! api_get "/mgmt/tm/sys/url-db/url-category"; then
        return 1
    fi
    
    echo "${API_RESPONSE}" | jq -r '.items // [] | .[].name' 2>/dev/null | sort || true
}

# Get URL entries from a category via REST API
get_url_category_entries_remote() {
    local cat_name="$1"
    
    if ! api_get "/mgmt/tm/sys/url-db/url-category/~Common~${cat_name}"; then
        return 1
    fi
    
    echo "${API_RESPONSE}" | jq -r '.urls // [] | .[].name' 2>/dev/null || true
}

# Get URL count from a category via REST API
get_url_category_count_remote() {
    local cat_name="$1"
    
    if ! api_get "/mgmt/tm/sys/url-db/url-category/~Common~${cat_name}"; then
        echo "0"
        return 1
    fi
    
    echo "${API_RESPONSE}" | jq -r '.urls // [] | length' 2>/dev/null || echo "0"
}

# Create URL category via REST API
# Args: cat_name, default_action, urls_json
# urls_json format: [{"name":"https://example.com/","type":"exact-match"}]
create_url_category_remote() {
    local cat_name="$1"
    local default_action="$2"
    local urls_json="$3"
    
    local data
    data=$(jq -n \
        --arg name "${cat_name}" \
        --arg displayName "${cat_name}" \
        --arg defaultAction "${default_action}" \
        --argjson urls "${urls_json}" \
        '{name: $name, displayName: $displayName, defaultAction: $defaultAction, urls: $urls}')
    
    if api_post "/mgmt/tm/sys/url-db/url-category" "${data}"; then
        return 0
    fi
    return 1
}

# Add URLs to existing category via REST API
# Args: cat_name, urls_json
modify_url_category_add_remote() {
    local cat_name="$1"
    local urls_json="$2"
    
    # Get existing URLs first
    if ! api_get "/mgmt/tm/sys/url-db/url-category/~Common~${cat_name}"; then
        return 1
    fi
    
    local existing_urls
    existing_urls=$(echo "${API_RESPONSE}" | jq -c '.urls // []' 2>/dev/null)
    
    # Merge existing and new URLs, deduplicate by name
    local merged_urls
    merged_urls=$(jq -nc --argjson existing "${existing_urls}" --argjson new "${urls_json}" '$existing + $new | unique_by(.name)')
    
    local data
    data=$(jq -n --argjson urls "${merged_urls}" '{urls: $urls}')
    
    if api_patch "/mgmt/tm/sys/url-db/url-category/~Common~${cat_name}" "${data}"; then
        return 0
    fi
    return 1
}

# Delete URLs from existing category via REST API
# Args: cat_name, urls_to_delete (newline separated)
modify_url_category_delete_remote() {
    local cat_name="$1"
    local urls_to_delete="$2"
    
    # Get existing URLs first
    if ! api_get "/mgmt/tm/sys/url-db/url-category/~Common~${cat_name}"; then
        return 1
    fi
    
    local existing_urls
    existing_urls=$(echo "${API_RESPONSE}" | jq -c '.urls // []' 2>/dev/null)
    
    # Build array of URLs to delete
    local delete_array
    delete_array=$(echo "${urls_to_delete}" | jq -R -s 'split("\n") | map(select(length > 0))')
    
    # Filter out deleted URLs
    local remaining_urls
    remaining_urls=$(jq -nc --argjson existing "${existing_urls}" --argjson delete "${delete_array}" '
        $existing | map(select(.name as $n | $delete | index($n) | not))
    ')
    
    local data
    data=$(jq -n --argjson urls "${remaining_urls}" '{urls: $urls}')
    
    if api_patch "/mgmt/tm/sys/url-db/url-category/~Common~${cat_name}" "${data}"; then
        return 0
    fi
    return 1
}

# Replace all URLs in category (overwrite) via REST API
# Args: cat_name, urls_json
modify_url_category_replace_remote() {
    local cat_name="$1"
    local urls_json="$2"
    
    local data
    data=$(jq -n --argjson urls "${urls_json}" '{urls: $urls}')
    
    if api_patch "/mgmt/tm/sys/url-db/url-category/~Common~${cat_name}" "${data}"; then
        return 0
    fi
    return 1
}

# Build URL JSON array from domain/URL list
# Input: domain/url lines via stdin
# Output: JSON array with proper type field for REST API
build_urls_json_remote() {
    jq -Rn '
        [inputs | select(length > 0) | 
        if contains("*") then
            {name: ., type: "glob-match"}
        else
            {name: ., type: "exact-match"}
        end]
    '
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

# Check if a partition exists on the system (LOCAL - uses tmsh)
partition_exists_local() {
    local partition="$1"
    tmsh list auth partition "${partition}" &>/dev/null
    return $?
}

# Check if a partition exists (DISPATCHER)
partition_exists() {
    local partition="$1"
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        partition_exists_remote "${partition}"
    else
        partition_exists_local "${partition}"
    fi
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

# Dispatcher function - calls appropriate preflight based on session mode
preflight_checks() {
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        preflight_checks_rest_api
    else
        preflight_checks_tmsh
    fi
}

# =============================================================================
# DATAGROUP OPERATIONS
# =============================================================================

# Get list of all INTERNAL datagroups from configured partitions (LOCAL - uses tmsh)
# Returns: partition|name|internal lines
# Note: Excludes datagroups inside application services (.app folders) as those are system-managed
get_internal_datagroup_list_local() {
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

# Get list of all INTERNAL datagroups (DISPATCHER)
get_internal_datagroup_list() {
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        for partition in "${PARTITION_LIST[@]}"; do
            if partition_exists "${partition}"; then
                get_internal_datagroup_list_remote "${partition}"
            fi
        done | sort -t'|' -k1,1 -k2,2
    else
        get_internal_datagroup_list_local
    fi
}

# Get list of all EXTERNAL datagroups from configured partitions (LOCAL - uses tmsh)
# Returns: partition|name|external lines
# Note: Excludes datagroups inside application services (.app folders) as those are system-managed
get_external_datagroup_list_local() {
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

# Get list of all EXTERNAL datagroups (DISPATCHER)
# Note: External datagroups are NOT supported in REST API mode
get_external_datagroup_list() {
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        # External datagroups not supported in REST API mode - return empty
        return 0
    else
        get_external_datagroup_list_local
    fi
}

# Get combined list of all datagroups (internal and external)
# Returns: partition|name|class lines
get_all_datagroup_list() {
    {
        get_internal_datagroup_list
        get_external_datagroup_list
    } | sort -t'|' -k1,1 -k2,2
}

# Check if INTERNAL datagroup exists in specified partition (LOCAL - uses tmsh)
internal_datagroup_exists_local() {
    local partition="$1"
    local dg_name="$2"
    tmsh list ltm data-group internal "/${partition}/${dg_name}" 2>/dev/null | grep -q "data-group internal"
    return $?
}

# Check if INTERNAL datagroup exists (DISPATCHER)
internal_datagroup_exists() {
    local partition="$1"
    local dg_name="$2"
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        internal_datagroup_exists_remote "${partition}" "${dg_name}"
    else
        internal_datagroup_exists_local "${partition}" "${dg_name}"
    fi
    return $?
}

# Check if EXTERNAL datagroup exists in specified partition (LOCAL - uses tmsh)
external_datagroup_exists_local() {
    local partition="$1"
    local dg_name="$2"
    tmsh list ltm data-group external "/${partition}/${dg_name}" 2>/dev/null | grep -q "data-group external"
    return $?
}

# Check if EXTERNAL datagroup exists (DISPATCHER)
# Note: External datagroups are NOT supported in REST API mode
external_datagroup_exists() {
    local partition="$1"
    local dg_name="$2"
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        # External datagroups not supported in REST API mode
        return 1
    else
        external_datagroup_exists_local "${partition}" "${dg_name}"
    fi
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

# Get INTERNAL datagroup type (string, address, integer) (LOCAL - uses tmsh)
get_internal_datagroup_type_local() {
    local partition="$1"
    local dg_name="$2"
    tmsh list ltm data-group internal "/${partition}/${dg_name}" 2>/dev/null \
        | grep "^\s*type" \
        | awk '{print $2}' || true
}

# Get INTERNAL datagroup type (DISPATCHER)
get_internal_datagroup_type() {
    local partition="$1"
    local dg_name="$2"
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        get_internal_datagroup_type_remote "${partition}" "${dg_name}"
    else
        get_internal_datagroup_type_local "${partition}" "${dg_name}"
    fi
}

# Get EXTERNAL datagroup type (string, ip, integer) (LOCAL - uses tmsh)
get_external_datagroup_type_local() {
    local partition="$1"
    local dg_name="$2"
    tmsh list ltm data-group external "/${partition}/${dg_name}" 2>/dev/null \
        | grep "^\s*type" \
        | awk '{print $2}' || true
}

# Get EXTERNAL datagroup type (DISPATCHER)
# Note: External datagroups are NOT supported in REST API mode
get_external_datagroup_type() {
    local partition="$1"
    local dg_name="$2"
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        # External datagroups not supported in REST API mode
        echo ""
        return 1
    else
        get_external_datagroup_type_local "${partition}" "${dg_name}"
    fi
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

# Get INTERNAL datagroup records as "key|value" lines (LOCAL - uses tmsh)
get_internal_datagroup_records_local() {
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

# Get INTERNAL datagroup records (DISPATCHER)
get_internal_datagroup_records() {
    local partition="$1"
    local dg_name="$2"
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        get_internal_datagroup_records_remote "${partition}" "${dg_name}"
    else
        get_internal_datagroup_records_local "${partition}" "${dg_name}"
    fi
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
# Note: External datagroups are NOT supported in REST API mode
get_external_datagroup_records() {
    local partition="$1"
    local dg_name="$2"
    
    # External datagroups not supported in REST API mode
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        log_error "External datagroups are not supported in REST API mode."
        return 1
    fi
    
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

# Apply records to INTERNAL datagroup (atomic replace-all-with operation) (LOCAL - uses tmsh)
apply_internal_datagroup_records_local() {
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

# Apply records to INTERNAL datagroup (DISPATCHER)
# In local mode: expects tmsh-formatted records string
# In remote mode: expects JSON records array
apply_internal_datagroup_records() {
    local partition="$1"
    local dg_name="$2"
    local records="$3"
    
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        # In remote mode, records should be JSON format
        apply_internal_datagroup_records_remote "${partition}" "${dg_name}" "${records}"
    else
        apply_internal_datagroup_records_local "${partition}" "${dg_name}" "${records}"
    fi
    return $?
}

# High-level function to apply records from arrays to internal datagroup
# Handles mode-specific record building and application
# Args: partition, dg_name, dg_type, keys_array_name, values_array_name
apply_records_from_arrays() {
    local partition="$1"
    local dg_name="$2"
    local dg_type="$3"
    local keys_name=$4
    local values_name=$5
    
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        # Build JSON from arrays and apply via REST API
        eval "local keys_count=\${#${keys_name}[@]}"
        
        local records_json
        records_json=$(
            for ((i=0; i<keys_count; i++)); do
                eval "local key=\"\${${keys_name}[$i]}\""
                eval "local value=\"\${${values_name}[$i]:-}\""
                echo "${key}|${value}"
            done | build_records_json_remote "${dg_type}"
        )
        
        apply_internal_datagroup_records_remote "${partition}" "${dg_name}" "${records_json}"
    else
        # Build tmsh format and apply via tmsh
        local records
        records=$(build_tmsh_records "${keys_name}" "${values_name}" "${dg_type}")
        apply_internal_datagroup_records_local "${partition}" "${dg_name}" "${records}"
    fi
    return $?
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

# Create INTERNAL datagroup (LOCAL - uses tmsh)
create_internal_datagroup_local() {
    local partition="$1"
    local dg_name="$2"
    local dg_type="$3"
    
    local result
    result=$(tmsh create ltm data-group internal "/${partition}/${dg_name}" type "${dg_type}" 2>&1)
    local rc=$?
    if [ ${rc} -ne 0 ]; then
        echo "${result}"
    fi
    return ${rc}
}

# Create INTERNAL datagroup (DISPATCHER)
create_internal_datagroup() {
    local partition="$1"
    local dg_name="$2"
    local dg_type="$3"
    
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        create_internal_datagroup_remote "${partition}" "${dg_name}" "${dg_type}"
    else
        create_internal_datagroup_local "${partition}" "${dg_name}" "${dg_type}"
    fi
    return $?
}

# Save system configuration (LOCAL - uses tmsh)
save_config_local() {
    if tmsh save sys config 2>/dev/null; then
        return 0
    fi
    return 1
}

# Save system configuration (DISPATCHER)
save_config() {
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        save_config_remote
    else
        save_config_local
    fi
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
    echo -e "  ${CYAN}║${NC}${WHITE}                    DGCAT-Admin v2.0                        ${NC}${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}${WHITE}               F5 BIG-IP Administration Tool                ${NC}${CYAN}║${NC}"
    echo -e "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
    
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        # REST API mode menu
        echo -e "  ${CYAN}${NC}  ${WHITE}Mode: ${GREEN}REST API${NC} - ${WHITE}${REMOTE_HOST}${NC}                            ${CYAN}${NC}"
        echo -e "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
        echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}"
        echo -e "  ${CYAN}║${NC}   ${YELLOW}1)${NC}  ${WHITE}View Datagroup               ${NC}                        ${CYAN}║${NC}"
        echo -e "  ${CYAN}║${NC}   ${YELLOW}2)${NC}  ${WHITE}Create/Update Datagroup or URL Category from CSV${NC}     ${CYAN}║${NC}"
        echo -e "  ${CYAN}║${NC}   ${YELLOW}3)${NC}  ${WHITE}Export Datagroup or URL Category to CSV${NC}              ${CYAN}║${NC}"
        echo -e "  ${CYAN}║${NC}   ${YELLOW}4)${NC}  ${WHITE}Edit a Datagroup or URL Category${NC}                     ${CYAN}║${NC}"
        echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}"
        echo -e "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
        echo -e "  ${CYAN}║${NC}   ${YELLOW}0)${NC}  ${WHITE}Exit${NC}                                                 ${CYAN}║${NC}"
        echo -e "  ${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    else
        # TMSH mode menu
        echo -e "  ${CYAN}${NC}  ${WHITE}Mode: ${GREEN}TMSH${NC}                                             ${CYAN}${NC}"
        echo -e "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
        echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}"
        echo -e "  ${CYAN}║${NC}   ${YELLOW}1)${NC}  ${WHITE}List All Datagroups${NC}                                  ${CYAN}║${NC}"
        echo -e "  ${CYAN}║${NC}   ${YELLOW}2)${NC}  ${WHITE}View Datagroup Contents${NC}                              ${CYAN}║${NC}"
        echo -e "  ${CYAN}║${NC}   ${YELLOW}3)${NC}  ${WHITE}Create/Update Datagroup or URL Category from CSV${NC}     ${CYAN}║${NC}"
        echo -e "  ${CYAN}║${NC}   ${YELLOW}4)${NC}  ${WHITE}Delete Datagroup or URL Category${NC}                     ${CYAN}║${NC}"
        echo -e "  ${CYAN}║${NC}   ${YELLOW}5)${NC}  ${WHITE}Export Datagroup or URL Category to CSV${NC}              ${CYAN}║${NC}"
        echo -e "  ${CYAN}║${NC}   ${YELLOW}6)${NC}  ${WHITE}Convert URL Category to Datagroup${NC}                    ${CYAN}║${NC}"
        echo -e "  ${CYAN}║${NC}   ${YELLOW}7)${NC}  ${WHITE}Edit a Datagroup or URL Category${NC}                     ${CYAN}║${NC}"
        echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}"
        echo -e "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
        echo -e "  ${CYAN}║${NC}   ${YELLOW}0)${NC}  ${WHITE}Exit${NC}                                                 ${CYAN}║${NC}"
        echo -e "  ${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    fi
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
    selection=$(select_datagroup "${partition}" "Enter datagroup name") || true
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
    read -rp "  Enter datagroup name (or 'q' to cancel): " dg_name
    
    if [ -z "${dg_name}" ] || [ "${dg_name}" == "q" ] || [ "${dg_name}" == "Q" ]; then
        log_info "Cancelled."
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
        # External datagroups are NOT supported in REST API mode
        if [ "${SESSION_MODE}" == "rest-api" ]; then
            dg_class="internal"
            log_info "REST API mode: Using internal datagroup (external not supported)."
        else
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
        fi
        
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
        
        # Convert type names for tmsh/API (address -> ip)
        local api_type="${dg_type}"
        if [ "${dg_type}" == "address" ]; then
            api_type="ip"
        fi
        
        if [ "${SESSION_MODE}" == "rest-api" ]; then
            # REST API mode: Build JSON records
            local records_json
            records_json=$(
                for ((i=0; i<${#FINAL_KEYS[@]}; i++)); do
                    echo "${FINAL_KEYS[$i]}|${FINAL_VALUES[$i]:-}"
                done | build_records_json_remote "${dg_type}"
            )
            
            if [ -z "${restore_mode}" ]; then
                # Create new internal datagroup via REST API
                log_step "Creating internal datagroup '/${partition}/${dg_name}'..."
                if ! create_internal_datagroup_remote "${partition}" "${dg_name}" "${api_type}"; then
                    log_error "Failed to create datagroup. HTTP ${API_HTTP_CODE}"
                    [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
                    press_enter_to_continue
                    return
                fi
            fi
            
            # Apply records via REST API
            log_step "Applying ${#FINAL_KEYS[@]} entries to datagroup..."
            if ! apply_internal_datagroup_records_remote "${partition}" "${dg_name}" "${records_json}"; then
                log_error "Failed to apply records to datagroup. HTTP ${API_HTTP_CODE}"
                [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
                press_enter_to_continue
                return
            fi
        else
            # TMSH mode: Build tmsh records
            local records
            records=$(build_tmsh_records FINAL_KEYS FINAL_VALUES "${dg_type}")
            
            # Notify about space conversions
            if [ ${SPACE_CONVERSIONS} -gt 0 ]; then
                log_info "Note: ${SPACE_CONVERSIONS} value(s) contained spaces which were converted to underscores."
                log_info "This is required for tmsh compatibility. Spaces can be restored on export."
            fi
            
            if [ -z "${restore_mode}" ]; then
                # Create new internal datagroup via tmsh
                log_step "Creating internal datagroup '/${partition}/${dg_name}'..."
                local create_error
                if ! create_error=$(create_internal_datagroup_local "${partition}" "${dg_name}" "${api_type}"); then
                    log_error "Failed to create datagroup: ${create_error}"
                    [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
                    press_enter_to_continue
                    return
                fi
            fi
            
            # Apply records via tmsh
            log_step "Applying ${#FINAL_KEYS[@]} entries to datagroup..."
            if ! apply_internal_datagroup_records_local "${partition}" "${dg_name}" "${records}"; then
                log_error "Failed to apply records to datagroup."
                [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
                press_enter_to_continue
                return
            fi
        fi
        
        log_ok "Internal datagroup '/${partition}/${dg_name}' saved with ${#FINAL_KEYS[@]} entries."
    fi
    
    prompt_save_config
    
    # Cleanup temp file if created
    [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
    
    press_enter_to_continue
}

# Option 4: Delete Datagroup or URL Category
menu_delete_datagroup() {
    log_section "Delete Datagroup or URL Category"
    
    echo ""
    echo -e "  ${WHITE}What would you like to delete?${NC}"
    echo -e "    ${YELLOW}1)${NC} ${WHITE}Datagroup${NC}"
    echo -e "    ${YELLOW}2)${NC} ${WHITE}URL Category${NC}"
    echo -e "    ${YELLOW}0)${NC} ${WHITE}Cancel${NC}"
    echo ""
    read -rp "  Select [0-2]: " delete_choice
    
    case "${delete_choice}" in
        1) menu_delete_datagroup_only ;;
        2) menu_delete_url_category ;;
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

# Option 4a: Delete datagroup
menu_delete_datagroup_only() {
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
    read -rp "  Enter datagroup name to delete (or 'q' to cancel): " dg_name
    
    if [ -z "${dg_name}" ] || [ "${dg_name}" == "q" ] || [ "${dg_name}" == "Q" ]; then
        log_info "Cancelled."
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

# Option 4b: Delete URL Category
menu_delete_url_category() {
    log_section "Delete URL Category"
    
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
                printf "    ${YELLOW}%3d)${NC} ${WHITE}%s${NC}\n" "${i}" "${cat}"
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
    
    # Get category details
    local url_count
    url_count=$(get_url_category_count "${selected_category}")
    
    echo ""
    log_warn "You are about to delete the following URL category:"
    log_info "  Category: ${selected_category}"
    log_info "  URLs:     ${url_count}"
    echo ""
    
    # Backup before delete
    log_step "Creating backup before deletion..."
    local safe_name
    safe_name=$(echo "${selected_category}" | sed 's/[^a-zA-Z0-9_-]/_/g')
    local backup_file="${BACKUP_DIR}/urlcat_${safe_name}_${TIMESTAMP}.csv"
    
    {
        echo "# URL Category Backup: ${selected_category}"
        echo "# Created: $(date)"
        echo "# Reason: Pre-deletion backup"
        echo "#"
        get_url_category_entries "${selected_category}"
    } > "${backup_file}" 2>/dev/null
    
    if [ -f "${backup_file}" ]; then
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
    
    # Delete the URL category
    log_step "Deleting URL category '${selected_category}'..."
    if tmsh delete sys url-db url-category "${selected_category}" 2>/dev/null; then
        log_ok "URL category '${selected_category}' deleted successfully."
    else
        log_error "Failed to delete URL category."
        press_enter_to_continue
        return
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
    selection=$(select_datagroup "${partition}" "Enter datagroup name to export") || true
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
    if ! url_category_db_available; then
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
# URL CATEGORY FUNCTIONS
# =============================================================================

# Check if URL database is available (LOCAL - uses tmsh)
url_category_db_available_local() {
    tmsh list sys url-db url-category one-line &>/dev/null
    return $?
}

# Check if URL database is available (DISPATCHER)
# Returns: 0 if URL categories are accessible, 1 if not
url_category_db_available() {
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        # In remote mode, try to list categories via REST API
        if api_get "/mgmt/tm/sys/url-db/url-category"; then
            return 0
        fi
        return 1
    else
        url_category_db_available_local
    fi
    return $?
}

# Check if URL category exists (LOCAL - uses tmsh)
# Returns: 0 if exists, 1 if not
url_category_exists_local() {
    local cat_name="$1"
    tmsh list sys url-db url-category "${cat_name}" &>/dev/null
    return $?
}

# Check if URL category exists (DISPATCHER)
url_category_exists() {
    local cat_name="$1"
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        url_category_exists_remote "${cat_name}"
    else
        url_category_exists_local "${cat_name}"
    fi
    return $?
}

# Get list of custom URL categories (LOCAL - uses tmsh)
# Returns: category names, one per line
get_url_category_list_local() {
    tmsh list sys url-db url-category one-line 2>/dev/null \
        | grep "^sys url-db url-category" \
        | awk '{print $4}' \
        | sort || true
}

# Get list of custom URL categories (DISPATCHER)
get_url_category_list() {
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        get_url_category_list_remote
    else
        get_url_category_list_local
    fi
}

# Get URL entries from a URL category (LOCAL - uses tmsh)
# Returns: raw URL entries, one per line
get_url_category_entries_local() {
    local category="$1"
    tmsh list sys url-db url-category "${category}" urls 2>/dev/null \
        | grep -E '^\s*http' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*{.*$//' || true
}

# Get URL entries from a URL category (DISPATCHER)
get_url_category_entries() {
    local category="$1"
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        get_url_category_entries_remote "${category}"
    else
        get_url_category_entries_local "${category}"
    fi
}

# Get URL count from a URL category (LOCAL - uses tmsh)
get_url_category_count_local() {
    local cat_name="$1"
    tmsh list sys url-db url-category "${cat_name}" urls 2>/dev/null \
        | grep -cE '^\s*http' || echo "0"
}

# Get URL count from a URL category (DISPATCHER)
get_url_category_count() {
    local cat_name="$1"
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        get_url_category_count_remote "${cat_name}"
    else
        get_url_category_count_local "${cat_name}"
    fi
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

# Option 6: Convert URL Category to Datagroup
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
    read -rp "  Enter datagroup name [${default_name}] (or 'q' to cancel): " dg_name
    
    if [ "${dg_name}" == "q" ] || [ "${dg_name}" == "Q" ]; then
        log_info "Cancelled."
        press_enter_to_continue
        return
    fi
    
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
    # Note: This function is disabled in REST API mode, but check anyway for safety
    local dg_class
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        dg_class="internal"
        log_info "REST API mode: Using internal datagroup (external not supported)."
    else
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

# Option 3b: Create URL Category from CSV
menu_create_url_category() {
    log_section "Create URL Category from CSV"
    
    # Check if URL database is available
    if ! url_category_db_available; then
        log_error "URL database not available or accessible."
        log_info "This feature requires the URL filtering module."
        press_enter_to_continue
        return
    fi
    
    # Get category name
    echo ""
    read -rp "  Enter URL category name (or 'q' to cancel): " cat_name
    
    if [ -z "${cat_name}" ] || [ "${cat_name}" == "q" ] || [ "${cat_name}" == "Q" ]; then
        log_info "Cancelled."
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
        
        # Use associative array to track existing URLs
        declare -A existing_set
        
        # Add existing URLs to set
        while IFS= read -r url; do
            [ -z "${url}" ] && continue
            existing_set["${url}"]=1
        done <<< "${existing_urls}"
        
        local existing_count=${#existing_set[@]}
        
        # Filter converted_urls to only include truly new ones
        local -a new_urls=()
        for url in "${converted_urls[@]}"; do
            if [ -z "${existing_set["${url}"]:-}" ]; then
                new_urls+=("${url}")
            fi
        done
        
        local new_added=${#new_urls[@]}
        local final_count=$((existing_count + new_added))
        
        log_info "Existing: ${existing_count}, New unique: ${new_added}, Final: ${final_count}"
        
        # Replace converted_urls with only the new ones
        if [ ${#new_urls[@]} -gt 0 ]; then
            converted_urls=("${new_urls[@]}")
        else
            converted_urls=()
            log_info "No new URLs to add - all entries already exist in category."
            press_enter_to_continue
            return
        fi
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
    if [ "${SESSION_MODE}" == "rest-api" ]; then
        # REST API mode: use REST API
        
        # Build JSON URLs array
        local urls_json
        urls_json=$(printf '%s\n' "${converted_urls[@]}" | build_urls_json_remote)
        
        if [ "${restore_mode}" == "overwrite" ]; then
            # Overwrite: Replace all URLs
            log_step "Replacing URLs in category '${cat_name}'..."
            if ! modify_url_category_replace_remote "${cat_name}" "${urls_json}"; then
                log_error "Failed to update URL category. HTTP ${API_HTTP_CODE}"
                [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
                press_enter_to_continue
                return
            fi
        elif [ -z "${restore_mode}" ]; then
            # Create new category
            log_step "Creating URL category '${cat_name}'..."
            if ! create_url_category_remote "${cat_name}" "${default_action}" "${urls_json}"; then
                log_error "Failed to create URL category. HTTP ${API_HTTP_CODE}"
                [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
                press_enter_to_continue
                return
            fi
        else
            # Merge mode - add to existing
            log_step "Adding URLs to existing category '${cat_name}'..."
            if ! modify_url_category_add_remote "${cat_name}" "${urls_json}"; then
                log_error "Failed to update URL category. HTTP ${API_HTTP_CODE}"
                [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
                press_enter_to_continue
                return
            fi
        fi
    else
        # TMSH mode: use tmsh
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
    fi
    
    log_ok "URL category '${cat_name}' created successfully with ${#converted_urls[@]} URLs."
    
    prompt_save_config
    
    # Cleanup
    [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
    
    press_enter_to_continue
}

# =============================================================================
# EDIT DATAGROUP/URL CATEGORY FUNCTIONS
# =============================================================================

# Default page size for browsing
EDIT_PAGE_SIZE=20

# Display paginated entries with optional filtering
# Args: entries (newline-separated), page_num, page_size, filter_pattern, sort_order
# Returns via echo: displayed entries count
display_entries_page() {
    local entries="$1"
    local page_num="${2:-1}"
    local page_size="${3:-${EDIT_PAGE_SIZE}}"
    local filter="${4:-}"
    local sort_order="${5:-original}"
    
    # Apply filter if provided
    local filtered_entries="${entries}"
    if [ -n "${filter}" ]; then
        filtered_entries=$(echo "${entries}" | grep -i "${filter}" 2>/dev/null || true)
    fi
    
    # Apply sort
    local sorted_entries="${filtered_entries}"
    case "${sort_order}" in
        "asc")  sorted_entries=$(echo "${filtered_entries}" | sort -f) ;;
        "desc") sorted_entries=$(echo "${filtered_entries}" | sort -rf) ;;
        *)      sorted_entries="${filtered_entries}" ;;
    esac
    
    # Count total entries
    local total_count=0
    if [ -n "${sorted_entries}" ]; then
        total_count=$(echo "${sorted_entries}" | wc -l)
    fi
    
    if [ ${total_count} -eq 0 ]; then
        echo "" >&2
        echo -e "  ${WHITE}(No matching entries)${NC}" >&2
        echo "0|0|0"
        return
    fi
    
    # Calculate pagination
    local total_pages=$(( (total_count + page_size - 1) / page_size ))
    if [ ${page_num} -gt ${total_pages} ]; then
        page_num=${total_pages}
    fi
    if [ ${page_num} -lt 1 ]; then
        page_num=1
    fi
    
    local start_line=$(( (page_num - 1) * page_size + 1 ))
    local end_line=$(( start_line + page_size - 1 ))
    
    # Display header (to stderr so it shows on screen)
    echo "" >&2
    echo -e "  ${CYAN}──────────────────────────────────────────────────────────────────────────${NC}" >&2
    printf "  ${WHITE}%-6s  %-66s${NC}\n" "NUM" "ENTRY" >&2
    echo -e "  ${CYAN}──────────────────────────────────────────────────────────────────────────${NC}" >&2
    
    # Display entries for current page
    local line_num=0
    local display_num=${start_line}
    while IFS= read -r entry; do
        [ -z "${entry}" ] && continue
        line_num=$((line_num + 1))
        
        if [ ${line_num} -ge ${start_line} ] && [ ${line_num} -le ${end_line} ]; then
            # Truncate long entries for display
            local display_entry="${entry}"
            if [ ${#entry} -gt 66 ]; then
                display_entry="${entry:0:63}..."
            fi
            printf "  ${WHITE}%-6d  %-66s${NC}\n" "${line_num}" "${display_entry}" >&2
        fi
        
        if [ ${line_num} -gt ${end_line} ]; then
            break
        fi
    done <<< "${sorted_entries}"
    
    echo -e "  ${CYAN}──────────────────────────────────────────────────────────────────────────${NC}" >&2
    
    # Display pagination info (to stderr)
    local showing_end=${end_line}
    if [ ${showing_end} -gt ${total_count} ]; then
        showing_end=${total_count}
    fi
    
    echo -e "  ${WHITE}Showing ${start_line}-${showing_end} of ${total_count} entries (Page ${page_num}/${total_pages})${NC}" >&2
    
    if [ -n "${filter}" ]; then
        echo -e "  ${YELLOW}Filter: '${filter}'${NC}" >&2
    fi
    
    # Return pagination state (to stdout for capture)
    echo "${total_count}|${page_num}|${total_pages}"
}

# =============================================================================
# UNIFIED EDITOR
# =============================================================================

# Unified editor for datagroups and URL categories
# All edits are staged in memory and applied atomically on user request
# Args for datagroup:  "datagroup" partition dg_name dg_class
# Args for URL cat:    "urlcat" cat_name
editor_submenu() {
    local edit_type="$1"
    
    # Type-specific variables
    local partition="" dg_name="" dg_class="" dg_type="" cat_name=""
    local display_title="" display_info1="" display_info2=""
    local entry_label="Entries"
    
    if [ "${edit_type}" == "datagroup" ]; then
        partition="$2"
        dg_name="$3"
        dg_class="$4"
        dg_type=$(get_datagroup_type "${partition}" "${dg_name}" "${dg_class}")
        display_title="DGCat-Admin Editor"
        display_info1="Path:  /${partition}/${dg_name}"
        display_info2="Class: ${dg_class}  |  Type: ${dg_type}"
    else
        cat_name="$2"
        display_title="DGCat-Admin Editor"
        display_info1="URL Category: ${cat_name}"
        display_info2=""
        entry_label="URLs"
    fi
    
    # Working arrays - all edits happen here until applied
    local -a working_keys=()
    local -a working_values=()
    
    # Original state - for change detection
    local -a original_keys=()
    local -a original_values=()
    
    # Load current state into working arrays (one-time fetch)
    log_step "Loading current entries..."
    if [ "${edit_type}" == "datagroup" ]; then
        while IFS='|' read -r key value; do
            [ -z "${key}" ] && continue
            working_keys+=("${key}")
            working_values+=("${value}")
            original_keys+=("${key}")
            original_values+=("${value}")
        done < <(get_datagroup_records "${partition}" "${dg_name}" "${dg_class}")
    else
        while IFS= read -r url; do
            [ -z "${url}" ] && continue
            working_keys+=("${url}")
            working_values+=("")
            original_keys+=("${url}")
            original_values+=("")
        done < <(get_url_category_entries "${cat_name}")
    fi
    log_ok "Loaded ${#working_keys[@]} entries"
    sleep 1
    
    # Session state
    local current_page=1
    local current_filter=""
    local current_sort="original"
    
    # Function to check if there are pending changes
    has_pending_changes() {
        # Quick length check first
        if [ ${#working_keys[@]} -ne ${#original_keys[@]} ]; then
            return 0
        fi
        # Compare contents
        local i
        for ((i=0; i<${#working_keys[@]}; i++)); do
            if [ "${working_keys[$i]}" != "${original_keys[$i]}" ] || \
               [ "${working_values[$i]}" != "${original_values[$i]}" ]; then
                return 0
            fi
        done
        return 1
    }
    
    # Function to build entries string from working arrays for display
    build_entries_display() {
        local result=""
        local i
        for ((i=0; i<${#working_keys[@]}; i++)); do
            if [ "${edit_type}" == "datagroup" ] && [ -n "${working_values[$i]}" ]; then
                result="${result}${working_keys[$i]}|${working_values[$i]}"$'\n'
            else
                result="${result}${working_keys[$i]}"$'\n'
            fi
        done
        echo "${result}" | sed '/^$/d'
    }
    
    while true; do
        clear
        echo ""
        echo -e "  ${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${CYAN}║${NC}${WHITE}                        ${display_title}                                ${NC}${CYAN}║${NC}"
        echo -e "  ${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
        echo -e "  ${WHITE}${display_info1}${NC}"
        if [ -n "${display_info2}" ]; then
            echo -e "  ${WHITE}${display_info2}${NC}"
        fi
        
        # Build entries from working arrays
        local entries=""
        entries=$(build_entries_display)
        local entry_count=${#working_keys[@]}
        
        echo -e "  ${WHITE}${entry_label}: ${entry_count}${NC}"
        if has_pending_changes; then
            echo -e "  ${YELLOW}(Pending changes - not yet applied)${NC}"
        fi
        
        # Display current page
        local page_info
        page_info=$(display_entries_page "${entries}" "${current_page}" "${EDIT_PAGE_SIZE}" "${current_filter}" "${current_sort}")
        local total_count page_num total_pages
        IFS='|' read -r total_count page_num total_pages <<< "${page_info}"
        current_page=${page_num}
        
        # Show sort indicator
        local sort_indicator="Original"
        case "${current_sort}" in
            "asc")  sort_indicator="A-Z" ;;
            "desc") sort_indicator="Z-A" ;;
        esac
        echo -e "  ${WHITE}Sort: ${sort_indicator}${NC}"
        
        # Menu options
        echo ""
        echo -e "  ${YELLOW}n)${NC} Next page    ${YELLOW}p)${NC} Previous page    ${YELLOW}g)${NC} Go to page"
        echo -e "  ${YELLOW}f)${NC} Filter       ${YELLOW}c)${NC} Clear filter     ${YELLOW}s)${NC} Change sort"
        echo -e "  ${YELLOW}a)${NC} Add entry    ${YELLOW}d)${NC} Delete entry     ${YELLOW}x)${NC} Delete by pattern"
        echo -e "  ${YELLOW}w)${NC} Apply changes (write to system)"
        echo -e "  ${YELLOW}q)${NC} Done (return to main menu)"
        echo ""
        read -rp "  Select option: " edit_choice
        
        case "${edit_choice}" in
            n|N)
                if [ ${current_page} -lt ${total_pages} ]; then
                    current_page=$((current_page + 1))
                fi
                ;;
            p|P)
                if [ ${current_page} -gt 1 ]; then
                    current_page=$((current_page - 1))
                fi
                ;;
            g|G)
                echo ""
                read -rp "  Enter page number (1-${total_pages}): " goto_page
                if [[ "${goto_page}" =~ ^[0-9]+$ ]] && [ "${goto_page}" -ge 1 ] && [ "${goto_page}" -le "${total_pages}" ]; then
                    current_page=${goto_page}
                else
                    log_warn "Invalid page number."
                    press_enter_to_continue
                fi
                ;;
            f|F)
                echo ""
                read -rp "  Enter search pattern (case-insensitive): " current_filter
                current_page=1
                ;;
            c|C)
                current_filter=""
                current_page=1
                ;;
            s|S)
                echo ""
                echo -e "  ${WHITE}Sort order:${NC}"
                echo -e "    ${YELLOW}1)${NC} Original (as stored)"
                echo -e "    ${YELLOW}2)${NC} A-Z (ascending)"
                echo -e "    ${YELLOW}3)${NC} Z-A (descending)"
                echo ""
                read -rp "  Select [1-3]: " sort_choice
                case "${sort_choice}" in
                    1) current_sort="original" ;;
                    2) current_sort="asc" ;;
                    3) current_sort="desc" ;;
                esac
                ;;
            a|A)
                # Add entry - modifies working arrays only
                if [ "${edit_type}" == "datagroup" ]; then
                    echo ""
                    read -rp "  Enter new entry: " new_key
                    if [ -z "${new_key}" ]; then
                        log_warn "No entry provided."
                        press_enter_to_continue
                        continue
                    fi
                    
                    # Check for duplicate
                    local is_dup=false
                    for existing_key in "${working_keys[@]}"; do
                        if [ "${existing_key}" == "${new_key}" ]; then
                            is_dup=true
                            break
                        fi
                    done
                    
                    if [ "${is_dup}" == "true" ]; then
                        log_warn "Entry '${new_key}' already exists."
                        press_enter_to_continue
                        continue
                    fi
                    
                    local new_value=""
                    read -rp "  Enter value (optional, press Enter to skip): " new_value
                    
                    # Add to working arrays
                    working_keys+=("${new_key}")
                    working_values+=("${new_value}")
                    log_ok "Entry staged for addition: ${new_key}"
                else
                    # URL category add
                    echo ""
                    read -rp "  Enter domain or URL to add: " new_url
                    
                    if [ -z "${new_url}" ]; then
                        log_warn "No URL provided."
                        press_enter_to_continue
                        continue
                    fi
                    
                    local formatted_url
                    formatted_url=$(format_domain_for_url_category "${new_url}")
                    
                    # Check for duplicate
                    local is_dup=false
                    for existing_url in "${working_keys[@]}"; do
                        if [ "${existing_url}" == "${formatted_url}" ]; then
                            is_dup=true
                            break
                        fi
                    done
                    
                    if [ "${is_dup}" == "true" ]; then
                        log_warn "URL '${formatted_url}' already exists."
                        press_enter_to_continue
                        continue
                    fi
                    
                    log_info "Will add: ${formatted_url}"
                    read -rp "  Confirm? (yes/no) [yes]: " confirm_add
                    confirm_add="${confirm_add:-yes}"
                    
                    if [ "${confirm_add}" != "yes" ]; then
                        log_info "Cancelled."
                        press_enter_to_continue
                        continue
                    fi
                    
                    # Add to working arrays
                    working_keys+=("${formatted_url}")
                    working_values+=("")
                    log_ok "URL staged for addition: ${formatted_url}"
                fi
                press_enter_to_continue
                ;;
            d|D)
                # Delete entry - modifies working arrays only
                echo ""
                read -rp "  Enter entry number or key to delete: " del_input
                
                if [ -z "${del_input}" ]; then
                    log_warn "No entry specified."
                    press_enter_to_continue
                    continue
                fi
                
                # Apply same filter/sort as display to get the view the user sees
                local view_entries="${entries}"
                if [ -n "${current_filter}" ]; then
                    view_entries=$(echo "${entries}" | grep -i "${current_filter}" 2>/dev/null || true)
                fi
                case "${current_sort}" in
                    "asc")  view_entries=$(echo "${view_entries}" | sort -f) ;;
                    "desc") view_entries=$(echo "${view_entries}" | sort -rf) ;;
                esac
                
                local del_key=""
                if [[ "${del_input}" =~ ^[0-9]+$ ]]; then
                    # Lookup by line number from filtered/sorted view
                    del_key=$(echo "${view_entries}" | sed -n "${del_input}p")
                    # For datagroups with key|value format, extract just the key
                    if [ "${edit_type}" == "datagroup" ] && [[ "${del_key}" == *"|"* ]]; then
                        del_key=$(echo "${del_key}" | cut -d'|' -f1)
                    fi
                    
                    if [ -z "${del_key}" ]; then
                        log_error "Entry number ${del_input} not found."
                        press_enter_to_continue
                        continue
                    fi
                else
                    # Direct key/URL input
                    del_key="${del_input}"
                fi
                
                # Find and remove from working arrays
                local found_idx=-1
                local i
                for ((i=0; i<${#working_keys[@]}; i++)); do
                    if [ "${working_keys[$i]}" == "${del_key}" ]; then
                        found_idx=$i
                        break
                    fi
                done
                
                if [ ${found_idx} -eq -1 ]; then
                    log_error "Entry not found: ${del_key}"
                    press_enter_to_continue
                    continue
                fi
                
                echo ""
                log_warn "Delete entry: ${del_key}"
                read -rp "  Confirm? (yes/no) [no]: " confirm_del
                
                if [ "${confirm_del}" != "yes" ]; then
                    log_info "Cancelled."
                    press_enter_to_continue
                    continue
                fi
                
                # Remove from working arrays by rebuilding without the deleted entry
                local -a new_keys=()
                local -a new_values=()
                for ((i=0; i<${#working_keys[@]}; i++)); do
                    if [ $i -ne ${found_idx} ]; then
                        new_keys+=("${working_keys[$i]}")
                        new_values+=("${working_values[$i]}")
                    fi
                done
                working_keys=("${new_keys[@]}")
                working_values=("${new_values[@]}")
                
                log_ok "Entry staged for deletion: ${del_key}"
                press_enter_to_continue
                ;;
            x|X)
                # Delete by pattern - modifies working arrays only
                echo ""
                read -rp "  Enter pattern to match entries for deletion: " del_pattern
                
                if [ -z "${del_pattern}" ]; then
                    log_warn "No pattern provided."
                    press_enter_to_continue
                    continue
                fi
                
                # Find matching entries in working arrays
                local -a matching_indices=()
                local matching_display=""
                local i
                for ((i=0; i<${#working_keys[@]}; i++)); do
                    if echo "${working_keys[$i]}" | grep -qi "${del_pattern}"; then
                        matching_indices+=($i)
                        matching_display="${matching_display}${working_keys[$i]}"$'\n'
                    fi
                done
                
                local match_count=${#matching_indices[@]}
                
                if [ ${match_count} -eq 0 ]; then
                    log_info "No entries match pattern '${del_pattern}'."
                    press_enter_to_continue
                    continue
                fi
                
                echo ""
                log_warn "Found ${match_count} entries matching '${del_pattern}':"
                echo -e "  ${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"
                echo "${matching_display}" | head -20 | while read -r entry; do
                    [ -z "${entry}" ] && continue
                    echo -e "    ${WHITE}${entry}${NC}"
                done
                if [ ${match_count} -gt 20 ]; then
                    echo -e "    ${YELLOW}... and $((match_count - 20)) more${NC}"
                fi
                echo -e "  ${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"
                
                echo ""
                read -rp "  Delete all ${match_count} matching entries? (yes/no) [no]: " confirm_del
                
                if [ "${confirm_del}" != "yes" ]; then
                    log_info "Cancelled."
                    press_enter_to_continue
                    continue
                fi
                
                # Remove matching entries by rebuilding arrays
                local -a new_keys=()
                local -a new_values=()
                for ((i=0; i<${#working_keys[@]}; i++)); do
                    local should_keep=true
                    for del_idx in "${matching_indices[@]}"; do
                        if [ $i -eq $del_idx ]; then
                            should_keep=false
                            break
                        fi
                    done
                    if [ "${should_keep}" == "true" ]; then
                        new_keys+=("${working_keys[$i]}")
                        new_values+=("${working_values[$i]}")
                    fi
                done
                working_keys=("${new_keys[@]}")
                working_values=("${new_values[@]}")
                
                log_ok "${match_count} entries staged for deletion."
                press_enter_to_continue
                ;;
            w|W)
                # Apply changes - create backup and write to system
                if ! has_pending_changes; then
                    log_info "No changes to apply."
                    press_enter_to_continue
                    continue
                fi
                
                # Build lists of additions and deletions
                local -a additions=()
                local -a deletions=()
                
                # Deleted = in original but not in working
                for orig_key in "${original_keys[@]}"; do
                    local found=false
                    for work_key in "${working_keys[@]}"; do
                        if [ "${orig_key}" == "${work_key}" ]; then
                            found=true
                            break
                        fi
                    done
                    if [ "${found}" == "false" ]; then
                        deletions+=("${orig_key}")
                    fi
                done
                
                # Added = in working but not in original
                for work_key in "${working_keys[@]}"; do
                    local found=false
                    for orig_key in "${original_keys[@]}"; do
                        if [ "${work_key}" == "${orig_key}" ]; then
                            found=true
                            break
                        fi
                    done
                    if [ "${found}" == "false" ]; then
                        additions+=("${work_key}")
                    fi
                done
                
                # Display pending changes
                echo ""
                log_info "Pending changes:"
                echo -e "  ${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"
                
                if [ ${#additions[@]} -gt 0 ]; then
                    echo -e "  ${GREEN}Additions (${#additions[@]}):${NC}"
                    for entry in "${additions[@]}"; do
                        echo -e "    ${GREEN}+ ${entry}${NC}"
                    done
                fi
                
                if [ ${#deletions[@]} -gt 0 ]; then
                    if [ ${#additions[@]} -gt 0 ]; then
                        echo ""
                    fi
                    echo -e "  ${RED}Deletions (${#deletions[@]}):${NC}"
                    for entry in "${deletions[@]}"; do
                        echo -e "    ${RED}- ${entry}${NC}"
                    done
                fi
                
                echo -e "  ${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"
                echo -e "  ${WHITE}Final count: ${#working_keys[@]} entries${NC}"
                echo ""
                read -rp "  Apply these changes? (yes/no) [no]: " confirm_apply
                
                if [ "${confirm_apply}" != "yes" ]; then
                    log_info "Cancelled."
                    press_enter_to_continue
                    continue
                fi
                
                # Create backup before applying
                log_step "Creating backup before applying changes..."
                local backup_file=""
                if [ "${edit_type}" == "datagroup" ]; then
                    backup_file=$(backup_datagroup "${partition}" "${dg_name}" "${dg_class}")
                else
                    # For URL categories, create a simple backup
                    local safe_name
                    safe_name=$(echo "${cat_name}" | sed 's/[^a-zA-Z0-9_-]/_/g')
                    backup_file="${BACKUP_DIR}/urlcat_${safe_name}_${TIMESTAMP}.csv"
                    {
                        echo "# URL Category Backup: ${cat_name}"
                        echo "# Created: $(date)"
                        echo "#"
                        for orig_url in "${original_keys[@]}"; do
                            echo "${orig_url}"
                        done
                    } > "${backup_file}" 2>/dev/null
                fi
                
                if [ -n "${backup_file}" ] && [ -f "${backup_file}" ]; then
                    log_ok "Backup saved: ${backup_file}"
                else
                    log_warn "Could not create backup."
                    read -rp "  Continue without backup? (yes/no) [no]: " cont
                    if [ "${cont}" != "yes" ]; then
                        continue
                    fi
                fi
                
                # Apply changes atomically
                if [ "${edit_type}" == "datagroup" ]; then
                    if [ "${dg_class}" == "external" ]; then
                        # External datagroups only supported in local mode
                        if [ "${SESSION_MODE}" == "rest-api" ]; then
                            log_error "External datagroups cannot be edited in REST API mode."
                            press_enter_to_continue
                            continue
                        fi
                        log_step "Applying changes to external datagroup..."
                        if update_external_datagroup "${partition}" "${dg_name}" "${dg_type}" working_keys working_values; then
                            log_ok "Changes applied successfully."
                        else
                            log_error "Failed to apply changes."
                            press_enter_to_continue
                            continue
                        fi
                    else
                        log_step "Applying changes to internal datagroup..."
                        
                        if [ "${SESSION_MODE}" == "rest-api" ]; then
                            # REST API mode: Build JSON and apply via REST API
                            local records_json
                            records_json=$(
                                for ((i=0; i<${#working_keys[@]}; i++)); do
                                    echo "${working_keys[$i]}|${working_values[$i]:-}"
                                done | build_records_json_remote "${dg_type}"
                            )
                            
                            if apply_internal_datagroup_records_remote "${partition}" "${dg_name}" "${records_json}"; then
                                log_ok "Changes applied successfully."
                            else
                                log_error "Failed to apply changes. HTTP ${API_HTTP_CODE}"
                                press_enter_to_continue
                                continue
                            fi
                        else
                            # TMSH mode: Build tmsh records and apply
                            local records
                            records=$(build_tmsh_records working_keys working_values "${dg_type}")
                            
                            if apply_internal_datagroup_records_local "${partition}" "${dg_name}" "${records}"; then
                                log_ok "Changes applied successfully."
                            else
                                log_error "Failed to apply changes."
                                press_enter_to_continue
                                continue
                            fi
                        fi
                    fi
                else
                    # URL category - apply only the changes (not full replace)
                    log_step "Applying changes to URL category..."
                    
                    local apply_errors=0
                    
                    if [ "${SESSION_MODE}" == "rest-api" ]; then
                        # REST API mode: use REST API
                        
                        # Handle deletions
                        if [ ${#deletions[@]} -gt 0 ]; then
                            local del_list
                            del_list=$(printf '%s\n' "${deletions[@]}")
                            if ! modify_url_category_delete_remote "${cat_name}" "${del_list}"; then
                                apply_errors=$((apply_errors + 1))
                            fi
                        fi
                        
                        # Handle additions
                        if [ ${#additions[@]} -gt 0 ]; then
                            local add_json
                            add_json=$(printf '%s\n' "${additions[@]}" | build_urls_json_remote)
                            if ! modify_url_category_add_remote "${cat_name}" "${add_json}"; then
                                apply_errors=$((apply_errors + 1))
                            fi
                        fi
                    else
                        # TMSH mode: use tmsh
                        
                        # Delete only the entries being removed
                        if [ ${#deletions[@]} -gt 0 ]; then
                            for del_url in "${deletions[@]}"; do
                                if ! tmsh modify sys url-db url-category "${cat_name}" urls delete \{ "${del_url}" \} 2>/dev/null; then
                                    apply_errors=$((apply_errors + 1))
                                fi
                            done
                        fi
                        
                        # Add only the new entries
                        if [ ${#additions[@]} -gt 0 ]; then
                            local urls_block=""
                            for add_url in "${additions[@]}"; do
                                urls_block="${urls_block} ${add_url} { }"
                            done
                            if ! tmsh modify sys url-db url-category "${cat_name}" urls add \{ ${urls_block} \} 2>/dev/null; then
                                apply_errors=$((apply_errors + 1))
                            fi
                        fi
                    fi
                    
                    if [ ${apply_errors} -eq 0 ]; then
                        log_ok "Changes applied successfully."
                    else
                        log_warn "Changes applied with ${apply_errors} error(s)."
                    fi
                fi
                
                # Update original arrays to match working (reset change tracking)
                original_keys=("${working_keys[@]}")
                original_values=("${working_values[@]}")
                
                prompt_save_config
                press_enter_to_continue
                ;;
            q|Q)
                # Check for pending changes before exit
                if has_pending_changes; then
                    echo ""
                    log_warn "You have unapplied changes that will be discarded."
                    read -rp "  Discard changes and exit? (yes/no) [no]: " confirm_exit
                    if [ "${confirm_exit}" != "yes" ]; then
                        continue
                    fi
                    log_info "Changes discarded."
                fi
                return
                ;;
            *)
                ;;
        esac
    done
}
# Option 7: Edit a Datagroup or URL Category
menu_edit_datagroup_or_category() {
    log_section "Edit a Datagroup or URL Category"
    
    echo ""
    echo -e "  ${WHITE}What would you like to edit?${NC}"
    echo -e "    ${YELLOW}1)${NC} ${WHITE}Datagroup${NC}"
    echo -e "    ${YELLOW}2)${NC} ${WHITE}URL Category${NC}"
    echo -e "    ${YELLOW}0)${NC} ${WHITE}Cancel${NC}"
    echo ""
    read -rp "  Select [0-2]: " edit_choice
    
    case "${edit_choice}" in
        1)
            # Edit datagroup
            local partition
            partition=$(select_partition "Select partition")
            if [ -z "${partition}" ]; then
                log_info "Cancelled."
                press_enter_to_continue
                return
            fi
            
            local selection dg_name dg_class
            selection=$(select_datagroup "${partition}" "Enter datagroup name to edit") || true
            if [ -z "${selection}" ]; then
                press_enter_to_continue
                return
            fi
            IFS='|' read -r dg_name dg_class <<< "${selection}"
            
            # Check if protected
            if is_protected_datagroup "${dg_name}"; then
                log_error "The datagroup '${dg_name}' is a protected BIG-IP system datagroup."
                log_error "Editing this datagroup could cause adverse system behavior."
                press_enter_to_continue
                return
            fi
            
            editor_submenu "datagroup" "${partition}" "${dg_name}" "${dg_class}"
            ;;
        2)
            # Edit URL category
            if ! url_category_db_available; then
                log_error "URL database not available or accessible."
                press_enter_to_continue
                return
            fi
            
            # Category selection
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
                        
                        if url_category_exists "${selected_category}"; then
                            break
                        fi
                        
                        local sslo_name="sslo-urlCat${selected_category}"
                        if url_category_exists "${sslo_name}"; then
                            log_info "Found as SSLO category: ${sslo_name}"
                            selected_category="${sslo_name}"
                            break
                        fi
                        
                        log_error "Category '${selected_category}' not found."
                    done
                    ;;
                2)
                    log_step "Retrieving URL categories..."
                    local categories
                    categories=$(get_url_category_list)
                    
                    if [ -z "${categories}" ]; then
                        log_error "No URL categories found."
                        press_enter_to_continue
                        return
                    fi
                    
                    echo ""
                    echo -e "  ${WHITE}Available URL Categories:${NC}"
                    echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
                    local i=1
                    local cat_array=()
                    while IFS= read -r cat; do
                        printf "    ${YELLOW}%3d)${NC} ${WHITE}%s${NC}\n" "${i}" "${cat}"
                        cat_array+=("${cat}")
                        i=$((i + 1))
                    done <<< "${categories}"
                    echo -e "  ${CYAN}─────────────────────────────────────────────────────────────${NC}"
                    echo -e "      ${YELLOW}0)${NC} ${WHITE}Cancel${NC}"
                    echo ""
                    
                    read -rp "  Select [0-$((${#cat_array[@]}))] : " cat_choice
                    
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
            
            editor_submenu "urlcat" "${selected_category}"
            ;;
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

main() {
    # Select operation mode first (before anything else)
    select_session_mode
    
    # Clear screen after mode selection
    clear
    
    # Try to create backup/log directory
    mkdir -p "${BACKUP_DIR}" 2>/dev/null
    
    # Initialize log (if directory is writable)
    if touch "${LOGFILE}" 2>/dev/null; then
        echo "DGCat-Admin v1.0 - F5 BIG-IP Administration Tool" > "${LOGFILE}"
        echo "Started: $(date)" >> "${LOGFILE}"
        echo "Mode: ${SESSION_MODE}" >> "${LOGFILE}"
        if [ "${SESSION_MODE}" == "rest-api" ]; then
            echo "Target: (pending connection)" >> "${LOGFILE}"
        fi
    fi
    
    # Run pre-flight checks (mode-specific)
    preflight_checks
    
    # Update log with target host if applicable
    if [ "${SESSION_MODE}" == "rest-api" ] && [ -n "${REMOTE_HOST}" ]; then
        echo "Target: ${REMOTE_HOST}" >> "${LOGFILE}" 2>/dev/null
    fi
    
    # Pause after TMSH preflight (REST API goes straight to menu)
    if [ "${SESSION_MODE}" == "tmsh" ]; then
        press_enter_to_continue
    fi
    
    # Main menu loop
    while true; do
        show_main_menu
        
        if [ "${SESSION_MODE}" == "rest-api" ]; then
            # REST API mode menu
            read -rp "  Select option [0-4]: " choice
            
            case "${choice}" in
                1) menu_view_datagroup ;;
                2) menu_create_from_csv ;;
                3) menu_export_to_csv ;;
                4) menu_edit_datagroup_or_category ;;
                0)
                    log_section "Exit"
                    log_info "Session ended: $(date)"
                    log_info "Log file: ${LOGFILE}"
                    echo ""
                    exit 0
                    ;;
                *)
                    log_warn "Invalid selection."
                    press_enter_to_continue
                    ;;
            esac
        else
            # TMSH mode menu
            read -rp "  Select option [0-7]: " choice
            
            case "${choice}" in
                1) menu_list_datagroups ;;
                2) menu_view_datagroup ;;
                3) menu_create_from_csv ;;
                4) menu_delete_datagroup ;;
                5) menu_export_to_csv ;;
                6) menu_convert_url_category ;;
                7) menu_edit_datagroup_or_category ;;
                0)
                    log_section "Exit"
                    log_info "Session ended: $(date)"
                    log_info "Log file: ${LOGFILE}"
                    echo ""
                    exit 0
                    ;;
                *)
                    log_warn "Invalid selection."
                    press_enter_to_continue
                    ;;
            esac
        fi
    done
}

# Global arrays for CSV parsing
declare -a CSV_KEYS
declare -a CSV_VALUES

main "$@"
