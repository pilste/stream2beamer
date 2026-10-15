<#
  Ueberwacht eine ATEM-Aufnahme ueber die Bedienseite auf dem Pi (nur lesen) und protokolliert sie.
  Wartet bis zu -WarteMin Minuten auf den Start, protokolliert alle -IntervallSek Sekunden und endet,
  wenn die Aufnahme stoppt (oder nach -MaxMin Minuten). Ergebnis: CSV-Protokoll + Zusammenfassung.
  Aufruf: powershell -NoProfile -ExecutionPolicy Bypass -File aufnahme-ueberwachung.ps1 [-Ziel http://192.168.10.20]
#>
param([string]$Ziel = 'http://192.168.10.20', [int]$WarteMin = 30, [int]$MaxMin = 180, [int]$IntervallSek = 10,
      [string]$Ordner = (Join-Path $PSScriptRoot 'protokolle'))
New-Item -ItemType Directory -Force $Ordner | Out-Null
$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$csv = Join-Path $Ordner "aufnahme_$stamp.csv"
$sum = Join-Path $Ordner "aufnahme_${stamp}_zusammenfassung.txt"
'Zeit;Aufnahme;Dauer;Restzeit_s;Fehler;Datentraeger;Stream;Erreichbar' | Set-Content $csv -Encoding UTF8

$t0 = Get-Date; $gestartet = $null; $fehler = @{}; $ausfaelle = 0; $minRest = $null; $letzte = $null; $grund = ''
while ($true) {
    $jetzt = Get-Date
    try { $s = Invoke-RestMethod "$Ziel/api/state" -TimeoutSec 8; $ok = $true } catch { $s = $null; $ok = $false; $ausfaelle++ }
    $r = if ($s) { $s.rec } else { $null }
    $disk = if ($r -and $r.disks) { ($r.disks | ForEach-Object { "$($_.name):$($_.status)" }) -join ',' } else { '' }
    "{0};{1};{2};{3};{4};{5};{6};{7}" -f $jetzt.ToString('HH:mm:ss'), $(if ($r) { $r.state } else { '' }), $(if ($r) { $r.duration } else { '' }),
        $(if ($r) { $r.timeLeft } else { '' }), $(if ($r) { $r.error } else { '' }), $disk, $(if ($s -and $s.stream) { $s.stream.state } else { '' }), $ok |
        Add-Content $csv -Encoding UTF8
    if ($r) {
        if ($r.on -and -not $gestartet) { $gestartet = $jetzt }
        if ($gestartet -and $r.error) { $fehler[$r.error] = 1 + [int]$fehler[$r.error] }
        if ($gestartet -and $r.timeLeft -ne $null -and ($minRest -eq $null -or $r.timeLeft -lt $minRest)) { $minRest = $r.timeLeft }
        if ($r.on) { $letzte = $r }
        if ($gestartet -and -not $r.on) { $grund = 'Aufnahme gestoppt'; break }
    }
    if (-not $gestartet -and ($jetzt - $t0).TotalMinutes -gt $WarteMin) { $grund = "kein Start innerhalb $WarteMin min"; break }
    if (($jetzt - $t0).TotalMinutes -gt $MaxMin) { $grund = "Hoechstdauer $MaxMin min erreicht"; break }
    Start-Sleep $IntervallSek
}

$z = @(
    "ATEM-Aufnahme-Ueberwachung $stamp"
    "Ende: $grund"
    "Start erkannt: $(if ($gestartet) { $gestartet.ToString('HH:mm:ss') } else { 'nein' })"
    "Letzte gemeldete Dauer: $(if ($letzte) { $letzte.duration } else { '-' })"
    # in Stunden und Minuten; vorher "{0:N0} min" ergab mit deutschem Tausenderpunkt "9,714 min" statt 9714 min
    "Kleinste Restzeit: $(if ($minRest -ne $null) { '{0} h {1:D2} min' -f [math]::Floor($minRest / 3600), [int][math]::Floor(($minRest % 3600) / 60) } else { '-' })"
    "Fehler waehrend der Aufnahme: $(if ($fehler.Count) { ($fehler.GetEnumerator() | ForEach-Object { "$($_.Key) ($($_.Value)x)" }) -join ', ' } else { 'keine' })"
    "Pi nicht erreichbar (Abfragen): $ausfaelle"
    "Protokoll: $csv"
)
$z | Set-Content $sum -Encoding UTF8
$z
