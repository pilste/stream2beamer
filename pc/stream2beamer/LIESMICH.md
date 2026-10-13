# stream2beamer für Windows (portabel)

Läuft ohne Installation. Windows 10/11, Netzwerkkabel zum selben Router wie der ATEM (oder direkt mit festen IPs).

## Erster Start

0. **mpv besorgen.** Es liegt aus Lizenz- und Größengründen nicht bei. Nötig ist ein Windows-Build **mit libsrt**, z. B. von https://github.com/shinchiro/mpv-winbuild-cmake/releases (Datei `mpv-x86_64-….7z`). Entpacken und `mpv.exe` und `mpv.com` in den Ordner `mpv` legen. Details stehen in `mpv/LIESMICH.txt`.
1. Ordner an einen festen Ort kopieren, z. B. `C:\stream2beamer`.
2. `stream2beamer.bat` doppelklicken.
3. **Nur bei Switch ohne Router:** Haken bei **Feste IP während Benutzung** setzen. Windows fragt einmal nach Adminrechten, das Programm startet neu und stellt den Kabel-Adapter auf 192.168.10.10. Beim Schließen kommt die vorherige Einstellung automatisch zurück.
4. **Firewall freigeben**: einmalig, Windows fragt nach Adminrechten. Freigabe gilt nur für Geräte im lokalen Netz.
5. **ATEM-Dateien erzeugen**: öffnet den Ordner mit zwei XML-Dateien und einer Anleitung.
6. ATEM Setup: Firmware mindestens 9.6. In ATEM Software Control `stream2beamer-SRT.xml` laden und Plattform „stream2beamer SRT" wählen.

## Testen ohne ATEM

1. **FFmpeg nachladen** (ca. 150 MB, nur für Testbild und ffplay nötig).
2. **Start** drücken, dann **Testbild senden**. Auf dem Beamer erscheint 60 s ein bewegtes Testbild.

## Einsatz

**Start** drücken, am ATEM On Air. Bricht der Stream ab, wartet das Programm automatisch weiter. **Stop** beendet die Anzeige.

## Einstellungen

| Feld | Bedeutung |
|---|---|
| Laptop-IP | Adresse, die im ATEM als Server steht. Kabel-Adapter wird bevorzugt |
| Player | mpv (selbst besorgen, siehe oben) oder ffplay (nach „FFmpeg nachladen"). Ist einer träge, den anderen testen |
| Beamer-Bildschirm | Automatisch = erster Bildschirm, der nicht der Hauptbildschirm ist |
| Puffer Laptop | SRT-Puffer. Ruckelt das Bild: 200 oder 300 |
| Latenz ATEM | landet in der XML-Datei. Nach Änderung Dateien neu erzeugen und im ATEM neu laden |
| Ton | aus spart Verzögerung |
| Feste IP während Benutzung | setzt am Kabel-Adapter die angegebene Adresse (Gateway leer) und stellt beim Schließen die alte Einstellung wieder her. Braucht Adminrechte. Der ATEM muss dann im selben Bereich liegen, z. B. 192.168.10.240 |

### Sicherheit der festen IP

- Die alte Einstellung wird in `netz-sicherung.json` gespeichert, bevor etwas geändert wird.
- Ist die Adresse im Netz schon vergeben, setzt das Programm sofort zurück und meldet es.
- Stürzt der Laptop ab oder wird hart ausgeschaltet, stellt das Programm beim nächsten Start die alte Einstellung wieder her.
- Nur der Kabel-Adapter wird geändert, WLAN bleibt unberührt. DNS-Einstellungen werden nicht verändert.
- Notfall von Hand: Einstellungen → Netzwerk und Internet → Ethernet → IP-Zuweisung → Automatisch (DHCP).

## Verzögerung messen

Handy-Stoppuhr in eine Kamera halten, Multiview und Beamer zusammen fotografieren, Differenz ablesen. Reihenfolge der Versuche: XML A mit mpv, A mit ffplay, XML B, ATEM auf 1080p50.

## Probleme

- **Nichts kommt an:** Steht im ATEM dieselbe IP wie oben im Fenster? Firewall freigegeben? Virenscanner mit eigener Firewall: dort UDP-Port 9000 freigeben.
- **IP beginnt mit 169.254:** Kein Router im Netz. Haken bei „Feste IP während Benutzung" setzen und den ATEM in ATEM Setup auf 192.168.10.240 stellen.
- **Feste IP lässt sich nicht setzen, „schon vergeben":** Anderes Gerät hat 192.168.10.10. Andere Adresse eintragen, z. B. 192.168.10.11.
- **Ruckeln:** Puffer erhöhen, Laptop ans Netzteil, Energiesparplan Höchstleistung, kein WLAN.
- **Ohne Fenster betreiben:** `stream2beamer-Konsole.bat` nutzt die zuletzt gespeicherten Einstellungen.

mpv (GPL) und FFmpeg (LGPL/GPL) werden nicht mitgeliefert. mpv besorgt man selbst (siehe oben), FFmpeg lädt das Programm bei Bedarf von github.com/BtbN/FFmpeg-Builds.
