# stream2beamer

Das Programmbild eines **Blackmagic ATEM Mini Pro / Pro ISO** über das Netzwerkkabel auf einen Beamer bringen, ohne Streaming Bridge. Dabei bleiben **USB-C für die Aufnahme** und **HDMI-Out für das Multiview** frei.

> Kein offizielles Projekt von Blackmagic Design. „ATEM“ und „Blackmagic“ sind Marken ihrer Inhaber. Nutzung auf eigene Verantwortung.

Zwei unabhängige Wege, je nach Bedarf:

| Weg | Empfänger | Verzögerung | Ordner |
|---|---|---|---|
| **PC-Modul** | Windows-Laptop am Beamer (SRT, Player mpv/ffplay) | gering, kaum spürbar | [`pc/stream2beamer`](pc/stream2beamer/LIESMICH.md) |
| **Raspberry Pi** | Pi 1/2/3 am Beamer (RTMP, omxplayer) | mehrere Sekunden | [`pi`](pi/LIESMICH.md) |

Der ATEM sendet immer nur an **ein** Ziel. Zwischen Laptop und Pi wird in ATEM Software Control (Plattform) oder auf der Bedienseite umgeschaltet.

## PC-Modul (Windows)

Portables PowerShell-Programm mit Oberfläche: SRT-Empfang mit mpv oder ffplay im Vollbild auf dem gewählten Bildschirm, ATEM-Streamingdateien erzeugen, Firewall-Regel, optional feste IP während der Benutzung (stellt beim Schließen die alte Einstellung wieder her), Testbild, Diagnose-Werkzeug.

mpv wird **nicht mitgeliefert** und muss einmal selbst heruntergeladen werden. Anleitung: [`pc/stream2beamer/LIESMICH.md`](pc/stream2beamer/LIESMICH.md).

## Raspberry Pi

| Teil | Was es tut | Anleitung |
|---|---|---|
| `pi/pi-atem-bridge.sh` | nginx-RTMP-Empfang und omxplayer per HDMI (Raspberry Pi OS **Buster Lite**). Stream Key egal, 720p 16:9 als Standard, feste Ersatzadresse 192.168.10.20 am Switch ohne Router | [`pi/LIESMICH.md`](pi/LIESMICH.md) |
| `pi/pi-hotspot.sh` | optional: WLAN-Hotspot „stream2beamer“ per USB-WLAN-Stick, Adressvergabe im ATEM-Netz, Name `beamer.lan`, Captive Portal (Gerät öffnet die Bedienseite nach dem Verbinden) | [`pi/LIESMICH.md`](pi/LIESMICH.md) |
| `pi/bedienseite/` | Bedienseite im Browser (Handy, Tablet, Laptop): Bild umschalten, Stream, Ton wie ein Mischpult-Kanalzug (Live-Pegel, 6-Band-Equalizer mit Presets, Gain, Kompressor, Limiter, Gate), Aufnahme mit ISO und Live-Verlauf, Standbilder, Pi herunterfahren | [`pi/bedienseite/LIESMICH.md`](pi/bedienseite/LIESMICH.md) |

## Netz (Vorschlag ohne Router)

| Gerät | Adresse |
|---|---|
| ATEM (in ATEM Setup fest einstellen) | 192.168.10.240 |
| Raspberry Pi | 192.168.10.20 |
| Laptop per Kabel | 192.168.10.10 |
| Laptop per WLAN (Hotspot) | 192.168.10.11 |

## Bekannte Grenzen (gemessen)

- **Pi 1:** Standbild-Upload über die Bedienseite nicht möglich (der ATEM trennt die Verbindung), deshalb dort abgeschaltet. Ab Pi 2/3 automatisch an, ungetestet.
- **Aufnahme mit ISO (4 Kameras):** ca. 38–52 GB pro Stunde je nach Bewegung im Bild. Ein getesteter USB-Stick verwarf nach ~19 min Bilder. Eine externe USB-Festplatte (exFAT) lief 1 h ohne Fehler. Für längere ISO-Aufnahmen also Festplatte oder SSD.
- **Hotspot mit RTL8188CUS-Stick am Pi 1:** ca. 15 Mbit/s, Aussetzer bis 0,7 s. Gut für die Bedienung, für Video zum Laptop besser Kabel.
- Die Bedienseite hat **kein Passwort**. Sie ist nur aus 192.168.10.0/24 erreichbar. Nur in einem eigenen Netz betreiben.

## Tests

Siehe [`tests/README.md`](tests/README.md) und `npm test` in `pi/bedienseite`.

## Lizenz

Eigener Code: MIT, siehe [`LICENSE`](LICENSE). Fremde Programme (mpv, FFmpeg, nginx, omxplayer, Node.js, atem-connection) werden nicht mitgeliefert und stehen unter ihren eigenen Lizenzen. Quellen und Belege: [`docs/QUELLEN.md`](docs/QUELLEN.md).
