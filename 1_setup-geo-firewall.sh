#!/bin/bash
# setup-geo-firewall.sh
# GeoIP-based firewall with Docker support - production ready
# Detect public IP
PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+')

# ==============================
# USER CONFIGURATION
# ==============================
ALLOW_COUNTRIES=("VN")
ALLOW_TCP_PORTS=("2224" "443")
ALLOW_UDP_PORTS=("443")

# PING Configuration
ENABLE_PING=false  # true

# ALLOWLIST CONFIGURATION
ALLOWLIST_URLS=(
    "https://hetrixtools.com/resources/uptime-monitor-only-ips.txt"
    "https://www.cloudflare.com/ips-v4/"
)
# Contabo Singapore Data Center - check-host.net
ALLOWLIST_IPS=("217.15.166.168" "$PUBLIC_IP")

# ==============================
# SYSTEM CONFIGURATION
# ==============================
SCRIPT_DIR="/home/geo-firewall"
FIREWALL_SCRIPT="$SCRIPT_DIR/geo-firewall.sh"
SERVICE_FILE="/etc/systemd/system/geo-firewall.service"
RESET_SCRIPT="$SCRIPT_DIR/emergency-reset.sh"

# Chain/IPSet names (MUST match in all scripts)
CHAIN_INPUT="GEO_INPUT"
CHAIN_DOCKER="GEO_DOCKER"
IPSET_COUNTRY="geo_country"
IPSET_ALLOWLIST="geo_allowlist"

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)." >&2
    exit 1
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# ==============================
# CLEANUP FUNCTION
# ==============================
cleanup_all() {
    log "Cleaning up all existing configurations..."
    
    # Stop and disable service
    if systemctl is-active --quiet geo-firewall.service 2>/dev/null; then
        systemctl stop geo-firewall.service 2>/dev/null || true
    fi
    systemctl disable geo-firewall.service 2>/dev/null || true
    
    # Remove iptables rules
    iptables -D INPUT -j "$CHAIN_INPUT" 2>/dev/null || true
    iptables -D DOCKER-USER -j "$CHAIN_DOCKER" 2>/dev/null || true
    
    for chain in "$CHAIN_INPUT" "$CHAIN_DOCKER"; do
        iptables -F "$chain" 2>/dev/null || true
        iptables -X "$chain" 2>/dev/null || true
    done
    
    # Remove ipsets
    for ipset_name in "$IPSET_COUNTRY" "$IPSET_ALLOWLIST"; do
        ipset destroy "$ipset_name" 2>/dev/null || true
    done
    
    # Remove cron job
    crontab -l 2>/dev/null | grep -v "$FIREWALL_SCRIPT" | crontab - 2>/dev/null || true
    
    # Remove systemd service file
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true
    
    # Remove script directory
    rm -rf "$SCRIPT_DIR"
    
    # Save clean iptables state
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    if command -v netfilter-persistent >/dev/null; then
        netfilter-persistent save 2>/dev/null || true
    fi
    
    log "✓ Cleanup complete"
}

# ==============================
# INSTALL DEPENDENCIES
# ==============================
log "Installing required packages..."
if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ipset iptables-persistent curl
elif command -v yum >/dev/null; then
    yum install -y -q ipset iptables-services curl
else
    log "ERROR: Unsupported package manager"
    exit 1
fi

# Clean up before starting
cleanup_all

# Create script directory
mkdir -p "$SCRIPT_DIR"

# ==============================
# GENERATE EMERGENCY RESET SCRIPT
# ==============================
log "Creating emergency reset script..."

cat > "$RESET_SCRIPT" << 'EOF_RESET'
#!/bin/bash
set -euo pipefail

# MUST match setup script
SCRIPT_DIR="/home/geo-firewall"
FIREWALL_SCRIPT="$SCRIPT_DIR/geo-firewall.sh"
SERVICE_FILE="/etc/systemd/system/geo-firewall.service"
CHAIN_INPUT="GEO_INPUT"
CHAIN_DOCKER="GEO_DOCKER"
IPSET_COUNTRY="geo_country"
IPSET_ALLOWLIST="geo_allowlist"

echo "=========================================="
echo "⚠️  EMERGENCY FIREWALL RESET"
echo "=========================================="

# Stop and disable service
if systemctl is-active --quiet geo-firewall.service 2>/dev/null; then
    systemctl stop geo-firewall.service 2>/dev/null || true
    echo "✓ Service stopped"
fi
systemctl disable geo-firewall.service 2>/dev/null || true

# Remove chain references
iptables -D INPUT -j "$CHAIN_INPUT" 2>/dev/null || true
iptables -D DOCKER-USER -j "$CHAIN_DOCKER" 2>/dev/null || true

# Flush and delete chains
for chain in "$CHAIN_INPUT" "$CHAIN_DOCKER"; do
    iptables -F "$chain" 2>/dev/null || true
    iptables -X "$chain" 2>/dev/null || true
done
echo "✓ Firewall chains removed"

# Destroy ipsets
for ipset_name in "$IPSET_COUNTRY" "$IPSET_ALLOWLIST"; do
    ipset destroy "$ipset_name" 2>/dev/null || true
done
echo "✓ IPsets destroyed"

# Remove cron job
crontab -l 2>/dev/null | grep -v "$FIREWALL_SCRIPT" | crontab - 2>/dev/null || true
echo "✓ Cron job removed"

# Remove systemd service
rm -f "$SERVICE_FILE"
systemctl daemon-reload 2>/dev/null || true
echo "✓ Systemd service removed"

# Remove script directory
rm -rf "$SCRIPT_DIR"
echo "✓ Scripts removed"

# Save clean state
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
if command -v netfilter-persistent >/dev/null; then
    netfilter-persistent save 2>/dev/null || true
fi
echo "✓ Configuration saved"

echo "=========================================="
echo "✓ All geo-firewall components removed"
echo "=========================================="
EOF_RESET

chmod +x "$RESET_SCRIPT"

# ==============================
# GENERATE MAIN FIREWALL SCRIPT
# ==============================
log "Generating firewall script..."

cat > "$FIREWALL_SCRIPT" << 'EOF_MAIN'
#!/bin/bash
set -euo pipefail

# Configuration
ALLOW_COUNTRIES=()
ALLOW_TCP_PORTS=()
ALLOW_UDP_PORTS=()
ALLOWLIST_URLS=()
ALLOWLIST_IPS=()
ENABLE_PING=false

# Chain/IPSet names
CHAIN_INPUT="GEO_INPUT"
CHAIN_DOCKER="GEO_DOCKER"
IPSET_COUNTRY="geo_country"
IPSET_ALLOWLIST="geo_allowlist"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# ==============================
# CLEANUP FUNCTION
# ==============================
cleanup_old_state() {
    log "Cleaning old firewall state..."
    
    iptables -D INPUT -j "$CHAIN_INPUT" 2>/dev/null || true
    iptables -D DOCKER-USER -j "$CHAIN_DOCKER" 2>/dev/null || true
    
    for chain in "$CHAIN_INPUT" "$CHAIN_DOCKER"; do
        iptables -F "$chain" 2>/dev/null || true
        iptables -X "$chain" 2>/dev/null || true
    done
    
    for ipset_name in "$IPSET_COUNTRY" "$IPSET_ALLOWLIST"; do
        ipset destroy "$ipset_name" 2>/dev/null || true
    done
    
    log "✓ Old state cleaned"
}

# ==============================
# BUILD ALLOWLIST IPSET
# ==============================
build_allowlist() {
    log "Building allowlist ipset..."
    ipset create "$IPSET_ALLOWLIST" hash:net maxelem 65536
    
    local count=0
    
    for ip in "${ALLOWLIST_IPS[@]}"; do
        [[ -z "$ip" ]] && continue
        if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
            ipset add "$IPSET_ALLOWLIST" "$ip" 2>/dev/null && ((count++)) || true
        fi
    done
    
    for url in "${ALLOWLIST_URLS[@]}"; do
        [[ -z "$url" ]] && continue
        log "Fetching: $url"
        
        local temp_file
        temp_file=$(mktemp)
        
        if curl -sf --connect-timeout 10 --max-time 30 "$url" -o "$temp_file" 2>/dev/null; then
            while IFS= read -r line; do
                line=$(echo "$line" | tr -d '\r' | xargs)
                [[ -z "$line" || "$line" =~ ^# ]] && continue
                
                if [[ $line =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
                    if ipset add "$IPSET_ALLOWLIST" "$line" 2>/dev/null; then
                        ((count++))
                    fi
                fi
            done < "$temp_file"
            log "✓ Fetched from URL"
        else
            log "✗ Failed to fetch: $url"
        fi
        
        rm -f "$temp_file"
    done
    
    log "✓ Allowlist total: $count entries"
    echo "$count"
}

# ==============================
# BUILD COUNTRY IPSET
# ==============================
build_country_ipset() {
    log "Building country ipset..."
    ipset create "$IPSET_COUNTRY" hash:net maxelem 131072
    
    local total=0
    local sources=(
        "https://raw.githubusercontent.com/ipverse/rir-ip/refs/heads/master/country/__CC__/ipv4-aggregated.txt"
        "https://www.ipdeny.com/ipblocks/data/countries/__CC__.zone"
    )
    
    for cc in "${ALLOW_COUNTRIES[@]}"; do
        log "Processing country: $cc"
        local cc_lower="${cc,,}"
        local temp_file
        temp_file=$(mktemp)
        
        for source_template in "${sources[@]}"; do
            local url="${source_template//__CC__/$cc_lower}"
            if curl -sf --connect-timeout 10 --max-time 30 "$url" 2>/dev/null | \
               grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' >> "$temp_file"; then
                log "✓ Fetched from: ${url##*/}"
            fi
        done
        
        if [[ -s "$temp_file" ]]; then
            local cc_count=0
            while read -r cidr; do
                ipset add "$IPSET_COUNTRY" "$cidr" 2>/dev/null && ((cc_count++)) || true
            done < <(sort -u "$temp_file")
            total=$((total + cc_count))
            log "✓ $cc: $cc_count CIDRs"
        else
            log "✗ $cc: No data found"
        fi
        
        rm -f "$temp_file"
    done
    
    if [[ $total -eq 0 ]]; then
        log "ERROR: No country data loaded"
        return 1
    fi
    
    log "✓ Country total: $total CIDRs"
    echo "$total"
}

# ==============================
# BUILD IPTABLES CHAINS
# ==============================
build_chains() {
    local allowlist_count=$1
    local country_count=$2
    
    log "Building iptables chains..."
    
    # INPUT CHAIN
    iptables -N "$CHAIN_INPUT"
    
    iptables -A "$CHAIN_INPUT" -i lo -j ACCEPT
    iptables -A "$CHAIN_INPUT" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
	if [[ "$ENABLE_PING" == "true" ]]; then
		if [[ $allowlist_count -gt 0 ]]; then
			iptables -A "$CHAIN_INPUT" -p icmp --icmp-type echo-request \
				-m set --match-set "$IPSET_ALLOWLIST" src -j ACCEPT
		fi
		iptables -A "$CHAIN_INPUT" -p icmp --icmp-type echo-request \
			-m set --match-set "$IPSET_COUNTRY" src -j ACCEPT
	fi
	
	# Allow all internal Docker traffic 
	iptables -A "$CHAIN_INPUT" -s 172.18.0.0/16 -j ACCEPT	
    
    if [[ $allowlist_count -gt 0 ]]; then
        for port in "${ALLOW_TCP_PORTS[@]}"; do
            iptables -A "$CHAIN_INPUT" -p tcp --dport "$port" \
                -m set --match-set "$IPSET_ALLOWLIST" src -j ACCEPT
        done
        
        for port in "${ALLOW_UDP_PORTS[@]}"; do
            iptables -A "$CHAIN_INPUT" -p udp --dport "$port" \
                -m set --match-set "$IPSET_ALLOWLIST" src -j ACCEPT
        done
    fi
    
    for port in "${ALLOW_TCP_PORTS[@]}"; do
        iptables -A "$CHAIN_INPUT" -p tcp --dport "$port" \
            -m set --match-set "$IPSET_COUNTRY" src -j ACCEPT
    done
    
    for port in "${ALLOW_UDP_PORTS[@]}"; do
        iptables -A "$CHAIN_INPUT" -p udp --dport "$port" \
            -m set --match-set "$IPSET_COUNTRY" src -j ACCEPT
    done
    
    iptables -A "$CHAIN_INPUT" -j DROP
    
    log "✓ INPUT chain built"

	# DOCKER CHAIN - lọc theo port
	if command -v docker >/dev/null 2>&1; then
		log "Building Docker chain..."
		
		iptables -N DOCKER-USER 2>/dev/null || true
		iptables -N "$CHAIN_DOCKER"
		
		# Allow internal Docker network traffic first
		iptables -I "$CHAIN_DOCKER" 1 -s 172.18.0.0/16 -j RETURN
		
		iptables -A "$CHAIN_DOCKER" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
		
		# Allowlist - specific ports only
		if [[ $allowlist_count -gt 0 ]]; then
			for port in "${ALLOW_TCP_PORTS[@]}"; do
				iptables -A "$CHAIN_DOCKER" -p tcp --dport "$port" \
					-m set --match-set "$IPSET_ALLOWLIST" src -j RETURN
			done
			
			for port in "${ALLOW_UDP_PORTS[@]}"; do
				iptables -A "$CHAIN_DOCKER" -p udp --dport "$port" \
					-m set --match-set "$IPSET_ALLOWLIST" src -j RETURN
			done
		fi
		
		# Country - specific ports only
		for port in "${ALLOW_TCP_PORTS[@]}"; do
			iptables -A "$CHAIN_DOCKER" -p tcp --dport "$port" \
				-m set --match-set "$IPSET_COUNTRY" src -j RETURN
		done
		
		for port in "${ALLOW_UDP_PORTS[@]}"; do
			iptables -A "$CHAIN_DOCKER" -p udp --dport "$port" \
				-m set --match-set "$IPSET_COUNTRY" src -j RETURN
		done
		
		iptables -A "$CHAIN_DOCKER" -j DROP
		
		log "✓ Docker chain built"
	fi
}

# ==============================
# ACTIVATE FIREWALL
# ==============================
activate_firewall() {
    log "Activating firewall..."
    
    iptables -I INPUT 1 -j "$CHAIN_INPUT"
    
    if iptables -L DOCKER-USER -n >/dev/null 2>&1; then
        iptables -I DOCKER-USER 1 -j "$CHAIN_DOCKER" 2>/dev/null || true
        log "✓ Docker protection enabled"
    fi
    
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    
    if command -v netfilter-persistent >/dev/null; then
        netfilter-persistent save 2>/dev/null || true
    fi
    
    log "✓ Rules saved"
}

# ==============================
# MAIN EXECUTION
# ==============================
main() {
    log "=========================================="
    log "GeoIP Firewall Activation"
    log "=========================================="
    
    cleanup_old_state
    
    allowlist_count=$(build_allowlist)
    country_count=$(build_country_ipset) || exit 1
    
    build_chains "$allowlist_count" "$country_count"
    activate_firewall
    
    log "=========================================="
    log "✓ FIREWALL ACTIVE"
    log "  Countries: ${ALLOW_COUNTRIES[*]}"
    log "  TCP Ports: ${ALLOW_TCP_PORTS[*]}"
    log "  UDP Ports: ${ALLOW_UDP_PORTS[*]}"
    log "  Allowlist: $allowlist_count entries"
    log "  Country IPs: $country_count CIDRs"
    log "=========================================="
}

main
EOF_MAIN

# Inject configuration into firewall script
sed -i "/^ALLOW_COUNTRIES=()/ c\ALLOW_COUNTRIES=($(printf '"%s" ' "${ALLOW_COUNTRIES[@]}") )" "$FIREWALL_SCRIPT"
sed -i "/^ALLOW_TCP_PORTS=()/ c\ALLOW_TCP_PORTS=($(printf '"%s" ' "${ALLOW_TCP_PORTS[@]}") )" "$FIREWALL_SCRIPT"
sed -i "/^ALLOW_UDP_PORTS=()/ c\ALLOW_UDP_PORTS=($(printf '"%s" ' "${ALLOW_UDP_PORTS[@]}") )" "$FIREWALL_SCRIPT"
sed -i "/^ALLOWLIST_URLS=()/ c\ALLOWLIST_URLS=($(printf '"%s" ' "${ALLOWLIST_URLS[@]}") )" "$FIREWALL_SCRIPT"
sed -i "/^ALLOWLIST_IPS=()/ c\ALLOWLIST_IPS=($(printf '"%s" ' "${ALLOWLIST_IPS[@]}") )" "$FIREWALL_SCRIPT"
sed -i "/^ENABLE_PING=/ c\ENABLE_PING=\"$ENABLE_PING\"" "$FIREWALL_SCRIPT"

chmod +x "$FIREWALL_SCRIPT"

# ==============================
# SETUP SYSTEMD SERVICE
# ==============================
log "Creating systemd service..."

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=GeoIP Firewall
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$FIREWALL_SCRIPT
RemainAfterExit=yes
StandardOutput=null
StandardError=null
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable geo-firewall.service

# ==============================
# SETUP CRON JOB
# ==============================
log "Setting up cron job..."

(crontab -l 2>/dev/null || true; echo "30 2 * * * $FIREWALL_SCRIPT >/dev/null 2>&1") | crontab -

# ==============================
# APPLY FIREWALL NOW
# ==============================
log "Applying firewall..."

if "$FIREWALL_SCRIPT"; then
    log "✓ Setup complete"
else
    log "✗ Firewall failed - running emergency reset"
    "$RESET_SCRIPT"
    exit 1
fi

# ==============================
# FINAL SUMMARY
# ==============================
echo ""
echo "╔════════════════════════════════════════╗"
echo "║     GEO FIREWALL INSTALLED             ║"
echo "╚════════════════════════════════════════╝"
echo ""
echo "Configuration:"
echo "  • Countries: ${ALLOW_COUNTRIES[*]}"
echo "  • TCP ports: ${ALLOW_TCP_PORTS[*]}"
echo "  • UDP ports: ${ALLOW_UDP_PORTS[*]}"
echo "  • Allowlist URLs: ${#ALLOWLIST_URLS[@]}"
echo "  • Allowlist IPs: ${#ALLOWLIST_IPS[@]}"
echo "  • Allowlist IPs: ${#ALLOWLIST_IPS[@]}"
if [[ "$ENABLE_PING" == "true" ]]; then
    echo "  • PING: Enabled (geo-filtered)"
else
    echo "  • PING: Disabled"
fi
echo ""
echo "Docker Support:"
echo "  • Rules applied to DOCKER-USER chain"
echo "  • Container traffic protected"
echo ""
echo "Auto-update:"
echo "  • Daily at 02:30 via cron"
echo "  • On boot via systemd"
echo ""
echo "Management Commands:"
echo "  • Status:  systemctl status geo-firewall"
echo "  • Restart: systemctl restart geo-firewall"
echo "  • Update:  $FIREWALL_SCRIPT"
echo "  • Reset:   $RESET_SCRIPT"
echo ""
echo "View Rules:"
echo "  • iptables -L $CHAIN_INPUT -n -v"
echo "  • iptables -L $CHAIN_DOCKER -n -v"
echo "  • ipset list $IPSET_COUNTRY"
echo "  • ipset list $IPSET_ALLOWLIST"
echo ""
echo "Logs:"
echo "  • Disabled for performance"
echo ""

exit 0
