<#
  Test der Funktion "feste IP waehrend der Benutzung" unter Linux.
  Die Windows-Netzwerkbefehle (Get-NetAdapter, New-NetIPAddress ...) werden durch Attrappen ersetzt,
  die einen virtuellen Adapter im Speicher fuehren. Geprueft wird der komplette Ablauf aus Common.ps1:
  sichern -> setzen -> wiederherstellen, Absturzreste, Adresskonflikt, Eingabepruefung.
  Aufruf:  pwsh -NoProfile -File tests/test_netz.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($t)  { Write-Host "  OK   $t" -ForegroundColor Green }
function Bad($t) { Write-Host "  FEHLER $t" -ForegroundColor Red; $script:fail++ }

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('atem-netz-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'app') | Out-Null
Copy-Item (Join-Path $repo 'pc/stream2beamer/app/Common.ps1') (Join-Path $tmpRoot 'app')
. (Join-Path $tmpRoot 'app/Common.ps1')

# ---------- virtueller Adapter ----------
function Reset-Fake([string]$Dhcp, $Addr, $Routes, $Lease) {
    $global:Fake = @{ Dhcp = $Dhcp; Addr = [Collections.ArrayList]@($Addr); Routes = [Collections.ArrayList]@($Routes)
                      Lease = $Lease; DupIP = $null; Calls = [Collections.ArrayList]@() }
}
function global:Get-NetAdapter { [CmdletBinding()] param([switch]$Physical)
    [pscustomobject]@{ Name = 'WLAN'; ifIndex = 3; MacAddress = 'AA-AA-AA-AA-AA-AA'; Status = 'Up'; MediaType = 'Native 802.11' }
    [pscustomobject]@{ Name = 'Ethernet 4'; ifIndex = 5; MacAddress = 'BB-BB-BB-BB-BB-BB'; Status = 'Up'; MediaType = '802.3' }
    [pscustomobject]@{ Name = 'Ethernet'; ifIndex = 7; MacAddress = '00-11-22-33-44-55'; Status = 'Up'; MediaType = '802.3' } }
$global:OtherIP = '172.25.135.90'   # Ethernet 4 haengt an einem Netz mit DHCP und darf nie veraendert werden
function global:Get-NetIPInterface { [CmdletBinding()] param($InterfaceIndex, $AddressFamily)
    [pscustomobject]@{ Dhcp = $global:Fake.Dhcp } }
function global:Get-NetIPAddress { [CmdletBinding()] param($InterfaceIndex, $AddressFamily, $IPAddress)
    if ($InterfaceIndex -eq 5) { return [pscustomobject]@{ IPAddress = $global:OtherIP; PrefixLength = 16; AddressState = 'Preferred' } }
    foreach ($a in $global:Fake.Addr) {
        $st = if ($a.IP -eq $global:Fake.DupIP) { 'Duplicate' } else { 'Preferred' }
        [pscustomobject]@{ IPAddress = $a.IP; PrefixLength = $a.Prefix; AddressState = $st } } }
function global:Get-NetRoute { [CmdletBinding()] param($InterfaceIndex, $AddressFamily, $DestinationPrefix)
    foreach ($r in $global:Fake.Routes) { [pscustomobject]@{ NextHop = $r } } }
function global:Set-NetIPInterface { [CmdletBinding()] param($InterfaceIndex, $AddressFamily, $Dhcp)
    if ($InterfaceIndex -ne 7) { [void]$global:Fake.Calls.Add("FALSCHER ADAPTER $InterfaceIndex") }
    [void]$global:Fake.Calls.Add("Dhcp=$Dhcp")
    $global:Fake.Dhcp = $Dhcp
    if ($Dhcp -eq 'Enabled' -and $global:Fake.Lease) {   # DHCP-Server vergibt wieder eine Adresse
        [void]$global:Fake.Addr.Add($global:Fake.Lease.A); [void]$global:Fake.Routes.Add($global:Fake.Lease.G) } }
function global:Remove-NetIPAddress { [CmdletBinding(SupportsShouldProcess)] param($InterfaceIndex, $IPAddress)
    if ($InterfaceIndex -ne 7) { [void]$global:Fake.Calls.Add("FALSCHER ADAPTER $InterfaceIndex") }
    [void]$global:Fake.Calls.Add("Del $IPAddress")
    $x = @($global:Fake.Addr | Where-Object { $_.IP -eq $IPAddress }); foreach ($y in $x) { $global:Fake.Addr.Remove($y) } }
function global:Remove-NetRoute { [CmdletBinding(SupportsShouldProcess)] param($InterfaceIndex, $DestinationPrefix)
    if ($InterfaceIndex -ne 7) { [void]$global:Fake.Calls.Add("FALSCHER ADAPTER $InterfaceIndex") }
    [void]$global:Fake.Calls.Add('DelGW'); $global:Fake.Routes.Clear() }
function global:New-NetIPAddress { [CmdletBinding()] param($InterfaceIndex, $AddressFamily, $IPAddress, $PrefixLength, $DefaultGateway)
    if ($InterfaceIndex -ne 7) { [void]$global:Fake.Calls.Add("FALSCHER ADAPTER $InterfaceIndex") }
    if ($global:Fake.Dhcp -eq 'Enabled') { throw 'Windows lehnt feste Adresse bei aktivem DHCP ab' }
    [void]$global:Fake.Calls.Add("Add $IPAddress/$PrefixLength gw=$DefaultGateway")
    [void]$global:Fake.Addr.Add(@{ IP = $IPAddress; Prefix = $PrefixLength })
    if ($DefaultGateway) { [void]$global:Fake.Routes.Add($DefaultGateway) } }
function global:Start-Sleep { param($Milliseconds, $Seconds) }
function Show { "Dhcp=$($Fake.Dhcp) Addr=$(($Fake.Addr | % { "$($_.IP)/$($_.Prefix)" }) -join ',') GW=$($Fake.Routes -join ',')" }

$cfg = Get-DefaultConfig
$cfg.FesteIPAdapter = 'Ethernet'

Write-Host '1. Eingabepruefung Test-IPv4'
$cases = @(
    @('192.168.10.10', 24, $true), @('192.168.10.0', 24, $false), @('192.168.10.255', 24, $false),
    @('10.0.0.1', 8, $true), @('256.1.1.1', 24, $false), @('169.254.1.1', 16, $false),
    @('127.0.0.1', 8, $false), @('abc', 24, $false), @('192.168.10.10', 31, $false), @('224.0.0.5', 24, $false))
foreach ($c in $cases) {
    $r = Test-IPv4 $c[0] $c[1]
    if ($r -eq $c[2]) { Ok "$($c[0])/$($c[1]) -> $r" } else { Bad "$($c[0])/$($c[1]) -> $r (erwartet $($c[2]))" }
}

Write-Host '2. Adapterwahl (typische Lage: Ethernet 4 im DHCP-Netz wird zuerst gemeldet, Ethernet am Switch ohne Router)'
$auto = Get-DefaultConfig
Reset-Fake 'Enabled' @(@{ IP = '169.254.12.34'; Prefix = 16 }) @() $null
$ad = Get-CableAdapter $auto
if ($ad.Name -eq 'Ethernet') { Ok 'Automatik nimmt den Switch-Adapter ohne Router-Netz, nicht Ethernet 4' } else { Bad "Automatik nahm $($ad.Name)" }
$r = Enable-StaticIp $auto
$wrong = @($Fake.Calls | Where-Object { $_ -like 'FALSCHER*' })
if ($r -eq 'gesetzt' -and $wrong.Count -eq 0) { Ok "feste IP nur auf Ethernet gesetzt: $(Show)" } else { Bad "$r $($Fake.Calls -join ';')" }
$ad2 = Get-CableAdapter $auto
if ($ad2.Name -eq 'Ethernet') { Ok 'danach weiter Ethernet (hat jetzt die feste Adresse)' } else { Bad "danach $($ad2.Name)" }
[void](Restore-NetState)
if ((Show) -eq 'Dhcp=Enabled Addr= GW=' -and -not (Test-NetBackupExists)) { Ok 'zurueck auf DHCP' } else { Bad (Show) }
$manual = Get-DefaultConfig; $manual.FesteIPAdapter = 'Ethernet 4'
if ((Get-CableAdapter $manual).Name -eq 'Ethernet 4') { Ok 'ausdruecklich gewaehlter Adapter hat Vorrang' } else { Bad 'Wahl ignoriert' }
$gone = Get-DefaultConfig; $gone.FesteIPAdapter = 'Ethernet 9'
if ((Get-CableAdapter $gone).Name -eq 'Ethernet') { Ok 'gewaehlter Adapter fehlt: Automatik greift' } else { Bad 'kein Rueckfall' }
$list = Get-EthernetAdapters
$t = ($list | ForEach-Object { Get-AdapterText $_ }) -join ' | '
if ($t -eq 'Ethernet 4  (172.25.135.90) | Ethernet  (kein Netz mit Router)') { Ok "Auswahlliste: $t" } else { Bad "Auswahlliste: $t" }
if (@($list | Where-Object { $_.Name -eq 'WLAN' }).Count -eq 0) { Ok 'WLAN nicht in der Liste' } else { Bad 'WLAN in der Liste' }

Write-Host '3. DHCP-Adapter: setzen und zuruecksetzen'
Reset-Fake 'Enabled' @(@{ IP = '192.168.1.50'; Prefix = 24 }) @('192.168.1.1') @{ A = @{ IP = '192.168.1.50'; Prefix = 24 }; G = '192.168.1.1' }
$vorher = Show
$r = Enable-StaticIp $cfg
if ($r -eq 'gesetzt' -and (Show) -eq 'Dhcp=Disabled Addr=192.168.10.10/24 GW=') { Ok "gesetzt: $(Show)" } else { Bad "nach Setzen: $r $(Show)" }
if (Test-NetBackupExists) { Ok 'Sicherung liegt vor' } else { Bad 'keine Sicherung' }
$saved = Get-Content $script:NetStatePath -Raw | ConvertFrom-Json
if ($saved.Dhcp -eq $true -and $saved.Mac -eq '00-11-22-33-44-55') { Ok 'Sicherung: DHCP + MAC' } else { Bad 'Sicherungsinhalt' }
if (Restore-NetState) { Ok 'wiederhergestellt' } else { Bad 'Restore meldet nichts' }
if ((Show) -eq $vorher) { Ok "wie vorher: $(Show)" } else { Bad "nach Restore: $(Show), vorher: $vorher" }
if (-not (Test-NetBackupExists)) { Ok 'Sicherung geloescht' } else { Bad 'Sicherung noch da' }

Write-Host '4. Fester Adapter mit 2 Adressen + Gateway'
Reset-Fake 'Disabled' @(@{ IP = '10.0.0.5'; Prefix = 24 }, @{ IP = '10.0.1.5'; Prefix = 16 }) @('10.0.0.1') $null
$vorher = Show
[void](Enable-StaticIp $cfg)
if ((Show) -eq 'Dhcp=Disabled Addr=192.168.10.10/24 GW=') { Ok "gesetzt: $(Show)" } else { Bad (Show) }
[void](Restore-NetState)
if ((Show) -eq $vorher) { Ok "wie vorher: $(Show)" } else { Bad "nach Restore: $(Show), vorher: $vorher" }

Write-Host '5. Adresse schon vorhanden'
Reset-Fake 'Disabled' @(@{ IP = '192.168.10.10'; Prefix = 24 }) @() $null
$r = Enable-StaticIp $cfg
if ($r -eq 'unveraendert' -and -not (Test-NetBackupExists) -and $Fake.Calls.Count -eq 0) { Ok 'nichts geaendert, keine Sicherung' } else { Bad "$r Calls=$($Fake.Calls -join ';')" }

Write-Host '6. Absturzrest blockiert neues Setzen'
Reset-Fake 'Enabled' @(@{ IP = '192.168.1.50'; Prefix = 24 }) @('192.168.1.1') @{ A = @{ IP = '192.168.1.50'; Prefix = 24 }; G = '192.168.1.1' }
[void](Enable-StaticIp $cfg)          # simuliert: Programm stuerzt danach ab, Sicherung bleibt
try { [void](Enable-StaticIp $cfg); Bad 'zweites Setzen nicht blockiert' } catch { Ok "blockiert: $($_.Exception.Message)" }
[void](Restore-NetState)              # das macht die GUI beim naechsten Start
if ((Show) -like 'Dhcp=Enabled Addr=192.168.1.50/24*') { Ok "nach Neustart wiederhergestellt: $(Show)" } else { Bad (Show) }

Write-Host '7. Adresskonflikt im Netz'
Reset-Fake 'Enabled' @(@{ IP = '192.168.1.50'; Prefix = 24 }) @('192.168.1.1') @{ A = @{ IP = '192.168.1.50'; Prefix = 24 }; G = '192.168.1.1' }
$Fake.DupIP = '192.168.10.10'
try { [void](Enable-StaticIp $cfg); Bad 'Konflikt nicht erkannt' } catch { if ($_.Exception.Message -like '*vergeben*wiederhergestellt*') { Ok $_.Exception.Message } else { Bad $_.Exception.Message } }
if ((Show) -like 'Dhcp=Enabled Addr=192.168.1.50/24*' -and -not (Test-NetBackupExists)) { Ok "zurueckgesetzt: $(Show)" } else { Bad (Show) }

Write-Host '8. Reihenfolge der Schritte'
Reset-Fake 'Enabled' @(@{ IP = '192.168.1.50'; Prefix = 24 }) @('192.168.1.1') $null
[void](Enable-StaticIp $cfg)
$seq = $Fake.Calls -join ' | '
if ($seq -eq 'Dhcp=Disabled | Del 192.168.1.50 | DelGW | Add 192.168.10.10/24 gw=') { Ok $seq } else { Bad $seq }
Remove-Item $script:NetStatePath -Force

Write-Host '9. Ungueltige Eingabe'
$c2 = Get-DefaultConfig; $c2.FesteIPAdapter = 'Ethernet'; $c2.FesteIPAdresse = '192.168.10.255'
try { [void](Enable-StaticIp $c2); Bad 'nicht abgefangen' } catch { Ok $_.Exception.Message }

Remove-Item $tmpRoot -Recurse -Force
if ($fail) { Write-Host "$fail Fehler" -ForegroundColor Red; exit 1 } else { Write-Host 'Alle Tests bestanden' -ForegroundColor Green }
