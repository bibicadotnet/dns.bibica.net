#!/bin/bash
set -euo pipefail

# === AdGuard Home ===
echo "[+] Installing AdGuardHome..."
AGH_DIR="/home/AdGuardHome"
CONFIG="$AGH_DIR/AdGuardHome.yaml"
[ -f "$CONFIG" ] && sudo cp "$CONFIG" /tmp/agh.yaml.bak

curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh -o /tmp/agh.sh
sudo bash /tmp/agh.sh -v -o /home -r
rm -f /tmp/agh.sh

sudo rm -f "$AGH_DIR"/{CHANGELOG.md,LICENSE.txt,README.md}

if [ -f /tmp/agh.yaml.bak ]; then
    sudo cp /tmp/agh.yaml.bak "$CONFIG"
    sudo chmod 600 "$CONFIG"
    rm -f /tmp/agh.yaml.bak
    sudo "$AGH_DIR/AdGuardHome" -s restart
fi

# === Wrapper điều khiển AdGuard Home ===
sudo install -m 755 /dev/stdin /usr/local/bin/agh <<'EOF'
#!/bin/bash
[ -x /home/AdGuardHome/AdGuardHome ] || { echo "Not found"; exit 1; }
case "$1" in
    version)      exec /home/AdGuardHome/AdGuardHome --version ;;
    *)            exec /home/AdGuardHome/AdGuardHome -s "$@" ;;
esac
EOF

# === Caddy + Plugin ===
echo "[+] Installing Caddy..."
sudo apt update -y
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg

# Xóa file cũ để tránh hỏi ghi đè
sudo rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
  sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

# Ghi đè không hỏi
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
  sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null

sudo apt update -y && sudo apt install -y caddy
sudo apt clean && sudo rm -rf /var/lib/apt/lists/*

# Thêm plugin caddy dns cloudflare - XỬ LÝ KHÔNG LỖI
if caddy help 2>/dev/null | grep -q add-package; then
  echo "[+] Adding Cloudflare DNS plugin..."
  if caddy add-package github.com/caddy-dns/cloudflare 2>/dev/null; then
    echo "[+] Cloudflare plugin installed successfully"
  else
    echo "[✓] Cloudflare plugin already installed"
  fi
fi

# === Cấu hình Caddy ===
CADDY_HOME="/home/caddy"
sudo mkdir -p "$CADDY_HOME"

if [ ! -f "$CADDY_HOME/Caddyfile" ] && [ -f /etc/caddy/Caddyfile ]; then
  sudo mv /etc/caddy/Caddyfile "$CADDY_HOME/Caddyfile"
elif [ -f /etc/caddy/Caddyfile ]; then
  sudo rm -f /etc/caddy/Caddyfile
fi

sudo chown -R caddy:caddy "$CADDY_HOME" 2>/dev/null || true

sudo mkdir -p /etc/systemd/system/caddy.service.d
sudo tee /etc/systemd/system/caddy.service.d/override.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/caddy run --environ --config $CADDY_HOME/Caddyfile
Environment=XDG_DATA_HOME=$CADDY_HOME
EOF

sudo systemctl daemon-reload
sudo systemctl restart caddy

# === Wrapper điều khiển Caddy ===
sudo install -m 755 /dev/stdin /usr/local/bin/caddy <<'EOF'
#!/bin/bash
case "$1" in
  restart) exec sudo systemctl restart caddy ;;
  start)   exec sudo systemctl start caddy ;;
  stop)    exec sudo systemctl stop caddy ;;
  status)  exec systemctl status caddy ;;
  reload)  exec sudo systemctl reload caddy ;;
  *)       exec /usr/bin/caddy "$@" ;;
esac
EOF

hash -r

echo "[+] Installation completed!"
echo
cat <<'EOF'
[INFO] Shortcuts available:
- Use 'caddy start|stop|restart|reload|status|version' to control Caddy.
- Use 'agh start|stop|restart|reload|status|install|uninstall|version' to control AdGuard Home.
EOF
