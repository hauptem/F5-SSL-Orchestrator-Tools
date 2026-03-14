#!/bin/bash
#===============================================================================
# TLS Recon Tester v1.0
#
# Tests TCP and TLS handshakes against multiple ports.
# Supports IPv4, IPv6
#
# Requirements: bash 4.0+, netcat (nc), openssl
# Usage: ./tls-recon-tester.sh
#
# Repository: https://github.com/hauptem/F5-SSL-Orchestrator-Tools
#===============================================================================

set -o pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------

# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
CYAN='\033[0;36m'
NC='\033[0m'

# Timeout for TCP connections (override with TIMEOUT env var)
DEFAULT_TIMEOUT=2
TIMEOUT=${TIMEOUT:-$DEFAULT_TIMEOUT}

# Persistent state for repeat tests
LAST_TARGET=""
LAST_SNI=""
LAST_PORTS=""

#-------------------------------------------------------------------------------
# Output Helpers
#-------------------------------------------------------------------------------

print_banner() {
    echo -e "${CYAN}"
    echo "============================================"
    echo "         TLS Recon Tester v1.0"
    echo "         F5 SSLO Validation Tool"
    echo "============================================"
    echo -e "${NC}"
}

print_footer() {
    echo ""
    echo -e "${WHITE}TLS Recon is part of the SSLO Tools repository${NC}"
    echo -e "${WHITE}https://github.com/hauptem/F5-SSL-Orchestrator-Tools${NC}"
    echo ""
}

print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_success() { echo -e "${GREEN}[OK]${NC} $1" >&2; }
print_info() { echo -e "${WHITE}[INFO]${NC} $1" >&2; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }

#-------------------------------------------------------------------------------
# Dependency Check
#-------------------------------------------------------------------------------

check_dependencies() {
    local missing=()
    
    for cmd in nc openssl; do
        command -v $cmd &>/dev/null || missing+=("$cmd")
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        print_error "Missing required dependencies: ${missing[*]}"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# Input Validation
#-------------------------------------------------------------------------------

# Validates IPv4, IPv6, or RFC 1123 hostname
validate_target() {
    local target="$1"
    
    if [ -z "$target" ]; then
        print_error "Target cannot be empty"
        return 1
    fi
    
    # IPv4
    if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local IFS='.'
        read -ra octets <<< "$target"
        for octet in "${octets[@]}"; do
            if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
                print_error "Invalid IPv4 address: octet $octet out of range"
                return 1
            fi
        done
        return 0
    fi
    
    # IPv6
    if [[ "$target" =~ ^[0-9a-fA-F:]+$ ]]; then
        return 0
    fi
    
    # Hostname (RFC 1123)
    if [[ "$target" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi
    
    print_error "Invalid target: must be a valid IP address or hostname"
    return 1
}

# Validates RFC 1123 hostname for SNI
validate_sni() {
    local sni="$1"
    
    if [ -z "$sni" ]; then
        print_error "SNI cannot be empty"
        return 1
    fi
    
    if [[ "$sni" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi
    
    print_error "Invalid SNI: must be a valid hostname"
    return 1
}

# Validates single port (1-65535)
validate_single_port() {
    local port="$1"
    
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        print_error "Invalid port: '$port' is not a number"
        return 1
    fi
    
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        print_error "Invalid port: $port is out of range (1-65535)"
        return 1
    fi
    
    return 0
}

# Validates and normalizes port list (comma or space separated)
validate_port_list() {
    local ports_input="$1"
    
    if [ -z "$ports_input" ]; then
        print_error "Ports cannot be empty"
        return 1
    fi
    
    # Normalize to space-separated
    local normalized
    normalized=$(echo "$ports_input" | tr ',' ' ' | tr -s ' ')
    
    for port in $normalized; do
        validate_single_port "$port" || return 1
    done
    
    echo "$normalized"
    return 0
}

#-------------------------------------------------------------------------------
# User Prompts
#-------------------------------------------------------------------------------

# Prompts for target with optional default from previous run
prompt_target() {
    local target prompt_text
    
    while true; do
        if [ -n "$LAST_TARGET" ]; then
            prompt_text="Enter target IP or hostname [${LAST_TARGET}]: "
        else
            prompt_text="Enter target IP or hostname: "
        fi
        
        read -rp "$prompt_text" target
        
        if [ -z "$target" ] && [ -n "$LAST_TARGET" ]; then
            echo "$LAST_TARGET"
            return 0
        fi
        
        validate_target "$target" && { echo "$target"; return 0; }
    done
}

# Prompts for SNI with optional default from previous run
prompt_sni() {
    local sni prompt_text
    
    while true; do
        if [ -n "$LAST_SNI" ]; then
            prompt_text="Enter SNI hostname [${LAST_SNI}]: "
        else
            prompt_text="Enter SNI hostname: "
        fi
        
        read -rp "$prompt_text" sni
        
        if [ -z "$sni" ] && [ -n "$LAST_SNI" ]; then
            echo "$LAST_SNI"
            return 0
        fi
        
        validate_sni "$sni" && { echo "$sni"; return 0; }
    done
}

# Prompts for test type selection
prompt_test_type() {
    local choice
    
    echo "" >&2
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "${CYAN}              TEST TYPE${NC}" >&2
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo "" >&2
    echo -e "  ${WHITE}[1] TCP  - TCP handshake only${NC}" >&2
    echo -e "  ${WHITE}[2] TLS  - TLS handshake only${NC}" >&2
    echo -e "  ${WHITE}[3] Both - TCP and TLS handshakes${NC}" >&2
    echo "" >&2
    
    while true; do
        read -rp "Select test type [1/2/3]: " choice
        case "$choice" in
            1) echo "tcp"; return 0 ;;
            2) echo "tls"; return 0 ;;
            3) echo "both"; return 0 ;;
            *) print_error "Invalid selection. Enter 1, 2, or 3." ;;
        esac
    done
}

# Prompts for port input method and collects ports
prompt_ports() {
    local method ports="" port_count
    
    echo "" >&2
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "${CYAN}           PORT INPUT METHOD${NC}" >&2
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo "" >&2
    echo -e "  ${WHITE}[1] Interactive - enter ports one at a time${NC}" >&2
    echo -e "  ${WHITE}[2] Batch       - enter comma or space separated list${NC}" >&2
    
    if [ -n "$LAST_PORTS" ]; then
        port_count=$(echo "$LAST_PORTS" | wc -w)
        echo -e "  ${WHITE}[3] Reuse       - use previous port list ($port_count ports)${NC}" >&2
    fi
    
    echo "" >&2
    
    while true; do
        if [ -n "$LAST_PORTS" ]; then
            read -rp "Select method [1/2/3]: " method
        else
            read -rp "Select method [1/2]: " method
        fi
        
        case "$method" in
            1) ports=$(prompt_ports_interactive); break ;;
            2) ports=$(prompt_ports_batch); break ;;
            3)
                if [ -n "$LAST_PORTS" ]; then
                    print_success "Using previous port list" >&2
                    ports="$LAST_PORTS"
                    break
                else
                    print_error "Invalid selection. Enter 1 or 2."
                fi
                ;;
            *)
                if [ -n "$LAST_PORTS" ]; then
                    print_error "Invalid selection. Enter 1, 2, or 3."
                else
                    print_error "Invalid selection. Enter 1 or 2."
                fi
                ;;
        esac
    done
    
    echo "$ports"
}

# Interactive port entry (one at a time)
prompt_ports_interactive() {
    local ports="" port count=0
    
    echo "" >&2
    print_info "Enter ports one at a time. Type 'done' when finished."
    echo "" >&2
    
    while true; do
        if [ $count -eq 0 ]; then
            read -rp "Enter port: " port
        else
            read -rp "Enter port (or 'done' to finish): " port
        fi
        
        case "$port" in
            [Dd][Oo][Nn][Ee]|[Dd])
                if [ $count -eq 0 ]; then
                    print_error "You must enter at least one port"
                    continue
                fi
                break
                ;;
            "")
                if [ $count -eq 0 ]; then
                    print_error "You must enter at least one port"
                else
                    print_warn "Empty input ignored. Type 'done' to finish."
                fi
                continue
                ;;
        esac
        
        if validate_single_port "$port"; then
            if echo "$ports" | grep -qw "$port"; then
                print_warn "Port $port already added, skipping duplicate"
            else
                ports="$ports $port"
                count=$((count + 1))
                print_success "Added port $port ($count ports total)"
            fi
        fi
    done
    
    echo "${ports# }"
}

# Batch port entry (comma or space separated)
prompt_ports_batch() {
    local ports_input validated_ports
    
    echo "" >&2
    while true; do
        echo -e "${WHITE}Enter ports (comma or space separated):${NC}" >&2
        read -rp "> " ports_input
        
        validated_ports=$(validate_port_list "$ports_input")
        if [ $? -eq 0 ]; then
            validated_ports=$(echo "$validated_ports" | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ')
            local count
            count=$(echo "$validated_ports" | wc -w)
            print_success "Validated $count ports"
            echo "${validated_ports% }"
            return 0
        fi
    done
}

#-------------------------------------------------------------------------------
# Test Functions
#-------------------------------------------------------------------------------

# Runs parallel TCP connection tests using netcat
run_tcp_test() {
    local target="$1"
    local ports="$2"
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}              TCP HANDSHAKE TEST${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local results_file
    results_file=$(mktemp)
    
    (
    for port in $ports; do
        (
            result=$(nc -zv -w "$TIMEOUT" "$target" "$port" 2>&1)
            if echo "$result" | grep -qE "(succeeded|open)"; then
                printf "${GREEN}[OPEN]${NC} TCP port %05d\n" "$port" >> "$results_file"
            elif echo "$result" | grep -q "refused"; then
                printf "${RED}[REFUSED]${NC} TCP port %05d\n" "$port" >> "$results_file"
            elif echo "$result" | grep -q "timed out"; then
                printf "${YELLOW}[TIMEOUT]${NC} TCP port %05d\n" "$port" >> "$results_file"
            else
                printf "${RED}[FAILED]${NC} TCP port %05d\n" "$port" >> "$results_file"
            fi
        ) &
    done
    wait
    )
    
    sort -t' ' -k4 "$results_file" | sed 's/port 0*/port /g'
    rm -f "$results_file"
}

# Initiates TLS handshakes using openssl s_client
run_tls_test() {
    local target="$1"
    local sni="$2"
    local ports="$3"
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}              TLS HANDSHAKE TEST${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    for port in $ports; do
        echo -e "${GREEN}[INIT]${NC} TLS handshake initiated on port $port"
        echo | openssl s_client -connect "$target:$port" -servername "$sni" &>/dev/null &
    done
    wait
}

# Displays test summary
print_summary() {
    local target="$1"
    local sni="$2"
    local ports="$3"
    local test_type="$4"
    local port_count
    port_count=$(echo "$ports" | wc -w)
    
    local test_label
    case "$test_type" in
        tcp)  test_label="TCP only" ;;
        tls)  test_label="TLS only" ;;
        both) test_label="TCP + TLS" ;;
    esac
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}                 SUMMARY${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${WHITE}Target:      ${GREEN}$target${NC}"
    echo -e "${WHITE}SNI:         ${GREEN}$sni${NC}"
    echo -e "${WHITE}Ports:       ${GREEN}$port_count${NC} ports tested"
    echo -e "${WHITE}Test Type:   ${GREEN}$test_label${NC}"
    echo -e "${WHITE}Timeout:     ${GREEN}${TIMEOUT}s${NC}"
    echo -e "${WHITE}Timestamp:   ${GREEN}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Prompts user to run another test
run_again_prompt() {
    echo ""
    read -rp "Run another test? (y/n): " again
    case "$again" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

#-------------------------------------------------------------------------------
# Main Entry Point
#-------------------------------------------------------------------------------

main() {
    clear
    print_banner
    check_dependencies
    
    while true; do
        # Collect inputs
        TARGET=$(prompt_target)
        LAST_TARGET="$TARGET"
        
        SNI=$(prompt_sni)
        LAST_SNI="$SNI"
        
        TEST_TYPE=$(prompt_test_type)
        
        PORTS=$(prompt_ports)
        LAST_PORTS="$PORTS"
        
        # Confirm configuration
        echo ""
        print_info "Configuration:"
        echo -e "  ${WHITE}Target:    $TARGET${NC}"
        echo -e "  ${WHITE}SNI:       $SNI${NC}"
        echo -e "  ${WHITE}Test Type: $TEST_TYPE${NC}"
        echo -e "  ${WHITE}Ports:     $PORTS${NC}"
        echo ""
        
        read -rp "Proceed with tests? (y/n): " confirm
        case "$confirm" in
            [Yy]|[Yy][Ee][Ss]) ;;
            *) print_warn "Aborted by user"; continue ;;
        esac
        
        # Execute selected tests
        case "$TEST_TYPE" in
            tcp)  run_tcp_test "$TARGET" "$PORTS" ;;
            tls)  run_tls_test "$TARGET" "$SNI" "$PORTS" ;;
            both)
                run_tcp_test "$TARGET" "$PORTS"
                run_tls_test "$TARGET" "$SNI" "$PORTS"
                ;;
        esac
        
        print_summary "$TARGET" "$SNI" "$PORTS" "$TEST_TYPE"
        
        # Prompt for another test or exit
        if ! run_again_prompt; then
            print_info "Goodbye!"
            print_footer
            exit 0
        fi
        
        clear
        print_banner
    done
}

# Handle Ctrl+C gracefully
trap 'echo ""; print_warn "Interrupted"; print_footer; exit 130' INT

main "$@"