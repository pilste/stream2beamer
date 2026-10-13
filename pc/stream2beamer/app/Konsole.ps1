<#
  stream2beamer ohne Fenster: liest config.json, wartet auf den ATEM, zeigt das Bild im Vollbild.
  Nach jedem Abbruch wird sofort neu gewartet. Beenden: Strg+C.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace Win -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][Win.Dpi]::SetProcessDPIAware()
Get-ChildItem $script:AppRoot -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

$cfg = Get-Config

# Absturzrest vom letzten Mal zuerst zuruecksetzen
if (Test-NetBackupExists) {
    if (Test-IsAdmin) { [void](Restore-NetState); Write-Host 'Alte Netzwerk-Sicherung gefunden und wiederhergestellt.' -ForegroundColor Yellow }
    else { Write-Warning 'Alte Netzwerk-Sicherung vorhanden. Als Administrator starten, dann wird sie wiederhergestellt.' }
}
$netApplied = $false
if ($cfg.FesteIP) {
    if (-not (Test-IsAdmin)) {
        throw 'Feste IP ist eingestellt: stream2beamer-Konsole.bat per Rechtsklick "Als Administrator ausfuehren" starten, oder in config.json "FesteIP": false setzen.'
    }
    $netApplied = ((Enable-StaticIp $cfg) -eq 'gesetzt')
    $cfg.LaptopIP = $cfg.FesteIPAdresse
    Write-Host "Feste IP $($cfg.FesteIPAdresse)/$($cfg.FesteIPPraefix) aktiv, wird beim Beenden mit Strg+C zurueckgesetzt." -ForegroundColor Cyan
}

$player = $cfg.Player
if (-not (Get-PlayerPath $player)) {
    Write-Host "Player $player fehlt, nehme mpv." -ForegroundColor Yellow; $player = 'mpv'
}
$exe = Get-PlayerPath $player
if (-not $exe) { throw 'Kein Player gefunden (Ordner mpv fehlt?).' }

$all = [Windows.Forms.Screen]::AllScreens
$si = Select-TargetScreen $all $cfg.Monitor
$b = $all[$si].Bounds
$pArgs = Get-PlayerArgs $player $cfg $b $si
if ($player -eq 'mpv') { $exe = $exe -replace 'mpv\.exe$', 'mpv.com' }   # Konsolenvariante, PowerShell wartet darauf

$ip = Get-BestIP $cfg
Write-Host "Player $player | Bildschirm $($b.Width)x$($b.Height) bei $($b.X),$($b.Y) | Puffer $($cfg.LatenzMs) ms | Ton $($cfg.Ton)" -ForegroundColor Cyan
Write-Host "ATEM-Server: srt://$($ip):$($cfg.Port)   Beenden mit Strg+C."
try {
    while ($true) {
        $start = Get-Date
        & $exe @pArgs
        $dauer = ((Get-Date) - $start).TotalSeconds
        Write-Host ("[{0:HH:mm:ss}] Stream beendet, warte erneut ..." -f (Get-Date))
        if ($dauer -lt 2) { Start-Sleep -Seconds 2 }
    }
} finally {
    # laeuft auch bei Strg+C; wird das Fenster hart geschlossen, greift die Sicherung beim naechsten Start
    if ($netApplied) { [void](Restore-NetState); Write-Host 'Vorherige Netzwerkeinstellung wiederhergestellt.' }
}
