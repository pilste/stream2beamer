#!/usr/bin/env bash
# WLAN-Hotspot "stream2beamer" auf dem Pi: wlan0 (hostapd) und eth0 in Bruecke br0.
# br0 holt per DHCP eine Adresse (Heimnetz) oder faellt auf 192.168.10.20 zurueck (Switch ohne Router).
# dnsmasq verteilt nur Adressen, wenn br0 im Netz 192.168.10.0/24 ist (dhcp-range passt sonst zu keiner Schnittstelle).
# Sicherheitsnetz: ohne /etc/stream2beamer-ap-ok wird 30 Minuten nach dem Start alles zurueckgesetzt (10 min waren im Test zu knapp).
# Aufruf: sudo LAPTOP_CABLE_MAC=aa:bb:.. LAPTOP_WLAN_MACS=cc:dd:..,ee:ff:.. bash pi-hotspot.sh
#         (USB-LAN-Adapter des Laptops; WLAN-MACs inkl. der zufaelligen MAC, die Windows pro Netz verwendet)
#         optional WLAN_COUNTRY=DE (Default), Kanal 13 ist in Europa erlaubt
# Danach das WLAN-Passwort als Zeile "00:00:00:00:00:00 PASSWORT" nach /etc/hostapd/stream2beamer-psk schreiben (nur LF) und hostapd neu starten.
# Getestet 13.10.2026 auf Pi 1 B+ mit RTL8188CUS: 15,6 Mbit/s durch die Bruecke, Ping-Spitzen bis ~700 ms unter Last.
set -euo pipefail
LAPTOP_CABLE_MAC="${LAPTOP_CABLE_MAC:-}"
LAPTOP_WLAN_MACS="${LAPTOP_WLAN_MACS:-}"
WLAN_COUNTRY="${WLAN_COUNTRY:-DE}"   # Laendercode fuer erlaubte WLAN-Kanaele
ETH_MAC=$(cat /sys/class/net/eth0/address)
B=/root/stream2beamer-ap-backup
mkdir -p "$B"
DEBIAN_FRONTEND=noninteractive apt-get install -y hostapd dnsmasq bridge-utils iw
systemctl stop hostapd dnsmasq 2>/dev/null || true
for f in /etc/dhcpcd.conf /etc/default/hostapd /etc/dnsmasq.conf; do [ -f "$B/$(basename "$f")" ] || cp -p "$f" "$B/"; done

# Bruecke br0 mit der MAC von eth0 (gleiche DHCP-Adresse am Router wie bisher)
cat >/etc/systemd/network/stream2beamer-br0.netdev <<EOF
[NetDev]
Name=br0
Kind=bridge
MACAddress=${ETH_MAC}
EOF
cat >/etc/systemd/network/stream2beamer-br0-eth0.network <<EOF
[Match]
Name=eth0

[Network]
Bridge=br0
EOF
systemctl enable systemd-networkd >/dev/null 2>&1

# dhcpcd: eth0 und wlan0 nicht mehr selbst, sondern br0 (mit Fallback 192.168.10.20)
python3 - <<'PY'
import re
p = '/etc/dhcpcd.conf'
s = open(p).read()
# alte Fallback-Bloecke (markiert oder aus der Ersteinrichtung) entfernen
s = re.sub(r'\n# >>> pi-atem-bridge >>>.*?# <<< pi-atem-bridge <<<\n?', '\n', s, flags=re.S)
s = re.sub(r'\n# stream2beamer: ohne DHCP-Server.*?fallback beamer_static\n?', '\n', s, flags=re.S)
s = s.rstrip() + '''

# >>> pi-atem-bridge >>>
denyinterfaces eth0 wlan0
profile beamer_static
static ip_address=192.168.10.20/24
interface br0
fallback beamer_static
# <<< pi-atem-bridge <<<
'''
open(p + '.tmp', 'w').write(s)
PY
mv /etc/dhcpcd.conf.tmp /etc/dhcpcd.conf

# hostapd (Passwort traegt der Nutzer selbst in /etc/hostapd/stream2beamer-psk ein, siehe unten)
cat >/etc/hostapd/hostapd.conf <<EOF
interface=wlan0
bridge=br0
driver=nl80211
ssid=stream2beamer
country_code=${WLAN_COUNTRY}
hw_mode=g
channel=13
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_psk_file=/etc/hostapd/stream2beamer-psk
EOF
[ -f /etc/hostapd/stream2beamer-psk ] || install -m 600 /dev/null /etc/hostapd/stream2beamer-psk
sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
systemctl unmask hostapd >/dev/null 2>&1; systemctl enable hostapd >/dev/null 2>&1

# dnsmasq: DHCP nur im ATEM-Netz. Laptop-Kabel bekommt .10 (Videobild), Laptop-WLAN .11 (Bedienung).
# Grund fuer die Trennung: beide gleichzeitig mit .10 ergaben einen Adresskonflikt am Laptop (13.10.2026).
# DNS nur fuer den eigenen Namen beamer.lan (Android loest beamer.local im Browser nicht auf), nichts ins Internet weiterleiten.
cat >/etc/dnsmasq.d/stream2beamer.conf <<EOF
interface=br0
bind-dynamic
dhcp-range=192.168.10.100,192.168.10.150,255.255.255.0,12h
${LAPTOP_CABLE_MAC:+dhcp-host=${LAPTOP_CABLE_MAC},192.168.10.10}
${LAPTOP_WLAN_MACS:+dhcp-host=${LAPTOP_WLAN_MACS},192.168.10.11}
# kein Gateway: der Laptop behaelt sein Internet ueber andere Wege
dhcp-option=3
no-resolv
local=/lan/
address=/beamer.lan/192.168.10.20
address=/beamer/192.168.10.20
dhcp-option=6,192.168.10.20
EOF
# Captive Portal: nur die Internet-Pruefadressen der Betriebssysteme auf den Pi, die Bedienseite leitet sie auf
# http://beamer.lan/ um -> Handy meldet "Im Netzwerk anmelden" und oeffnet die Seite. Kein Wildcard, damit der Laptop
# am Kabel (bekommt ebenfalls den Pi als DNS) sein Internet ueber andere Wege behaelt. Getestet 13.10.2026.
cat >/etc/dnsmasq.d/stream2beamer-portal.conf <<'EOF'
address=/connectivitycheck.gstatic.com/192.168.10.20
address=/connectivitycheck.android.com/192.168.10.20
address=/clients3.google.com/192.168.10.20
address=/clients1.google.com/192.168.10.20
address=/connectivitycheck.platform.hicloud.com/192.168.10.20
address=/connectivitycheck.platform.hihonorcloud.com/192.168.10.20
address=/captive.apple.com/192.168.10.20
address=/www.msftconnecttest.com/192.168.10.20
address=/msftconnecttest.com/192.168.10.20
address=/www.msftncsi.com/192.168.10.20
address=/detectportal.firefox.com/192.168.10.20
address=/nmcheck.gnome.org/192.168.10.20
address=/connectivity-check.ubuntu.com/192.168.10.20
EOF
systemctl enable dnsmasq >/dev/null 2>&1
# dnsmasq soll sich nicht als Namensserver des Pi selbst eintragen (sonst hat der Pi kein Internet-DNS)
grep -q '^DNSMASQ_EXCEPT=' /etc/default/dnsmasq || echo 'DNSMASQ_EXCEPT="lo"' >>/etc/default/dnsmasq

# Hostname beamer -> http://beamer.local (mDNS nur IPv4, die Bedienseite lauscht nur auf IPv4)
echo beamer >/etc/hostname
sed -i "s/127.0.1.1.*/127.0.1.1\tbeamer/" /etc/hosts
hostname beamer
sed -i 's/^#\?use-ipv6=.*/use-ipv6=no/' /etc/avahi/avahi-daemon.conf

# Kabelwaechter: br0 bleibt durch den Hotspot immer "verbunden", dhcpcd merkt den Wechsel Router -> Switch sonst nicht
# und behaelt die alte Heimnetz-Adresse (gefunden 13.10.2026). Nach jedem Einstecken von eth0 neu anfragen.
cat >/usr/local/bin/stream2beamer-kabelwaechter.sh <<'EOF'
#!/usr/bin/env bash
# erzeugt fuer den ATEM-Hotspot: nach jedem Einstecken des Netzwerkkabels Adresse von br0 neu beziehen
alt=$(cat /sys/class/net/eth0/carrier 2>/dev/null || echo 0)
while sleep 2; do
  neu=$(cat /sys/class/net/eth0/carrier 2>/dev/null || echo 0)
  if [ "$neu" = "1" ] && [ "$alt" != "1" ]; then
    echo "Kabel eingesteckt: br0 neu anfragen"
    dhcpcd -k br0 >/dev/null 2>&1 || true
    sleep 1
    dhcpcd -n br0 >/dev/null 2>&1 || true
  fi
  alt=$neu
done
EOF
chmod 755 /usr/local/bin/stream2beamer-kabelwaechter.sh
cat >/etc/systemd/system/stream2beamer-kabelwaechter.service <<'EOF'
[Unit]
Description=ATEM-Hotspot: Adresse nach Kabelwechsel neu beziehen
After=dhcpcd.service

[Service]
ExecStart=/usr/local/bin/stream2beamer-kabelwaechter.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable stream2beamer-kabelwaechter >/dev/null 2>&1

# Sicherheitsnetz
cat >/root/stream2beamer-ap-revert.sh <<EOF
#!/bin/sh
cp -p $B/dhcpcd.conf /etc/dhcpcd.conf
cp -p $B/hostapd /etc/default/hostapd
rm -f /etc/systemd/network/stream2beamer-br0.netdev /etc/systemd/network/stream2beamer-br0-eth0.network /etc/dnsmasq.d/stream2beamer.conf
systemctl disable hostapd dnsmasq systemd-networkd stream2beamer-kabelwaechter
rm -f /etc/cron.d/stream2beamer-ap-revert
/sbin/reboot
EOF
chmod 700 /root/stream2beamer-ap-revert.sh
rm -f /etc/stream2beamer-ap-ok
echo '@reboot root sleep 1800; [ -f /etc/stream2beamer-ap-ok ] || /root/stream2beamer-ap-revert.sh' >/etc/cron.d/stream2beamer-ap-revert
echo "EINGERICHTET (eth0 MAC $ETH_MAC). Nach dem Neustart pruefen, dann: sudo touch /etc/stream2beamer-ap-ok"
