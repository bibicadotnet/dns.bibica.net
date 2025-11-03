#!/bin/bash

# ============================================================================
# Optimized Akamai DNS Rewrite Manager for AdGuard Home
# ============================================================================

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# CONFIGURATION - Customize these settings
# ============================================================================

# AdGuard Home credentials
AGH_URL="https://admin.dns.bibica.net"
AGH_USER="xxxxxx"
AGH_PASS="xxxxxxxxxxxxxx"
AUTH="$AGH_USER:$AGH_PASS"

# ECS IP for Vietnam (used for DNS queries)
ECS_IP="14.191.231.0"

# Parallel processing (20 = safe, 30-50 = faster but higher load)
PARALLEL_JOBS=20

# Cache settings
VN_IP_CACHE_AGE=86400       # 24 hours - Vietnam IP ranges cache lifetime
NON_AKAMAI_CACHE_AGE=604800 # 7 days - Non-Akamai domains cache lifetime

# Query log limit (how many recent queries to check)
QUERY_LOG_LIMIT=1000000

# ============================================================================
# INTERNAL VARIABLES - Do not modify
# ============================================================================

# Cache files (stored in same directory as script)
VN_IP_CACHE="${SCRIPT_DIR}/vn_ip_ranges.txt"
NON_AKAMAI_CACHE="${SCRIPT_DIR}/non_akamai_domains.txt"

# Comprehensive Akamai patterns
AKAMAI_PATTERNS="edgesuite\.net|edgekey\.net|akamaiedge\.net|akamaized\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|akamai\.net|akamaitechnologies\.(com|net)"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|akamaihd\.net|akamaistream\.net|akamaitech\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|akam\.net|akadns\.net|akasecure\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|akamaiorigin\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|akamai-staging\.net|akamaiedge-staging\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|akamaihd-staging\.net|akamaiorigin-staging\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|akamaized-staging\.net|edgekey-staging\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|edgesuite-staging\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|com\.akadns\.net|net\.akadns\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|com\.akamaized\.net|net\.akamaized\.net|mdc\.akamaized\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|com\.akamaized-staging\.net|net\.akamaized-staging\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|mdc\.akamaized-staging\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|com\.edgekey\.net|test\.edgekey\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|com\.edgekey-staging\.net|test\.edgekey-staging\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|com\.edgesuite\.net|net\.edgesuite\.net|mdc\.edgesuite\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|com\.edgesuite-staging\.net|net\.edgesuite-staging\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|mdc\.edgesuite-staging\.net"

# ============================================================================
# SETUP: Install grepcidr if not available
# ============================================================================
if ! command -v grepcidr >/dev/null 2>&1; then
    echo "Installing grepcidr..."
    apt-get update && apt-get install -y grepcidr >/dev/null 2>&1
fi

# ============================================================================
# FUNCTION: Download and merge Vietnam IP ranges
# ============================================================================
download_vietnam_ip_ranges() {
    local need_update=false
    
    # Check if cache exists and is fresh
    if [ -f "$VN_IP_CACHE" ]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$VN_IP_CACHE" 2>/dev/null || echo 0)))
        if [ $cache_age -gt $VN_IP_CACHE_AGE ]; then
            need_update=true
        fi
    else
        need_update=true
    fi
    
    if [ "$need_update" = true ]; then
        echo "Downloading Vietnam IP ranges..."
        
        local tmp1="/tmp/vn_source1_$$.txt"
        local tmp2="/tmp/vn_source2_$$.txt"
        
        # Download from both sources
        curl -s "https://www.ipdeny.com/ipblocks/data/countries/vn.zone" > "$tmp1"
        curl -s "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/vn/ipv4-aggregated.txt" > "$tmp2"
        
        # Merge, remove duplicates, sort
        cat "$tmp1" "$tmp2" | grep -v '^#' | grep -v '^$' | sort -u > "$VN_IP_CACHE"
        
        rm -f "$tmp1" "$tmp2"
        
        local count=$(wc -l < "$VN_IP_CACHE")
        echo "Downloaded and merged $count IP ranges"
    else
        local count=$(wc -l < "$VN_IP_CACHE")
        echo "Using cached Vietnam IP ranges ($count ranges)"
    fi
}

# ============================================================================
# FUNCTION: Check if IP is from Vietnam (OFFLINE, using grepcidr)
# ============================================================================
is_vietnam_ip() {
    local ip="$1"
    echo "$ip" | grepcidr -f "$VN_IP_CACHE" >/dev/null 2>&1
    return $?
}

# ============================================================================
# FUNCTION: Check if domain is in non-Akamai cache
# ============================================================================
is_cached_non_akamai() {
    local domain="$1"
    
    if [ ! -f "$NON_AKAMAI_CACHE" ]; then
        return 1
    fi
    
    grep -qx "$domain" "$NON_AKAMAI_CACHE" 2>/dev/null
    return $?
}

# ============================================================================
# FUNCTION: Add domain to non-Akamai cache
# ============================================================================
cache_non_akamai() {
    local domain="$1"
    echo "$domain" >> "$NON_AKAMAI_CACHE"
}

# ============================================================================
# FUNCTION: Clean old non-Akamai cache
# ============================================================================
clean_old_cache() {
    if [ -f "$NON_AKAMAI_CACHE" ]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$NON_AKAMAI_CACHE" 2>/dev/null || echo 0)))
        if [ $cache_age -gt $NON_AKAMAI_CACHE_AGE ]; then
            echo "Cleaning old non-Akamai cache..."
            rm -f "$NON_AKAMAI_CACHE"
        fi
    fi
}

# ============================================================================
# FUNCTION: Check if domain uses Akamai CDN and get Vietnam IP
# ============================================================================
check_akamai_and_get_vn_ip() {
    local domain="$1"
    
    # Check cache first
    if is_cached_non_akamai "$domain"; then
        return 1
    fi
    
    # Query Google DNS with ECS
    local response=$(curl -s -m 5 "https://dns.google/resolve?name=${domain}&type=A&edns_client_subnet=${ECS_IP}" 2>/dev/null)
    
    if [ -z "$response" ]; then
        return 1
    fi
    
    # Check if uses Akamai (CNAME records)
    local has_akamai=$(echo "$response" | jq -r '.Answer[]? | select(.type == 5) | .data' 2>/dev/null | grep -iE "$AKAMAI_PATTERNS")
    
    if [ -z "$has_akamai" ]; then
        # Not Akamai, cache it
        cache_non_akamai "$domain"
        return 1
    fi
    
    # Extract A record IPs
    local ips=$(echo "$response" | jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null)
    
    if [ -z "$ips" ]; then
        return 1
    fi
    
    # Check each IP for Vietnam
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        
        if is_vietnam_ip "$ip"; then
            echo "$ip"
            return 0
        fi
    done <<< "$ips"
    
    return 1
}

# ============================================================================
# FUNCTION: Process single existing rewrite (for parallel processing)
# ============================================================================
process_existing_rewrite() {
    local domain="$1"
    local current_ip="$2"
    
    # Get new Vietnam IP
    local new_ip=$(check_akamai_and_get_vn_ip "$domain")
    
    if [ -z "$new_ip" ]; then
        echo "NO_VN_IP|$domain|$current_ip"
        return
    fi
    
    if [ "$current_ip" = "$new_ip" ]; then
        echo "OK|$domain|$current_ip"
    else
        # Delete old rewrite
        curl -s -u "$AUTH" \
          -X POST \
          -H 'Content-Type: application/json' \
          -d "$(jq -n --arg d "$domain" --arg a "$current_ip" '{domain: $d, answer: $a}')" \
          "$AGH_URL/control/rewrite/delete" > /dev/null 2>&1
        
        # Add new rewrite
        local result=$(curl -s -u "$AUTH" \
          -X POST \
          -H 'Content-Type: application/json' \
          -d "$(jq -n --arg d "$domain" --arg a "$new_ip" '{domain: $d, answer: $a}')" \
          "$AGH_URL/control/rewrite/add" 2>&1)
        
        local error_msg=$(echo "$result" | jq -r '.error // empty' 2>/dev/null)
        if [ -z "$error_msg" ]; then
            echo "UPDATED|$domain|$current_ip|$new_ip"
        else
            echo "ERROR|$domain|$error_msg"
        fi
    fi
}

# ============================================================================
# FUNCTION: Process single new domain (for parallel processing)
# ============================================================================
process_new_domain() {
    local domain="$1"
    
    # Check Akamai and get Vietnam IP
    local vn_ip=$(check_akamai_and_get_vn_ip "$domain")
    
    if [ $? -ne 0 ] || [ -z "$vn_ip" ]; then
        echo "NO_AKAMAI|$domain"
        return
    fi
    
    # Add new rewrite
    local result=$(curl -s -u "$AUTH" \
      -X POST \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg d "$domain" --arg a "$vn_ip" '{domain: $d, answer: $a}')" \
      "$AGH_URL/control/rewrite/add" 2>&1)
    
    local error_msg=$(echo "$result" | jq -r '.error // empty' 2>/dev/null)
    if [ -z "$error_msg" ]; then
        echo "ADDED|$domain|$vn_ip"
    else
        echo "ERROR|$domain|$error_msg"
    fi
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

echo "============================================================================"
echo "Optimized Akamai DNS Rewrite Manager"
echo "============================================================================"
echo ""

# Step 1: Setup
download_vietnam_ip_ranges
clean_old_cache
echo ""

# Step 2: Get existing rewrites
echo "Fetching existing DNS rewrites..."
EXISTING_REWRITES_JSON=$(curl -s -u "$AUTH" "$AGH_URL/control/rewrite/list")
EXISTING_COUNT=$(echo "$EXISTING_REWRITES_JSON" | jq '. | length' 2>/dev/null || echo 0)
echo "Found $EXISTING_COUNT existing rewrites"
echo ""

# Step 3: Update existing rewrites FIRST (Priority) - NOW IN PARALLEL
echo "============================================================================"
echo "PHASE 1: Updating existing rewrites (Priority)"
echo "============================================================================"

if [ $EXISTING_COUNT -eq 0 ]; then
    echo "No existing rewrites to update."
else
    # Prepare existing rewrites for parallel processing
    TEMP_EXISTING="/tmp/agh_existing_$$.txt"
    echo "$EXISTING_REWRITES_JSON" | jq -r '.[] | "\(.domain)|\(.answer)"' 2>/dev/null > "$TEMP_EXISTING"
    
    # Process existing rewrites in parallel
    TEMP_RESULTS_PHASE1="/tmp/agh_results_phase1_$$.txt"
    > "$TEMP_RESULTS_PHASE1"
    
    export -f process_existing_rewrite
    export -f check_akamai_and_get_vn_ip
    export -f is_vietnam_ip
    export -f is_cached_non_akamai
    export -f cache_non_akamai
    export AUTH AGH_URL ECS_IP AKAMAI_PATTERNS VN_IP_CACHE NON_AKAMAI_CACHE
    
    echo "Processing $EXISTING_COUNT existing rewrites in parallel..."
    
    cat "$TEMP_EXISTING" | xargs -P "$PARALLEL_JOBS" -I {} bash -c '
        IFS="|" read -r domain current_ip <<< "{}"
        process_existing_rewrite "$domain" "$current_ip"
    ' >> "$TEMP_RESULTS_PHASE1"
    
    # Count results
    COUNT_OK=$(grep -c "^OK|" "$TEMP_RESULTS_PHASE1" || echo 0)
    COUNT_UPDATED=$(grep -c "^UPDATED|" "$TEMP_RESULTS_PHASE1" || echo 0)
    COUNT_NO_VN_IP=$(grep -c "^NO_VN_IP|" "$TEMP_RESULTS_PHASE1" || echo 0)
    COUNT_ERROR=$(grep -c "^ERROR|" "$TEMP_RESULTS_PHASE1" || echo 0)
    
    # Display results
    while IFS='|' read -r status domain data1 data2; do
        case "$status" in
            OK)
                echo "OK: $domain - $data1"
                ;;
            UPDATED)
                echo "UPDATED: $domain - $data1 -> $data2"
                ;;
            NO_VN_IP)
                echo "NO_VN_IP: $domain - Cannot find Vietnam IP"
                ;;
            ERROR)
                echo "ERROR: $domain - $data1"
                ;;
        esac
    done < "$TEMP_RESULTS_PHASE1"
    
    rm -f "$TEMP_EXISTING" "$TEMP_RESULTS_PHASE1"
    
    echo ""
    echo "Phase 1 Summary:"
    echo "  Already correct: $COUNT_OK"
    echo "  Updated:         $COUNT_UPDATED"
    echo "  No Vietnam IP:   $COUNT_NO_VN_IP"
    echo "  Errors:          $COUNT_ERROR"
    echo ""
fi

# Step 4: Find NEW domains from logs
echo "============================================================================"
echo "PHASE 2: Discovering new Akamai domains from logs"
echo "============================================================================"

echo "Fetching domains from query logs..."
TEMP_DOMAINS="/tmp/agh_domains_$$.txt"

curl -s -u "$AUTH" "$AGH_URL/control/querylog?limit=10000" \
  | jq -r '.data[].question.name' \
  | sed 's/\.$//' \
  | sort -u \
  > "$TEMP_DOMAINS"

TOTAL=$(wc -l < "$TEMP_DOMAINS")
echo "Found $TOTAL unique domains in logs"

# Remove domains that already have rewrites
TEMP_NEW_DOMAINS="/tmp/agh_new_domains_$$.txt"
comm -23 "$TEMP_DOMAINS" <(echo "$EXISTING_REWRITES_JSON" | jq -r '.[].domain' | sort) > "$TEMP_NEW_DOMAINS"

NEW_TOTAL=$(wc -l < "$TEMP_NEW_DOMAINS")
echo "$NEW_TOTAL new domains to check (after removing existing rewrites)"
echo ""

if [ $NEW_TOTAL -eq 0 ]; then
    echo "No new domains to process."
    rm -f "$TEMP_DOMAINS" "$TEMP_NEW_DOMAINS"
    exit 0
fi

# Process new domains in PARALLEL
COUNT_ADDED=0
COUNT_NO_AKAMAI=0
COUNT_ERROR=0

# Export function for parallel processing
export -f process_new_domain

TEMP_RESULTS_PHASE2="/tmp/agh_results_phase2_$$.txt"
> "$TEMP_RESULTS_PHASE2"

echo "Processing $NEW_TOTAL new domains in parallel..."

cat "$TEMP_NEW_DOMAINS" | xargs -P "$PARALLEL_JOBS" -I {} bash -c "process_new_domain '{}'" >> "$TEMP_RESULTS_PHASE2"

# Parse results
while IFS='|' read -r status domain data; do
    case "$status" in
        ADDED)
            echo "ADDED: $domain -> $data"
            COUNT_ADDED=$((COUNT_ADDED + 1))
            ;;
        NO_AKAMAI)
            COUNT_NO_AKAMAI=$((COUNT_NO_AKAMAI + 1))
            ;;
        ERROR)
            echo "ERROR: $domain - $data"
            COUNT_ERROR=$((COUNT_ERROR + 1))
            ;;
    esac
done < "$TEMP_RESULTS_PHASE2"

rm -f "$TEMP_RESULTS_PHASE2"

# Cleanup
rm -f "$TEMP_DOMAINS" "$TEMP_NEW_DOMAINS"

echo ""
echo "Phase 2 Summary:"
echo "  New domains added:    $COUNT_ADDED"
echo "  Not using Akamai:     $COUNT_NO_AKAMAI (cached)"
echo "  Errors:               $COUNT_ERROR"
echo ""

# Final statistics
echo "============================================================================"
echo "COMPLETED!"
echo "============================================================================"
echo "Total rewrites in system: $(curl -s -u "$AUTH" "$AGH_URL/control/rewrite/list" | jq '. | length')"
echo "Non-Akamai cache size:    $(wc -l < "$NON_AKAMAI_CACHE" 2>/dev/null || echo 0) domains"
echo ""
