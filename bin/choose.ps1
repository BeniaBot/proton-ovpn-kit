# Country window (4-choose-country.cmd). Saves the choice for 2-connect, and offers to
# connect now. If the VPN is already up, the status window switches over by itself
# (no new admin prompt). Runs as the normal user.

. (Join-Path $PSScriptRoot 'common.ps1')

$countries = @(Get-Countries)
$chosen = Get-ChosenCountry
$running = Test-VpnRunning
$connectedCode = if ($running -and (Test-Path $ConnectedFile)) { (Get-Content $ConnectedFile -Raw).Trim() } else { '' }
$connected = $countries | Where-Object Code -eq $connectedCode | Select-Object -First 1
$current = if ($connected) { $connected } else { $chosen }
$status = if ($connected) { "מחוברים עכשיו: $($connected.Name)" } elseif ($running) { 'ה-VPN מתחבר עכשיו.' } else { "נבחרה עכשיו: $($chosen.Name)" }

$picked = Show-CountryPicker $countries $current.Code $status
if (-not $picked) { exit 0 }
$new = $countries | Where-Object Code -eq $picked | Select-Object -First 1
Set-Content $CountryFile $new.Code -Encoding ASCII

if (Test-VpnRunning) {
    if (-not ($connected -and $connected.Code -eq $new.Code)) { Request-VpnSwitch }   # the status window takes it from here
    exit 0
}
if ((Show-Msg "נבחרה $($new.Name).`n`nלהתחבר עכשיו?" 'Question' 'YesNo') -eq 'Yes') { Start-KitButton '2-connect.cmd' }
