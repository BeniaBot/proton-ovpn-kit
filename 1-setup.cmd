@echo off
if exist "%~dp0bin\common.ps1" goto :kit_ok
rem Run from inside the zip: Windows copied only this file to a temp folder. Say so in Hebrew.
powershell -NoProfile -WindowStyle Hidden -Command "(New-Object -ComObject WScript.Shell).Popup([regex]::Unescape('\u05E6\u05E8\u05D9\u05DA \u05E7\u05D5\u05D3\u05DD \u05DC\u05D7\u05DC\u05E5 \u05D0\u05EA \u05E7\u05D5\u05D1\u05E5 \u05D4-zip.\n\n\u05DC\u05D7\u05D9\u05E6\u05D4 \u05D9\u05DE\u05E0\u05D9\u05EA \u05E2\u05DC \u05E7\u05D5\u05D1\u05E5 \u05D4-zip \u2190 \u0022\u05D7\u05DC\u05E5 \u05D4\u05DB\u05D5\u05DC\u0022 (Extract All),\n\u05D5\u05D0\u05D6 \u05DC\u05D4\u05E4\u05E2\u05D9\u05DC \u05D0\u05EA \u05D4\u05E7\u05D1\u05E6\u05D9\u05DD \u05DE\u05EA\u05D5\u05DA \u05D4\u05EA\u05D9\u05E7\u05D9\u05D9\u05D4 \u05E9\u05E0\u05D5\u05E6\u05E8\u05D4.'), 0, 'Proton VPN', 4096 + 48 + 1048576 + 524288) | Out-Null"
exit /b
:kit_ok
rem One-time setup: saves your Proton OpenVPN username/password (encrypted).
rem start: this window closes at once; the setup shows its own messages.
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0bin\setup.ps1"
