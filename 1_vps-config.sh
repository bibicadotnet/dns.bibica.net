#!/bin/bash
set -euo pipefail

# === PRIVILEGE & OS CHECK ===
(( EUID == 0 )) || { echo "ERROR: Run as root or with sudo!" >&2; exit 1; }
[ -f /etc/os-release ] || { echo "ERROR: Cannot detect OS." >&2; exit 1; }

. /etc/os-release
case ${ID:-} in
  ubuntu) (( ${VERSION_ID%%.*} >= 18 )) || exit 1 ;;
  debian) (( ${VERSION_ID%%.*} >= 10 )) || exit 1 ;;
  *) echo "ERROR: Only Debian/Ubuntu supported." >&2; exit 1 ;;
esac

# === ESSENTIAL PACKAGES ===
apt-get update -y
apt-get install -y curl wget git htop unzip nano zip zstd jq sudo \
  python3 net-tools lsof iputils-ping bind9-dnsutils

# === HOSTNAME & DNS ===
grep -q "$(hostname)" /etc/hosts || echo "127.0.0.1 $(hostname)" >> /etc/hosts

systemctl disable --now systemd-resolved &>/dev/null || :

{ [ -f /etc/resolv.conf ] && chattr -i /etc/resolv.conf 2>/dev/null; } || :
cat > /etc/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
chattr +i /etc/resolv.conf

# === SYSTEM TUNING ===
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-optimizations.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
vm.swappiness = 1
EOF
sysctl -p /etc/sysctl.d/99-optimizations.conf &>/dev/null || :

timedatectl set-timezone Asia/Ho_Chi_Minh

# === SWAPFILE ===
RAM_GB=$(($(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024))
SWAP_SIZE=$((RAM_GB <= 2 ? 2 : 4))G

swapoff /swapfile &>/dev/null || :
rm -f /swapfile
sed -i '\|/swapfile|d' /etc/fstab

if { fallocate -l "$SWAP_SIZE" /swapfile || 
     dd if=/dev/zero of=/swapfile bs=1M count=$(( ${SWAP_SIZE%G} * 1024 )) &>/dev/null; } 2>/dev/null
then
  chmod 600 /swapfile && mkswap /swapfile &>/dev/null && swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

# === DISABLE JOURNALD ===
systemctl mask --now systemd-journald{,-audit,-dev-log}.socket systemd-journald &>/dev/null || :

mkdir -p /etc/systemd/journald.conf.d
echo -e "[Journal]\nStorage=none" > /etc/systemd/journald.conf.d/no-logging.conf
rm -rf /var/log/journal /run/log/journal &>/dev/null || :
dmesg -C &>/dev/null || :

# === DISABLE TRANSPARENT HUGE PAGES ===
{ echo never > /sys/kernel/mm/transparent_hugepage/enabled &&
  echo never > /sys/kernel/mm/transparent_hugepage/defrag; } 2>/dev/null || :

cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
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
systemctl enable --now disable-thp.service &>/dev/null || :

# === SSH KEEPALIVE ===
SSH_CONFIG="/etc/ssh/sshd_config"
sed -i '/^\s*#\?\s*ClientAliveInterval/d;/^\s*#\?\s*ClientAliveCountMax/d' "$SSH_CONFIG"
echo -e "ClientAliveInterval 7200\nClientAliveCountMax 3" >> "$SSH_CONFIG"
systemctl restart sshd &>/dev/null || :

# === REMOVE UNNECESSARY SERVICES ===
apt purge -y qemu-guest-agent 2>/dev/null || true
systemctl stop getty@tty1.service serial-getty@ttyS0.service 2>/dev/null || true
systemctl mask getty@tty1.service serial-getty@ttyS0.service 2>/dev/null || true

# === CONFIGURE STATIC IP AND REMOVE DHCP CLIENTS ===
iface=$(ip route show default | awk '{print $5; exit}')
gw=$(ip route show default | awk '{print $3; exit}')
addr_cidr=$(ip -4 addr show dev "$iface" | awk '/inet/ && !/127\.0\.0\.1/ {print $2; exit}')

dpkg -l ifupdown &>/dev/null || apt install -y ifupdown

cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto $iface
iface $iface inet static
    address $addr_cidr
    gateway $gw
EOF

# Remove dhcpcd to prevent IP override
apt purge -y dhcpcd5 dhcpcd dhcpcd-base 2>/dev/null || true
apt autoremove -y 2>/dev/null || true

systemctl restart networking

# === DONE ===
cat <<'EOF'
========================================
VPS SETUP COMPLETED
========================================

Reboot to apply all settings:
  reboot
EOF
