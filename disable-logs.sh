#!/bin/bash
set -e

# Check root
[ "$(id -u)" -ne 0 ] && echo "Run with sudo!" && exit 1

echo "Stopping journald service and sockets..."
systemctl stop systemd-journald systemd-journald.socket systemd-journald-dev-log.socket systemd-journald-audit.socket 2>/dev/null || true

echo "Masking journald to prevent auto-start..."
systemctl mask systemd-journald systemd-journald.socket systemd-journald-dev-log.socket systemd-journald-audit.socket 2>/dev/null || true

echo "Disabling persistent journal..."
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/no-logging.conf << 'EOF'
[Journal]
Storage=none
EOF

echo "Removing old journal files..."
rm -rf /var/log/journal /run/log/journal || true

echo "Creating empty /var/log/journal directory..."
mkdir -p /var/log/journal
chmod 755 /var/log/journal

echo "Clearing kernel ring buffer..."
dmesg -C 2>/dev/null || true

echo "Done! Reboot to apply changes."
