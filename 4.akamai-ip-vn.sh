#!/bin/bash

# ============================================================================
# Akamai DNS Rewrite Manager - Simplified Edition
# Manages specific domains only - Fast & Lightweight
# ============================================================================

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# CONFIGURATION
# ============================================================================

AGH_URL="https://admin.dns.bibica.net"
AGH_USER="xxxxxxxxxxxxxxxxx"
AGH_PASS="xxxxxxxxxxxxxxxxxxxxxxxxxxx"

ECS_IP="14.191.231.0"

# Files
DOMAINS_FILE="${SCRIPT_DIR}/domains.txt"
VN_IP_CACHE="${SCRIPT_DIR}/vn_ip_ranges.txt"
VN_IP_CACHE_AGE=86400  # 24 hours

# Parallel jobs
PARALLEL_DNS=20
PARALLEL_API=1

# Temp directory
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# ============================================================================
# FUNCTIONS
# ============================================================================

# Download Vietnam IP ranges
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
            curl -sf "https://www.ipdeny.com/ipblocks/data/countries/vn.zone"
            curl -sf "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/vn/ipv4-aggregated.txt"
        } | grep -vE '^(#|$)' | sort -u > "$VN_IP_CACHE"
        echo "  $(wc -l < "$VN_IP_CACHE") IP ranges cached"
    fi
}

# Check if IP is from Vietnam
is_vn_ip() {
    echo "$1" | grepcidr -f "$VN_IP_CACHE" &>/dev/null
}

# Query DNS and get Vietnam IPs for a domain
get_vn_ips() {
    local domain="$1"
    local response=$(curl -sf -m5 "https://dns.google/resolve?name=${domain}&type=A&edns_client_subnet=${ECS_IP}")
    
    echo "$response" | jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null | \
    while read -r ip; do
        is_vn_ip "$ip" && echo "$ip"
    done | sort -u | tr '\n' ',' | sed 's/,$//'
}

# Apply single API action
api_action() {
    local action="$1"
    local domain="$2"
    local ip="$3"
    
    curl -sf --connect-timeout 5 --max-time 10 \
        -u "${AGH_USER}:${AGH_PASS}" \
        -X POST \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg d "$domain" --arg a "$ip" '{domain: $d, answer: $a}')" \
        "${AGH_URL}/control/rewrite/${action}" &>/dev/null
}

# ============================================================================
# MAIN
# ============================================================================

echo "============================================================================"
echo "Akamai DNS Rewrite Manager - Simplified"
echo "============================================================================"
echo

# Check dependencies
command -v grepcidr >/dev/null || { echo "Installing grepcidr..."; apt-get update && apt-get install -y grepcidr >/dev/null; }
command -v jq >/dev/null || { echo "Error: jq not found"; exit 1; }

# Check domains file
[[ ! -f "$DOMAINS_FILE" ]] && { echo "Error: $DOMAINS_FILE not found"; exit 1; }

# Load domains
mapfile -t DOMAINS < <(grep -vE '^(#|$)' "$DOMAINS_FILE" | sed 's/[[:space:]]*$//')
DOMAIN_COUNT=${#DOMAINS[@]}
[[ $DOMAIN_COUNT -eq 0 ]] && { echo "Error: No domains in $DOMAINS_FILE"; exit 1; }

echo "Domains to manage: $DOMAIN_COUNT"
printf '  - %s\n' "${DOMAINS[@]}"
echo

# Update VN IP ranges
update_vn_ip_ranges
echo

# Get existing rewrites
echo "Fetching existing rewrites..."
REWRITES_JSON=$(curl -sf --connect-timeout 5 --max-time 10 -u "${AGH_USER}:${AGH_PASS}" "${AGH_URL}/control/rewrite/list")

# Build current state map: domain -> IPs
declare -A CURRENT_STATE
while IFS='|' read -r domain ip; do
    [[ -z "$domain" ]] && continue
    CURRENT_STATE["$domain"]+="${ip},"
done < <(echo "$REWRITES_JSON" | jq -r '.[] | "\(.domain)|\(.answer)"' 2>/dev/null)

# Trim trailing commas
for domain in "${!CURRENT_STATE[@]}"; do
    CURRENT_STATE["$domain"]="${CURRENT_STATE[$domain]%,}"
done

echo "  Loaded $(echo "$REWRITES_JSON" | jq '. | length' 2>/dev/null || echo 0) entries"
echo

# Query DNS for all domains (parallel)
echo "Querying DNS for Vietnam IPs..."
export -f get_vn_ips is_vn_ip
export ECS_IP VN_IP_CACHE

DNS_RESULTS="${TEMP_DIR}/dns_results.txt"
printf '%s\n' "${DOMAINS[@]}" | xargs -P "$PARALLEL_DNS" -I {} bash -c 'echo "{}|$(get_vn_ips "{}")"' > "$DNS_RESULTS"

# Build new state map
# Build new state map
declare -A NEW_STATE
while IFS='|' read -r domain ips; do
    [[ -n "$ips" ]] && NEW_STATE["$domain"]="$ips"
done < "$DNS_RESULTS"

# Count results (safe for empty array)
if [[ -v NEW_STATE[@] ]]; then
    echo "  Found Vietnam IPs for ${#NEW_STATE[@]} domains"
else
    echo "  Found Vietnam IPs for 0 domains"
fi

# Compare and build change lists
DELETE_LIST="${TEMP_DIR}/delete.txt"
ADD_LIST="${TEMP_DIR}/add.txt"
> "$DELETE_LIST"
> "$ADD_LIST"

echo "Analyzing changes..."
UNCHANGED=0
UPDATED=0
ADDED=0
DELETED=0

for domain in "${DOMAINS[@]}"; do
    current="${CURRENT_STATE[$domain]:-}"
    new="${NEW_STATE[$domain]:-}"
    
    if [[ -z "$current" && -z "$new" ]]; then
        # No current, no new - skip
        continue
    elif [[ -z "$current" && -n "$new" ]]; then
        # New domain
        IFS=',' read -ra NEW_IPS <<< "$new"
        for ip in "${NEW_IPS[@]}"; do
            echo "$domain|$ip" >> "$ADD_LIST"
        done
        ADDED=$((ADDED + 1))
        echo "  ADD: $domain (${#NEW_IPS[@]} IPs)"
    elif [[ -n "$current" && -z "$new" ]]; then
        # No VN IPs available - delete
        IFS=',' read -ra CURR_IPS <<< "$current"
        for ip in "${CURR_IPS[@]}"; do
            echo "$domain|$ip" >> "$DELETE_LIST"
        done
        DELETED=$((DELETED + 1))
        echo "  DELETE: $domain (no VN IPs)"
    else
        # Compare
        current_sorted=$(echo "$current" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
        new_sorted=$(echo "$new" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
        
        if [[ "$current_sorted" == "$new_sorted" ]]; then
            UNCHANGED=$((UNCHANGED + 1))
        else
            # Find diff
            IFS=',' read -ra CURR_IPS <<< "$current"
            IFS=',' read -ra NEW_IPS <<< "$new"
            
            # To delete: in current but not in new
            for ip in "${CURR_IPS[@]}"; do
                [[ ! " ${NEW_IPS[*]} " =~ " ${ip} " ]] && echo "$domain|$ip" >> "$DELETE_LIST"
            done
            
            # To add: in new but not in current
            for ip in "${NEW_IPS[@]}"; do
                [[ ! " ${CURR_IPS[*]} " =~ " ${ip} " ]] && echo "$domain|$ip" >> "$ADD_LIST"
            done
            
            UPDATED=$((UPDATED + 1))
            DEL_COUNT=$(grep -c "^${domain}|" "$DELETE_LIST" 2>/dev/null || echo 0)
            ADD_COUNT=$(grep -c "^${domain}|" "$ADD_LIST" 2>/dev/null || echo 0)
            echo "  UPDATE: $domain (-${DEL_COUNT} +${ADD_COUNT})"
        fi
    fi
done

echo
echo "Summary: Unchanged=$UNCHANGED, Updated=$UPDATED, Added=$ADDED, Deleted=$DELETED"
echo

# Apply changes
DELETE_COUNT=$(wc -l < "$DELETE_LIST")
ADD_COUNT=$(wc -l < "$ADD_LIST")

if [[ $DELETE_COUNT -eq 0 && $ADD_COUNT -eq 0 ]]; then
    echo "No changes needed."
    exit 0
fi

export -f api_action
export AGH_URL AGH_USER AGH_PASS

if [[ $DELETE_COUNT -gt 0 ]]; then
    echo "Deleting $DELETE_COUNT entries..."
    cat "$DELETE_LIST" | xargs -P "$PARALLEL_API" -I {} bash -c '
        IFS="|" read -r domain ip <<< "{}"
        api_action "delete" "$domain" "$ip"
    '
    echo "  Done"
fi

if [[ $ADD_COUNT -gt 0 ]]; then
    echo "Adding $ADD_COUNT entries..."
    cat "$ADD_LIST" | xargs -P "$PARALLEL_API" -I {} bash -c '
        IFS="|" read -r domain ip <<< "{}"
        api_action "add" "$domain" "$ip"
    '
    echo "  Done"
fi

echo
echo "============================================================================"
echo "COMPLETED!"
echo "============================================================================"
