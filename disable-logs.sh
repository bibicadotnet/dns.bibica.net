#!/bin/bash
set -e

# Check root
[ "$(id -u)" -ne 0 ] && echo "Run with sudo!" && exit 1

echo "Stopping journald service and sockets..."
systemctl stop systemd-journald systemd-journald.socket systemd-journald-dev-log.socket || true

echo "Masking journald to prevent auto-start..."
systemctl mask systemd-journald systemd-journald.socket systemd-journald-dev-log.socket || true

echo "Removing old journal files..."
rm -rf /var/log/journal /run/log/journal || true

echo "Creating empty /var/log/journal directory to avoid errors from some services..."
mkdir -p /var/log/journal
chmod 755 /var/log/journal

echo "Journald logging is now disabled."
echo "Reboot recommended to ensure changes take effect."
