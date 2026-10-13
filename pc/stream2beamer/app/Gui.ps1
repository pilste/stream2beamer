<#
  stream2beamer - Bedienoberflaeche (Windows PowerShell 5.1, WinForms)
  Zeigt das Programmbild des ATEM per SRT im Vollbild auf dem Beamer-Bildschirm.
  Start ueber stream2beamer.bat.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace Win -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][Win.Dpi]::SetProcessDPIAware()           # echte Pixel fuer die Bildschirmkoordinaten
[System.Windows.Forms.Application]::EnableVisualStyles()

# aus dem Internet geladene Dateien entsperren (sonst Sicherheitsabfragen beim Start von mpv/ffplay)
Get-ChildItem $script:AppRoot -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

$cfg = Get-Config
$script:GuiPath = $PSCommandPath   # fuer Neustart mit Adminrechten

# Feste IP oder Absturzrest brauchen Adminrechte: einmal mit Windows-Abfrage neu starten
$script:ElevateDeclined = $false
if (($cfg.FesteIP -or (Test-NetBackupExists)) -and -not (Test-IsAdmin)) {
    try {
        Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$script:GuiPath`"")
        exit
    } catch { $script:ElevateDeclined = $true }
}

$script:Running   = $false
$script:Proc      = $null
$script:ProcStart = $null
$script:NextStart = [datetime]::MinValue
$script:TestProc  = $null

# ---------- Fenster ----------
# Eigene Skalierung: Alle Masse unten sind fuer 100 % (96 DPI) angegeben und werden mit dem
# Skalierungsfaktor des Bildschirms multipliziert. Die Schrift (in Punkt) skaliert Windows selbst.
$gfx = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:K = $gfx.DpiX / 96.0
$gfx.Dispose()
function S([double]$v) { [int][math]::Round($v * $script:K) }
function P($x, $y) { New-Object Drawing.Point((S $x), (S $y)) }
function Sz($w, $h) { New-Object Drawing.Size((S $w), (S $h)) }

$form = New-Object Windows.Forms.Form
$form.Text = 'stream2beamer'
$form.AutoScaleMode = 'None'
$form.Font = New-Object Drawing.Font('Segoe UI', 9)
$form.ClientSize = Sz 680 680
$form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'

# Spalten und Zeilen (Werte bei 100 %)
$X1 = 14; $X2 = 200; $W2 = 340; $X3 = 552; $W3 = 114; $RH = 26
function Add-Ctl($c, $x, $y, $w, $h) { $c.Location = P $x $y; $c.Size = Sz $w $h; $form.Controls.Add($c); $c }
function Add-Label($text, $x, $y, $w = 180) {
    $l = New-Object Windows.Forms.Label; $l.Text = $text; $l.TextAlign = 'MiddleLeft'; $l.AutoEllipsis = $true
    Add-Ctl $l $x $y $w $RH
}
function Add-Button($text, $x, $y, $w = 150, $h = 32) {
    $b = New-Object Windows.Forms.Button; $b.Text = $text; Add-Ctl $b $x $y $w $h
}
function Add-Num($val, $min, $max, $x, $y, $w = 90) {
    $n = New-Object Windows.Forms.NumericUpDown; $n.Minimum = $min; $n.Maximum = $max; $n.Value = $val
    Add-Ctl $n $x ($y + 2) $w 24
}
function Add-Combo($x, $y, $w) {
    $c = New-Object Windows.Forms.ComboBox; $c.DropDownStyle = 'DropDownList'; Add-Ctl $c $x ($y + 2) $w 24
}

# Zeile 1-2: IP und Server-Adresse
Add-Label 'Laptop-IP (für den ATEM):' $X1 12 | Out-Null
$cbIp = Add-Combo $X2 12 $W2
$btnRefresh = Add-Button 'Aktualisieren' $X3 11 $W3 28
Add-Label 'ATEM-Server:' $X1 46 | Out-Null
$tbUrl = Add-Ctl (New-Object Windows.Forms.TextBox) $X2 48 $W2 24
$tbUrl.ReadOnly = $true
$btnCopy = Add-Button 'Kopieren' $X3 45 $W3 28

# Zeile 3-7: Einstellungen
Add-Label 'Player:' $X1 88 | Out-Null
$cbPlayer = Add-Combo $X2 88 120
[void]$cbPlayer.Items.AddRange(@('mpv', 'ffplay'))
$cbPlayer.SelectedItem = $cfg.Player
if ($null -eq $cbPlayer.SelectedItem) { $cbPlayer.SelectedIndex = 0 }

Add-Label 'Beamer-Bildschirm:' $X1 120 | Out-Null
$cbScreen = Add-Combo $X2 120 466

Add-Label 'SRT-Port:' $X1 152 | Out-Null
$nPort = Add-Num $cfg.Port 1024 65535 $X2 152
Add-Label 'Puffer Laptop (ms):' $X1 184 | Out-Null
$nLat = Add-Num $cfg.LatenzMs 20 2000 $X2 184
Add-Label 'Latenz ATEM (ms):' $X1 216 | Out-Null
$nAtemLat = Add-Num $cfg.AtemLatenzMs 20 2000 $X2 216
$chkTon = Add-Ctl (New-Object Windows.Forms.CheckBox) 320 184 346 $RH
$chkTon.Text = 'Ton abspielen (kostet Verzögerung)'; $chkTon.Checked = $cfg.Ton

# Zeile 8-9: feste IP
$chkFest = Add-Ctl (New-Object Windows.Forms.CheckBox) $X1 252 182 $RH
$chkFest.Text = 'Feste IP verwenden:'; $chkFest.Checked = $cfg.FesteIP
$tbFestIp = Add-Ctl (New-Object Windows.Forms.TextBox) $X2 254 130 24
$tbFestIp.Text = $cfg.FesteIPAdresse
Add-Label '/' 336 252 14 | Out-Null
$nFestPre = Add-Num $cfg.FesteIPPraefix 8 30 352 252 60
Add-Label '24 = Maske 255.255.255.0' 420 252 246 | Out-Null
Add-Label 'Adapter für feste IP:' $X1 282 | Out-Null
$cbAdapter = Add-Combo $X2 282 466
$lblNetz = Add-Label '' $X1 312 652
$lblNetz.ForeColor = [Drawing.Color]::DimGray

# Hauptknoepfe
$btnStart = Add-Button 'Start' $X1 352 318 44
$btnStart.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$btnStop  = Add-Button 'Stop' 348 352 318 44
$btnStop.Font = $btnStart.Font; $btnStop.Enabled = $false

# Werkzeuge
$btnXml  = Add-Button 'ATEM-Dateien erzeugen' $X1 406 159
$btnFw   = Add-Button 'Firewall freigeben' 178 406 159
$btnFF   = Add-Button 'FFmpeg nachladen' 343 406 159
$btnTest = Add-Button 'Testbild senden' 507 406 159

$lblStatus = Add-Label '' $X1 444 652
$lblStatus.ForeColor = [Drawing.Color]::DimGray

$tbLog = Add-Ctl (New-Object Windows.Forms.TextBox) $X1 474 652 192
$tbLog.Multiline = $true; $tbLog.ReadOnly = $true; $tbLog.ScrollBars = 'Vertical'
$tbLog.Font = New-Object Drawing.Font('Consolas', 9)

function Log([string]$t) {
    $tbLog.AppendText(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $t) + "`r`n")
}

# ---------- Logik ----------
function Read-UiConfig {
    $cfg.Player       = [string]$cbPlayer.SelectedItem
    $cfg.Port         = [int]$nPort.Value
    $cfg.LatenzMs     = [int]$nLat.Value
    $cfg.AtemLatenzMs = [int]$nAtemLat.Value
    $cfg.Ton          = $chkTon.Checked
    $cfg.FesteIP        = $chkFest.Checked
    $cfg.FesteIPAdresse = $tbFestIp.Text.Trim()
    $cfg.FesteIPPraefix = [int]$nFestPre.Value
    $cfg.FesteIPAdapter = if ($cbAdapter.SelectedIndex -le 0 -or $cbAdapter.SelectedIndex -gt $script:AdapterNames.Count) { 'auto' } else { $script:AdapterNames[$cbAdapter.SelectedIndex - 1] }
    $cfg.Monitor      = if ($cbScreen.SelectedIndex -le 0) { 'auto' } else { [string]$cbScreen.SelectedIndex }
    $ip = Get-SelectedIp
    if ($ip) { $cfg.LaptopIP = $ip }
}

$script:IpList = @()
function Get-SelectedIp {
    if ($cbIp.SelectedIndex -ge 0 -and $cbIp.SelectedIndex -lt $script:IpList.Count) { return $script:IpList[$cbIp.SelectedIndex] }
    return $null
}

function Update-Url {
    $ip = Get-SelectedIp
    $tbUrl.Text = if ($ip) { "srt://$($ip):$([int]$nPort.Value)" } else { '(keine IP - Kabel stecken)' }
}

function Fill-Ips {
    $cbIp.Items.Clear(); $script:IpList = @()
    $list = @(Get-LaptopIPs)
    foreach ($i in $list) {
        $suffix = ''
        if ($i.Kabel) { $suffix = '  [Kabel]' }
        if ($i.Apipa) { $suffix = '  [ungültig: feste IP setzen]' }
        if ($i.AtemUsb) { $suffix = '  [ATEM per USB, nicht wählen]' }
        [void]$cbIp.Items.Add("$($i.IP)   $($i.Adapter)$suffix")
        $script:IpList += $i.IP
    }
    $want = if ($cfg.LaptopIP -ne 'auto') { $cfg.LaptopIP } else { Get-BestIP $cfg }
    for ($k = 0; $k -lt $script:IpList.Count; $k++) { if ($script:IpList[$k] -eq $want) { $cbIp.SelectedIndex = $k } }
    if ($cbIp.SelectedIndex -lt 0 -and $cbIp.Items.Count -gt 0) { $cbIp.SelectedIndex = 0 }
    Update-Url
}

function Fill-Screens {
    $cbScreen.Items.Clear()
    [void]$cbScreen.Items.Add('Automatisch (erster Nicht-Hauptbildschirm)')
    $n = 1
    foreach ($s in [Windows.Forms.Screen]::AllScreens) {
        $h = if ($s.Primary) { ' (Hauptbildschirm)' } else { '' }
        [void]$cbScreen.Items.Add(('{0}: {1}x{2}{3}' -f $n, $s.Bounds.Width, $s.Bounds.Height, $h)); $n++
    }
    $idx = 0
    if ($cfg.Monitor -ne 'auto') { $idx = [int]$cfg.Monitor; if ($idx -ge $cbScreen.Items.Count) { $idx = 0 } }
    $cbScreen.SelectedIndex = $idx
}

function Get-TargetScreenIndex {
    $m = if ($cbScreen.SelectedIndex -le 0) { 'auto' } else { $cbScreen.SelectedIndex }
    return (Select-TargetScreen ([Windows.Forms.Screen]::AllScreens) $m)
}

function Get-TargetBounds {
    return ([Windows.Forms.Screen]::AllScreens)[(Get-TargetScreenIndex)].Bounds
}

function Update-Status {
    $fw = if (Test-FirewallRule) { 'Firewall: frei' } else { 'Firewall: NICHT frei (Knopf drücken)' }
    $pl = if (Get-PlayerPath ([string]$cbPlayer.SelectedItem)) { "Player $($cbPlayer.SelectedItem): da" } else { "Player $($cbPlayer.SelectedItem): fehlt" }
    $ff = if (Get-FFmpegPath) { 'FFmpeg: da' } else { 'FFmpeg: nicht geladen (nur für ffplay/Testbild nötig)' }
    $lblStatus.Text = "$fw   |   $pl   |   $ff"
    $btnTest.Enabled = [bool](Get-FFmpegPath)
}

function Start-PlayerProcess {
    $player = [string]$cbPlayer.SelectedItem
    $exe = Get-PlayerPath $player
    if (-not $exe) { throw "Player $player fehlt. Bei ffplay zuerst 'FFmpeg nachladen'." }
    $b = Get-TargetBounds
    $pArgs = Get-PlayerArgs $player $cfg $b (Get-TargetScreenIndex)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = Join-WinArgs $pArgs
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = Split-Path $exe
    $script:Proc = [Diagnostics.Process]::Start($psi)
    $script:ProcStart = Get-Date
}

$timer = New-Object Windows.Forms.Timer; $timer.Interval = 500
$timer.Add_Tick({
    try {
        if (-not $script:Running) { return }
        if ($script:Proc -and -not $script:Proc.HasExited) { return }
        if ($script:Proc -and $script:Proc.HasExited) {
            $dauer = ((Get-Date) - $script:ProcStart).TotalSeconds
            if ($dauer -ge 3) { Log ('Stream beendet nach {0:N0} s. Warte erneut ...' -f $dauer) }
            $script:NextStart = if ($dauer -lt 2) { (Get-Date).AddSeconds(2) } else { (Get-Date).AddMilliseconds(300) }
            $script:Proc = $null
        }
        if ((Get-Date) -ge $script:NextStart) { Start-PlayerProcess }
    } catch {
        Log "FEHLER: $($_.Exception.Message)"; Stop-Beamer
    }
})

function Stop-Beamer {
    $script:Running = $false
    if ($script:Proc -and -not $script:Proc.HasExited) { try { $script:Proc.Kill() } catch {} }
    $script:Proc = $null
    $btnStart.Enabled = $true; $btnStop.Enabled = $false
    foreach ($c in @($cbPlayer, $cbScreen, $nPort, $nLat, $chkTon)) { $c.Enabled = $true }
    Log 'Gestoppt.'
}

# ---------- feste IP ----------
$script:NetApplied = $false
$script:Muting     = $false
$script:InitDone   = $false
$script:Relaunching = $false

function Set-ChkSilently([bool]$v) { $script:Muting = $true; $chkFest.Checked = $v; $script:Muting = $false }

$script:AdapterNames = @()
function Fill-Adapters {
    $script:Muting = $true
    $cbAdapter.Items.Clear(); $script:AdapterNames = @()
    [void]$cbAdapter.Items.Add('Automatisch (bevorzugt Adapter ohne Router-Netz)')
    foreach ($e in (Get-EthernetAdapters)) {
        [void]$cbAdapter.Items.Add((Get-AdapterText $e)); $script:AdapterNames += $e.Name
    }
    $idx = 0
    for ($k = 0; $k -lt $script:AdapterNames.Count; $k++) { if ($script:AdapterNames[$k] -eq $cfg.FesteIPAdapter) { $idx = $k + 1 } }
    $cbAdapter.SelectedIndex = $idx
    $script:Muting = $false
}

function Update-NetLabel {
    try {
        $ad = Get-CableAdapter $cfg
        $st = Get-NetState $ad
        $txt = "Feste IP würde auf '$($ad.Name)' gesetzt. Jetzt: $(Get-NetStateText $st)"
        if ($script:NetApplied) { $txt = "Feste IP aktiv auf '$($ad.Name)': $(Get-NetStateText $st). Wird beim Schließen zurückgesetzt." }
        $lblNetz.Text = $txt
    } catch { $lblNetz.Text = "Netzwerk: $($_.Exception.Message)" }
    $tbFestIp.Enabled = -not $script:NetApplied; $nFestPre.Enabled = -not $script:NetApplied; $cbAdapter.Enabled = -not $script:NetApplied
}

function Apply-Fest {
    Read-UiConfig
    if (-not (Test-IPv4 $cfg.FesteIPAdresse $cfg.FesteIPPraefix)) {
        Log "Ungültige feste IP: $($cfg.FesteIPAdresse)/$($cfg.FesteIPPraefix)"; Set-ChkSilently $false; return
    }
    if (-not (Test-IsAdmin)) {
        Log 'Feste IP braucht Adminrechte. Programm startet mit Windows-Abfrage neu ...'
        Save-Config $cfg
        try {
            Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$script:GuiPath`"")
            $script:Relaunching = $true; $form.Close()
        } catch { Log 'Adminrechte abgelehnt, feste IP bleibt aus.'; Set-ChkSilently $false; $cfg.FesteIP = $false; Save-Config $cfg }
        return
    }
    try {
        $ad = Get-CableAdapter $cfg
        $vorher = Get-NetStateText (Get-NetState $ad)
        $r = Enable-StaticIp $cfg
        if ($r -eq 'gesetzt') {
            $script:NetApplied = $true
            Log "Feste IP $($cfg.FesteIPAdresse)/$($cfg.FesteIPPraefix) auf '$($ad.Name)' gesetzt. Vorher: $vorher (gesichert)."
        } else {
            Log "'$($ad.Name)' hat $($cfg.FesteIPAdresse) bereits, nichts geändert."
        }
        $cfg.LaptopIP = $cfg.FesteIPAdresse; Save-Config $cfg
    } catch { Log "FEHLER feste IP: $($_.Exception.Message)"; Set-ChkSilently $false }
    Fill-Adapters; Update-NetLabel; Fill-Ips
}

function Undo-Fest {
    try {
        if (Restore-NetState) { Log 'Vorherige Netzwerkeinstellung wiederhergestellt.' }
    } catch { Log "FEHLER beim Zurücksetzen: $($_.Exception.Message)" }
    $script:NetApplied = $false; $cfg.LaptopIP = 'auto'
    Fill-Adapters; Update-NetLabel; Fill-Ips
}

# ---------- Ereignisse ----------
$cbAdapter.Add_SelectedIndexChanged({
    if ($script:Muting -or -not $script:InitDone) { return }
    Read-UiConfig; Save-Config $cfg; Update-NetLabel
})
$chkFest.Add_CheckedChanged({
    if ($script:Muting -or -not $script:InitDone) { return }
    if ($chkFest.Checked) { Apply-Fest } else { Undo-Fest }
})
$btnRefresh.Add_Click({ Fill-Ips; Fill-Screens; Fill-Adapters; Update-NetLabel; Update-Status; Log 'IPs und Bildschirme neu eingelesen.' })
$cbIp.Add_SelectedIndexChanged({ Update-Url })
$nPort.Add_ValueChanged({ Update-Url })
$cbPlayer.Add_SelectedIndexChanged({ Update-Status })
$btnCopy.Add_Click({ if ($tbUrl.Text -like 'srt://*') { [Windows.Forms.Clipboard]::SetText($tbUrl.Text); Log "Kopiert: $($tbUrl.Text)" } })

$btnStart.Add_Click({
    try {
        Read-UiConfig; Save-Config $cfg
        if (-not (Get-PlayerPath $cfg.Player)) { throw "Player $($cfg.Player) fehlt. Bei ffplay zuerst 'FFmpeg nachladen'." }
        if (-not (Test-FirewallRule)) { Log 'Achtung: Firewall-Regel fehlt. Ohne Freigabe kommt evtl. nichts an.' }
        $b = Get-TargetBounds
        Log ("Start: {0}, Bildschirm {1}x{2} bei {3},{4}, Port {5}, Puffer {6} ms, Ton {7}" -f `
             $cfg.Player, $b.Width, $b.Height, $b.X, $b.Y, $cfg.Port, $cfg.LatenzMs, $cfg.Ton)
        Log "Warte auf ATEM unter $($tbUrl.Text) ..."
        $script:Running = $true; $script:NextStart = [datetime]::MinValue
        $btnStart.Enabled = $false; $btnStop.Enabled = $true
        foreach ($c in @($cbPlayer, $cbScreen, $nPort, $nLat, $chkTon)) { $c.Enabled = $false }
    } catch { Log "FEHLER: $($_.Exception.Message)" }
})
$btnStop.Add_Click({ Stop-Beamer })

$btnXml.Add_Click({
    try {
        Read-UiConfig; Save-Config $cfg
        $ip = Get-SelectedIp
        if (-not $ip) { throw 'Keine IP ausgewählt.' }
        $dir = Export-AtemFiles $ip $cfg
        Log "ATEM-Dateien erzeugt in $dir"
        Start-Process explorer.exe $dir
    } catch { Log "FEHLER: $($_.Exception.Message)" }
})

$btnFw.Add_Click({
    try {
        Read-UiConfig; Save-Config $cfg
        Log 'Firewall-Regel anlegen (Windows fragt nach Adminrechten) ...'
        if (Set-FirewallRule $cfg) { Log "Firewall: UDP $($cfg.Port) freigegeben (nur lokales Netz)." } else { Log 'Firewall-Regel nicht angelegt.' }
    } catch { Log "FEHLER: $($_.Exception.Message)" }
    Update-Status
})

$btnFF.Add_Click({
    $form.Cursor = 'WaitCursor'; $btnFF.Enabled = $false
    try { Install-FFmpeg { param($t) Log $t; [Windows.Forms.Application]::DoEvents() } }
    catch { Log "FEHLER: $($_.Exception.Message)" }
    finally { $form.Cursor = 'Default'; $btnFF.Enabled = $true; Update-Status }
})

$btnTest.Add_Click({
    try {
        Read-UiConfig
        if ($script:TestProc -and -not $script:TestProc.HasExited) { $script:TestProc.Kill() }
        $script:TestProc = Start-Testbild $cfg
        Log 'Testbild läuft 60 s. Vorher Start drücken, dann erscheint es auf dem Beamer.'
    } catch { Log "FEHLER: $($_.Exception.Message)" }
})

$form.Add_FormClosing({
    $timer.Stop()
    if ($script:NetApplied) {
        try { if (Restore-NetState) { $script:NetApplied = $false } }
        catch { [Windows.Forms.MessageBox]::Show("Netzwerk konnte nicht zurückgesetzt werden:`n$($_.Exception.Message)`n`nBeim nächsten Start versucht stream2beamer es erneut.", 'stream2beamer') | Out-Null }
    }
    if ($script:Proc -and -not $script:Proc.HasExited) { try { $script:Proc.Kill() } catch {} }
    if ($script:TestProc -and -not $script:TestProc.HasExited) { try { $script:TestProc.Kill() } catch {} }
    try { Read-UiConfig; Save-Config $cfg } catch {}
})

# ---------- Start ----------
try {
    Fill-Ips; Fill-Screens; Fill-Adapters; Update-Status
    if (Test-NetBackupExists) {
        if (Test-IsAdmin) {
            [void](Restore-NetState)
            Log 'Programm wurde letztes Mal nicht sauber beendet: vorherige Netzwerkeinstellung wiederhergestellt.'
        } else { Log 'WARNUNG: alte Netzwerk-Sicherung vorhanden, ohne Adminrechte nicht wiederherstellbar.' }
    }
    if ($cfg.FesteIP) {
        if (Test-IsAdmin) { Apply-Fest }
        else { Log 'Feste IP ist eingestellt, aber Adminrechte wurden abgelehnt. Feste IP bleibt aus.'; Set-ChkSilently $false }
    }
    Update-NetLabel
    Log 'Bereit. 1) ATEM-Dateien erzeugen und im ATEM laden  2) Firewall freigeben (einmalig)  3) Start.'
} catch { Log "FEHLER beim Einlesen: $($_.Exception.Message)" }
$script:InitDone = $true
$timer.Start()
[void]$form.ShowDialog()
