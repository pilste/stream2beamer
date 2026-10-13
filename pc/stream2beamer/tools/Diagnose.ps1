<#
  stream2beamer Diagnose - liest nur, aendert nichts.
  Sammelt alles, was fuer "Testbild geht, ATEM-Bild kommt nicht an" wichtig ist,
  und schreibt es nach Diagnose-Bericht.txt im Programmordner.
  Aufruf: tools\Diagnose.bat (als Administrator liefert mehr Firewall-Details)
  Parameter: -AtemIP 192.168.10.240 -Port 9000
#>
param([string]$AtemIP = '192.168.10.240', [int]$Port = 9000)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$out = New-Object Collections.Generic.List[string]
$summary = New-Object Collections.Generic.List[string]
function Line($t) { $out.Add($t); Write-Host $t }
function Result($level, $text) { $l = "[$level] $text"; $summary.Add($l); Line $l }
function Section($t) { Line ''; Line "=== $t ===" }
function Try-Run($name, [scriptblock]$sb) {
    try { & $sb } catch { Result 'FEHLER' "$($name): $($_.Exception.Message)" }
}

Section 'System'
Try-Run 'System' {
    Line "Zeit:        $(Get-Date -Format s)"
    Line "Windows:     $([Environment]::OSVersion.VersionString)"
    Line "PowerShell:  $($PSVersionTable.PSVersion)"
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Line "Admin:       $admin"
    if (-not $admin) { Result 'HINWEIS' 'Nicht als Administrator gestartet: einige Firewall-Details fehlen evtl.' }
}

Section 'stream2beamer'
Try-Run 'Programmordner' {
    Line "Ordner:      $root"
    $cfgPath = Join-Path $root 'config.json'
    if (Test-Path $cfgPath) { Line 'config.json:'; Get-Content $cfgPath | ForEach-Object { Line "  $_" } } else { Result 'WARNUNG' 'config.json fehlt' }
    if (Test-Path (Join-Path $root 'netz-sicherung.json')) { Result 'INFO' 'netz-sicherung.json vorhanden: feste IP ist aktiv (oder Absturzrest)' }
    foreach ($exe in 'mpv\mpv.exe', 'ffmpeg\ffplay.exe', 'ffmpeg\ffmpeg.exe') {
        Line ("{0,-20} {1}" -f $exe, (Test-Path (Join-Path $root $exe)))
    }
    $x = Join-Path $root 'ATEM-Dateien\stream2beamer-SRT.xml'
    if (Test-Path $x) {
        $url = ([xml](Get-Content $x -Raw)).streaming.service.servers.server.url
        Line "XML-Ziel:    $url"
        $urlIp = ($url -replace '^srt://', '' -split ':')[0]
        $mine = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
        if ($mine -contains $urlIp) { Result 'OK' "ATEM-Datei zeigt auf eine Adresse dieses Laptops ($urlIp)" }
        else { Result 'FEHLER' "ATEM-Datei zeigt auf $urlIp, der Laptop hat diese Adresse aber nicht. ATEM-Dateien neu erzeugen und laden." }
    } else { Result 'WARNUNG' 'ATEM-Dateien noch nicht erzeugt' }
}

Section 'Netzwerkadapter'
Try-Run 'Adapter' {
    foreach ($a in (Get-NetAdapter -ErrorAction Stop | Sort-Object Name)) {
        $ip = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength) $($_.AddressState)" }) -join ', '
        $dhcp = (Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
        Line ("{0,-22} {1,-12} {2,-14} DHCP={3,-8} {4}" -f $a.Name, $a.Status, $a.MediaType, $dhcp, $ip)
    }
    Line ''
    foreach ($p in (Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
        Line ("Netzprofil: {0,-22} Kategorie={1} ({2})" -f $p.InterfaceAlias, $p.NetworkCategory, $p.Name)
    }
}

Section "Erreichbarkeit ATEM $AtemIP"
Try-Run 'Ping' {
    $ok = Test-Connection -ComputerName $AtemIP -Count 2 -Quiet -ErrorAction SilentlyContinue
    if ($ok) { Result 'OK' "Ping auf $AtemIP beantwortet" } else { Result 'FEHLER' "Ping auf $AtemIP ohne Antwort" }
    $route = Find-NetRoute -RemoteIPAddress $AtemIP -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($route) { Line "Weg zum ATEM ueber Adapter: $($route.InterfaceAlias), eigene Quelladresse $(($route | Where-Object IPAddress).IPAddress)" }
    $n = Get-NetNeighbor -IPAddress $AtemIP -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($n) { Line "ARP: $AtemIP -> MAC $($n.LinkLayerAddress) ($($n.State)) ueber $($n.InterfaceAlias)" }
}

Section "Lauscht etwas auf UDP $Port?"
Try-Run 'UDP-Endpunkt' {
    $ep = @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue)
    if ($ep.Count -eq 0) { Result 'HINWEIS' "Niemand lauscht auf UDP $Port (Start in stream2beamer gedrueckt?)" }
    foreach ($e in $ep) {
        $proc = Get-Process -Id $e.OwningProcess -ErrorAction SilentlyContinue
        Result 'OK' "UDP $($e.LocalAddress):$Port gehoert $($proc.ProcessName) (PID $($e.OwningProcess), $($proc.Path))"
    }
}

Section 'Firewall'
Try-Run 'Firewall-Profile' {
    foreach ($fp in (Get-NetFirewallProfile -ErrorAction Stop)) {
        Line ("Profil {0,-8} aktiv={1,-5} Standard eingehend={2,-12} LogBlocked={3}" -f $fp.Name, $fp.Enabled, $fp.DefaultInboundAction, $fp.LogBlocked)
    }
}
Try-Run 'stream2beamer-Regel' {
    $r = @(Get-NetFirewallRule -DisplayName 'stream2beamer SRT' -ErrorAction SilentlyContinue)
    if ($r.Count -eq 0) { Result 'FEHLER' "Firewall-Regel 'stream2beamer SRT' fehlt" }
    foreach ($x in $r) {
        $pf = $x | Get-NetFirewallPortFilter; $af = $x | Get-NetFirewallAddressFilter
        Line "Regel: Enabled=$($x.Enabled) Action=$($x.Action) Profile=$($x.Profile) Protokoll=$($pf.Protocol) Port=$($pf.LocalPort) Remote=$($af.RemoteAddress -join ',')"
        if ("$($x.Enabled)" -eq 'True' -and "$($x.Action)" -eq 'Allow' -and "$($pf.LocalPort)" -eq "$Port") { Result 'OK' 'stream2beamer-Regel vorhanden und passend' }
        else { Result 'WARNUNG' 'stream2beamer-Regel weicht ab (Port, Aktion oder deaktiviert)' }
    }
}
Try-Run 'Blockier-Regeln' {
    $block = @(Get-NetFirewallApplicationFilter -ErrorAction Stop |
               Where-Object { $_.Program -match 'mpv|ffplay' } | Get-NetFirewallRule |
               Where-Object { $_.Direction -eq 'Inbound' -and $_.Action -eq 'Block' -and "$($_.Enabled)" -eq 'True' })
    if ($block.Count -gt 0) {
        foreach ($b in $block) { Result 'FEHLER' "Blockier-Regel: '$($b.DisplayName)' Profil=$($b.Profile) Programm=$(($b | Get-NetFirewallApplicationFilter).Program)" }
    } else { Result 'OK' 'keine Blockier-Regeln fuer mpv/ffplay' }
    $portBlock = @(Get-NetFirewallPortFilter -Protocol UDP -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq "$Port" } |
                   Get-NetFirewallRule | Where-Object { $_.Action -eq 'Block' -and "$($_.Enabled)" -eq 'True' })
    foreach ($b in $portBlock) { Result 'FEHLER' "Blockier-Regel auf UDP $($Port): '$($b.DisplayName)'" }
}
Try-Run 'Sicherheitssoftware' {
    $av = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | ForEach-Object { $_.displayName })
    $fw = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName FirewallProduct -ErrorAction SilentlyContinue | ForEach-Object { $_.displayName })
    Line "Virenscanner: $($av -join ', ')"
    Line "Fremd-Firewall: $($fw -join ', ')"
    if (@($fw | Where-Object { $_ -and $_ -notmatch 'Windows|Defender' }).Count -gt 0) { Result 'WARNUNG' "Fremd-Firewall aktiv: $($fw -join ', '). Dort UDP $Port freigeben." }
}

Section 'Zusammenfassung'
$summary | ForEach-Object { Line $_ }
$file = Join-Path $root 'Diagnose-Bericht.txt'
try {
    [IO.File]::WriteAllText("$file.tmp", ($out -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($false)))
    Move-Item "$file.tmp" $file -Force
    Write-Host "`nBericht gespeichert: $file" -ForegroundColor Cyan
} catch { Write-Host "Bericht konnte nicht gespeichert werden: $_" }
