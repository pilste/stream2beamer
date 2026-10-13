# Tests

Laufen unter Linux oder WSL. Sie prüfen die Logik, nicht die Windows-Oberfläche und keinen echten Pi.

```bash
sudo apt install ffmpeg mpv nginx libnginx-mod-rtmp shellcheck
pwsh -NoProfile -File tests/test_pc.ps1          # PowerShell 7 nötig
pwsh -NoProfile -File tests/test_netz.ps1        # feste IP gegen simulierten Adapter
pwsh -NoProfile -File tests/test_gui_static.ps1  # statische GUI-Prüfung
pwsh -NoProfile -File tests/test_auswahl.ps1     # ATEM-USB-Adapter, Bildschirmwahl (läuft auch unter Windows)
(cd pi/bedienseite && npm install && npm test)   # Logik der Bedienseite (ohne ATEM)
bash tests/test_pi.sh
```

`test_pc.ps1` arbeitet auf einer Kopie im Temp-Ordner und verändert `config.json` nicht. `test_pi.sh` startet einen eigenen nginx auf Port 1935 und ersetzt omxplayer durch eine ffmpeg-Attrappe, die empfangene Bilder zählt.
