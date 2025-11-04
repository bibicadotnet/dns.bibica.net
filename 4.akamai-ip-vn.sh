#!/bin/bash

# ============================================================================
# Optimized Akamai DNS Rewrite Manager for AdGuard Home v2.1
# Self-Learning Edition - Auto-discovers and tracks Akamai CNAMEs
# ============================================================================

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# CONFIGURATION - Customize these settings
# ============================================================================

# AdGuard Home credentials
AGH_URL="https://admin.dns.bibica.net"
AGH_USER="xxxxxxxxxxxxxx"
AGH_PASS="xxxxxxxxxxxxxxxxxxxxxxxxxxx"
AUTH="$AGH_USER:$AGH_PASS"

# ECS IP for Vietnam (used for DNS queries)
ECS_IP="14.191.231.0"

# Curl options
CURL_OPTS_DNS="-s -m 5"
CURL_OPTS_API="-s --connect-timeout 5 --max-time 10"

# Parallel processing for DNS checks (can be high - no impact on VPS)
PARALLEL_DNS_JOBS=20

# Parallel processing for API calls to AdGuard Home (keep low to protect VPS)
PARALLEL_API_JOBS=3

# Cache settings
VN_IP_CACHE_AGE=86400       # 24 hours - Vietnam IP ranges cache lifetime

# Query log limit (how many recent queries to check)
QUERY_LOG_LIMIT=1000000

# ============================================================================
# INTERNAL VARIABLES - Do not modify
# ============================================================================

# Create temp directory with auto-cleanup
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT INT TERM

# Cache and database files (stored in same directory as script)
VN_IP_CACHE="${SCRIPT_DIR}/vn_ip_ranges.txt"
AKAMAI_CNAME_DB="${SCRIPT_DIR}/akamai_cnames.db"

# Comprehensive Akamai patterns (for matching CNAME records)
AKAMAI_PATTERNS="edgesuite\.net|edgekey\.net|akamaiedge\.net|akamaized\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|akamai\.net|akamaitechnologies\.(com|net)"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|akamaihd\.net|akamaistream\.net|akamaitech\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|akam\.net|akadns\.net|akasecure\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|akamaiorigin\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|akamai-staging\.net|akamaiedge-staging\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|akamaihd-staging\.net|akamaiorigin-staging\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|akamaized-staging\.net|edgekey-staging\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|edgesuite-staging\.net"

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
        
        local tmp1="$TEMP_DIR/vn_source1.txt"
        local tmp2="$TEMP_DIR/vn_source2.txt"
        
        # Download from both sources
        curl -s "https://www.ipdeny.com/ipblocks/data/countries/vn.zone" > "$tmp1"
        curl -s "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/vn/ipv4-aggregated.txt" > "$tmp2"
        
        # Merge, remove duplicates, sort
        cat "$tmp1" "$tmp2" | grep -v '^#' | grep -v '^$' | sort -u > "$VN_IP_CACHE"
        
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
# FUNCTION: Extract Akamai CNAMEs from DNS response
# ============================================================================
extract_akamai_cnames() {
    local response="$1"
    
    # Extract all CNAME records that match Akamai patterns
    echo "$response" | jq -r '.Answer[]? | select(.type == 5) | .data' 2>/dev/null | \
        grep -iE "$AKAMAI_PATTERNS" | \
        sed 's/\.$//' | \
        sort -u | \
        tr '\n' ',' | \
        sed 's/,$//'
}

# ============================================================================
# FUNCTION: Extract Vietnam IPs from DNS response (deduplicated)
# ============================================================================
extract_vn_ips_from_response() {
    local response="$1"
    
    # Extract A record IPs
    local ips=$(echo "$response" | jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null)
    
    if [ -z "$ips" ]; then
        return 1
    fi
    
    # Collect ALL Vietnam IPs with deduplication
    declare -A seen_ips
    local vn_ips=""
    
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        
        # Skip if already seen
        [ -n "${seen_ips[$ip]}" ] && continue
        
        if is_vietnam_ip "$ip"; then
            seen_ips[$ip]=1
            if [ -z "$vn_ips" ]; then
                vn_ips="$ip"
            else
                vn_ips="$vn_ips,$ip"
            fi
        fi
    done <<< "$ips"
    
    if [ -z "$vn_ips" ]; then
        return 1
    fi
    
    echo "$vn_ips"
    return 0
}

# ============================================================================
# FUNCTION: Load Akamai CNAMEs from database for a domain
# ============================================================================
get_akamai_cnames_from_db() {
    local domain="$1"
    
    if [ ! -f "$AKAMAI_CNAME_DB" ]; then
        return 1
    fi
    
    # Find domain in database and return CNAMEs
    grep "^${domain}|" "$AKAMAI_CNAME_DB" 2>/dev/null | cut -d'|' -f2
}

# ============================================================================
# FUNCTION: Save/Update Akamai CNAMEs to database
# ============================================================================
update_akamai_cnames_in_db() {
    local domain="$1"
    local new_cnames="$2"
    
    [ -z "$new_cnames" ] && return
    
    # Create database if not exists
    touch "$AKAMAI_CNAME_DB"
    
    # Get existing CNAMEs
    local existing_cnames=$(get_akamai_cnames_from_db "$domain")
    
    # Merge CNAMEs (deduplicate)
    local all_cnames=""
    if [ -n "$existing_cnames" ]; then
        all_cnames="${existing_cnames},${new_cnames}"
    else
        all_cnames="$new_cnames"
    fi
    
    # Deduplicate
    all_cnames=$(echo "$all_cnames" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
    
    # Remove old entry if exists
    sed -i "/^${domain}|/d" "$AKAMAI_CNAME_DB" 2>/dev/null
    
    # Add new entry
    echo "${domain}|${all_cnames}" >> "$AKAMAI_CNAME_DB"
}

# ============================================================================
# FUNCTION: Check if domain uses Akamai (from response or database)
# ============================================================================
is_akamai_domain() {
    local domain="$1"
    local response="$2"
    
    # Check if response has Akamai CNAMEs
    if [ -n "$response" ]; then
        local akamai_cnames=$(extract_akamai_cnames "$response")
        if [ -n "$akamai_cnames" ]; then
            return 0
        fi
    fi
    
    # Check if domain is in database
    local db_cnames=$(get_akamai_cnames_from_db "$domain")
    if [ -n "$db_cnames" ]; then
        return 0
    fi
    
    return 1
}

# ============================================================================
# FUNCTION: Check domain and get ALL Vietnam IPs (with self-learning)
# Only processes Akamai domains!
# ============================================================================
check_domain_and_get_vn_ips() {
    local domain="$1"
    
    local all_vn_ips=""
    local is_akamai=false
    
    # STEP 1: Query original domain
    local response=$(curl $CURL_OPTS_DNS "https://dns.google/resolve?name=${domain}&type=A&edns_client_subnet=${ECS_IP}" 2>/dev/null)
    
    if [ -n "$response" ]; then
        # Extract Akamai CNAMEs from response
        local akamai_cnames=$(extract_akamai_cnames "$response")
        
        # If found Akamai CNAMEs, mark as Akamai and save to database
        if [ -n "$akamai_cnames" ]; then
            is_akamai=true
            update_akamai_cnames_in_db "$domain" "$akamai_cnames"
        fi
        
        # Extract VN IPs from response
        local vn_ips=$(extract_vn_ips_from_response "$response")
        if [ -n "$vn_ips" ]; then
            all_vn_ips="$vn_ips"
        fi
    fi
    
    # STEP 2: Check if domain is in database (previously used Akamai)
    local db_cnames=$(get_akamai_cnames_from_db "$domain")
    
    if [ -n "$db_cnames" ]; then
        is_akamai=true
        
        # Query each Akamai CNAME from database
        IFS=',' read -ra CNAME_ARRAY <<< "$db_cnames"
        for cname in "${CNAME_ARRAY[@]}"; do
            [ -z "$cname" ] && continue
            
            local cname_response=$(curl $CURL_OPTS_DNS "https://dns.google/resolve?name=${cname}&type=A&edns_client_subnet=${ECS_IP}" 2>/dev/null)
            
            if [ -n "$cname_response" ]; then
                local cname_vn_ips=$(extract_vn_ips_from_response "$cname_response")
                if [ -n "$cname_vn_ips" ]; then
                    if [ -z "$all_vn_ips" ]; then
                        all_vn_ips="$cname_vn_ips"
                    else
                        all_vn_ips="${all_vn_ips},${cname_vn_ips}"
                    fi
                fi
            fi
        done
    fi
    
    # STEP 3: Only return IPs if domain uses Akamai
    if [ "$is_akamai" = false ]; then
        return 1
    fi
    
    # STEP 4: Deduplicate all collected VN IPs
    if [ -n "$all_vn_ips" ]; then
        all_vn_ips=$(echo "$all_vn_ips" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
        echo "$all_vn_ips"
        return 0
    fi
    
    return 1
}

# ============================================================================
# FUNCTION: Check existing rewrite (DNS check only - no API calls)
# ============================================================================
check_existing_rewrite() {
    local domain="$1"
    local current_ips="$2"
    
    # Get ALL Vietnam IPs (with self-learning, only for Akamai domains)
    local new_ips=$(check_domain_and_get_vn_ips "$domain")
    
    if [ -z "$new_ips" ]; then
        echo "NO_VN_IP|$domain|$current_ips"
        return
    fi
    
    # Sort IPs for comparison
    local current_sorted=$(echo "$current_ips" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
    local new_sorted=$(echo "$new_ips" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
    
    if [ "$current_sorted" = "$new_sorted" ]; then
        echo "OK|$domain|$current_ips"
    else
        echo "UPDATE|$domain|$current_ips|$new_ips"
    fi
}

# ============================================================================
# FUNCTION: Apply API action (for rate-limited execution)
# ============================================================================
apply_api_action() {
    local action="$1"
    local domain="$2"
    local current_ips="$3"  # Comma-separated
    local new_ips="$4"      # Comma-separated
    
    case "$action" in
        UPDATE)
            # Delete ALL existing entries for this domain first, then add all new IPs
            
            # Step 1: Delete all current IPs
            IFS=',' read -ra CURRENT_ARRAY <<< "$current_ips"
            local deleted=0
            for ip in "${CURRENT_ARRAY[@]}"; do
                curl $CURL_OPTS_API -u "$AUTH" \
                  -X POST \
                  -H 'Content-Type: application/json' \
                  -d "$(jq -n --arg d "$domain" --arg a "$ip" '{domain: $d, answer: $a}')" \
                  "$AGH_URL/control/rewrite/delete" > /dev/null 2>&1
                deleted=$((deleted + 1))
            done
            
            # Step 2: Add all new IPs
            IFS=',' read -ra NEW_ARRAY <<< "$new_ips"
            
            local added=0
            local errors=0
            for ip in "${NEW_ARRAY[@]}"; do
                local result=$(curl $CURL_OPTS_API -u "$AUTH" \
                  -X POST \
                  -H 'Content-Type: application/json' \
                  -d "$(jq -n --arg d "$domain" --arg a "$ip" '{domain: $d, answer: $a}')" \
                  "$AGH_URL/control/rewrite/add" 2>&1)
                
                local error_msg=$(echo "$result" | jq -r '.error // empty' 2>/dev/null)
                if [ -z "$error_msg" ]; then
                    added=$((added + 1))
                else
                    errors=$((errors + 1))
                fi
            done
            
            if [ $errors -eq 0 ]; then
                echo "UPDATED|$domain|Removed: $deleted, Added: $added, Total: ${#NEW_ARRAY[@]} IPs"
            else
                echo "ERROR|$domain|Updated with errors: +$added -$deleted !$errors"
            fi
            ;;
            
        ADD)
            # Add all IPs for new domain
            IFS=',' read -ra IP_ARRAY <<< "$current_ips"
            local added=0
            local errors=0
            
            for ip in "${IP_ARRAY[@]}"; do
                local result=$(curl $CURL_OPTS_API -u "$AUTH" \
                  -X POST \
                  -H 'Content-Type: application/json' \
                  -d "$(jq -n --arg d "$domain" --arg a "$ip" '{domain: $d, answer: $a}')" \
                  "$AGH_URL/control/rewrite/add" 2>&1)
                
                local error_msg=$(echo "$result" | jq -r '.error // empty' 2>/dev/null)
                if [ -z "$error_msg" ]; then
                    added=$((added + 1))
                else
                    errors=$((errors + 1))
                fi
            done
            
            if [ $errors -eq 0 ]; then
                echo "ADDED|$domain|${#IP_ARRAY[@]} IPs added: ${IP_ARRAY[*]}"
            else
                echo "ERROR|$domain|Added with errors: +$added !$errors"
            fi
            ;;
    esac
}

# ============================================================================
# FUNCTION: Check new domain (DNS check only - no API calls)
# ============================================================================
check_new_domain() {
    local domain="$1"
    
    # Check domain and get ALL Vietnam IPs (only for Akamai domains)
    local vn_ips=$(check_domain_and_get_vn_ips "$domain")
    
    if [ $? -ne 0 ] || [ -z "$vn_ips" ]; then
        echo "NO_AKAMAI|$domain"
        return
    fi
    
    echo "ADD|$domain|$vn_ips"
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

echo "============================================================================"
echo "Akamai DNS Rewrite Manager - Self-Learning Edition"
echo "============================================================================"
echo ""

# Step 1: Setup
download_vietnam_ip_ranges
echo ""

# Display database stats
if [ -f "$AKAMAI_CNAME_DB" ]; then
    DB_SIZE=$(wc -l < "$AKAMAI_CNAME_DB")
    echo "Akamai CNAME Database: $DB_SIZE domains tracked"
else
    echo "Akamai CNAME Database: Empty (will be built automatically)"
fi
echo ""

# Step 2: Get existing rewrites and group by domain
echo "Fetching existing DNS rewrites..."
EXISTING_REWRITES_JSON=$(curl $CURL_OPTS_API -u "$AUTH" "$AGH_URL/control/rewrite/list")
EXISTING_COUNT=$(echo "$EXISTING_REWRITES_JSON" | jq '. | length' 2>/dev/null || echo 0)

# Group rewrites by domain (multiple IPs per domain)
TEMP_GROUPED_REWRITES="$TEMP_DIR/grouped_rewrites.txt"
> "$TEMP_GROUPED_REWRITES"

echo "$EXISTING_REWRITES_JSON" | jq -r '.[] | "\(.domain)|\(.answer)"' | \
while IFS='|' read -r domain ip; do
    echo "$domain|$ip"
done | sort | \
awk -F'|' '{
    if (domain != $1) {
        if (domain != "") print domain "|" ips
        domain = $1
        ips = $2
    } else {
        ips = ips "," $2
    }
}
END {
    if (domain != "") print domain "|" ips
}' > "$TEMP_GROUPED_REWRITES"

UNIQUE_DOMAINS=$(wc -l < "$TEMP_GROUPED_REWRITES")
echo "Found $EXISTING_COUNT rewrite entries for $UNIQUE_DOMAINS unique domains"
echo ""

# Step 3: Get query log (only non-blocked domains)
echo "Fetching query logs (limit: $QUERY_LOG_LIMIT)..."
QUERY_LOG_JSON=$(curl $CURL_OPTS_API -u "$AUTH" "$AGH_URL/control/querylog?limit=$QUERY_LOG_LIMIT")
echo "Query logs fetched successfully"
echo ""

# Clear logs immediately after fetching
echo "Clearing query logs..."
curl -s -X POST -u "$AUTH" "$AGH_URL/control/querylog_clear" > /dev/null 2>&1
echo "Query logs cleared."
echo ""

# Step 4: PHASE 1 - Check existing rewrites
echo "============================================================================"
echo "PHASE 1: Checking existing rewrites"
echo "============================================================================"

if [ $UNIQUE_DOMAINS -eq 0 ]; then
    echo "No existing rewrites to check."
else
    # Export functions for parallel DNS checks
    export -f check_existing_rewrite
    export -f check_domain_and_get_vn_ips
    export -f is_akamai_domain
    export -f extract_akamai_cnames
    export -f extract_vn_ips_from_response
    export -f is_vietnam_ip
    export -f get_akamai_cnames_from_db
    export -f update_akamai_cnames_in_db
    export ECS_IP
    export AKAMAI_PATTERNS
    export AKAMAI_CNAME_DB
    export VN_IP_CACHE
    export CURL_OPTS_DNS
    
    TEMP_CHECK_RESULTS="$TEMP_DIR/check_results.txt"
    > "$TEMP_CHECK_RESULTS"
    
    echo "Checking $UNIQUE_DOMAINS domains (parallel DNS checks: $PARALLEL_DNS_JOBS)..."
    
    # Run DNS checks in parallel
    cat "$TEMP_GROUPED_REWRITES" | xargs -P "$PARALLEL_DNS_JOBS" -I {} bash -c '
        IFS="|" read -r domain current_ips <<< "{}"
        check_existing_rewrite "$domain" "$current_ips"
    ' >> "$TEMP_CHECK_RESULTS"
    
    # Export function for API calls
    export -f apply_api_action
    export AUTH
    export AGH_URL
    export CURL_OPTS_API
    
    # Separate actions that need API calls
    TEMP_API_ACTIONS="$TEMP_DIR/api_actions.txt"
    > "$TEMP_API_ACTIONS"
    
    grep "^UPDATE|" "$TEMP_CHECK_RESULTS" > "$TEMP_API_ACTIONS" || true
    
    API_ACTION_COUNT=$(wc -l < "$TEMP_API_ACTIONS")
    
    echo "DNS checks completed. Now applying $API_ACTION_COUNT API actions (parallel: $PARALLEL_API_JOBS)..."
    
    TEMP_API_RESULTS="$TEMP_DIR/api_results.txt"
    > "$TEMP_API_RESULTS"
    
    # Apply API actions with rate limiting
    if [ $API_ACTION_COUNT -gt 0 ]; then
        cat "$TEMP_API_ACTIONS" | xargs -P "$PARALLEL_API_JOBS" -I {} bash -c '
            IFS="|" read -r action domain current_ips new_ips <<< "{}"
            apply_api_action "$action" "$domain" "$current_ips" "$new_ips"
        ' >> "$TEMP_API_RESULTS"
    fi
    
    # Count and display results
    COUNT_OK=$(grep -c "^OK|" "$TEMP_CHECK_RESULTS" || echo 0)
    COUNT_UPDATED=$(grep -c "^UPDATED|" "$TEMP_API_RESULTS" || echo 0)
    COUNT_NO_VN_IP=$(grep -c "^NO_VN_IP|" "$TEMP_CHECK_RESULTS" || echo 0)
    COUNT_ERROR=$(grep -c "^ERROR|" "$TEMP_API_RESULTS" || echo 0)
    
    # Display detailed results
    echo ""
    echo "Results:"
    
    # Show OK entries (sample - limit to 10)
    ok_count=0
    while IFS='|' read -r status domain ips && [ $ok_count -lt 10 ]; do
        ip_count=$(echo "$ips" | tr ',' '\n' | wc -l)
        echo "  OK: $domain - $ip_count IPs"
        ok_count=$((ok_count + 1))
    done < <(grep "^OK|" "$TEMP_CHECK_RESULTS" || true)
    
    if [ $COUNT_OK -gt 10 ]; then
        echo "  ... and $((COUNT_OK - 10)) more domains unchanged"
    fi
    
    # Show API results
    while IFS='|' read -r status domain message; do
        case "$status" in
            UPDATED)
                echo "  UPDATED: $domain - $message"
                ;;
            ERROR)
                echo "  ERROR: $domain - $message"
                ;;
        esac
    done < "$TEMP_API_RESULTS"
    
    # Show no VN IP entries (sample - limit to 5)
    no_vn_count=0
    while IFS='|' read -r status domain ips && [ $no_vn_count -lt 5 ]; do
        echo "  NO_VN_IP: $domain - Cannot find Vietnam IP"
        no_vn_count=$((no_vn_count + 1))
    done < <(grep "^NO_VN_IP|" "$TEMP_CHECK_RESULTS" || true)
    
    if [ $COUNT_NO_VN_IP -gt 5 ]; then
        echo "  ... and $((COUNT_NO_VN_IP - 5)) more domains without VN IPs"
    fi
    
    echo ""
    echo "Phase 1 Summary:"
    echo "  Already correct:     $COUNT_OK domains"
    echo "  Updated:             $COUNT_UPDATED domains"
    echo "  No Vietnam IP:       $COUNT_NO_VN_IP domains"
    echo "  Errors:              $COUNT_ERROR domains"
    echo ""
fi

# Step 5: PHASE 2 - Find NEW domains from logs
echo "============================================================================"
echo "PHASE 2: Discovering new Akamai domains from logs"
echo "============================================================================"

echo "Extracting non-blocked domains from query logs..."
TEMP_DOMAINS="$TEMP_DIR/domains.txt"

# Extract domains that are NOT blocked
echo "$QUERY_LOG_JSON" | jq -r '.data[] | select(.reason == "NotFilteredNotFound" or .reason == "NotFilteredAllowList") | .question.name' | sed 's/\.$//' | sort -u > "$TEMP_DOMAINS"

TOTAL=$(wc -l < "$TEMP_DOMAINS")
echo "Found $TOTAL unique non-blocked domains in logs"

# Get existing domains (unique)
TEMP_EXISTING_DOMAINS="$TEMP_DIR/existing_domains.txt"
echo "$EXISTING_REWRITES_JSON" | jq -r '.[].domain' | sort -u > "$TEMP_EXISTING_DOMAINS"

# Remove domains that already have rewrites
TEMP_NEW_DOMAINS="$TEMP_DIR/new_domains.txt"
comm -23 "$TEMP_DOMAINS" "$TEMP_EXISTING_DOMAINS" > "$TEMP_NEW_DOMAINS"

NEW_TOTAL=$(wc -l < "$TEMP_NEW_DOMAINS")
echo "$NEW_TOTAL new domains to check (after removing existing rewrites)"
echo ""

if [ $NEW_TOTAL -eq 0 ]; then
    echo "No new domains to process."
else
    # Export functions for parallel DNS checks
    export -f check_new_domain
    export -f check_domain_and_get_vn_ips
    export -f is_akamai_domain
    export -f extract_akamai_cnames
    export -f extract_vn_ips_from_response
    export -f is_vietnam_ip
    export -f get_akamai_cnames_from_db
    export -f update_akamai_cnames_in_db
    export ECS_IP
    export AKAMAI_PATTERNS
    export AKAMAI_CNAME_DB
    export VN_IP_CACHE
    export CURL_OPTS_DNS

    TEMP_NEW_CHECK_RESULTS="$TEMP_DIR/new_check_results.txt"
    > "$TEMP_NEW_CHECK_RESULTS"

    echo "Checking $NEW_TOTAL new domains (parallel DNS checks: $PARALLEL_DNS_JOBS)..."

    # Run DNS checks in parallel
    cat "$TEMP_NEW_DOMAINS" | xargs -P "$PARALLEL_DNS_JOBS" -I {} bash -c "check_new_domain '{}'" >> "$TEMP_NEW_CHECK_RESULTS"

    # Separate ADD actions
    TEMP_ADD_ACTIONS="$TEMP_DIR/add_actions.txt"
    grep "^ADD|" "$TEMP_NEW_CHECK_RESULTS" > "$TEMP_ADD_ACTIONS" || true

    ADD_ACTION_COUNT=$(wc -l < "$TEMP_ADD_ACTIONS")
    COUNT_NO_AKAMAI=$(grep -c "^NO_AKAMAI|" "$TEMP_NEW_CHECK_RESULTS" || echo 0)

    echo "DNS checks completed. Now adding $ADD_ACTION_COUNT new domains (parallel: $PARALLEL_API_JOBS)..."

    TEMP_ADD_RESULTS="$TEMP_DIR/add_results.txt"
    > "$TEMP_ADD_RESULTS"

    # Export function for API calls
    export -f apply_api_action
    export AUTH
    export AGH_URL
    export CURL_OPTS_API

    # Apply ADD actions with rate limiting
    if [ $ADD_ACTION_COUNT -gt 0 ]; then
        cat "$TEMP_ADD_ACTIONS" | xargs -P "$PARALLEL_API_JOBS" -I {} bash -c '
            IFS="|" read -r action domain ips <<< "{}"
            apply_api_action "$action" "$domain" "$ips" ""
        ' >> "$TEMP_ADD_RESULTS"
    fi

    # Count and display results
    COUNT_ADDED=$(grep -c "^ADDED|" "$TEMP_ADD_RESULTS" || echo 0)
    COUNT_ERROR=$(grep -c "^ERROR|" "$TEMP_ADD_RESULTS" || echo 0)

    echo ""
    echo "Results:"

    # Show added entries
    while IFS='|' read -r status domain message; do
        echo "  ADDED: $domain - $message"
    done < <(grep "^ADDED|" "$TEMP_ADD_RESULTS" || true)

    # Show errors
    while IFS='|' read -r status domain error; do
        echo "  ERROR: $domain - $error"
    done < <(grep "^ERROR|" "$TEMP_ADD_RESULTS" || true)

    echo ""
    echo "Phase 2 Summary:"
    echo "  New domains added:    $COUNT_ADDED domains"
    echo "  Not using Akamai:     $COUNT_NO_AKAMAI domains"
    echo "  Errors:               $COUNT_ERROR domains"
    echo ""
fi

# Final statistics
echo "============================================================================"
echo "COMPLETED!"
echo "============================================================================"

# Display updated database stats
if [ -f "$AKAMAI_CNAME_DB" ]; then
    DB_SIZE=$(wc -l < "$AKAMAI_CNAME_DB")
    echo "Akamai CNAME Database: $DB_SIZE domains tracked"
fi

echo ""
