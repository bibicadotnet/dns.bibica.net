#!/bin/bash

# AdGuardHome Auto Config

# Check root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

# Check htpasswd installation
if ! command -v htpasswd &> /dev/null; then
    apt-get update > /dev/null 2>&1 && apt-get install -y apache2-utils > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Failed to install apache2-utils"
        exit 1
    fi
fi

# Get user input
read -p "Enter username: " username
while [ -z "$username" ]; do
    read -p "Username cannot be empty: " username
done

read -s -p "Enter password: " password
echo ""
while [ -z "$password" ]; do
    read -s -p "Password cannot be empty: " password
    echo ""
done

read -s -p "Confirm password: " password_confirm
echo ""
while [ "$password" != "$password_confirm" ]; do
    echo "Passwords do not match!"
    read -s -p "Enter password: " password
    echo ""
    read -s -p "Confirm password: " password_confirm
    echo ""
done

# Generate password hash
password_hash=$(htpasswd -B -C 10 -n -b "$username" "$password" 2>/dev/null | cut -d: -f2)

if [ -z "$password_hash" ]; then
    echo "Failed to generate password hash"
    exit 1
fi

# Download template file
wget -q -O /tmp/AdGuardHome_template.yaml https://raw.githubusercontent.com/bibicadotnet/dns.bibica.net/refs/heads/main/AdGuardHome.yaml

if [ $? -ne 0 ]; then
    echo "Failed to download template file"
    exit 1
fi

# Verify template format
if ! grep -q "username_xxxxxxx" /tmp/AdGuardHome_template.yaml || ! grep -q "password_xxxxxxx" /tmp/AdGuardHome_template.yaml; then
    echo "Invalid template format - missing username_xxxxxxx or password_xxxxxxx"
    exit 1
fi

# Stop AdGuardHome container
docker stop adguardhome > /dev/null 2>&1

# Replace using awk (safe for special characters)
awk -v user="$username" -v pass="$password_hash" '
    { 
        gsub("username_xxxxxxx", user)
        gsub("password_xxxxxxx", pass)
        print
    }
' /tmp/AdGuardHome_template.yaml > /tmp/AdGuardHome_new.yaml

# Backup old config and apply new one
if [ -f "/home/adguardhome/adguard/config/AdGuardHome.yaml" ]; then
    backup_file="/home/adguardhome/adguard/config/AdGuardHome.yaml.backup.$(date +%Y%m%d_%H%M%S)"
    cp "/home/adguardhome/adguard/config/AdGuardHome.yaml" "$backup_file"
fi

cp /tmp/AdGuardHome_new.yaml /home/adguardhome/adguard/config/AdGuardHome.yaml

# Start AdGuardHome container
docker start adguardhome > /dev/null 2>&1

# Cleanup
rm -f /tmp/AdGuardHome_template.yaml /tmp/AdGuardHome_new.yaml

echo "Configuration completed successfully"
echo "Username: $username"
echo "Config file: /home/adguardhome/adguard/config/AdGuardHome.yaml"
