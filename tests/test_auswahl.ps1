<#
  Test der automatischen Auswahl (laeuft unter Windows PowerShell 5.1 und PowerShell 7 auf Linux).
  Prueft mit Attrappen der Windows-Netzwerkbefehle:
    - ATEM per USB (Adapter "Blackmagic Design ...") wird nie Ziel-IP und nie Adapter fuer die feste IP
    - Zielbildschirm 'auto' / Nummer, und mpv bekommt --screen statt --geometry
  Aufruf:  pwsh -NoProfile -File tests/test_auswahl.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'pc/stream2beamer/app/Common.ps1')
$fail = 0
function Ok($t)  { Write-Host "  OK   $t" -ForegroundColor Green }
function Bad($t) { Write-Host "  FEHLER $t" -ForegroundColor Red; $script:fail++ }

# Nachbau eines typischen Laptops: ATEM per USB mit echter Adresse, Kabel-Adapter nur APIPA, WLAN und VPN aktiv
$script:Adapters = @(
    [pscustomobject]@{ Name = 'Ethernet 4'; ifIndex = 21; InterfaceDescription = 'Blackmagic Design ATEM Mini Pro ISO'; Status = 'Up'; MediaType = '802.3'; Physical = $true }
    [pscustomobject]@{ Name = 'Ethernet 5'; ifIndex = 43; InterfaceDescription = 'USB-LAN-Adapter'; Status = 'Up'; MediaType = '802.3'; Physical = $true }
    [pscustomobject]@{ Name = 'WLAN'; ifIndex = 10; InterfaceDescription = 'WLAN-Adapter'; Status = 'Up'; MediaType = 'Native 802.11'; Physical = $true }
    [pscustomobject]@{ Name = 'VPN'; ifIndex = 13; InterfaceDescription = 'VPN-Tunnel'; Status = 'Up'; MediaType = 'IP'; Physical = $false }
)
$script:Ips = @(
    [pscustomobject]@{ IPAddress = '172.25.135.90'; InterfaceAlias = 'Ethernet 4'; InterfaceIndex = 21 }
    [pscustomobject]@{ IPAddress = '169.254.23.12'; InterfaceAlias = 'Ethernet 5'; InterfaceIndex = 43 }
    [pscustomobject]@{ IPAddress = '192.168.178.20'; InterfaceAlias = 'WLAN'; InterfaceIndex = 10 }
    [pscustomobject]@{ IPAddress = '10.8.0.2'; InterfaceAlias = 'VPN'; InterfaceIndex = 13 }
    [pscustomobject]@{ IPAddress = '127.0.0.1'; InterfaceAlias = 'Loopback'; InterfaceIndex = 1 }
)
function Get-NetAdapter { param([switch]$Physical, $ErrorAction)
    $script:Adapters | Where-Object { -not $Physical -or $_.Physical } }
function Get-NetIPAddress { param($InterfaceIndex, $AddressFamily, $ErrorAction)
    $script:Ips | Where-Object { $null -eq $InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex } }

$cfg = Get-DefaultConfig

Write-Host '1. ATEM per USB'
if (Test-AtemUsbAdapter 'Blackmagic Design ATEM Mini Pro ISO') { Ok 'Blackmagic-Adapter erkannt' } else { Bad 'Blackmagic-Adapter nicht erkannt' }
if (-not (Test-AtemUsbAdapter 'USB-LAN-Adapter')) { Ok 'USB-LAN-Adapter ist kein ATEM' } else { Bad 'USB-LAN-Adapter faelschlich als ATEM' }

$liste = @(Get-LaptopIPs)
$u = $liste | Where-Object { $_.IP -eq '172.25.135.90' }
if ($u.AtemUsb -and -not $u.Kabel) { Ok 'USB-Adresse als ATEM-USB markiert, nicht als Kabel' } else { Bad "USB-Adresse: AtemUsb=$($u.AtemUsb) Kabel=$($u.Kabel)" }
if ($liste[-1].IP -eq '172.25.135.90') { Ok 'USB-Adresse steht in der Liste ganz hinten' } else { Bad "Reihenfolge: $($liste.IP -join ', ')" }
if ($liste[0].IP -eq '169.254.23.12') { Ok 'Kabel-Adapter steht vorn' } else { Bad "erste IP $($liste[0].IP)" }

$best = Get-BestIP $cfg
if ($best -ne '172.25.135.90') { Ok "Get-BestIP nimmt nicht die USB-Adresse (sondern $best)" } else { Bad 'Get-BestIP nimmt die USB-Adresse (alter Fehler)' }

$eth = @(Get-EthernetAdapters)
if (($eth.Name -join ',') -eq 'Ethernet 5') { Ok 'Adapterliste fuer feste IP ohne ATEM-USB' } else { Bad "Adapterliste: $($eth.Name -join ',')" }
$ad = Get-CableAdapter $cfg
if ($ad.Name -eq 'Ethernet 5') { Ok 'Automatik waehlt Ethernet 5 fuer die feste IP' } else { Bad "Automatik waehlt $($ad.Name)" }

# Gegenprobe: ohne Kabel-Adapter darf trotzdem nie die USB-Adresse kommen
$script:Ips = @($script:Ips | Where-Object { $_.InterfaceIndex -ne 43 -and $_.InterfaceIndex -ne 10 -and $_.InterfaceIndex -ne 13 })
$best = Get-BestIP $cfg
if ($null -eq $best) { Ok 'nur ATEM-USB vorhanden: keine Ziel-IP statt falscher' } else { Bad "nur ATEM-USB: Get-BestIP = $best" }

Write-Host '2. Zielbildschirm'
$two = @([pscustomobject]@{ Primary = $true }, [pscustomobject]@{ Primary = $false })
$beamerFirst = @([pscustomobject]@{ Primary = $false }, [pscustomobject]@{ Primary = $true })
$one = @([pscustomobject]@{ Primary = $true })
$cases = @(
    @($two, 'auto', 1, 'auto, Beamer an zweiter Stelle'),
    @($beamerFirst, 'auto', 0, 'auto, Beamer an erster Stelle'),
    @($one, 'auto', 0, 'auto, nur ein Bildschirm'),
    @($two, '1', 0, 'Nummer 1'),
    @($two, '2', 1, 'Nummer 2'),
    @($two, '5', 1, 'Nummer zu gross -> auto'),
    @($two, '0', 1, 'Nummer 0 -> auto')
)
foreach ($c in $cases) {
    $r = Select-TargetScreen $c[0] $c[1]
    if ($r -eq $c[2]) { Ok "$($c[3]) -> $r" } else { Bad "$($c[3]): erwartet $($c[2]), bekommen $r" }
}

Write-Host '3. Player-Argumente'
$bounds = [pscustomobject]@{ X = 5760; Y = 0; Width = 2048; Height = 1200 }
$a = Get-PlayerArgs 'mpv' $cfg $bounds 1
if ($a -contains '--screen=1' -and $a -contains '--fs-screen=1' -and $a -contains '--fs') { Ok 'mpv mit --screen=1 --fs-screen=1 --fs' } else { Bad "mpv: $($a -join ' ')" }
if (-not ($a | Where-Object { $_ -like '--geometry=*' })) { Ok 'mpv ohne --geometry, wenn Bildschirm bekannt' } else { Bad 'mpv hat noch --geometry' }
if ($a[-1] -like 'srt://*') { Ok 'URL steht am Ende' } else { Bad "letztes Argument $($a[-1])" }
$a = Get-PlayerArgs 'mpv' $cfg $bounds
if ($a -contains '--geometry=2048x1200+5760+0') { Ok 'ohne Bildschirmnummer: altes Verhalten (--geometry)' } else { Bad "mpv ohne Index: $($a -join ' ')" }
$a = Get-PlayerArgs 'ffplay' $cfg $bounds 1
if ($a -contains '-left' -and $a -contains '5760') { Ok 'ffplay unveraendert mit -left/-top' } else { Bad "ffplay: $($a -join ' ')" }

if ($fail) { Write-Host "$fail Fehler" -ForegroundColor Red; exit 1 } else { Write-Host 'Alle Tests bestanden' -ForegroundColor Green }
