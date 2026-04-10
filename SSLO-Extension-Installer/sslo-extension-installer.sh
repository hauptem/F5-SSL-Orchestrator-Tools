#!/bin/bash
# F5 SSL Orchestrator Service Extension Installer
# Version 1.0
# Author: Eric Haupt
# https://github.com/hauptem/F5-SSL-Orchestrator-Tools
#
# Created for closed network organizations who cannot use Kevin's original versions.
# Unified installer and uninstaller for SSL Orchestrator service extensions.
#
# Currently included extensions:
#
#   - Advanced Blocking Pages
#     Version 1.0
#     Author: Kevin Stewart - F5 Inc.
#     https://github.com/f5devcentral/sslo-service-extensions/tree/main/advanced-blocking-pages
#
#   - DoH Guardian
#     Version 1.0
#     Author: Kevin Stewart - F5 Inc.
#     https://github.com/f5devcentral/sslo-service-extensions/tree/main/doh-guardian
#

# ===========================================================================
# Optional script integrity verification
# ===========================================================================
# This script supports optional SHA-256 self-verification. The feature is
# DISABLED by default and should only be enabled when sealing the script
# for transfer through a cross-domain solution (CDS), guard, one-way diode,
# or other restricted file-transfer path. The check proves on the receiving
# side that not a single byte has changed in transit.
#
# Sending-side workflow:
#
#   1. Finalize any customizations to the script.
#   2. Open the script and set the toggle near the top:
#
#        HASH_CHECK_ENABLED=1
#
#   3. Compute the script hash:
#
#        head -n -1 sslo-extensions-installer.sh | sha256sum | cut -d' ' -f1
#
#   4. Replace the placeholder on the very last line of the script with
#      the 64-character hash from the previous step. The last line must
#      match exactly:
#
#        ## SCRIPT_SHA256: <64-hex-char-hash>
#
#      Nothing may follow. No trailing blank lines, no comments, no
#      trailing newline after the hash value.
#   5. Transfer the script through the CDS.
#
# Receiving-side behavior at preflight:
#
#   - Match:      silent, script continues
#   - Mismatch:   WARN, operator is prompted to continue or abort
#   - Unsigned:   WARN, operator is prompted to continue or abort
#
# If HASH_CHECK_ENABLED=0 (the default) the verifier is skipped entirely
# and the last-line hash is ignored.
# ===========================================================================


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
    fail "Aborted. Exiting."
    exit 1
}


## ===========================================================================
## Runtime toggles
## ===========================================================================
## Script integrity verification - set to 1 to enable the SHA-256 check
## at preflight. Default is 0 (disabled). Only enable this on a copy of
## the script that has been signed with a real hash on the last line.
HASH_CHECK_ENABLED=0


## ===========================================================================
## Progress bar globals and rendering helpers
## ===========================================================================
INSTALL_STEP=0
INSTALL_TOTAL=0
EXTENSION_TITLE=""

render_banner() {
    local title_line
    if [[ -n "${EXTENSION_TITLE}" ]]; then
        title_line="${EXTENSION_TITLE}"
    else
        title_line=""
    fi
    local padded
    printf -v padded "%-59s" "${title_line}"
    echo -e "${C_BOLD}${C_BLUE}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}║${C_RESET}  ${C_BOLD}${C_WHITE}F5 SSL Orchestrator Service Extensions ${C_RESET}                     ${C_BOLD}${C_BLUE}║${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}║${C_RESET}  ${C_BOLD}${C_WHITE}${padded}${C_RESET} ${C_BOLD}${C_BLUE}║${C_RESET}"
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

## ---------------------------------------------------------------------------
## Script integrity verification - compares a SHA-256 of the script content
## (everything except the last line) against the hash stored on the last
## line. Runs before any other preflight so a tampered or unsigned script
## gives the operator a chance to bail before anything else happens.
##
## Disabled by default. Controlled by HASH_CHECK_ENABLED near the top of
## the script.
## ---------------------------------------------------------------------------
verify_script_hash() {
    (( HASH_CHECK_ENABLED )) || return 0

    local script_path="${BASH_SOURCE[0]}"
    local last_line stored_hash computed_hash prompt_needed=0 reason=""

    last_line=$(tail -n 1 "${script_path}")

    if [[ ! "${last_line}" =~ ^##[[:space:]]SCRIPT_SHA256:[[:space:]] ]]; then
        reason="Script is missing its integrity hash line."
        prompt_needed=1
    else
        stored_hash="${last_line##*SCRIPT_SHA256: }"
        stored_hash="${stored_hash// /}"
        if [[ "${stored_hash}" == "<unsigned>" || "${stored_hash}" =~ ^0+$ ]]; then
            reason="Script has not been signed (integrity hash is a placeholder)."
            prompt_needed=1
        elif [[ ! "${stored_hash}" =~ ^[0-9a-fA-F]{64}$ ]]; then
            reason="Script integrity hash is malformed."
            prompt_needed=1
        else
            computed_hash=$(head -n -1 "${script_path}" | sha256sum | cut -d' ' -f1)
            if [[ "${computed_hash}" != "${stored_hash}" ]]; then
                reason="Script content does not match its stored integrity hash."
                prompt_needed=1
            fi
        fi
    fi

    if (( prompt_needed )); then
        echo
        warn "${reason}"
        warn "The script may have been modified since it was signed."
        echo
        read -p "$(echo -e "${C_WHITE}Continue anyway? (type CONTINUE to proceed): ${C_RESET}")" answer
        if [[ "${answer}" != "CONTINUE" ]]; then
            abort "Aborted by user due to script integrity warning."
        fi
        echo
    fi
}
verify_script_hash

if [[ ! -f /VERSION ]] || ! grep -qi "BIG-IP" /VERSION 2>/dev/null; then
    abort "This installer must be run on a BIG-IP system."
fi
ok "BIG-IP system detected"
sleep 1


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
        fail "${description} (HTTP ${http_code})"
        return 1
    fi
}

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
## tmsh helper - run a tmsh command, capture exit status, report tagged
## result in the same style as the REST helpers.
## ===========================================================================
tmsh_run() {
    local description="$1"
    shift
    local output
    if output=$("$@" 2>&1); then
        ok "${description}"
        return 0
    else
        fail "${description}"
        [[ -n "${output}" ]] && echo -e "${C_WHITE}${output}${C_RESET}"
        return 1
    fi
}


## ===========================================================================
## Cleanup trap - removes temp files on exit. If mutations were started
## but the script did not complete, prints a partial-state warning.
## ===========================================================================
COMPLETED=0
MUTATIONS_STARTED=0
DISCOVERY_CACHED_FOR=""
cleanup_on_exit() {
    local rc=$?
    rm -f rule-converter.py
    rm -f blocking-page-rule blocking-page-rule.out
    rm -f sslo-tls-verify-rule sslo-tls-verify-rule.out
    rm -f blocking-page-service
    rm -f doh-guardian-rule doh-guardian-rule.out
    rm -f doh-guardian-service
    rm -f sinkhole.crt sinkhole.key
    if (( COMPLETED == 0 && MUTATIONS_STARTED == 1 )); then
        echo
        fail "Script exited before completion (rc=${rc})."
        fail "The BIG-IP may be in a partial state."
        fail "Re-run and select Uninstall to clean up any created objects."
        echo
    fi
}
trap cleanup_on_exit EXIT INT TERM


## ===========================================================================
## Shared rule converter by Kevin Stweart
#  Writes a small Python helper to disk that escapes a Tcl iRule for 
#  embedding in a JSON body. 
## ===========================================================================
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


## ===========================================================================
## Extension selection menu
## ===========================================================================
select_extension() {
    while true; do
        clear
        render_banner
        echo -e "${C_WHITE}Select a supported service extension:${C_RESET}"
        echo
        echo -e "  ${C_WHITE}1) Advanced Blocking Pages${C_RESET}"
        echo -e "  ${C_WHITE}2) DoH Guardian${C_RESET}"
        echo -e "  ${C_WHITE}0) Exit${C_RESET}"
        echo
        read -p "$(echo -e "${C_WHITE}Select an option: ${C_RESET}")" ext_choice
        case "${ext_choice}" in
            1)
                EXTENSION="blocking_page"
                EXTENSION_TITLE="Advanced Blocking Pages v1.0"
                break
                ;;
            2)
                EXTENSION="doh_guardian"
                EXTENSION_TITLE="DoH Guardian v1.0"
                break
                ;;
            0)
                COMPLETED=1
                exit 0
                ;;
            *)
                echo
                warn "Invalid selection. Press Enter to try again."
                read -r
                ;;
        esac
    done
    echo
}


## ===========================================================================
## Install/uninstall submenu
## ===========================================================================
select_mode() {
    while true; do
        clear
        render_banner
        echo -e "${C_WHITE}What would you like to do?${C_RESET}"
        echo
        echo -e "  ${C_WHITE}1) Install${C_RESET}"
        echo -e "  ${C_WHITE}2) Uninstall${C_RESET}"
        echo -e "  ${C_WHITE}0) Exit${C_RESET}"
        echo
        read -p "$(echo -e "${C_WHITE}Select an option: ${C_RESET}")" menu_choice
        case "${menu_choice}" in
            1) MODE=1; break ;;
            2) MODE=2; break ;;
            0)
                COMPLETED=1
                exit 0
                ;;
            *)
                echo
                warn "Invalid selection. Press Enter to try again."
                read -r
                ;;
        esac
    done
    echo
}


## ===========================================================================
## Credential prompt and verification
## ===========================================================================
prompt_credentials() {
    read -p "$(echo -e "${C_WHITE}Enter admin username: ${C_RESET}")" biguser
    read -sp "$(echo -e "${C_WHITE}Enter admin password: ${C_RESET}")" bigpass
    echo
    if [[ -z "${biguser}" || -z "${bigpass}" ]]; then
        abort "Username and password are required."
    fi
    BIGUSER="${biguser}:${bigpass}"

    ## The authn/login endpoint returns a token only on valid credentials.
    local probe_body
    probe_body=$(curl -sk \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${biguser}\",\"password\":\"${bigpass}\",\"loginProviderName\":\"tmos\"}" \
        "https://localhost/mgmt/shared/authn/login")
    if ! echo "${probe_body}" | grep -q '"token"'; then
        abort "Credential check failed. Verify username and password."
    fi
    ok "Credentials accepted"
    sleep 1
}


## ===========================================================================
## Existing-components prompt - shared between extensions. Called by an
## install function when it finds objects already on the BIG-IP. Returns:
##   0 - user pressed Enter, caller should return 2 to dispatch loop
##   1 - user chose to exit (handled directly by exit 0)
## ===========================================================================
prompt_existing_components() {
    local title="$1"
    shift
    local items=("$@")
    fail "${title}"
    echo
    for o in "${items[@]}"; do
        echo -e "  ${C_RED}*${C_RESET} ${C_WHITE}${o}${C_RESET}"
    done
    echo
    echo -e "${C_WHITE}These must be removed before this extension can be installed.${C_RESET}"
    echo
    echo -e "  ${C_WHITE}Press Enter to return to the install/uninstall menu${C_RESET}"
    echo -e "  ${C_WHITE}0) Exit${C_RESET}"
    echo
    read -p "$(echo -e "${C_WHITE}Selection: ${C_RESET}")" choice
    if [[ "${choice}" == "0" ]]; then
        COMPLETED=1
        exit 0
    fi
    return 0
}


## ###########################################################################
## ###########################################################################
## ##                                                                       ##
## ##               SSLO EXTENSION: Advanced Blocking Pages                 ##
## ##                                                                       ##
## ###########################################################################
## ###########################################################################


## ---------------------------------------------------------------------------
## INSTALLER
## ---------------------------------------------------------------------------
install_blocking_page() {
    ## The blocking page HTML file must be present in the current directory.
    if [[ ! -f "blocking-page-html" ]]; then
        abort "Required file 'blocking-page-html' not found in current directory."
    fi
    ok "blocking-page-html present"
    sleep 1

    INSTALL_TOTAL=9
    echo -e "${C_WHITE}Objects to be created:${C_RESET}"
    echo -e "${C_WHITE}  - LTM iRule:        blocking-page-rule${C_RESET}"
    echo -e "${C_WHITE}  - LTM iRule:        sslo-tls-verify-rule${C_RESET}"
    echo -e "${C_WHITE}  - System iFile:     blocking-page-html${C_RESET}"
    echo -e "${C_WHITE}  - LTM iFile:        blocking-page-html${C_RESET}"
    echo -e "${C_WHITE}  - iAppsLX block:    ssloS_Blocking_Page${C_RESET}"
    echo
    echo -e "${C_WHITE}To proceed, type CONFIRM (case sensitive).${C_RESET}"
    read -p "$(echo -e "${C_WHITE}Confirm: ${C_RESET}")" confirmation
    if [[ "${confirmation}" != "CONFIRM" ]]; then
        abort "Confirmation not received. No changes were made to the BIG-IP."
    fi


    ## Existing-install detection - if components are present, populate the
    ## same discovery state the uninstaller would build, then offer the user
    ## the chance to bounce back to the menu and run uninstall without a
    ## second scan.
    clear
    render_banner
    echo -e "${C_WHITE}Scanning the BIG-IP for existing Blocking_Page components${C_RESET}"
    echo -e "${C_WHITE}This may take a few moments...${C_RESET}"
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
    if rest_get "/mgmt/tm/ltm/virtual/ssloS_Blocking_Page.app~ssloS_Blocking_Page-t-4"; then
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

    EXISTING=()
    (( HAS_BP_RULE ))    && EXISTING+=("LTM iRule: blocking-page-rule")
    (( HAS_TLS_RULE ))   && EXISTING+=("LTM iRule: sslo-tls-verify-rule")
    (( HAS_SYS_IFILE ))  && EXISTING+=("System iFile: blocking-page-html")
    (( HAS_LTM_IFILE ))  && EXISTING+=("LTM iFile: blocking-page-html")
    (( HAS_BLOCK ))      && EXISTING+=("iAppsLX block instance: ssloS_Blocking_Page")

    if (( ${#EXISTING[@]} > 0 )); then
        DISCOVERY_CACHED_FOR="blocking_page"
        prompt_existing_components "Existing Blocking_Page components detected:" "${EXISTING[@]}"
        return 2
    fi
    ok "No existing components found - safe to install"
    sleep 1


    ## Extract embedded payloads to working files.
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


    ## Create blocking-page-rule iRule
    step_screen "Install blocking-page-rule iRule"
    MUTATIONS_STARTED=1
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
    rest_post "SSLO Blocking_Page inspection service created" "/mgmt/shared/iapp/blocks" "${data}" \
        || abort "iAppsLX block instance creation failed - cannot continue"
    step_done
    sleep 1


    ## Poll the -t-4 virtual every 10 seconds, up to a 60 second ceiling.
    ## The display ticks every second to show the script is alive.
    step_screen "Wait for SSL Orchestrator to build the service"
    POLL_MAX=60
    POLL_ELAPSED=0
    while (( POLL_ELAPSED < POLL_MAX )); do
        if rest_get "/mgmt/tm/ltm/virtual/ssloS_Blocking_Page.app~ssloS_Blocking_Page-t-4"; then
            break
        fi
        for (( tick=1; tick<=10 && POLL_ELAPSED < POLL_MAX; tick++ )); do
            POLL_ELAPSED=$(( POLL_ELAPSED + 1 ))
            printf "\r${C_WHITE}Waiting for service virtual... ${C_BOLD}%d${C_RESET}${C_WHITE}s elapsed${C_RESET}    " "${POLL_ELAPSED}"
            sleep 1
        done
    done
    echo
    (( POLL_ELAPSED >= POLL_MAX )) && abort "Service virtual not ready after ${POLL_MAX}s"
    ok "Service virtual ready (${POLL_ELAPSED}s)"
    step_done
    sleep 1


    ## Replace the iRule list on the -t-4 virtual with only blocking-page-rule.
    step_screen "Clear rules array on the service virtual"
    rest_patch "rules array cleared" \
        "/mgmt/tm/ltm/virtual/ssloS_Blocking_Page.app~ssloS_Blocking_Page-t-4" \
        '{"rules":[]}' \
        || abort "Failed to clear rules array on service virtual - cannot continue"

    ## Allow mcpd to commit the clear before the set
    step_done
    sleep 5

    step_screen "Attach blocking-page-rule to the service virtual"
    rest_patch "blocking-page-rule attached" \
        "/mgmt/tm/ltm/virtual/ssloS_Blocking_Page.app~ssloS_Blocking_Page-t-4" \
        '{"rules":["/Common/blocking-page-rule"]}' \
        || abort "Failed to attach blocking-page-rule to service virtual - cannot continue"

    ## Allow mcpd to commit the set before verification
    step_done
    sleep 5

    ## Verify the rules list now contains only blocking-page-rule
    step_screen "Verify virtual rules list"
    verify_response=$(curl -sk -u "${BIGUSER}" \
        "https://localhost/mgmt/tm/ltm/virtual/ssloS_Blocking_Page.app~ssloS_Blocking_Page-t-4")
    rules_list=$(echo "${verify_response}" | jq -r '.rules[]?' 2>/dev/null)
    if [[ "${rules_list}" == "/Common/blocking-page-rule" ]]; then
        ok "blocking-page-rule is the only iRule attached"
    elif [[ -z "${rules_list}" ]]; then
        warn "Rules array is empty - inspect virtual manually"
    else
        warn "Unexpected rules on virtual - inspect manually:"
        echo "${rules_list}" | while read -r r; do
            echo -e "  ${C_YELLOW}*${C_RESET} ${C_WHITE}${r}${C_RESET}"
        done
    fi
    step_done
    sleep 1


    COMPLETED=1

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
    echo -e "  ${C_GREEN}*${C_RESET} ${C_WHITE}iAppsLX block:${C_RESET}    ssloS_Blocking_Page"
    echo
    echo -e "${C_WHITE}Based on Kevin Stewart's original script:${C_RESET}"
    echo -e "${C_WHITE}https://github.com/f5devcentral/sslo-service-extensions/tree/main/advanced-blocking-pages${C_RESET}"
    echo
}

## ---------------------------------------------------------------------------
## UNINSTALLER
## ---------------------------------------------------------------------------
uninstall_blocking_page() {
    INSTALL_TOTAL=8
    echo -e "${C_WHITE}Objects to be removed:${C_RESET}"
    echo -e "${C_WHITE}  - iAppsLX block:    ssloS_Blocking_Page${C_RESET}"
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

        REMOVED=()
        SKIPPED=()
        FAILED=()

        ## -----------------------------------------------------------------------
        ## Phase 1: Discovery
        ## -----------------------------------------------------------------------
        step_screen "Discover existing Blocking_Page components"
        if [[ "${DISCOVERY_CACHED_FOR}" == "blocking_page" ]]; then
            echo -e "${C_WHITE}Using discovery state from previous install attempt${C_RESET}"
            echo
            DISCOVERY_CACHED_FOR=""
        else
            echo -e "${C_WHITE}Scanning the BIG-IP for existing Blocking_Page components${C_RESET}"
            echo -e "${C_WHITE}This may take a few moments...${C_RESET}"
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
            if rest_get "/mgmt/tm/ltm/virtual/ssloS_Blocking_Page.app~ssloS_Blocking_Page-t-4"; then
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
        fi

        echo
        info "Discovery results:"
        if (( HAS_BLOCK )); then
            echo -e "  ${C_WHITE}* iAppsLX block instance:          found (${BLOCK_STATE})${C_RESET}"
        else
            echo -e "  ${C_WHITE}* iAppsLX block instance:          not present${C_RESET}"
        fi
        if (( HAS_APP_SERVICE )); then
            echo -e "  ${C_WHITE}* iAppsLX application service:     found${C_RESET}"
        else
            echo -e "  ${C_WHITE}* iAppsLX application service:     not present${C_RESET}"
        fi
        if (( HAS_APP_FOLDER )); then
            echo -e "  ${C_WHITE}* .app folder:                     found${C_RESET}"
        else
            echo -e "  ${C_WHITE}* .app folder:                     not present${C_RESET}"
        fi
        if (( HAS_T4_VIRTUAL )); then
            echo -e "  ${C_WHITE}* ssloS_Blocking_Page-t-4 virtual: found${C_RESET}"
        else
            echo -e "  ${C_WHITE}* ssloS_Blocking_Page-t-4 virtual: not present${C_RESET}"
        fi
        if (( HAS_BP_RULE )); then
            echo -e "  ${C_WHITE}* blocking-page-rule iRule:        found${C_RESET}"
        else
            echo -e "  ${C_WHITE}* blocking-page-rule iRule:        not present${C_RESET}"
        fi
        if (( HAS_TLS_RULE )); then
            echo -e "  ${C_WHITE}* sslo-tls-verify-rule iRule:      found${C_RESET}"
        else
            echo -e "  ${C_WHITE}* sslo-tls-verify-rule iRule:      not present${C_RESET}"
        fi
        if (( HAS_LTM_IFILE )); then
            echo -e "  ${C_WHITE}* blocking-page-html LTM iFile:    found${C_RESET}"
        else
            echo -e "  ${C_WHITE}* blocking-page-html LTM iFile:    not present${C_RESET}"
        fi
        if (( HAS_SYS_IFILE )); then
            echo -e "  ${C_WHITE}* blocking-page-html sys iFile:    found${C_RESET}"
        else
            echo -e "  ${C_WHITE}* blocking-page-html sys iFile:    not present${C_RESET}"
        fi
        echo

        if (( HAS_BLOCK == 0 && HAS_APP_SERVICE == 0 && HAS_APP_FOLDER == 0 \
            && HAS_T4_VIRTUAL == 0 && HAS_BP_RULE == 0 && HAS_TLS_RULE == 0 \
            && HAS_LTM_IFILE == 0 && HAS_SYS_IFILE == 0 )); then
            ok "Nothing to remove. The BIG-IP is already clean."
            echo
            COMPLETED=1
                return 0
        fi
        step_done
        sleep 2

        ## -----------------------------------------------------------------------
        ## Phase 2: Remove the iAppsLX block instance (if present)
        ## -----------------------------------------------------------------------
        step_screen "Remove the iAppsLX block instance"
        MUTATIONS_STARTED=1
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
        ## Phase 3: Delete the iAppsLX application service
        ## -----------------------------------------------------------------------
        ## Deleting the application service cascades and removes the .app
        ## folder, the connector profile, the -t-4 virtual, and any other
        ## framework-managed objects inside it.
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
        echo -e "${C_WHITE}Re-scanning the BIG-IP to confirm state${C_RESET}"
        echo -e "${C_WHITE}This may take a few moments...${C_RESET}"
        echo

        LEFTOVERS=()
        rest_get "/mgmt/shared/iapp/blocks" >/dev/null
        if echo "${REST_RESPONSE_BODY}" | jq -e '.items[]? | select(.name=="ssloS_Blocking_Page")' >/dev/null 2>&1; then
            LEFTOVERS+=("iAppsLX block instance: ssloS_Blocking_Page")
        fi
        if rest_get "/mgmt/tm/sys/folder/~Common~ssloS_Blocking_Page.app"; then
            LEFTOVERS+=(".app folder: /Common/ssloS_Blocking_Page.app")
        fi
        if rest_get "/mgmt/tm/ltm/virtual/ssloS_Blocking_Page.app~ssloS_Blocking_Page-t-4"; then
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
            ok "All Blocking_Page components removed"
        else
            fail "The following objects are still on the BIG-IP:"
            for o in "${LEFTOVERS[@]}"; do
                echo -e "  ${C_RED}*${C_RESET} ${C_WHITE}${o}${C_RESET}"
                ## Promote any leftovers not already recorded as failed
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

        COMPLETED=1
        return 0
}

## ###########################################################################
## ###########################################################################
## ##                                                                       ##
## ##                   SSLO EXTENSION: DoH Guardian                        ##
## ##                                                                       ##
## ###########################################################################
## ###########################################################################


## ---------------------------------------------------------------------------
## INSTALLER
## ---------------------------------------------------------------------------
install_doh_guardian() {
    INSTALL_TOTAL=6
    echo -e "${C_WHITE}Objects to be created:${C_RESET}"
    echo -e "${C_WHITE}  - LTM iRule:        doh-guardian-rule${C_RESET}"
    echo -e "${C_WHITE}  - iAppsLX block:    ssloS_DoH_Guard${C_RESET}"
    echo
    echo -e "${C_WHITE}After the core install completes you will be offered the optional${C_RESET}"
    echo -e "${C_WHITE}sinkhole configuration (cert/key, client SSL profile, internal${C_RESET}"
    echo -e "${C_WHITE}virtual, and sinkhole target iRule).${C_RESET}"
    echo
    echo -e "${C_WHITE}To proceed, type CONFIRM (case sensitive).${C_RESET}"
    read -p "$(echo -e "${C_WHITE}Confirm: ${C_RESET}")" confirmation
    if [[ "${confirmation}" != "CONFIRM" ]]; then
        abort "Confirmation not received. No changes were made to the BIG-IP."
    fi


    ## Existing-install detection - if components are present, populate the
    ## same discovery state the uninstaller would build, then offer the user
    ## the chance to bounce back to the menu and run uninstall without a
    ## second scan.
    clear
    render_banner
    echo -e "${C_WHITE}Scanning the BIG-IP for existing DoH Guardian components${C_RESET}"
    echo -e "${C_WHITE}This may take a few moments...${C_RESET}"
    echo

    HAS_BLOCK=0
    BLOCK_ID=""
    BLOCK_STATE=""
    HAS_APP_SERVICE=0
    HAS_APP_FOLDER=0
    HAS_T4_VIRTUAL=0
    HAS_DOH_RULE=0
    HAS_SINK_RULE=0
    HAS_SINK_VIRTUAL=0
    HAS_SINK_CLIENTSSL=0
    HAS_SINK_CERT=0
    HAS_SINK_KEY=0

    block_json=$(curl -sk -u "${BIGUSER}" \
        "https://localhost/mgmt/shared/iapp/blocks" \
        | jq -r '.items[]? | select(.name=="ssloS_DoH_Guard") | "\(.id) \(.state)"' 2>/dev/null)
    if [[ -n "${block_json}" ]]; then
        HAS_BLOCK=1
        BLOCK_ID="${block_json%% *}"
        BLOCK_STATE="${block_json##* }"
    fi
    if rest_get "/mgmt/tm/sys/application/service/~Common~ssloS_DoH_Guard.app~ssloS_DoH_Guard"; then
        HAS_APP_SERVICE=1
    fi
    if rest_get "/mgmt/tm/sys/folder/~Common~ssloS_DoH_Guard.app"; then
        HAS_APP_FOLDER=1
    fi
    if rest_get "/mgmt/tm/ltm/virtual/ssloS_DoH_Guard.app~ssloS_DoH_Guard-t-4"; then
        HAS_T4_VIRTUAL=1
    fi
    if rest_get "/mgmt/tm/ltm/rule/doh-guardian-rule"; then
        HAS_DOH_RULE=1
    fi
    if rest_get "/mgmt/tm/ltm/rule/sinkhole-target-rule"; then
        HAS_SINK_RULE=1
    fi
    if rest_get "/mgmt/tm/ltm/virtual/sinkhole-internal-vip"; then
        HAS_SINK_VIRTUAL=1
    fi
    if rest_get "/mgmt/tm/ltm/profile/client-ssl/sinkhole-clientssl"; then
        HAS_SINK_CLIENTSSL=1
    fi
    if rest_get "/mgmt/tm/sys/file/ssl-cert/sinkhole-cert"; then
        HAS_SINK_CERT=1
    fi
    if rest_get "/mgmt/tm/sys/file/ssl-key/sinkhole-cert"; then
        HAS_SINK_KEY=1
    fi

    EXISTING=()
    (( HAS_DOH_RULE ))      && EXISTING+=("LTM iRule: doh-guardian-rule")
    (( HAS_SINK_RULE ))     && EXISTING+=("LTM iRule: sinkhole-target-rule")
    (( HAS_SINK_VIRTUAL ))  && EXISTING+=("LTM virtual: sinkhole-internal-vip")
    (( HAS_SINK_CLIENTSSL )) && EXISTING+=("LTM client-ssl: sinkhole-clientssl")
    (( HAS_SINK_CERT ))     && EXISTING+=("SSL cert: sinkhole-cert")
    (( HAS_SINK_KEY ))      && EXISTING+=("SSL key: sinkhole-cert")
    (( HAS_BLOCK ))         && EXISTING+=("iAppsLX block instance: ssloS_DoH_Guard")

    if (( ${#EXISTING[@]} > 0 )); then
        DISCOVERY_CACHED_FOR="doh_guardian"
        prompt_existing_components "Existing DoH Guardian components detected:" "${EXISTING[@]}"
        return 2
    fi
    ok "No existing components found - safe to install"
    sleep 1


    ## Extract embedded payloads to working files.
    info "Extracting embedded payloads"

    cat > "doh-guardian-rule" << 'DOH_GUARDIAN_RULE_EOF'
## SSL Orchestrator Service Extension - DNS-over-HTTP Guardian
## Version: 1.0
## Date: 2025 Aug 06
## Author: Kevin Stewart, F5 Networks

when RULE_INIT {
    ## ===========================================
    ## User-Defined Setting :: LOCAL LOGGING: Use this Boolean to send log traffic to local syslog facility (local0).
    ##  This option is not recommended under heavy load. Consider using HSL logging to send to an external SIEM.
    ## ===========================================
    set static::DOH_LOG_LOCAL 0

    ## ===========================================
    ## User-Defined Setting :: HSL LOGGING: Use this string value to send log traffic to an external Syslog service via high-speed logging (HSL).
    ##  The string must point to an existing HSL pool (ex. /Common/syslog-pool). A value of "none" disables HSL logging.
    ## ===========================================
    set static::DOH_LOG_HSL "none"

    ## ===========================================
    ## User-Defined Setting :: CATEGORY TYPE: Use this option to indicate the type of category to use.
    ##  Options: "subscription", "custom_only", or "sub_and_custom"
    ## ===========================================
    set static::DOH_CATEGORY_TYPE "subscription"

    ## ===========================================
    ## User-Defined Setting :: BASIC BLOCKING: Use this Boolean to indicate basic blocking of all DoH requests.
    ##  This option is mutually exclusive and takes precedence over all other blocking functions.
    ## ===========================================
    set static::DOH_BLOCKING_BASIC 0

    ## ===========================================
    ## User-Defined Array :: BLACKHOLE CATEGORY BLOCKING: Use this array to include any URL categories to trigger a DoH/DNS blackhole.
    ##  A DNS blackhole sends a valid (but bad) address to the client in response. In this implementation, and IPv4 request
    ##  gets 199.199.199.199, and an IPv6 requests gets 0:0:0:0:0:ffff:c7c7:c7c7.
    ##  Note: if a category exists in both DOH_BLACKHOLE_BY_CATEGORY and DOH_SINKHOLE_BY_CATEGORY, the former takes precedence
    ##
    ##  Actions (select one of these for each anomaly condition):
    ##      - dryrun        --> Dry Run action (just log)
    ##      - blackhole     --> Blackhole the response
    ## ===========================================
    set static::DOH_BLACKHOLE_BY_CATEGORY_ACTION "blackhole"
    set static::DOH_BLACKHOLE_BY_CATEGORY {
        #/Common/Information_Technology
    }

    ## ===========================================
    ## User-Defined Array :: SINKHOLE CATEGORY BLOCKING: Use this array to include any URL categories to trigger a DoH/DNS sinkhole.
    ##  A DNS sinkhole sends a valid address that points to a local blocking page.
    ##  Note: if a category exists in both DOH_BLACKHOLE_BY_CATEGORY and DOH_SINKHOLE_BY_CATEGORY, the former takes precedence
    ##
    ##  Actions (select one of these for each anomaly condition):
    ##      - dryrun        --> Dry Run action (just log)
    ##      - sinkhole      --> Sinkhole the response
    ## ===========================================
    set static::DOH_SINKHOLE_BY_CATEGORY_ACTION "sinkhole"
    set static::DOH_SINKHOLE_BY_CATEGORY {
        #/Common/Entertainment
    }

    ## ===========================================
    ## User-defined Setting: SINKHOLE IP ADDRESS: This IP address points to an HTTPS VIP on this BIG-IP that will serve up a
    ##  blocking page.
    ## ===========================================
    set static::DOH_SINKHOLE_IP4 "10.1.10.160"
    set static::DOH_SINKHOLE_IP6 "2002:c7c7:c7c8::"

    ## ===========================================
    ## User-defined Setting: ANOMALY DETECTION: Use this Boolean to enable DNS/DoH anomaly detection, including:
    ## Ref: Real time detection of malicious DoH traffic using statistical analysis: https://www.sciencedirect.com/science/article/pii/S1389128623003559
    ##
    ##  - Anomaly Conditions:
    ##      - Unsually long domain name in query
    ##      - Uncommon record types in query
    ##  - Anomaly Actions (select one of these for each anomaly condition):
    ##      - dryrun        --> Dry Run action (just log)
    ##      - drop          --> Drop the request or response (depending on anomaly condition)
    ##      - blackhole     --> Blackhole the response
    ##      - sinkhole      --> Sinkhole the response
    ## ===========================================
    set static::DOH_ANOMALY_DETECTION_ENABLE 0

    ## ===========================================
    ## User-defined Setting: ANOMALY CONDITION: LONG DOMAIN: Enter an integer value here to indicate the maximum character length for a domain
    ##  Default: > 52 characters
    ##  Disable: 0
    ## ===========================================
    set static::DOH_ANOMALY_CONDITION_LONG_DOMAIN_ACTION "dryrun"
    set static::DOH_ANOMALY_CONDITION_LONG_DOMAIN 52

    ## ===========================================
    ## User-defined Setting: ANOMALY CONDITION: UNCOMMON RECORD TYPES: Enter a list of flagged record types
    ##  Default: {"NULL" "NAPTR"}
    ##  Disable: {""}
    ## ===========================================
    set static::DOH_ANOMALY_CONDITION_UNCOMMON_TYPE_ACTION "dryrun"
    set static::DOH_ANOMALY_CONDITION_UNCOMMON_TYPE {"NULL" "NAPTR"}

    ##############################################
    ## INTERNAL ##################################
    ##############################################

    ## DNS CODES
    ## Ref: https://www.iana.org/assignments/dns-parameters/dns-parameters.xhtml
    ## Ref: https://en.wikipedia.org/wiki/List_of_DNS_record_types
    ## array set static::dns_codes { 1 A 2 NS 5 CNAME 6 SOA 10 NULL 12 PTR 13 HINFO 15 MX 16 TXT 17 RP 18 AFSDB 28 AAAA 29 LOC 33 SRV 35 NAPTR 37 CERT 39 DNAME 43 DS 46 RRSIG 47 NSEC 48 DNSKEY 49 DHCID 50 NSEC3 51 NSEC3PARAM 52 TLSA 65 HTTPS 99 SPF 257 CAA }
    array set static::dns_codes {1 A 2 NS 3 MD 4 MF 5 CNAME 6 SOA 7 MB 8 MG 9 MR 10 NULL 11 WKS 12 PTR 13 HINFO 14 MINFO 15 MX 16 TXT 17 RP 18 AFSDB 19 X25 20 ISDN 21 RT 22 NSAP 23 NSAPPTR 24 SIG 25 KEY 26 PX 27 GPOS 28 AAAA 29 LOC 30 NXT 31 EID 32 NIMLOC 33 SRV 34 ATMA 35 NAPTR 36 KX 37 CERT 38 A6 39 DNAME 40 SINK 41 OPT 42 APL 43 DS 44 SSHFP 45 IPSECKEY 46 RRSIG 47 NSEC 48 DNSKEY 49 DHCID 50 NSEC3 51 NSEC3PARAM 52 TLSA 53 SMIMEA 55 HIP 56 NINFO 57 RKEY 58 TALINK 59 CDS 60 CDNSKEY 61 OPENPGPKEY 62 CSYNC 63 ZONEMD 64 SVCB 65 HTTPS 99 SPF 100 UINFO 101 UID 102 GID 103 UNSPEC 104 NID 105 L32 106 L64 107 LP 108 EUI48 109 EUI64 249 TKEY 250 TSIG 251 IXFR 252 AXFR 253 MAILB 254 MAILA 256 URI 257 CAA 259 DOA 32768 TA 32769 DLV}
}

## UTILITY: DOH_LOG
## This procedure consumes the message string, DoH question name, and HSL pool object to generates log messages.
## Inputs:
##  msg:    message string
##  name:   name of the requested host (ex. www.f5labs.com)
##  hsl:    hsl pool if configured, otherwise "none"
proc DOH_LOG { msg name hsl } {
    if { ${static::DOH_LOG_LOCAL} } { log -noname local0. "[IP::client_addr]:[TCP::client_port]-[IP::local_addr]:[TCP::local_port] :: ${msg}: ${name}" }
    if { ${static::DOH_LOG_HSL} ne "none" } { HSL::send ${hsl} "<34>1 [clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%S.000Z}] $static::tcl_platform(machine) sslo - [TMM::cmp_count] - ${msg}: ${name}"}
}

## UTILITY: IP_TO_HEX
## Converts the incoming IP to hex
## Inputs:
##  ver:    IP version (ipv4 or ipv6)
##  ip:     IP address
proc IP_TO_HEX { ver ip } {
    switch -- ${ver} {
        "ipv4" {
            set iplist [split ${ip} "."]
            set ipint [expr { \
                [expr { [lindex ${iplist} 3] }] + \
                [expr { [lindex ${iplist} 2] * 256 }] + \
                [expr { [lindex ${iplist} 1] * 65536 }] + \
                [expr { [lindex ${iplist} 0] * 16777216 }] \
            }]
            return [format %08x ${ipint}]
        }
        "ipv6" {
            return [format %032s [string map {":" ""} $ip]]
        }
    }
}

## UTILITY: SAFE_BASE64_DECODE
## Safely decodes a base64-encoded payload and catches any errors
## Inputs:
##  payload:    base64-encoded payload
proc SAFE_BASE64_DECODE { payload } {
    if { [catch {b64decode "${payload}[expr {[string length ${payload}] % 4 == 0 ? "":[string repeat "=" [expr {4 - [string length ${payload}] % 4}]]}]"} decoded_value] == 0 and ${decoded_value} ne "" } {
        return ${decoded_value}
    } else {
        return 0
    }
}

## DECODE_DNS_REQ
## This procedure consumes the HEX-encoded DoH question and decodes to return the question name and type (A,AAAA,TXT, etc.).
## Inputs:
##  data:   HEX-encoded DNS request data
proc DECODE_DNS_REQ { data } {
    if { [catch { 
        set name "" ; set pos 0 ; set num 0 ; set count 0 ; set typectr 0 ; set type ""
        ## process question
        foreach {i j} [split ${data} ""] {
            scan ${i}${j} %x num
            if { ${typectr} > 0 } {
                append type "${i}${j}"
                if { ${typectr} == 2 } { break }
                incr typectr
            } elseif { ${num} == 0 } {
                ## we're done
                set typectr 1
                #break
            } elseif { ${num} < 31 } {
                set pos 1
                set count ${num}
                append name "."
            } elseif { [expr { ${pos} <= ${count} }] } {
                set char [binary format H* ${i}${j}]
                append name $char
                incr pos
            }
        }
        set name [string range ${name} 1 end]
        ## process qtype
        if { [catch {
            scan ${type} %xx type
            set typestr $static::dns_codes(${type})
        }] } {
            set typestr "UNK"
        } 
    }] } {
        return "error"
    } else {
        return "[string toupper ${typestr}]:${name}"
    }
}

## DOH_BLOCK
## Performs blackhole or sinkhole block on request
## Inputs:
##  block:  type of block --> "blackhole" or "sinkhole"
##  type:   request type --> A, AAAA, or TXT for blackhole, A or AAAA for sinkhole
##  ver:    DoH request version --> WF-GET, WF-POST, or JSON
##  id:     id of the request
##  name:   name of the requested host (ex. www.f5labs.com)
##  hsl:    hsl pool if configured, otherwise "none"
proc DOH_BLOCK { block type ver id name hsl } {
    switch -- ${block} {
        "blackhole" {
            ## Normalize type
            if { [lsearch [list "A" "AAAA" "TXT"] $type] < 0 } { set type "A" }

            switch -- ${type} {
                "A" {
                    if { ${ver} starts_with "WF-" } {
                        ## build DNS A record blackhole response

                        ## insert --> {id},flags(8180),questions(0001),answer-rrs(0001),authority-rrs(0000),addl-rrs(0000)
                        set retstring "${id}81800001000100000000"

                        ## split name into hex values
                        foreach x [split ${name} "."] {
                            append retstring [format %02x [string length ${x}]]
                            foreach y [split ${x} ""] {
                                append retstring [format %02x [scan ${y} %c]]
                            }
                        }

                        ## insert --> 00,A(0001),IN(0001),name(c00c),type(0001),class(0001),ttl(00000012),length(0004)
                        append retstring {0000010001c00c00010001000000120004}

                        ## insert --> 199.199.199.199
                        append retstring {c7c7c7c7}

                        call DOH_LOG "Sending DoH Blackhole for Request" "${type}:${name}" ${hsl}
                        HTTP::respond 200 content [binary format H* ${retstring}] "Content-Type" "application/dns-message" "Access-Control-Allow-Origin" "*"                

                    } elseif { ${ver} eq "JSON" } {
                        set template "\{\"Status\": 0,\"TC\": false,\"RD\": true,\"RA\": true,\"AD\": true,\"CD\": false,\"Question\": \[\{\"name\": \"BLACKHOLE_TEMPLATE\",\"type\": 1 \}\],\"Answer\": \[\{\"name\": \"BLACKHOLE_TEMPLATE\",\"type\":1,\"TTL\": 84078,\"data\": \"199.199.199.199\" \}\]\}"
                        set template [string map [list "BLACKHOLE_TEMPLATE" ${name}] ${template}]
                        call DOH_LOG "Sending DoH Blackhole for Request" "${type}:${name}" ${hsl}
                        HTTP::respond 200 content ${template} "Content-Type" "application/dns-json" "Access-Control-Allow-Origin" "*"
                    }
                }
                "AAAA" {
                    if { ${ver} starts_with "WF-" } {
                        ## build DNS A record blackhole response

                        ## insert --> {id},flags(8180),questions(0001),answer-rrs(0001),authority-rrs(0000),addl-rrs(0000)
                        set retstring "${id}81800001000100000000"

                        ## split name into hex values
                        foreach x [split ${name} "."] {
                            append retstring [format %02x [string length ${x}]]
                            foreach y [split ${x} ""] {
                                append retstring [format %02x [scan ${y} %c]]
                            }
                        }

                        ## insert --> 00,AAAA(001c),IN(0001),name(c00c),type(001c),class(0001),ttl(00000012),length(0010)
                        append retstring {00001c0001c00c001c0001000000120010}

                        ## insert --> 2002:c7c7:c7c7:: (199.199.199.199)
                        append retstring {2002c7c7c7c700000000000000000000}

                        call DOH_LOG "Sending DoH Blackhole for Request" "${type}:${name}" ${hsl}
                        HTTP::respond 200 content [binary format H* ${retstring}] "Content-Type" "application/dns-message" "Access-Control-Allow-Origin" "*"

                    } elseif { ${ver} eq "JSON" } {
                        set template "\{\"Status\": 0,\"TC\": false,\"RD\": true,\"RA\": true,\"AD\": true,\"CD\": false,\"Question\": \[\{\"name\": \"BLACKHOLE_TEMPLATE\",\"type\": 28 \}\],\"Answer\": \[\{\"name\": \"BLACKHOLE_TEMPLATE\",\"type\":28,\"TTL\": 84078,\"data\": \"2002:c7c7:c7c7::\" \}\]\}"
                        set template [string map [list "BLACKHOLE_TEMPLATE" ${name}] ${template}]
                        call DOH_LOG "Sending DoH Blackhole for Request" "${type}:${name}" ${hsl}
                        HTTP::respond 200 content ${template} "Content-Type" "application/dns-json" "Access-Control-Allow-Origin" "*"
                    }
                }
                "TXT" {
                    if { ${ver} starts_with "WF-" } {
                        ## build DNS A record blackhole response

                        ## insert --> {id},flags(8180),questions(0001),answer-rrs(0001),authority-rrs(0000),addl-rrs(0000)
                        set retstring "${id}81800001000100000000"

                        ## split name into hex values
                        foreach x [split ${name} "."] {
                            append retstring [format %02x [string length ${x}]]
                            foreach y [split ${x} ""] {
                                append retstring [format %02x [scan ${y} %c]]
                            }
                        }

                        ## insert --> 00,TXT(0010),IN(0001),name(c00c),type(0010),class(0001),ttl(00000012),length(000c)
                        append retstring {0000100001c00c0010000100000012000c}

                        ## insert --> generic "v=spf1 -all"
                        append retstring {0b763d73706631202d616c6c}

                        call DOH_LOG "Sending DoH Blackhole for Request" "${type}:${name}" ${hsl}
                        HTTP::respond 200 content [binary format H* ${retstring}] "Content-Type" "application/dns-message" "Access-Control-Allow-Origin" "*"

                    } elseif { ${ver} eq "JSON" } {
                        set template "\{\"Status\": 0,\"TC\": false,\"RD\": true,\"RA\": true,\"AD\": true,\"CD\": false,\"Question\": \[\{\"name\": \"BLACKHOLE_TEMPLATE\",\"type\": 16 \}\],\"Answer\": \[\{\"name\": \"BLACKHOLE_TEMPLATE\",\"type\":16,\"TTL\": 84078,\"data\": \"v=spf1 -all\" \}\]\}"
                        set template [string map [list "BLACKHOLE_TEMPLATE" ${name}] ${template}]
                        call DOH_LOG "Sending DoH Blackhole for Request" "${type}:${name}" ${hsl}
                        HTTP::respond 200 content ${template} "Content-Type" "application/dns-json" "Access-Control-Allow-Origin" "*"
                    }
                }
            }
        }
        "sinkhole" {
            ## Normalize type
            if { [lsearch [list "A" "AAAA"] $type] < 0 } { set type "A" }

            switch -- ${type} {
                "A" {
                    ## Get sinkhole IP, or use default
                    if { $static::DOH_SINKHOLE_IP4 ne "" } {
                        set ipinjected $static::DOH_SINKHOLE_IP4
                        set iphexinjected [call IP_TO_HEX "ipv4" $static::DOH_SINKHOLE_IP4]
                    } else {
                        set ipinjected "199.199.199.199"
                        set iphexinjected [call IP_TO_HEX "ipv4" "199.199.199.199"]
                    }

                    if { ${ver} starts_with "WF-" } {
                        ## build DNS A record sinkhole response

                        ## insert --> {id},flags(8180),questions(0001),answer-rrs(0001),authority-rrs(0000),addl-rrs(0000)
                        set retstring "${id}81800001000100000000"

                        ## split name into hex values
                        foreach x [split ${name} "."] {
                            append retstring [format %02x [string length ${x}]]
                            foreach y [split ${x} ""] {
                                append retstring [format %02x [scan ${y} %c]]
                            }
                        }

                        ## insert --> 00,A(0001),IN(0001),name(c00c),type(0001),class(0001),ttl(00000012),length(0010)
                        append retstring {0000010001c00c00010001000000120004}

                        ## insert --> answer (ipv4)
                        append retstring ${iphexinjected}

                        call DOH_LOG "Sending DoH Sinkhole for Request" "${type}:${name}" ${hsl}
                        HTTP::respond 200 content [binary format H* ${retstring}] "Content-Type" "application/dns-message" "Access-Control-Allow-Origin" "*"

                    } elseif { ${ver} eq "JSON" } {
                        set template "\{\"Status\": 0,\"TC\": false,\"RD\": true,\"RA\": true,\"AD\": true,\"CD\": false,\"Question\": \[\{\"name\": \"BLACKHOLE_TEMPLATE\",\"type\": 1 \}\],\"Answer\": \[\{\"name\": \"BLACKHOLE_TEMPLATE\",\"type\":1,\"TTL\": 84078,\"data\": \"${ipinjected}\" \}\]\}"
                        set template [string map [list "BLACKHOLE_TEMPLATE" ${name}] ${template}]
                        call DOH_LOG "Sending DoH Sinkhole for Request" "${type}:${name}" ${hsl}
                        HTTP::respond 200 content ${template} "Content-Type" "application/dns-json" "Access-Control-Allow-Origin" "*"
                    }
                }
                "AAAA" {
                    ## Get sinkhole IP, or use default
                    if { $static::DOH_SINKHOLE_IP6 ne "" } {
                        set ipinjected $static::DOH_SINKHOLE_IP6
                        set iphexinjected [call IP_TO_HEX "ipv6" $static::DOH_SINKHOLE_IP6]
                    } else {
                        set ipinjected "2002:c7c7:c7c7::"
                        set iphexinjected [call IP_TO_HEX "ipv6" "2002:c7c7:c7c7::"]
                    }

                    if { ${ver} starts_with "WF-" } {
                        ## build DNS A record sinkhole response

                        ## insert --> {id},flags(8180),questions(0001),answer-rrs(0001),authority-rrs(0000),addl-rrs(0000)
                        set retstring "${id}81800001000100000000"

                        ## split name into hex values
                        foreach x [split ${name} "."] {
                            append retstring [format %02x [string length ${x}]]
                            foreach y [split ${x} ""] {
                                append retstring [format %02x [scan ${y} %c]]
                            }
                        }

                        ## insert --> 00,AAAA(001c),IN(0001),name(c00c),type(001c),class(0001),ttl(00000012),length(0010)
                        append retstring {00001c0001c00c001c0001000000120010}

                        ## insert --> answer (ipv6)
                        append retstring ${iphexinjected}

                        call DOH_LOG "Sending DoH Sinkhole for Request" "${type}:${name}" ${hsl}
                        HTTP::respond 200 content [binary format H* ${retstring}] "Content-Type" "application/dns-message" "Access-Control-Allow-Origin" "*"

                    } elseif { ${ver} eq "JSON" } {
                        set template "\{\"Status\": 0,\"TC\": false,\"RD\": true,\"RA\": true,\"AD\": true,\"CD\": false,\"Question\": \[\{\"name\": \"BLACKHOLE_TEMPLATE\",\"type\": 28 \}\],\"Answer\": \[\{\"name\": \"BLACKHOLE_TEMPLATE\",\"type\":28,\"TTL\": 84078,\"data\": \"${ipinjected}\" \}\]\}"
                        set template [string map [list "BLACKHOLE_TEMPLATE" ${name}] ${template}]
                        call DOH_LOG "Sending DoH Sinkhole for Request" "${type}:${name}" ${hsl}
                        HTTP::respond 200 content ${template} "Content-Type" "application/dns-json" "Access-Control-Allow-Origin" "*"
                    }
                }
            }
        }
    }
}

## DOH_DECIDE_REQ
## Queries against the blockhole or sinkhole categories, or performs general anomaly detection on the DoH request
proc DOH_DECIDE_REQ { ver id name hsl } {

    ## Get request name and type
    set type [lindex [split ${name} ":"] 0]
    set name [lindex [split ${name} ":"] 1]

    ## Set category lookup type
    switch $static::DOH_CATEGORY_TYPE {
        "subscription" { set query_type "request_default" }
        "custom_only" { set query_type "custom"}
        "sub_and_custom" { set query_type "request_default_and_custom" }
        default { set query_type "custom" }
    }

    ## Perform a single category lookup (and test for URLDB errors)
    set cat ""
    if { [catch {
        set cat [CATEGORY::lookup "https://${name}/" ${query_type}]
    } err] } {
        call DOH_LOG "DoH Category Lookup Error: ${err}" "${type}:${name}" ${hsl}
        return
    }

    ## DoH request log
    call DOH_LOG "DoH Query Detected: name=${name},type=${type},version=${ver},id=${id},cat=${cat}" "" ${hsl}

    ## Test for blackhole, sinkhole, or anomaly conditions (mutually exclusive)
    ## - Blackhole currently supports A, AAAA, and TXT records
    ## - Sinkhole supports A and AAAA records
    ## - Anomaly detection + blocking/logging action
    if { ([lsearch -exact $static::DOH_BLACKHOLE_BY_CATEGORY [getfield ${cat} " " 1]] >= 0) } {
        switch -- ${static::DOH_BLACKHOLE_BY_CATEGORY_ACTION} {
            "dryrun" {
                call DOH_LOG "DoH blackhole by category detected (dryrun): " "${type}:${name}" ${hsl}
            }
            default {
                call DOH_BLOCK "blackhole" ${type} ${ver} ${id} ${name} ${hsl}
            }
        }

    } elseif { ([lsearch -exact $static::DOH_SINKHOLE_BY_CATEGORY [getfield ${cat} " " 1]] >= 0) } {
        switch -- ${static::DOH_SINKHOLE_BY_CATEGORY_ACTION} {
            "dryrun" {
                call DOH_LOG "DoH sinkhole by category detected (dryrun): " "${type}:${name}" ${hsl}
            }
            default {
                call DOH_BLOCK "sinkhole" ${type} ${ver} ${id} ${name} ${hsl}
            }
        }

    } elseif { ${static::DOH_ANOMALY_DETECTION_ENABLE} } {
        ## DoH Anomaly: Excessive domain name length
        if { (${static::DOH_ANOMALY_CONDITION_LONG_DOMAIN}) and ([expr [string length ${name}] > ${static::DOH_ANOMALY_CONDITION_LONG_DOMAIN}]) } {
            switch -- ${static::DOH_ANOMALY_CONDITION_LONG_DOMAIN_ACTION} {
                "dryrun" {
                    call DOH_LOG "DoH anomaly detected: Long Domain Name ([string length ${name}] chars) -- dryrun" "${type}:${name}" ${hsl}
                }
                "drop" {
                    call DOH_LOG "DoH anomaly detected: Long Domain Name ([string length ${name}] chars) -- dropping" "${type}:${name}" ${hsl}
                    reject
                }
                "blackhole" {
                    call DOH_LOG "DoH anomaly detected: Long Domain Name ([string length ${name}] chars) -- sending to blackhole" "${type}:${name}" ${hsl}
                    call DOH_BLOCK "blackhole" ${type} ${ver} ${id} ${name} ${hsl}
                }
                "sinkhole" {
                    call DOH_LOG "DoH anomaly detected: Long Domain Name ([string length ${name}] chars) -- sending to sinkhole" "${type}:${name}" ${hsl}
                    call DOH_BLOCK "sinkhole" ${type} ${ver} ${id} ${name} ${hsl}
                }
            }
        }

        ## DoH Anomaly: Uncommon DNS query type
        if { (${static::DOH_ANOMALY_CONDITION_UNCOMMON_TYPE} ne "") and ([lsearch ${static::DOH_ANOMALY_CONDITION_UNCOMMON_TYPE} ${type}] >= 0) } {
            switch -- ${static::DOH_ANOMALY_CONDITION_UNCOMMON_TYPE_ACTION} {
                "dryrun" {
                    call DOH_LOG "DoH anomaly detected: Uncommon Query Type (${type}) -- dryrun" "${type}:${name}" ${hsl}
                }
                "drop" {
                    call DOH_LOG "DoH anomaly detected: Uncommon Query Type (${type}) -- dropping" "${type}:${name}" ${hsl}
                    reject
                }
                "blackhole" {
                    call DOH_LOG "DoH anomaly detected: Uncommon Query Type (${type}) -- sending to blackhole" "${type}:${name}" ${hsl}
                    call DOH_BLOCK "blackhole" ${type} ${ver} ${id} ${name} ${hsl}
                }
                "sinkhole" {
                    call DOH_LOG "DoH anomaly detected: Uncommon Query Type (${type}) -- sending to sinkhole" "${type}:${name}" ${hsl}
                    call DOH_BLOCK "sinkhole" ${type} ${ver} ${id} ${name} ${hsl}
                }
            }
        }
    }
}

when CLIENT_ACCEPTED {
    ## This event establishes HSL connection (as required) and sends reject if destination address is the blackhole IP.
    if { [catch { if { ${static::DOH_LOG_HSL} ne "none" } { set hsl [HSL::open -proto UDP -pool ${static::DOH_LOG_HSL}] } else { set hsl "none" } } err] } { set hsl "none" }
    if { [IP::local_addr] eq "199.199.199.199" } { reject }
    if { [IP::local_addr] eq "0:0:0:0:0:ffff:c7c7:c7c7" } { reject }
}

when HTTP_REQUEST {
    ## Test if this is DoH, and type of DoH

    set is_doh_wire_post 0

    ## Conditions:
    ##  - Basic block and all DoH request types
    ##  - DoH JSON GET
    ##  - DoH WireFrame GET
    ##  - DoH WireFrame POST
    if { ($static::DOH_BLOCKING_BASIC) and \
        ( ( [HTTP::method] equals "GET" and [HTTP::header exists "accept"] and [HTTP::header "accept"] equals "application/dns-json" ) or \
        ( [HTTP::method] equals "GET" and [HTTP::header exists "content-type"] and [HTTP::header "content-type"] equals "application/dns-message" ) or \
        ( [HTTP::method] equals "GET" and [HTTP::header exists "accept"] and [HTTP::header "accept"] equals "application/dns-message" ) or \
        ( [HTTP::method] equals "POST" and [HTTP::header exists "content-type"] and [HTTP::header "content-type"] equals "application/dns-message" ) ) } {
        ## DoH Basic blocking (all request types)
        reject

    } elseif { ( [HTTP::method] equals "GET" and [HTTP::header exists "accept"] and [HTTP::header "accept"] equals "application/dns-json" ) } {
        ## DoH JSON GET request
        set type [string toupper [URI::query [HTTP::uri] type]] ; if { ${type} eq "" } { set type "A" }
        set name [URI::query [HTTP::uri] name] ; if { ${name} ne "" } { 
            # call DOH_LOG "DoH (JSON GET) Request" "${type}:${name}" ${hsl}
            call DOH_DECIDE_REQ "JSON" "null" "${type}:${name}" ${hsl}
        }

    } elseif { ( ( [HTTP::method] equals "GET" and [HTTP::header exists "content-type"] and [HTTP::header "content-type"] equals "application/dns-message" ) \
        or ( [HTTP::method] equals "GET" and [HTTP::header exists "accept"] and [HTTP::header "accept"] equals "application/dns-message" ) ) } {
        ## DoH WireFormat GET request
        if { [set name [URI::query [HTTP::uri] dns]] >= 0 } {
            ## Use this construct to handle potentially missing padding characters
            binary scan [call SAFE_BASE64_DECODE ${name}] H* tmp
            set id [string range ${tmp} 0 3]
            set tmp [string range ${tmp} 24 end]
            if { [set name [call DECODE_DNS_REQ ${tmp}]] ne "error" } {
                # call DOH_LOG "DoH (WireFormat GET) Request" ${name} ${hsl}
                call DOH_DECIDE_REQ "WF-GET" ${id} ${name} ${hsl}
            }
        }

    } elseif { ( [HTTP::method] equals "POST" and [HTTP::header exists "content-type"] and [HTTP::header "content-type"] equals "application/dns-message" ) } {
        ## DoH WireFormat POST request
        set is_doh_wire_post 1
        HTTP::collect 100
    }
}
when HTTP_REQUEST_DATA {
    if { ($is_doh_wire_post) } {
        binary scan [HTTP::payload] H* tmp
        set id [string range ${tmp} 0 3]
        set tmp [string range ${tmp} 24 end]
        if { [set name [call DECODE_DNS_REQ ${tmp}]] ne "error" } {
            # call DOH_LOG "DoH (WireFormat POST) Request" ${name} ${hsl}
            call DOH_DECIDE_REQ "WF-POST" ${id} ${name} ${hsl}
        }
    }
}
DOH_GUARDIAN_RULE_EOF

    cat > "doh-guardian-service" << 'DOH_GUARDIAN_SERVICE_EOF'
{
    "name": "sslo_ob_SERVICE_CREATE_ssloS_DoH_Guard",
    "inputProperties": [
      {
        "id": "f5-ssl-orchestrator-operation-context",
        "type": "JSON",
        "value": {
          "operationType": "CREATE",
          "deploymentType": "SERVICE",
          "deploymentName": "ssloS_DoH_Guard",
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
            "name": "ssloS_DoH_Guard",
            "strictness": false,
            "customService": {
              "name": "ssloS_DoH_Guard",
              "ipFamily": "ipv4",
              "serviceDownAction": "",
              "serviceType": "f5-tenant-restrictions",
              "serviceSpecific": {
                "restrictAccessToTenant": "F5DOH",
                "restrictAccessContext": "F5DOH",
                "subType": "o365",
                "name": "ssloS_DoH_Guard"
              },
              "iRuleList": [
                {
                  "name": "/Common/doh-guardian-rule",
                  "value": "/Common/doh-guardian-rule"
                }
              ]
            },
            "vendorInfo": {
              "name": "F5 SSLO DoH Guardian Service",
              "product": "",
              "model": "",
              "version": ""
            },
            "description": "Type: f5-sslo-doh-guardian",
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
DOH_GUARDIAN_SERVICE_EOF


    ## Create doh-guardian-rule iRule
    step_screen "Install doh-guardian-rule iRule"
    MUTATIONS_STARTED=1
    python3 rule-converter.py doh-guardian-rule
    rule=$(cat doh-guardian-rule.out)
    data="{\"name\":\"doh-guardian-rule\",\"apiAnonymous\":\"${rule}\"}"
    rest_post "doh-guardian-rule iRule created" "/mgmt/tm/ltm/rule" "${data}" \
        || abort "iRule creation failed - cannot continue"
    step_done
    sleep 1


    ## Create SSL Orchestrator doh-guardian inspection service
    step_screen "Create SSL Orchestrator doh-guardian inspection service"
    data="$(cat doh-guardian-service)"
    rest_post "SSLO DoH Guardian inspection service created" "/mgmt/shared/iapp/blocks" "${data}" \
        || abort "iAppsLX block instance creation failed - cannot continue"
    step_done
    sleep 1


    ## Poll the -t-4 virtual every 10 seconds, up to a 60 second ceiling.
    ## The display ticks every second to show the script is alive.
    step_screen "Wait for SSL Orchestrator to build the service"
    POLL_MAX=60
    POLL_ELAPSED=0
    while (( POLL_ELAPSED < POLL_MAX )); do
        if rest_get "/mgmt/tm/ltm/virtual/ssloS_DoH_Guard.app~ssloS_DoH_Guard-t-4"; then
            break
        fi
        for (( tick=1; tick<=10 && POLL_ELAPSED < POLL_MAX; tick++ )); do
            POLL_ELAPSED=$(( POLL_ELAPSED + 1 ))
            printf "\r${C_WHITE}Waiting for service virtual... ${C_BOLD}%d${C_RESET}${C_WHITE}s elapsed${C_RESET}    " "${POLL_ELAPSED}"
            sleep 1
        done
    done
    echo
    (( POLL_ELAPSED >= POLL_MAX )) && abort "Service virtual not ready after ${POLL_MAX}s"
    ok "Service virtual ready (${POLL_ELAPSED}s)"
    step_done
    sleep 1


    ## Replace the iRule list on the -t-4 virtual with only doh-guardian-rule.
    step_screen "Clear rules array on the service virtual"
    rest_patch "rules array cleared" \
        "/mgmt/tm/ltm/virtual/ssloS_DoH_Guard.app~ssloS_DoH_Guard-t-4" \
        '{"rules":[]}' \
        || abort "Failed to clear rules array on service virtual - cannot continue"

    ## Allow mcpd to commit the clear before the set
    step_done
    sleep 5

    step_screen "Attach doh-guardian-rule to the service virtual"
    rest_patch "doh-guardian-rule attached" \
        "/mgmt/tm/ltm/virtual/ssloS_DoH_Guard.app~ssloS_DoH_Guard-t-4" \
        '{"rules":["/Common/doh-guardian-rule"]}' \
        || abort "Failed to attach doh-guardian-rule to service virtual - cannot continue"

    ## Allow mcpd to commit the set before verification
    step_done
    sleep 5

    ## Verify the rules list now contains only doh-guardian-rule
    step_screen "Verify virtual rules list"
    verify_response=$(curl -sk -u "${BIGUSER}" \
        "https://localhost/mgmt/tm/ltm/virtual/ssloS_DoH_Guard.app~ssloS_DoH_Guard-t-4")
    rules_list=$(echo "${verify_response}" | jq -r '.rules[]?' 2>/dev/null)
    if [[ "${rules_list}" == "/Common/doh-guardian-rule" ]]; then
        ok "doh-guardian-rule is the only iRule attached"
    elif [[ -z "${rules_list}" ]]; then
        warn "Rules array is empty - inspect virtual manually"
    else
        warn "Unexpected rules on virtual - inspect manually:"
        echo "${rules_list}" | while read -r r; do
            echo -e "  ${C_YELLOW}*${C_RESET} ${C_WHITE}${r}${C_RESET}"
        done
    fi
    step_done
    sleep 1


    ## ===========================================================================
    ## Optional sinkhole install
    ## ===========================================================================
    clear
    render_banner
    render_progress
    ok "Core DoH Guardian install complete"
    echo
    echo -e "${C_WHITE}Would you also like to install the optional sinkhole components?${C_RESET}"
    echo
    echo -e "${C_WHITE}This will create:${C_RESET}"
    echo -e "${C_WHITE}  - SSL cert/key:     sinkhole-cert (self-signed, empty Subject)${C_RESET}"
    echo -e "${C_WHITE}  - LTM client-ssl:   sinkhole-clientssl${C_RESET}"
    echo -e "${C_WHITE}  - LTM virtual:      sinkhole-internal-vip${C_RESET}"
    echo -e "${C_WHITE}  - LTM iRule:        sinkhole-target-rule${C_RESET}"
    echo
    echo -e "${C_WHITE}To install the sinkhole components, type CONFIRM (case sensitive).${C_RESET}"
    echo -e "${C_WHITE}Anything else skips the sinkhole install.${C_RESET}"
    read -p "$(echo -e "${C_WHITE}Confirm: ${C_RESET}")" sinkhole_choice
    echo

    SINKHOLE_INSTALLED=0
    if [[ "${sinkhole_choice}" == "CONFIRM" ]]; then
        SINKHOLE_INSTALLED=1
        INSTALL_TOTAL=12

        ## -----------------------------------------------------------------------
        ## Sinkhole Step 1: Generate cert and key with openssl. The cert has
        ## an empty Subject; SSL Orchestrator forges the SAN at runtime.
        ## -----------------------------------------------------------------------
        step_screen "Generate sinkhole certificate and key"
        openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "sinkhole.key" \
        -out "sinkhole.crt" \
        -subj "/" \
        -config <(printf "[req]\n
    distinguished_name=dn\n
    x509_extensions=v3_req\n
    [dn]\n\n
    [v3_req]\n
    keyUsage=critical,digitalSignature,keyEncipherment\n
    extendedKeyUsage=serverAuth,clientAuth") > /dev/null 2>&1
        if [[ -s "sinkhole.crt" && -s "sinkhole.key" ]]; then
            ok "sinkhole certificate and key generated"
        else
            abort "openssl failed to generate cert/key - cannot continue"
        fi
        step_done
        sleep 1

        ## -----------------------------------------------------------------------
        ## Sinkhole Step 2: Install cert and key to BIG-IP via tmsh cli
        ## transaction.
        ## -----------------------------------------------------------------------
        step_screen "Install sinkhole certificate and key to BIG-IP"
        transaction_output=$( (echo create cli transaction
            echo install sys crypto key sinkhole-cert from-local-file "$(pwd)/sinkhole.key"
            echo install sys crypto cert sinkhole-cert from-local-file "$(pwd)/sinkhole.crt"
            echo submit cli transaction
            ) | tmsh 2>&1 )
        if rest_get "/mgmt/tm/sys/file/ssl-cert/sinkhole-cert" \
            && rest_get "/mgmt/tm/sys/file/ssl-key/sinkhole-cert"; then
            ok "sinkhole-cert certificate and key installed"
        else
            fail "sinkhole-cert install failed"
            [[ -n "${transaction_output}" ]] && echo -e "${C_WHITE}${transaction_output}${C_RESET}"
            abort "tmsh cli transaction failed - cannot continue"
        fi
        step_done
        sleep 1

        ## -----------------------------------------------------------------------
        ## Sinkhole Step 3: Create client-ssl profile.
        ## -----------------------------------------------------------------------
        step_screen "Create sinkhole-clientssl profile"
        tmsh_run "sinkhole-clientssl profile created" \
            tmsh create ltm profile client-ssl sinkhole-clientssl cert sinkhole-cert key sinkhole-cert \
            || abort "client-ssl profile creation failed - cannot continue"
        step_done
        sleep 1

        ## -----------------------------------------------------------------------
        ## Sinkhole Step 4: Create internal virtual server.
        ## -----------------------------------------------------------------------
        step_screen "Create sinkhole-internal-vip virtual server"
        tmsh_run "sinkhole-internal-vip virtual created" \
            tmsh create ltm virtual sinkhole-internal-vip destination 0.0.0.0:9999 profiles replace-all-with { tcp http sinkhole-clientssl } vlans-enabled \
            || abort "virtual server creation failed - cannot continue"
        step_done
        sleep 1

        ## -----------------------------------------------------------------------
        ## Sinkhole Step 5: Create sinkhole-target-rule iRule.
        ## -----------------------------------------------------------------------
        step_screen "Install sinkhole-target-rule iRule"
        rule='when CLIENT_ACCEPTED {\n    virtual \"sinkhole-internal-vip\"\n}\nwhen CLIENTSSL_CLIENTHELLO priority 800 {\n    if {[SSL::extensions exists -type 0]} {\n        binary scan [SSL::extensions -type 0] @9a* SNI\n    }\n\n    if { [info exists SNI] } {\n        SSL::forward_proxy extension 2.5.29.17 \"critical,DNS:${SNI}\"\n    }\n}\nwhen HTTP_REQUEST {\n    HTTP::respond 403 content \"<html><head></head><body><h1>Site Blocked!</h1></body></html>\"\n}\n'
        data="{\"name\":\"sinkhole-target-rule\",\"apiAnonymous\":\"${rule}\"}"
        rest_post "sinkhole-target-rule iRule created" "/mgmt/tm/ltm/rule" "${data}" \
            || abort "sinkhole-target-rule creation failed - cannot continue"
        step_done
        sleep 1

        ## -----------------------------------------------------------------------
        ## Sinkhole Step 6: Clean up local cert/key files
        ## -----------------------------------------------------------------------
        step_screen "Clean up local sinkhole cert/key files"
        rm -f sinkhole.crt sinkhole.key
        ok "local cert/key files removed"
        step_done
        sleep 1
    else
        info "Skipping sinkhole install"
        sleep 1
    fi


    COMPLETED=1

    ## Final completion screen
    clear
    render_banner
    echo -e "${C_BOLD}${C_GREEN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}${C_GREEN}║${C_RESET}  ${C_BOLD}${C_WHITE}Installation Complete${C_RESET}                                       ${C_BOLD}${C_GREEN}║${C_RESET}"
    echo -e "${C_BOLD}${C_GREEN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    echo
    echo -e "${C_WHITE}The following objects were created on the BIG-IP:${C_RESET}"
    echo
    echo -e "  ${C_GREEN}*${C_RESET} ${C_WHITE}LTM iRule:${C_RESET}        doh-guardian-rule"
    echo -e "  ${C_GREEN}*${C_RESET} ${C_WHITE}iAppsLX block:${C_RESET}    ssloS_DoH_Guard"
    if (( SINKHOLE_INSTALLED )); then
        echo -e "  ${C_GREEN}*${C_RESET} ${C_WHITE}SSL cert/key:${C_RESET}     sinkhole-cert"
        echo -e "  ${C_GREEN}*${C_RESET} ${C_WHITE}LTM client-ssl:${C_RESET}   sinkhole-clientssl"
        echo -e "  ${C_GREEN}*${C_RESET} ${C_WHITE}LTM virtual:${C_RESET}      sinkhole-internal-vip"
        echo -e "  ${C_GREEN}*${C_RESET} ${C_WHITE}LTM iRule:${C_RESET}        sinkhole-target-rule"
    else
        echo
        echo -e "${C_WHITE}Sinkhole components were not installed.${C_RESET}"
    fi
    echo
    echo -e "${C_WHITE}Based on Kevin Stewart's original script:${C_RESET}"
    echo -e "${C_WHITE}https://github.com/f5devcentral/sslo-service-extensions/tree/main/doh-guardian${C_RESET}"
    echo
}

## ---------------------------------------------------------------------------
## UNINSTALLER
## ---------------------------------------------------------------------------
uninstall_doh_guardian() {
    INSTALL_TOTAL=9
    echo -e "${C_WHITE}Objects to be removed:${C_RESET}"
    echo -e "${C_WHITE}  - iAppsLX block:    ssloS_DoH_Guard${C_RESET}"
    echo -e "${C_WHITE}  - LTM iRule:        doh-guardian-rule${C_RESET}"
    echo -e "${C_WHITE}  - LTM iRule:        sinkhole-target-rule${C_RESET}"
    echo -e "${C_WHITE}  - LTM virtual:      sinkhole-internal-vip${C_RESET}"
    echo -e "${C_WHITE}  - LTM client-ssl:   sinkhole-clientssl${C_RESET}"
    echo -e "${C_WHITE}  - SSL cert/key:     sinkhole-cert${C_RESET}"
    echo
    echo -e "${C_WHITE}Anything not present will be skipped.${C_RESET}"
    echo
    echo -e "${C_WHITE}To proceed, type CONFIRM (case sensitive). Anything else aborts.${C_RESET}"
    read -p "$(echo -e "${C_WHITE}Confirm: ${C_RESET}")" confirmation
    if [[ "${confirmation}" != "CONFIRM" ]]; then
        abort "Confirmation not received. No changes were made to the BIG-IP."
    fi

        REMOVED=()
        SKIPPED=()
        FAILED=()

        ## -----------------------------------------------------------------------
        ## Phase 1: Discovery
        ## -----------------------------------------------------------------------
        step_screen "Discover existing DoH Guardian components"
        if [[ "${DISCOVERY_CACHED_FOR}" == "doh_guardian" ]]; then
            echo -e "${C_WHITE}Using discovery state from previous install attempt${C_RESET}"
            echo
            DISCOVERY_CACHED_FOR=""
        else
            echo -e "${C_WHITE}Scanning the BIG-IP for existing DoH Guardian components${C_RESET}"
            echo -e "${C_WHITE}This may take a few moments...${C_RESET}"
            echo

            HAS_BLOCK=0
            BLOCK_ID=""
            BLOCK_STATE=""
            HAS_APP_SERVICE=0
            HAS_APP_FOLDER=0
            HAS_T4_VIRTUAL=0
            HAS_DOH_RULE=0
            HAS_SINK_RULE=0
            HAS_SINK_VIRTUAL=0
            HAS_SINK_CLIENTSSL=0
            HAS_SINK_CERT=0
            HAS_SINK_KEY=0

            block_json=$(curl -sk -u "${BIGUSER}" \
                "https://localhost/mgmt/shared/iapp/blocks" \
                | jq -r '.items[]? | select(.name=="ssloS_DoH_Guard") | "\(.id) \(.state)"' 2>/dev/null)
            if [[ -n "${block_json}" ]]; then
                HAS_BLOCK=1
                BLOCK_ID="${block_json%% *}"
                BLOCK_STATE="${block_json##* }"
            fi

            if rest_get "/mgmt/tm/sys/application/service/~Common~ssloS_DoH_Guard.app~ssloS_DoH_Guard"; then
                HAS_APP_SERVICE=1
            fi
            if rest_get "/mgmt/tm/sys/folder/~Common~ssloS_DoH_Guard.app"; then
                HAS_APP_FOLDER=1
            fi
            if rest_get "/mgmt/tm/ltm/virtual/ssloS_DoH_Guard.app~ssloS_DoH_Guard-t-4"; then
                HAS_T4_VIRTUAL=1
            fi
            if rest_get "/mgmt/tm/ltm/rule/doh-guardian-rule"; then
                HAS_DOH_RULE=1
            fi
            if rest_get "/mgmt/tm/ltm/rule/sinkhole-target-rule"; then
                HAS_SINK_RULE=1
            fi
            if rest_get "/mgmt/tm/ltm/virtual/sinkhole-internal-vip"; then
                HAS_SINK_VIRTUAL=1
            fi
            if rest_get "/mgmt/tm/ltm/profile/client-ssl/sinkhole-clientssl"; then
                HAS_SINK_CLIENTSSL=1
            fi
            if rest_get "/mgmt/tm/sys/file/ssl-cert/sinkhole-cert"; then
                HAS_SINK_CERT=1
            fi
            if rest_get "/mgmt/tm/sys/file/ssl-key/sinkhole-cert"; then
                HAS_SINK_KEY=1
            fi
        fi

        echo
        info "Discovery results:"
        if (( HAS_BLOCK )); then
            echo -e "  ${C_WHITE}* iAppsLX block instance:          found (${BLOCK_STATE})${C_RESET}"
        else
            echo -e "  ${C_WHITE}* iAppsLX block instance:          not present${C_RESET}"
        fi
        if (( HAS_APP_SERVICE )); then
            echo -e "  ${C_WHITE}* iAppsLX application service:     found${C_RESET}"
        else
            echo -e "  ${C_WHITE}* iAppsLX application service:     not present${C_RESET}"
        fi
        if (( HAS_APP_FOLDER )); then
            echo -e "  ${C_WHITE}* .app folder:                     found${C_RESET}"
        else
            echo -e "  ${C_WHITE}* .app folder:                     not present${C_RESET}"
        fi
        if (( HAS_T4_VIRTUAL )); then
            echo -e "  ${C_WHITE}* ssloS_DoH_Guard-t-4 virtual:     found${C_RESET}"
        else
            echo -e "  ${C_WHITE}* ssloS_DoH_Guard-t-4 virtual:     not present${C_RESET}"
        fi
        if (( HAS_DOH_RULE )); then
            echo -e "  ${C_WHITE}* doh-guardian-rule iRule:         found${C_RESET}"
        else
            echo -e "  ${C_WHITE}* doh-guardian-rule iRule:         not present${C_RESET}"
        fi
        if (( HAS_SINK_RULE )); then
            echo -e "  ${C_WHITE}* sinkhole-target-rule iRule:      found${C_RESET}"
        else
            echo -e "  ${C_WHITE}* sinkhole-target-rule iRule:      not present${C_RESET}"
        fi
        if (( HAS_SINK_VIRTUAL )); then
            echo -e "  ${C_WHITE}* sinkhole-internal-vip virtual:   found${C_RESET}"
        else
            echo -e "  ${C_WHITE}* sinkhole-internal-vip virtual:   not present${C_RESET}"
        fi
        if (( HAS_SINK_CLIENTSSL )); then
            echo -e "  ${C_WHITE}* sinkhole-clientssl profile:      found${C_RESET}"
        else
            echo -e "  ${C_WHITE}* sinkhole-clientssl profile:      not present${C_RESET}"
        fi
        if (( HAS_SINK_CERT || HAS_SINK_KEY )); then
            echo -e "  ${C_WHITE}* sinkhole-cert cert/key:          found${C_RESET}"
        else
            echo -e "  ${C_WHITE}* sinkhole-cert cert/key:          not present${C_RESET}"
        fi
        echo

        if (( HAS_BLOCK == 0 && HAS_APP_SERVICE == 0 && HAS_APP_FOLDER == 0 \
            && HAS_T4_VIRTUAL == 0 && HAS_DOH_RULE == 0 && HAS_SINK_RULE == 0 \
            && HAS_SINK_VIRTUAL == 0 && HAS_SINK_CLIENTSSL == 0 \
            && HAS_SINK_CERT == 0 && HAS_SINK_KEY == 0 )); then
            ok "Nothing to remove. The BIG-IP is already clean."
            echo
            COMPLETED=1
            return 0
        fi
        step_done
        sleep 2

        ## -----------------------------------------------------------------------
        ## Phase 2: Remove the iAppsLX block instance (if present)
        ## -----------------------------------------------------------------------
        step_screen "Remove the iAppsLX block instance"
        MUTATIONS_STARTED=1
        if (( HAS_BLOCK == 0 )); then
            info "No iAppsLX block instance to remove"
            SKIPPED+=("iAppsLX block instance: ssloS_DoH_Guard")
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
                REMOVED+=("iAppsLX block instance: ssloS_DoH_Guard")
            else
                FAILED+=("iAppsLX block instance: ssloS_DoH_Guard (delete failed)")
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

        if rest_get "/mgmt/tm/sys/application/service/~Common~ssloS_DoH_Guard.app~ssloS_DoH_Guard"; then
            if rest_delete "iAppsLX application service deleted" \
                "/mgmt/tm/sys/application/service/~Common~ssloS_DoH_Guard.app~ssloS_DoH_Guard"; then
                REMOVED+=("iAppsLX application service: ssloS_DoH_Guard")
                sleep_with_countdown 10 "Waiting for .app folder teardown:"
            else
                FAILED+=("iAppsLX application service: ssloS_DoH_Guard (delete failed)")
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
        ## Phase 4: Delete doh-guardian-rule iRule
        ## -----------------------------------------------------------------------
        step_screen "Remove iRule doh-guardian-rule"
        if rest_get "/mgmt/tm/ltm/rule/doh-guardian-rule"; then
            if rest_delete "iRule doh-guardian-rule deleted" \
                "/mgmt/tm/ltm/rule/doh-guardian-rule"; then
                REMOVED+=("LTM iRule: doh-guardian-rule")
            else
                FAILED+=("LTM iRule: doh-guardian-rule")
            fi
        else
            info "iRule doh-guardian-rule not found"
            if (( HAS_DOH_RULE )); then
                REMOVED+=("LTM iRule: doh-guardian-rule")
            else
                SKIPPED+=("LTM iRule: doh-guardian-rule")
            fi
        fi
        step_done
        sleep 1

        ## -----------------------------------------------------------------------
        ## Phase 5: Delete sinkhole-target-rule iRule
        ## -----------------------------------------------------------------------
        step_screen "Remove iRule sinkhole-target-rule"
        if rest_get "/mgmt/tm/ltm/rule/sinkhole-target-rule"; then
            if rest_delete "iRule sinkhole-target-rule deleted" \
                "/mgmt/tm/ltm/rule/sinkhole-target-rule"; then
                REMOVED+=("LTM iRule: sinkhole-target-rule")
            else
                FAILED+=("LTM iRule: sinkhole-target-rule")
            fi
        else
            info "iRule sinkhole-target-rule not found"
            if (( HAS_SINK_RULE )); then
                REMOVED+=("LTM iRule: sinkhole-target-rule")
            else
                SKIPPED+=("LTM iRule: sinkhole-target-rule")
            fi
        fi
        step_done
        sleep 1

        ## -----------------------------------------------------------------------
        ## Phase 6: Delete sinkhole-internal-vip virtual
        ## -----------------------------------------------------------------------
        step_screen "Remove virtual sinkhole-internal-vip"
        if rest_get "/mgmt/tm/ltm/virtual/sinkhole-internal-vip"; then
            if tmsh_run "virtual sinkhole-internal-vip deleted" \
                tmsh delete ltm virtual sinkhole-internal-vip; then
                REMOVED+=("LTM virtual: sinkhole-internal-vip")
            else
                FAILED+=("LTM virtual: sinkhole-internal-vip")
            fi
        else
            info "virtual sinkhole-internal-vip not found"
            if (( HAS_SINK_VIRTUAL )); then
                REMOVED+=("LTM virtual: sinkhole-internal-vip")
            else
                SKIPPED+=("LTM virtual: sinkhole-internal-vip")
            fi
        fi
        step_done
        sleep 1

        ## -----------------------------------------------------------------------
        ## Phase 7: Delete sinkhole-clientssl profile (tmsh)
        ## -----------------------------------------------------------------------
        step_screen "Remove client-ssl profile sinkhole-clientssl"
        if rest_get "/mgmt/tm/ltm/profile/client-ssl/sinkhole-clientssl"; then
            if tmsh_run "client-ssl profile sinkhole-clientssl deleted" \
                tmsh delete ltm profile client-ssl sinkhole-clientssl; then
                REMOVED+=("LTM client-ssl: sinkhole-clientssl")
            else
                FAILED+=("LTM client-ssl: sinkhole-clientssl")
            fi
        else
            info "client-ssl profile sinkhole-clientssl not found"
            if (( HAS_SINK_CLIENTSSL )); then
                REMOVED+=("LTM client-ssl: sinkhole-clientssl")
            else
                SKIPPED+=("LTM client-ssl: sinkhole-clientssl")
            fi
        fi
        step_done
        sleep 1

        ## -----------------------------------------------------------------------
        ## Phase 8: Delete sinkhole-cert certificate and key (tmsh)
        ## -----------------------------------------------------------------------
        step_screen "Remove sinkhole-cert certificate and key"
        cert_removed=0
        key_removed=0

        if rest_get "/mgmt/tm/sys/file/ssl-cert/sinkhole-cert"; then
            if tmsh_run "certificate sinkhole-cert deleted" \
                tmsh delete sys file ssl-cert sinkhole-cert; then
                cert_removed=1
            else
                FAILED+=("SSL cert: sinkhole-cert")
            fi
        else
            info "certificate sinkhole-cert not found"
            (( HAS_SINK_CERT )) && cert_removed=1
        fi

        if rest_get "/mgmt/tm/sys/file/ssl-key/sinkhole-cert"; then
            if tmsh_run "key sinkhole-cert deleted" \
                tmsh delete sys file ssl-key sinkhole-cert; then
                key_removed=1
            else
                FAILED+=("SSL key: sinkhole-cert")
            fi
        else
            info "key sinkhole-cert not found"
            (( HAS_SINK_KEY )) && key_removed=1
        fi

        if (( cert_removed && key_removed )); then
            REMOVED+=("SSL cert/key: sinkhole-cert")
        elif (( HAS_SINK_CERT == 0 && HAS_SINK_KEY == 0 )); then
            SKIPPED+=("SSL cert/key: sinkhole-cert")
        fi
        step_done
        sleep 1

        ## -----------------------------------------------------------------------
        ## Phase 9: Final verification
        ## -----------------------------------------------------------------------
        step_screen "Final verification"
        echo -e "${C_WHITE}Re-scanning the BIG-IP to confirm state${C_RESET}"
        echo -e "${C_WHITE}This may take a few moments...${C_RESET}"
        echo

        LEFTOVERS=()
        rest_get "/mgmt/shared/iapp/blocks" >/dev/null
        if echo "${REST_RESPONSE_BODY}" | jq -e '.items[]? | select(.name=="ssloS_DoH_Guard")' >/dev/null 2>&1; then
            LEFTOVERS+=("iAppsLX block instance: ssloS_DoH_Guard")
        fi
        if rest_get "/mgmt/tm/sys/folder/~Common~ssloS_DoH_Guard.app"; then
            LEFTOVERS+=(".app folder: /Common/ssloS_DoH_Guard.app")
        fi
        if rest_get "/mgmt/tm/ltm/virtual/ssloS_DoH_Guard.app~ssloS_DoH_Guard-t-4"; then
            LEFTOVERS+=("Virtual: ssloS_DoH_Guard-t-4")
        fi
        if rest_get "/mgmt/tm/ltm/rule/doh-guardian-rule"; then
            LEFTOVERS+=("LTM iRule: doh-guardian-rule")
        fi
        if rest_get "/mgmt/tm/ltm/rule/sinkhole-target-rule"; then
            LEFTOVERS+=("LTM iRule: sinkhole-target-rule")
        fi
        if rest_get "/mgmt/tm/ltm/virtual/sinkhole-internal-vip"; then
            LEFTOVERS+=("LTM virtual: sinkhole-internal-vip")
        fi
        if rest_get "/mgmt/tm/ltm/profile/client-ssl/sinkhole-clientssl"; then
            LEFTOVERS+=("LTM client-ssl: sinkhole-clientssl")
        fi
        if rest_get "/mgmt/tm/sys/file/ssl-cert/sinkhole-cert"; then
            LEFTOVERS+=("SSL cert: sinkhole-cert")
        fi
        if rest_get "/mgmt/tm/sys/file/ssl-key/sinkhole-cert"; then
            LEFTOVERS+=("SSL key: sinkhole-cert")
        fi

        if (( ${#LEFTOVERS[@]} == 0 )); then
            ok "All DoH Guardian and sinkhole components removed"
        else
            fail "The following objects are still on the BIG-IP:"
            for o in "${LEFTOVERS[@]}"; do
                echo -e "  ${C_RED}*${C_RESET} ${C_WHITE}${o}${C_RESET}"
                ## Promote any leftovers not already recorded as failed
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

        COMPLETED=1
        return 0
}

## ===========================================================================
## Top-level dispatch
## ===========================================================================
select_extension
prompt_credentials

while true; do
    select_mode
    case "${EXTENSION}-${MODE}" in
        blocking_page-1) install_blocking_page ;;
        blocking_page-2) uninstall_blocking_page ;;
        doh_guardian-1)  install_doh_guardian ;;
        doh_guardian-2)  uninstall_doh_guardian ;;
        *) abort "Internal error: unknown extension/mode combination" ;;
    esac
    rc=$?
    ## A function returning 2 means the user asked to come back to the
    ## install/uninstall menu (existing components found, etc.). Anything
    ## else (success or abort) exits the script.
    (( rc == 2 )) || exit "${rc}"
done

## SCRIPT_SHA256: <unsigned>