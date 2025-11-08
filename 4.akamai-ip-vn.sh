#!/bin/bash

# ============================================================================
# Akamai DNS Rewrite Manager
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# CONFIGURATION
# ============================================================================

# AdGuard Home
AGH_URL="https://xxxxx.xxxxx.xxxx.xxxx"
AGH_USER="xxxxxx"
AGH_PASS="xxxxxxxxxxxxxxxxxxxx"

# DNS Query
ECS_IP="14.191.231.0"

# Performance tuning
GLOBAL_PARALLEL=5         # Global concurrent queries (sweet spot)
DNS_TIMEOUT_DIRECT=2      # Timeout for direct queries (seconds)
DNS_TIMEOUT_PROXY=4       # Timeout for proxy queries (seconds)
AGH_BATCH_SIZE=1          # API calls per batch
AGH_BATCH_DELAY=0.1       # Delay between batches (seconds)

ENABLE_PING_TEST=true     # Enable ping test to select best IPs
BEST_IP_COUNT=2           # Number of best IPs to keep per domain (0 = keep all)
PING_COUNT=10             # Number of ping packets
PING_TIMEOUT=2            # Ping timeout in seconds

# Domains to manage
DOMAINS=(
upos-sz-mirrorcosov.bilivideo.com
v16-webapp-prime.tiktok.com
)

# Proxies (format: ip:port:user:pass)
PROXIES=(
ip:port:user:pass
ip:port:user:pass
ip:port:user:pass
ip:port:user:pass
)

# Cache settings
VN_IP_CACHE="${SCRIPT_DIR}/vn_ip_ranges.txt"
VN_IP_CACHE_AGE=86400  # 24 hours

# Temp directory
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# ============================================================================
# LOGGING FUNCTIONS (all output to stderr)
# ============================================================================

log_section() {
    echo >&2
    echo "============================================================================" >&2
    echo "$1" >&2
    echo "============================================================================" >&2
}

log_step() {
    echo "→ $1" >&2
}

log_info() {
    echo "  $1" >&2
}

log_error() {
    echo "ERROR: $1" >&2
}

log_warning() {
    echo "WARNING: $1" >&2
}

# ============================================================================
# STAGE 0: BOOTSTRAP & VALIDATION
# ============================================================================

check_dependencies() {
    log_step "Checking dependencies..."
    
    local missing=()
    for pkg in curl jq grepcidr; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done
    
    if [[ ${#missing[@]} -ne 0 ]]; then
        log_info "Installing: ${missing[*]}"
        apt-get update -qq >/dev/null 2>&1 || {
            log_error "Failed to update apt cache"
            exit 1
        }
        apt-get install -y "${missing[@]}" >/dev/null 2>&1 || {
            log_error "Failed to install dependencies"
            exit 1
        }
        log_info "Dependencies installed successfully"
    else
        log_info "All dependencies available"
    fi
}

update_vn_ip_ranges() {
    log_step "Updating Vietnam IP ranges..."
    
    local need_update=false
    local temp_cache="${VN_IP_CACHE}.tmp"
    
    # Check if update needed
    if [[ -f "$VN_IP_CACHE" ]]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$VN_IP_CACHE" 2>/dev/null || echo 0)))
        if [[ $cache_age -gt $VN_IP_CACHE_AGE ]]; then
            need_update=true
            log_info "Cache expired (age: ${cache_age}s)"
        else
            log_info "Cache valid (age: ${cache_age}s)"
        fi
    else
        need_update=true
        log_info "No cache found"
    fi
    
    # Download if needed
    if [[ "$need_update" == "true" ]]; then
        log_info "Downloading from sources..."
        
        local download_success=false
        {
            curl -sf --connect-timeout 5 --max-time 15 \
                "https://www.ipdeny.com/ipblocks/data/countries/vn.zone" 2>/dev/null || true
            curl -sf --connect-timeout 5 --max-time 15 \
                "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/vn/ipv4-aggregated.txt" 2>/dev/null || true
        } | grep -vE '^(#|$)' | sort -u > "$temp_cache"
        
        # Validate download
        if [[ -s "$temp_cache" ]] && [[ $(wc -l < "$temp_cache") -ge 100 ]]; then
            mv "$temp_cache" "$VN_IP_CACHE"
            download_success=true
            log_info "Downloaded $(wc -l < "$VN_IP_CACHE") IP ranges"
        else
            rm -f "$temp_cache"
            log_warning "Download failed or invalid data"
        fi
        
        # Fallback to old cache
        if [[ "$download_success" == "false" ]]; then
            if [[ -f "$VN_IP_CACHE" ]] && [[ $(wc -l < "$VN_IP_CACHE") -ge 100 ]]; then
                log_warning "Using old cache ($(wc -l < "$VN_IP_CACHE") ranges)"
            else
                log_error "No valid VN IP cache available"
                exit 1
            fi
        fi
    fi
    
    # Final validation
    if [[ ! -f "$VN_IP_CACHE" ]] || [[ $(wc -l < "$VN_IP_CACHE") -lt 100 ]]; then
        log_error "VN IP cache invalid or too small"
        exit 1
    fi
    
    log_info "Cache ready: $(wc -l < "$VN_IP_CACHE") IP ranges"
}

# ============================================================================
# STAGE 1: FETCH CURRENT STATE FROM ADGUARD
# ============================================================================

fetch_current_rewrites() {
    log_step "Fetching current rewrites from AdGuard Home..."
    
    local current_file="${TEMP_DIR}/current.txt"
    
    # Single API call
    if ! curl -sf --connect-timeout 10 --max-time 30 \
        -u "${AGH_USER}:${AGH_PASS}" \
        "${AGH_URL}/control/rewrite/list" 2>/dev/null | \
        jq -r '.[] | "\(.domain) \(.answer)"' 2>/dev/null > "${current_file}.raw"; then
        log_error "Failed to fetch from AdGuard Home"
        exit 1
    fi
    
    # Filter only managed domains
    local domain_pattern="^($(IFS='|'; echo "${DOMAINS[*]}"))"
    grep -E "$domain_pattern " "${current_file}.raw" 2>/dev/null | sort -u > "$current_file" || true
    
    local count=$(wc -l < "$current_file" 2>/dev/null || echo 0)
    log_info "Found $count existing entries"
    
    # Return filename to stdout
    echo "$current_file"
}

# ============================================================================
# STAGE 2: GENERATE QUERY LIST
# ============================================================================

generate_query_list() {
    log_step "Generating query list..."
    
    local query_list="${TEMP_DIR}/queries.txt"
    > "$query_list"
    
    # Generate flat list of all queries
    for domain in "${DOMAINS[@]}"; do
        # Direct query with ECS
        echo "DIRECT|${domain}||" >> "$query_list"
        
        # Proxy queries
        for proxy_info in "${PROXIES[@]}"; do
            echo "PROXY|${domain}|${proxy_info}" >> "$query_list"
        done
    done
    
    local total=$(wc -l < "$query_list")
    local per_domain=$((total / ${#DOMAINS[@]}))
    log_info "Generated $total queries ($per_domain per domain)"
    
    # Return filename to stdout
    echo "$query_list"
}

# ============================================================================
# STAGE 3: EXECUTE DNS QUERIES (GLOBAL PARALLEL CONTROL)
# ============================================================================

execute_single_query() {
    local line="$1"
    IFS='|' read -r query_type domain proxy_info <<< "$line"
    
    if [[ "$query_type" == "DIRECT" ]]; then
        # Direct query with ECS
        curl -sf --connect-timeout "$DNS_TIMEOUT_DIRECT" --max-time "$DNS_TIMEOUT_DIRECT" \
            "https://dns.google/resolve?name=${domain}&type=A&edns_client_subnet=${ECS_IP}" 2>/dev/null | \
            jq -r --arg d "$domain" '.Answer[]? | select(.type == 1) | "\($d) \(.data)"' 2>/dev/null || true
    else
        # Proxy query
        IFS=':' read -r ip port user pass <<< "$proxy_info"
        curl -sf --connect-timeout "$DNS_TIMEOUT_PROXY" --max-time "$DNS_TIMEOUT_PROXY" \
            -x "http://${user}:${pass}@${ip}:${port}" \
            "https://dns.google/resolve?name=${domain}&type=A" 2>/dev/null | \
            jq -r --arg d "$domain" '.Answer[]? | select(.type == 1) | "\($d) \(.data)"' 2>/dev/null || true
    fi
}

export -f execute_single_query
export ECS_IP DNS_TIMEOUT_DIRECT DNS_TIMEOUT_PROXY

execute_all_queries() {
    local query_list="$1"
    log_step "Executing DNS queries (parallel: $GLOBAL_PARALLEL)..."
    
    local desired_file="${TEMP_DIR}/desired.txt"
    local all_ips="${TEMP_DIR}/all_ips.txt"
    
    local start_time=$(date +%s)
    
    # SINGLE POINT OF PARALLEL CONTROL
    # Process all queries with global limit, stream to grepcidr
    cat "$query_list" | \
        xargs -I {} -P "$GLOBAL_PARALLEL" bash -c 'execute_single_query "{}"' 2>/dev/null | \
        sort -u > "$all_ips"
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_info "Collected $(wc -l < "$all_ips") unique IPs in ${duration}s"
    
    # Filter Vietnam IPs in single pass
    log_info "Filtering Vietnam IPs..."
    if [[ -s "$all_ips" ]]; then
        grepcidr -f "$VN_IP_CACHE" "$all_ips" 2>/dev/null | sort -u > "$desired_file" || true
    else
        > "$desired_file"
    fi
    
    local vn_count=$(wc -l < "$desired_file" 2>/dev/null || echo 0)
    log_info "Found $vn_count Vietnam IPs"

	# Ping test and keep only best IPs per domain (optional)
	if [[ "$ENABLE_PING_TEST" == "true" ]] && [[ $BEST_IP_COUNT -gt 0 ]] && [[ $vn_count -gt 0 ]]; then
		log_info "Testing ping for best IPs (keeping top $BEST_IP_COUNT per domain)..."
		local final_file="${TEMP_DIR}/final.txt"
		> "$final_file"
		
		for domain in "${DOMAINS[@]}"; do
			local domain_ips="${TEMP_DIR}/domain_${domain//[^a-zA-Z0-9]/_}.txt"
			grep "^${domain} " "$desired_file" > "$domain_ips" 2>/dev/null || continue
			
			local ip_count=$(wc -l < "$domain_ips")
			if [[ $ip_count -le $BEST_IP_COUNT ]]; then
				cat "$domain_ips" >> "$final_file"
				log_info "$domain: kept all $ip_count IPs"
			else
				local ping_results="${TEMP_DIR}/ping_${domain//[^a-zA-Z0-9]/_}.txt"
				> "$ping_results"
				
				while read -r d ip; do
					local avg_ping=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" 2>/dev/null | \
						awk -F'/' '/^rtt/ {print $5}' || echo "9999")
					echo "${avg_ping} ${d} ${ip}" >> "$ping_results"
				done < "$domain_ips"
				
				sort -n "$ping_results" | head -"$BEST_IP_COUNT" | \
					awk '{print $2, $3}' >> "$final_file"
				
				log_info "$domain: tested $ip_count IPs, kept best $BEST_IP_COUNT"
			fi
		done
		
		mv "$final_file" "$desired_file"
		vn_count=$(wc -l < "$desired_file")
		log_info "Final count after ping test: $vn_count IPs"
	fi
    
    # Return filename to stdout
    echo "$desired_file"
}

# ============================================================================
# STAGE 4: CALCULATE DIFFERENCES
# ============================================================================

calculate_diff() {
    local current_file="$1"
    local desired_file="$2"
    
    log_step "Calculating differences..."
    
    local to_add="${TEMP_DIR}/to_add.txt"
    local to_delete="${TEMP_DIR}/to_delete.txt"
    local to_keep="${TEMP_DIR}/to_keep.txt"
    
    # Ensure both files are sorted (required for comm)
    sort -u "$current_file" -o "$current_file"
    sort -u "$desired_file" -o "$desired_file"
    
    # Calculate differences
    comm -23 "$desired_file" "$current_file" > "$to_add" 2>/dev/null || true
    comm -13 "$desired_file" "$current_file" > "$to_delete" 2>/dev/null || true
    comm -12 "$desired_file" "$current_file" > "$to_keep" 2>/dev/null || true
    
    local add_count=$(wc -l < "$to_add" 2>/dev/null || echo 0)
    local delete_count=$(wc -l < "$to_delete" 2>/dev/null || echo 0)
    local keep_count=$(wc -l < "$to_keep" 2>/dev/null || echo 0)
    
    log_info "Keep: $keep_count"
    log_info "Add: $add_count"
    log_info "Delete: $delete_count"
    
    # Return values to stdout
    echo "${to_add}|${to_delete}|${add_count}|${delete_count}"
}

# ============================================================================
# STAGE 5: APPLY CHANGES TO ADGUARD
# ============================================================================

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

apply_changes_batch() {
    local action="$1"
    local file="$2"
    local total="$3"
    
    if [[ $total -eq 0 ]]; then
        return 0
    fi
    
    log_step "Applying ${action} changes ($total entries)..."
    
    local count=0
    local batch=0
    local errors=0
    local start_time=$(date +%s)
    
    while read -r domain ip; do
        if api_call "$action" "$domain" "$ip"; then
            ((count++))
        else
            ((errors++))
            log_warning "Failed: $action $domain -> $ip"
        fi
        
        # Batch control
        if (( count % AGH_BATCH_SIZE == 0 )); then
            ((batch++))
            log_info "Batch $batch: $AGH_BATCH_SIZE entries processed"
            sleep "$AGH_BATCH_DELAY"
        fi
    done < "$file"
    
    # Handle remaining entries in partial batch
    if (( count % AGH_BATCH_SIZE != 0 )); then
        ((batch++))
        log_info "Batch $batch: $((count % AGH_BATCH_SIZE)) entries processed"
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_info "Completed: $count succeeded, $errors failed in ${duration}s"
    
    return $(( errors > 0 ? 1 : 0 ))
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    log_section "Akamai DNS Rewrite Manager - Redesigned Architecture"
    
    echo "Configuration:" >&2
    echo "  Domains: ${#DOMAINS[@]}" >&2
    for d in "${DOMAINS[@]}"; do
        echo "    - $d" >&2
    done
    echo "  Proxies: ${#PROXIES[@]}" >&2
    echo "  Global parallel: $GLOBAL_PARALLEL" >&2
    echo "  AdGuard batch size: $AGH_BATCH_SIZE" >&2
    
    # ========================================================================
    # STAGE 0: Bootstrap
    # ========================================================================
    log_section "STAGE 0: Bootstrap & Validation"
    check_dependencies
    update_vn_ip_ranges
    
    # ========================================================================
    # STAGE 1: Fetch current state
    # ========================================================================
    log_section "STAGE 1: Fetch Current State"
    current_file=$(fetch_current_rewrites)
    
    # ========================================================================
    # STAGE 2: Generate query list
    # ========================================================================
    log_section "STAGE 2: Generate Query List"
    query_list=$(generate_query_list)
    
    # ========================================================================
    # STAGE 3: Execute queries
    # ========================================================================
    log_section "STAGE 3: Execute DNS Queries"
    desired_file=$(execute_all_queries "$query_list")
    
    # ========================================================================
    # STAGE 4: Calculate diff
    # ========================================================================
    log_section "STAGE 4: Calculate Differences"
    diff_result=$(calculate_diff "$current_file" "$desired_file")
    IFS='|' read -r to_add to_delete add_count delete_count <<< "$diff_result"
    
    # ========================================================================
    # STAGE 5: Apply changes
    # ========================================================================
    log_section "STAGE 5: Apply Changes"
    
    if [[ $add_count -eq 0 && $delete_count -eq 0 ]]; then
        log_info "No changes needed - everything up to date"
        log_section "COMPLETED - No Changes"
        exit 0
    fi
    
    local total_errors=0
    
    # Delete first (cleanup old entries)
    if [[ $delete_count -gt 0 ]]; then
        if ! apply_changes_batch "delete" "$to_delete" "$delete_count"; then
            ((total_errors++))
        fi
    fi
    
    # Then add new entries
    if [[ $add_count -gt 0 ]]; then
        if ! apply_changes_batch "add" "$to_add" "$add_count"; then
            ((total_errors++))
        fi
    fi
    
    # ========================================================================
    # Summary
    # ========================================================================
    log_section "COMPLETED"
    echo "Summary:" >&2
    echo "  Deleted: $delete_count entries" >&2
    echo "  Added: $add_count entries" >&2
    if [[ $total_errors -gt 0 ]]; then
        echo "  Status: Completed with errors" >&2
        exit 1
    else
        echo "  Status: Success" >&2
        exit 0
    fi
}

# Execute main function
main
