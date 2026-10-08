# Connects through the bundled OpenVPN. Runs elevated (2-connect.cmd asks for it).
# Credentials go to OpenVPN over its local management port, never to a file.

. (Join-Path $PSScriptRoot 'common.ps1')
$Host.UI.RawUI.WindowTitle = 'Proton VPN - do not close while working'
# Every run leaves a record (connect-last.log, and openvpn-last.log from OpenVPN itself),
# and an unexpected error shows a message instead of the window just vanishing.
try { Start-Transcript -Path (Join-Path $Bin 'connect-last.log') -Force | Out-Null } catch { }
$logLines = New-Object Collections.Generic.List[string]
function Save-OpenVpnLog {
    # OpenVPN echoes the username in its log; keep it out of files people may send around
    $logLines | Where-Object { $_ -notmatch 'username "Auth"' } | Set-Content (Join-Path $Bin 'openvpn-last.log') -Encoding UTF8
}
trap {
    Write-Host "UNEXPECTED ERROR: $_"
    Write-Host $_.ScriptStackTrace
    Save-OpenVpnLog
    Restore-Ipv6
    Show-Msg ("שגיאה לא צפויה:`n$_`n`nפרטים נשמרו בקבצים connect-last.log ו-openvpn-last.log בתיקייה bin.") 'Error' | Out-Null
    exit 1
}

function Fail([string]$Text) {
    Restore-Ipv6
    Save-OpenVpnLog
    $Text += "`n`n(פרטים טכניים נשמרו בתיקייה bin, בקבצים connect-last.log ו-openvpn-last.log)"
    Show-Msg $Text 'Error' | Out-Null
    exit 1
}

if (-not (Test-Path $CredFile)) { Show-Msg "צריך קודם להריץ פעם אחת את 1-setup.cmd" 'Warning' | Out-Null; exit 1 }
if (Test-VpnRunning) { Show-Msg "ה-VPN כבר מחובר." | Out-Null; exit 0 }

# The Proton app and this kit share the same network adapter; only one can use it.
Get-Process ProtonVPN.Client -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# Network adapter (TAP). Already there if the Proton app was ever installed.
if (-not (Get-NetAdapter -IncludeHidden | Where-Object InterfaceDescription -like 'TAP-ProtonVPN*')) {
    Write-Host 'Installing the VPN network adapter (one time)...'
    Show-Msg ("בפעם הראשונה צריך להתקין רכיב רשת של Proton.`n`n" +
        "אם ווינדוס שואל אם להתקין תוכנת התקן של Proton AG - לחצו 'התקן'.") | Out-Null
    & (Join-Path $Bin 'tap\tapinstall.exe') install (Join-Path $Bin 'tap\OemVista.inf') tapprotonvpn | Out-Host
    Start-Sleep -Seconds 2
    if (-not (Get-NetAdapter -IncludeHidden | Where-Object InterfaceDescription -like 'TAP-ProtonVPN*')) {
        Fail "התקנת רכיב הרשת לא הצליחה. נסו שוב, ואם זה חוזר - הפעילו מחדש את המחשב ונסו שוב."
    }
}

try {
    $j = Get-Content $CredFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $toPlain = { param($s) $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $s))
                 try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) } }
    $user = & $toPlain $j.u
    $pass = & $toPlain $j.p
} catch {
    Show-Msg "לא הצלחתי לקרוא את פרטי הכניסה השמורים.`nהריצו שוב את 1-setup.cmd" 'Error' | Out-Null
    exit 1
}

Disable-Ipv6

Write-Host 'Connecting... (this window must stay open while you work)'
Write-Host ''
$MgmtPort = Find-FreePort
Set-Content $PortFile $MgmtPort -Encoding ASCII
$ovpnArgs = @('--config', $Config, '--windows-driver', 'tap-windows6',
          '--management', '127.0.0.1', "$MgmtPort", '--management-hold', '--management-query-passwords',
          '--auth-retry', 'none', '--auth-nocache', '--verb', '3')
$proc = Start-Process $OpenVpn -ArgumentList $ovpnArgs -WorkingDirectory $Bin -NoNewWindow -PassThru

# Talk to OpenVPN's management port until the tunnel is up.
$client = $null
for ($i = 0; $i -lt 40 -and -not $client -and -not $proc.HasExited; $i++) {
    Start-Sleep -Milliseconds 250
    try { $client = New-Object Net.Sockets.TcpClient('127.0.0.1', $MgmtPort) } catch { }
}
if (-not $client) { Fail "תוכנת ה-VPN לא עלתה. נסו שוב." }

$stream = $client.GetStream()
$writer = New-Object IO.StreamWriter($stream); $writer.NewLine = "`n"; $writer.AutoFlush = $true
$quote = { param($v) '"' + (($v -replace '\\', '\\') -replace '"', '\"') + '"' }
# One command at a time, each only after OpenVPN answered the previous one (SUCCESS/ERROR).
# Sent in a burst, OpenVPN on Windows sometimes ran the first command twice and dropped
# the rest (e.g. the password), and then waited forever.
$queue = New-Object Collections.Generic.Queue[string]
'state on', 'log on', 'hold release' | ForEach-Object { $queue.Enqueue($_) }
$ready = $false; $waiting = $false
function Send-Next {
    if ($script:ready -and -not $script:waiting -and $queue.Count) { $writer.WriteLine($queue.Dequeue()); $script:waiting = $true }
}

$result = 'timeout'; $buf = ''; $bytes = New-Object byte[] 4096
$deadline = (Get-Date).AddSeconds(150)
while ((Get-Date) -lt $deadline -and $result -eq 'timeout') {
    if (-not $stream.DataAvailable) {
        # read whatever OpenVPN said on its way out before calling it an exit
        if ($proc.HasExited) { Start-Sleep -Milliseconds 300; if (-not $stream.DataAvailable) { $result = 'exited'; break } }
        else { Start-Sleep -Milliseconds 200 }
        continue
    }
    $n = $stream.Read($bytes, 0, $bytes.Length)
    if ($n -le 0) { $result = 'exited'; break }
    $buf += [Text.Encoding]::UTF8.GetString($bytes, 0, $n)
    while (($k = $buf.IndexOf("`n")) -ge 0) {
        $line = $buf.Substring(0, $k).TrimEnd("`r"); $buf = $buf.Substring($k + 1)
        if ($line -like '>LOG:*' -or $line -like '>STATE:*') { $logLines.Add($line) }
        if ($line -like '>INFO:*' -or $line -like '>HOLD:*') { $ready = $true }
        elseif ($line -like 'SUCCESS:*' -or $line -like 'ERROR:*') { $waiting = $false }
        elseif ($line -like ">PASSWORD:Need 'Auth'*") {
            $queue.Enqueue('username "Auth" ' + (& $quote $user))
            $queue.Enqueue('password "Auth" ' + (& $quote $pass))
        }
        elseif ($line -like '>PASSWORD:Verification Failed*' -or $line -match '^>STATE:\d+,EXITING,auth-failure') { $result = 'auth'; break }
        elseif ($line -match '^>STATE:\d+,CONNECTED,SUCCESS') { $result = 'ok'; break }
        Send-Next
    }
}$user = $null; $pass = $null
$client.Close()
Save-OpenVpnLog

switch ($result) {
    'auth' {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Fail ("Proton דחה את שם המשתמש או הסיסמה.`n`n" +
            "הריצו שוב את 1-setup.cmd והעתיקו את הפרטים מחדש.`n" +
            "(אלה הפרטים מעמוד OpenVPN - לא הסיסמה הרגילה של החשבון.)")
    }
    'timeout' {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Fail "החיבור לא הצליח תוך שתי דקות וחצי. בדקו שיש אינטרנט ונסו שוב."
    }
    'exited' {
        Fail "תוכנת ה-VPN נסגרה לפני שהתחברה. נסו שוב."
    }
}

Write-Host ''
Write-Host '=== CONNECTED. Keep this window open (you may minimize it). To disconnect: 3-disconnect.cmd ==='
Write-Host ''
Show-Msg ("מחוברים ל-VPN.`n`n" +
    "החלון השחור צריך להישאר פתוח כל זמן העבודה - אפשר למזער אותו.`n" +
    "כדי להתנתק: לחיצה כפולה על 3-disconnect.cmd") | Out-Null

$proc.WaitForExit()
Remove-Item $PortFile -Force -ErrorAction SilentlyContinue
Restore-Ipv6
Write-Host 'Disconnected.'
Start-Sleep -Seconds 3
