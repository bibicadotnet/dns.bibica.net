#!/bin/bash
# setup-geo-firewall.sh
# GeoIP-based firewall - allows traffic ONLY from specified countries

# ==============================
# USER CONFIGURATION
# ==============================
ALLOW_COUNTRIES=("VN" "SG")
ALLOW_TCP_PORTS=("2224" "443" "53")
ALLOW_UDP_PORTS=("443" "53")

# ALLOWLIST CONFIGURATION
ALLOWLIST_URLS=("https://hetrixtools.com/resources/uptime-monitor-only-ips.txt" "https://www.cloudflare.com/ips-v4/")
ALLOWLIST_IPS=("217.15.166.168")

# ==============================
# SYSTEM CONFIGURATION
# ==============================
SCRIPT_DIR="/opt/geo-firewall"
FIREWALL_SCRIPT="$SCRIPT_DIR/geo-firewall.sh"
SERVICE_FILE="/etc/systemd/system/geo-firewall.service"
CRON_LOG="/var/log/geo-firewall.log"
BACKUP_SCRIPT="$SCRIPT_DIR/emergency-reset.sh"

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)." >&2
    exit 1
fi

log() {
    echo "[$(date -Iseconds)] $*"
}

log "Installing required packages..."
if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ipset curl iptables-persistent 2>&1 | grep -v "^$" || true
elif command -v yum >/dev/null; then
    yum install -y -q ipset curl iptables-services 2>&1 | grep -v "^$" || true
fi

mkdir -p "$SCRIPT_DIR"

log "Generating firewall script..."

TCP_STR=$(printf '"%s" ' "${ALLOW_TCP_PORTS[@]}")
UDP_STR=$(printf '"%s" ' "${ALLOW_UDP_PORTS[@]}")
CC_STR=$(printf '"%s" ' "${ALLOW_COUNTRIES[@]}")
ALLOWLIST_URLS_STR=$(printf '"%s" ' "${ALLOWLIST_URLS[@]}")
ALLOWLIST_IPS_STR=$(printf '"%s" ' "${ALLOWLIST_IPS[@]}")

cat > "$FIREWALL_SCRIPT" << 'EOFMAIN'
#!/bin/bash
set -euo pipefail

ALLOW_COUNTRIES=(VN SG)
ALLOW_TCP_PORTS=(2224 443)
ALLOW_UDP_PORTS=(443)
ALLOWLIST_URLS=("https://hetrixtools.com/resources/uptime-monitor-only-ips.txt" "https://www.cloudflare.com/ips-v4/")
ALLOWLIST_IPS=("217.15.166.168")

IPSET_NAME="geo_allowed"
IPSET_ALLOWLIST="geo_allowlist"

log() { echo "[$(date -Iseconds)] $*"; }

# ========================================
# CLEAN ALL OLD STATE FIRST
# ========================================
log "Cleaning all old firewall state..."

# Remove all GEO chains from INPUT
iptables -D INPUT -j GEO_MAIN 2>/dev/null || true
iptables -D INPUT -j GEO_NEW 2>/dev/null || true

# Flush and delete all GEO chains
iptables -F GEO_MAIN 2>/dev/null || true
iptables -F GEO_NEW 2>/dev/null || true
iptables -X GEO_MAIN 2>/dev/null || true
iptables -X GEO_NEW 2>/dev/null || true

# Destroy all geo ipsets
ipset list -n 2>/dev/null | grep '^geo' | xargs -r -n1 ipset destroy 2>/dev/null || true

log "Old state cleaned"

# ========================================
# BUILD ALLOWLIST IPSET
# ========================================
log "Creating allowlist ipset: $IPSET_ALLOWLIST"
ipset create "$IPSET_ALLOWLIST" hash:net maxelem 65536 2>/dev/null || true
ipset flush "$IPSET_ALLOWLIST" 2>/dev/null || true

# Function to add IP/CIDR to allowlist
add_to_allowlist() {
    local entry="$1"
    if [[ $entry =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
        ipset add "$IPSET_ALLOWLIST" "$entry" 2>/dev/null && return 0
    fi
    return 1
}

# Process direct IP entries
allowlist_count=0
for ip_entry in "${ALLOWLIST_IPS[@]}"; do
    if [[ -n "$ip_entry" ]]; then
        if add_to_allowlist "$ip_entry"; then
            allowlist_count=$((allowlist_count + 1))
            log "✓ Added to allowlist: $ip_entry"
        else
            log "✗ Invalid allowlist entry: $ip_entry"
        fi
    fi
done

# Process URLs for allowlist
for url in "${ALLOWLIST_URLS[@]}"; do
    if [[ -n "$url" ]]; then
        log "Fetching allowlist from: $url"
        temp_url=$(mktemp)
        if curl -sf --connect-timeout 10 --max-time 30 "$url" -o "$temp_url" 2>/dev/null; then
            url_count=0
            while IFS= read -r line; do
                line=$(echo "$line" | tr -d '\r' | xargs)
                [[ -z "$line" ]] && continue
                [[ "$line" =~ ^# ]] && continue
                
                if add_to_allowlist "$line"; then
                    url_count=$((url_count + 1))
                    allowlist_count=$((allowlist_count + 1))
                fi
            done < "$temp_url"
            log "✓ Added $url_count IPs from $url"
        else
            log "✗ Failed to fetch allowlist from: $url"
        fi
        rm -f "$temp_url"
    fi
done

if [[ $allowlist_count -gt 0 ]]; then
    log "Total allowlist entries: $allowlist_count"
fi

# ========================================
# BUILD COUNTRY IPSET
# ========================================
log "Creating country ipset: $IPSET_NAME"
ipset create "$IPSET_NAME" hash:net maxelem 131072

log "Fetching IP ranges for: ${ALLOW_COUNTRIES[*]}"
success=0
total_cidrs=0

for cc in "${ALLOW_COUNTRIES[@]}"; do
    log "Processing country: $cc"
    temp_all=$(mktemp)
    > "$temp_all"

    # Tải từ ipverse
    if curl -sf --connect-timeout 10 --max-time 30 \
        "https://raw.githubusercontent.com/ipverse/rir-ip/refs/heads/master/country/${cc,,}/ipv4-aggregated.txt" \
        -o - 2>/dev/null | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' >> "$temp_all"; then
        log "✓ ipverse: added CIDRs for $cc"
    fi

    # Tải từ ipdeny
    if curl -sf --connect-timeout 10 --max-time 30 \
        "https://www.ipdeny.com/ipblocks/data/countries/${cc,,}.zone" \
        -o - 2>/dev/null | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' >> "$temp_all"; then
        log "✓ ipdeny: added CIDRs for $cc"
    fi

    # Gộp và nạp vào ipset
    if [[ -s "$temp_all" ]]; then
        while IFS= read -r cidr; do
            ipset add "$IPSET_NAME" "$cidr" 2>/dev/null && total_cidrs=$((total_cidrs + 1))
        done < <(sort -u "$temp_all")
        success=$((success + 1))
        log "✓ Finalized $cc"
    else
        log "✗ No data for $cc"
    fi

    rm -f "$temp_all"
done

if [[ $success -eq 0 ]] || [[ $total_cidrs -eq 0 ]]; then
    log "ERROR: No country data loaded"
    ipset destroy "$IPSET_NAME" 2>/dev/null || true
    ipset destroy "$IPSET_ALLOWLIST" 2>/dev/null || true
    exit 1
fi

log "Loaded $total_cidrs CIDR blocks"

# ========================================
# BUILD NEW CHAIN
# ========================================
log "Building chain GEO_MAIN..."
iptables -N GEO_MAIN

iptables -A GEO_MAIN -i lo -j ACCEPT
iptables -A GEO_MAIN -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow allowlist IPs first
if [[ $allowlist_count -gt 0 ]]; then
    for port in "${ALLOW_TCP_PORTS[@]}"; do
        iptables -A GEO_MAIN -p tcp --dport "$port" -m set --match-set "$IPSET_ALLOWLIST" src -j ACCEPT
    done

    for port in "${ALLOW_UDP_PORTS[@]}"; do
        iptables -A GEO_MAIN -p udp --dport "$port" -m set --match-set "$IPSET_ALLOWLIST" src -j ACCEPT
    done
fi

# Allow country IPs
for port in "${ALLOW_TCP_PORTS[@]}"; do
    iptables -A GEO_MAIN -p tcp --dport "$port" -m set --match-set "$IPSET_NAME" src -j ACCEPT
done

for port in "${ALLOW_UDP_PORTS[@]}"; do
    iptables -A GEO_MAIN -p udp --dport "$port" -m set --match-set "$IPSET_NAME" src -j ACCEPT
done

iptables -A GEO_MAIN -j DROP

# ========================================
# ACTIVATE
# ========================================
log "Activating firewall..."
iptables -I INPUT 1 -j GEO_MAIN

log "Saving rules..."
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
command -v netfilter-persistent >/dev/null && netfilter-persistent save 2>/dev/null || true

log "=========================================="
log "✓ SUCCESS"
log "  Countries: ${ALLOW_COUNTRIES[*]}"
log "  TCP: ${ALLOW_TCP_PORTS[*]} | UDP: ${ALLOW_UDP_PORTS[*]}"
log "  CIDR blocks: $total_cidrs"
if [[ $allowlist_count -gt 0 ]]; then
    log "  Allowlist entries: $allowlist_count"
fi
log "=========================================="
EOFMAIN

# Update the script with user configuration
sed -i "s/^ALLOW_COUNTRIES=.*/ALLOW_COUNTRIES=($CC_STR)/" "$FIREWALL_SCRIPT"
sed -i "s/^ALLOW_TCP_PORTS=.*/ALLOW_TCP_PORTS=($TCP_STR)/" "$FIREWALL_SCRIPT"
sed -i "s/^ALLOW_UDP_PORTS=.*/ALLOW_UDP_PORTS=($UDP_STR)/" "$FIREWALL_SCRIPT"
sed -i "s|^ALLOWLIST_URLS=.*|ALLOWLIST_URLS=($ALLOWLIST_URLS_STR)|" "$FIREWALL_SCRIPT"
sed -i "s/^ALLOWLIST_IPS=.*/ALLOWLIST_IPS=($ALLOWLIST_IPS_STR)/" "$FIREWALL_SCRIPT"

chmod +x "$FIREWALL_SCRIPT"

log "Creating emergency reset script..."

cat > "$BACKUP_SCRIPT" << 'EOFBACKUP'
#!/bin/bash
echo "=========================================="
echo "⚠️  EMERGENCY FIREWALL RESET"
echo "=========================================="
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F
iptables -X
ipset list -n | grep '^geo' | xargs -r -n1 ipset destroy 2>/dev/null || true
rm -f /etc/iptables/rules.v4
command -v netfilter-persistent >/dev/null && netfilter-persistent save 2>/dev/null || true
echo "✓ Firewall disabled - all traffic allowed"
echo "=========================================="
EOFBACKUP

chmod +x "$BACKUP_SCRIPT"

log "Creating systemd service..."

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=GeoIP Firewall
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$FIREWALL_SCRIPT
RemainAfterExit=yes
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload 2>&1 || true
systemctl enable geo-firewall.service 2>&1 || true

log "Setting up cron job..."

CRON_JOB="30 2 * * * $FIREWALL_SCRIPT >> $CRON_LOG 2>&1"
(crontab -l 2>/dev/null | grep -v "geo-firewall" || true; echo "$CRON_JOB") | crontab - 2>&1 || true

log "Cleaning old state..."

iptables -D INPUT -j GEO_MAIN 2>/dev/null || true
iptables -D INPUT -j GEO_NEW 2>/dev/null || true
iptables -F GEO_MAIN 2>/dev/null || true
iptables -F GEO_NEW 2>/dev/null || true
iptables -X GEO_MAIN 2>/dev/null || true
iptables -X GEO_NEW 2>/dev/null || true
ipset list -n | grep '^geo' | xargs -r -n1 ipset destroy 2>/dev/null || true

log "Applying firewall now..."

"$FIREWALL_SCRIPT" || {
    log "✗ Firewall apply failed - running emergency reset"
    "$BACKUP_SCRIPT"
    exit 1
}

log "✓ Setup complete"

echo ""
echo "╔════════════════════════════════════════╗"
echo "║     GEO FIREWALL ACTIVE                ║"
echo "╚════════════════════════════════════════╝"
echo ""
echo "Configuration:"
echo "  • Countries: ${ALLOW_COUNTRIES[*]}"
echo "  • TCP ports: ${ALLOW_TCP_PORTS[*]}"
echo "  • UDP ports: ${ALLOW_UDP_PORTS[*]}"
echo "  • Allowlist URLs: ${#ALLOWLIST_URLS[@]}"
echo "  • Allowlist IPs: ${#ALLOWLIST_IPS[@]}"
echo "  • Auto-update: Daily at 02:30"
echo ""
echo "Management:"
echo "  • Status:    systemctl status geo-firewall"
echo "  • Rules:     iptables -L GEO_MAIN -n -v"
echo "  • IP sets:   ipset list geo_allowed"
echo "  • Update:    $FIREWALL_SCRIPT"
echo "  • Reset:     $BACKUP_SCRIPT"
echo ""
echo "To modify: Edit $0 and run again"
echo ""
exit 0
