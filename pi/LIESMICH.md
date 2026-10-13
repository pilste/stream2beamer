# ATEM-Bridge für Raspberry Pi 1, 2, 3

Der Pi empfängt den RTMP-Stream des ATEM und zeigt das Programmbild am HDMI-Ausgang. Verzögerung: mehrere Sekunden (Pi 1 am langsamsten). Gut für Nebenraum, Foyer, Folien. Für Redner live im selben Raum zu langsam.

## Voraussetzungen

- Raspberry Pi 1 B+, 2 oder 3 (nicht Pi 4/5), Netzteil 5 V / 2 A, SD-Karte ≥ 8 GB
- **Raspberry Pi OS (Legacy) Buster Lite, 32 Bit** aus dem Archiv von raspberrypi.com. Im Raspberry Pi Imager SSH und Benutzer `pi` einrichten.
- ATEM auf **1080p25 oder 1080p30** stellen (Pi-Decoder schafft 50p/60p nicht flüssig)

## Installation

```bash
scp pi-atem-bridge.sh pi@IP-DES-PI:
ssh pi@IP-DES-PI
sudo BLACK_SCREEN=1 bash pi-atem-bridge.sh
sudo reboot
```

Standard ist Plug and Play am Switch ohne Router: Der Pi nimmt dort automatisch `192.168.10.20` (am Router weiter DHCP), Streams werden nur aus `192.168.10.0/24` angenommen, HDMI läuft fest auf 720p 16:9 (`HDMI_MODE=4`), weil Beamer ihre Daten oft nicht melden und der Pi sonst auf 640x480 4:3 zurückfällt.

Anpassen: `PI_IP=…`, `PUBLISH_NET=…`, `HDMI_MODE=16` (1080p60) oder `auto`, `STATIC_FALLBACK=0` (nur DHCP).

Weitere Optionen: `STREAM_KEY=beamer`, `AUDIO=none` (HDMI stumm), `BLACK_SCREEN=1` (kein Login-Text am Beamer), `FIX_APT=0` (Paketquellen nicht anfassen).

## ATEM

`/home/pi/atem-raspberry-pi.xml` auf den PC kopieren, in ATEM Software Control laden, Plattform „Raspberry Pi Beamer“. Der Stream Key ist egal, auch leer geht. On Air.

## Betrieb

- Status: `systemctl status stream2beamer-player`
- Live-Log: `journalctl -u stream2beamer-player -f`
- Neustart des Players: `sudo systemctl restart stream2beamer-player`

## Rückweg

Originale liegen als `*.orig-bridge` neben `config.txt`, `cmdline.txt`, `nginx.conf` und den Paketquellen.

## Optional: WLAN-Hotspot „stream2beamer“

Mit einem USB-WLAN-Stick spannt der Pi ein WLAN auf, das mit dem Switch-Netz verbunden ist. Der Laptop kommt dann per WLAN statt per Kabel ins Netz. Am Switch verteilt der Pi Adressen. Per MAC-Reservierung bekommt das Laptop-Kabel 192.168.10.10 (Videobild) und das Laptop-WLAN 192.168.10.11 (Bedienung). Der Pi heißt `beamer`: Bedienseite unter http://beamer.lan oder http://beamer.local. Am Heimrouter reicht der Pi nur durch und verteilt keine Adressen.

```bash
sudo LAPTOP_CABLE_MAC=aa:bb:cc:dd:ee:ff LAPTOP_WLAN_MACS=11:22:33:44:55:66 bash pi-hotspot.sh
sudo reboot
# Passwort (8-63 Zeichen, ohne Umlaute) als eine Zeile mit LF nach /etc/hostapd/stream2beamer-psk:
#   00:00:00:00:00:00 PASSWORT
sudo systemctl restart hostapd
sudo touch /etc/stream2beamer-ap-ok   # sonst setzt sich der Pi 30 min nach dem Start zurück
```

Gemessen mit Pi 1 B+ und RTL8188CUS: ca. 15 Mbit/s, kurze Aussetzer bis 0,7 s. Gut für ATEM Software Control, für Video zum Laptop nur mit größerem Puffer.
