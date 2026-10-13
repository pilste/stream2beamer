<#
  Statische Pruefung der Oberflaeche (WinForms laeuft nicht unter Linux):
  - Parser fehlerfrei
  - jeder aufgerufene Befehl ist entweder in Gui.ps1/Common.ps1 definiert,
    ein vorhandener Befehl oder ein bekannter Windows-Befehl
  - jede in Gui.ps1 verwendete $script:-Variable wird irgendwo gesetzt
  Aufruf: pwsh -NoProfile -File tests/test_gui_static.ps1
#>
$repo = Split-Path -Parent $PSScriptRoot
$app = Join-Path $repo 'pc/stream2beamer/app'
$fail = 0
$defined = @{}
$asts = @{}
foreach ($f in 'Common.ps1', 'Gui.ps1', 'Konsole.ps1') {
    $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $app $f), [ref]$null, [ref]$e)
    if ($e) { Write-Host "  FEHLER Parser $f : $($e[0])"; $fail++ }
    $asts[$f] = $ast
    $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $defined[$_.Name] = $true }
}
$windowsOnly = 'Get-NetAdapter','Get-NetIPAddress','Get-NetIPInterface','Get-NetRoute','Set-NetIPInterface','New-NetIPAddress',
  'Remove-NetIPAddress','Remove-NetRoute','Get-NetFirewallRule','New-NetFirewallRule','Remove-NetFirewallRule','Unblock-File','explorer.exe','powershell','tar.exe'
foreach ($f in 'Gui.ps1', 'Konsole.ps1') {
    $cmds = $asts[$f].FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique
    foreach ($c in $cmds) {
        if ($defined[$c] -or $windowsOnly -contains $c -or (Get-Command $c -ErrorAction SilentlyContinue)) { continue }
        Write-Host "  FEHLER $f ruft unbekannten Befehl: $c"; $fail++
    }
    Write-Host "  OK   $f : $($cmds.Count) Befehle geprueft"
}
# $script:-Variablen: gelesen aber nie gesetzt?
$src = (Get-Content (Join-Path $app 'Gui.ps1') -Raw) + (Get-Content (Join-Path $app 'Common.ps1') -Raw)
$used = [regex]::Matches($src, '\$script:(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
foreach ($v in $used) {
    if ($src -notmatch ('\$script:' + $v + '\s*=[^=]')) { Write-Host "  FEHLER `$script:$v wird nie gesetzt"; $fail++ }
}
Write-Host "  OK   $($used.Count) Skript-Variablen geprueft"
if ($fail) { Write-Host "$fail Fehler"; exit 1 } else { Write-Host 'Alle Tests bestanden' }
