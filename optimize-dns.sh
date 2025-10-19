#!/bin/bash
# optimize-dns-turbo.sh

API_URL="http://172.18.0.3"
AUTH='username_xxxxxxx:password_xxxxxxx'

SUBNET="103.166.228.0/24"
DNS_SERVERS=("8.8.8.8")
MAX_PARALLEL=30
PING_COUNT=2
PING_TIMEOUT=1

DOMAINS=(
alive.github.com
api.github.com
avatars.githubusercontent.com
codeload.github.com
docs.github.com
github-cloud.s3.amazonaws.com
github.com
github.githubassets.com
raw.githubusercontent.com
release-assets.githubusercontent.com
user-images.githubusercontent.com
)

declare -A PROCESSED_DOMAINS
CURRENT_REWRITES_FILE=$(mktemp)

log() { echo "[$(date '+%H:%M:%S')] $1"; }

fetch_current_rewrites() {
    log "Fetching current rewrites..."
    
    local response=$(curl -s -u "$AUTH" "$API_URL/control/rewrite/list" 2>&1)
    
    > "$CURRENT_REWRITES_FILE"
    
    if [ -z "$response" ] || [ "$response" = "null" ] || [ "$response" = "[]" ]; then
        log "  → No existing rewrites"
        return 0
    fi
    
    if ! echo "$response" | jq -e 'type == "array"' >/dev/null 2>&1; then
        log "  ⚠ Invalid JSON response"
        return 1
    fi
    
    local count=$(echo "$response" | jq -r '.[] | "\(.domain)|\(.answer)"' | tee "$CURRENT_REWRITES_FILE" | wc -l)
    
    if [ "$count" -gt 0 ]; then
        log "  ✓ Loaded $count existing rewrites"
    else
        log "  → No existing rewrites"
    fi
}

has_rewrite() {
    local domain=$1
    local ip=$2
    grep -qF "$domain|$ip" "$CURRENT_REWRITES_FILE" 2>/dev/null
}

delete_all_rewrites_for_domain() {
    local domain=$1
    
    grep "^${domain}|" "$CURRENT_REWRITES_FILE" 2>/dev/null | while IFS='|' read -r dom ip; do
        log "    Deleting old: $dom -> $ip"
        
        curl -s -X POST "$API_URL/control/rewrite/delete" \
            -u "$AUTH" \
            -H "Content-Type: application/json" \
            -d "{\"domain\":\"$dom\",\"answer\":\"$ip\"}" >/dev/null
        
        sleep 0.1
    done
    
    sed -i "/^${domain}|/d" "$CURRENT_REWRITES_FILE" 2>/dev/null
}

query_dns_simple() {
    local domain=$1
    
    for dns in "${DNS_SERVERS[@]}"; do
        local result=$(dig +short @"$dns" "$domain" A +subnet=$SUBNET +time=2 +tries=1 2>/dev/null)
        local ips=$(echo "$result" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        
        if [ -n "$ips" ]; then
            echo "$ips" | head -5
            return 0
        fi
    done
    
    return 1
}

# FIXED: Parse fping output correctly
ping_ip_simple() {
    local ip=$1
    
    if command -v fping &>/dev/null; then
        local result=$(fping -c "$PING_COUNT" -t "$((PING_TIMEOUT * 1000))" -q "$ip" 2>&1)
        
        if echo "$result" | grep -q "min/avg/max"; then
            # Parse: min/avg/max = 236/236/236 hoặc 236.5/237/238
            local latency=$(echo "$result" | grep -oP 'min/avg/max = [0-9.]+/\K[0-9.]+')
            if [ -n "$latency" ]; then
                echo "$latency"
                return 0
            fi
        fi
    else
        local result=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -q "$ip" 2>/dev/null)
        
        if echo "$result" | grep -q "rtt"; then
            local latency=$(echo "$result" | grep -oP 'rtt min/avg/max/mdev = [0-9.]+/\K[0-9.]+')
            if [ -n "$latency" ]; then
                echo "$latency"
                return 0
            fi
        fi
    fi
    
    return 1
}

process_single_domain() {
    local domain=$1
    
    local ips=$(query_dns_simple "$domain")
    if [ -z "$ips" ]; then
        echo "$domain|||NO_IPS"
        return 1
    fi
    
    local best_ip=""
    local best_latency=9999
    
    while read -r ip; do
        [ -z "$ip" ] && continue
        
        local latency=$(ping_ip_simple "$ip" 2>/dev/null)
        if [ -n "$latency" ]; then
            if (( $(echo "$latency < $best_latency" | bc -l 2>/dev/null || echo 0) )); then
                best_latency=$latency
                best_ip=$ip
            fi
        fi
    done <<< "$ips"
    
    if [ -n "$best_ip" ]; then
        echo "$domain|$best_ip|${best_latency}ms"
    else
        local first=$(echo "$ips" | head -1)
        echo "$domain|$first|FALLBACK"
    fi
}

process_domains_parallel() {
    log "Processing ${#DOMAINS[@]} domains (max $MAX_PARALLEL concurrent)..."
    
    local result_file=$(mktemp)
    local pids=()
    
    for domain in "${DOMAINS[@]}"; do
        process_single_domain "$domain" >> "$result_file" &
        pids+=($!)
        
        if [ ${#pids[@]} -ge $MAX_PARALLEL ]; then
            wait "${pids[@]}"
            pids=()
        fi
    done
    
    wait
    
    log "Collecting results..."
    local success=0
    local failed=0
    
    while IFS='|' read -r domain ip info extra; do
        if [ -n "$domain" ]; then
            PROCESSED_DOMAINS["$domain"]="$ip|$info"
            
            if [ "$info" = "NO_IPS" ]; then
                ((failed++))
                log "  ✗ $domain -> No IPs found"
            else
                ((success++))
                log "  ✓ $domain -> $ip ($info)"
            fi
        fi
    done < "$result_file"
    
    rm -f "$result_file"
    log "Results: Success=$success | Failed=$failed"
}

update_rewrites() {
    log "Updating DNS rewrites..."
    
    local updated=0
    local skipped=0
    local failed=0
    
    for domain in "${!PROCESSED_DOMAINS[@]}"; do
        local result="${PROCESSED_DOMAINS[$domain]}"
        IFS='|' read -r ip info <<< "$result"
        
        if [ -z "$ip" ] || [ "$info" = "NO_IPS" ]; then
            ((failed++))
            continue
        fi
        
        if has_rewrite "$domain" "$ip"; then
            ((skipped++))
            log "  → $domain already set to $ip"
            continue
        fi
        
        log "  Processing: $domain -> $ip"
        delete_all_rewrites_for_domain "$domain"
        sleep 0.2
        
        local response=$(curl -s -X POST "$API_URL/control/rewrite/add" \
            -u "$AUTH" \
            -H "Content-Type: application/json" \
            -d "{\"domain\":\"$domain\",\"answer\":\"$ip\"}")
        
        if [ -z "$response" ] || [ "$response" = "null" ]; then
            ((updated++))
            log "  ✓ Added: $domain -> $ip"
            echo "$domain|$ip" >> "$CURRENT_REWRITES_FILE"
        else
            ((failed++))
            log "  ✗ Failed: $response"
        fi
        
        sleep 0.1
    done
    
    echo ""
    log "Summary: Updated=$updated | Skipped=$skipped | Failed=$failed"
}

check_deps() {
    local missing=()
    for cmd in jq dig curl bc; do
        command -v $cmd &>/dev/null || missing+=($cmd)
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log "Installing: ${missing[*]}"
        apt-get update -qq && apt-get install -y -qq "${missing[@]}" dnsutils 2>/dev/null
    fi
    
    if ! command -v fping &>/dev/null; then
        apt-get install -y -qq fping 2>/dev/null || true
    fi
}

cleanup() {
    rm -f "$CURRENT_REWRITES_FILE"
}

trap cleanup EXIT

main() {
    local start=$(date +%s)
    
    echo "========================================"
    echo "Turbo DNS Optimization Script v3.1"
    echo "Domains: ${#DOMAINS[@]} | Parallel: $MAX_PARALLEL"
    echo "========================================"
    
    check_deps
    fetch_current_rewrites
    process_domains_parallel
    update_rewrites
    
    local duration=$(($(date +%s) - start))
    
    echo ""
    echo "========================================"
    echo "✓ Completed in ${duration}s"
    echo "========================================"
}

main
