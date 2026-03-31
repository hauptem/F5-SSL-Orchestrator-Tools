#!/bin/bash
# =============================================================================
# DGCat-Admin - F5 BIG-IP Datagroup and URL Category Administration Tool
# =============================================================================
# Version: 4.5
# Author: Eric Haupt
# Released under the MIT License. See LICENSE file for details.
# https://github.com/hauptem/F5-SSL-Orchestrator-Tools
#
# Requirements: BIG-IP TMOS 17.x or higher
#
# PURPOSE:
#   Menu-driven tool for managing LTM datagroups and URL categories used in 
#   SSL Orchestrator policies. Supports bulk import/export via CSV files,
#   backup before modifications, type validation, and bidirectional conversion
#   between datagroups and URL categories.
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

# Session logging (set to 1 to enable log file creation)
LOGGING_ENABLED=0

# API timeout settings (seconds)
# Connect timeout: max time to establish TCP connection to a BIG-IP
# Request timeout: max total time for any single API request
API_CONNECT_TIMEOUT=10
API_REQUEST_TIMEOUT=60

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
# CONNECTION SETTINGS
# =============================================================================

# Connection settings
REMOTE_HOST=""
REMOTE_USER=""
REMOTE_PASS=""
REMOTE_HOSTNAME=""

# API response storage
API_RESPONSE=""
API_HTTP_CODE=""

# Session cache (populated during preflight, avoids redundant API calls)
declare -A PARTITION_CACHE          # Partition existence: PARTITION_CACHE["Common"]="valid"
URL_CATEGORY_DB_CACHED=""           # URL DB availability: "yes", "no", or "" (not yet checked)

# =============================================================================
# FLEET CONFIGURATION
# =============================================================================

# Fleet configuration file
FLEET_CONFIG_FILE="${BACKUP_DIR}/fleet.conf"

# Runtime fleet arrays (parallel arrays - same index = same device)
declare -a FLEET_SITES
declare -a FLEET_HOSTS

# Track unique sites for deploy menu
declare -a FLEET_UNIQUE_SITES

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
    if [ "${LOGGING_ENABLED}" -eq 1 ]; then
        echo -e "$1" | tee -a "${LOGFILE}" 2>/dev/null
    else
        echo -e "$1"
    fi
}

log_section() {
    log ""
    log "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
    log "    ${WHITE}$1${NC}"
    log "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
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

# Validate CIDR entries have properly zeroed host bits
# BIG-IP rejects CIDR addresses where host bits are non-zero (e.g., 10.159.55.0/16)
# Args: keys_array_name
# Outputs: error_count|example1|example2|... (pipe-delimited, max 5 examples)
validate_cidr_alignment() {
    local keys_name=$1
    eval "local total=\${#${keys_name}[@]}"
    
    local error_count=0
    local examples=""
    
    for ((i=0; i<total; i++)); do
        eval "local entry=\"\${${keys_name}[$i]}\""
        
        # Only check entries with a prefix length (CIDR notation)
        if [[ "${entry}" != *"/"* ]]; then
            continue
        fi
        
        # Only check IPv4 CIDR
        if ! [[ "${entry}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
            continue
        fi
        
        local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}"
        local prefix="${BASH_REMATCH[5]}"
        
        # Skip invalid prefix lengths
        if [ "${prefix}" -lt 1 ] || [ "${prefix}" -gt 32 ]; then
            continue
        fi
        
        # Calculate network address by zeroing host bits
        local ip_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))
        local mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
        local net_int=$(( ip_int & mask ))
        
        local net_a=$(( (net_int >> 24) & 0xFF ))
        local net_b=$(( (net_int >> 16) & 0xFF ))
        local net_c=$(( (net_int >> 8) & 0xFF ))
        local net_d=$(( net_int & 0xFF ))
        
        local correct="${net_a}.${net_b}.${net_c}.${net_d}/${prefix}"
        
        if [ "${entry}" != "${correct}" ]; then
            error_count=$((error_count + 1))
            if [ ${error_count} -le 5 ]; then
                examples="${examples}|${entry} -> ${correct}"
            fi
        fi
    done
    
    echo "${error_count}${examples}"
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
# BIG-IP and CSV parsing require Unix line endings
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
    
    while true; do
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
            echo -e "${RED}  [FAIL]${NC}  ${WHITE}Datagroup '${dg_name}' does not exist in partition '${partition}'. Try again.${NC}" >&2
            continue
        fi
        
        echo "${dg_name}|${dg_class}"
        return 0
    done
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
            log_warn "Could not save configuration. Save manually via BIG-IP GUI or tmsh."
        fi
    fi
}

# =============================================================================
# API FUNCTIONS
# =============================================================================

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
        --connect-timeout "${API_CONNECT_TIMEOUT}"
        --max-time "${API_REQUEST_TIMEOUT}"
    )
    
    local response
    if [ -n "${data}" ]; then
        response=$(printf '%s' "${data}" | curl "${curl_opts[@]}" -d @- "${url}" 2>/dev/null) || {
            API_RESPONSE=""
            API_HTTP_CODE="000"
            return 1
        }
    else
        response=$(curl "${curl_opts[@]}" "${url}" 2>/dev/null) || {
            API_RESPONSE=""
            API_HTTP_CODE="000"
            return 1
        }
    fi
    
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
# Connection Functions
# -----------------------------------------------------------------------------

# Prompt for REST API connection details and test connection
# Uses FLEET_HOSTS/FLEET_SITES arrays if already loaded by load_fleet_config()
# Returns: 0 on successful connection, 1 on failure
setup_remote_connection() {
    log_section "REST API Connection Setup"
    
    # Show fleet hosts for quick selection if fleet is loaded
    if [ ${#FLEET_HOSTS[@]} -gt 0 ]; then
        echo ""
        echo -e "  ${WHITE}Fleet hosts:${NC}"
        echo -e "  ${CYAN}────────────────────────────────────────────────────────────${NC}"
        local i=1
        for idx in "${!FLEET_HOSTS[@]}"; do
            printf "    ${YELLOW}%2d)${NC} ${WHITE}%s (%s)${NC}\n" "${i}" "${FLEET_HOSTS[$idx]}" "${FLEET_SITES[$idx]}"
            i=$((i + 1))
        done
        echo -e "  ${CYAN}────────────────────────────────────────────────────────────${NC}"
        printf "    ${YELLOW} 0)${NC} ${WHITE}Exit${NC}\n"
    fi
    
    echo ""
    local host_input
    if [ ${#FLEET_HOSTS[@]} -gt 0 ]; then
        read -rp "  Select [0-${#FLEET_HOSTS[@]}] or enter hostname/IP: " host_input
    else
        read -rp "  BIG-IP hostname or IP (0 to exit): " host_input
    fi
    
    if [ "${host_input}" == "0" ]; then
        echo ""
        echo -e "  ${WHITE}Exiting.${NC}"
        echo -e "  ${CYAN}Latest version: https://github.com/hauptem/F5-SSL-Orchestrator-Tools${NC}"
        echo ""
        exit 0
    fi
    
    if [ -n "${host_input}" ] && [[ "${host_input}" =~ ^[0-9]+$ ]] && \
       [ ${#FLEET_HOSTS[@]} -gt 0 ] && \
       [ "${host_input}" -ge 1 ] && [ "${host_input}" -le ${#FLEET_HOSTS[@]} ] 2>/dev/null; then
        REMOTE_HOST="${FLEET_HOSTS[$((host_input - 1))]}"
    else
        REMOTE_HOST="${host_input}"
    fi
    
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
        
        # Retrieve system hostname for operator validation
        if api_get "/mgmt/tm/sys/global-settings"; then
            REMOTE_HOSTNAME=$(echo "${API_RESPONSE}" | jq -r '.hostname // empty' 2>/dev/null)
        fi
        if [ -z "${REMOTE_HOSTNAME}" ]; then
            REMOTE_HOSTNAME="${REMOTE_HOST}"
        fi
        
        log_ok "Connected to BIG-IP: ${REMOTE_HOSTNAME}"
        if [ -n "${version}" ]; then
            log_ok "TMOS version ${version}"
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
# Pre-flight checks
# Validates dependencies and establishes connection
# Returns: 0 on success, exits on critical failure
preflight_checks_rest_api() {
    log_section "Pre-Flight Checks"
    
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
    
    # Load fleet configuration if available (before connection for host selection)
    if load_fleet_config; then
        local host_word="hosts"
        local site_word="sites"
        [ ${#FLEET_HOSTS[@]} -eq 1 ] && host_word="host"
        [ ${#FLEET_UNIQUE_SITES[@]} -eq 1 ] && site_word="site"
        log_ok "Fleet loaded: ${#FLEET_HOSTS[@]} ${host_word} across ${#FLEET_UNIQUE_SITES[@]} ${site_word}"
    else
        # Create boilerplate fleet.conf for the user
        if [ ! -f "${FLEET_CONFIG_FILE}" ] && [ -d "${BACKUP_DIR}" ]; then
            cat > "${FLEET_CONFIG_FILE}" 2>/dev/null << 'FLEET_TEMPLATE'
# DGCat-Admin Fleet Configuration File
# This file defines BIG-IPs within an enterprise that will be managed by DGCat-Admin
# https://github.com/hauptem/F5-SSL-Orchestrator-Tools
#
# Format: SITE|HOSTNAME_OR_IP
#
# Examples:
# DC1|bigip01-mgmt.dc1.example.com
# DC1|bigip02-mgmt.dc1.example.com
# DC2|bigip01-mgmt.dc2.example.com
# DC2|bigip02-mgmt.dc2.example.com
#
# Site names: letters, numbers, dashes, underscores only
FLEET_TEMPLATE
            log_info "Fleet config template created: ${FLEET_CONFIG_FILE}"
        else
            log_info "No fleet configured (optional: create ${FLEET_CONFIG_FILE})"
        fi
    fi
    
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
            echo -e "  ${CYAN}Latest version: https://github.com/hauptem/F5-SSL-Orchestrator-Tools${NC}"
            exit 0
        fi
    done
    
    # Validate partitions exist on target system
    log_step "Validating partitions on target system..."
    local invalid_count=0
    for partition in "${PARTITION_LIST[@]}"; do
        if ! partition_exists "${partition}"; then
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
    
    # Cache URL category DB availability for the session
    if url_category_db_available; then
        log_ok "URL category database available"
    else
        log_info "URL category database not available (URL filtering module may not be provisioned)"
    fi
    
    log ""
    log_info "Connected to: ${REMOTE_HOSTNAME}"
    if [ "${LOGGING_ENABLED}" -eq 1 ]; then
        log_info "Log file: ${LOGFILE}"
    fi
}
# -----------------------------------------------------------------------------
# System Functions
# -----------------------------------------------------------------------------

# Get BIG-IP version
get_version_remote() {
    if api_get "/mgmt/tm/sys/version"; then
        echo "${API_RESPONSE}" | jq -r '.entries[].nestedStats.entries.Version.description // "unknown"' 2>/dev/null | head -1
        return 0
    fi
    echo "unknown"
    return 1
}

# Save configuration
save_config_remote() {
    local data='{"command":"save"}'
    if api_post "/mgmt/tm/sys/config" "${data}"; then
        return 0
    fi
    return 1
}

# Check if partition exists
partition_exists_remote() {
    local partition="$1"
    if api_get "/mgmt/tm/auth/partition/${partition}"; then
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# Datagroup Functions
# -----------------------------------------------------------------------------

# Get list of datagroups in a partition
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

# Check if datagroup exists by partition and name
internal_datagroup_exists_remote() {
    local partition="$1"
    local dg_name="$2"
    
    if api_get "/mgmt/tm/ltm/data-group/internal/~${partition}~${dg_name}"; then
        return 0
    fi
    return 1
}

# Get datagroup type by partition and name
get_internal_datagroup_type_remote() {
    local partition="$1"
    local dg_name="$2"
    
    if api_get "/mgmt/tm/ltm/data-group/internal/~${partition}~${dg_name}"; then
        echo "${API_RESPONSE}" | jq -r '.type // empty' 2>/dev/null
        return 0
    fi
    return 1
}

# Get datagroup records as key|value lines
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

# Create datagroup
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

# Apply records to datagroup (replace all)
# Args: partition, name, records_json
# records_json format: [{"name":"key1","data":"value1"},{"name":"key2"}]
apply_internal_datagroup_records_remote() {
    local partition="$1"
    local dg_name="$2"
    local records_json="$3"
    
    local data
    data=$(printf '%s' "${records_json}" | jq '{records: .}')
    
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
# URL Category Functions
# -----------------------------------------------------------------------------

# Check if URL category exists by name
url_category_exists_remote() {
    local cat_name="$1"
    
    if api_get "/mgmt/tm/sys/url-db/url-category/~Common~${cat_name}"; then
        return 0
    fi
    return 1
}

# Get list of URL categories
get_url_category_list_remote() {
    if ! api_get "/mgmt/tm/sys/url-db/url-category"; then
        return 1
    fi
    
    echo "${API_RESPONSE}" | jq -r '.items // [] | .[].name' 2>/dev/null | sort || true
}

# Get URL entries from a category
get_url_category_entries_remote() {
    local cat_name="$1"
    
    if ! api_get "/mgmt/tm/sys/url-db/url-category/~Common~${cat_name}"; then
        return 1
    fi
    
    echo "${API_RESPONSE}" | jq -r '.urls // [] | .[].name' 2>/dev/null || true
}

# Get URL count from a category
get_url_category_count_remote() {
    local cat_name="$1"
    
    if ! api_get "/mgmt/tm/sys/url-db/url-category/~Common~${cat_name}"; then
        echo "0"
        return 1
    fi
    
    echo "${API_RESPONSE}" | jq -r '.urls // [] | length' 2>/dev/null || echo "0"
}

# Create URL category
# Args: cat_name, default_action, urls_json
# urls_json format: [{"name":"https://example.com/","type":"exact-match"}]
create_url_category_remote() {
    local cat_name="$1"
    local default_action="$2"
    local urls_json="$3"
    
    local data
    data=$(printf '%s' "${urls_json}" | jq \
        --arg name "${cat_name}" \
        --arg displayName "${cat_name}" \
        --arg defaultAction "${default_action}" \
        '{name: $name, displayName: $displayName, defaultAction: $defaultAction, urls: .}')
    
    if api_post "/mgmt/tm/sys/url-db/url-category" "${data}"; then
        return 0
    fi
    return 1
}

# Add URLs to existing category
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
    merged_urls=$(printf '%s\n%s' "${existing_urls}" "${urls_json}" | jq -sc '.[0] + .[1] | unique_by(.name)')
    
    local data
    data=$(printf '%s' "${merged_urls}" | jq '{urls: .}')
    
    if api_patch "/mgmt/tm/sys/url-db/url-category/~Common~${cat_name}" "${data}"; then
        return 0
    fi
    return 1
}

# Delete URLs from existing category
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
    remaining_urls=$(printf '%s\n%s' "${existing_urls}" "${delete_array}" | jq -sc '
        .[0] as $existing | .[1] as $delete |
        $existing | map(select(.name as $n | $delete | index($n) | not))
    ')
    
    local data
    data=$(printf '%s' "${remaining_urls}" | jq '{urls: .}')
    
    if api_patch "/mgmt/tm/sys/url-db/url-category/~Common~${cat_name}" "${data}"; then
        return 0
    fi
    return 1
}

# Replace all URLs in category
# Args: cat_name, urls_json
modify_url_category_replace_remote() {
    local cat_name="$1"
    local urls_json="$2"
    
    local data
    data=$(printf '%s' "${urls_json}" | jq '{urls: .}')
    
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

# -----------------------------------------------------------------------------
# Delete Functions
# -----------------------------------------------------------------------------

# Delete datagroup
# Args: partition, dg_name
# Returns: 0 on success, 1 on failure
delete_internal_datagroup_remote() {
    local partition="$1"
    local dg_name="$2"
    
    if api_delete "/mgmt/tm/ltm/data-group/internal/~${partition}~${dg_name}"; then
        return 0
    fi
    return 1
}

# Delete URL category by name
# Args: cat_name
# Returns: 0 on success, 1 on failure
delete_url_category_remote() {
    local cat_name="$1"
    
    if api_delete "/mgmt/tm/sys/url-db/url-category/~Common~${cat_name}"; then
        return 0
    fi
    return 1
}
# Delete internal datagroup
# Args: partition, dg_name
# Returns: 0 on success, 1 on failure
delete_internal_datagroup() {
    local partition="$1"
    local dg_name="$2"
    delete_internal_datagroup_remote "${partition}" "${dg_name}"
    return $?
}
# Delete URL category
# Args: cat_name
# Returns: 0 on success, 1 on failure
delete_url_category() {
    local cat_name="$1"
    delete_url_category_remote "${cat_name}"
    return $?
}

# =============================================================================
# FLEET MANAGEMENT FUNCTIONS
# =============================================================================

# Load fleet configuration from file
# Populates FLEET_SITES, FLEET_HOSTS, and FLEET_UNIQUE_SITES arrays
# Returns: 0 on success, 1 if file not found or empty
load_fleet_config() {
    FLEET_SITES=()
    FLEET_HOSTS=()
    FLEET_UNIQUE_SITES=()
    
    if [ ! -f "${FLEET_CONFIG_FILE}" ]; then
        return 1
    fi
    
    local -A seen_sites=()
    
    while IFS= read -r line || [ -n "${line}" ]; do
        # Skip empty lines and comments
        [ -z "${line}" ] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        
        # Trim whitespace
        line=$(echo "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "${line}" ] && continue
        
        # Parse SITE|HOST format
        local site host
        site=$(echo "${line}" | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        host=$(echo "${line}" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Validate format
        if [ -z "${site}" ] || [ -z "${host}" ]; then
            continue
        fi
        
        # Validate site ID (alphanumeric, dash, underscore only)
        if ! [[ "${site}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            continue
        fi
        
        FLEET_SITES+=("${site}")
        FLEET_HOSTS+=("${host}")
        
        # Track unique sites (use +x to avoid unbound variable error with set -u)
        if [ -z "${seen_sites[${site}]+x}" ]; then
            seen_sites["${site}"]=1
            FLEET_UNIQUE_SITES+=("${site}")
        fi
    done < "${FLEET_CONFIG_FILE}"
    
    if [ ${#FLEET_HOSTS[@]} -eq 0 ]; then
        return 1
    fi
    
    return 0
}

# Get hosts for a specific site
# Args: site_id
# Outputs: hostnames (one per line)
get_site_hosts() {
    local site_id="$1"
    
    for i in "${!FLEET_HOSTS[@]}"; do
        if [ "${FLEET_SITES[$i]}" == "${site_id}" ]; then
            echo "${FLEET_HOSTS[$i]}"
        fi
    done
}

# Get site ID for a host
# Args: hostname
# Outputs: site_id or empty if not found
get_host_site() {
    local hostname="$1"
    
    for i in "${!FLEET_HOSTS[@]}"; do
        if [ "${FLEET_HOSTS[$i]}" == "${hostname}" ]; then
            echo "${FLEET_SITES[$i]}"
            return 0
        fi
    done
    return 1
}

# Count hosts in a site
# Args: site_id
# Outputs: count
count_site_hosts() {
    local site_id="$1"
    local count=0
    
    for site in "${FLEET_SITES[@]}"; do
        if [ "${site}" == "${site_id}" ]; then
            count=$((count + 1))
        fi
    done
    
    echo "${count}"
}

# Check if fleet is configured and loaded
# Returns: 0 if fleet available, 1 if not
fleet_available() {
    if [ ${#FLEET_HOSTS[@]} -gt 0 ]; then
        return 0
    fi
    return 1
}

# Ensure site log directory exists
# Args: site_id
# Returns: 0 on success, 1 on failure
ensure_site_log_dir() {
    local site_id="$1"
    local site_dir="${BACKUP_DIR}/${site_id}"
    
    if [ ! -d "${site_dir}" ]; then
        mkdir -p "${site_dir}" 2>/dev/null || return 1
    fi
    return 0
}

# Get the correct backup directory for the connected host
# If the connected host is part of a fleet site, returns the site subfolder
# Otherwise returns the root backup directory
# Outputs: backup directory path
get_connected_backup_dir() {
    local host_site
    host_site=$(get_host_site "${REMOTE_HOST}" 2>/dev/null) || true
    if [ -n "${host_site}" ]; then
        ensure_site_log_dir "${host_site}" 2>/dev/null || true
        echo "${BACKUP_DIR}/${host_site}"
    else
        echo "${BACKUP_DIR}"
    fi
}

# Get log file path for a host
# Args: site_id, hostname
# Outputs: log file path
get_host_log_path() {
    local site_id="$1"
    local hostname="$2"
    local safe_hostname
    safe_hostname=$(echo "${hostname}" | sed 's/[^a-zA-Z0-9_-]/_/g')
    
    echo "${BACKUP_DIR}/${site_id}/${safe_hostname}_${TIMESTAMP}.log"
}

# =============================================================================
# DEPLOY VALIDATION FUNCTIONS
# =============================================================================

# Test connectivity to a single host using current credentials
# Args: hostname
# Returns: 0 on success, 1 on failure
# Sets: API_RESPONSE, API_HTTP_CODE
test_host_connection() {
    local host="$1"
    
    # Temporarily swap REMOTE_HOST
    local orig_host="${REMOTE_HOST}"
    REMOTE_HOST="${host}"
    
    local result=1
    if api_get "/mgmt/tm/sys/version"; then
        result=0
    fi
    
    # Restore original
    REMOTE_HOST="${orig_host}"
    return ${result}
}

# Verify internal datagroup exists on remote host
# Args: hostname, partition, dg_name
# Returns: 0 if exists, 1 if not
verify_remote_internal_datagroup() {
    local host="$1"
    local partition="$2"
    local dg_name="$3"
    
    local orig_host="${REMOTE_HOST}"
    REMOTE_HOST="${host}"
    
    local result=1
    if internal_datagroup_exists_remote "${partition}" "${dg_name}"; then
        result=0
    fi
    
    REMOTE_HOST="${orig_host}"
    return ${result}
}

# Verify URL category exists on remote host
# Args: hostname, cat_name
# Returns: 0 if exists, 1 if not
verify_remote_url_category() {
    local host="$1"
    local cat_name="$2"
    
    local orig_host="${REMOTE_HOST}"
    REMOTE_HOST="${host}"
    
    local result=1
    if url_category_exists_remote "${cat_name}"; then
        result=0
    fi
    
    REMOTE_HOST="${orig_host}"
    return ${result}
}

# Create backup of internal datagroup on remote host
# Args: hostname, partition, dg_name, site_id
# Returns: 0 on success, 1 on failure
# Outputs: backup file path
backup_remote_internal_datagroup() {
    local host="$1"
    local partition="$2"
    local dg_name="$3"
    local site_id="$4"
    
    local orig_host="${REMOTE_HOST}"
    REMOTE_HOST="${host}"
    
    # Ensure site directory exists
    ensure_site_log_dir "${site_id}"
    
    local safe_hostname
    safe_hostname=$(echo "${host}" | sed 's/[^a-zA-Z0-9_-]/_/g')
    local backup_file="${BACKUP_DIR}/${site_id}/${safe_hostname}_${partition}_${dg_name}_${TIMESTAMP}.csv"
    
    local dg_type
    dg_type=$(get_internal_datagroup_type_remote "${partition}" "${dg_name}")
    
    {
        echo "# Datagroup Backup: /${partition}/${dg_name}"
        echo "# Host: ${host}"
        echo "# Site: ${site_id}"
        echo "# Type: ${dg_type}"
        echo "# Created: $(date)"
        echo "# Reason: Pre-deploy backup"
        echo "#"
        get_internal_datagroup_records_remote "${partition}" "${dg_name}" | while IFS='|' read -r key value; do
            echo "${key},${value}"
        done
    } > "${backup_file}" 2>/dev/null
    
    REMOTE_HOST="${orig_host}"
    
    if [ -f "${backup_file}" ]; then
        echo "${backup_file}"
        return 0
    fi
    return 1
}

# Create backup of URL category on remote host
# Args: hostname, cat_name, site_id
# Returns: 0 on success, 1 on failure
# Outputs: backup file path
backup_remote_url_category() {
    local host="$1"
    local cat_name="$2"
    local site_id="$3"
    
    local orig_host="${REMOTE_HOST}"
    REMOTE_HOST="${host}"
    
    # Ensure site directory exists
    ensure_site_log_dir "${site_id}"
    
    local safe_hostname
    safe_hostname=$(echo "${host}" | sed 's/[^a-zA-Z0-9_-]/_/g')
    local safe_catname
    safe_catname=$(echo "${cat_name}" | sed 's/[^a-zA-Z0-9_-]/_/g')
    local backup_file="${BACKUP_DIR}/${site_id}/${safe_hostname}_urlcat_${safe_catname}_${TIMESTAMP}.csv"
    
    {
        echo "# URL Category Backup: ${cat_name}"
        echo "# Host: ${host}"
        echo "# Site: ${site_id}"
        echo "# Created: $(date)"
        echo "# Reason: Pre-deploy backup"
        echo "#"
        get_url_category_entries_remote "${cat_name}"
    } > "${backup_file}" 2>/dev/null
    
    REMOTE_HOST="${orig_host}"
    
    if [ -f "${backup_file}" ]; then
        echo "${backup_file}"
        return 0
    fi
    return 1
}

# =============================================================================
# DEPLOY EXECUTION FUNCTIONS
# =============================================================================

# Global for tracking deploy error
DEPLOY_ERROR_MSG=""

# Display deploy scope selection menu
# Args: object_type ("datagroup" or "urlcat"), object_name
# Outputs: selected hosts (newline-separated) or empty if cancelled
# Returns: 0 on selection, 1 on cancel
select_deploy_scope() {
    local object_type="$1"
    local object_name="$2"
    
    echo "" >&2
    echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}" >&2
    echo -e "  ${WHITE}  DEPLOY SCOPE SELECTION${NC}" >&2
    echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}" >&2
    echo "" >&2
    echo -e "  ${WHITE}Object: ${object_name}${NC}" >&2
    echo -e "  ${WHITE}Type:   ${object_type}${NC}" >&2
    echo "" >&2
    echo -e "  ${WHITE}Select deployment scope:${NC}" >&2
    echo "" >&2
    
    # Option 1: Entire topology (show true counts, connected host excluded at deploy time)
    local total_hosts=${#FLEET_HOSTS[@]}
    
    # Pluralization for topology
    local topo_host_word="hosts"
    local topo_site_word="sites"
    [ ${total_hosts} -eq 1 ] && topo_host_word="host"
    [ ${#FLEET_UNIQUE_SITES[@]} -eq 1 ] && topo_site_word="site"
    
    echo -e "    ${YELLOW}1)${NC} ${WHITE}Entire topology${NC} (${total_hosts} ${topo_host_word} across ${#FLEET_UNIQUE_SITES[@]} ${topo_site_word})" >&2
    
    # Options 2+: Individual sites
    local option_num=2
    for site in "${FLEET_UNIQUE_SITES[@]}"; do
        local site_count
        site_count=$(count_site_hosts "${site}")
        
        # Pluralization for site
        local site_host_word="hosts"
        [ ${site_count} -eq 1 ] && site_host_word="host"
        
        echo -e "    ${YELLOW}${option_num})${NC} ${WHITE}Site: ${site}${NC} (${site_count} ${site_host_word})" >&2
        option_num=$((option_num + 1))
    done
    
    echo "" >&2
    echo -e "    ${YELLOW}0)${NC} ${WHITE}Cancel${NC}" >&2
    echo "" >&2
    
    local max_option=$((option_num - 1))
    read -rp "  Select [0-${max_option}]: " scope_choice
    
    if [ "${scope_choice}" == "0" ] || [ -z "${scope_choice}" ]; then
        return 1
    fi
    
    if ! [[ "${scope_choice}" =~ ^[0-9]+$ ]] || [ "${scope_choice}" -lt 1 ] || [ "${scope_choice}" -gt ${max_option} ]; then
        return 1
    fi
    
    # Build target list based on selection
    local -a targets=()
    
    if [ "${scope_choice}" == "1" ]; then
        # Entire topology
        for host in "${FLEET_HOSTS[@]}"; do
            if [ "${host}" != "${REMOTE_HOST}" ]; then
                targets+=("${host}")
            fi
        done
    else
        # Specific site
        local site_index=$((scope_choice - 2))
        local selected_site="${FLEET_UNIQUE_SITES[${site_index}]}"
        
        for i in "${!FLEET_HOSTS[@]}"; do
            if [ "${FLEET_SITES[$i]}" == "${selected_site}" ] && [ "${FLEET_HOSTS[$i]}" != "${REMOTE_HOST}" ]; then
                targets+=("${FLEET_HOSTS[$i]}")
            fi
        done
    fi
    
    # Output selected hosts
    printf '%s\n' "${targets[@]}"
    return 0
}

# Deploy internal datagroup to a single host
# Args: hostname, partition, dg_name, dg_type, records_json, site_id, deploy_mode, additions_json, deletions_list
# deploy_mode: "replace" (default) or "merge"
# For merge: additions_json = JSON records to add, deletions_list = newline-separated keys to remove
# Returns: 0 on success, 1 on failure
# Sets: DEPLOY_ERROR_MSG on failure
deploy_internal_datagroup_to_host() {
    local host="$1"
    local partition="$2"
    local dg_name="$3"
    local dg_type="$4"
    local records_json="$5"
    local site_id="$6"
    local deploy_mode="${7:-replace}"
    local additions_json="${8:-[]}"
    local deletions_list="${9:-}"
    
    DEPLOY_ERROR_MSG=""
    
    local orig_host="${REMOTE_HOST}"
    REMOTE_HOST="${host}"
    
    local final_records_json="${records_json}"
    
    if [ "${deploy_mode}" == "merge" ]; then
        # Pull current records from target host
        local target_records
        if ! target_records=$(get_internal_datagroup_records_remote "${partition}" "${dg_name}"); then
            DEPLOY_ERROR_MSG="Failed to read target records (HTTP ${API_HTTP_CODE})"
            REMOTE_HOST="${orig_host}"
            return 1
        fi
        
        # Build merged result: start with target, remove deletions, add additions
        # Use jq to merge: target records - deletions + additions
        local delete_array
        delete_array=$(echo "${deletions_list}" | jq -R -s 'split("\n") | map(select(length > 0))')
        
        local target_json
        target_json=$(echo "${target_records}" | build_records_json_remote "${dg_type}")
        
        final_records_json=$(printf '%s\n%s\n%s' "${target_json}" "${additions_json}" "${delete_array}" | jq -sc '
            .[0] as $target | .[1] as $additions | .[2] as $deletions |
            ($target | map(select(.name as $n | $deletions | index($n) | not))) + $additions | unique_by(.name)')
    fi
    
    # Apply records
    if ! apply_internal_datagroup_records_remote "${partition}" "${dg_name}" "${final_records_json}"; then
        echo -e "  ${RED}[FAIL]${NC}  ${WHITE}Applying changes${NC}"
        DEPLOY_ERROR_MSG="Failed to apply records (HTTP ${API_HTTP_CODE})"
        REMOTE_HOST="${orig_host}"
        return 1
    fi
    echo -e "  ${GREEN}[ OK ]${NC}  ${WHITE}Applying changes${NC}"
    
    # Save config
    if ! save_config_remote; then
        echo -e "  ${RED}[FAIL]${NC}  ${WHITE}Saving configuration${NC}"
        DEPLOY_ERROR_MSG="Applied but failed to save config (HTTP ${API_HTTP_CODE})"
        REMOTE_HOST="${orig_host}"
        return 1
    fi
    echo -e "  ${GREEN}[ OK ]${NC}  ${WHITE}Saving configuration${NC}"
    
    REMOTE_HOST="${orig_host}"
    return 0
}

# Deploy URL category to a single host
# Args: hostname, cat_name, urls_json, site_id, deploy_mode, additions_json, deletions_list
# deploy_mode: "replace" (default) or "merge"
# For merge: additions_json = JSON URLs to add, deletions_list = newline-separated URLs to remove
# Returns: 0 on success, 1 on failure
# Sets: DEPLOY_ERROR_MSG on failure
deploy_url_category_to_host() {
    local host="$1"
    local cat_name="$2"
    local urls_json="$3"
    local site_id="$4"
    local deploy_mode="${5:-replace}"
    local additions_json="${6:-[]}"
    local deletions_list="${7:-}"
    
    DEPLOY_ERROR_MSG=""
    
    local orig_host="${REMOTE_HOST}"
    REMOTE_HOST="${host}"
    
    if [ "${deploy_mode}" == "merge" ]; then
        # Merge mode: apply only additions and deletions
        local merge_errors=0
        
        # Delete removed URLs
        if [ -n "${deletions_list}" ]; then
            if ! modify_url_category_delete_remote "${cat_name}" "${deletions_list}"; then
                merge_errors=$((merge_errors + 1))
            fi
        fi
        
        # Add new URLs
        if [ "${additions_json}" != "[]" ]; then
            if ! modify_url_category_add_remote "${cat_name}" "${additions_json}"; then
                merge_errors=$((merge_errors + 1))
            fi
        fi
        
        if [ ${merge_errors} -gt 0 ]; then
            echo -e "  ${RED}[FAIL]${NC}  ${WHITE}Applying changes${NC}"
            DEPLOY_ERROR_MSG="Merge completed with ${merge_errors} error(s) (HTTP ${API_HTTP_CODE})"
            REMOTE_HOST="${orig_host}"
            return 1
        fi
        echo -e "  ${GREEN}[ OK ]${NC}  ${WHITE}Applying changes${NC}"
    else
        # Replace mode: overwrite all URLs
        if ! modify_url_category_replace_remote "${cat_name}" "${urls_json}"; then
            echo -e "  ${RED}[FAIL]${NC}  ${WHITE}Applying changes${NC}"
            DEPLOY_ERROR_MSG="Failed to apply URLs (HTTP ${API_HTTP_CODE})"
            REMOTE_HOST="${orig_host}"
            return 1
        fi
        echo -e "  ${GREEN}[ OK ]${NC}  ${WHITE}Applying changes${NC}"
    fi
    
    # Save config
    if ! save_config_remote; then
        echo -e "  ${RED}[FAIL]${NC}  ${WHITE}Saving configuration${NC}"
        DEPLOY_ERROR_MSG="Applied but failed to save config (HTTP ${API_HTTP_CODE})"
        REMOTE_HOST="${orig_host}"
        return 1
    fi
    echo -e "  ${GREEN}[ OK ]${NC}  ${WHITE}Saving configuration${NC}"
    
    REMOTE_HOST="${orig_host}"
    return 0
}

# Run pre-deploy validation for internal datagroup
# Args: partition, dg_name, targets (newline-separated hosts)
# Returns: 0 if all pass, 1 if any fail
# Outputs: validation summary to stderr, results to stdout
run_predeploy_validation_datagroup() {
    local partition="$1"
    local dg_name="$2"
    local targets="$3"
    
    local all_passed=true
    local -a validation_results=()
    
    echo "" >&2
    
    while IFS= read -r host; do
        [ -z "${host}" ] && continue
        
        local site_id
        site_id=$(get_host_site "${host}")
        
        echo -ne "  ${WHITE}[....] ${host} (${site_id})${NC}\r" >&2
        
        # Test connectivity
        if ! test_host_connection "${host}"; then
            echo -e "\033[2K\r  ${RED}[FAIL]${NC} ${WHITE}${host} (${site_id})${NC} - Connection failed" >&2
            validation_results+=("${host}|${site_id}|FAIL|Connection failed")
            all_passed=false
            continue
        fi
        
        # Verify object exists
        if ! verify_remote_internal_datagroup "${host}" "${partition}" "${dg_name}"; then
            echo -e "\033[2K\r  ${RED}[FAIL]${NC} ${WHITE}${host} (${site_id})${NC} - Datagroup not found" >&2
            validation_results+=("${host}|${site_id}|FAIL|Datagroup not found")
            continue
        fi
        
        echo -e "\033[2K\r  ${GREEN}[ OK ]${NC} ${WHITE}${host} (${site_id})${NC} - Ready" >&2
        validation_results+=("${host}|${site_id}|OK|Ready")
    done <<< "${targets}"
    
    echo "" >&2
    echo -e "  ${CYAN}──────────────────────────────────────────────────────────────${NC}" >&2
    
    # Count results
    local ok_count=0
    local fail_count=0
    
    for result in "${validation_results[@]}"; do
        local status
        status=$(echo "${result}" | cut -d'|' -f3)
        case "${status}" in
            OK) ok_count=$((ok_count + 1)) ;;
            *) fail_count=$((fail_count + 1)) ;;
        esac
    done
    
    echo -e "  ${WHITE}Validation complete: ${GREEN}${ok_count} ready${NC}, ${RED}${fail_count} failed${NC}" >&2
    
    # Output results for deploy function to use
    printf '%s\n' "${validation_results[@]}"
    
    if [ "${all_passed}" == "true" ]; then
        return 0
    fi
    return 1
}

# Run pre-deploy validation for URL category
# Args: cat_name, targets (newline-separated hosts)
# Returns: 0 if all pass, 1 if any fail
# Outputs: validation summary to stderr, results to stdout
run_predeploy_validation_urlcat() {
    local cat_name="$1"
    local targets="$2"
    
    local all_passed=true
    local -a validation_results=()
    
    echo "" >&2
    
    while IFS= read -r host; do
        [ -z "${host}" ] && continue
        
        local site_id
        site_id=$(get_host_site "${host}")
        
        echo -ne "  ${WHITE}[....] ${host} (${site_id})${NC}\r" >&2
        
        # Test connectivity
        if ! test_host_connection "${host}"; then
            echo -e "\033[2K\r  ${RED}[FAIL]${NC} ${WHITE}${host} (${site_id})${NC} - Connection failed" >&2
            validation_results+=("${host}|${site_id}|FAIL|Connection failed")
            all_passed=false
            continue
        fi
        
        # Verify object exists
        if ! verify_remote_url_category "${host}" "${cat_name}"; then
            echo -e "  ${RED}[FAIL]${NC} ${WHITE}${host} (${site_id})${NC} - Category not found" >&2
            validation_results+=("${host}|${site_id}|FAIL|Category not found")
            continue
        fi
        
        echo -e "\033[2K\r  ${GREEN}[ OK ]${NC} ${WHITE}${host} (${site_id})${NC} - Ready" >&2
        validation_results+=("${host}|${site_id}|OK|Ready")
    done <<< "${targets}"
    
    echo "" >&2
    echo -e "  ${CYAN}──────────────────────────────────────────────────────────────${NC}" >&2
    
    # Count results
    local ok_count=0
    local fail_count=0
    
    for result in "${validation_results[@]}"; do
        local status
        status=$(echo "${result}" | cut -d'|' -f3)
        case "${status}" in
            OK) ok_count=$((ok_count + 1)) ;;
            *) fail_count=$((fail_count + 1)) ;;
        esac
    done
    
    echo -e "  ${WHITE}Validation complete: ${GREEN}${ok_count} ready${NC}, ${RED}${fail_count} failed${NC}" >&2
    
    # Output results for deploy function to use
    printf '%s\n' "${validation_results[@]}"
    
    if [ "${all_passed}" == "true" ]; then
        return 0
    fi
    return 1
}

# Execute deploy for internal datagroup
# Args: partition, dg_name, dg_type, records_json, validation_results (newline-separated), current_host, current_status, current_message, deploy_mode, additions_json, deletions_list
# Returns: 0 on complete success, 1 on any failure
execute_deploy_datagroup() {
    local partition="$1"
    local dg_name="$2"
    local dg_type="$3"
    local records_json="$4"
    local validation_results="$5"
    local current_host="${6:-}"
    local current_status="${7:-}"
    local current_message="${8:-}"
    local deploy_mode="${9:-replace}"
    local additions_json="${10:-[]}"
    local deletions_list="${11:-}"
    
    local success_count=0
    local fail_count=0
    local skip_count=0
    local last_error=""
    local consecutive_same_error=0
    local -a deploy_results=()
    
    # Add current device to results if provided
    if [ -n "${current_host}" ]; then
        deploy_results+=("${current_host}|CURRENT|${current_status}|${current_message}")
        if [ "${current_status}" == "OK" ]; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    fi
    
    while IFS='|' read -r host site_id status message; do
        [ -z "${host}" ] && continue
        
        # Pre-check failures are skips in deploy - FAIL is reserved for actual deploy failures
        if [ "${status}" != "OK" ]; then
            deploy_results+=("${host}|${site_id}|SKIP|")
            skip_count=$((skip_count + 1))
            continue
        fi
        
        echo ""
        echo -ne "  ${WHITE}Deploying to ${host} (${site_id})...${NC}\n"
        
        # Backup
        local backup_file
        backup_file=$(backup_remote_internal_datagroup "${host}" "${partition}" "${dg_name}" "${site_id}")
        if [ -z "${backup_file}" ]; then
            echo -e "  ${RED}[FAIL]${NC}  ${WHITE}Creating backup${NC}"
            deploy_results+=("${host}|${site_id}|FAIL|Backup failed")
            fail_count=$((fail_count + 1))
            last_error="Backup failed"
            consecutive_same_error=$((consecutive_same_error + 1))
            if [ ${consecutive_same_error} -ge 3 ]; then
                echo ""
                log_warn "Systemic failure detected: Same error on 3 consecutive hosts"
                read -rp "  Continue deploying to remaining hosts? (yes/no) [no]: " cont_deploy
                if [ "${cont_deploy}" != "yes" ]; then
                    log_info "Deployment stopped by user."
                    break
                fi
                consecutive_same_error=0
            fi
            continue
        fi
        echo -e "  ${GREEN}[ OK ]${NC}  ${WHITE}Creating backup${NC}"
        
        # Deploy (apply + save with verbose output)
        if deploy_internal_datagroup_to_host "${host}" "${partition}" "${dg_name}" "${dg_type}" "${records_json}" "${site_id}" "${deploy_mode}" "${additions_json}" "${deletions_list}"; then
            deploy_results+=("${host}|${site_id}|OK|Deployed and saved")
            success_count=$((success_count + 1))
            last_error=""
            consecutive_same_error=0
        else
            deploy_results+=("${host}|${site_id}|FAIL|${DEPLOY_ERROR_MSG}")
            fail_count=$((fail_count + 1))
            
            # Check for systemic failure (same error on consecutive hosts)
            if [ "${DEPLOY_ERROR_MSG}" == "${last_error}" ]; then
                consecutive_same_error=$((consecutive_same_error + 1))
                if [ ${consecutive_same_error} -ge 3 ]; then
                    echo ""
                    log_warn "Systemic failure detected: Same error on 3 consecutive hosts"
                    read -rp "  Continue deploying to remaining hosts? (yes/no) [no]: " cont_deploy
                    if [ "${cont_deploy}" != "yes" ]; then
                        log_info "Deployment stopped by user."
                        break
                    fi
                    consecutive_same_error=0
                fi
            else
                last_error="${DEPLOY_ERROR_MSG}"
                consecutive_same_error=1
            fi
        fi
    done <<< "${validation_results}"
    
    # Display summary
    echo ""
    echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}  DEPLOY SUMMARY${NC}"
    echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    printf "  ${WHITE}%-35s %-10s %-8s %s${NC}\n" "HOST" "SITE" "STATUS" "MESSAGE"
    echo -e "  ${CYAN}──────────────────────────────────────────────────────────────${NC}"
    
    for result in "${deploy_results[@]}"; do
        local r_host r_site r_status r_message
        IFS='|' read -r r_host r_site r_status r_message <<< "${result}"
        
        local status_color="${WHITE}"
        case "${r_status}" in
            OK) status_color="${GREEN}" ;;
            FAIL) status_color="${RED}" ;;
            SKIP) status_color="${YELLOW}" ;;
        esac
        
        # Mark current device
        local site_display="${r_site}"
        if [ "${r_site}" == "CURRENT" ]; then
            site_display="(current)"
        fi
        
        printf "  ${WHITE}%-35s${NC} ${WHITE}%-10s${NC} ${status_color}%-8s${NC} ${WHITE}%s${NC}\n" \
            "${r_host:0:35}" "${site_display}" "${r_status}" "${r_message:0:30}"
    done
    
    echo -e "  ${CYAN}──────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}Total: ${GREEN}${success_count} succeeded${NC}, ${RED}${fail_count} failed${NC}, ${YELLOW}${skip_count} skipped${NC}"
    echo ""
    
    if [ ${fail_count} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Execute deploy for URL category
# Args: cat_name, urls_json, validation_results (newline-separated), current_host, current_status, current_message, deploy_mode, additions_json, deletions_list
# Returns: 0 on complete success, 1 on any failure
execute_deploy_urlcat() {
    local cat_name="$1"
    local urls_json="$2"
    local validation_results="$3"
    local current_host="${4:-}"
    local current_status="${5:-}"
    local current_message="${6:-}"
    local deploy_mode="${7:-replace}"
    local additions_json="${8:-[]}"
    local deletions_list="${9:-}"
    
    local success_count=0
    local fail_count=0
    local skip_count=0
    local last_error=""
    local consecutive_same_error=0
    local -a deploy_results=()
    
    # Add current device to results if provided
    if [ -n "${current_host}" ]; then
        deploy_results+=("${current_host}|CURRENT|${current_status}|${current_message}")
        if [ "${current_status}" == "OK" ]; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    fi
    
    while IFS='|' read -r host site_id status message; do
        [ -z "${host}" ] && continue
        
        # Pre-check failures are skips in deploy - FAIL is reserved for actual deploy failures
        if [ "${status}" != "OK" ]; then
            deploy_results+=("${host}|${site_id}|SKIP|")
            skip_count=$((skip_count + 1))
            continue
        fi
        
        echo ""
        echo -ne "  ${WHITE}Deploying to ${host} (${site_id})...${NC}\n"
        
        # Backup
        local backup_file
        backup_file=$(backup_remote_url_category "${host}" "${cat_name}" "${site_id}")
        if [ -z "${backup_file}" ]; then
            echo -e "  ${RED}[FAIL]${NC}  ${WHITE}Creating backup${NC}"
            deploy_results+=("${host}|${site_id}|FAIL|Backup failed")
            fail_count=$((fail_count + 1))
            last_error="Backup failed"
            consecutive_same_error=$((consecutive_same_error + 1))
            if [ ${consecutive_same_error} -ge 3 ]; then
                echo ""
                log_warn "Systemic failure detected: Same error on 3 consecutive hosts"
                read -rp "  Continue deploying to remaining hosts? (yes/no) [no]: " cont_deploy
                if [ "${cont_deploy}" != "yes" ]; then
                    log_info "Deployment stopped by user."
                    break
                fi
                consecutive_same_error=0
            fi
            continue
        fi
        echo -e "  ${GREEN}[ OK ]${NC}  ${WHITE}Creating backup${NC}"
        
        # Deploy (apply + save with verbose output)
        if deploy_url_category_to_host "${host}" "${cat_name}" "${urls_json}" "${site_id}" "${deploy_mode}" "${additions_json}" "${deletions_list}"; then
            deploy_results+=("${host}|${site_id}|OK|Deployed and saved")
            success_count=$((success_count + 1))
            last_error=""
            consecutive_same_error=0
        else
            deploy_results+=("${host}|${site_id}|FAIL|${DEPLOY_ERROR_MSG}")
            fail_count=$((fail_count + 1))
            
            # Check for systemic failure (same error on consecutive hosts)
            if [ "${DEPLOY_ERROR_MSG}" == "${last_error}" ]; then
                consecutive_same_error=$((consecutive_same_error + 1))
                if [ ${consecutive_same_error} -ge 3 ]; then
                    echo ""
                    log_warn "Systemic failure detected: Same error on 3 consecutive hosts"
                    read -rp "  Continue deploying to remaining hosts? (yes/no) [no]: " cont_deploy
                    if [ "${cont_deploy}" != "yes" ]; then
                        log_info "Deployment stopped by user."
                        break
                    fi
                    consecutive_same_error=0
                fi
            else
                last_error="${DEPLOY_ERROR_MSG}"
                consecutive_same_error=1
            fi
        fi
    done <<< "${validation_results}"
    
    # Display summary
    echo ""
    echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}  DEPLOY SUMMARY${NC}"
    echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    printf "  ${WHITE}%-35s %-10s %-8s %s${NC}\n" "HOST" "SITE" "STATUS" "MESSAGE"
    echo -e "  ${CYAN}──────────────────────────────────────────────────────────────${NC}"
    
    for result in "${deploy_results[@]}"; do
        local r_host r_site r_status r_message
        IFS='|' read -r r_host r_site r_status r_message <<< "${result}"
        
        local status_color="${WHITE}"
        case "${r_status}" in
            OK) status_color="${GREEN}" ;;
            FAIL) status_color="${RED}" ;;
            SKIP) status_color="${YELLOW}" ;;
        esac
        
        # Mark current device
        local site_display="${r_site}"
        if [ "${r_site}" == "CURRENT" ]; then
            site_display="(current)"
        fi
        
        printf "  ${WHITE}%-35s${NC} ${WHITE}%-10s${NC} ${status_color}%-8s${NC} ${WHITE}%s${NC}\n" \
            "${r_host:0:35}" "${site_display}" "${r_status}" "${r_message:0:30}"
    done
    
    echo -e "  ${CYAN}──────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}Total: ${GREEN}${success_count} succeeded${NC}, ${RED}${fail_count} failed${NC}, ${YELLOW}${skip_count} skipped${NC}"
    echo ""
    
    if [ ${fail_count} -eq 0 ]; then
        return 0
    fi
    return 1
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
# Check if a partition exists
# Uses session cache when available to avoid redundant API calls
partition_exists() {
    local partition="$1"
    
    # Check session cache first
    if [ -n "${PARTITION_CACHE[${partition}]+x}" ]; then
        if [ "${PARTITION_CACHE[${partition}]}" == "valid" ]; then
            return 0
        else
            return 1
        fi
    fi
    
    # Cache miss - query and cache result
    local result=1
    if partition_exists_remote "${partition}"; then
        result=0
    fi
    
    if [ ${result} -eq 0 ]; then
        PARTITION_CACHE["${partition}"]="valid"
    else
        PARTITION_CACHE["${partition}"]="invalid"
    fi
    return ${result}
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

# Run pre-flight checks
preflight_checks() {
    preflight_checks_rest_api
}
# Get list of all INTERNAL datagroups
get_internal_datagroup_list() {
    for partition in "${PARTITION_LIST[@]}"; do
        if partition_exists "${partition}"; then
            get_internal_datagroup_list_remote "${partition}"
        fi
    done | sort -t'|' -k1,1 -k2,2
}
# Get list of all datagroups
# Returns: partition|name|class lines
get_all_datagroup_list() {
    get_internal_datagroup_list
}
# Check if datagroup exists in specified partition
internal_datagroup_exists() {
    local partition="$1"
    local dg_name="$2"
    internal_datagroup_exists_remote "${partition}" "${dg_name}"
    return $?
}
# Check if datagroup exists
# Returns: "internal" or empty string
datagroup_exists() {
    local partition="$1"
    local dg_name="$2"
    
    if internal_datagroup_exists "${partition}" "${dg_name}"; then
        echo "internal"
        return 0
    fi
    echo ""
    return 0
}
# Get datagroup type (string, address, integer)
get_internal_datagroup_type() {
    local partition="$1"
    local dg_name="$2"
    get_internal_datagroup_type_remote "${partition}" "${dg_name}"
}
# Get datagroup type
get_datagroup_type() {
    local partition="$1"
    local dg_name="$2"
    get_internal_datagroup_type "${partition}" "${dg_name}"
}
# Get datagroup records as "key|value" lines
get_internal_datagroup_records() {
    local partition="$1"
    local dg_name="$2"
    get_internal_datagroup_records_remote "${partition}" "${dg_name}"
}
# Get datagroup records
get_datagroup_records() {
    local partition="$1"
    local dg_name="$2"
    get_internal_datagroup_records "${partition}" "${dg_name}"
}

# Backup a datagroup to CSV file
backup_datagroup() {
    local partition="$1"
    local dg_name="$2"
    local dg_class="${3:-internal}"
    # Include partition and class in backup filename to avoid collisions
    local safe_partition
    safe_partition=$(echo "${partition}" | sed 's/\//_/g')
    local safe_hostname
    safe_hostname=$(echo "${REMOTE_HOST}" | sed 's/[^a-zA-Z0-9_-]/_/g')
    
    # Determine backup path: fleet hosts go in site subfolder
    local backup_path
    backup_path=$(get_connected_backup_dir)
    
    local backup_file="${backup_path}/${safe_hostname}_${safe_partition}_${dg_name}_${dg_class}_${TIMESTAMP}.csv"
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
# Apply records from arrays to datagroup
# Args: partition, dg_name, dg_type, keys_array_name, values_array_name
apply_records_from_arrays() {
    local partition="$1"
    local dg_name="$2"
    local dg_type="$3"
    local keys_name=$4
    local values_name=$5
    
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
    return $?
}
# Create datagroup
create_internal_datagroup() {
    local partition="$1"
    local dg_name="$2"
    local dg_type="$3"
    create_internal_datagroup_remote "${partition}" "${dg_name}" "${dg_type}"
    return $?
}
# Save system configuration
save_config() {
    save_config_remote
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
        
        # Trim whitespace (bash builtins - no subprocess)
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        
        # Skip if still empty after trim
        [ -z "${line}" ] && continue
        
        # Parse based on format
        if [ "${format}" == "keys_only" ]; then
            # Take first column only, ignore the rest
            local key="${line%%,*}"
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            
            if [ -z "${key}" ]; then
                log_warn "Line ${line_num}: Empty key, skipping"
                continue
            fi
            
            CSV_KEYS+=("${key}")
            CSV_VALUES+=("")
        else
            # Keys and values format
            local key="${line%%,*}"
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            
            local value=""
            if [[ "${line}" == *","* ]]; then
                value="${line#*,}"
                value="${value#"${value%%[![:space:]]*}"}"
                value="${value%"${value##*[![:space:]]}"}"
            fi
            
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
    echo -e "  ${CYAN}║${NC}${WHITE}                    DGCAT-Admin v4.5                        ${NC}${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}${WHITE}               F5 BIG-IP Administration Tool                ${NC}${CYAN}║${NC}"
    echo -e "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "  ${CYAN}${NC}  ${WHITE}Connected: ${YELLOW}${REMOTE_HOSTNAME}${NC}"
    echo -e "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}   ${YELLOW}1)${NC}  ${WHITE}Create Datagroup or URL Category${NC}                     ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}   ${YELLOW}2)${NC}  ${WHITE}Create/Update Datagroup or URL Category from CSV${NC}     ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}   ${YELLOW}3)${NC}  ${WHITE}Delete Datagroup or URL Category${NC}                     ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}   ${YELLOW}4)${NC}  ${WHITE}Export Datagroup or URL Category to CSV${NC}              ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}   ${YELLOW}5)${NC}  ${WHITE}View/Edit a Datagroup or URL Category${NC}                ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}   ${YELLOW}6)${NC}  ${WHITE}Search${NC}                                               ${CYAN}║${NC}"
    echo -e "  ${CYAN}║${NC}                                                            ${CYAN}║${NC}"
    echo -e "  ${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "  ${CYAN}║${NC}   ${YELLOW}0)${NC}  ${WHITE}Exit${NC}                                                 ${CYAN}║${NC}"
    echo -e "  ${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Option 1: Create empty Datagroup or URL Category
menu_create_empty() {
    log_section "Create Datagroup or URL Category"
    
    echo ""
    echo -e "  ${WHITE}What would you like to create?${NC}"
    echo -e "    ${YELLOW}1)${NC} ${WHITE}Datagroup${NC}"
    echo -e "    ${YELLOW}2)${NC} ${WHITE}URL Category${NC}"
    echo -e "    ${YELLOW}0)${NC} ${WHITE}Cancel${NC}"
    echo ""
    local choice
    read -rp "  Select [0-2]: " choice
    
    case "${choice}" in
        1) menu_create_empty_datagroup ;;
        2) menu_create_empty_url_category ;;
        *)
            log_info "Cancelled."
            press_enter_to_continue
            ;;
    esac
}

menu_create_empty_datagroup() {
    log_section "Create Empty Datagroup"
    
    local partition
    partition=$(select_partition "Select partition")
    if [ -z "${partition}" ]; then
        log_info "Cancelled."
        press_enter_to_continue
        return
    fi
    
    echo ""
    local dg_name
    read -rp "  Enter datagroup name (or 'q' to cancel): " dg_name
    if [ -z "${dg_name}" ] || [ "${dg_name}" == "q" ]; then
        log_info "Cancelled."
        press_enter_to_continue
        return
    fi
    
    dg_name=$(strip_partition_prefix "${dg_name}")
    
    if is_protected_datagroup "${dg_name}"; then
        log_error "The name '${dg_name}' is reserved for a BIG-IP system datagroup."
        press_enter_to_continue
        return
    fi
    
    # Check if already exists
    local existing_class
    existing_class=$(datagroup_exists "${partition}" "${dg_name}")
    if [ -n "${existing_class}" ]; then
        log_error "Datagroup '${dg_name}' already exists in partition '${partition}'."
        log_info "Use the editor (option 5) to modify existing datagroups."
        press_enter_to_continue
        return
    fi
    
    # Select type
    echo ""
    echo -e "  ${WHITE}Select datagroup type:${NC}"
    echo -e "    ${YELLOW}1)${NC} ${WHITE}string  - For domains, hostnames, URLs${NC}"
    echo -e "    ${YELLOW}2)${NC} ${WHITE}address - For IP addresses, subnets (CIDR)${NC}"
    echo -e "    ${YELLOW}3)${NC} ${WHITE}integer - For port numbers, numeric values${NC}"
    echo ""
    local type_choice
    read -rp "  Select [1-3]: " type_choice
    
    local dg_type=""
    case "${type_choice}" in
        1) dg_type="string" ;;
        2) dg_type="ip" ;;
        3) dg_type="integer" ;;
        *)
            log_warn "Invalid selection."
            press_enter_to_continue
            return
            ;;
    esac
    
    local display_type="${dg_type}"
    [ "${dg_type}" == "ip" ] && display_type="address"
    
    # Confirm
    echo ""
    log_info "Ready to create:"
    log_info "  Path: /${partition}/${dg_name}"
    log_info "  Type: ${display_type}"
    echo ""
    local confirm
    read -rp "  Create this datagroup? (yes/no) [no]: " confirm
    if [ "${confirm}" != "yes" ]; then
        log_info "Cancelled."
        press_enter_to_continue
        return
    fi
    
    log_step "Creating datagroup '/${partition}/${dg_name}'..."
    if create_internal_datagroup "${partition}" "${dg_name}" "${dg_type}"; then
        log_ok "Datagroup '/${partition}/${dg_name}' created successfully (empty)."
        prompt_save_config
    else
        log_error "Failed to create datagroup. HTTP ${API_HTTP_CODE}"
    fi
    
    press_enter_to_continue
}

menu_create_empty_url_category() {
    log_section "Create Empty URL Category"
    
    if ! url_category_db_available; then
        log_error "URL database not available or accessible."
        log_info "This feature requires the URL filtering module."
        press_enter_to_continue
        return
    fi
    
    echo ""
    local cat_name
    read -rp "  Enter URL category name (or 'q' to cancel): " cat_name
    if [ -z "${cat_name}" ] || [ "${cat_name}" == "q" ]; then
        log_info "Cancelled."
        press_enter_to_continue
        return
    fi
    
    # Sanitize name
    local original_name="${cat_name}"
    cat_name=$(echo "${cat_name}" | sed 's/[^a-zA-Z0-9_-]/_/g')
    if [ "${cat_name}" != "${original_name}" ]; then
        log_info "Category name sanitized to: ${cat_name}"
    fi
    
    # Check if already exists
    if url_category_exists "${cat_name}"; then
        log_error "URL category '${cat_name}' already exists."
        log_info "Use the editor (option 5) to modify existing URL categories."
        press_enter_to_continue
        return
    fi
    
    # Select default action
    echo ""
    echo -e "  ${WHITE}Select default action for this category:${NC}"
    echo -e "    ${YELLOW}1)${NC} ${WHITE}allow   - Allow traffic (use for bypass lists)${NC}"
    echo -e "    ${YELLOW}2)${NC} ${WHITE}block   - Block traffic${NC}"
    echo -e "    ${YELLOW}3)${NC} ${WHITE}confirm - Prompt user for confirmation${NC}"
    echo ""
    local action_choice
    read -rp "  Select [1-3] [1]: " action_choice
    action_choice="${action_choice:-1}"
    
    local default_action=""
    case "${action_choice}" in
        1) default_action="allow" ;;
        2) default_action="block" ;;
        3) default_action="confirm" ;;
        *) default_action="allow" ;;
    esac
    
    # Confirm
    echo ""
    log_info "Ready to create:"
    log_info "  Category: ${cat_name}"
    log_info "  Action:   ${default_action}"
    echo ""
    local confirm
    read -rp "  Create this URL category? (yes/no) [no]: " confirm
    if [ "${confirm}" != "yes" ]; then
        log_info "Cancelled."
        press_enter_to_continue
        return
    fi
    
    log_step "Creating URL category '${cat_name}'..."
    if create_url_category_remote "${cat_name}" "${default_action}" "[]"; then
        log_ok "URL category '${cat_name}' created successfully (empty)."
        prompt_save_config
    else
        log_error "Failed to create URL category. HTTP ${API_HTTP_CODE}"
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
    
    # Check if already exists
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
        # New datagroup - ask for type
        dg_class="internal"
        
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
        temp_csv="/var/tmp/import_${TIMESTAMP}.csv"
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
        # Get first column only (bash builtins - no subprocess)
        local first_col="${line%%,*}"
        first_col="${first_col#"${first_col%%[![:space:]]*}"}"
        first_col="${first_col%"${first_col##*[![:space:]]}"}"
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
    
    # Check for CIDR alignment errors (address type only)
    if [ "${dg_type}" == "address" ]; then
        local cidr_result
        cidr_result=$(validate_cidr_alignment CSV_KEYS)
        local cidr_error_count
        cidr_error_count=$(echo "${cidr_result}" | cut -d'|' -f1)
        
        if [ "${cidr_error_count}" -gt 0 ]; then
            echo ""
            log_warn "CIDR alignment errors detected"
            log_warn "${cidr_error_count} entries have non-zero host bits that BIG-IP will reject"
            echo ""
            # Display examples
            IFS='|' read -ra cidr_parts <<< "${cidr_result}"
            for ((idx=1; idx<${#cidr_parts[@]}; idx++)); do
                echo -e "          ${WHITE}${cidr_parts[$idx]}${NC}"
            done
            if [ "${cidr_error_count}" -gt 5 ]; then
                echo -e "          ${WHITE}... and $((cidr_error_count - 5)) more${NC}"
            fi
            echo ""
            log_error "Correct these entries in your CSV and reimport."
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
        # Overwrite or new: Deduplicate CSV entries
        declare -A dedup_data
        for i in "${!CSV_KEYS[@]}"; do
            dedup_data["${CSV_KEYS[$i]}"]="${CSV_VALUES[$i]}"
        done
        
        local dedup_removed=$((${#CSV_KEYS[@]} - ${#dedup_data[@]}))
        if [ ${dedup_removed} -gt 0 ]; then
            log_info "${dedup_removed} duplicate entries removed, ${#dedup_data[@]} unique entries"
        fi
        
        for key in "${!dedup_data[@]}"; do
            FINAL_KEYS+=("${key}")
            FINAL_VALUES+=("${dedup_data[$key]}")
        done
    fi
    
    # Apply records
    log_step "Building datagroup records..."
    
    # Convert type names for API (address -> ip)
    local api_type="${dg_type}"
    if [ "${dg_type}" == "address" ]; then
        api_type="ip"
    fi
    
    # Build JSON records
    local records_json
    records_json=$(
        for ((i=0; i<${#FINAL_KEYS[@]}; i++)); do
            echo "${FINAL_KEYS[$i]}|${FINAL_VALUES[$i]:-}"
        done | build_records_json_remote "${dg_type}"
    )
    
    if [ -z "${restore_mode}" ]; then
        # Create new datagroup
        log_step "Creating datagroup '/${partition}/${dg_name}'..."
        if ! create_internal_datagroup_remote "${partition}" "${dg_name}" "${api_type}"; then
            log_error "Failed to create datagroup. HTTP ${API_HTTP_CODE}"
            [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
            press_enter_to_continue
            return
        fi
    fi
    
    # Apply records
    log_step "Applying ${#FINAL_KEYS[@]} entries to datagroup..."
    if ! apply_internal_datagroup_records_remote "${partition}" "${dg_name}" "${records_json}"; then
        log_error "Failed to apply records to datagroup. HTTP ${API_HTTP_CODE}"
        [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
        press_enter_to_continue
        return
    fi
    
    log_ok "Datagroup '/${partition}/${dg_name}' saved with ${#FINAL_KEYS[@]} entries."
    
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
    
    
    echo ""
    log_warn "You are about to delete the following datagroup:"
    log_info "  Path:    /${partition}/${dg_name}"
    log_info "  Class:   ${dg_class}"
    log_info "  Type:    ${dg_type}"
    log_info "  Records: ${record_count}"

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
    echo -ne "  ${RED}Type DELETE to confirm:${NC} "
    read -r confirm
    if [ "${confirm}" != "DELETE" ]; then
        log_info "Aborted by user."
        press_enter_to_continue
        return
    fi
    
    # Delete the datagroup
    log_step "Deleting datagroup '/${partition}/${dg_name}'..."
    if delete_internal_datagroup "${partition}" "${dg_name}"; then
        log_ok "Datagroup '/${partition}/${dg_name}' deleted successfully."
    else
        log_error "Failed to delete datagroup. HTTP ${API_HTTP_CODE}"
        press_enter_to_continue
        return
    fi
    
    prompt_save_config
    press_enter_to_continue
}

# Option 4b: Delete URL Category
menu_delete_url_category() {
    log_section "Delete URL Category"
    
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
    local backup_file="$(get_connected_backup_dir)/$(echo "${REMOTE_HOST}" | sed 's/[^a-zA-Z0-9_-]/_/g')_urlcat_${safe_name}_${TIMESTAMP}.csv"
    
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
    echo -ne "  ${RED}Type DELETE to confirm:${NC} "
    read -r confirm
    if [ "${confirm}" != "DELETE" ]; then
        log_info "Aborted by user."
        press_enter_to_continue
        return
    fi
    
    # Delete the URL category
    log_step "Deleting URL category '${selected_category}'..."
    if delete_url_category "${selected_category}"; then
        log_ok "URL category '${selected_category}' deleted successfully."
    else
        log_error "Failed to delete URL category."
        log_error "HTTP ${API_HTTP_CODE}"
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
        echo "#"
        get_datagroup_records "${partition}" "${dg_name}" "${dg_class}" | while IFS='|' read -r key value; do
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
                # Convert to domain format using bash builtins (no subprocess)
                local domain="${url#http://}"
                domain="${domain#https://}"
                domain="${domain%%/*}"
                domain="${domain#\\*}"
                domain="${domain#\*}"
                if [[ "${domain}" != .* && "${url}" == *"*"* ]]; then
                    domain=".${domain}"
                fi
                echo "${domain}"
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
# Check if URL database is available
# Uses session cache when available to avoid redundant API calls
# Returns: 0 if URL categories are accessible, 1 if not
url_category_db_available() {
    # Check session cache first
    if [ "${URL_CATEGORY_DB_CACHED}" == "yes" ]; then
        return 0
    elif [ "${URL_CATEGORY_DB_CACHED}" == "no" ]; then
        return 1
    fi
    
    # Cache miss - query and cache result
    local result=1
    if api_get "/mgmt/tm/sys/url-db/url-category"; then
        result=0
    fi
    
    if [ ${result} -eq 0 ]; then
        URL_CATEGORY_DB_CACHED="yes"
    else
        URL_CATEGORY_DB_CACHED="no"
    fi
    return ${result}
}
# Check if URL category exists
url_category_exists() {
    local cat_name="$1"
    url_category_exists_remote "${cat_name}"
    return $?
}
# Get list of custom URL categories
get_url_category_list() {
    get_url_category_list_remote
}

# Get URL entries from a URL category
get_url_category_entries() {
    local category="$1"
    get_url_category_entries_remote "${category}"
}
# Get URL count from a URL category
get_url_category_count() {
    local cat_name="$1"
    get_url_category_count_remote "${cat_name}"
}

# Format URL for SSLO datagroup (domain-only format)
# Strips protocol, converts wildcard to leading dot, removes path
# Input: https://\*.example.com/ or https://www.example.com/path
# Output: .example.com or www.example.com
format_url_for_sslo() {
    local url="$1"
    local domain
    
    # Remove protocol
    domain="${url#http://}"
    domain="${domain#https://}"
    
    # Handle wildcards: \* or * at start becomes leading dot
    domain="${domain#\\*}"
    domain="${domain#\*}"
    if [[ "${domain}" != .* && "${url}" == *"*"* ]]; then
        domain=".${domain}"
    fi
    
    # Remove path (everything after first /)
    domain="${domain%%/*}"
    
    # Remove port if present
    if [[ "${domain}" =~ ^(.+):[0-9]+$ ]]; then
        domain="${BASH_REMATCH[1]}"
    fi
    
    # Remove any trailing dots
    domain="${domain%.}"
    
    echo "${domain}"
}

# Format domain/URL for URL category (F5 URL category format)
# Input: domain like "example.com" or ".example.com" or "www.example.com"
# Output: https://example.com/ or https://*.example.com/
format_domain_for_url_category() {
    local domain="$1"
    
    # Remove any existing protocol
    domain="${domain#http://}"
    domain="${domain#https://}"
    
    # Remove path (everything after first /)
    domain="${domain%%/*}"
    
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
        temp_csv="/var/tmp/import_cat_${TIMESTAMP}.csv"
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
    
    # Deduplicate converted URLs
    declare -A url_dedup
    local -a unique_urls=()
    for url in "${converted_urls[@]}"; do
        if [ -z "${url_dedup[${url}]+x}" ]; then
            url_dedup["${url}"]=1
            unique_urls+=("${url}")
        fi
    done
    local url_dedup_removed=$(( ${#converted_urls[@]} - ${#unique_urls[@]} ))
    if [ ${url_dedup_removed} -gt 0 ]; then
        log_info "${url_dedup_removed} duplicate URLs removed, ${#unique_urls[@]} unique URLs"
    fi
    converted_urls=("${unique_urls[@]}")
    
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
    
    # Build JSON URLs array
    local urls_json
    urls_json=$(printf '%s\n' "${converted_urls[@]}" | build_urls_json_remote)
    
    # Create or update the URL category
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
        # Create new category (empty first, then populate)
        log_step "Creating URL category '${cat_name}'..."
        if ! create_url_category_remote "${cat_name}" "${default_action}" "[]"; then
            log_error "Failed to create URL category. HTTP ${API_HTTP_CODE}"
            [ -n "${temp_csv}" ] && rm -f "${temp_csv}" 2>/dev/null
            press_enter_to_continue
            return
        fi
        log_ok "URL category created"
        log_step "Populating ${#converted_urls[@]} URLs..."
        if ! modify_url_category_replace_remote "${cat_name}" "${urls_json}"; then
            log_error "Failed to populate URL category. HTTP ${API_HTTP_CODE}"
            log_warn "Category '${cat_name}' exists but is empty. Retry with overwrite."
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
    
    # Warn about bash performance with large datasets
    if [ ${#working_keys[@]} -gt 8000 ]; then
        echo ""
        log_warn "This dataset has ${#working_keys[@]} entries."
        log_warn "The bash editor will be very slow at this scale."
        log_info "Consider using the PowerShell version for large dataset editing."
        echo ""
        read -rp "  Continue to editor? (yes/no) [no]: " continue_choice
        if [ "${continue_choice}" != "yes" ]; then
            log_info "Exiting editor."
            press_enter_to_continue
            return
        fi
    fi
    
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
        echo -e "  ${CYAN}${NC}${WHITE}                           ${display_title}                             ${NC}${CYAN}${NC}"
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
        echo -e "  ${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${YELLOW}n)${NC} Next page    ${YELLOW}p)${NC} Previous page    ${YELLOW}g)${NC} Go to page"
        echo -e "  ${YELLOW}f)${NC} Filter       ${YELLOW}c)${NC} Clear filter     ${YELLOW}s)${NC} Change sort"
        echo ""
        echo -e "  ${YELLOW}a)${NC} Add entry    ${YELLOW}d)${NC} Delete entry     ${YELLOW}x)${NC} Delete by pattern"
        echo ""
        echo -e "  ${YELLOW}w)${NC} Apply changes (write to current device)"
        if fleet_available; then
            echo -e "  ${YELLOW}D)${NC} Deploy to fleet"
        fi
        echo ""
        echo -e "  ${YELLOW}q)${NC} Done (return to main menu)"
        echo ""
        read -rp "  Select option: " edit_choice
        
        case "${edit_choice}" in
            n)
                if [ ${current_page} -lt ${total_pages} ]; then
                    current_page=$((current_page + 1))
                fi
                ;;
            p)
                if [ ${current_page} -gt 1 ]; then
                    current_page=$((current_page - 1))
                fi
                ;;
            g)
                echo ""
                read -rp "  Enter page number (1-${total_pages}): " goto_page
                if [[ "${goto_page}" =~ ^[0-9]+$ ]] && [ "${goto_page}" -ge 1 ] && [ "${goto_page}" -le "${total_pages}" ]; then
                    current_page=${goto_page}
                else
                    log_warn "Invalid page number."
                    press_enter_to_continue
                fi
                ;;
            f)
                echo ""
                read -rp "  Enter search pattern (case-insensitive): " current_filter
                current_page=1
                ;;
            c)
                current_filter=""
                current_page=1
                ;;
            s)
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
            a)
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
            d)
                # Delete entry - modifies working arrays only
                echo ""
                read -rp "  Enter entry number or key to delete (or 'q' to cancel): " del_input
                
                if [ -z "${del_input}" ] || [ "${del_input}" == "q" ] || [ "${del_input}" == "Q" ]; then
                    log_info "Cancelled."
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
            x)
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
            w)
                # Apply changes - create backup and write to system
                if ! has_pending_changes; then
                    log_info "No changes to apply."
                    press_enter_to_continue
                    continue
                fi
                
                # Build lookup tables for O(n) comparison
                local -A orig_lookup=()
                local -A work_lookup=()
                local -a additions=()
                local -a deletions=()
                
                for key in "${original_keys[@]}"; do
                    orig_lookup["${key}"]=1
                done
                
                for key in "${working_keys[@]}"; do
                    work_lookup["${key}"]=1
                done
                
                # Deleted = in original but not in working
                for orig_key in "${original_keys[@]}"; do
                    if [ -z "${work_lookup[${orig_key}]+x}" ]; then
                        deletions+=("${orig_key}")
                    fi
                done
                
                # Added = in working but not in original
                for work_key in "${working_keys[@]}"; do
                    if [ -z "${orig_lookup[${work_key}]+x}" ]; then
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
                    backup_file="$(get_connected_backup_dir)/$(echo "${REMOTE_HOST}" | sed 's/[^a-zA-Z0-9_-]/_/g')_urlcat_${safe_name}_${TIMESTAMP}.csv"
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
                    log_step "Applying changes to datagroup..."
                    
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
                    # URL category - apply only the changes (not full replace)
                    log_step "Applying changes to URL category..."
                    
                    local apply_errors=0
                    
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
            D)
                # Deploy to fleet

                
                if ! fleet_available; then
                    log_warn "No Big-IPs configured. Add hosts to ${FLEET_CONFIG_FILE}"
                    press_enter_to_continue
                    continue
                fi
                
                if ! has_pending_changes; then
                    echo ""
                    log_info "No pending changes detected."
                    read -rp "  Deploy current state to fleet anyway? (yes/no) [no]: " deploy_anyway
                    if [ "${deploy_anyway}" != "yes" ]; then
                        log_info "Deploy cancelled."
                        press_enter_to_continue
                        continue
                    fi
                fi
                
                # Track whether there are actual changes to apply locally
                local deploy_has_local_changes=false
                
                # Analyze changes (may be empty if deploying current state)
                local -a deploy_additions=()
                local -a deploy_deletions=()
                
                if has_pending_changes; then
                    deploy_has_local_changes=true
                    # Show processing message for large datasets
                    echo ""
                    echo -ne "  ${WHITE}[....] Analyzing changes...${NC}\r"
                    
                    # Build lookup tables for O(n) comparison
                    local -A orig_lookup=()
                    local -A work_lookup=()
                    
                    for key in "${original_keys[@]}"; do
                        orig_lookup["${key}"]=1
                    done
                    
                    for key in "${working_keys[@]}"; do
                        work_lookup["${key}"]=1
                    done
                    
                    # Build lists of additions and deletions using lookup tables
                    
                    # Deleted = in original but not in working
                    for orig_key in "${original_keys[@]}"; do
                        if [ -z "${work_lookup[${orig_key}]+x}" ]; then
                            deploy_deletions+=("${orig_key}")
                        fi
                    done
                    
                    # Added = in working but not in original
                    for work_key in "${working_keys[@]}"; do
                        if [ -z "${orig_lookup[${work_key}]+x}" ]; then
                            deploy_additions+=("${work_key}")
                        fi
                    done
                    
                    echo -e "  ${GREEN}[ OK ]${NC} ${WHITE}Analyzing changes... done${NC}"
                    
                    # Show pending changes
                    echo ""
                    echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
                    echo -e "  ${WHITE}  PENDING CHANGES TO DEPLOY${NC}"
                    echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
                    echo ""
                    
                    if [ ${#deploy_additions[@]} -gt 0 ]; then
                        echo -e "  ${GREEN}Additions (${#deploy_additions[@]}):${NC}"
                        local show_count=0
                        for entry in "${deploy_additions[@]}"; do
                            if [ ${show_count} -lt 10 ]; then
                                echo -e "    ${GREEN}+ ${entry}${NC}"
                            fi
                            show_count=$((show_count + 1))
                        done
                        if [ ${#deploy_additions[@]} -gt 10 ]; then
                            echo -e "    ${GREEN}... and $((${#deploy_additions[@]} - 10)) more${NC}"
                        fi
                    fi
                    
                    if [ ${#deploy_deletions[@]} -gt 0 ]; then
                        if [ ${#deploy_additions[@]} -gt 0 ]; then
                            echo ""
                        fi
                        echo -e "  ${RED}Deletions (${#deploy_deletions[@]}):${NC}"
                        local show_count=0
                        for entry in "${deploy_deletions[@]}"; do
                            if [ ${show_count} -lt 10 ]; then
                                echo -e "    ${RED}- ${entry}${NC}"
                            fi
                            show_count=$((show_count + 1))
                        done
                        if [ ${#deploy_deletions[@]} -gt 10 ]; then
                            echo -e "    ${RED}... and $((${#deploy_deletions[@]} - 10)) more${NC}"
                        fi
                    fi
                    
                    echo ""
                    echo -e "  ${CYAN}──────────────────────────────────────────────────────────────${NC}"
                    echo -e "  ${WHITE}Final entry count: ${#working_keys[@]}${NC}"
                    echo ""
                    
                    read -rp "  Continue to deployment options? (yes/no) [no]: " continue_deploy
                    if [ "${continue_deploy}" != "yes" ]; then
                        log_info "Deploy cancelled."
                        press_enter_to_continue
                        continue
                    fi
                    
                    # Select deploy mode
                    echo ""
                    echo -e "  ${WHITE}Select deployment mode:${NC}"
                    echo -e "    ${YELLOW}1)${NC} ${WHITE}Full Replace - Overwrite target with exact state from current device${NC}"
                    echo -e "    ${YELLOW}2)${NC} ${WHITE}Merge        - Apply only additions/deletions, preserve target-specific entries${NC}"
                    echo -e "    ${YELLOW}0)${NC} ${WHITE}Cancel${NC}"
                    echo ""
                    read -rp "  Select [0-2]: " deploy_mode_choice
                    
                    local deploy_mode="replace"
                    case "${deploy_mode_choice}" in
                        1) deploy_mode="replace" ;;
                        2) deploy_mode="merge" ;;
                        0|"")
                            log_info "Deploy cancelled."
                            press_enter_to_continue
                            continue
                            ;;
                        *)
                            log_warn "Invalid selection."
                            press_enter_to_continue
                            continue
                            ;;
                    esac
                else
                    # No pending changes - deploy current state as full replace
                    local deploy_mode="replace"
                    log_info "Deploying current state (${#working_keys[@]} entries) as full replace."
                fi
                
                # Select deploy scope
                local deploy_targets
                if [ "${edit_type}" == "datagroup" ]; then
                    deploy_targets=$(select_deploy_scope "datagroup" "/${partition}/${dg_name}")
                else
                    deploy_targets=$(select_deploy_scope "urlcat" "${cat_name}")
                fi
                
                if [ -z "${deploy_targets}" ]; then
                    log_info "Deploy cancelled."
                    press_enter_to_continue
                    continue
                fi
                
                local target_count
                target_count=$(echo "${deploy_targets}" | grep -c . || echo "0")
                
                # Show deployment summary
                echo ""
                echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
                echo -e "  ${WHITE}  DEPLOY PREVIEW${NC}"
                echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
                echo ""
                if [ "${edit_type}" == "datagroup" ]; then
                    echo -e "  ${WHITE}Object:  /${partition}/${dg_name} (${dg_type})${NC}"
                else
                    echo -e "  ${WHITE}Object:  ${cat_name}${NC}"
                fi
                echo -e "  ${WHITE}Changes: ${GREEN}+${#deploy_additions[@]}${NC} / ${RED}-${#deploy_deletions[@]}${NC}"
                if [ "${deploy_mode}" == "merge" ]; then
                    echo -e "  ${WHITE}Mode:    ${YELLOW}Merge${NC} ${WHITE}(additions/deletions only, preserves target-specific entries)${NC}"
                else
                    echo -e "  ${WHITE}Mode:    Full Replace${NC} ${WHITE}(exact parity with current device)${NC}"
                fi
                echo ""
                echo -e "  ${WHITE}Deployment order:${NC}"
                local target_num=1
                if [ "${deploy_has_local_changes}" == "true" ]; then
                    echo -e "    ${WHITE}${target_num}. ${REMOTE_HOST} (current device)${NC}"
                    target_num=$((target_num + 1))
                fi
                while IFS= read -r target_host; do
                    [ -z "${target_host}" ] && continue
                    local target_site
                    target_site=$(get_host_site "${target_host}")
                    echo -e "    ${WHITE}${target_num}. ${target_host} (${target_site})${NC}"
                    target_num=$((target_num + 1))
                done <<< "${deploy_targets}"
                echo ""
                
                local total_targets=${target_count}
                if [ "${deploy_has_local_changes}" == "true" ]; then
                    total_targets=$((target_count + 1))
                fi
                echo -e "  ${WHITE}Total: ${total_targets} device(s)${NC}"
                echo ""
                
                # Require explicit confirmation
                if [ "${deploy_has_local_changes}" == "true" ]; then
                    echo -e "  ${RED}WARNING: This will push pending changes to all listed Big-IPs.${NC}"
                else
                    echo -e "  ${RED}WARNING: This will push current state to all listed Big-IPs.${NC}"
                fi
                echo ""
                read -rp "  Type DEPLOY to confirm: " confirm_deploy
                
                if [ "${confirm_deploy}" != "DEPLOY" ]; then
                    log_info "Deploy cancelled."
                    press_enter_to_continue
                    continue
                fi
                clear
                # =====================================================================
                # STEP 1: Pre-deploy validation on fleet
                # =====================================================================
                echo ""
                echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
                echo -e "  ${WHITE}  STEP 1: PRE-DEPLOY VALIDATION${NC}"
                echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
                
                # Run pre-deploy validation on fleet BEFORE making any changes
                local validation_results
                if [ "${edit_type}" == "datagroup" ]; then
                    validation_results=$(run_predeploy_validation_datagroup "${partition}" "${dg_name}" "${deploy_targets}") || true
                else
                    validation_results=$(run_predeploy_validation_urlcat "${cat_name}" "${deploy_targets}") || true
                fi
                
                # Count ready fleet hosts
                local ready_count
                ready_count=$(echo "${validation_results}" | grep -c '|OK|' || echo "0")
                
                if [ "${ready_count}" -eq 0 ]; then
                    log_warn "No fleet hosts passed validation. No changes have been made."
                    press_enter_to_continue
                    continue
                fi
                
                # User decision point - no changes have been made anywhere yet
                # Only prompt if some hosts failed - user already typed DEPLOY
                if [ "${ready_count}" -lt "${target_count}" ]; then
                    echo ""
                    local deploy_prompt=""
                    if [ "${deploy_has_local_changes}" == "true" ]; then
                        deploy_prompt="  Proceed with deployment to ${ready_count} fleet host(s) + current device? (yes/no) [no]: "
                    else
                        deploy_prompt="  Proceed with deployment to ${ready_count} fleet host(s)? (yes/no) [no]: "
                    fi
                    read -rp "${deploy_prompt}" proceed_deploy
                    if [ "${proceed_deploy}" != "yes" ]; then
                        log_info "Deploy cancelled. No changes have been made."
                        press_enter_to_continue
                        continue
                    fi
                fi
                
                # =====================================================================
                # STEP 2: Apply to current device (only if pending changes)
                # =====================================================================
                local current_device_status="OK"
                local current_device_message="No changes needed"
                
                if [ "${deploy_has_local_changes}" == "true" ]; then
                echo ""
                echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
                echo -e "  ${WHITE}  STEP 2: APPLYING TO CURRENT DEVICE${NC}"
                echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
                echo ""
                echo -e "  ${WHITE}Deploying to ${REMOTE_HOST}...${NC}"
                
                # Create backup of current device
                local current_backup=""
                if [ "${edit_type}" == "datagroup" ]; then
                    current_backup=$(backup_datagroup "${partition}" "${dg_name}" "${dg_class}")
                else
                    local safe_name
                    safe_name=$(echo "${cat_name}" | sed 's/[^a-zA-Z0-9_-]/_/g')
                    current_backup="$(get_connected_backup_dir)/$(echo "${REMOTE_HOST}" | sed 's/[^a-zA-Z0-9_-]/_/g')_urlcat_${safe_name}_${TIMESTAMP}.csv"
                    {
                        echo "# URL Category Backup: ${cat_name}"
                        echo "# Host: ${REMOTE_HOST}"
                        echo "# Created: $(date)"
                        echo "#"
                        for orig_url in "${original_keys[@]}"; do
                            echo "${orig_url}"
                        done
                    } > "${current_backup}" 2>/dev/null
                fi
                
                if [ -n "${current_backup}" ] && [ -f "${current_backup}" ]; then
                    echo -e "  ${GREEN}[ OK ]${NC}  ${WHITE}Creating backup${NC}"
                else
                    echo -e "  ${RED}[FAIL]${NC}  ${WHITE}Creating backup${NC}"
                    read -rp "  Continue without backup? (yes/no) [no]: " cont
                    if [ "${cont}" != "yes" ]; then
                        log_info "Deploy cancelled."
                        press_enter_to_continue
                        continue
                    fi
                fi
                
                # Apply to current device
                local current_device_success=false
                if [ "${edit_type}" == "datagroup" ]; then
                    local current_records_json
                    current_records_json=$(
                        for ((i=0; i<${#working_keys[@]}; i++)); do
                            echo "${working_keys[$i]}|${working_values[$i]:-}"
                        done | build_records_json_remote "${dg_type}"
                    )
                    
                    if apply_internal_datagroup_records_remote "${partition}" "${dg_name}" "${current_records_json}"; then
                        echo -e "  ${GREEN}[ OK ]${NC}  ${WHITE}Applying changes${NC}"
                        if save_config_remote; then
                            echo -e "  ${GREEN}[ OK ]${NC}  ${WHITE}Saving configuration${NC}"
                            current_device_success=true
                        else
                            echo -e "  ${RED}[FAIL]${NC}  ${WHITE}Saving configuration${NC}"
                        fi
                    else
                        echo -e "  ${RED}[FAIL]${NC}  ${WHITE}Applying changes${NC}"
                    fi
                else
                    local current_urls_json
                    current_urls_json=$(printf '%s\n' "${working_keys[@]}" | build_urls_json_remote)
                    
                    if modify_url_category_replace_remote "${cat_name}" "${current_urls_json}"; then
                        echo -e "  ${GREEN}[ OK ]${NC}  ${WHITE}Applying changes${NC}"
                        if save_config_remote; then
                            echo -e "  ${GREEN}[ OK ]${NC}  ${WHITE}Saving configuration${NC}"
                            current_device_success=true
                        else
                            echo -e "  ${RED}[FAIL]${NC}  ${WHITE}Saving configuration${NC}"
                        fi
                    else
                        echo -e "  ${RED}[FAIL]${NC}  ${WHITE}Applying changes${NC}"
                    fi
                fi
                
                if [ "${current_device_success}" != "true" ]; then
                    echo ""
                    log_error "Failed to apply changes to current device."
                    read -rp "  Continue deploying to fleet anyway? (yes/no) [no]: " cont_fleet
                    if [ "${cont_fleet}" != "yes" ]; then
                        log_info "Deploy aborted."
                        press_enter_to_continue
                        continue
                    fi
                fi
                
                # Track current device status for summary
                current_device_status="FAIL"
                current_device_message="Failed to apply"
                if [ "${current_device_success}" == "true" ]; then
                    current_device_status="OK"
                    current_device_message="Deployed and saved"
                    original_keys=("${working_keys[@]}")
                    original_values=("${working_values[@]}")
                fi
                fi
                
                # =====================================================================
                # Deploy to fleet
                # =====================================================================
                local fleet_step_num=3
                if [ "${deploy_has_local_changes}" != "true" ]; then
                    fleet_step_num=2
                fi
                echo ""
                echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
                echo -e "  ${WHITE}  STEP ${fleet_step_num}: DEPLOYING TO FLEET${NC}"
                echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
                
                # Build merge data for deploy functions
                local deploy_additions_json="[]"
                local deploy_deletions_list=""
                
                if [ "${deploy_mode}" == "merge" ]; then
                    
                    if [ "${edit_type}" == "datagroup" ]; then
                        # Build additions as JSON records
                        if [ ${#deploy_additions[@]} -gt 0 ]; then
                            deploy_additions_json=$(
                                for add_key in "${deploy_additions[@]}"; do
                                    # Find value for this key in working arrays
                                    for ((i=0; i<${#working_keys[@]}; i++)); do
                                        if [ "${working_keys[$i]}" == "${add_key}" ]; then
                                            echo "${add_key}|${working_values[$i]:-}"
                                            break
                                        fi
                                    done
                                done | build_records_json_remote "${dg_type}"
                            )
                        fi
                    else
                        # Build additions as URL JSON
                        if [ ${#deploy_additions[@]} -gt 0 ]; then
                            deploy_additions_json=$(printf '%s\n' "${deploy_additions[@]}" | build_urls_json_remote)
                        fi
                    fi
                    
                    # Build deletions as newline-separated list
                    if [ ${#deploy_deletions[@]} -gt 0 ]; then
                        deploy_deletions_list=$(printf '%s\n' "${deploy_deletions[@]}")
                    fi
                    
                fi
                
                # Execute deploy to fleet hosts
                if [ "${edit_type}" == "datagroup" ]; then
                    local deploy_records_json
                    deploy_records_json=$(
                        for ((i=0; i<${#working_keys[@]}; i++)); do
                            echo "${working_keys[$i]}|${working_values[$i]:-}"
                        done | build_records_json_remote "${dg_type}"
                    )
                    
                    execute_deploy_datagroup "${partition}" "${dg_name}" "${dg_type}" "${deploy_records_json}" "${validation_results}" "${REMOTE_HOST}" "${current_device_status}" "${current_device_message}" "${deploy_mode}" "${deploy_additions_json}" "${deploy_deletions_list}" || true
                else
                    local deploy_urls_json
                    deploy_urls_json=$(printf '%s\n' "${working_keys[@]}" | build_urls_json_remote)
                    
                    execute_deploy_urlcat "${cat_name}" "${deploy_urls_json}" "${validation_results}" "${REMOTE_HOST}" "${current_device_status}" "${current_device_message}" "${deploy_mode}" "${deploy_additions_json}" "${deploy_deletions_list}" || true
                fi
                
                press_enter_to_continue
                ;;
            q)
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
# =============================================================================
# OPTION 6: FLEET LOOKING GLASS
# =============================================================================
menu_fleet_looking_glass() {
    log_section "DGCat-Admin Search"
    
    # Require fleet config
    if [ ${#FLEET_HOSTS[@]} -eq 0 ]; then
        log_error "No fleet configuration loaded. Configure fleet.conf to use this feature."
        press_enter_to_continue
        return
    fi
    
    echo ""
    echo -e "  ${WHITE}What would you like to inspect?${NC}"
    echo -e "    ${YELLOW}1)${NC} ${WHITE}Datagroup${NC}"
    echo -e "    ${YELLOW}2)${NC} ${WHITE}URL Category${NC}"
    echo -e "    ${YELLOW}0)${NC} ${WHITE}Cancel${NC}"
    echo ""
    local type_choice
    read -rp "  Select [0-2]: " type_choice
    
    local object_type=""
    local object_name=""
    local partition=""
    
    case "${type_choice}" in
        1)
            object_type="datagroup"
            # Select partition
            if [ ${#PARTITION_LIST[@]} -gt 1 ]; then
                partition=$(select_partition)
                [ -z "${partition}" ] && return
            else
                partition="${PARTITION_LIST[0]}"
            fi
            echo ""
            read -rp "  Enter datagroup name (or 'q' to cancel): " object_name
            if [ -z "${object_name}" ] || [ "${object_name}" == "q" ]; then
                return
            fi
            object_name=$(strip_partition_prefix "${object_name}")
            ;;
        2)
            object_type="urlcat"
            echo ""
            read -rp "  Enter URL category name (or 'q' to cancel): " object_name
            if [ -z "${object_name}" ] || [ "${object_name}" == "q" ]; then
                return
            fi
            ;;
        *)
            return
            ;;
    esac
    
    # Select search scope
    echo ""
    echo -e "  ${WHITE}Select search scope:${NC}"
    echo ""
    echo -e "    ${YELLOW}1)${NC} ${WHITE}All fleet hosts${NC}"
    echo -e "    ${YELLOW}2)${NC} ${WHITE}Select by site${NC}"
    echo -e "    ${YELLOW}3)${NC} ${WHITE}Select by host${NC}"
    echo -e "    ${YELLOW}0)${NC} ${WHITE}Cancel${NC}"
    echo ""
    local scope_type
    read -rp "  Select [0-3]: " scope_type
    
    local -a target_hosts=()
    local -a target_sites_list=()
    
    case "${scope_type}" in
        1)
            # All fleet hosts
            target_hosts=("${FLEET_HOSTS[@]}")
            target_sites_list=("${FLEET_SITES[@]}")
            ;;
        2)
            # Select by site
            echo ""
            for ((s=0; s<${#FLEET_UNIQUE_SITES[@]}; s++)); do
                local site="${FLEET_UNIQUE_SITES[$s]}"
                local site_count
                site_count=$(count_site_hosts "${site}")
                local site_host_word="hosts"
                [ ${site_count} -eq 1 ] && site_host_word="host"
                echo -e "    ${YELLOW}$((s + 1)))${NC} ${WHITE}${site}${NC} (${site_count} ${site_host_word})"
            done
            echo ""
            local site_input
            read -rp "  Enter site numbers (comma-separate for multiple): " site_input
            
            if [ -z "${site_input}" ]; then
                return
            fi
            
            IFS=',' read -ra site_selections <<< "${site_input}"
            for sel in "${site_selections[@]}"; do
                sel=$(echo "${sel}" | tr -d ' ')
                if [[ "${sel}" =~ ^[0-9]+$ ]] && [ "${sel}" -ge 1 ] && [ "${sel}" -le ${#FLEET_UNIQUE_SITES[@]} ]; then
                    local selected_site="${FLEET_UNIQUE_SITES[$((sel - 1))]}"
                    for i in "${!FLEET_HOSTS[@]}"; do
                        if [ "${FLEET_SITES[$i]}" == "${selected_site}" ]; then
                            target_hosts+=("${FLEET_HOSTS[$i]}")
                            target_sites_list+=("${FLEET_SITES[$i]}")
                        fi
                    done
                fi
            done
            ;;
        3)
            # Select by host
            echo ""
            for ((h=0; h<${#FLEET_HOSTS[@]}; h++)); do
                echo -e "    ${YELLOW}$((h + 1)))${NC} ${WHITE}${FLEET_HOSTS[$h]} (${FLEET_SITES[$h]})${NC}"
            done
            echo ""
            local host_input
            read -rp "  Enter host numbers (comma-separate for multiple): " host_input
            
            if [ -z "${host_input}" ]; then
                return
            fi
            
            IFS=',' read -ra host_selections <<< "${host_input}"
            for sel in "${host_selections[@]}"; do
                sel=$(echo "${sel}" | tr -d ' ')
                if [[ "${sel}" =~ ^[0-9]+$ ]] && [ "${sel}" -ge 1 ] && [ "${sel}" -le ${#FLEET_HOSTS[@]} ]; then
                    local idx=$((sel - 1))
                    target_hosts+=("${FLEET_HOSTS[$idx]}")
                    target_sites_list+=("${FLEET_SITES[$idx]}")
                fi
            done
            ;;
        *)
            return
            ;;
    esac
    
    if [ ${#target_hosts[@]} -eq 0 ]; then
        log_warn "No valid scope selected."
        press_enter_to_continue
        return
    fi
    
    # Pull from fleet
    clear
    echo ""
    echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}  FLEET QUERY: ${object_name}${NC}"
    echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
    
    local orig_host="${REMOTE_HOST}"
    
    declare -A entry_hosts      # entry -> "host1|host2|..."
    declare -a pulled_hosts     # hosts that were pulled
    declare -A host_counts      # host -> entry count
    declare -A host_sites       # host -> site name
    
    for ((h=0; h<${#target_hosts[@]}; h++)); do
        local host="${target_hosts[$h]}"
        local site="${target_sites_list[$h]}"
        host_sites["${host}"]="${site}"
        
        echo -ne "  ${WHITE}[....] ${host} (${site})${NC}\r"
        
        REMOTE_HOST="${host}"
        
        # Test connectivity
        if ! api_get "/mgmt/tm/sys/version" >/dev/null 2>&1; then
            echo -e "\033[2K\r  ${RED}[FAIL]${NC} ${WHITE}${host} (${site}) - Connection failed${NC}"
            continue
        fi
        
        # Pull entries
        local entries=""
        local count=0
        
        if [ "${object_type}" == "datagroup" ]; then
            if ! api_get "/mgmt/tm/ltm/data-group/internal/~${partition}~${object_name}" >/dev/null 2>&1; then
                echo -e "\033[2K\r  ${RED}[FAIL]${NC} ${WHITE}${host} (${site}) - Object not found${NC}"
                continue
            fi
            while IFS='|' read -r key value; do
                [ -z "${key}" ] && continue
                local entry="${key}"
                if [ -n "${entry_hosts[${entry}]+x}" ]; then
                    entry_hosts["${entry}"]="${entry_hosts[${entry}]}|${host}"
                else
                    entry_hosts["${entry}"]="${host}"
                fi
                count=$((count + 1))
            done < <(get_internal_datagroup_records_remote "${partition}" "${object_name}")
        else
            if ! api_get "/mgmt/tm/sys/url-db/url-category/~Common~${object_name}" >/dev/null 2>&1; then
                echo -e "\033[2K\r  ${RED}[FAIL]${NC} ${WHITE}${host} (${site}) - Object not found${NC}"
                continue
            fi
            while IFS= read -r url; do
                [ -z "${url}" ] && continue
                if [ -n "${entry_hosts[${url}]+x}" ]; then
                    entry_hosts["${url}"]="${entry_hosts[${url}]}|${host}"
                else
                    entry_hosts["${url}"]="${host}"
                fi
                count=$((count + 1))
            done < <(get_url_category_entries_remote "${object_name}")
        fi
        
        pulled_hosts+=("${host}")
        host_counts["${host}"]=${count}
        echo -e "\033[2K\r  ${GREEN}[ OK ]${NC} ${WHITE}${host} (${site}) - ${count} entries${NC}"
    done
    
    REMOTE_HOST="${orig_host}"
    
    echo -e "  ${CYAN}──────────────────────────────────────────────────────────────${NC}"
    
    local total_pulled=${#pulled_hosts[@]}
    
    if [ ${total_pulled} -eq 0 ]; then
        log_error "No hosts returned data."
        press_enter_to_continue
        return
    fi
    
    # Build display info
    local object_display="${object_name}"
    if [ "${object_type}" == "datagroup" ]; then
        object_display="/${partition}/${object_name} (Datagroup)"
    else
        object_display="${object_name} (URL Category)"
    fi
    
    # Viewer loop
    while true; do
        clear
        echo ""
        echo -e "  ${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${CYAN}${NC}${WHITE}                         DGCat-Admin Search                            ${NC}${CYAN}${NC}"
        echo -e "  ${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
        echo -e "  ${WHITE}Object: ${YELLOW}${object_display}${NC}"
        echo -e "  ${WHITE}Hosts:  ${GREEN}${total_pulled}${NC} ${WHITE}of ${#target_hosts[@]} pulled | ${#entry_hosts[@]} unique entries across fleet${NC}"
        echo ""
        # Host counts
        for fleet_host in "${pulled_hosts[@]}"; do
            local site="${host_sites[${fleet_host}]}"
            echo -e "    ${GREEN}*${NC} ${WHITE}${fleet_host} (${site}): ${host_counts[${fleet_host}]} entries${NC}"
        done
        echo ""
        echo -e "  ${CYAN}──────────────────────────────────────────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${YELLOW}s)${NC} Search      ${YELLOW}d)${NC} Diff      ${YELLOW}q)${NC} Quit"
        echo ""
        local input
        read -rp "  Select option: " input
        
        [ -z "${input}" ] && continue
        
        if [ "${input}" == "q" ] || [ "${input}" == "Q" ]; then
            break
        fi
        
        if [ "${input}" == "d" ] || [ "${input}" == "D" ]; then
            # Diff
            clear
            echo ""
            echo -e "  ${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "  ${CYAN}${NC}${WHITE}                         DGCat-Admin Search                            ${NC}${CYAN}${NC}"
            echo -e "  ${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
            echo -e "  ${WHITE}Object: ${YELLOW}${object_display}${NC}"
            echo -e "  ${WHITE}Hosts:  ${GREEN}${total_pulled}${NC} ${WHITE}of ${#target_hosts[@]} pulled | ${#entry_hosts[@]} unique entries across fleet${NC}"
            echo ""
            echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
            local diff_label=""
            if [ "${object_type}" == "datagroup" ]; then
                diff_label="Datagroup: /${partition}/${object_name}"
            else
                diff_label="URL Category: ${object_name}"
            fi
            echo -e "  ${WHITE}  ${diff_label}${NC}"
            echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
            echo ""
            
            local drift_count=0
            local consistent_count=0
            
            for entry in "${!entry_hosts[@]}"; do
                local hosts_with="${entry_hosts[${entry}]}"
                local host_count=$(( $(echo "${hosts_with}" | tr -cd '|' | wc -c) + 1 ))
                
                if [ ${host_count} -lt ${total_pulled} ]; then
                    drift_count=$((drift_count + 1))
                    echo -e "  ${YELLOW}${entry}${NC}"
                    echo -e "  ${CYAN}──────────────────────────────────────────────────────────────${NC}"
                    for fleet_host in "${pulled_hosts[@]}"; do
                        local site="${host_sites[${fleet_host}]}"
                        if [[ "|${hosts_with}|" == *"|${fleet_host}|"* ]] || [[ "${hosts_with}" == "${fleet_host}" ]]; then
                            echo -e "    ${WHITE}${fleet_host} (${site})${NC}"
                        else
                            echo -e "    ${WHITE}${fleet_host} (${site})${NC} - ${RED}missing${NC}"
                        fi
                    done
                    echo ""
                else
                    consistent_count=$((consistent_count + 1))
                fi
            done
            
            if [ ${drift_count} -eq 0 ]; then
                echo -e "  ${GREEN}All ${#entry_hosts[@]} entries consistent across all ${total_pulled} hosts.${NC}"
            else
                echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
                echo -e "  ${WHITE}${drift_count} inconsistent | ${consistent_count} consistent across all hosts${NC}"
            fi
            echo ""
            press_enter_to_continue
            continue
        fi
        
        if [ "${input}" == "s" ] || [ "${input}" == "S" ]; then
            echo ""
            local search_term
            read -rp "  Enter search pattern: " search_term
            [ -z "${search_term}" ] && continue
            
            clear
            echo ""
            echo -e "  ${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "  ${CYAN}${NC}${WHITE}                         DGCat-Admin Search                            ${NC}${CYAN}${NC}"
            echo -e "  ${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
            echo -e "  ${WHITE}Object: ${YELLOW}${object_display}${NC}"
            echo -e "  ${WHITE}Hosts:  ${GREEN}${total_pulled}${NC} ${WHITE}of ${#target_hosts[@]} pulled | ${#entry_hosts[@]} unique entries across fleet${NC}"
            echo ""
            echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
            echo -e "  ${WHITE}  SEARCH: ${search_term}${NC}"
            echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
            echo ""
            
            local search_lower="${search_term,,}"
            local match_count=0
            
            # Collect matching entries and classify by consistency
            local -a consistent_matches=()
            local -a inconsistent_matches=()
            
            for entry in "${!entry_hosts[@]}"; do
                local entry_lower="${entry,,}"
                if [[ "${entry_lower}" != *"${search_lower}"* ]]; then
                    continue
                fi
                
                match_count=$((match_count + 1))
                local hosts_with="${entry_hosts[${entry}]}"
                local host_count=$(( $(echo "${hosts_with}" | tr -cd '|' | wc -c) + 1 ))
                
                if [ ${host_count} -ge ${total_pulled} ]; then
                    consistent_matches+=("${entry}")
                else
                    inconsistent_matches+=("${entry}")
                fi
            done
            
            if [ ${match_count} -eq 0 ]; then
                echo -e "  ${WHITE}No matches for '${search_term}'${NC}"
            else
                # Display consistent matches (on all hosts) - listed once
                if [ ${#consistent_matches[@]} -gt 0 ]; then
                    echo -e "  ${GREEN}Matches on all ${total_pulled} hosts (${#consistent_matches[@]}):${NC}"
                    echo -e "  ${CYAN}──────────────────────────────────────────────────────────────${NC}"
                    for m in "${consistent_matches[@]}"; do
                        echo -e "          ${YELLOW}${m}${NC}"
                    done
                    echo ""
                fi
                
                # Display inconsistent matches (some hosts) - per-host detail
                if [ ${#inconsistent_matches[@]} -gt 0 ]; then
                    echo -e "  ${YELLOW}Partial matches (${#inconsistent_matches[@]}):${NC}"
                    echo -e "  ${CYAN}──────────────────────────────────────────────────────────────${NC}"
                    for entry in "${inconsistent_matches[@]}"; do
                        echo -e "  ${YELLOW}${entry}${NC}"
                        local hosts_with="${entry_hosts[${entry}]}"
                        for fleet_host in "${pulled_hosts[@]}"; do
                            local site="${host_sites[${fleet_host}]}"
                            if [[ "|${hosts_with}|" == *"|${fleet_host}|"* ]] || [[ "${hosts_with}" == "${fleet_host}" ]]; then
                                echo -e "    ${WHITE}${fleet_host} (${site})${NC}"
                            else
                                echo -e "    ${WHITE}${fleet_host} (${site})${NC} - ${RED}missing${NC}"
                            fi
                        done
                        echo ""
                    done
                fi
                
                echo -e "  ${CYAN}══════════════════════════════════════════════════════════════${NC}"
                echo -e "  ${WHITE}${match_count} unique matches | ${GREEN}${#consistent_matches[@]} on all hosts${NC}, ${YELLOW}${#inconsistent_matches[@]} inconsistent${NC}"
            fi
            echo ""
            
            press_enter_to_continue
            continue
        fi
        
        log_warn "Invalid selection."
        press_enter_to_continue
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
    # Session setup
    while true; do
        # Reset session variables
        REMOTE_HOST=""
        REMOTE_USER=""
        REMOTE_PASS=""
        REMOTE_HOSTNAME=""
        FLEET_SITES=()
        FLEET_HOSTS=()
        FLEET_UNIQUE_SITES=()
        PARTITION_CACHE=()
        URL_CATEGORY_DB_CACHED=""
        
        # Clear screen
        clear
        
        # Welcome banner
        echo ""
        echo -e "  ${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${CYAN}║${NC}${WHITE}                    DGCAT-Admin v4.5                        ${NC}${CYAN}║${NC}"
        echo -e "  ${CYAN}║${NC}${WHITE}               F5 BIG-IP Administration Tool                ${NC}${CYAN}║${NC}"
        echo -e "  ${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "    ${YELLOW}1)${NC}  ${WHITE}Connect to BIG-IP${NC}"
        echo -e "    ${YELLOW}0)${NC}  ${WHITE}Exit${NC}"
        echo ""
        
        local start_choice
        read -rp "  Select [0-1]: " start_choice
        
        if [ "${start_choice}" == "0" ]; then
            echo ""
            echo -e "  ${WHITE}Exiting.${NC}"
            echo -e "  ${CYAN}Latest version: https://github.com/hauptem/F5-SSL-Orchestrator-Tools${NC}"
            echo ""
            exit 0
        fi
        
        # Try to create backup/log directory
        mkdir -p "${BACKUP_DIR}" 2>/dev/null
        
        # Update timestamp for new session
        TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
        LOGFILE="${BACKUP_DIR}/dgcat-admin-${TIMESTAMP}.log"
        
        # Initialize log (if logging enabled and directory is writable)
        if [ "${LOGGING_ENABLED}" -eq 1 ]; then
            if touch "${LOGFILE}" 2>/dev/null; then
                echo "DGCat-Admin - F5 BIG-IP Administration Tool" > "${LOGFILE}"
                echo "Started: $(date)" >> "${LOGFILE}"
                echo "Mode: REST API" >> "${LOGFILE}"
                echo "Target: (pending connection)" >> "${LOGFILE}"
            fi
        fi
        
        # Run pre-flight checks (mode-specific)
        preflight_checks
        
        # Update log with target host if applicable
        if [ "${LOGGING_ENABLED}" -eq 1 ] && [ -n "${REMOTE_HOST}" ]; then
            echo "Target: ${REMOTE_HOST}" >> "${LOGFILE}" 2>/dev/null
        fi
        
        # Brief pause after preflight checks
        sleep 2
        
        # Main menu loop
        local return_to_session_start=false
        while true; do
            show_main_menu
            
            read -rp "  Select option [0-6]: " choice
            
            case "${choice}" in
                1) menu_create_empty ;;
                2) menu_create_from_csv ;;
                3) menu_delete_datagroup ;;
                4) menu_export_to_csv ;;
                5) menu_edit_datagroup_or_category ;;
                6) menu_fleet_looking_glass ;;
                0)
                    log_section "Session End"
                    log_info "Session ended: $(date)"
                    if [ "${LOGGING_ENABLED}" -eq 1 ]; then
                        log_info "Log file: ${LOGFILE}"
                    fi
                    echo ""
                    return_to_session_start=true
                    break
                    ;;
                *)
                    log_warn "Invalid selection."
                    press_enter_to_continue
                    ;;
            esac
        done
        
        # If we broke out of menu loop, continue to new session
        if [ "${return_to_session_start}" == "true" ]; then
            continue
        fi
    done
}

# Global arrays for CSV parsing
declare -a CSV_KEYS
declare -a CSV_VALUES

main "$@"
