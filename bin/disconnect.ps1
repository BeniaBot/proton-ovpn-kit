# Disconnects: asks the connect window to stop OpenVPN (it is the only one OpenVPN
# listens to), and switches IPv6 back on. Also repairs IPv6 if the black window was
# closed with X instead.

. (Join-Path $PSScriptRoot 'common.ps1')

if (Test-VpnRunning) {
    if (-not (Request-VpnStop)) {
        # the connect window is gone or stuck; this script runs elevated, so stop it directly
        Get-VpnProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
    }
    Remove-Item $StopFile, $ConnectedFile -Force -ErrorAction SilentlyContinue
    Restore-Ipv6
    Show-Msg "ה-VPN נותק." | Out-Null
} else {
    Remove-Item $StopFile, $ConnectedFile -Force -ErrorAction SilentlyContinue
    Restore-Ipv6
    Show-Msg "ה-VPN לא היה מחובר. הגדרות הרשת הוחזרו למצב הרגיל." | Out-Null
}
