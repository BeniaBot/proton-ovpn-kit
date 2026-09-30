# Disconnects cleanly through OpenVPN's management port and switches IPv6 back on.
# Also repairs IPv6 if the black window was closed with X instead.

. (Join-Path $PSScriptRoot 'common.ps1')

if (Test-VpnRunning) {
    Send-VpnStop | Out-Null
    for ($i = 0; $i -lt 20 -and (Test-VpnRunning); $i++) { Start-Sleep -Milliseconds 500 }
    Restore-Ipv6
    Show-Msg "ה-VPN נותק." | Out-Null
} else {
    Restore-Ipv6
    Show-Msg "ה-VPN לא היה מחובר. הגדרות הרשת הוחזרו למצב הרגיל." | Out-Null
}
