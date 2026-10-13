#!/usr/bin/env bash
# Test der Pi-Bridge unter Linux (Ubuntu/Debian mit nginx, libnginx-mod-rtmp, ffmpeg, shellcheck).
# Prüft: Syntax, Shellcheck, Modell-Erkennung, Paketquellen-Umstellung,
#        echte nginx-RTMP-Konfig + Player-Schleife (omxplayer durch ffmpeg-Attrappe ersetzt).
# Aufruf:  bash tests/test_pi.sh
set -u
S="$(cd "$(dirname "$0")/.." && pwd)/pi/pi-atem-bridge.sh"
T="$(mktemp -d)"; FAIL=0
ok()  { printf '  OK     %s\n' "$*"; }
bad() { printf '  FEHLER %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "1. Syntax"
bash -n "$S" && ok "bash -n" || bad "bash -n"
if command -v shellcheck >/dev/null; then shellcheck "$S" && ok "shellcheck" || bad "shellcheck"; else echo "  (shellcheck fehlt, übersprungen)"; fi

echo "2. Modell-Erkennung (gleiche Muster wie im Skript)"
check() { local r=ok; case "$1" in *"Pi 4"*|*"Pi 5"*) r=abbruch;; "Raspberry Pi Model"*|*"Zero"*) r=warnung;; esac; [ "$r" = "$2" ] && ok "$1 -> $r" || bad "$1 -> $r (erwartet $2)"; }
grep -qF '"Raspberry Pi Model"*|*"Zero"*)' "$S" || bad "Muster im Skript geändert, Test anpassen"
check "Raspberry Pi Model B Plus Rev 1.2" warnung
check "Raspberry Pi 2 Model B Rev 1.1" ok
check "Raspberry Pi 3 Model B Rev 1.2" ok
check "Raspberry Pi 4 Model B Rev 1.4" abbruch
check "Raspberry Pi 400 Rev 1.0" abbruch
check "Raspberry Pi Zero W Rev 1.1" warnung

echo "3. Paketquellen-Umstellung"
SEDX='s#https?://(raspbian\.raspberrypi\.org|mirrordirector\.raspbian\.org|archive\.raspbian\.org)/#http://legacy.raspbian.org/#g'
grep -qF "$SEDX" "$S" || bad "sed-Ausdruck im Skript geändert, Test anpassen"
r=$(echo 'deb http://raspbian.raspberrypi.org/raspbian/ buster main contrib non-free rpi' | sed -E "$SEDX")
[ "$r" = 'deb http://legacy.raspbian.org/raspbian/ buster main contrib non-free rpi' ] && ok "Raspbian-Zeile umgestellt" || bad "$r"
r=$(echo 'deb http://archive.raspberrypi.org/debian/ buster main' | sed -E "$SEDX")
[ "$r" = 'deb http://archive.raspberrypi.org/debian/ buster main' ] && ok "raspberrypi.org-Zeile unverändert" || bad "$r"

echo "4. nginx + Player-Schleife"
if ! [ -f /usr/lib/nginx/modules/ngx_rtmp_module.so ]; then echo "  (nginx-RTMP fehlt: apt install nginx libnginx-mod-rtmp) übersprungen"; else
  ext() { awk -v start="$1" '$0 ~ start {f=1; next} f && /^EOF$/ {exit} f' "$S"; }
  PUBLISH_NET="127.0.0.0/8"; STREAM_KEY="beamer"; OMX_AUDIO="hdmi"
  eval "cat <<EOF
$(ext 'atomic_write "\$RTMP_CONF" <<EOF')
EOF" > "$T/rtmp.conf"
  eval "cat <<EOF
$(ext 'atomic_write "\$PLAYER_SH" 755 <<EOF')
EOF" > "$T/player.sh"; chmod +x "$T/player.sh"
  printf 'load_module /usr/lib/nginx/modules/ngx_rtmp_module.so;\npid %s/nginx.pid; error_log %s/error.log; worker_processes 1;\nevents {}\ninclude %s/rtmp.conf;\n' "$T" "$T" "$T" > "$T/nginx.conf"
  nginx -t -c "$T/nginx.conf" >/dev/null 2>&1 && ok "nginx -t mit erzeugter Konfig" || bad "nginx -t"
  nginx -c "$T/nginx.conf"
  mkdir -p "$T/bin"
  cat > "$T/bin/omxplayer" <<EOM
#!/usr/bin/env bash
URL="\${@: -1}"
ffmpeg -nostats -loglevel error -i "\$URL" -an -f null - -progress "$T/prog.txt" 2>>"$T/omx.err"
echo "ENDE frames=\$(grep -o 'frame=[0-9]*' "$T/prog.txt" 2>/dev/null | tail -1)" >> "$T/omx.log"
EOM
  chmod +x "$T/bin/omxplayer"
  PATH="$T/bin:$PATH" timeout 26 "$T/player.sh" & PL=$!
  sleep 6
  n=$(grep -c ENDE "$T/omx.log" 2>/dev/null || echo 0)
  [ "$n" -ge 2 ] && ok "ohne Sender: Player versucht es wiederholt ($n Versuche)" || bad "ohne Sender: $n Versuche"
  timeout 9 ffmpeg -hide_banner -loglevel error -re -f lavfi -i testsrc2=size=1920x1080:rate=25 -f lavfi -i sine -t 6 \
    -c:v libx264 -preset veryfast -tune zerolatency -g 25 -pix_fmt yuv420p -c:a aac -f flv rtmp://127.0.0.1/live/beamer \
    && ok "Sender (wie ATEM, RTMP) fertig" || bad "Sender"
  sleep 5
  best=$(grep -o 'frames=frame=[0-9]*' "$T/omx.log" | grep -o '[0-9]*$' | sort -n | tail -1)
  [ "${best:-0}" -ge 100 ] && ok "Stream empfangen: $best von 150 Bildern (Einstieg bis 2 s nach Streamstart erlaubt)" || bad "nur ${best:-0} Bilder"
  sleep 4
  after=$(tail -1 "$T/omx.log")
  case "$after" in *"frames="|*"frames=frame=0") ok "nach Streamende wieder im Wartemodus";; *) bad "nach Ende: $after";; esac
  nginx -c "$T/nginx.conf" -s stop 2>/dev/null; kill $PL 2>/dev/null; wait $PL 2>/dev/null
fi
rm -rf "$T"
[ $FAIL -eq 0 ] && echo "Alle Tests bestanden" || { echo "$FAIL Fehler"; exit 1; }
