#!/bin/bash
# =============================================================================
# SSL Orchestrator - Clean Slate
# =============================================================================
# Version:  1.0
# Author: Eric Haupt
# Based on: Kevin Stewart's original "sslo nuclear delete" script v7.0 from 
#           https://github.com/f5devcentral/sslo-script-tools/tree/main/sslo-nuke-delete
#
# Requirements:  SSL Orchestrator 12.x or higher / TMOS 17.x or higher
#
# PURPOSE:
#   Removes all SSL Orchestrator (SSLO) configuration objects, clears REST 
#   storage, and reinstalls the SSLO RPM.
#
# WARNING:
#   THIS SCRIPT IS DESTRUCTIVE. It will permanently delete ALL SSLO configuration 
#   on this device. This action cannot be undone.
#   Do NOT run this on a device with active production SSLO traffic.
#
# USAGE:
#   chmod +x sslo-clean-slate.sh
#   ./sslo-clean-slate.sh
#
# OUTPUT:
#   A log file is written to /var/log/sslo-clean-<timestamp>.log
#
# https://github.com/hauptem/F5-SSL-Orchestrator-Tools
# =============================================================================

set -euo pipefail

# =============================================================================
# Globals
# =============================================================================
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOGFILE="/var/log/sslo-clean-${TIMESTAMP}.log"
RPM_BACKUP_DIR="/var/tmp"
RPM_DOWNLOAD_DIR="/var/config/rest/downloads"
ERRORS=0

# =============================================================================
# Logging and output helpers
# =============================================================================
log() {
    echo "$1" | tee -a "${LOGFILE}"
}

log_section() {
    log ""
    log "============================================================"
    log "  $1"
    log "============================================================"
}

log_info() {
    log "  [INFO]  $1"
}

log_ok() {
    log "  [ OK ]  $1"
}

log_warn() {
    log "  [WARN]  $1"
}

log_error() {
    log "  [FAIL]  $1"
    ERRORS=$((ERRORS + 1))
}

log_step() {
    log "  [....] $1"
}

# =============================================================================
# Pre-flight: Confirm running as root on a BIG-IP
# =============================================================================
preflight_checks() {
    log_section "Pre-Flight Checks"

    if [ "$(id -u)" != "0" ]; then
        log_error "This script must be run as root."
        exit 1
    fi
    log_ok "Running as root"

    if ! command -v tmsh &>/dev/null; then
        log_error "tmsh not found. This script must be run on a BIG-IP."
        exit 1
    fi
    log_ok "tmsh found"

    if ! command -v restcurl &>/dev/null; then
        log_error "restcurl not found. This script must be run on a BIG-IP."
        exit 1
    fi
    log_ok "restcurl found"

    if ! command -v jq &>/dev/null; then
        log_error "jq not found. Please install jq before running this script."
        exit 1
    fi
    log_ok "jq found"

    local tmos_version
    tmos_version=$(tmsh show sys version | grep "^\s*Version" | awk '{print $2}' | head -1)
    log_ok "TMOS Version: ${tmos_version}"

    local sslo_rpm
    sslo_rpm=$(restcurl shared/iapp/installed-packages 2>/dev/null | grep "packageName" | grep -iE 'sslo|ssl.orchestrator' | awk -F'"' '{print $4}' || true)
    if [ -z "${sslo_rpm}" ]; then
        log_warn "No SSLO RPM detected in installed packages. Proceeding anyway."
    else
        log_ok "Detected installed SSLO RPM: ${sslo_rpm}"
    fi
}

# =============================================================================
# Prompt for credentials
# =============================================================================
get_credentials() {
    log_section "Credentials"
    log_info "Enter BIG-IP admin credentials."
    echo ""

    read -rp "  Username [admin]: " input_user
    ADMIN_USER="${input_user:-admin}"

    read -rsp "  Password: " input_pass
    echo ""
    ADMIN_PASS="${input_pass}"
    USER_PASS="${ADMIN_USER}:${ADMIN_PASS}"

    # Validate credentials
    log_step "Validating credentials..."
    local http_code
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        -u "${USER_PASS}" \
        "https://localhost/mgmt/tm/sys/version")

    if [ "${http_code}" != "200" ]; then
        log_error "Credential validation failed (HTTP ${http_code}). Check username/password and try again."
        exit 1
    fi
    log_ok "Credentials validated successfully"
}

# =============================================================================
# Confirmation prompt
# =============================================================================
confirm_execution() {
    log_section "Confirmation Required"
    log_warn "This script will PERMANENTLY DELETE all SSL Orchestrator"
    log_warn "configuration on this BIG-IP. This cannot be undone."
    log ""
    log_info "Device:   $(hostname)"
    log_info "Log file: ${LOGFILE}"
    log ""

    echo ""
    echo "  !! WARNING: ALL SSLO CONFIGURATION WILL BE DESTROYED !!"
    echo ""
    read -rp "  Type CONFIRM to proceed, or anything else to abort: " confirm
    echo ""

    if [ "${confirm}" != "CONFIRM" ]; then
        log_info "Aborted by user. No changes were made."
        exit 0
    fi
    log_ok "Confirmed by user. Proceeding with clean slate."
}

# =============================================================================
# Step 1: Back up the RPM before anything is deleted
# =============================================================================
backup_rpm() {
    log_section "Step 1 of 7: Backing Up Installed SSLO RPM"

    INSTALLED_RPM=$(restcurl shared/iapp/installed-packages 2>/dev/null \
        | grep "packageName" | grep -iE 'sslo|ssl.orchestrator' | awk -F'"' '{print $4}' || true)

    if [ -z "${INSTALLED_RPM}" ]; then
        log_warn "Could not detect an installed SSLO RPM. RPM backup skipped."
        log_warn "You will need to manually supply the RPM after this script completes."
        RPM_BACKED_UP=false
        return
    fi

    local rpm_src="${RPM_DOWNLOAD_DIR}/${INSTALLED_RPM}.rpm"

    if [ ! -f "${rpm_src}" ]; then
        log_warn "RPM file not found at ${rpm_src}"
        log_warn "Searching for RPM elsewhere on the filesystem..."
        local found_rpm
        found_rpm=$(find / -name "${INSTALLED_RPM}.rpm" 2>/dev/null | head -1 || true)
        if [ -n "${found_rpm}" ]; then
            rpm_src="${found_rpm}"
            log_ok "Found RPM at: ${rpm_src}"
        else
            log_warn "RPM file not found anywhere on the filesystem."
            log_warn "You will need to manually supply the RPM after this script completes."
            RPM_BACKED_UP=false
            return
        fi
    fi

    cp "${rpm_src}" "${RPM_BACKUP_DIR}/${INSTALLED_RPM}.rpm"
    if [ -f "${RPM_BACKUP_DIR}/${INSTALLED_RPM}.rpm" ]; then
        log_ok "RPM backed up to: ${RPM_BACKUP_DIR}/${INSTALLED_RPM}.rpm"
        RPM_BACKED_UP=true
    else
        log_error "RPM backup failed. Aborting to prevent unrecoverable state."
        exit 1
    fi
}

# =============================================================================
# Step 2: Delete iApp blocks and packages
# =============================================================================
delete_iapp_blocks_and_packages() {
    log_section "Step 2 of 7: Deleting iApp Blocks and Installed Packages"

    local blocks
    blocks=$(restcurl shared/iapp/blocks 2>/dev/null \
        | grep "      \"id\":" | grep -v "       \"id\":" | awk -F'"' '{print $4}' || true)

    if [ -z "${blocks}" ]; then
        log_info "No iApp blocks found."
    else
        local count=0
        for b in ${blocks}; do
            log_step "Deleting iApp block: ${b}"
            if restcurl -X DELETE "shared/iapp/blocks/${b}" > /dev/null 2>&1; then
                log_ok "Deleted block: ${b}"
            else
                log_warn "Could not delete block: ${b} (may already be gone)"
            fi
            count=$((count + 1))
        done
        log_ok "Processed ${count} iApp block(s)"
    fi

    local packages
    packages=$(restcurl shared/iapp/installed-packages 2>/dev/null \
        | grep "      \"id\":" | grep -v "       \"id\":" | awk -F'"' '{print $4}' || true)

    if [ -z "${packages}" ]; then
        log_info "No installed packages found."
    else
        local count=0
        for p in ${packages}; do
            log_step "Deleting installed package: ${p}"
            if restcurl -X DELETE "shared/iapp/installed-packages/${p}" > /dev/null 2>&1; then
                log_ok "Deleted package: ${p}"
            else
                log_warn "Could not delete package: ${p} (may already be gone)"
            fi
            count=$((count + 1))
        done
        log_ok "Processed ${count} installed package(s)"
    fi
}

# =============================================================================
# Step 3: Delete SSLO application services
# =============================================================================
delete_app_services() {
    local pass_label="$1"
    log_section "${pass_label}: Deleting SSLO Application Services"

    local appsvcs
    appsvcs=$(restcurl -u "${USER_PASS}" mgmt/tm/sys/application/service 2>/dev/null \
        | jq -r '.items[].fullPath' 2>/dev/null \
        | sed 's/\/Common\///g' \
        | grep "^sslo" || true)

    if [ -z "${appsvcs}" ]; then
        log_info "No SSLO application services found."
        return
    fi

    local count=0
    while IFS= read -r a; do
        [ -z "${a}" ] && continue
        log_step "Processing application service: ${a}"
        if tmsh modify sys application service "${a}" strict-updates disabled > /dev/null 2>&1; then
            log_ok "Disabled strict-updates on: ${a}"
        else
            log_warn "Could not disable strict-updates on: ${a}"
        fi
        if tmsh delete sys application service "${a}" > /dev/null 2>&1; then
            log_ok "Deleted application service: ${a}"
        else
            log_warn "Could not delete application service: ${a} (may already be gone)"
        fi
        count=$((count + 1))
    done <<< "${appsvcs}"
    log_ok "Processed ${count} application service(s)"
}

# =============================================================================
# Step 4: Unbind SSLO blocks
# =============================================================================
unbind_sslo_blocks() {
    local pass_label="$1"
    log_section "${pass_label}: Unbinding SSLO Blocks"

    local blocks
    blocks=$(curl -sk -X GET \
        'https://localhost/mgmt/shared/iapp/blocks?$select=id,state,name&$filter=state%20eq%20%27*%27%20and%20state%20ne%20%27TEMPLATE%27' \
        -u "${USER_PASS}" 2>/dev/null \
        | jq -r '.items[] | [.name, .id] | join(":")' 2>/dev/null \
        | grep -E '^sslo|f5-ssl-orchestrator' \
        | awk -F':' '{print $2}' || true)

    if [ -z "${blocks}" ]; then
        log_info "No SSLO blocks found to unbind."
        return
    fi

    local count=0
    for block in ${blocks}; do
        log_step "Unbinding block: ${block}"
        curl -sk -X PATCH \
            "https://localhost/mgmt/shared/iapp/blocks/${block}" \
            -d '{"state":"UNBINDING"}' \
            -u "${USER_PASS}" > /dev/null 2>&1
        log_info "  Waiting 15 seconds for unbind to complete..."
        sleep 15
        if curl -sk -X DELETE \
            "https://localhost/mgmt/shared/iapp/blocks/${block}" \
            -u "${USER_PASS}" > /dev/null 2>&1; then
            log_ok "Block unbound and deleted: ${block}"
        else
            log_warn "Could not delete block after unbind: ${block}"
        fi
        count=$((count + 1))
    done
    log_ok "Processed ${count} SSLO block(s)"
}

# =============================================================================
# Step 5: Delete SSLO tmsh objects
# =============================================================================
delete_sslo_objects() {
    log_section "Step 5 of 7: Deleting SSLO tmsh Objects"

    local sslo_objects
    sslo_objects=$(tmsh list 2>/dev/null \
        | grep -v "^\s" \
        | grep sslo \
        | sed -e 's/{//g;s/}//g' \
        | grep -v "apm profile access /Common/ssloDefault_accessProfile" \
        | grep -v "apm log-setting /Common/default-sslo-log-setting" \
        | grep -v "net dns-resolver /Common/ssloGS_global.app/ssloGS-net-resolver" \
        | grep -v "sys application service /Common/ssloGS_global.app/ssloGS_global" \
        | grep -v "sys provision sslo" || true)

    # Delete explicit named objects first
    local explicit_objects=(
        "apm profile access /Common/ssloDefault_accessProfile"
        "net dns-resolver /Common/ssloGS_global.app/ssloGS-net-resolver"
        "sys application service /Common/ssloGS_global.app/ssloGS_global"
        "apm policy access-policy /Common/ssloDefault_accessPolicy"
    )
    for obj in "${explicit_objects[@]}"; do
        log_step "Deleting: tmsh delete ${obj}"
        if tmsh delete ${obj} > /dev/null 2>&1; then
            log_ok "Deleted: ${obj}"
        else
            log_info "Skipped (not present or already deleted): ${obj}"
        fi
    done

    if [ -z "${sslo_objects}" ]; then
        log_info "No additional SSLO tmsh objects found."
        return
    fi

    local count=0
    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        log_step "Deleting: tmsh delete ${line}"
        if eval "tmsh delete ${line}" > /dev/null 2>&1; then
            log_ok "Deleted: ${line}"
        else
            log_warn "Could not delete (may already be gone): ${line}"
        fi
        count=$((count + 1))
    done <<< "${sslo_objects}"
    log_ok "Processed ${count} additional SSLO tmsh object(s)"
}

# =============================================================================
# Step 6: Clear REST storage
# =============================================================================
clear_rest_storage() {
    log_section "Step 6 of 7: Clearing REST Storage"
    log_warn "This will wipe /var/config/rest/downloads and all REST-persisted data."
    log_info "RPM has already been backed up to ${RPM_BACKUP_DIR} — safe to proceed."

    if clear-rest-storage -l > /dev/null 2>&1; then
        log_ok "REST storage cleared successfully"
    else
        log_error "clear-rest-storage returned an error. Check logs."
    fi

    log_info "Waiting 10 seconds for REST framework to stabilise..."
    sleep 10
    log_ok "REST framework stabilisation wait complete"
}

# =============================================================================
# Step 7: Post-run verification
# =============================================================================
post_run_verification() {
    log_section "Step 7 of 7: Post-Run Verification"

    local remaining_appsvcs
    remaining_appsvcs=$(restcurl -u "${USER_PASS}" mgmt/tm/sys/application/service 2>/dev/null \
        | jq -r '.items[].fullPath' 2>/dev/null | grep "^/Common/sslo" || true)
    if [ -z "${remaining_appsvcs}" ]; then
        log_ok "No SSLO application services remain"
    else
        log_warn "Remaining SSLO application services detected:"
        while IFS= read -r svc; do
            log_warn "  ${svc}"
        done <<< "${remaining_appsvcs}"
    fi

    local remaining_blocks
    remaining_blocks=$(curl -sk -X GET \
        'https://localhost/mgmt/shared/iapp/blocks?$select=id,state,name&$filter=state%20eq%20%27*%27%20and%20state%20ne%20%27TEMPLATE%27' \
        -u "${USER_PASS}" 2>/dev/null \
        | jq -r '.items[].name' 2>/dev/null \
        | grep -E '^sslo|f5-ssl-orchestrator' || true)
    if [ -z "${remaining_blocks}" ]; then
        log_ok "No SSLO iApp blocks remain"
    else
        log_warn "Remaining SSLO blocks detected:"
        while IFS= read -r blk; do
            log_warn "  ${blk}"
        done <<< "${remaining_blocks}"
    fi

    local reinstalled_rpm
    reinstalled_rpm=$(restcurl shared/iapp/installed-packages 2>/dev/null \
        | grep "packageName" | grep -iE 'sslo|ssl.orchestrator' | awk -F'"' '{print $4}' || true)
    if [ -z "${reinstalled_rpm}" ] && [ "${RPM_BACKED_UP}" == "true" ]; then
        log_ok "SSLO RPM is not installed (expected). Backed up to: ${RPM_BACKUP_DIR}/${INSTALLED_RPM}.rpm"
        log_info "Manual reinstall required via GUI: iApps > Package Management LX > Import"
    elif [ -z "${reinstalled_rpm}" ]; then
        log_warn "SSLO RPM is not installed and no backup was made. Manual RPM sourcing required."
    else
        log_info "SSLO RPM is still installed: ${reinstalled_rpm}"
    fi
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
    log_section "Run Summary"
    log_info "Completed at: $(date)"
    log_info "Log file:     ${LOGFILE}"
    if [ "${ERRORS}" -eq 0 ]; then
        log_ok "Script completed with no errors."
        log_ok "SSLO configuration has been removed."
    else
        log_warn "Script completed with ${ERRORS} error(s)."
        log_warn "Review the log file for details: ${LOGFILE}"
        log_warn "You may need to run this script again or remediate manually."
    fi
    log ""
    if [ "${RPM_BACKED_UP}" == "true" ]; then
        log_info "RPM backed up to: ${RPM_BACKUP_DIR}/${INSTALLED_RPM}.rpm"
        log_info "To reinstall, upload the RPM via the GUI:"
        log_info "  iApps > Package Management LX > Import"
    else
        log_warn "No RPM was backed up. You will need to obtain the SSLO RPM"
        log_warn "and install it manually via the GUI before reconfiguring."
    fi
    log ""
}

# =============================================================================
# Main
# =============================================================================
main() {
    # Initialise log
    echo "SSL Orchestrator Clean Slate - v1.0" | tee "${LOGFILE}"
    echo "Started: $(date)" | tee -a "${LOGFILE}"

    RPM_BACKED_UP=false
    INSTALLED_RPM=""

    preflight_checks
    get_credentials
    confirm_execution

    backup_rpm
    delete_iapp_blocks_and_packages
    delete_app_services  "Step 3 of 7 (Pass 1)"
    unbind_sslo_blocks   "Step 4 of 7 (Pass 1)"
    delete_sslo_objects
    delete_app_services  "Step 3 of 7 (Pass 2)"
    unbind_sslo_blocks   "Step 4 of 7 (Pass 2)"
    clear_rest_storage
    post_run_verification
    print_summary
}

main "$@"
