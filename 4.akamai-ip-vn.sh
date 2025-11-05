#!/bin/bash

# ============================================================================
# Akamai DNS Rewrite Manager - Optimized Version
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# CONFIGURATION
# ============================================================================

AGH_URL="https://xxxxxxxxxxxxxxxx"
AGH_USER="xxxxxxxxx"
AGH_PASS="xxxxxxxxxxxxxxxxx"

ECS_IP="14.191.231.0"

# Performance tuning
DNS_PARALLEL=20
DNS_TIMEOUT=1

# Domains
DOMAINS=(
    "upos-hz-mirrorakam.akamaized.net"
    "v16-webapp-prime.tiktok.com"
)

# Proxies (format: ip:port:user:pass)
PROXIES=(
xxxxxxxx:xxxx:xxxxxx:xxxxx
xxxxxxxx:xxxx:xxxxxx:xxxxx
)

# Files
VN_IP_CACHE="${SCRIPT_DIR}/vn_ip_ranges.txt"
VN_IP_CACHE_AGE=86400

# Temp
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# ============================================================================
# FUNCTIONS
# ============================================================================

update_vn_ip_ranges() {
    local need_update=false
    
    if [[ -f "$VN_IP_CACHE" ]]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$VN_IP_CACHE")))
        [[ $cache_age -gt $VN_IP_CACHE_AGE ]] && need_update=true
    else
        need_update=true
    fi
    
    if [[ "$need_update" == "true" ]]; then
        echo "Updating Vietnam IP ranges..."
        {
            curl -sf "https://www.ipdeny.com/ipblocks/data/countries/vn.zone" 2>/dev/null
            curl -sf "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/vn/ipv4-aggregated.txt" 2>/dev/null
        } | grep -vE '^(#|$)' | sort -u > "$VN_IP_CACHE" || true
        echo "  Cached $(wc -l < "$VN_IP_CACHE" 2>/dev/null || echo 0) IP ranges"
    fi
}

query_single() {
    local query="$1"
    
    if [[ "$query" == "DIRECT"* ]]; then
        # Direct query with ECS
        local domain="${query#DIRECT:}"
        curl -sf -m"$DNS_TIMEOUT" "https://dns.google/resolve?name=${domain}&type=A&edns_client_subnet=${ECS_IP}" 2>/dev/null | \
            jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null || true
    else
        # Proxy query
        IFS=':' read -r domain ip port user pass <<< "$query"
        curl -sf -m3 -x "http://${user}:${pass}@${ip}:${port}" \
            "https://dns.google/resolve?name=${domain}&type=A" 2>/dev/null | \
            jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null || true
    fi
}

export -f query_single
export DNS_TIMEOUT ECS_IP

query_domain_parallel() {
    local domain="$1"
    local all_ips="${TEMP_DIR}/${domain//\//_}_all.txt"
    
    > "$all_ips"
    
    # Generate query list: DIRECT + all proxies
    {
        echo "DIRECT:${domain}"
        for proxy_info in "${PROXIES[@]}"; do
            IFS=':' read -r ip port user pass <<< "$proxy_info"
            echo "${domain}:${ip}:${port}:${user}:${pass}"
        done
    } | xargs -I {} -P "$DNS_PARALLEL" bash -c 'query_single "{}"' >> "$all_ips" 2>/dev/null
    
    # Batch IP validation - single grepcidr call
    if [[ -f "$all_ips" && -s "$all_ips" ]]; then
        cat "$all_ips" | grepcidr -f "$VN_IP_CACHE" 2>/dev/null | sort -u || true
    fi
}

api_call() {
    local action="$1"
    local domain="$2"
    local ip="$3"
    
    curl -sf --connect-timeout 5 --max-time 10 \
        -u "${AGH_USER}:${AGH_PASS}" \
        -X POST \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg d "$domain" --arg a "$ip" '{domain: $d, answer: $a}')" \
        "${AGH_URL}/control/rewrite/${action}" >/dev/null 2>&1
}

# ============================================================================
# MAIN
# ============================================================================

echo "============================================================================"
echo "Akamai DNS Rewrite Manager - Optimized"
echo "============================================================================"
echo

# Check dependencies
missing=()
for pkg in grepcidr jq; do 
    command -v "$pkg" >/dev/null || missing+=("$pkg")
done

if [[ ${#missing[@]} -ne 0 ]]; then
    echo "Installing dependencies: ${missing[*]}"
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y "${missing[@]}" >/dev/null 2>&1
fi

echo "Domains: ${#DOMAINS[@]}"
for d in "${DOMAINS[@]}"; do echo "  - $d"; done
echo

echo "Proxies: ${#PROXIES[@]}"
echo "Parallel queries: $DNS_PARALLEL"
echo "DNS timeout: ${DNS_TIMEOUT}s"
echo

# Update VN IP cache
update_vn_ip_ranges
echo

# Step 1: Get current rewrites from AdGuard
echo "Step 1: Fetching current rewrites from AdGuard..."
CURRENT_FILE="${TEMP_DIR}/current.txt"
curl -sf -u "${AGH_USER}:${AGH_PASS}" "${AGH_URL}/control/rewrite/list" 2>/dev/null | \
    jq -r '.[] | select(.domain == "'"${DOMAINS[0]}"'" or .domain == "'"${DOMAINS[1]}"'") | "\(.domain) \(.answer)"' 2>/dev/null | \
    sort -u > "$CURRENT_FILE" || true

echo "  Current entries: $(wc -l < "$CURRENT_FILE" 2>/dev/null || echo 0)"
echo

# Step 2: Parallel DNS queries for all domains
echo "Step 2: Querying DNS for Vietnam IPs (parallel)..."
DESIRED_FILE="${TEMP_DIR}/desired.txt"
> "$DESIRED_FILE"

# Process domains in parallel
for domain in "${DOMAINS[@]}"; do
    echo "  Querying: $domain"
    query_domain_parallel "$domain" | while read -r ip; do
        echo "$domain $ip" >> "$DESIRED_FILE"
    done &
done

wait

sort -u "$DESIRED_FILE" -o "$DESIRED_FILE"
echo "  Found entries: $(wc -l < "$DESIRED_FILE" 2>/dev/null || echo 0)"
echo

# Step 3: Compare and determine actions
echo "Step 3: Comparing..."
TO_ADD="${TEMP_DIR}/to_add.txt"
TO_DELETE="${TEMP_DIR}/to_delete.txt"

# What to ADD: in DESIRED but not in CURRENT
comm -23 "$DESIRED_FILE" "$CURRENT_FILE" 2>/dev/null > "$TO_ADD" || true

# What to DELETE: in CURRENT but not in DESIRED  
comm -13 "$DESIRED_FILE" "$CURRENT_FILE" 2>/dev/null > "$TO_DELETE" || true

ADD_COUNT=$(wc -l < "$TO_ADD" 2>/dev/null || echo 0)
DELETE_COUNT=$(wc -l < "$TO_DELETE" 2>/dev/null || echo 0)
KEEP_COUNT=$(comm -12 "$DESIRED_FILE" "$CURRENT_FILE" 2>/dev/null | wc -l 2>/dev/null || echo 0)

echo "  Keep: $KEEP_COUNT"
echo "  Add: $ADD_COUNT"
echo "  Delete: $DELETE_COUNT"
echo

# Step 4: Apply changes sequentially (protect VPS)
if [[ $ADD_COUNT -eq 0 && $DELETE_COUNT -eq 0 ]]; then
    echo "No changes needed."
    exit 0
fi

if [[ $DELETE_COUNT -gt 0 ]]; then
    echo "Deleting $DELETE_COUNT entries..."
    while read -r domain ip; do
        echo "  DELETE: $domain -> $ip"
        api_call "delete" "$domain" "$ip" || true
    done < "$TO_DELETE"
fi

if [[ $ADD_COUNT -gt 0 ]]; then
    echo "Adding $ADD_COUNT entries..."
    while read -r domain ip; do
        echo "  ADD: $domain -> $ip"
        api_call "add" "$domain" "$ip" || true
    done < "$TO_ADD"
fi

echo
echo "============================================================================"
echo "COMPLETED!"
echo "============================================================================"
