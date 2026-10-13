<#
  Common.ps1 - gemeinsame Funktionen fuer GUI (Gui.ps1) und Konsole (Konsole.ps1).
  Keine Windows-Abhaengigkeit ausser in Get-LaptopIPs, Set-FirewallRule, Install-FFmpeg:
  der Rest laeuft auch unter PowerShell 7 auf Linux (Tests in /tests).
#>

$script:AppRoot    = Split-Path -Parent $PSScriptRoot      # Ordner stream2beamer
$script:ConfigPath = Join-Path $script:AppRoot 'config.json'
$script:RuleName   = 'stream2beamer SRT'

function Get-DefaultConfig {
    [ordered]@{
        Port         = 9000      # UDP-Port fuer SRT
        LatenzMs     = 120       # SRT-Puffer im Laptop
        AtemLatenzMs = 120       # SRT-Latenz in der ATEM-XML
        Player       = 'mpv'     # 'mpv' (beiliegend) oder 'ffplay' (nachladbar)
        Ton          = $false    # Ton abspielen
        Monitor      = 'auto'    # 'auto' = erster Nicht-Hauptbildschirm, sonst 1,2,...
        LaptopIP     = 'auto'    # IP fuer die ATEM-Dateien
        StreamKey    = 'beamer'  # Key fuer Variante "Custom URL H.264"
        FesteIP        = $false            # waehrend der Benutzung feste IP am Kabel-Adapter setzen
        FesteIPAdresse = '192.168.10.10'
        FesteIPPraefix = 24                # 24 = Subnetzmaske 255.255.255.0
        FesteIPAdapter = 'auto'            # 'auto' = erster physischer Ethernet-Adapter, sonst Adaptername
    }
}

function Get-Config {
    $cfg = Get-DefaultConfig
    if (Test-Path $script:ConfigPath) {
        try {
            $j = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                if ($null -ne $j.$k) { $cfg[$k] = $j.$k }
            }
        } catch { Write-Warning "config.json unlesbar, nehme Standardwerte: $_" }
    }
    $cfg.Port = [int]$cfg.Port; $cfg.LatenzMs = [int]$cfg.LatenzMs; $cfg.AtemLatenzMs = [int]$cfg.AtemLatenzMs
    $cfg.Ton = [bool]$cfg.Ton
    $cfg.FesteIP = [bool]$cfg.FesteIP; $cfg.FesteIPPraefix = [int]$cfg.FesteIPPraefix
    return $cfg
}

# Datei atomar schreiben: Temp-Datei, Leer-Check, ersetzen
function Write-Atomic([string]$Path, [string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { throw "Leerer Inhalt fuer $Path" }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding($false)))
    Move-Item -Path $tmp -Destination $Path -Force
}

function Save-Config($cfg) {
    Write-Atomic $script:ConfigPath (($cfg | ConvertTo-Json) + "`n")
}

function Get-PlayerPath([string]$Player) {
    if ($Player -eq 'mpv') {
        foreach ($n in @('mpv.exe', 'mpv')) {
            $p = Join-Path $script:AppRoot "mpv/$n"; if (Test-Path $p -PathType Leaf) { return $p }
        }
    } else {
        foreach ($n in @('ffplay.exe', 'ffplay')) {
            $p = Join-Path $script:AppRoot "ffmpeg/$n"; if (Test-Path $p -PathType Leaf) { return $p }
        }
    }
    return $null
}

function Get-FFmpegPath {
    foreach ($n in @('ffmpeg.exe', 'ffmpeg')) {
        $p = Join-Path $script:AppRoot "ffmpeg/$n"; if (Test-Path $p -PathType Leaf) { return $p }
    }
    return $null
}

function Get-ListenUrl($cfg) {
    "srt://0.0.0.0:$($cfg.Port)?mode=listener&latency=$([int]$cfg.LatenzMs * 1000)"
}

<#
  Argumente fuer den Player. $Bounds: Objekt mit X, Y, Width, Height (Zielbildschirm).
  Alle Schalter im Container mit echtem SRT-Stream getestet (siehe tests/test_pc.ps1).
#>
# USB-Netz des ATEM (Adapter "Blackmagic Design ATEM ..."): nur Steuerung, nie Ziel fuer Stream oder feste IP
function Test-AtemUsbAdapter([string]$Description) { $Description -match 'Blackmagic' }

# Zielbildschirm als Index in der Bildschirmliste. Monitor 'auto' = erster Nicht-Hauptbildschirm, sonst 1,2,...
function Select-TargetScreen($Screens, $Monitor) {
    $list = @($Screens)
    if ("$Monitor" -ne 'auto') {
        $i = [int]$Monitor - 1
        if ($i -ge 0 -and $i -lt $list.Count) { return $i }
    }
    for ($i = 0; $i -lt $list.Count; $i++) { if (-not $list[$i].Primary) { return $i } }
    return 0
}

<#
  ScreenIndex >= 0: mpv per --screen/--fs-screen auf den Bildschirm legen. Grund: Bei unterschiedlich
  skalierten Bildschirmen landete mpv mit --geometry (echte Pixel) auf dem Hauptbildschirm und ohne Vollbild
  (getestet 12.10.2026). Die Nummerierung von mpv entspricht der Reihenfolge von Screen.AllScreens.
#>
function Get-PlayerArgs([string]$Player, $cfg, $Bounds, [int]$ScreenIndex = -1) {
    $url = Get-ListenUrl $cfg
    if ($Player -eq 'ffplay') {
        $a = @('-hide_banner', '-loglevel', 'warning',
               '-fflags', 'nobuffer', '-flags', 'low_delay', '-framedrop',
               '-autoexit', '-noborder', '-window_title', 'stream2beamer',
               '-left', "$($Bounds.X)", '-top', "$($Bounds.Y)",
               '-x', "$($Bounds.Width)", '-y', "$($Bounds.Height)", '-fs')
        if ($cfg.Ton) { $a += @('-probesize', '500000', '-analyzeduration', '500000') }
        else          { $a += @('-probesize', '32768', '-analyzeduration', '0', '-an', '-sync', 'ext') }
    } else {
        $a = @('--profile=low-latency', '--no-cache', '--demuxer-lavf-o=fflags=+nobuffer',
               '--no-osc', '--osd-level=0', '--title=stream2beamer', '--msg-level=all=warn',
               '--no-config', '--keep-open=no', '--idle=no')
        if ($ScreenIndex -ge 0) { $a += @("--screen=$ScreenIndex", "--fs-screen=$ScreenIndex", '--fs') }
        else { $a += @(('--geometry={0}x{1}+{2}+{3}' -f $Bounds.Width, $Bounds.Height, $Bounds.X, $Bounds.Y), '--fs') }
        if (-not $cfg.Ton) { $a += @('--aid=no', '--untimed') }
    }
    return ,($a + $url)
}

# Windows-Kommandozeile aus Argumentliste bauen (fuer ProcessStartInfo.Arguments)
function Join-WinArgs([string[]]$Items) {
    ($Items | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
}

function New-AtemXml([string]$Ip, $cfg, [bool]$Extended) {
    if ($Ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "IP '$Ip' ist keine IPv4-Adresse." }
    $nl = "`n"
    $srtExt = ''; $ll = ''; $kf = '2'; $name = 'stream2beamer SRT (einfach)'
    if ($Extended) {
        $name = 'stream2beamer SRT'
        $srtExt = $nl + '                <srt-extensions>' + $nl +
                  '                    <stream-latency>' + $nl +
                  ('                        <item key="latency" value="{0}"/>' -f [int]$cfg.AtemLatenzMs) + $nl +
                  '                    </stream-latency>' + $nl +
                  '                </srt-extensions>'
        $ll = $nl + '                <low-latency/>'
        $kf = '1'
    }
    $cfgBlock = {
        param($fps, $br)
        '                <config resolution="1080p" fps="' + $fps + '">' + $nl +
        '                    <bitrate>' + $br + '</bitrate>' + $nl +
        '                    <audio-bitrate>128000</audio-bitrate>' + $nl +
        '                    <keyframe-interval>' + $kf + '</keyframe-interval>' + $nl +
        '                </config>'
    }
    return '<?xml version="1.0" encoding="UTF-8"?>' + $nl +
        '<streaming>' + $nl +
        '    <service>' + $nl +
        "        <name>$name</name>" + $nl +
        '        <servers>' + $nl +
        '            <server group="Primary">' + $nl +
        "                <name>Laptop $Ip</name>" + $nl +
        "                <url>srt://$($Ip):$($cfg.Port)</url>" + $srtExt + $nl +
        '            </server>' + $nl +
        '        </servers>' + $nl +
        '        <profiles>' + $nl +
        '            <profile>' + $nl +
        '                <name>Beamer</name>' + $ll + $nl +
        (& $cfgBlock '60' '8000000') + $nl +
        (& $cfgBlock '30' '6000000') + $nl +
        '            </profile>' + $nl +
        '        </profiles>' + $nl +
        '    </service>' + $nl +
        '</streaming>' + $nl
}

# schreibt beide ATEM-Dateien + Text-Anleitung in den Ordner ATEM-Dateien, gibt den Ordner zurueck
function Export-AtemFiles([string]$Ip, $cfg) {
    $dir = Join-Path $script:AppRoot 'ATEM-Dateien'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    foreach ($v in @(@{ F = 'stream2beamer-SRT.xml'; E = $true }, @{ F = 'stream2beamer-SRT-einfach.xml'; E = $false })) {
        $xml = New-AtemXml $Ip $cfg $v.E
        [xml]$xml | Out-Null   # wirft bei kaputtem XML
        Write-Atomic (Join-Path $dir $v.F) $xml
    }
    $txt = @(
        'ATEM einrichten (Firmware und ATEM Software Control mindestens 9.6)', '',
        'Weg A (empfohlen): stream2beamer-SRT.xml in ATEM Software Control laden,',
        '  Plattform "stream2beamer SRT" waehlen.', '',
        'Weg B: Kommt mit A keine Verbindung zustande: stream2beamer-SRT-einfach.xml laden.', '',
        'Weg C ohne Datei: Ausgang > Live-Stream > Plattform "Custom URL H.264"',
        "  Server: srt://$($Ip):$($cfg.Port)",
        "  Key:    $($cfg.StreamKey)"
    ) -join "`r`n"
    Write-Atomic (Join-Path $dir 'ATEM-Einstellungen.txt') ($txt + "`r`n")
    return $dir
}

# --- ab hier nur Windows ---

function Get-LaptopIPs {
    # ATEM per USB erscheint als eigener Ethernet-Adapter mit echter Adresse (z. B. 172.25.x/30).
    # Er darf nie als Ziel in die ATEM-Dateien, der Stream geht ueber das Netzwerkkabel.
    $atem = @(Get-NetAdapter -ErrorAction SilentlyContinue |
              Where-Object { Test-AtemUsbAdapter $_.InterfaceDescription } | ForEach-Object { $_.ifIndex })
    $eth = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
             Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' -and $atem -notcontains $_.ifIndex } |
             ForEach-Object { $_.ifIndex })
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' } |
        ForEach-Object {
            [pscustomobject]@{
                IP       = $_.IPAddress
                Adapter  = $_.InterfaceAlias
                Kabel    = ($eth -contains $_.InterfaceIndex)
                Apipa    = ($_.IPAddress -like '169.254.*')
                AtemUsb  = ($atem -contains $_.InterfaceIndex)
            }
        } | Sort-Object @{ E = { $_.AtemUsb } }, @{ E = { -not $_.Kabel } }, @{ E = { $_.Apipa } }, Adapter
}

function Get-BestIP($cfg) {
    if ($cfg.LaptopIP -ne 'auto') { return $cfg.LaptopIP }
    $ip = Get-LaptopIPs | Where-Object { -not $_.Apipa -and -not $_.AtemUsb } | Select-Object -First 1
    if ($ip) { return $ip.IP } else { return $null }
}

function Test-FirewallRule {
    [bool](Get-NetFirewallRule -DisplayName $script:RuleName -ErrorAction SilentlyContinue)
}

# legt die Regel mit Adminrechten an (UAC-Abfrage). Profile Any, aber nur lokales Subnetz.
function Set-FirewallRule($cfg) {
    $cmd = "Get-NetFirewallRule -DisplayName '$($script:RuleName)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule; " +
           "New-NetFirewallRule -DisplayName '$($script:RuleName)' -Direction Inbound -Protocol UDP " +
           "-LocalPort $([int]$cfg.Port) -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null"
    $p = Start-Process powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
         -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
    return ($p.ExitCode -eq 0)
}

# laedt ffplay + ffmpeg (BtbN, GitHub) nach .\ffmpeg; Ordner wird erst komplett gebaut, dann umbenannt
function Install-FFmpeg([scriptblock]$Log) {
    $url = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
    $target = Join-Path $script:AppRoot 'ffmpeg'
    $tmp = Join-Path $env:TEMP ('stream2beamer-player-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        & $Log 'Lade FFmpeg (ca. 150 MB) ...'
        $zip = Join-Path $tmp 'ffmpeg.zip'
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        if ((Get-Item $zip).Length -lt 10MB) { throw 'Download zu klein, vermutlich fehlgeschlagen.' }
        & $Log 'Entpacke ...'
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $bin = Get-ChildItem -Path $tmp -Recurse -Filter 'ffplay.exe' | Select-Object -First 1
        if (-not $bin) { throw 'ffplay.exe nicht im Archiv gefunden.' }
        $stage = "$target.tmp"
        if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
        New-Item -ItemType Directory -Path $stage | Out-Null
        Copy-Item (Join-Path $bin.DirectoryName 'ffplay.exe'), (Join-Path $bin.DirectoryName 'ffmpeg.exe') $stage
        if (Test-Path $target) { Remove-Item $target -Recurse -Force }
        Rename-Item $stage 'ffmpeg'
        $prot = & (Join-Path $target 'ffplay.exe') -hide_banner -protocols 2>$null
        if (-not ($prot -match '^\s*srt\s*$')) { throw 'Geladenes ffplay kann kein SRT.' }
        & $Log 'FFmpeg installiert, SRT OK.'
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Testbild per SRT an diesen Rechner (braucht ffmpeg). Gibt den Prozess zurueck.
function Start-Testbild($cfg) {
    $ff = Get-FFmpegPath
    if (-not $ff) { throw 'Testbild braucht FFmpeg. Erst "FFmpeg nachladen".' }
    $ffArgs = @('-hide_banner', '-loglevel', 'error', '-re',
              '-f', 'lavfi', '-i', 'testsrc2=size=1920x1080:rate=25',
              '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '60',
              '-c:v', 'libx264', '-preset', 'veryfast', '-tune', 'zerolatency', '-g', '50', '-pix_fmt', 'yuv420p',
              '-c:a', 'aac', '-b:a', '128k', '-f', 'mpegts', "srt://127.0.0.1:$($cfg.Port)?mode=caller")
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $ff; $psi.Arguments = Join-WinArgs $ffArgs
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    return [Diagnostics.Process]::Start($psi)
}


# =====================================================================
#  Feste IP waehrend der Benutzung (nur Windows, braucht Adminrechte)
#  Ablauf: Zustand sichern (Datei) -> Plan ausfuehren -> beim Schliessen
#  Sicherung zurueckspielen -> Datei loeschen. Liegt beim Start noch eine
#  Sicherung herum (Absturz), wird sie zuerst wiederhergestellt.
#  Die Plaene sind reine Daten und unter Linux mit Attrappen testbar.
# =====================================================================

$script:NetStatePath = Join-Path $script:AppRoot 'netz-sicherung.json'

function Test-IsAdmin {
    try {
        ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

function Test-IPv4([string]$Ip, [int]$Prefix) {
    if ($Ip -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    $o = 1..4 | ForEach-Object { [int]$Matches[$_] }
    if (($o | Where-Object { $_ -gt 255 }).Count -gt 0) { return $false }
    if ($Prefix -lt 8 -or $Prefix -gt 30) { return $false }
    if ($o[0] -eq 0 -or $o[0] -eq 127 -or $o[0] -ge 224) { return $false }
    if ($o[0] -eq 169 -and $o[1] -eq 254) { return $false }
    # Netz- und Broadcastadresse ausschliessen
    $n = ([uint32]$o[0] -shl 24) -bor ([uint32]$o[1] -shl 16) -bor ([uint32]$o[2] -shl 8) -bor [uint32]$o[3]
    $hostBits = 32 - $Prefix
    $hostPart = $n -band ([uint32]([math]::Pow(2, $hostBits) - 1))
    if ($hostPart -eq 0 -or $hostPart -eq [uint32]([math]::Pow(2, $hostBits) - 1)) { return $false }
    return $true
}

function Test-NetBackupExists { Test-Path $script:NetStatePath }

# alle physischen Ethernet-Adapter mit ihren IPv4-Adressen (fuer Auswahlliste und Automatik)
function Get-EthernetAdapters {
    @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
      Where-Object { $_.MediaType -eq '802.3' -and -not (Test-AtemUsbAdapter $_.InterfaceDescription) } | ForEach-Object {
        $ips = @(Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
        [pscustomobject]@{
            Adapter = $_
            Name    = $_.Name
            Up      = ($_.Status -eq 'Up')
            IPs     = $ips
            RealIPs = @($ips | Where-Object { $_ -notlike '169.254.*' })   # 169.254 = kein DHCP-Server erreichbar
        }
    })
}

function Get-AdapterText($e) {
    $st = if (-not $e.Up) { 'kein Kabel' } elseif ($e.RealIPs.Count -gt 0) { $e.RealIPs -join ', ' } else { 'kein Netz mit Router' }
    "$($e.Name)  ($st)"
}

<#
  Adapter fuer die feste IP. Reihenfolge:
  1. in der Konfig gewaehlter Name
  2. Adapter, der die feste Adresse schon hat
  3. verbundener Adapter OHNE echte Adresse (typisch: Switch ohne Router)
  4. erster verbundener Adapter, 5. irgendeiner
#>
function Get-CableAdapter($cfg) {
    $all = Get-EthernetAdapters
    if ($all.Count -eq 0) { throw 'Kein Ethernet-Adapter gefunden (USB-LAN-Adapter eingesteckt?).' }
    if ($cfg.FesteIPAdapter -and $cfg.FesteIPAdapter -ne 'auto') {
        $e = $all | Where-Object { $_.Name -eq $cfg.FesteIPAdapter } | Select-Object -First 1
        if ($e) { return $e.Adapter }
    }
    $e = $all | Where-Object { $_.IPs -contains $cfg.FesteIPAdresse } | Select-Object -First 1
    if (-not $e) { $e = $all | Where-Object { $_.Up -and $_.RealIPs.Count -eq 0 } | Select-Object -First 1 }
    if (-not $e) { $e = $all | Where-Object { $_.Up } | Select-Object -First 1 }
    if (-not $e) { $e = $all | Select-Object -First 1 }
    return $e.Adapter
}

function Get-NetState($Adapter) {
    $i = $Adapter.ifIndex
    $ipIf = Get-NetIPInterface -InterfaceIndex $i -AddressFamily IPv4
    $addr = @(Get-NetIPAddress -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.254.*' } |
              ForEach-Object { [ordered]@{ IPAddress = $_.IPAddress; PrefixLength = [int]$_.PrefixLength } })
    $gw = @(Get-NetRoute -InterfaceIndex $i -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.NextHop } | Where-Object { $_ -and $_ -ne '0.0.0.0' })
    [ordered]@{
        Version     = 1
        Zeit        = (Get-Date).ToString('s')
        AdapterName = $Adapter.Name
        Mac         = $Adapter.MacAddress
        Dhcp        = ("$($ipIf.Dhcp)" -eq 'Enabled')
        Adressen    = $addr
        Gateways    = $gw
    }
}

function New-StaticPlan([string]$Ip, [int]$Prefix) {
    ,@(
        @{ Op = 'DhcpAus' },
        @{ Op = 'AdressenLoeschen' },
        @{ Op = 'GatewayLoeschen' },
        @{ Op = 'AdresseSetzen'; IP = $Ip; Prefix = $Prefix; Gateway = $null }
    )
}

function New-RestorePlan($State) {
    $plan = @(@{ Op = 'AdressenLoeschen' }, @{ Op = 'GatewayLoeschen' })
    if ($State.Dhcp) {
        $plan += @{ Op = 'DhcpEin' }
    } else {
        $first = $true
        foreach ($a in @($State.Adressen)) {
            $gw = $null
            if ($first -and @($State.Gateways).Count -gt 0) { $gw = @($State.Gateways)[0] }
            $plan += @{ Op = 'AdresseSetzen'; IP = $a.IPAddress; Prefix = [int]$a.PrefixLength; Gateway = $gw }
            $first = $false
        }
    }
    ,$plan
}

function Invoke-NetPlan([int]$IfIndex, $Plan) {
    foreach ($s in $Plan) {
        switch ($s.Op) {
            'DhcpAus' { Set-NetIPInterface -InterfaceIndex $IfIndex -AddressFamily IPv4 -Dhcp Disabled }
            'DhcpEin' { Set-NetIPInterface -InterfaceIndex $IfIndex -AddressFamily IPv4 -Dhcp Enabled }
            'AdressenLoeschen' {
                foreach ($a in @(Get-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
                    Remove-NetIPAddress -InterfaceIndex $IfIndex -IPAddress $a.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
            'GatewayLoeschen' {
                Remove-NetRoute -InterfaceIndex $IfIndex -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue
            }
            'AdresseSetzen' {
                if ($s.Gateway) {
                    New-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -IPAddress $s.IP -PrefixLength $s.Prefix -DefaultGateway $s.Gateway | Out-Null
                } else {
                    New-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -IPAddress $s.IP -PrefixLength $s.Prefix | Out-Null
                }
            }
            default { throw "Unbekannter Schritt $($s.Op)" }
        }
    }
}

# setzt die feste IP. Rueckgabe: 'gesetzt' oder 'unveraendert' (Adresse war schon da)
function Enable-StaticIp($cfg) {
    if (-not (Test-IPv4 $cfg.FesteIPAdresse $cfg.FesteIPPraefix)) { throw "Ungueltige feste IP: $($cfg.FesteIPAdresse)/$($cfg.FesteIPPraefix)" }
    if (Test-NetBackupExists) { throw 'Es liegt noch eine Netzwerk-Sicherung vor. Erst wiederherstellen.' }
    $ad = Get-CableAdapter $cfg
    $state = Get-NetState $ad
    if ((-not $state.Dhcp) -and (@($state.Adressen | Where-Object { $_.IPAddress -eq $cfg.FesteIPAdresse }).Count -gt 0)) {
        return 'unveraendert'
    }
    Write-Atomic $script:NetStatePath (($state | ConvertTo-Json -Depth 5) + "`n")   # Sicherung VOR jeder Aenderung
    try {
        Invoke-NetPlan $ad.ifIndex (New-StaticPlan $cfg.FesteIPAdresse $cfg.FesteIPPraefix)
        Start-Sleep -Milliseconds 1500    # Windows prueft in dieser Zeit auf doppelte Adressen
        $now = Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -eq $cfg.FesteIPAdresse }
        if (-not $now) { throw 'Adresse wurde nicht uebernommen.' }
        if ("$($now.AddressState)" -eq 'Duplicate') { throw "Adresse $($cfg.FesteIPAdresse) ist im Netz schon vergeben." }
    } catch {
        $err = $_.Exception.Message
        try { [void](Restore-NetState) } catch {}
        throw "$err Vorherige Einstellung wurde wiederhergestellt."
    }
    return 'gesetzt'
}

# spielt die Sicherung zurueck. Rueckgabe: $true wenn etwas wiederhergestellt wurde
function Restore-NetState {
    if (-not (Test-NetBackupExists)) { return $false }
    $state = Get-Content $script:NetStatePath -Raw | ConvertFrom-Json
    $ad = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.MacAddress -eq $state.Mac } | Select-Object -First 1
    if (-not $ad) { $ad = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $state.AdapterName } | Select-Object -First 1 }
    if (-not $ad) { throw "Adapter $($state.AdapterName) nicht gefunden. Sicherung bleibt in $($script:NetStatePath)." }
    Invoke-NetPlan $ad.ifIndex (New-RestorePlan $state)
    Remove-Item $script:NetStatePath -Force
    return $true
}

function Get-NetStateText($State) {
    if ($State.Dhcp) { return 'automatisch (DHCP)' }
    ($State.Adressen | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ', '
}
