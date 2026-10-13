#!/usr/bin/env bash
# Installiert die stream2beamer-Bedienseite auf dem Raspberry Pi (Pi 1/2/3, Raspberry Pi OS Buster).
# Aufruf im Ordner bedienseite (mit node_modules, ohne native Teile):  sudo bash install-pi.sh
# Braucht einmal Internet fuer Node.js (inoffizieller Build fuer ARMv6, mit SHA256-Pruefung).
set -euo pipefail
# Node 18: die ARMv6-Builds ab Node 20 brauchen eine neuere libstdc++ als Buster (GLIBCXX_3.4.30), getestet 13.10.2026.
# Node 18 ist seit 04/2025 ohne Sicherheitsupdates. Vertretbar, weil die Seite nur im ATEM-Netz erreichbar ist.
NODE_V="${NODE_V:-v18.20.8}"
APP=/opt/stream2beamer-bedienseite
SRC="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "bitte mit sudo starten"; exit 1; }

# ---------- Node.js ----------
ARCH="$(uname -m)"
case "$ARCH" in armv6l) NODE_ARCH=armv6l; BASE=https://unofficial-builds.nodejs.org/download/release ;;
  armv7l) NODE_ARCH=armv7l; BASE=https://nodejs.org/dist ;;
  aarch64) NODE_ARCH=arm64; BASE=https://nodejs.org/dist ;;
  *) echo "Architektur $ARCH nicht vorgesehen"; exit 1 ;; esac
if [ "$(/opt/node/bin/node -v 2>/dev/null || true)" != "$NODE_V" ]; then
  echo "[bedienseite] Node.js $NODE_V ($NODE_ARCH) laden"
  T="$(mktemp -d)"
  F="node-$NODE_V-linux-$NODE_ARCH.tar.xz"
  wget -q "$BASE/$NODE_V/$F" -O "$T/$F"
  wget -q "$BASE/$NODE_V/SHASUMS256.txt" -O "$T/SHASUMS256.txt"
  (cd "$T" && grep " $F\$" SHASUMS256.txt | sha256sum -c -) || { echo "SHA256 passt nicht, Abbruch"; exit 1; }
  mkdir -p /opt/node.neu
  tar -xJf "$T/$F" -C /opt/node.neu --strip-components=1
  /opt/node.neu/bin/node -v >/dev/null || { echo "Node $NODE_V startet auf diesem System nicht, alte Version bleibt"; rm -r /opt/node.neu "$T"; exit 1; }
  [ -d /opt/node ] && mv /opt/node "/opt/node.alt.$(date +%s)"
  mv /opt/node.neu /opt/node
  rm -r "$T"
fi
echo "[bedienseite] $(/opt/node/bin/node -e 'console.log("Node", process.version, process.arch)')"

# ---------- Programm ----------
echo "[bedienseite] Programm nach $APP"
mkdir -p "$APP"
cp -r "$SRC/server.js" "$SRC/lib.js" "$SRC/package.json" "$SRC/public" "$SRC/node_modules" "$SRC/stubs" "$APP/"
chown -R root:root "$APP"
/opt/node/bin/node -e "require('$APP/node_modules/atem-connection'); console.log('[bedienseite] atem-connection laedt')"

# ---------- Port 80 frei machen: nginx wird nur fuer RTMP gebraucht, seine Standard-Webseite belegt sonst Port 80 ----------
if [ -L /etc/nginx/sites-enabled/default ]; then
  echo "[bedienseite] nginx-Standardseite abschalten (bleibt in sites-available/default)"
  rm /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
fi

# ---------- Dienst (Port 80 ohne root dank Capability) ----------
cat >/etc/systemd/system/stream2beamer-bedienseite.service <<'EOF'
[Unit]
Description=stream2beamer-Bedienseite im Browser (http://192.168.10.20)
After=network-online.target
Wants=network-online.target

[Service]
User=pi
WorkingDirectory=/opt/stream2beamer-bedienseite
Environment=ATEM_IP=192.168.10.240 PORT=80 PI_IP=192.168.10.20 LAPTOP_IP=192.168.10.10 ALLOW_NETS=192.168.10.0/24,127.0.0.1/32
ExecStart=/opt/node/bin/node server.js
AmbientCapabilities=CAP_NET_BIND_SERVICE
# /run/stream2beamer-bedienseite (gehoert pi): dort legt der Knopf 'Pi herunterfahren' seine Markierung ab
RuntimeDirectory=stream2beamer-bedienseite
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
# Herunterfahren per Knopf: Root-Dienst wartet auf die Markierung der Bedienseite (die selbst ohne Root laeuft)
cat >/etc/systemd/system/stream2beamer-poweroff.path <<'EOF'
[Unit]
Description=stream2beamer-Bedienseite: Knopf "Pi herunterfahren"

[Path]
PathExists=/run/stream2beamer-bedienseite/poweroff
Unit=stream2beamer-poweroff.service

[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/stream2beamer-poweroff.service <<'EOF'
[Unit]
Description=Raspberry Pi herunterfahren (angefordert ueber die Bedienseite)

[Service]
Type=oneshot
ExecStart=/bin/systemctl poweroff
EOF
systemctl daemon-reload
systemctl enable --now stream2beamer-poweroff.path >/dev/null
systemctl enable stream2beamer-bedienseite >/dev/null
systemctl restart stream2beamer-bedienseite
sleep 8
echo "[bedienseite] Dienst: $(systemctl is-active stream2beamer-bedienseite)"
journalctl -u stream2beamer-bedienseite -n 5 --no-pager
