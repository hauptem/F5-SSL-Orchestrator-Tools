#!/bin/bash
# SSL Orchestrator Advanced Blocking Page
# Version 1.0
#
# Based entirely on Kevin Smith's SSLO Service Extensions "Advanced Blocking Pages"
# https://github.com/f5devcentral/sslo-service-extensions/tree/main/advanced-blocking-pages
#
# Kevin's original uses curl calls to Github to pull installer artifact files.
# This method is not acceptable for closed network customers so the curl dependancy was
# removed and the individual artifact files were rolled into a single installer script for
# ease of use and extension portability. Only the blocking-page-html iFile source is kept external,
# since it is intended to be customized per customer organization.
#
# This script also offers a full uninstaller for all created components.

## ===========================================================================
## Color codes and tagged status helpers
## ===========================================================================
C_RESET="\033[0m"
C_WHITE="\033[1;37m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[0;33m"
C_RED="\033[0;31m"
C_BLUE="\033[0;34m"
C_BOLD="\033[1m"

info() { echo -e "${C_WHITE}[INFO]${C_RESET} ${C_WHITE}$*${C_RESET}"; }
ok()   { echo -e "${C_GREEN}[ OK ]${C_RESET}   ${C_WHITE}$*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} ${C_WHITE}$*${C_RESET}"; }
fail() { echo -e "${C_RED}[FAIL]${C_RESET} ${C_WHITE}$*${C_RESET}" >&2; }

abort() {
    fail "$*"
    echo
    fail "Aborted. Temp files left for review."
    exit 1
}


## ===========================================================================
## Progress bar globals and rendering helpers
## ===========================================================================
INSTALL_STEP=0
INSTALL_TOTAL=0

render_banner() {
    echo -e "${C_BOLD}${C_BLUE}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}║${C_RESET}  ${C_BOLD}${C_WHITE}F5 SSLO Service Extensions Installer:${C_RESET}                       ${C_BOLD}${C_BLUE}║${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}║${C_RESET}  ${C_BOLD}${C_WHITE}Advanced Blocking Pages v1.0${C_RESET}                                ${C_BOLD}${C_BLUE}║${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    echo
}

render_progress() {
    local step="${INSTALL_STEP}"
    local total="${INSTALL_TOTAL}"
    local width=64
    local filled=0
    (( total > 0 )) && filled=$(( step * width / total ))
    local empty=$(( width - filled ))
    local bar="" i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty;  i++ )); do bar+="░"; done
    printf "${C_GREEN}%s${C_RESET}\n" "${bar}"
    echo
}

## step_screen TITLE
step_screen() {
    local title="$1"
    clear
    render_banner
    render_progress
    echo -e "${C_BOLD}${C_WHITE}${title}${C_RESET}"
    echo
}

## step_done - advance the progress bar after a step completes
step_done() {
    INSTALL_STEP=$(( INSTALL_STEP + 1 ))
}

## sleep_with_countdown SECONDS MESSAGE
sleep_with_countdown() {
    local seconds="$1"
    local message="$2"
    local i
    for (( i=seconds; i>0; i-- )); do
        printf "\r${C_WHITE}%s ${C_BOLD}%d${C_RESET}${C_WHITE}s remaining...${C_RESET}    " "${message}" "${i}"
        sleep 1
    done
    printf "\r${C_WHITE}%s done.${C_RESET}                              \n" "${message}"
}


## ===========================================================================
## Preflight checks
## ===========================================================================
clear
render_banner
info "Running preflight checks"

if [[ ! -f /VERSION ]] || ! grep -qi "BIG-IP" /VERSION 2>/dev/null; then
    abort "This installer must be run on a BIG-IP system."
fi
ok "BIG-IP system detected"

if [[ ! -f "blocking-page-html" ]]; then
    abort "Required file 'blocking-page-html' not found in current directory."
fi
ok "blocking-page-html present"


## ===========================================================================
## Credentials
## ===========================================================================
echo
read -p "$(echo -e "${C_WHITE}Enter admin username: ${C_RESET}")" biguser
read -sp "$(echo -e "${C_WHITE}Enter admin password: ${C_RESET}")" bigpass
echo
if [[ -z "${biguser}" || -z "${bigpass}" ]]; then
    abort "Username and password are required."
fi
BIGUSER="${biguser}:${bigpass}"


## ===========================================================================
## REST helpers - perform curl calls, capture HTTP status code, report
## tagged result. rest_post and rest_patch return 0 on 2xx, 1 otherwise.
## rest_get returns 0 if the object exists (2xx), 1 if 404, 2 on other error.
## rest_delete returns 0 on 2xx, 1 otherwise.
## ===========================================================================
rest_post() {
    local description="$1"
    local uri="$2"
    local body="$3"
    local response http_code

    response=$(curl -sk -u "${BIGUSER}" \
        -w "\n__HTTP_CODE__:%{http_code}" \
        -H "Content-Type: application/json" \
        -d "${body}" \
        "https://localhost${uri}")
    http_code=$(echo "${response}" | grep "__HTTP_CODE__:" | cut -d: -f2)

    if [[ "${http_code}" =~ ^2 ]]; then
        ok "${description} (HTTP ${http_code})"
        return 0
    else
        fail "${description} (HTTP ${http_code})"
        return 1
    fi
}

rest_patch() {
    local description="$1"
    local uri="$2"
    local body="$3"
    local response http_code

    response=$(curl -sk -u "${BIGUSER}" \
        -w "\n__HTTP_CODE__:%{http_code}" \
        -H "Content-Type: application/json" \
        -X PATCH \
        -d "${body}" \
        "https://localhost${uri}")
    http_code=$(echo "${response}" | grep "__HTTP_CODE__:" | cut -d: -f2)

    if [[ "${http_code}" =~ ^2 ]]; then
        ok "${description} (HTTP ${http_code})"
        return 0
    else
        warn "${description} (HTTP ${http_code})"
        return 1
    fi
}

## rest_get URI - silent existence check, sets REST_RESPONSE_BODY and
## REST_HTTP_CODE globals for caller inspection.
rest_get() {
    local uri="$1"
    local response
    response=$(curl -sk -u "${BIGUSER}" \
        -w "\n__HTTP_CODE__:%{http_code}" \
        "https://localhost${uri}")
    REST_HTTP_CODE=$(echo "${response}" | grep "__HTTP_CODE__:" | cut -d: -f2)
    REST_RESPONSE_BODY=$(echo "${response}" | sed '/__HTTP_CODE__:/d')
    if [[ "${REST_HTTP_CODE}" =~ ^2 ]]; then
        return 0
    elif [[ "${REST_HTTP_CODE}" == "404" ]]; then
        return 1
    else
        return 2
    fi
}

## rest_delete DESCRIPTION URI - delete an object, report tagged result.
rest_delete() {
    local description="$1"
    local uri="$2"
    local response http_code

    response=$(curl -sk -u "${BIGUSER}" \
        -w "\n__HTTP_CODE__:%{http_code}" \
        -X DELETE \
        "https://localhost${uri}")
    http_code=$(echo "${response}" | grep "__HTTP_CODE__:" | cut -d: -f2)

    if [[ "${http_code}" =~ ^2 ]]; then
        ok "${description} (HTTP ${http_code})"
        return 0
    else
        fail "${description} (HTTP ${http_code})"
        return 1
    fi
}


## ===========================================================================
## Top-level menu 
## ===========================================================================
clear
render_banner
echo -e "${C_WHITE}What would you like to do?${C_RESET}"
echo
echo -e "  ${C_WHITE}1) Install${C_RESET}"
echo -e "  ${C_WHITE}2) Uninstall${C_RESET}"
echo
read -p "$(echo -e "${C_WHITE}Select (1 or 2): ${C_RESET}")" menu_choice
case "${menu_choice}" in
    1) MODE=1 ;;
    2) MODE=2 ;;
    *) abort "Invalid selection. Aborting." ;;
esac
echo


## ===========================================================================
## Confirmation gate 
## ===========================================================================
if [[ "${MODE}" == "1" ]]; then
    INSTALL_TOTAL=9
    echo -e "${C_WHITE}Objects to be created:${C_RESET}"
    echo -e "${C_WHITE}  - LTM iRule:        blocking-page-rule${C_RESET}"
    echo -e "${C_WHITE}  - LTM iRule:        sslo-tls-verify-rule${C_RESET}"
    echo -e "${C_WHITE}  - System iFile:     blocking-page-html${C_RESET}"
    echo -e "${C_WHITE}  - LTM iFile:        blocking-page-html${C_RESET}"
    echo -e "${C_WHITE}  - iAppsLX block: ssloS_Blocking_Page${C_RESET}"
    echo
    echo -e "${C_WHITE}To proceed, type CONFIRM (case sensitive).${C_RESET}"
    read -p "$(echo -e "${C_WHITE}Confirm: ${C_RESET}")" confirmation
    if [[ "${confirmation}" != "CONFIRM" ]]; then
        abort "Confirmation not received. No changes were made to the BIG-IP."
    fi
else
    INSTALL_TOTAL=8
    echo -e "${C_WHITE}Objects to be removed:${C_RESET}"
    echo -e "${C_WHITE}  - iAppsLX block: ssloS_Blocking_Page${C_RESET}"
    echo -e "${C_WHITE}  - LTM iFile:        blocking-page-html${C_RESET}"
    echo -e "${C_WHITE}  - System iFile:     blocking-page-html${C_RESET}"
    echo -e "${C_WHITE}  - LTM iRule:        sslo-tls-verify-rule${C_RESET}"
    echo -e "${C_WHITE}  - LTM iRule:        blocking-page-rule${C_RESET}"
    echo
    echo -e "${C_WHITE}To proceed, type CONFIRM (case sensitive). Anything else aborts.${C_RESET}"
    read -p "$(echo -e "${C_WHITE}Confirm: ${C_RESET}")" confirmation
    if [[ "${confirmation}" != "CONFIRM" ]]; then
        abort "Confirmation not received. No changes were made to the BIG-IP."
    fi
fi
echo


## ===========================================================================
## Dispatch
## ===========================================================================


if [[ "${MODE}" == "2" ]]; then
    ## ----- Uninstall path -----
    ##

    REMOVED=()
    SKIPPED=()
    FAILED=()

    ## -----------------------------------------------------------------------
    ## Phase 1: Discovery
    ## -----------------------------------------------------------------------
    step_screen "Discover existing Blocking_Page components"
    info "Scanning the BIG-IP for Blocking_Page objects"
    info "This may take a moment"
    echo

    HAS_BLOCK=0
    BLOCK_ID=""
    BLOCK_STATE=""
    HAS_APP_SERVICE=0
    HAS_APP_FOLDER=0
    HAS_T4_VIRTUAL=0
    HAS_BP_RULE=0
    HAS_TLS_RULE=0
    HAS_LTM_IFILE=0
    HAS_SYS_IFILE=0

    block_json=$(curl -sk -u "${BIGUSER}" \
        "https://localhost/mgmt/shared/iapp/blocks" \
        | jq -r '.items[]? | select(.name=="ssloS_Blocking_Page") | "\(.id) \(.state)"' 2>/dev/null)
    if [[ -n "${block_json}" ]]; then
        HAS_BLOCK=1
        BLOCK_ID="${block_json%% *}"
        BLOCK_STATE="${block_json##* }"
    fi

    if rest_get "/mgmt/tm/sys/application/service/~Common~ssloS_Blocking_Page.app~ssloS_Blocking_Page"; then
        HAS_APP_SERVICE=1
    fi
    if rest_get "/mgmt/tm/sys/folder/~Common~ssloS_Blocking_Page.app"; then
        HAS_APP_FOLDER=1
    fi
    if rest_get "/mgmt/tm/ltm/virtual/~Common~ssloS_Blocking_Page.app~ssloS_Blocking_Page-t-4"; then
        HAS_T4_VIRTUAL=1
    fi
    if rest_get "/mgmt/tm/ltm/rule/blocking-page-rule"; then
        HAS_BP_RULE=1
    fi
    if rest_get "/mgmt/tm/ltm/rule/sslo-tls-verify-rule"; then
        HAS_TLS_RULE=1
    fi
    if rest_get "/mgmt/tm/ltm/ifile/blocking-page-html"; then
        HAS_LTM_IFILE=1
    fi
    if rest_get "/mgmt/tm/sys/file/ifile/blocking-page-html"; then
        HAS_SYS_IFILE=1
    fi

    echo
    info "Discovery results:"
    if (( HAS_BLOCK )); then
        echo -e "  ${C_WHITE}* iAppsLX block instance:      found (${BLOCK_STATE})${C_RESET}"
    else
        echo -e "  ${C_WHITE}* iAppsLX block instance:      not present${C_RESET}"
    fi
    if (( HAS_APP_SERVICE )); then
        echo -e "  ${C_WHITE}* iAppsLX application service: found${C_RESET}"
    else
        echo -e "  ${C_WHITE}* iAppsLX application service: not present${C_RESET}"
    fi
    if (( HAS_APP_FOLDER )); then
        echo -e "  ${C_WHITE}* .app folder:                  found${C_RESET}"
    else
        echo -e "  ${C_WHITE}* .app folder:                  not present${C_RESET}"
    fi
    if (( HAS_T4_VIRTUAL )); then
        echo -e "  ${C_WHITE}* ssloS_Blocking_Page-t-4:      found${C_RESET}"
    else
        echo -e "  ${C_WHITE}* ssloS_Blocking_Page-t-4:      not present${C_RESET}"
    fi
    if (( HAS_BP_RULE )); then
        echo -e "  ${C_WHITE}* blocking-page-rule iRule:     found${C_RESET}"
    else
        echo -e "  ${C_WHITE}* blocking-page-rule iRule:     not present${C_RESET}"
    fi
    if (( HAS_TLS_RULE )); then
        echo -e "  ${C_WHITE}* sslo-tls-verify-rule iRule:   found${C_RESET}"
    else
        echo -e "  ${C_WHITE}* sslo-tls-verify-rule iRule:   not present${C_RESET}"
    fi
    if (( HAS_LTM_IFILE )); then
        echo -e "  ${C_WHITE}* blocking-page-html LTM iFile: found${C_RESET}"
    else
        echo -e "  ${C_WHITE}* blocking-page-html LTM iFile: not present${C_RESET}"
    fi
    if (( HAS_SYS_IFILE )); then
        echo -e "  ${C_WHITE}* blocking-page-html sys iFile: found${C_RESET}"
    else
        echo -e "  ${C_WHITE}* blocking-page-html sys iFile: not present${C_RESET}"
    fi
    echo

    if (( HAS_BLOCK == 0 && HAS_APP_SERVICE == 0 && HAS_APP_FOLDER == 0 \
        && HAS_T4_VIRTUAL == 0 && HAS_BP_RULE == 0 && HAS_TLS_RULE == 0 \
        && HAS_LTM_IFILE == 0 && HAS_SYS_IFILE == 0 )); then
        ok "Nothing to remove. The BIG-IP is already clean."
        echo
        exit 0
    fi
    step_done
    sleep 2

    ## -----------------------------------------------------------------------
    ## Phase 2: Remove the iAppsLX block instance (if present)
    ## -----------------------------------------------------------------------
    step_screen "Remove the iAppsLX block instance"
    if (( HAS_BLOCK == 0 )); then
        info "No iAppsLX block instance to remove"
        SKIPPED+=("iAppsLX block instance: ssloS_Blocking_Page")
    else
        info "Found iAppsLX block instance in state: ${BLOCK_STATE}"
        case "${BLOCK_STATE}" in
            BOUND)
                info "Triggering iAppsLX unbind workflow"
                if rest_patch "block state set to UNBINDING" \
                    "/mgmt/shared/iapp/blocks/${BLOCK_ID}" \
                    '{"state":"UNBINDING"}'; then
                    sleep_with_countdown 15 "Waiting for unbind to complete:"
                fi
                ;;
            UNBINDING)
                info "Block already UNBINDING - waiting for completion"
                sleep_with_countdown 15 "Waiting for unbind to complete:"
                ;;
            UNBOUND|ERROR)
                info "Phase 3 will remove the iAppsLX application service"
                ;;
            *)
                warn "Unexpected state '${BLOCK_STATE}' - trying unbind"
                rest_patch "block state set to UNBINDING" \
                    "/mgmt/shared/iapp/blocks/${BLOCK_ID}" \
                    '{"state":"UNBINDING"}' || true
                sleep_with_countdown 15 "Waiting for unbind to complete:"
                ;;
        esac

        if rest_delete "iAppsLX block instance deleted" \
            "/mgmt/shared/iapp/blocks/${BLOCK_ID}"; then
            REMOVED+=("iAppsLX block instance: ssloS_Blocking_Page")
        else
            FAILED+=("iAppsLX block instance: ssloS_Blocking_Page (delete failed)")
        fi
    fi
    step_done
    sleep 1

    ## -----------------------------------------------------------------------
    ## Phase 3: Delete the iAppsLX application service for the .app folder
    ## -----------------------------------------------------------------------
    ## This is the authoritative iAppsLX framework cleanup. Deleting the
    ## application service tears down the entire .app folder including the
    ## connector profile, the -t-4 virtual, and any other objects the
    ## framework created inside it. 
    step_screen "Delete the iAppsLX application service"

    if rest_get "/mgmt/tm/sys/application/service/~Common~ssloS_Blocking_Page.app~ssloS_Blocking_Page"; then
        if rest_delete "iAppsLX application service deleted" \
            "/mgmt/tm/sys/application/service/~Common~ssloS_Blocking_Page.app~ssloS_Blocking_Page"; then
            REMOVED+=("iAppsLX application service: ssloS_Blocking_Page")
            sleep_with_countdown 10 "Waiting for .app folder teardown:"
        else
            FAILED+=("iAppsLX application service: ssloS_Blocking_Page (delete failed)")
        fi
    else
        info "iAppsLX application service not present"
        if (( HAS_APP_FOLDER || HAS_T4_VIRTUAL )); then
            warn ".app folder or virtual present, no app service"
            warn "Orphaned state - manual cleanup may be required"
        fi
    fi
    step_done
    sleep 1

    ## -----------------------------------------------------------------------
    ## Phase 4: Delete blocking-page-rule iRule
    ## -----------------------------------------------------------------------
    step_screen "Remove iRule blocking-page-rule"
    if rest_get "/mgmt/tm/ltm/rule/blocking-page-rule"; then
        if rest_delete "iRule blocking-page-rule deleted" \
            "/mgmt/tm/ltm/rule/blocking-page-rule"; then
            REMOVED+=("LTM iRule: blocking-page-rule")
        else
            err_body="${REST_RESPONSE_BODY}"
            fail "Server response: ${err_body}"
            FAILED+=("LTM iRule: blocking-page-rule")
        fi
    else
        info "iRule blocking-page-rule not found"
        if (( HAS_BP_RULE )); then
            REMOVED+=("LTM iRule: blocking-page-rule")
        else
            SKIPPED+=("LTM iRule: blocking-page-rule")
        fi
    fi
    step_done
    sleep 1

    ## -----------------------------------------------------------------------
    ## Phase 5: Delete LTM iFile blocking-page-html
    ## -----------------------------------------------------------------------
    step_screen "Remove LTM iFile blocking-page-html"
    if rest_get "/mgmt/tm/ltm/ifile/blocking-page-html"; then
        if rest_delete "LTM iFile blocking-page-html deleted" \
            "/mgmt/tm/ltm/ifile/blocking-page-html"; then
            REMOVED+=("LTM iFile: blocking-page-html")
        else
            FAILED+=("LTM iFile: blocking-page-html")
        fi
    else
        info "LTM iFile blocking-page-html not found"
        if (( HAS_LTM_IFILE )); then
            REMOVED+=("LTM iFile: blocking-page-html")
        else
            SKIPPED+=("LTM iFile: blocking-page-html")
        fi
    fi
    step_done
    sleep 1

    ## -----------------------------------------------------------------------
    ## Phase 6: Delete system iFile blocking-page-html
    ## -----------------------------------------------------------------------
    step_screen "Remove system iFile blocking-page-html"
    if rest_get "/mgmt/tm/sys/file/ifile/blocking-page-html"; then
        if rest_delete "system iFile blocking-page-html deleted" \
            "/mgmt/tm/sys/file/ifile/blocking-page-html"; then
            REMOVED+=("System iFile: blocking-page-html")
        else
            FAILED+=("System iFile: blocking-page-html")
        fi
    else
        info "system iFile blocking-page-html not found"
        if (( HAS_SYS_IFILE )); then
            REMOVED+=("System iFile: blocking-page-html")
        else
            SKIPPED+=("System iFile: blocking-page-html")
        fi
    fi
    step_done
    sleep 1

    ## -----------------------------------------------------------------------
    ## Phase 7: Delete sslo-tls-verify-rule iRule 
    ## -----------------------------------------------------------------------
    step_screen "Remove iRule sslo-tls-verify-rule"
    if rest_get "/mgmt/tm/ltm/rule/sslo-tls-verify-rule"; then
        if rest_delete "iRule sslo-tls-verify-rule deleted" \
            "/mgmt/tm/ltm/rule/sslo-tls-verify-rule"; then
            REMOVED+=("LTM iRule: sslo-tls-verify-rule")
        else
            FAILED+=("LTM iRule: sslo-tls-verify-rule")
        fi
    else
        info "iRule sslo-tls-verify-rule not found"
        if (( HAS_TLS_RULE )); then
            REMOVED+=("LTM iRule: sslo-tls-verify-rule")
        else
            SKIPPED+=("LTM iRule: sslo-tls-verify-rule")
        fi
    fi
    step_done
    sleep 1

    ## -----------------------------------------------------------------------
    ## Phase 8: Final verification
    ## -----------------------------------------------------------------------
    step_screen "Final verification"
    info "Re-scanning the BIG-IP to confirm state"
    info "This may take a moment"
    echo

    LEFTOVERS=()
    rest_get "/mgmt/shared/iapp/blocks" >/dev/null
    if echo "${REST_RESPONSE_BODY}" | jq -e '.items[]? | select(.name=="ssloS_Blocking_Page")' >/dev/null 2>&1; then
        LEFTOVERS+=("iAppsLX block instance: ssloS_Blocking_Page")
    fi
    if rest_get "/mgmt/tm/sys/folder/~Common~ssloS_Blocking_Page.app"; then
        LEFTOVERS+=(".app folder: /Common/ssloS_Blocking_Page.app")
    fi
    if rest_get "/mgmt/tm/ltm/virtual/~Common~ssloS_Blocking_Page.app~ssloS_Blocking_Page-t-4"; then
        LEFTOVERS+=("Virtual: ssloS_Blocking_Page-t-4")
    fi
    if rest_get "/mgmt/tm/ltm/rule/blocking-page-rule"; then
        LEFTOVERS+=("LTM iRule: blocking-page-rule")
    fi
    if rest_get "/mgmt/tm/ltm/rule/sslo-tls-verify-rule"; then
        LEFTOVERS+=("LTM iRule: sslo-tls-verify-rule")
    fi
    if rest_get "/mgmt/tm/ltm/ifile/blocking-page-html"; then
        LEFTOVERS+=("LTM iFile: blocking-page-html")
    fi
    if rest_get "/mgmt/tm/sys/file/ifile/blocking-page-html"; then
        LEFTOVERS+=("System iFile: blocking-page-html")
    fi

    if (( ${#LEFTOVERS[@]} == 0 )); then
        ok "All Blocking-Page components removed"
    else
        fail "The following objects are still on the BIG-IP:"
        for o in "${LEFTOVERS[@]}"; do
            echo -e "  ${C_RED}*${C_RESET} ${C_WHITE}${o}${C_RESET}"
            ## Promote any leftovers that we did not already record as failed
            already=0
            for f in "${FAILED[@]+"${FAILED[@]}"}"; do
                if [[ "${f}" == *"${o}"* ]]; then
                    already=1
                    break
                fi
            done
            if (( ! already )); then
                FAILED+=("${o} (still present after uninstall)")
            fi
        done
    fi
    step_done
    sleep 2

    ## -----------------------------------------------------------------------
    ## Final summary
    ## -----------------------------------------------------------------------
    clear
    render_banner
    if (( ${#FAILED[@]} == 0 )); then
        echo -e "${C_BOLD}${C_GREEN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
        echo -e "${C_BOLD}${C_GREEN}║${C_RESET}  ${C_BOLD}${C_WHITE}Uninstall Complete${C_RESET}                                          ${C_BOLD}${C_GREEN}║${C_RESET}"
        echo -e "${C_BOLD}${C_GREEN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    else
        echo -e "${C_BOLD}${C_YELLOW}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
        echo -e "${C_BOLD}${C_YELLOW}║${C_RESET}  ${C_BOLD}${C_WHITE}Uninstall Completed with Errors${C_RESET}                             ${C_BOLD}${C_YELLOW}║${C_RESET}"
        echo -e "${C_BOLD}${C_YELLOW}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    fi
    echo

    if (( ${#REMOVED[@]} > 0 )); then
        echo -e "${C_WHITE}Removed:${C_RESET}"
        for o in "${REMOVED[@]}"; do
            echo -e "  ${C_GREEN}*${C_RESET} ${C_WHITE}${o}${C_RESET}"
        done
        echo
    fi

    if (( ${#SKIPPED[@]} > 0 )); then
        echo -e "${C_WHITE}Skipped (not present):${C_RESET}"
        for o in "${SKIPPED[@]}"; do
            echo -e "  ${C_YELLOW}*${C_RESET} ${C_WHITE}${o}${C_RESET}"
        done
        echo
    fi

    if (( ${#FAILED[@]} > 0 )); then
        echo -e "${C_WHITE}Failed (manual cleanup required):${C_RESET}"
        for o in "${FAILED[@]}"; do
            echo -e "  ${C_RED}*${C_RESET} ${C_WHITE}${o}${C_RESET}"
        done
        echo
    fi

    exit 0
fi

## ===========================================================================
## Install path begins here
## ===========================================================================
## Existing-install detection - if any objects are found, abort 
clear
render_banner
info "Scanning the BIG-IP for existing Blocking-Page components"
info "This may take a moment"
echo

EXISTING=()
if rest_get "/mgmt/tm/ltm/rule/blocking-page-rule"; then
    EXISTING+=("LTM iRule: blocking-page-rule")
fi
if rest_get "/mgmt/tm/ltm/rule/sslo-tls-verify-rule"; then
    EXISTING+=("LTM iRule: sslo-tls-verify-rule")
fi
if rest_get "/mgmt/tm/sys/file/ifile/blocking-page-html"; then
    EXISTING+=("System iFile: blocking-page-html")
fi
if rest_get "/mgmt/tm/ltm/ifile/blocking-page-html"; then
    EXISTING+=("LTM iFile: blocking-page-html")
fi
existing_block=$(curl -sk -u "${BIGUSER}" \
    "https://localhost/mgmt/shared/iapp/blocks" \
    | jq -r '.items[] | select(.name=="ssloS_Blocking_Page") | .id' 2>/dev/null)
if [[ -n "${existing_block}" && "${existing_block}" != "null" ]]; then
    EXISTING+=("iAppsLX block instance: ssloS_Blocking_Page")
fi

if (( ${#EXISTING[@]} > 0 )); then
    fail "Existing Blocking_Page components detected:"
    echo
    for o in "${EXISTING[@]}"; do
        echo -e "  ${C_RED}*${C_RESET} ${C_WHITE}${o}${C_RESET}"
    done
    echo
    fail "Re-run and select Uninstall to remove them first."
    echo
    exit 1
fi
ok "No existing components found - safe to install"
sleep 1


## Extract embedded payloads to working files
## Quoted heredoc delimiters ('EOF') prevent shell expansion of Tcl/JSON content.
info "Extracting embedded payloads"

cat > "blocking-page-rule" << 'EOF'
## SSL Orchestrator Service Extension - Advanced Blocking Pages
## Version: 1.0
## Date: 2025 Oct 10
## Author: Kevin Stewart, F5 Networks

when RULE_INIT {
    ## ===========================================
    ## User-Defined Setting :: GLOBAL BLOCK: Use this Boolean to indicate blocking strategy:
    ##  0 (off): The iRule logic below determines the blocking behavior, where the blocking service can be placed in all service chains.
    ##  1  (on): The SSLO policy inserts a static blocking action, where the blocking service is applied to a blocking service chain.
    ##
    ## User-Defined Setting :: GLOBAL BLOCK MESSAGE: Send this string to the iFile for any additional messaging on the page.
    ## ===========================================
    set static::GLOBAL_BLOCK 0
    set static::GLOBAL_BLOCK_MESSAGE "This request has been blocked. If you believe you have reached this page in error, please contact support."
}

proc GEN_BLOCK_PAGE { msg } {
    set receive_msg $msg
    HTTP::respond 200 content  [subst -nocommands -nobackslashes [ifile get blocking-page-html]] "Connection" "close"
}

when HTTP_REQUEST {
    if { $static::GLOBAL_BLOCK } {
        call GEN_BLOCK_PAGE ${static::GLOBAL_BLOCK_MESSAGE}
        event disable all
    } else {
        sharedvar ctx
        if { ( [info exists ctx(tlsverify)] ) and ( $ctx(tlsverify) ne "ok" ) } {
            call GEN_BLOCK_PAGE "This request has been blocked due to a server side TLS issue: <br /></br>[string toupper $ctx(tlsverify)]"
            event disable all
        }
    }
}
EOF

cat > "sslo-tls-verify-rule" << 'EOF'
## SSL Orchestrator Service Extension - Advanced Blocking Pages (TLS Verification Rule)
## Version: 1.0
## Date: 2025 Oct 10
## Author: Kevin Stewart, F5 Networks

when SERVERSSL_SERVERCERT {
    sharedvar ctx
    set ctx(tlsverify) [X509::verify_cert_error_string [SSL::verify_result]]
}
EOF

cat > "blocking-page-service" << 'EOF'
{
    "name": "sslo_ob_SERVICE_CREATE_ssloS_Blocking_Page",
    "inputProperties": [
      {
        "id": "f5-ssl-orchestrator-operation-context",
        "type": "JSON",
        "value": {
          "operationType": "CREATE",
          "deploymentType": "SERVICE",
          "deploymentName": "ssloS_Blocking_Page",
          "deploymentReference": "",
          "partition": "Common",
          "strictness": true
        }
      },
      {
        "id": "f5-ssl-orchestrator-service",
        "type": "JSON",
        "value": [
          {
            "name": "ssloS_Blocking_Page",
            "strictness": false,
            "customService": {
              "name": "ssloS_Blocking_Page",
              "ipFamily": "ipv4",
              "serviceDownAction": "",
              "serviceType": "f5-tenant-restrictions",
              "serviceSpecific": {
                "restrictAccessToTenant": "F5ABP",
                "restrictAccessContext": "F5ABP",
                "subType": "o365",
                "name": "ssloS_Blocking_Page"
              },
              "iRuleList": [
                {
                  "name": "/Common/blocking-page-rule",
                  "value": "/Common/blocking-page-rule"
                }
              ]
            },
            "vendorInfo": {
              "name": "SSLO Blocking Page",
              "product": "",
              "model": "",
              "version": ""
            },
            "description": "Type: f5-sslo-blocking-page",
            "useTemplate": false,
            "serviceTemplate": "",
            "partition": "Common",
            "previousVersion": "11.0",
            "version": "11.0"
          }
        ]
      },
      {
        "id": "f5-ssl-orchestrator-tls",
        "type": "JSON",
        "value": {}
      },
      {
        "id": "f5-ssl-orchestrator-authentication",
        "type": "JSON",
        "value": []
      },
      {
        "id": "f5-ssl-orchestrator-service-chain",
        "type": "JSON",
        "value": []
      },
      {
        "id": "f5-ssl-orchestrator-policy",
        "type": "JSON",
        "value": {}
      },
      {
        "id": "f5-ssl-orchestrator-topology",
        "type": "JSON",
        "value": {}
      },
      {
        "id": "f5-ssl-orchestrator-intercept-rule",
        "type": "JSON",
        "value": []
      },
      {
        "id": "f5-ssl-orchestrator-network",
        "type": "JSON",
        "value": []
      }
    ],
    "configurationProcessorReference": {
      "link": "https://localhost/mgmt/shared/iapp/processors/f5-iappslx-ssl-orchestrator-gc"
    },
    "configProcessorTimeoutSeconds": 120,
    "statsProcessorTimeoutSeconds": 60,
    "configProcessorAffinity": {
      "processorPolicy": "LOCAL",
      "affinityProcessorReference": {
        "link": "https://localhost/mgmt/shared/iapp/affinity/local"
      }
    },
    "state": "BINDING",
    "presentationHtmlReference": {
      "link": "https://localhost/iapps/f5-iappslx-ssl-orchestrator/sgc/sgcIndex.html"
    },
    "operation": "CREATE"
  }
EOF


## Create temporary Python converter
cat > "rule-converter.py" << 'EOF'
import sys

filename = sys.argv[1]

with open(filename, "r") as file:
    lines = file.readlines()

escape_chars = {
    '\\': '\\\\',
    '"': '\\"',
    '\n': '\\n',
    '\[': '\\[',
    '\]': '\\]',
    '\.': '\\.',
    '\d': '\\d',
}

one_line = "".join(lines)
for old, new in escape_chars.items():
    one_line = one_line.replace(old, new)

output_filename = filename.split(".")[0] + ".out"
with open(output_filename, "w") as f:
    f.write(one_line)
EOF


## Create blocking-page-rule iRule
step_screen "Install blocking-page-rule iRule"
python3 rule-converter.py blocking-page-rule
rule=$(cat blocking-page-rule.out)
data="{\"name\":\"blocking-page-rule\",\"apiAnonymous\":\"${rule}\"}"
rest_post "blocking-page-rule iRule created" "/mgmt/tm/ltm/rule" "${data}" \
    || abort "iRule creation failed - cannot continue"
step_done
sleep 1


## Create sslo-tls-verify-rule iRule
step_screen "Install sslo-tls-verify-rule iRule"
python3 rule-converter.py sslo-tls-verify-rule
rule=$(cat sslo-tls-verify-rule.out)
data="{\"name\":\"sslo-tls-verify-rule\",\"apiAnonymous\":\"${rule}\"}"
rest_post "sslo-tls-verify-rule iRule created" "/mgmt/tm/ltm/rule" "${data}" \
    || abort "iRule creation failed - cannot continue"
step_done
sleep 1


## Create system iFile (blocking-page-html)
step_screen "Create system iFile blocking-page-html"
data="{\"name\": \"blocking-page-html\", \"source-path\": \"file://${PWD}/blocking-page-html\"}"
rest_post "system iFile blocking-page-html created" "/mgmt/tm/sys/file/ifile/" "${data}" \
    || abort "System iFile creation failed - cannot continue"
step_done
sleep 1


## Create LTM iFile (blocking-page-html)
step_screen "Create LTM iFile blocking-page-html"
data='{"name":"blocking-page-html", "file-name": "blocking-page-html"}'
rest_post "LTM iFile blocking-page-html created" "/mgmt/tm/ltm/ifile" "${data}" \
    || abort "LTM iFile creation failed - cannot continue"
step_done
sleep 1


## Create SSL Orchestrator blocking-page inspection service
step_screen "Create SSL Orchestrator blocking-page inspection service"
data="$(cat blocking-page-service)"
rest_post "SSLO Blocking-Page inspection service created" "/mgmt/shared/iapp/blocks" "${data}" \
    || abort "iAppsLX block instance creation failed - cannot continue"
step_done
sleep 1


## Sleep for 15 seconds to allow the inspection service build to finish
step_screen "Wait for SSL Orchestrator to build the service"
sleep_with_countdown 15 "Waiting:"
step_done
sleep 1


## Replace the iRule list on the -t-4 virtual with only blocking-page-rule.
step_screen "Clear rules array on the service virtual"
rest_patch "rules array cleared" \
    "/mgmt/tm/ltm/virtual/ssloS_Blocking_Page.app~ssloS_Blocking_Page-t-4" \
    '{"rules":[]}'

## Allow mcpd time to commit the clear before issuing the set
step_done
sleep 5

step_screen "Attach blocking-page-rule to the service virtual"
rest_patch "blocking-page-rule attached" \
    "/mgmt/tm/ltm/virtual/ssloS_Blocking_Page.app~ssloS_Blocking_Page-t-4" \
    '{"rules":["/Common/blocking-page-rule"]}'

## Allow mcpd time to commit the set before verification
step_done
sleep 5

## Verify the rules list now contains only blocking-page-rule
step_screen "Verify virtual rules list"
verify_response=$(curl -sk -u "${BIGUSER}" \
    "https://localhost/mgmt/tm/ltm/virtual/ssloS_Blocking_Page.app~ssloS_Blocking_Page-t-4")
if echo "${verify_response}" | grep -q "tenant-restrictions"; then
    warn "tenant-restrictions iRule still attached"
elif echo "${verify_response}" | grep -q "blocking-page-rule"; then
    ok "blocking-page-rule is the only iRule attached"
else
    warn "Cannot confirm rules list - inspect virtual manually"
fi
step_done
sleep 1


## Clean up temporary files and extracted payloads
rm -f rule-converter.py blocking-page-rule.out sslo-tls-verify-rule.out
rm -f blocking-page-rule sslo-tls-verify-rule blocking-page-service

## Final completion screen
clear
render_banner
echo -e "${C_BOLD}${C_GREEN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}║${C_RESET}  ${C_BOLD}${C_WHITE}Installation Complete${C_RESET}                                       ${C_BOLD}${C_GREEN}║${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
echo
echo -e "${C_WHITE}The following objects were created on the BIG-IP:${C_RESET}"
echo
echo -e "  ${C_GREEN}*${C_RESET} ${C_WHITE}LTM iRule:${C_RESET}        blocking-page-rule"
echo -e "  ${C_GREEN}*${C_RESET} ${C_WHITE}LTM iRule:${C_RESET}        sslo-tls-verify-rule"
echo -e "  ${C_GREEN}*${C_RESET} ${C_WHITE}System iFile:${C_RESET}     blocking-page-html"
echo -e "  ${C_GREEN}*${C_RESET} ${C_WHITE}LTM iFile:${C_RESET}        blocking-page-html"
echo -e "  ${C_GREEN}*${C_RESET} ${C_WHITE}iAppsLX block:${C_RESET}   ssloS_Blocking_Page"
echo
echo -e "${C_WHITE}Based on Kevin Stewart's original script:${C_RESET}"
echo -e "${C_WHITE}https://github.com/f5devcentral/sslo-service-extensions/tree/main/advanced-blocking-pages${C_RESET}"
echo
