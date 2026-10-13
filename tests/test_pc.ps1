<#
  Test der PC-Logik unter Linux (PowerShell 7 + mpv + ffmpeg/ffplay installiert).
  Prueft: Parser, Konfig lesen/schreiben, ATEM-XML, Player-Argumente mit echtem SRT-Stream.
  Aufruf:  pwsh -NoProfile -File tests/test_pc.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$app  = Join-Path $repo 'pc/stream2beamer/app'
$fail = 0
function Ok($t)  { Write-Host "  OK   $t" -ForegroundColor Green }
function Bad($t) { Write-Host "  FEHLER $t" -ForegroundColor Red; $script:fail++ }

Write-Host '1. Parser'
foreach ($f in Get-ChildItem $app -Filter *.ps1) {
    $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
    if ($e) { Bad "$($f.Name): $($e[0])" } else { Ok $f.Name }
}

# Testkopie, damit config.json und ATEM-Dateien im Repo unberuehrt bleiben
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('atem-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'app') | Out-Null
Copy-Item (Join-Path $app 'Common.ps1') (Join-Path $tmpRoot 'app')
Copy-Item (Join-Path $repo 'pc/stream2beamer/config.json') $tmpRoot
. (Join-Path $tmpRoot 'app/Common.ps1')

Write-Host '2. Konfiguration'
$cfg = Get-Config
if ($cfg.Port -eq 9000 -and $cfg.Player -eq 'mpv' -and $cfg.Ton -eq $false) { Ok 'config.json gelesen' } else { Bad 'config.json Werte' }
$cfg.LatenzMs = 200; Save-Config $cfg; $c2 = Get-Config
if ($c2.LatenzMs -eq 200) { Ok 'Speichern und erneut lesen' } else { Bad 'Roundtrip' }
$cfg.LatenzMs = 120

Write-Host '3. ATEM-XML'
$dir = Export-AtemFiles '192.168.10.10' $cfg
$a = [xml](Get-Content (Join-Path $dir 'stream2beamer-SRT.xml') -Raw)
$s = $a.streaming.service
if ($s.servers.server.url -eq 'srt://192.168.10.10:9000') { Ok 'URL' } else { Bad "URL $($s.servers.server.url)" }
if ($s.servers.server.'srt-extensions'.'stream-latency'.item.value -eq '120') { Ok 'ATEM-Latenz' } else { Bad 'ATEM-Latenz' }
if ($s.profiles.profile.SelectSingleNode('low-latency')) { Ok 'low-latency-Tag' } else { Bad 'low-latency-Tag' }
$b = [xml](Get-Content (Join-Path $dir 'stream2beamer-SRT-einfach.xml') -Raw)
if (-not $b.streaming.service.servers.server.'srt-extensions') { Ok 'einfach ohne Erweiterungen' } else { Bad 'einfach' }
try { New-AtemXml 'kaputt' $cfg $true | Out-Null; Bad 'ungueltige IP nicht abgefangen' } catch { Ok 'ungueltige IP abgefangen' }

Write-Host '4. Player mit echtem SRT-Stream (Sender wie ATEM: Caller, Stream-ID im Blackmagic-Format)'
$bounds = [pscustomobject]@{ X = 1920; Y = 0; Width = 1920; Height = 1080 }
$port = 9100
foreach ($pl in @('mpv', 'ffplay')) {
    foreach ($ton in @($false, $true)) {
        $port++; $cfg.Port = $port; $cfg.Ton = $ton
        $pa = Get-PlayerArgs $pl $cfg $bounds
        if ($pl -eq 'mpv') { $pa = @('--vo=null', '--ao=null') + $pa } else { $env:SDL_VIDEODRIVER = 'dummy'; $env:SDL_AUDIODRIVER = 'dummy' }
        $log = Join-Path $tmpRoot "$pl-$ton.log"
        $p = Start-Process -FilePath $pl -ArgumentList $pa -RedirectStandardError $log -RedirectStandardOutput "$log.out" -PassThru
        Start-Sleep 3
        $snd = Start-Process ffmpeg -PassThru -Wait -ArgumentList @('-hide_banner', '-loglevel', 'error', '-re',
            '-f', 'lavfi', '-i', 'testsrc2=size=1920x1080:rate=25', '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '4',
            '-c:v', 'libx264', '-preset', 'veryfast', '-tune', 'zerolatency', '-g', '50', '-pix_fmt', 'yuv420p',
            '-c:a', 'aac', '-b:a', '128k', '-f', 'mpegts',
            "srt://127.0.0.1:$($port)?mode=caller&streamid=%23!::u=beamer,bmd_name=ATEM%20Mini%20Pro")
        $ended = $p.WaitForExit(15000)
        if (-not $ended) { $p.Kill() }
        $err = (Get-Content $log, "$log.out" -ErrorAction SilentlyContinue) -join ' '
        $bad = $err -match 'unknown option|Error parsing|Option .* not found|Invalid'
        if ($snd.ExitCode -eq 0 -and $ended -and -not $bad) { Ok "$pl Ton=${ton}: empfangen, sauber beendet" }
        else { Bad "$pl Ton=$ton (Sender rc=$($snd.ExitCode), beendet=$ended): $err" }
    }
}

Write-Host '5. Windows-Kommandozeile'
$j = Join-WinArgs @('--title=Mein Beamer', 'a"b', 'plain')
if ($j -eq '"--title=Mein Beamer" "a\"b" plain') { Ok $j } else { Bad $j }

Remove-Item $tmpRoot -Recurse -Force
if ($fail) { Write-Host "$fail Fehler" -ForegroundColor Red; exit 1 } else { Write-Host 'Alle Tests bestanden' -ForegroundColor Green }
