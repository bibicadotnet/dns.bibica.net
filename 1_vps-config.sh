#!/bin/bash

set -euo pipefail

# ========================================
# SYSTEM CHECK AND PRIVILEGE VERIFICATION
# ========================================

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root or with sudo!" >&2
    exit 1
fi

# Check for supported Debian/Ubuntu system
if [ ! -f /etc/os-release ]; then
    echo "ERROR: Cannot determine operating system." >&2
    exit 1
fi

. /etc/os-release
v=${VERSION_ID%%.*}

if { [ "$ID" = ubuntu ] && [ "$v" -lt 18 ]; } || \
   { [ "$ID" = debian ] && [ "$v" -lt 10 ]; }; then
    echo "ERROR: $ID $VERSION_ID is not supported. Requires Ubuntu >= 18.04 or Debian >= 10" >&2
    exit 1
elif [ "$ID" != ubuntu ] && [ "$ID" != debian ]; then
    echo "ERROR: $ID is not supported. Only Debian/Ubuntu are supported" >&2
    exit 1
fi

# Essential applications list
ESSENTIAL_APPS=(
    curl wget git htop unzip nano zip zstd jq sudo python3 net-tools lsof iputils-ping chrony dnsutils
)

# ========================================
# SYSTEM INFORMATION DISPLAY FUNCTION
# ========================================

show_system_info() {
    cat <<EOF

========================================
SYSTEM INFORMATION
----------------------------------------
Hostname            : $(hostname)
OS                  : $(lsb_release -ds 2>/dev/null || awk -F= '/^PRETTY_NAME/ {gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || echo "Unknown")
Kernel              : $(uname -r)
Arch                : $(uname -m) ($(getconf LONG_BIT)-bit)
CPU                 : $(awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo)
CPU Cores           : $(nproc)
RAM                 : $(awk '/MemTotal:|MemAvailable:|MemFree:|Buffers:|Cached:/ {if($1=="MemTotal:") total=$2/1024; if($1=="MemAvailable:") avail=$2/1024; if($1=="MemFree:") free=$2/1024; if($1=="Buffers:") buffers=$2/1024; if($1=="Cached:") cached=$2/1024} END {used = total - free - buffers - cached; printf "%s total, %s used, %s available", (total<1000 ? int(total)" MB" : sprintf("%.1f GB",total/1024)), (used<1000 ? int(used)" MB" : sprintf("%.1f GB",used/1024)), (avail<1000 ? int(avail)" MB" : sprintf("%.1f GB",avail/1024))}' /proc/meminfo)
Swap                : $(awk '/SwapTotal:|SwapFree:/ {if($1=="SwapTotal:") total=$2/1024; if($1=="SwapFree:") free=$2/1024} END {used = total - free; if(total==0) print "None total, None used, None free"; else printf "%s total, %s used, %s free", (total<1000 ? int(total)" MB" : sprintf("%.1f GB",total/1024)), (used<1000 ? int(used)" MB" : sprintf("%.1f GB",used/1024)), (free<1000 ? int(free)" MB" : sprintf("%.1f GB",free/1024))}' /proc/meminfo)
Disk                : $(df -h / | awk 'NR==2 {print $2 " total, " $3 " used, " $4 " free"}')
Public IP           : $(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "Unknown")
Private IP          : $(ip -4 addr show | awk '/inet.*brd/ && !/127\.0\.0\.1/ {gsub(/\/.*/, "", $2); print $2; exit}')
Main Interface      : $(ip -4 route show default | awk '{print $5; exit}')
TCP CC              : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "Unknown")
Virtualization      : $(systemd-detect-virt 2>/dev/null || awk '/hypervisor/ {print "Yes"; exit} END {if(!found) print "None"}' /proc/cpuinfo)
Load Average        : $(awk '{print $1", "$2", "$3}' /proc/loadavg)
Uptime              : $(awk '{days=int($1/86400); hours=int(($1%86400)/3600); mins=int(($1%3600)/60); if(days>0) printf "%d days, ", days; if(hours>0) printf "%d hours, ", hours; printf "%d minutes", mins}' /proc/uptime)
Location            : $(curl -s --max-time 2 ipinfo.io/city 2>/dev/null), $(curl -s --max-time 2 ipinfo.io/country 2>/dev/null)
System Time         : $(date +'%d/%m/%Y at %I:%M %p (GMT%:z)')

========================================
SYSTEM CONFIGURATION
----------------------------------------
EOF

    # Display IPv6 configuration
    echo "[IPv6 Configuration]"
    if [ -f /etc/sysctl.d/99-disable-ipv6.conf ]; then
        grep -v '^\s*#' /etc/sysctl.d/99-disable-ipv6.conf | grep -v '^\s*$'
        echo "Status: $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | awk '{print $1 ? "DISABLED" : "ENABLED"}')"
    else
        echo "Not configured"
    fi
    echo

    # Display memory configuration
    echo "[Memory Configuration]"
    if [ -f /etc/sysctl.d/99-memory-config.conf ]; then
        grep -v '^\s*#' /etc/sysctl.d/99-memory-config.conf | grep -v '^\s*$'
        echo "Current swappiness: $(sysctl -n vm.swappiness 2>/dev/null || echo "Unknown")"
    else
        echo "Not configured"
    fi
    echo

    # Display swap configuration
    echo "[Swap Configuration]"
    if [ -f /swapfile ]; then
        swap_size=$(ls -lh /swapfile | awk '{print $5}')
        swap_used=$(swapon --show | awk '/\/swapfile/ {print $3}')
        echo "Swap file: /swapfile ($swap_size)"
        echo "Swap in use: $swap_used"
    else
        echo "No swap file configured"
    fi
    echo

    # Display DNS configuration
    echo "[DNS Configuration]"
    grep '^nameserver' /etc/resolv.conf || echo "No nameserver configuration"
    if lsattr /etc/resolv.conf 2>/dev/null | grep -q '\-i\-'; then
        echo "Status: Immutable file (protected)"
    else
        echo "Status: Writable file"
    fi
    echo

    # Display time configuration
    echo "[Time Configuration]"
    echo "Timezone: $(timedatectl show --property=Timezone --value 2>/dev/null || echo "Unknown")"
    echo "NTP synchronized: $(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "Unknown")"
    echo

    # Display Chrony status
    echo "[Chrony Time Sync]"
    if command -v chronyc >/dev/null 2>&1; then
        status=$(chronyc tracking 2>/dev/null | awk -F': ' '/Leap status/ {print $2}' || echo "Unknown")
        jitter_seconds=$(chronyc tracking 2>/dev/null | awk -F': ' '/Root dispersion/ {print $2}' | xargs || echo "0")
        jitter_ms=$(awk -v val="$jitter_seconds" 'BEGIN {printf "%.2f", val * 1000}')
        
        echo "Service status: $(systemctl is-active chrony 2>/dev/null || echo "inactive")"
        echo "Leap status    : $status"
        [[ -n "$jitter_ms" && "$jitter_ms" != "0.00" ]] && echo "Sync error     : ±${jitter_ms} ms"
    else
        echo "Chrony not installed"
    fi
    echo

    # Display SSH configuration
    echo "[SSH Configuration]"
    if [ -f /etc/ssh/sshd_config ]; then
        client_alive_interval=$(grep -E '^ClientAliveInterval' /etc/ssh/sshd_config | awk '{print $2}' || echo "Not set")
        client_alive_count=$(grep -E '^ClientAliveCountMax' /etc/ssh/sshd_config | awk '{print $2}' || echo "Not set")
        echo "ClientAliveInterval: $client_alive_interval"
        echo "ClientAliveCountMax: $client_alive_count"
    else
        echo "SSH config file not found"
    fi
    echo

    # Display THP configuration
    echo "[Transparent Huge Pages]"
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        thp_enabled=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | awk -F'[\\[\\]]' '{print $2}' || echo "unknown")
        thp_defrag=$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null | awk -F'[\\[\\]]' '{print $2}' || echo "unknown")
        echo "Enabled: $thp_enabled"
        echo "Defrag: $thp_defrag"
        echo "Service: $(systemctl is-active disable-thp.service 2>/dev/null || echo "not installed")"
    else
        echo "THP not available"
    fi
    echo

    # Display journald configuration
    echo "[Systemd Journald]"
    if systemctl is-active systemd-journald >/dev/null 2>&1; then
        echo "Status: ACTIVE"
    elif systemctl is-enabled systemd-journald >/dev/null 2>&1; then
        echo "Status: MASKED (logging disabled)"
    else
        echo "Status: INACTIVE"
    fi
    if [ -f /etc/systemd/journald.conf.d/no-logging.conf ]; then
        echo "Storage: none (no logging)"
    fi
    echo

    # Display installed software list
    echo "[Installed Essential Software]"
    installed_count=0
    for app in "${ESSENTIAL_APPS[@]}"; do 
        if command -v "$app" >/dev/null 2>&1 || dpkg -l | grep -q "^ii  $app "; then
            echo -n "$app "
            ((installed_count++))
        fi
    done
    echo
    echo "Total: $installed_count/${#ESSENTIAL_APPS[@]} applications installed"
    echo
}

# Check for --info parameter to only display information
if [[ "${1:-}" == "--info" ]]; then
    show_system_info
    exit 0
fi

# ========================================
# HOSTNAME AND DNS CONFIGURATION
# ========================================

# Add hostname to /etc/hosts if not present
HOSTNAME=$(hostname)
HOSTS_FILE="/etc/hosts"
if ! grep -q "$HOSTNAME" "$HOSTS_FILE"; then
    echo "127.0.0.1 $HOSTNAME" >> "$HOSTS_FILE"
fi

# Configure static DNS (8.8.8.8, 1.1.1.1)
systemctl disable --now systemd-resolved 2>/dev/null || true

# Remove immutable attribute if set and recreate resolv.conf
if [ -f /etc/resolv.conf ] && lsattr /etc/resolv.conf 2>/dev/null | grep -q '\-i\-'; then
    chattr -i /etc/resolv.conf
fi

rm -f /etc/resolv.conf
cat <<EOF > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
chattr +i /etc/resolv.conf

# ========================================
# OPERATING SYSTEM UPDATE
# ========================================

# Update package lists
apt-get update -y

# Install essential applications (skip if already installed)
for app in "${ESSENTIAL_APPS[@]}"; do
    if ! dpkg -l | grep -q "^ii  $app "; then
        apt-get install -y "$app"
    fi
done

# ========================================
# SYSTEM OPTIMIZATION
# ========================================

# Disable IPv6 for faster connections (idempotent)
cat <<EOF > /etc/sysctl.d/99-disable-ipv6.conf
# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1 || true

# Set timezone to Vietnam
timedatectl set-timezone Asia/Ho_Chi_Minh

# Start and enable Chrony for time synchronization
systemctl start chrony 2>/dev/null || true
systemctl enable chrony 2>/dev/null || true

# ========================================
# SWAP CREATION AND CONFIGURATION
# ========================================

# Calculate swap size based on RAM
RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
SWAP_SIZE=$([ $RAM_GB -le 2 ] && echo "2G" || echo "4G")

# Remove old swap if exists (idempotent)
swapoff /swapfile 2>/dev/null || true
rm -f /swapfile
sed -i '/\/swapfile/d' /etc/fstab

# Create new swap
fallocate -l $SWAP_SIZE /swapfile
chmod 600 /swapfile
mkswap /swapfile >/dev/null
swapon /swapfile
echo "/swapfile none swap sw 0 0" >> /etc/fstab

# Memory optimization configuration (idempotent)
cat <<EOF > /etc/sysctl.d/99-memory-config.conf
# Memory optimization
vm.swappiness = 10
EOF
sysctl -p /etc/sysctl.d/99-memory-config.conf >/dev/null 2>&1 || true

# ========================================
# DISABLE SYSTEMD-JOURNALD (NO LOGGING)
# ========================================

# Stop and mask journald to disable all logging (idempotent)
systemctl stop systemd-journald.socket systemd-journald-dev-log.socket systemd-journald-audit.socket 2>/dev/null || true
systemctl stop systemd-journald 2>/dev/null || true
systemctl mask systemd-journald systemd-journald.socket systemd-journald-dev-log.socket systemd-journald-audit.socket 2>/dev/null || true

# Configure no logging
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/no-logging.conf << 'EOF'
[Journal]
Storage=none
EOF

# Clean up journal directories
rm -rf /var/log/journal /run/log/journal 2>/dev/null || true
mkdir -p /var/log/journal
chmod 755 /var/log/journal

# Clear dmesg buffer
dmesg -C 2>/dev/null || true

# ========================================
# DISABLE TRANSPARENT HUGE PAGES (THP) - REQUIRED FOR GO APPS
# ========================================

# Disable THP immediately
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

# Create systemd service to disable THP permanently (idempotent)
cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=basic.target
EOF

systemctl daemon-reload
systemctl enable disable-thp.service 2>/dev/null || true
systemctl start disable-thp.service 2>/dev/null || true

# ========================================
# SSH CONFIGURATION
# ========================================

SSH_CONFIG="/etc/ssh/sshd_config"
# Remove existing ClientAlive configurations
sed -i '/^\s*#\?\s*ClientAliveInterval/d' "$SSH_CONFIG"
sed -i '/^\s*#\?\s*ClientAliveCountMax/d' "$SSH_CONFIG"
# Add new configurations
echo "ClientAliveInterval 7200" >> "$SSH_CONFIG"
echo "ClientAliveCountMax 3" >> "$SSH_CONFIG"
systemctl restart sshd 2>/dev/null || true

# ========================================
# FINAL COMPLETION MESSAGE
# ========================================

show_system_info

cat <<EOF

######################################################
# CONFIGURATION COMPLETE
# Please reboot to fully apply all settings (especially IPv6 and THP):
#
#         reboot now
#
# Please verify all configurations after reboot:
# - Check if IPv6 is disabled
# - Verify swap is active and correct size
# - Confirm time synchronization is working
# - Ensure DNS resolution works properly
# - Verify THP is disabled
# - Check that SSH timeout settings are applied
#
######################################################

EOF
