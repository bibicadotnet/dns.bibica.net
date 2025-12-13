#!/bin/bash
set -e

# Detect architecture
ARCH=$(uname -m)
case $ARCH in
  x86_64) ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  armv7l) ARCH="armv7" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Get latest version
LATEST=$(curl -s https://api.github.com/repos/pmkol/mosdns-x/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
[ -z "$LATEST" ] && { echo "Failed to get latest version"; exit 1; }

# Download and install binary
echo "Installing mosdns-x $LATEST for $ARCH..."
curl -sL "https://github.com/pmkol/mosdns-x/releases/download/$LATEST/mosdns-linux-$ARCH.zip" -o /tmp/mosdns.zip
unzip -qo /tmp/mosdns.zip -d /tmp
mkdir -p /home/mosdns-x/{bin,config,log}
mv -f /tmp/mosdns /home/mosdns-x/bin/
chmod +x /home/mosdns-x/bin/mosdns
rm -f /tmp/mosdns.zip

# Download config files (backup if exists)
echo "Downloading config files..."
[ -f /home/mosdns-x/config/config.yaml ] && cp /home/mosdns-x/config/config.yaml /home/mosdns-x/config/config.yaml.bak
[ -f /home/mosdns-x/config/cdn_domains.txt ] && cp /home/mosdns-x/config/cdn_domains.txt /home/mosdns-x/config/cdn_domains.txt.bak
curl -sL https://raw.githubusercontent.com/bibicadotnet/dns.bibica.net/main/mosdns-x/config.yaml -o /home/mosdns-x/config/config.yaml
curl -sL https://raw.githubusercontent.com/bibicadotnet/dns.bibica.net/main/mosdns-x/cdn_domains.txt -o /home/mosdns-x/config/cdn_domains.txt

# Create systemd service
cat > /etc/systemd/system/mosdns.service << 'EOF'
[Unit]
Description=mosdns-x DNS Server
After=network.target

[Service]
Type=simple
ExecStart=/home/mosdns-x/bin/mosdns start -c /home/mosdns-x/config/config.yaml -d /home/mosdns-x
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
systemctl daemon-reload
systemctl enable mosdns
systemctl restart mosdns

echo "tls" | tee /etc/modules-load.d/tls.conf
modprobe tls

echo "  mosdns-x installed successfully!"
echo "  Version: $LATEST"
echo "  Config: /home/mosdns-x/config/config.yaml"
[ -f /home/mosdns-x/config/config.yaml.bak ] && echo "  Backup: /home/mosdns-x/config/*.bak"
echo "  Status: systemctl status mosdns"
