#!/bin/bash

# ============================================================================
# Optimized Akamai DNS Rewrite Manager for AdGuard Home
# With Multiple Vietnam IPs Support & Blocklist Protection
# ============================================================================

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# CONFIGURATION - Customize these settings
# ============================================================================

# AdGuard Home credentials
AGH_URL="https://admin.dns.bibica.net"
AGH_USER="xxxxxxxx"
AGH_PASS="xxxxxxxxxxxxxxxxxx"
AUTH="$AGH_USER:$AGH_PASS"

# ECS IP for Vietnam (used for DNS queries)
ECS_IP="14.191.231.0"

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

# Cache files (stored in same directory as script)
VN_IP_CACHE="${SCRIPT_DIR}/vn_ip_ranges.txt"

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
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|com\.akadns\.net|net\.akadns\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|com\.akamaized\.net|net\.akamaized\.net|mdc\.akamaized\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|com\.akamaized-staging\.net|net\.akamaized-staging\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|mdc\.akamaized-staging\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|com\.edgekey\.net|test\.edgekey\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|com\.edgekey-staging\.net|test\.edgekey-staging\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|com\.edgesuite\.net|net\.edgesuite\.net|mdc\.edgesuite\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|com\.edgesuite-staging\.net|net\.edgesuite-staging\.net"
AKAMAI_PATTERNS="${AKAMAI_PATTERNS}|mdc\.edgesuite-staging\.net"

# Common Akamai domain suffixes to try when checking existing rewrites
AKAMAI_SUFFIXES="akamaized.net edgesuite.net edgekey.net akamaiedge.net akamaihd.net akadns.net akasecure.net akamaitechnologies.com akamaitechnologies.net"

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
# FUNCTION: Query DNS and extract Vietnam IPs from response
# ============================================================================
extract_vn_ips_from_response() {
    local response="$1"
    
    # Extract A record IPs
    local ips=$(echo "$response" | jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null)
    
    if [ -z "$ips" ]; then
        return 1
    fi
    
    # Collect ALL Vietnam IPs
    local vn_ips=""
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        
        if is_vietnam_ip "$ip"; then
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
# FUNCTION: Check if domain uses Akamai CDN and get ALL Vietnam IPs
# ============================================================================
check_akamai_and_get_all_vn_ips() {
    local domain="$1"
    local try_akamai_patterns="${2:-false}"  # Optional: try Akamai domain patterns if no VN IP found
    
    # Query Google DNS with ECS
    local response=$(curl -s -m 5 "https://dns.google/resolve?name=${domain}&type=A&edns_client_subnet=${ECS_IP}" 2>/dev/null)
    local has_akamai=""
    
    if [ -n "$response" ]; then
        # Check if uses Akamai (CNAME records)
        has_akamai=$(echo "$response" | jq -r '.Answer[]? | select(.type == 5) | .data' 2>/dev/null | grep -iE "$AKAMAI_PATTERNS")
        
        if [ -n "$has_akamai" ]; then
            # Try to extract Vietnam IPs from response
            local vn_ips=$(extract_vn_ips_from_response "$response")
            
            if [ -n "$vn_ips" ]; then
                echo "$vn_ips"
                return 0
            fi
        fi
    fi
    
    # If no Vietnam IPs found and try_akamai_patterns is enabled, try Akamai domain patterns
    # This is especially useful for existing rewrites where domain might temporarily use different CDN
    if [ "$try_akamai_patterns" = "true" ]; then
        for suffix in $AKAMAI_SUFFIXES; do
            local akamai_domain="${domain}.${suffix}"
            local akamai_response=$(curl -s -m 5 "https://dns.google/resolve?name=${akamai_domain}&type=A&edns_client_subnet=${ECS_IP}" 2>/dev/null)
            
            if [ -z "$akamai_response" ]; then
                continue
            fi
            
            # Check if this is Akamai domain (CNAME or direct A record)
            local akamai_check=$(echo "$akamai_response" | jq -r '.Answer[]? | select(.type == 5) | .data' 2>/dev/null | grep -iE "$AKAMAI_PATTERNS")
            if [ -z "$akamai_check" ]; then
                # Also check A records (might be direct Akamai IP)
                akamai_check=$(echo "$akamai_response" | jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null)
            fi
            
            if [ -n "$akamai_check" ]; then
                # Try to extract Vietnam IPs from Akamai domain response
                local akamai_vn_ips=$(extract_vn_ips_from_response "$akamai_response")
                if [ -n "$akamai_vn_ips" ]; then
                    echo "$akamai_vn_ips"
                    return 0
                fi
            fi
        done
    else
        # If not trying patterns and no Akamai found, return failure
        if [ -z "$has_akamai" ]; then
            return 1
        fi
    fi
    
    return 1
}

# ============================================================================
# FUNCTION: Check existing rewrite (DNS check only - no API calls)
# ============================================================================
check_existing_rewrite() {
    local domain="$1"
    local current_ips="$2"  # Comma-separated list of current IPs
    local is_blocked="$3"
    
    # If blocked, mark for deletion
    if [ "$is_blocked" = "true" ]; then
        echo "DELETE_ALL|$domain|$current_ips"
        return
    fi
    
    # Get ALL new Vietnam IPs
    # Try Akamai patterns if domain is in rewrites but no VN IP found (might be using different CDN temporarily)
    local new_ips=$(check_akamai_and_get_all_vn_ips "$domain" "true")
    
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
        DELETE_ALL)
            # Delete all IPs for this domain
            local deleted_count=0
            IFS=',' read -ra IP_ARRAY <<< "$current_ips"
            for ip in "${IP_ARRAY[@]}"; do
                curl -s -u "$AUTH" \
                  -X POST \
                  -H 'Content-Type: application/json' \
                  -d "$(jq -n --arg d "$domain" --arg a "$ip" '{domain: $d, answer: $a}')" \
                  "$AGH_URL/control/rewrite/delete" > /dev/null 2>&1
                deleted_count=$((deleted_count + 1))
            done
            echo "BLOCKED_REMOVED|$domain|$deleted_count IPs removed"
            ;;
            
        UPDATE)
            # Convert to arrays
            IFS=',' read -ra CURRENT_ARRAY <<< "$current_ips"
            IFS=',' read -ra NEW_ARRAY <<< "$new_ips"
            
            # Find IPs to delete (in current but not in new)
            local deleted=0
            for ip in "${CURRENT_ARRAY[@]}"; do
                if [[ ! " ${NEW_ARRAY[@]} " =~ " ${ip} " ]]; then
                    curl -s -u "$AUTH" \
                      -X POST \
                      -H 'Content-Type: application/json' \
                      -d "$(jq -n --arg d "$domain" --arg a "$ip" '{domain: $d, answer: $a}')" \
                      "$AGH_URL/control/rewrite/delete" > /dev/null 2>&1
                    deleted=$((deleted + 1))
                fi
            done
            
            # Find IPs to add (in new but not in current)
            local added=0
            local errors=0
            for ip in "${NEW_ARRAY[@]}"; do
                if [[ ! " ${CURRENT_ARRAY[@]} " =~ " ${ip} " ]]; then
                    local result=$(curl -s -u "$AUTH" \
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
                local result=$(curl -s -u "$AUTH" \
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
    
    # Check Akamai and get ALL Vietnam IPs
    local vn_ips=$(check_akamai_and_get_all_vn_ips "$domain")
    
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
echo "Akamai DNS Rewrite Manager - Multiple Vietnam IPs Support"
echo "============================================================================"
echo ""

# Step 1: Setup
download_vietnam_ip_ranges
echo ""

# Step 2: Get existing rewrites and group by domain
echo "Fetching existing DNS rewrites..."
EXISTING_REWRITES_JSON=$(curl -s -u "$AUTH" "$AGH_URL/control/rewrite/list")
EXISTING_COUNT=$(echo "$EXISTING_REWRITES_JSON" | jq '. | length' 2>/dev/null || echo 0)

# Group rewrites by domain (multiple IPs per domain)
TEMP_GROUPED_REWRITES="/tmp/agh_grouped_$$.txt"
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

# Step 3: Get query log with filtering status
echo "Fetching query logs with filtering status (limit: $QUERY_LOG_LIMIT)..."
QUERY_LOG_JSON=$(curl -s -u "$AUTH" "$AGH_URL/control/querylog?limit=$QUERY_LOG_LIMIT")

# Create blocked domains lookup
TEMP_BLOCKED="/tmp/agh_blocked_$$.txt"
echo "$QUERY_LOG_JSON" | jq -r '.data[] | select(.reason == "FilteredBlockList" or .reason == "FilteredBlockedService") | .question.name' | sed 's/\.$//' | sort -u > "$TEMP_BLOCKED"
BLOCKED_COUNT=$(wc -l < "$TEMP_BLOCKED")
echo "Found $BLOCKED_COUNT blocked domains in logs"
echo ""

# Step 4: PHASE 1 - Check existing rewrites
echo "============================================================================"
echo "PHASE 1: Checking existing rewrites"
echo "============================================================================"

if [ $UNIQUE_DOMAINS -eq 0 ]; then
    echo "No existing rewrites to check."
else
    # Prepare data with blocked status
    TEMP_EXISTING="/tmp/agh_existing_$$.txt"
    
    while IFS='|' read -r domain ips; do
        if grep -qx "$domain" "$TEMP_BLOCKED" 2>/dev/null; then
            echo "$domain|$ips|true"
        else
            echo "$domain|$ips|false"
        fi
    done < "$TEMP_GROUPED_REWRITES" > "$TEMP_EXISTING"
    
    # Export functions for parallel DNS checks
    export -f check_existing_rewrite
    export -f check_akamai_and_get_all_vn_ips
    export -f extract_vn_ips_from_response
    export -f is_vietnam_ip
    export ECS_IP
    export AKAMAI_PATTERNS
    export AKAMAI_SUFFIXES
    export VN_IP_CACHE
    
    TEMP_CHECK_RESULTS="/tmp/agh_check_results_$$.txt"
    > "$TEMP_CHECK_RESULTS"
    
    echo "Checking $UNIQUE_DOMAINS domains (parallel DNS checks: $PARALLEL_DNS_JOBS)..."
    
    # Run DNS checks in parallel
    cat "$TEMP_EXISTING" | xargs -P "$PARALLEL_DNS_JOBS" -I {} bash -c '
        IFS="|" read -r domain current_ips is_blocked <<< "{}"
        check_existing_rewrite "$domain" "$current_ips" "$is_blocked"
    ' >> "$TEMP_CHECK_RESULTS"
    
    # Export function for API calls
    export -f apply_api_action
    export AUTH
    export AGH_URL
    
    # Separate actions that need API calls
    TEMP_API_ACTIONS="/tmp/agh_api_actions_$$.txt"
    > "$TEMP_API_ACTIONS"
    
    grep -E "^(DELETE_ALL|UPDATE)\|" "$TEMP_CHECK_RESULTS" > "$TEMP_API_ACTIONS" || true
    
    API_ACTION_COUNT=$(wc -l < "$TEMP_API_ACTIONS")
    
    echo "DNS checks completed. Now applying $API_ACTION_COUNT API actions (parallel: $PARALLEL_API_JOBS)..."
    
    TEMP_API_RESULTS="/tmp/agh_api_results_$$.txt"
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
    COUNT_BLOCKED_REMOVED=$(grep -c "^BLOCKED_REMOVED|" "$TEMP_API_RESULTS" || echo 0)
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
            BLOCKED_REMOVED)
                echo "  BLOCKED: $domain - $message"
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
    
    rm -f "$TEMP_EXISTING" "$TEMP_CHECK_RESULTS" "$TEMP_API_ACTIONS" "$TEMP_API_RESULTS"
    
    echo ""
    echo "Phase 1 Summary:"
    echo "  Already correct:     $COUNT_OK domains"
    echo "  Updated:             $COUNT_UPDATED domains"
    echo "  No Vietnam IP:       $COUNT_NO_VN_IP domains"
    echo "  Blocked (removed):   $COUNT_BLOCKED_REMOVED domains"
    echo "  Errors:              $COUNT_ERROR domains"
    echo ""
fi

rm -f "$TEMP_GROUPED_REWRITES"

# Step 5: PHASE 2 - Find NEW domains from logs
echo "============================================================================"
echo "PHASE 2: Discovering new Akamai domains from logs"
echo "============================================================================"

echo "Extracting non-blocked domains from query logs..."
TEMP_DOMAINS="/tmp/agh_domains_$$.txt"

# Extract domains that are NOT blocked
echo "$QUERY_LOG_JSON" | jq -r '.data[] | select(.reason == "NotFilteredNotFound" or .reason == "NotFilteredAllowList") | .question.name' | sed 's/\.$//' | sort -u > "$TEMP_DOMAINS"

TOTAL=$(wc -l < "$TEMP_DOMAINS")
echo "Found $TOTAL unique non-blocked domains in logs"

# Get existing domains (unique)
TEMP_EXISTING_DOMAINS="/tmp/agh_existing_domains_$$.txt"
echo "$EXISTING_REWRITES_JSON" | jq -r '.[].domain' | sort -u > "$TEMP_EXISTING_DOMAINS"

# Remove domains that already have rewrites
TEMP_NEW_DOMAINS="/tmp/agh_new_domains_$$.txt"
comm -23 "$TEMP_DOMAINS" "$TEMP_EXISTING_DOMAINS" > "$TEMP_NEW_DOMAINS"

NEW_TOTAL=$(wc -l < "$TEMP_NEW_DOMAINS")
echo "$NEW_TOTAL new domains to check (after removing existing rewrites)"
echo ""

if [ $NEW_TOTAL -eq 0 ]; then
    echo "No new domains to process."
    rm -f "$TEMP_DOMAINS" "$TEMP_NEW_DOMAINS" "$TEMP_EXISTING_DOMAINS" "$TEMP_BLOCKED"
    exit 0
fi

    # Export functions for parallel DNS checks
    export -f check_new_domain
    export -f check_akamai_and_get_all_vn_ips
    export -f extract_vn_ips_from_response
    export -f is_vietnam_ip
    export ECS_IP
    export AKAMAI_PATTERNS
    export AKAMAI_SUFFIXES
    export VN_IP_CACHE

TEMP_NEW_CHECK_RESULTS="/tmp/agh_new_check_results_$$.txt"
> "$TEMP_NEW_CHECK_RESULTS"

echo "Checking $NEW_TOTAL new domains (parallel DNS checks: $PARALLEL_DNS_JOBS)..."

# Run DNS checks in parallel
cat "$TEMP_NEW_DOMAINS" | xargs -P "$PARALLEL_DNS_JOBS" -I {} bash -c "check_new_domain '{}'" >> "$TEMP_NEW_CHECK_RESULTS"

# Separate ADD actions
TEMP_ADD_ACTIONS="/tmp/agh_add_actions_$$.txt"
grep "^ADD|" "$TEMP_NEW_CHECK_RESULTS" > "$TEMP_ADD_ACTIONS" || true

ADD_ACTION_COUNT=$(wc -l < "$TEMP_ADD_ACTIONS")
COUNT_NO_AKAMAI=$(grep -c "^NO_AKAMAI|" "$TEMP_NEW_CHECK_RESULTS" || echo 0)

echo "DNS checks completed. Now adding $ADD_ACTION_COUNT new domains (parallel: $PARALLEL_API_JOBS)..."

TEMP_ADD_RESULTS="/tmp/agh_add_results_$$.txt"
> "$TEMP_ADD_RESULTS"

# Export function for API calls
export -f apply_api_action
export AUTH
export AGH_URL

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

rm -f "$TEMP_NEW_CHECK_RESULTS" "$TEMP_ADD_ACTIONS" "$TEMP_ADD_RESULTS"

# Cleanup
rm -f "$TEMP_DOMAINS" "$TEMP_NEW_DOMAINS" "$TEMP_EXISTING_DOMAINS" "$TEMP_BLOCKED"

echo ""
echo "Phase 2 Summary:"
echo "  New domains added:    $COUNT_ADDED domains"
echo "  Not using Akamai:     $COUNT_NO_AKAMAI domains"
echo "  Errors:               $COUNT_ERROR domains"
echo ""

# Final statistics
echo "============================================================================"
echo "COMPLETED!"
echo "============================================================================"

# Get final rewrite stats
FINAL_REWRITES_JSON=$(curl -s -u "$AUTH" "$AGH_URL/control/rewrite/list")

# Clear query logs
echo ""
echo "Clearing query logs..."
curl -s -X POST -u "$AUTH" "$AGH_URL/control/querylog_clear" > /dev/null 2>&1
echo "Query logs cleared."
