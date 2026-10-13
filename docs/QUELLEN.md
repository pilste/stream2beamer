# Quellen

Stand der Recherche: Oktober 2026. Jede Zeile: was die Quelle belegt.

## Ausgangspunkt

| Quelle | Belegt |
|---|---|
| [YouTube-Video (Startlink)](https://www.youtube.com/watch?v=MtETl23cnOA) | Idee: Pi als DIY-Streaming-Bridge |
| [Aaron Parecki: RTMP-Server und Player mit Raspberry Pi](https://aaronparecki.com/2020/09/07/7/raspberry-pi-streaming-server) | nginx-RTMP + omxplayer, Pi wird zur Bridge. omxplayer fehlt in neuen OS-Versionen. Pi 3 funktioniert, aber mit mehr Verzögerung als Pi 4 |
| [yencarnacion/raspberry-pi-rtmp](https://github.com/yencarnacion/raspberry-pi-rtmp) | Nachbau der Parecki-Konfiguration |
| [proalvo/raspberry-pi-streaming-bridge](https://github.com/proalvo/raspberry-pi-streaming-bridge) | Variante mit Weiterleitung an YouTube/Facebook und Aufzeichnung |
| [MediaMTX](https://github.com/bluenviron/mediamtx) | Server für SRT/RTMP u. a., wandelt zwischen Protokollen |

## ATEM: Anschlüsse und Grenzen

| Quelle | Belegt |
|---|---|
| [Blackmagic-Forum: USB Host vs. Endgerät](https://forum.blackmagicdesign.com/viewtopic.php?f=4&t=110566) | Mit Platten ist der ATEM USB-Host, als Webcam Endgerät, nicht beides gleichzeitig. Beim Aufnehmen kein Durchschleifen des Livebilds |
| [Blackmagic-Forum: ISO + Webcam gleichzeitig](https://forum.blackmagicdesign.com/viewtopic.php?f=4&t=119626) | Pro ISO: USB entweder Platte oder Computer |
| [Blackmagic ATEM Mini Produktseite](https://www.blackmagicdesign.com/products/atemmini) | Hub/MultiDock nur für mehrere Platten (Weiterschreiben bei voller Platte) |
| [Blackmagic-Forum: Multiview über Ethernet](https://forum.blackmagicdesign.com/viewtopic.php?f=4&t=190752) | Streaming Bridge nur Programm. Workaround: HDMI-Out → Capture-Karte → NDI |
| [Manchester Video: Impossible features](https://www.manchestervideo.com/2020/06/24/impossible-features-of-the-blackmagic-design-atem-mini-and-mini-pro/) | Multiview über USB-C ab ATEM 9.5 für Pro ISO und Extreme ISO |
| [Galfe Medienproduktion: Multiview im Eigenbau](https://www.galfe.de/atem-mini-multiview-vorschau-im-eigenbau/) | DIY-Multiview mit HDMI-Splittern + Quad-Multiviewer |
| [eBay: Quad-Multiviewer](https://www.ebay.de/itm/116875122691) | Preisrahmen ab ca. 16 € |

## SRT am ATEM

| Quelle | Belegt |
|---|---|
| [Blackmagic auf X: ATEM 9.5](https://x.com/Blackmagic_News/status/1798898360545690016) | SRT-Streaming für ATEM Mini Pro, Extreme u. a. ab 9.5 |
| [Subsplash: ATEM mit SRT](https://support.subsplash.com/en/articles/9021616-setting-up-a-blackmagic-atem-mini-pro-extreme-with-subsplash-live) | Software und Firmware mindestens 9.6 |
| [Streamwell: Blackmagic-Geräte](https://docs.streamwell.net/using-streamwell/streaming/hardware-encoders/blackmagic-devices) | Plattform „Custom URL H.264", Server als `srt://` |
| [OvenMediaEngine Discussion #1641](https://github.com/OvenMediaLabs/OvenMediaEngine/discussions/1641) | Stream-ID-Format des ATEM (Key, UUID, Gerätename) |
| [Blackmagic-Forum: ATEM SRT zu Restreamer](https://forum.blackmagicdesign.com/viewtopic.php?f=4&t=220449) | XML-Struktur mit `srt-extensions` / `stream-latency` |
| [Blackmagic-Forum: Web Presenter SRT-Konfiguration](https://forum.blackmagicdesign.com/viewtopic.php?f=4&t=188339) | Jeder SRT-Parameter in eigenem Unterabschnitt, Latenz in ms. `<low-latency/>`-Tag existiert, Bedeutung undokumentiert |
| [Blackmagic-Forum: Web Presenter XML / SRT mit Castr](https://forum.blackmagicdesign.com/viewtopic.php?f=4&t=215052) | Nutzer sah keinen Effekt verschiedener Latenzwerte |
| [Epiphan: SRT-Latenz](https://www.epiphan.com/userguides/pearl-mini/Content/stream/StreamSRTlatency.htm) | SRT nimmt den höheren Latenzwert beider Seiten |

## Verzögerungen

| Quelle | Belegt |
|---|---|
| [OBS-Forum: ATEM Mini SRT mit 300 ms](https://obsproject.com/forum/threads/using-a-mini-atem-to-send-low-latency-300ms-srt-stream-to-obs.190554/) | ca. 300 ms, ohne Ton unter 100 ms (ein Nutzer, Linux) |
| [SRS-Dokumentation SRT](https://ossrs.net/lts/en-us/docs/v5/doc/srt) | ffplay ca. 200 ms als schnellster Player; RTMP 1 bis 3 s, SRT 300 bis 500 ms |
| [vMix-Forum: VLC-Latenz](https://forums.vmix.com/posts/t20603-VLC-Latency---2-seconds) | VLC puffert standardmäßig 1000 ms |
| [Haivision SRT Issue #1729](https://github.com/Haivision/srt/issues/1729) | Gegenbeleg: ffplay ca. 1,5 s im LAN (HEVC, ohne Low-Delay-Schalter) |
| [Blackmagic-Forum: Streaming Bridge Verzögerung](https://forum.m.blackmagicdesign.com/viewtopic.php?uid=16&f=4&t=125997&start=0) | Bridge im LAN ca. 1 s oder weniger |
| [Blackmagic-Forum: Bridge und andere Dienste](https://forum.blackmagicdesign.com/viewtopic.php?f=4&t=146121) | Bridge stürzt mit FFmpeg-RTMP-Streams ab (Header-Format) |
| [eBay: Streaming Bridge](https://www.ebay.de/p/10042445191) | Preis ca. 280 € |

## Raspberry Pi

| Quelle | Belegt |
|---|---|
| [Raspberry-Pi-Forum: Buster nach legacy](https://forums.raspberrypi.com/viewtopic.php?t=394811) | Buster liegt seit Ende 2025 auf `legacy.raspbian.org` |
| [RetroPie Issue #4135](https://github.com/RetroPie/RetroPie-Setup/issues/4135) | Fehlerbild 404 und genaue Ersatzzeile |
| [Debian-Manpage srt-live-transmit (Bullseye)](https://manpages.debian.org/bullseye/srt-tools/srt-live-transmit.1.en.html) | srt-tools ab Bullseye, nicht in Buster |
| [GStreamer mit SRT auf dem Pi bauen](https://github.com/tholmgren/Building-Gstreamer-Raspberry-Pi-With-SRT-Support) | SRT unter Buster nur mit langem Selbstbau |

## Software im Paket

| Quelle | Verwendung |
|---|---|
| [mpv-winbuild-cmake, Release 20260928](https://github.com/shinchiro/mpv-winbuild-cmake/releases/tag/20260928) | beiliegender mpv, libsrt enthalten (geprüft) |
| [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds) | ffplay/ffmpeg zum Nachladen |
