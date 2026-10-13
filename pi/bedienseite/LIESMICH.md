# stream2beamer-Bedienseite (Browser)

Läuft auf dem Raspberry Pi. Jedes Gerät im ATEM-Netz (Kabel am Switch oder WLAN „stream2beamer“) öffnet **http://beamer.lan** (Android), **http://beamer.local** (iPhone, Windows, Mac) oder **http://192.168.10.20** und kann:

- **Bild:** Programm und Vorschau umschalten, CUT, AUTO, FTB
- **Stream:** Ziel wählen (Beamer am Pi oder Laptop über SRT), ON AIR starten und stoppen, Laufzeit, Anzeige ob der Pi Bild bekommt
- **Ton:** Fairlight-Pegel je Quelle (Kameras, Mikro 1/2), Ein/Aus/AFV, Master. −10 dB auf der Seite entsprechen −10,0 in Software Control (geprüft).
- **Aufnahme:** Start/Stopp, Laufzeit, Restzeit, Datenträger mit Status, Laufwerk wechseln (bei zwei Platten), Dateiname, ISO an/aus, Qualität (Mittel 6 / Hoch 9 / Sehr hoch 12 Mbit/s). Die Qualität ist die Encoder-Bitrate der Stream-Einstellung. Der ATEM Mini Pro nimmt das Programm mit dieser Bitrate auf (gemessen: Mittel 4,5 Mbit/s, Sehr hoch 8,6 Mbit/s). Die ISO-Spuren haben eine eigene Bitrate von 20–30 Mbit/s. Einstellungen nur bei gestoppter Aufnahme bzw. gestopptem Stream änderbar.
- **Pi herunterfahren** (Reiter Bild, ganz unten, mit Rückfrage): Die Seite legt `/run/stream2beamer-bedienseite/poweroff` an, der Root-Dienst `stream2beamer-poweroff.path` ruft dann `systemctl poweroff` auf. Der Strom kann weg, sobald die grüne LED nicht mehr blinkt (ca. 30 s). Funktioniert auch, wenn der ATEM nicht verbunden ist.
- **Media:** Standbilder im ATEM sehen, in MP1 legen, löschen. **Hochladen erst ab Pi 2/3** (ungetestet). Auf dem Pi 1 trennte der ATEM jeden Upload nach 9 bis 41 s, deshalb ist es dort abgeschaltet. Bilder dann mit Software Control hochladen.

**Automatisch öffnen (Captive Portal):** Nach dem Verbinden mit dem WLAN „stream2beamer“ meldet das Gerät „Im Netzwerk anmelden“ und öffnet die Seite. iPhone und Windows meist von selbst, Android per Mitteilung zum Antippen. dnsmasq leitet nur die Prüfadressen der Betriebssysteme auf den Pi (`/etc/dnsmasq.d/stream2beamer-portal.conf`), der Server leitet fremde Hostnamen per 302 auf http://beamer.lan/ um.

**Handy:** Das Pi-WLAN hat kein Internet, viele Android-Handys schicken dann alles über mobile Daten. Bei „Kein Internet, trotzdem verbunden bleiben?“ **Ja** wählen, sonst „WLAN+“ bzw. „Intelligente Netzwerkumschaltung“ ausschalten oder mobile Daten kurz aus. Die Adresse mit `http://` eintippen und als Lesezeichen oder auf den Startbildschirm legen.

Für Einrichtung, EQ, Dynamics, Grafiken usw. bleibt ATEM Software Control nötig.

## Installation (Pi braucht einmal Internet)

Auf dem PC im Ordner `pi/bedienseite`: `npm install` (zieht `atem-connection`, der native Schrift-Baustein `@julusian/freetype2` wird durch `stubs/freetype2` ersetzt, es entsteht reines JavaScript). Dann den Ordner auf den Pi kopieren und:

```bash
sudo bash install-pi.sh
```

Das Skript installiert Node.js 18 (ARMv6-Build, SHA256-geprüft) nach `/opt/node`, das Programm nach `/opt/stream2beamer-bedienseite` und den Dienst `stream2beamer-bedienseite` (Port 80, Benutzer `pi`). Die Standard-Webseite von nginx wird abgeschaltet, weil sie sonst Port 80 belegt. nginx bleibt für RTMP aktiv.

## Aufnahme überwachen (Windows)

`aufnahme-ueberwachung.ps1` liest während einer langen Probeaufnahme alle 10 s den Zustand über die Bedienseite. Es ändert nichts am ATEM. Ergebnis: CSV-Protokoll und Zusammenfassung in `protokolle/`, darunter auch, ob und wann der Datenträger zu langsam war.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File aufnahme-ueberwachung.ps1 -Ziel http://192.168.10.20
```

## Hinweise

- **Kein Passwort.** Nur Adressen aus `192.168.10.0/24` (und der Pi selbst) dürfen die Seite benutzen, alle anderen bekommen 403. Einstellbar in `/etc/systemd/system/stream2beamer-bedienseite.service` (`ALLOW_NETS`).
- **Node 18** ist seit 04/2025 ohne Sicherheitsupdates. Die ARMv6-Builds ab Node 20 laufen auf Buster nicht (`GLIBCXX_3.4.30` fehlt).
- Zielwechsel nur bei gestopptem Stream (lehnt der ATEM sonst ab).
- Test ohne ATEM: `npm test`. Status: `systemctl status stream2beamer-bedienseite`, Log: `journalctl -u stream2beamer-bedienseite -f`
