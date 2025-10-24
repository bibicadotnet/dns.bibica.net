#!/bin/bash
set -euo pipefail

# ========================================
# ROOT & SYSTEM CHECK
# ========================================
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root" >&2
    exit 1
fi

if ! command -v ip >/dev/null; then
    echo "ERROR: 'ip' command not found" >&2
    exit 1
fi

# ========================================
# AUTO-DETECT NETWORK CONFIG
# ========================================

# Detect main interface (default route)
INTERFACE=$(ip route show default | awk '{print $5; exit}')
if [ -z "$INTERFACE" ]; then
    echo "ERROR: No default interface found" >&2
    exit 1
fi

# Detect private IP (first non-loopback IPv4)
PRIVATE_IP=$(ip -4 addr show dev "$INTERFACE" | awk '/inet/ {print $2; exit}' | cut -d'/' -f1)
if [ -z "$PRIVATE_IP" ]; then
    echo "ERROR: No private IP found on $INTERFACE" >&2
    exit 1
fi

# Detect prefix (CIDR)
PREFIX=$(ip -4 addr show dev "$INTERFACE" | awk '/inet/ {print $2; exit}' | cut -d'/' -f2)
if [ -z "$PREFIX" ]; then
    echo "ERROR: Could not detect CIDR prefix" >&2
    exit 1
fi

# Detect gateway
GATEWAY=$(ip route show default | awk '{print $3; exit}')
if [ -z "$GATEWAY" ]; then
    echo "ERROR: No gateway found" >&2
    exit 1
fi

echo "Detected:"
echo "  Interface: $INTERFACE"
echo "  IP:        $PRIVATE_IP/$PREFIX"
echo "  Gateway:   $GATEWAY"
echo

# ========================================
# INSTALL ifupdown (if not present)
# ========================================
if ! dpkg -l ifupdown >/dev/null 2>&1; then
    echo "Installing ifupdown..."
    apt update -y
    apt install -y ifupdown
fi

# ========================================
# CONFIGURE /etc/network/interfaces
# ========================================
cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto $INTERFACE
iface $INTERFACE inet static
    address $PRIVATE_IP/$PREFIX
    gateway $GATEWAY
EOF

echo "Configured /etc/network/interfaces"

# ========================================
# APPLY STATIC IP (safe during SSH)
# ========================================
echo "Applying static IP configuration..."

# Add static IP (if not already present)
if ! ip addr show "$INTERFACE" | grep -q "$PRIVATE_IP/$PREFIX"; then
    ip addr add "$PRIVATE_IP/$PREFIX" dev "$INTERFACE"
fi

# Remove dynamic IP (if exists)
if ip addr show "$INTERFACE" | grep -q "dynamic"; then
    ip addr del "$PRIVATE_IP/$PREFIX" dev "$INTERFACE" 2>/dev/null || true
fi

# Restart networking
systemctl restart networking

# ========================================
# CONFIGURE DNS (immutable)
# ========================================
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
chattr +i /etc/resolv.conf
echo "DNS configured and locked"

# ========================================
# REMOVE dhcpcd (if present)
# ========================================
if systemctl is-active --quiet dhcpcd 2>/dev/null || dpkg -l | grep -q dhcpcd; then
    echo "Removing dhcpcd..."
    systemctl stop dhcpcd 2>/dev/null || true
    systemctl disable dhcpcd 2>/dev/null || true
    apt purge -y dhcpcd5 dhcpcd-base dhcpcd 2>/dev/null || true
    apt autoremove -y 2>/dev/null || true
    echo "dhcpcd removed"
fi

# ========================================
# FINAL CHECK
# ========================================
echo
echo "Static IP setup complete!"
echo
ip addr show "$INTERFACE" | grep "inet "
ip route show default
echo
echo "Test connectivity:"
ping -c 2 8.8.8.8 >/dev/null && echo "Internet OK" || echo "Internet failed"
