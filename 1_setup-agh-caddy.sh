#!/bin/bash

# === AdGuard Home ===
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sudo bash -s -- -v -o /home

# Tạo script wrapper agh
sudo tee /usr/local/bin/agh << 'EOF'
#!/bin/bash
exec /home/AdGuardHome/AdGuardHome -s "$@"
EOF
sudo chmod +x /usr/local/bin/agh

# === Caddy + Plugin ===
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install caddy -y
caddy add-package github.com/caddy-dns/cloudflare

# === Cấu hình Caddy dùng /home ===
CADDY_HOME="/home/caddy"
sudo mkdir -p "$CADDY_HOME"
sudo cp /etc/caddy/Caddyfile "$CADDY_HOME/"
sudo chown -R caddy:caddy "$CADDY_HOME"

# === Override systemd ===
sudo mkdir -p /etc/systemd/system/caddy.service.d
cat << EOF | sudo tee /etc/systemd/system/caddy.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/caddy run --environ --config $CADDY_HOME/Caddyfile
Environment=XDG_DATA_HOME=$CADDY_HOME
EOF

sudo systemctl daemon-reload
sudo systemctl restart caddy

# Tạo script wrapper caddy
sudo tee /usr/local/bin/caddy <<'EOF'
#!/bin/bash
case "$1" in
    restart)   exec sudo systemctl restart caddy ;;
    start)     exec sudo systemctl start caddy ;;
    stop)      exec sudo systemctl stop caddy ;;
    status)    exec systemctl status caddy ;;
    logs)      exec journalctl -u caddy -n 100 -f ;;
    *)         exec /usr/bin/caddy "$@" ;;
esac
EOF
sudo chmod +x /usr/local/bin/caddy

hash -r
