#!/usr/bin/env bash
# pi-atem-bridge.sh  (Raspberry Pi 1 B+, 2, 3 mit Raspberry Pi OS Buster Lite)
# ATEM Mini Pro ISO streamt per RTMP an den Pi, der Pi zeigt das Programmbild am HDMI-Ausgang.
# Basis: Aaron Parecki, "How to make an RTMP Streaming Server and Player with a Raspberry Pi" (2020)
#
# Aufbau:  nginx (RTMP-Empfang)  ->  Dienst stream2beamer-player (omxplayer, Hardware-Decoder der GPU)  ->  HDMI
#
# Aufruf:  sudo bash pi-atem-bridge.sh
# Optionen per Umgebungsvariable:
#   PUBLISH_NET=192.168.1.0/24   Netz, aus dem gestreamt werden darf (Default: 192.168.10.0/24 = ATEM-Netz)
#   STREAM_KEY=beamer            interner Streamname. Der Schluessel im ATEM ist egal (auch leer), siehe nginx-Abschnitt
#   PI_IP=192.168.10.20          Adresse des Pi am Switch ohne Router (dhcpcd-Fallback) und Ziel in der ATEM-Datei
#   STATIC_FALLBACK=1            Fallback-Adresse setzen (Default: 1). 0 = nur DHCP, ATEM-Datei bekommt die aktuelle IP
#   HDMI_MODE=4                  CEA-Modus (4=720p60 Default, 16=1080p60, 31=1080p50, 33=1080p25, 34=1080p30), auto = vom Beamer
#                                Grund fuer 720p als Default: Beamer meldeten ihre Daten nicht (tvservice "No device present"),
#                                der Pi fiel auf 640x480 4:3 zurueck und das 16:9-Bild war gestaucht (getestet 13.10.2026)
#   AUDIO=hdmi|none              Ton über HDMI (Default) oder HDMI stumm
#   BLACK_SCREEN=1               Login-Konsole auf HDMI abschalten (dann nur noch per SSH bedienbar)
#   ENABLE_SSH=1                 SSH aktivieren (Default: 1)
#   FIX_APT=1                    Paketquellen automatisch auf legacy.raspbian.org umstellen (Default: 1)

set -euo pipefail

PUBLISH_NET="${PUBLISH_NET:-192.168.10.0/24}"
STREAM_KEY="${STREAM_KEY:-beamer}"
PI_IP="${PI_IP:-192.168.10.20}"
STATIC_FALLBACK="${STATIC_FALLBACK:-1}"
HDMI_MODE="${HDMI_MODE:-4}"
AUDIO="${AUDIO:-hdmi}"
BLACK_SCREEN="${BLACK_SCREEN:-0}"
ENABLE_SSH="${ENABLE_SSH:-1}"
FIX_APT="${FIX_APT:-1}"
PI_USER="${SUDO_USER:-pi}"
[ "$PI_USER" = "root" ] && PI_USER="pi"

MARK_BEGIN="# >>> pi-atem-bridge >>>"
MARK_END="# <<< pi-atem-bridge <<<"
BOOT_CFG="/boot/config.txt"
BOOT_CMD="/boot/cmdline.txt"
NGINX_MAIN="/etc/nginx/nginx.conf"
RTMP_CONF="/etc/nginx/rtmp-bridge.conf"
PLAYER_SH="/usr/local/bin/stream2beamer-player.sh"
SERVICE="/etc/systemd/system/stream2beamer-player.service"
APT_MAIN="/etc/apt/sources.list"

log()  { printf '\n[bridge] %s\n' "$*"; }
warn() { printf '\n[bridge] HINWEIS: %s\n' "$*"; }
fail() { printf '\n[bridge] FEHLER: %s\n' "$*" >&2; exit 1; }

# Datei atomar schreiben: Inhalt aus stdin -> Temp-Datei -> Leer-Check -> mv
atomic_write() {
  local target="$1" mode="${2:-644}" tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  cat > "$tmp"
  [ -s "$tmp" ] || { rm -f "$tmp"; fail "leerer Inhalt für $target, nichts geschrieben"; }
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$target"
}

# Einmalige Sicherung der Originaldatei (wird nie überschrieben)
backup_once() {
  local f="$1"
  [ -f "${f}.orig-bridge" ] || cp -p "$f" "${f}.orig-bridge"
}

# ---------- 1. Vorprüfungen ----------
[ "$(id -u)" -eq 0 ] || fail "bitte mit sudo starten"
grep -q 'VERSION_CODENAME=buster' /etc/os-release \
  || fail "kein Buster erkannt. omxplayer gibt es nur bis Raspberry Pi OS Buster."
MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
case "$MODEL" in *"Raspberry Pi"*) ;; *) fail "kein Raspberry Pi erkannt";; esac
case "$AUDIO" in hdmi|none) ;; *) fail "AUDIO muss hdmi oder none sein";; esac
case "$STREAM_KEY" in *[!A-Za-z0-9_-]*|"") fail "STREAM_KEY nur aus Buchstaben, Ziffern, _ und -";; esac
case "$STATIC_FALLBACK" in 0|1) ;; *) fail "STATIC_FALLBACK muss 0 oder 1 sein";; esac
case "$HDMI_MODE" in auto) ;; *[!0-9]*|"") fail "HDMI_MODE muss eine Zahl oder auto sein";; esac
echo "$PI_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || fail "PI_IP ist keine IPv4-Adresse: $PI_IP"
id "$PI_USER" >/dev/null 2>&1 || fail "Benutzer $PI_USER existiert nicht"
log "Gerät: $MODEL"
case "$MODEL" in
  *"Pi 4"*|*"Pi 5"*)   # erfasst auch Pi 400
    fail "Pi 4/5 dekodiert mit omxplayer nicht. Für Pi 4/5 ein anderes Rezept verwenden." ;;
  "Raspberry Pi Model"*|*"Zero"*)   # Pi 1 heißt nur "Raspberry Pi Model ...", Pi 2/3 tragen die Ziffer
    warn "Pi 1 / Zero: der Prozessor ist schwach. Rechne mit mehreren Sekunden Verzögerung." ;;
esac

# ---------- 2. Paketquellen (Buster liegt seit Ende 2025 auf legacy.raspbian.org) ----------
fix_sources() {
  local f="$1"
  [ -f "$f" ] || return 0
  if grep -Eq 'raspbian\.raspberrypi\.org|mirrordirector\.raspbian\.org|archive\.raspbian\.org' "$f"; then
    log "Paketquelle umstellen: $f"
    backup_once "$f"
    sed -E 's#https?://(raspbian\.raspberrypi\.org|mirrordirector\.raspbian\.org|archive\.raspbian\.org)/#http://legacy.raspbian.org/#g' "$f" \
      | atomic_write "$f"
  fi
}
if [ "$FIX_APT" = "1" ]; then
  fix_sources "$APT_MAIN"
  for f in /etc/apt/sources.list.d/*.list; do fix_sources "$f"; done
fi

log "Paketlisten aktualisieren"
apt-get update || fail "apt-get update fehlgeschlagen. Inhalt von $APT_MAIN prüfen, Buster gehört nach http://legacy.raspbian.org/raspbian/"
log "nginx, RTMP-Modul und omxplayer installieren"
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx libnginx-mod-rtmp omxplayer

# omxplayer braucht die GPU-Bibliotheken aus /opt/vc/lib; fehlt der Suchpfad, nachtragen
OMX_BIN="$(command -v omxplayer.bin || true)"
[ -n "$OMX_BIN" ] || OMX_BIN="/usr/bin/omxplayer.bin"
if [ -x "$OMX_BIN" ] && ldd "$OMX_BIN" | grep -q 'not found'; then
  log "GPU-Bibliotheken in den Suchpfad aufnehmen"
  echo "/opt/vc/lib" | atomic_write /etc/ld.so.conf.d/00-vmcs.conf
  ldconfig
fi
if [ -x "$OMX_BIN" ] && ldd "$OMX_BIN" | grep -q 'not found'; then
  ldd "$OMX_BIN" | grep 'not found' >&2
  fail "omxplayer findet Bibliotheken nicht (siehe oben)"
fi
usermod -aG video "$PI_USER"

# ---------- 3. RTMP-Empfang (nginx) ----------
log "RTMP-Konfiguration schreiben: $RTMP_CONF"
atomic_write "$RTMP_CONF" <<EOF
# erzeugt von pi-atem-bridge.sh
rtmp {
  server {
    listen 1935;
    chunk_size 4096;

    # Eingang vom ATEM. Der Stream Key ist egal (auch leer): jeder Stream wird intern
    # als view/${STREAM_KEY} weitergereicht. Grund: Beim Laden der XML uebernimmt der ATEM
    # keinen Schluessel, das Feld blieb leer und der Player fand nichts (getestet 13.10.2026).
    application live {
      live on;
      record off;
      # nur aus dem eigenen Netz senden lassen
      allow publish ${PUBLISH_NET};
      allow publish 127.0.0.1;
      deny publish all;
      deny play all;
      push rtmp://127.0.0.1:1935/view name=${STREAM_KEY};
    }

    # intern: nur der Pi selbst sendet und spielt ab
    application view {
      live on;
      record off;
      # Player ohne Sender sofort trennen -> Player-Dienst startet sauber neu
      idle_streams off;
      allow publish 127.0.0.1;
      deny publish all;
      allow play 127.0.0.1;
      deny play all;
    }
  }
}
EOF

if ! grep -qF "include ${RTMP_CONF};" "$NGINX_MAIN"; then
  log "RTMP-Konfiguration in nginx.conf einbinden"
  backup_once "$NGINX_MAIN"
  { cat "$NGINX_MAIN"; printf '\n%s\ninclude %s;\n%s\n' "$MARK_BEGIN" "$RTMP_CONF" "$MARK_END"; } \
    | atomic_write "$NGINX_MAIN"
fi
nginx -t || fail "nginx-Konfiguration ungültig, siehe Meldung oben"
systemctl enable nginx >/dev/null
systemctl restart nginx

# ---------- 4. Player-Dienst (omxplayer als $PI_USER, Endlosschleife) ----------
if [ "$AUDIO" = "hdmi" ]; then OMX_AUDIO="hdmi"; else OMX_AUDIO="local"; fi

log "Player-Skript schreiben: $PLAYER_SH"
atomic_write "$PLAYER_SH" 755 <<EOF
#!/usr/bin/env bash
# erzeugt von pi-atem-bridge.sh: wartet auf den ATEM-Stream und zeigt ihn per HDMI.
URL="rtmp://127.0.0.1:1935/view/${STREAM_KEY}"
while true; do
  START=\$(date +%s)
  omxplayer --live --blank --no-osd --no-keys -o ${OMX_AUDIO} "\$URL" </dev/null || true
  # ohne Sender trennt nginx sofort; kurze Pause verhindert Dauerschleife
  [ \$((\$(date +%s) - START)) -lt 3 ] && sleep 1
done
EOF

log "Dienst schreiben: $SERVICE"
atomic_write "$SERVICE" <<EOF
[Unit]
Description=ATEM Programmbild per HDMI (omxplayer)
After=network-online.target nginx.service
Wants=network-online.target

[Service]
User=${PI_USER}
SupplementaryGroups=video
ExecStart=${PLAYER_SH}
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable stream2beamer-player.service >/dev/null

# ---------- 5. GPU-Speicher und HDMI ----------
log "GPU-Speicher und HDMI in $BOOT_CFG"
backup_once "$BOOT_CFG"
{
  sed "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/d" "$BOOT_CFG"
  echo "$MARK_BEGIN"
  echo "gpu_mem=128"            # Hardware-Decoder braucht Speicher für 1080p
  echo "hdmi_force_hotplug=1"   # HDMI aktiv, auch wenn der Beamer beim Booten aus ist
  echo "disable_overscan=1"
  echo "hdmi_drive=2"           # Ton über HDMI
  if [ "$HDMI_MODE" != "auto" ]; then
    echo "hdmi_group=1"
    echo "hdmi_mode=${HDMI_MODE}"
  fi
  echo "$MARK_END"
} | atomic_write "$BOOT_CFG"

log "Bootanzeige beruhigen ($BOOT_CMD)"
backup_once "$BOOT_CMD"
CMDLINE="$(head -n1 "$BOOT_CMD")"
for opt in consoleblank=0 logo.nologo vt.global_cursor_default=0 quiet; do
  case " $CMDLINE " in *" $opt "*) ;; *) CMDLINE="$CMDLINE $opt";; esac
done
printf '%s\n' "$CMDLINE" | atomic_write "$BOOT_CMD"

# ---------- 6. Optionen ----------
if [ "$ENABLE_SSH" = "1" ]; then
  systemctl enable --now ssh >/dev/null 2>&1 || warn "SSH konnte nicht aktiviert werden"
fi
if [ "$BLACK_SCREEN" = "1" ]; then
  log "Login-Konsole auf HDMI abschalten (Bedienung nur noch per SSH)"
  systemctl disable getty@tty1 >/dev/null 2>&1 || true
fi

# Am Router DHCP, am Switch ohne Router feste Adresse im ATEM-Netz (dhcpcd-Fallback)
DHCPCD="/etc/dhcpcd.conf"
if [ "$STATIC_FALLBACK" = "1" ] && [ -f "$DHCPCD" ]; then
  log "Fallback-Adresse ${PI_IP}/24 fuer eth0 ohne DHCP ($DHCPCD)"
  backup_once "$DHCPCD"
  {
    sed "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/d" "$DHCPCD"
    echo "$MARK_BEGIN"
    # mit WLAN-Hotspot (pi-hotspot.sh) haengen eth0 und wlan0 an der Bruecke br0
    if [ -f /etc/systemd/network/stream2beamer-br0.netdev ]; then
      NET_IF="br0"; echo "denyinterfaces eth0 wlan0"
    else
      NET_IF="eth0"
    fi
    echo "profile beamer_static"
    echo "static ip_address=${PI_IP}/24"
    echo "interface ${NET_IF}"
    echo "fallback beamer_static"
    echo "$MARK_END"
  } | atomic_write "$DHCPCD"
  if [ "$(grep -c '^profile beamer_static' "$DHCPCD")" -gt 1 ]; then
    warn "beamer_static steht mehrfach in $DHCPCD (aelterer Eintrag ohne Markierung). Bitte pruefen."
  fi
fi

# ---------- 7. ATEM-Streamingdatei ----------
if [ "$STATIC_FALLBACK" = "0" ]; then
  PI_IP="$(hostname -I | awk '{print $1}')"
  [ -n "$PI_IP" ] || PI_IP="IP_DES_PI"
fi
PI_HOME="$(getent passwd "$PI_USER" | cut -d: -f6)"
XML_OUT="${PI_HOME}/atem-raspberry-pi.xml"
log "ATEM-Streamingdatei schreiben: $XML_OUT"
atomic_write "$XML_OUT" <<EOF
<streaming>
    <service>
        <name>Raspberry Pi Beamer</name>
        <servers>
            <server>
                <name>Pi ${PI_IP}</name>
                <url>rtmp://${PI_IP}/live</url>
            </server>
        </servers>
        <profiles>
            <profile>
                <name>Pi Beamer</name>
                <config resolution="1080p" fps="30">
                    <bitrate>4500000</bitrate>
                    <audio-bitrate>128000</audio-bitrate>
                    <keyframe-interval>1</keyframe-interval>
                </config>
                <config resolution="1080p" fps="60">
                    <bitrate>6000000</bitrate>
                    <audio-bitrate>128000</audio-bitrate>
                    <keyframe-interval>1</keyframe-interval>
                </config>
            </profile>
        </profiles>
    </service>
</streaming>
EOF
chown "$PI_USER:$PI_USER" "$XML_OUT" 2>/dev/null || true

log "Fertig. Jetzt neu starten: sudo reboot"
cat <<EOF

  ATEM:   Datei ${XML_OUT} auf den PC kopieren und in ATEM Software Control laden,
          Plattform "Raspberry Pi Beamer". Stream Key egal (leer geht auch).
  Netz:   am Switch ohne Router hat der Pi ${PI_IP}, am Router seine DHCP-Adresse.
  WICHTIG: ATEM auf 1080p25 oder 1080p30 stellen. Der Decoder des Pi schafft 50p/60p nicht flüssig.
  Status: systemctl status stream2beamer-player    Log: journalctl -u stream2beamer-player -f
  Tipp:   dem Pi im Router eine feste IP geben.
  Rückweg: Originale liegen als *.orig-bridge neben den geänderten Dateien.
EOF
