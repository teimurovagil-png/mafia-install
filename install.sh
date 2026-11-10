#!/usr/bin/env bash
# Установка «Мафия PRO» на чистый сервер Ubuntu 24.04 (Рег.облако).
# Запуск от root:  bash install.sh
set -euo pipefail

DOMAIN="mafia-pro.ru"
REPO="git@github.com:teimurovagil-png/mafia-pro-mobile.git"
REPO_443="ssh://git@ssh.github.com:443/teimurovagil-png/mafia-pro-mobile.git"
APP_DIR="/opt/mafia"
APP_USER="mafia"

[ "$(id -u)" = "0" ] || { echo "Run as root"; exit 1; }

echo "==> 1/6 Installing packages (2-5 min)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nodejs npm git caddy ufw

echo "==> 2/6 Creating user and GitHub access key"
id "$APP_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$APP_USER"
KEY="/home/$APP_USER/.ssh/id_ed25519"
if [ ! -f "$KEY" ]; then
  sudo -u "$APP_USER" mkdir -p "/home/$APP_USER/.ssh"
  sudo -u "$APP_USER" ssh-keygen -t ed25519 -N "" -C "mafia-server" -f "$KEY" >/dev/null
fi
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"

if [ ! -d "$APP_DIR/.git" ]; then
  # Временно показываем открытый ключ по обычной ссылке, чтобы его можно было скопировать из браузера.
  mkdir -p /usr/share/caddy
  cp "$KEY.pub" /usr/share/caddy/key.txt
  chmod 644 /usr/share/caddy/key.txt
  printf ':80 {\n\troot * /usr/share/caddy\n\tfile_server\n}\n' > /etc/caddy/Caddyfile
  systemctl restart caddy || true
  IP="$(curl -s -4 --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')"
  echo
  echo "------------------------------------------------------------------"
  echo "OPEN IN BROWSER ON YOUR PC:   http://$IP/key.txt"
  echo "Copy the whole line and add it to GitHub:"
  echo "repository -> Settings -> Deploy keys -> Add deploy key"
  echo "(Title: server, do NOT tick 'Allow write access')"
  echo
  echo "If the link does not open, the same key is:"
  cat "$KEY.pub"
  echo "------------------------------------------------------------------"
  mkdir -p "$APP_DIR" && chown "$APP_USER:$APP_USER" "$APP_DIR"
  while :; do
    read -r -p "When the key is added to GitHub, press Enter... " _
    if sudo -u "$APP_USER" env GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git clone "$REPO" "$APP_DIR" \
       || sudo -u "$APP_USER" env GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git clone "$REPO_443" "$APP_DIR"; then break; fi
    echo "Could not download the code. Check the key is added to GitHub and press Enter again."
    rm -rf "$APP_DIR"; mkdir -p "$APP_DIR"; chown "$APP_USER:$APP_USER" "$APP_DIR"
  done
  rm -f /usr/share/caddy/key.txt
fi

echo "==> 3/6 Installing game dependencies"
cd "$APP_DIR"
sudo -u "$APP_USER" npm install --omit=dev --no-audit --no-fund

echo "==> 4/6 Settings"
if [ ! -f /etc/mafia.env ]; then
  while :; do
    read -r -s -p "New HOST password (8+ chars, typing is hidden): " P1; echo
    read -r -s -p "Repeat password: " P2; echo
    [ "$P1" = "$P2" ] && [ "${#P1}" -ge 8 ] && break
    echo "Passwords differ or too short, try again."
  done
  umask 077
  printf 'PORT=3000\nPUBLIC_URL=https://%s\nHOST_PASSWORD=%s\n' "$DOMAIN" "$P1" > /etc/mafia.env
  chown root:root /etc/mafia.env; chmod 600 /etc/mafia.env
  umask 022
fi

echo "==> 5/6 Game autostart"
cat > /etc/systemd/system/mafia.service <<UNIT
[Unit]
Description=Mafia PRO
After=network.target

[Service]
User=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=/etc/mafia.env
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now mafia
systemctl restart mafia

cat > /usr/local/bin/mafia-update <<UPD
#!/usr/bin/env bash
# Подтянуть свежий код из GitHub и перезапустить игру
set -euo pipefail
cd $APP_DIR
sudo -u $APP_USER env GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" git pull --ff-only
sudo -u $APP_USER npm install --omit=dev --no-audit --no-fund
systemctl restart mafia
sleep 1
curl -s http://127.0.0.1:3000/healthz; echo
UPD
chmod +x /usr/local/bin/mafia-update

echo "==> 6/6 HTTPS and firewall"
cat > /etc/caddy/Caddyfile <<CADDY
$DOMAIN {
	reverse_proxy 127.0.0.1:3000
}
www.$DOMAIN {
	redir https://$DOMAIN{uri}
}
CADDY
systemctl enable caddy
systemctl restart caddy
ufw allow 22/tcp >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null

sleep 2
echo
echo "Game check:"
curl -s http://127.0.0.1:3000/healthz || echo "GAME NOT RESPONDING - run: journalctl -u mafia -n 30"
echo
echo "DONE. Site: https://$DOMAIN (certificate appears 1-2 min after the domain points here)"
echo "To update after GitHub changes run:  mafia-update"
