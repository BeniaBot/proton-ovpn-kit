# Disconnects: asks the status window to stop OpenVPN (it is the only one OpenVPN
# listens to), and puts the network back: IPv6 on, no routes left on the VPN adapter.
# Also repairs all that when the window or the computer went down mid-connection.

. (Join-Path $PSScriptRoot 'common.ps1')

if (Test-VpnRunning) {
    if (-not (Request-VpnStop)) {
        # the status window is gone or stuck; this script runs elevated, so stop it directly
        Get-VpnProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
    }
    Remove-Item $StopFile, $ConnectedFile -Force -ErrorAction SilentlyContinue
    Clear-TunnelRoutes   # leftovers when OpenVPN was killed rather than stopped
    Restore-Ipv6
    Show-Msg "ה-VPN נותק." 'Success' | Out-Null
} else {
    Remove-Item $StopFile, $ConnectedFile -Force -ErrorAction SilentlyContinue
    Clear-TunnelRoutes
    Restore-Ipv6
    Show-Msg "ה-VPN לא היה מחובר. הגדרות הרשת הוחזרו למצב הרגיל." | Out-Null
}
