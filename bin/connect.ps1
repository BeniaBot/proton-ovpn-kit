# Connects through the bundled OpenVPN. Runs elevated (2-connect.cmd asks for it).
# Credentials go to OpenVPN over its local management port, never to a file.
#
# A small status window replaces the old black console. It shows the country and the
# state, warns when the connection drops (and pops to the front) and when it is back,
# switches country without a new admin prompt, and disconnects cleanly - also when it
# is closed with X. Meanwhile it keeps answering OpenVPN: Proton gives no reconnect
# token, so OpenVPN asks for the password again on every reconnect.
# The window is WPF; where WPF cannot run, a plain WinForms window does the same job.

. (Join-Path $PSScriptRoot 'common.ps1')
# Every run leaves a record (connect-last.log, and openvpn-last.log from OpenVPN itself),
# and an unexpected error shows a message instead of the window just vanishing.
try { Start-Transcript -Path (Join-Path $Bin 'connect-last.log') -Force | Out-Null } catch { }

# All live state in one table, so window events and functions share it without scope tricks.
$S = @{ Country = (Get-ChosenCountry); Log = (New-Object Collections.Generic.List[string]); Phase = 'idle'
        Outcome = $null; Stopping = $null; Next = $null; Done = $false; Bytes = (New-Object byte[] 4096) }

function Save-OpenVpnLog {
    # OpenVPN echoes the username in its log; keep it out of files people may send around
    $S.Log | Where-Object { $_ -notmatch 'username "Auth"' } | Set-Content (Join-Path $Bin 'openvpn-last.log') -Encoding UTF8
}

# Leaves the computer as it was: OpenVPN gone, IPv6 back on, no state files.
function Complete-Vpn {
    if ($S.Client) { try { $S.Client.Close() } catch { } }
    if ($S.Proc -and -not $S.Proc.HasExited) { Stop-Process -Id $S.Proc.Id -Force -ErrorAction SilentlyContinue }
    Save-OpenVpnLog
    Remove-Item $ConnectedFile, $StopFile -Force -ErrorAction SilentlyContinue
    Restore-Ipv6
}

trap {
    Write-Host "UNEXPECTED ERROR: $_"
    Write-Host $_.ScriptStackTrace
    Complete-Vpn
    Show-Msg ("שגיאה לא צפויה:`n$_`n`nפרטים נשמרו בקבצים connect-last.log ו-openvpn-last.log בתיקייה bin.") 'Error' | Out-Null
    exit 1
}

function Fail([string]$Text) {
    Complete-Vpn
    $Text += "`n`n(פרטים טכניים נשמרו בתיקייה bin, בקבצים connect-last.log ו-openvpn-last.log)"
    Show-Msg $Text 'Error' | Out-Null
    exit 1
}

if (-not (Test-Path $CredFile)) { Show-Msg "צריך קודם להריץ פעם אחת את 1-setup.cmd" 'Warning' | Out-Null; exit 1 }
if (Test-VpnRunning) { Show-Msg "ה-VPN כבר מחובר." | Out-Null; exit 0 }
Remove-Item $StopFile, $ConnectedFile -Force -ErrorAction SilentlyContinue   # leftovers of a crashed run

# The slow part (2-3 s of network queries) runs after the window is up, from its first
# tick: measured, doing it first left the screen empty for seconds after the UAC prompt.
function Initialize-Network {
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
            $S.Outcome = 'tap'; return $false
        }
    }
    Disable-Ipv6
    $true
}

# The credentials stay encrypted in memory and are decrypted only when OpenVPN asks.
$toPlain = { param($s) $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $s))
             try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) } }
try {
    $cred = Get-Content $CredFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not (& $toPlain $cred.u) -or -not (& $toPlain $cred.p)) { throw 'empty' }
} catch {
    Show-Msg "לא הצלחתי לקרוא את פרטי הכניסה השמורים.`nהריצו שוב את 1-setup.cmd" 'Error' | Out-Null
    exit 1
}

# ---------------------------------------------------------------- the connection

# Server list for a country: the first address first (the proven one), the rest
# shuffled so users spread out. UDP 1194 is fast and passes most networks; the first
# three servers get it first, then other ports and TCP, then the remaining servers.
function Get-RemoteArgs($Country) {
    $s = @($Country.Servers)
    if ($s.Count -gt 2) { $s = @($s[0]) + @($s[1..($s.Count - 1)] | Get-Random -Count ($s.Count - 1)) }
    $head = @($s | Select-Object -First 3); $tail = @($s | Select-Object -Skip 3)
    $r = @()
    foreach ($ip in $head) { $r += @('--remote', $ip, '1194', 'udp') }
    $r += @('--remote', $s[0], '51820', 'udp', '--remote', $s[0], '80', 'udp')
    foreach ($ip in $head) { $r += @('--remote', $ip, '443', 'tcp') }
    $r += @('--remote', $s[0], '7770', 'tcp')
    foreach ($ip in $tail) { $r += @('--remote', $ip, '1194', 'udp') }
    foreach ($ip in $tail) { $r += @('--remote', $ip, '443', 'tcp') }
    $r
}

function Start-Vpn {
    $c = $S.Country
    Write-Host "$(Get-Date -Format 'HH:mm:ss') Connecting to $($c.Code)..."
    $port = Find-FreePort
    $ovpnArgs = @('--config', $Config, '--windows-driver', 'tap-windows6',
              '--management', '127.0.0.1', "$port", '--management-hold', '--management-query-passwords',
              '--auth-retry', 'none', '--auth-nocache', '--verb', '3',
              '--log', 'openvpn-run.log') + (Get-RemoteArgs $c)   # its own full log, kept even if the management line drops
    # no stale AUTH_FAILED from an earlier run, should this one die before opening its log
    Remove-Item (Join-Path $Bin 'openvpn-run.log') -Force -ErrorAction SilentlyContinue
    $S.Proc = Start-Process $OpenVpn -ArgumentList $ovpnArgs -WorkingDirectory $Bin -NoNewWindow -PassThru
    $client = $null
    for ($i = 0; $i -lt 40 -and -not $client -and -not $S.Proc.HasExited; $i++) {
        Start-Sleep -Milliseconds 250
        try { $client = New-Object Net.Sockets.TcpClient('127.0.0.1', $port) } catch { }
    }
    if (-not $client) { $S.Outcome = 'nostart'; return $false }
    $S.Client = $client; $S.Stream = $client.GetStream()
    $S.Writer = New-Object IO.StreamWriter($S.Stream); $S.Writer.NewLine = "`n"; $S.Writer.AutoFlush = $true
    $S.Queue = New-Object Collections.Generic.Queue[string]
    'state on', 'log on', 'hold release' | ForEach-Object { $S.Queue.Enqueue($_) }
    $S.Ready = $false; $S.Waiting = $false; $S.Buf = ''; $S.ExitSeen = $false
    $limit = if ($env:PROTON_KIT_CONNECT_TIMEOUT) { [int]$env:PROTON_KIT_CONNECT_TIMEOUT } else { 150 }   # shorter only in tests
    $S.Phase = 'connecting'; $S.Deadline = (Get-Date).AddSeconds($limit)
    $S.Stopping = $null; $S.KillAt = $null; $S.Dropped = $false; $S.AuthFailed = $false
    $true
}

# One command at a time, each only after OpenVPN answered the previous one (SUCCESS/ERROR).
# Sent in a burst, OpenVPN on Windows sometimes ran the first command twice and dropped
# the rest (e.g. the password), and then waited forever.
function Send-Next {
    if ($S.Ready -and -not $S.Waiting -and $S.Queue.Count) { $S.Writer.WriteLine($S.Queue.Dequeue()); $S.Waiting = $true }
}

function Request-Stop([string]$Why, $Next = $null) {
    if ($S.Stopping) { return }
    $S.Stopping = $Why; $S.Next = $Next
    Write-Host "$(Get-Date -Format 'HH:mm:ss') Stop requested ($Why)"
    if ($S.Phase -ne 'idle') {
        $S.Queue.Clear(); $S.Queue.Enqueue('signal SIGTERM'); $S.Waiting = $false
        $S.KillAt = (Get-Date).AddSeconds(8)     # in case OpenVPN does not answer
    }
    Set-View $(if ($Why -eq 'switch') { 'switching' } else { 'stopping' })
}

$quote = { param($v) '"' + (($v -replace '\\', '\\') -replace '"', '\"') + '"' }

# One line from OpenVPN. Returns $false when the run is over (wrong credentials).
function Read-VpnLine([string]$line) {
    if ($line -like '>LOG:*' -or $line -like '>STATE:*') {
        $S.Log.Add($line)
        if ($S.Log.Count -gt 4000) { $S.Log.RemoveRange(0, 1000) }   # days-long sessions
    }
    if ($line -like '>INFO:*' -or $line -like '>HOLD:*') { $S.Ready = $true }
    elseif ($line -like 'SUCCESS:*' -or $line -like 'ERROR:*') { $S.Waiting = $false }
    elseif ($line -like ">PASSWORD:Need 'Auth'*") {
        $S.Queue.Enqueue('username "Auth" ' + (& $quote (& $toPlain $cred.u)))
        $S.Queue.Enqueue('password "Auth" ' + (& $quote (& $toPlain $cred.p)))
    }
    elseif ($line -like '>PASSWORD:Verification Failed*' -or $line -match '^>STATE:\d+,EXITING,auth-failure') {
        $S.AuthFailed = $true
        if ($S.Phase -eq 'connecting' -and -not $S.Stopping) {
            $S.Outcome = 'auth'; Stop-Process -Id $S.Proc.Id -Force -ErrorAction SilentlyContinue
            return $false
        }
    }
    elseif ($line -match '^>STATE:\d+,CONNECTED,SUCCESS') {
        if ($S.Phase -eq 'connecting') {
            $S.Phase = 'up'; $S.UpSince = Get-Date
            Set-Content $ConnectedFile $S.Country.Code -Encoding ASCII
            Save-OpenVpnLog
            Write-Host "$(Get-Date -Format 'HH:mm:ss') CONNECTED ($($S.Country.Code))"
            Set-View 'connected'
        } elseif ($S.Dropped) {
            $S.Dropped = $false
            Write-Host "$(Get-Date -Format 'HH:mm:ss') Connection is back."
            Set-View 'back'
        }
    }
    elseif ($line -match '^>STATE:\d+,RECONNECTING' -and $S.Phase -eq 'up' -and -not $S.Stopping -and -not $S.Dropped) {
        $S.Dropped = $true
        Write-Host "$(Get-Date -Format 'HH:mm:ss') Connection dropped - reconnecting..."
        Set-View 'dropped'
    }
    $true
}

# OpenVPN has exited. A country switch starts the next one; anything else ends the run.
function Complete-Run {
    try { $S.Client.Close() } catch { }
    $S.Client = $null
    Save-OpenVpnLog
    Remove-Item $ConnectedFile -Force -ErrorAction SilentlyContinue
    if ($S.Stopping -eq 'switch') {
        $S.Country = $S.Next; $S.Phase = 'idle'; $S.Stopping = $null
        Set-View 'connecting'
        return $true
    }
    # OpenVPN says "verification failed" and exits at once; that last line can be lost with
    # the connection (tests: 1 run in 6). Its own log file still has AUTH_FAILED.
    if (-not $S.AuthFailed -and (Select-String -LiteralPath (Join-Path $Bin 'openvpn-run.log') -Pattern 'AUTH_FAILED' -Quiet -ErrorAction SilentlyContinue)) { $S.AuthFailed = $true }
    $S.Outcome = if ($S.Stopping) { 'stopped' } elseif ($S.Phase -eq 'connecting') { if ($S.AuthFailed) { 'auth' } else { 'exited' } } else { 'lost' }
    $false
}

# Called every 200 ms by the window's timer. Returns $false when the run is over.
function Step-Vpn {
    if ($S.Phase -eq 'idle') {
        if ($S.Stopping) { $S.Outcome = 'stopped'; return $false }
        Set-View 'connecting'
        if (-not $S.Prepared) {
            if (-not (Initialize-Network)) { return $false }
            $S.Prepared = $true
            return $true      # a fresh tick for Start-Vpn, so a stop pressed meanwhile is seen
        }
        return (Start-Vpn)
    }
    if (-not $S.Stopping -and (Test-Path $StopFile)) {      # from 3-disconnect or 4-choose-country
        $kind = "$(Get-Content $StopFile -Raw -ErrorAction SilentlyContinue)".Trim()
        Remove-Item $StopFile -Force -ErrorAction SilentlyContinue
        if ($kind -eq 'switch') {
            $n = Get-ChosenCountry
            if ($n.Code -ne $S.Country.Code) { Request-Stop 'switch' $n }
        } else { Request-Stop 'user' }
    }
    if ($S.Phase -eq 'connecting' -and -not $S.Stopping -and (Get-Date) -gt $S.Deadline) {
        $S.Outcome = 'timeout'; Stop-Process -Id $S.Proc.Id -Force -ErrorAction SilentlyContinue
        return $false
    }
    if ($S.KillAt -and (Get-Date) -gt $S.KillAt) { Stop-Process -Id $S.Proc.Id -Force -ErrorAction SilentlyContinue; $S.KillAt = $null }
    Send-Next
    while ($S.Stream.DataAvailable) {
        $n = $S.Stream.Read($S.Bytes, 0, $S.Bytes.Length)
        if ($n -le 0) { break }
        $S.Buf += [Text.Encoding]::UTF8.GetString($S.Bytes, 0, $n)
        while (($k = $S.Buf.IndexOf("`n")) -ge 0) {
            $line = $S.Buf.Substring(0, $k).TrimEnd("`r"); $S.Buf = $S.Buf.Substring($k + 1)
            if (-not (Read-VpnLine $line)) { return $false }
            Send-Next
        }
    }
    if ($S.Proc.HasExited) {
        # one more round first, to read whatever OpenVPN said on its way out
        if (-not $S.ExitSeen) { $S.ExitSeen = $true; return $true }
        return (Complete-Run)
    }
    if ($S.Phase -eq 'up' -and -not $S.Dropped -and -not $S.Stopping) { Update-Elapsed }
    $true
}

# ---------------------------------------------------------------- the window

function Get-ViewText([string]$Kind) {
    $name = $S.Country.Name
    switch ($Kind) {
        'connecting' { @('מתחבר...', 'amber', 'זה לוקח בדרך כלל כמה שניות.') }
        'connected'  { @('מחובר', 'green', '') }
        'back'       { @('מחובר', 'green', 'החיבור חזר.') }
        'dropped'    { @('החיבור נפל', 'red', "מנסה להתחבר מחדש.`nעד שיחזור - לא לשלוח ולא להעלות דברים רגישים.") }
        'switching'  { @("עובר ל$($S.Next.Name)...", 'amber', '') }
        'stopping'   { @('מתנתק...', 'gray', '') }
        'stopped'    { @('נותק', 'gray', 'הגלישה חזרה להיות רגילה.') }
    }
}

function Format-Elapsed {
    $d = (Get-Date) - $S.UpSince
    if ($d.TotalHours -ge 1) { '{0}:{1:mm\:ss}' -f [int][Math]::Floor($d.TotalHours), $d } else { '{0:m\:ss}' -f $d }
}

function Set-View([string]$Kind) {
    if ($S.View -ne $Kind) { Write-Host "$(Get-Date -Format 'HH:mm:ss') [window] $Kind" }
    $S.View = $Kind
    if (-not $S.Ui) { return }
    $v = Get-ViewText $Kind
    if ($S.Ui -eq 'wpf') { Set-ViewWpf $Kind $v } else { Set-ViewClassic $Kind $v }
}

function Update-Elapsed {
    if (-not $S.Ui) { return }
    if ($S.View -eq 'back' -and ((Get-Date) - $S.BackAt).TotalSeconds -lt 6) { return }   # let "back" be read first
    $S.Els.Detail.Text = "מחובר כבר $(Format-Elapsed)"
}

# --- WPF

function Set-ViewWpf([string]$Kind, $v) {
    $t = $S.Theme; $e = $S.Els; $w = $S.W
    $tone = @{ amber = @('Amber', 'AmberSoft'); green = @('Green', 'GreenSoft'); red = @('Red', 'RedSoft'); gray = @('Sub', 'Surface') }[$v[1]]
    $fg = Get-Brush $t[$tone[0]]; $bg = Get-Brush $t[$tone[1]]
    $e.State.Text = $v[0]; $e.State.Foreground = $fg; $e.Dot.Fill = $fg; $e.Pill.Background = $bg; $e.Halo.Background = $bg
    $e.Detail.Text = $v[2]
    $e.Country.Text = $S.Country.Name
    $flag = Get-FlagSource $S.Country.Code
    if ($flag) { $b = New-Object Windows.Media.ImageBrush($flag); $b.Stretch = 'UniformToFill'; $e.Flag.Background = $b }
    $w.Title = "Proton VPN · $($S.Country.Name)"
    $icon = New-AppIcon $S.Country.Code; if ($icon) { $w.Icon = $icon }
    # a calm steady dot when all is well, a pulse while something is happening
    if ($v[1] -eq 'green' -or $v[1] -eq 'gray') { $e.Dot.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $e.Dot.Opacity = 1 }
    else {
        $a = New-Object Windows.Media.Animation.DoubleAnimation(1, 0.25, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(750))))
        $a.AutoReverse = $true; $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $e.Dot.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
    }
    $busy = $Kind -in 'stopping', 'switching', 'stopped'
    $e.StopBtn.IsEnabled = -not $busy; $e.SwitchBtn.IsEnabled = -not $busy
    switch ($Kind) {
        'connected' { $w.Topmost = $false }
        'back'      { $S.BackAt = Get-Date; $w.Topmost = $false }
        'dropped'   { $w.WindowState = 'Normal'; $w.Topmost = $true; [void]$w.Activate() }   # get noticed
        'switching' { $w.WindowState = 'Normal'; [void]$w.Activate() }
    }
}

function Show-StatusWpf {
    $t = Get-UiTheme; $S.Theme = $t
    $body = @"
<StackPanel Width="336">
  <Grid HorizontalAlignment="Center" Margin="0,4,0,0">
    <Border x:Name="Halo" Width="132" Height="98" CornerRadius="22" Background="{{AmberSoft}}"/>
    $(Get-FlagXaml $S.Country.Code 96 64 10 'Flag')
  </Grid>
  <TextBlock x:Name="Country" FontSize="26" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,16,0,0"/>
  <Border x:Name="Pill" CornerRadius="15" Padding="14,6,16,7" HorizontalAlignment="Center" Margin="0,10,0,0">
    <StackPanel Orientation="Horizontal">
      <Ellipse x:Name="Dot" Width="9" Height="9" VerticalAlignment="Center" Margin="0,1,9,0"/>
      <TextBlock x:Name="State" FontSize="14" FontWeight="SemiBold"/>
    </StackPanel>
  </Border>
  <TextBlock x:Name="Detail" FontSize="13" Foreground="{{Sub}}" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" Margin="0,10,0,0" MinHeight="38"/>
  <Grid Margin="0,16,0,0">
    <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition/></Grid.ColumnDefinitions>
    <Button x:Name="SwitchBtn" Grid.Column="0" Style="{StaticResource Btn}" Content="החלפת מדינה"/>
    <Button x:Name="StopBtn" Grid.Column="2" Style="{StaticResource Danger}" Content="התנתקות"/>
  </Grid>
  <TextBlock FontSize="12" Foreground="{{Sub}}" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" Margin="0,16,0,0" Text="אפשר למזער את החלון. סגירה שלו מנתקת את ה-VPN."/>
</StackPanel>
"@
    $w = New-UiWindow $body -Minimize -Persistent
    $S.W = $w
    $S.Els = @{}
    foreach ($n in 'Halo', 'Flag', 'Country', 'Pill', 'Dot', 'State', 'Detail', 'SwitchBtn', 'StopBtn') { $S.Els[$n] = $w.FindName($n) }
    $S.Ui = 'wpf'
    Set-View 'connecting'

    $S.Els.StopBtn.Add_Click({ Request-Stop 'user' })
    $S.Els.SwitchBtn.Add_Click({ Invoke-Switch })
    # X: cancel the close, then ask once this event has returned (a dialog is better shown
    # from a plain dispatcher turn than from inside WPF's Closing).
    $w.Add_Closing({
        if ($S.Done) { return }
        $_.Cancel = $true
        if ($S.Stopping -or $S.Asking) { return }
        $S.Asking = $true
        [void]$this.Dispatcher.BeginInvoke([Action]{
            try { if (-not $S.Stopping -and (Show-Msg "לנתק את ה-VPN?" 'Question' 'YesNo') -eq 'Yes') { Request-Stop 'user' } }
            finally { $S.Asking = $false }
        })
    })
    $statusTimer = New-Object Windows.Threading.DispatcherTimer
    $statusTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $statusTimer.Add_Tick({
        if ($S.InTick) { return }   # a dialog inside a tick pumps messages; do not step underneath it
        $S.InTick = $true
        try { $go = Step-Vpn }
        catch { Write-Host "UNEXPECTED ERROR: $_"; Write-Host $_.ScriptStackTrace; $S.Outcome = 'error'; $S.Error = "$_"; $go = $false }
        finally { $S.InTick = $false }
        if (-not $go) { $this.Stop(); Close-Status }
    })
    $S.Timer = $statusTimer
    $w.Add_ContentRendered({ if (-not $S.Timer.IsEnabled -and -not $S.Done) { $S.Timer.Start() } })
    [void]$w.ShowDialog()
}

# --- the plain window, for when WPF is not available

function Set-ViewClassic([string]$Kind, $v) {
    $e = $S.Els
    $e.Country.Text = $S.Country.Name
    $e.State.Text = '● ' + $v[0]
    $e.State.ForeColor = @{ amber = [Drawing.Color]::FromArgb(178, 111, 0); green = [Drawing.Color]::FromArgb(24, 136, 74)
                            red = [Drawing.Color]::FromArgb(204, 42, 54); gray = [Drawing.Color]::FromArgb(100, 107, 118) }[$v[1]]
    $e.Detail.Text = $v[2]
    $S.W.Text = "Proton VPN · $($S.Country.Name)"
    $busy = $Kind -in 'stopping', 'switching', 'stopped'
    $e.StopBtn.Enabled = -not $busy; $e.SwitchBtn.Enabled = -not $busy
    switch ($Kind) {
        'connected' { $S.W.TopMost = $false }
        'back'      { $S.BackAt = Get-Date; $S.W.TopMost = $false }
        'dropped'   { $S.W.WindowState = 'Normal'; $S.W.TopMost = $true; $S.W.Activate() }
    }
}

function Show-StatusClassic {
    $f = New-Object Windows.Forms.Form
    $f.StartPosition = 'CenterScreen'; $f.TopMost = $true; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false
    $f.RightToLeft = 'Yes'; $f.RightToLeftLayout = $true; $f.BackColor = [Drawing.Color]::White
    $f.Font = New-Object Drawing.Font('Segoe UI', 11); $f.ClientSize = New-Object Drawing.Size(360, 250)
    $mk = { param($Text, $Size, $Style, $Top, $H)
        $l = New-Object Windows.Forms.Label -Property @{ Text = $Text; AutoSize = $false; TextAlign = 'MiddleCenter'
            Font = (New-Object Drawing.Font('Segoe UI', $Size, [Drawing.FontStyle]$Style)); Location = (New-Object Drawing.Point(10, $Top)); Size = (New-Object Drawing.Size(340, $H)) }
        $f.Controls.Add($l); $l }
    $S.Els = @{ Country = (& $mk '' 18 'Bold' 18 40); State = (& $mk '' 12 'Bold' 62 28); Detail = (& $mk '' 10 'Regular' 92 52) }
    $S.Els.Detail.ForeColor = [Drawing.Color]::FromArgb(100, 107, 118)
    $S.Els.SwitchBtn = New-Object Windows.Forms.Button -Property @{ Text = 'החלפת מדינה'; Location = (New-Object Drawing.Point(190, 160)); Size = (New-Object Drawing.Size(150, 38)) }
    $S.Els.StopBtn = New-Object Windows.Forms.Button -Property @{ Text = 'התנתקות'; Location = (New-Object Drawing.Point(20, 160)); Size = (New-Object Drawing.Size(150, 38)) }
    $f.Controls.Add($S.Els.SwitchBtn); $f.Controls.Add($S.Els.StopBtn)
    [void](& $mk 'אפשר למזער את החלון. סגירה שלו מנתקת את ה-VPN.' 9 'Regular' 208 30)
    $S.W = $f; $S.Ui = 'classic'
    Set-View 'connecting'
    $S.Els.StopBtn.Add_Click({ Request-Stop 'user' })
    $S.Els.SwitchBtn.Add_Click({ Invoke-Switch })
    $f.Add_FormClosing({
        if ($S.Done) { return }
        $_.Cancel = $true
        if (-not $S.Stopping -and (Show-Msg "לנתק את ה-VPN?" 'Question' 'YesNo') -eq 'Yes') { Request-Stop 'user' }
    })
    $statusTimer = New-Object Windows.Forms.Timer -Property @{ Interval = 200 }
    $statusTimer.Add_Tick({
        if ($S.InTick) { return }   # a dialog inside a tick pumps messages; do not step underneath it
        $S.InTick = $true
        try { $go = Step-Vpn }
        catch { Write-Host "UNEXPECTED ERROR: $_"; Write-Host $_.ScriptStackTrace; $S.Outcome = 'error'; $S.Error = "$_"; $go = $false }
        finally { $S.InTick = $false }
        if (-not $go) { $this.Stop(); Close-Status }
    })
    $S.Timer = $statusTimer
    $f.Add_Shown({ $S.Timer.Start() })
    [void]$f.ShowDialog()
}

# --- shared by both windows

function Invoke-Switch {
    $status = if ($S.Phase -eq 'up') { "מחוברים עכשיו: $($S.Country.Name)" } else { "מתחבר עכשיו: $($S.Country.Name)" }
    $code = Show-CountryPicker @(Get-Countries) $S.Country.Code $status
    if (-not $code -or $code -eq $S.Country.Code -or $S.Stopping) { return }
    Set-Content $CountryFile $code -Encoding ASCII
    Request-Stop 'switch' (Get-Countries | Where-Object Code -eq $code | Select-Object -First 1)
}

function Close-Status {
    $S.Done = $true
    if ($S.Outcome -eq 'stopped') {
        Set-View 'stopped'   # a moment of "disconnected" before the window goes away
        if ($S.Ui -eq 'wpf') {
            $t = New-Object Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromMilliseconds(1200); $t.Tag = $S.W
            $t.Add_Tick({ $this.Stop(); $this.Tag.Close() }); $t.Start()
        } else {
            $t = New-Object Windows.Forms.Timer -Property @{ Interval = 1200; Tag = $S.W }
            $t.Add_Tick({ $this.Stop(); $this.Tag.Close() }); $t.Start()
        }
    } else { $S.W.Close() }
}

# ---------------------------------------------------------------- run

$shown = $false
if (Test-Wpf) {
    try { Show-StatusWpf; $shown = $true }
    catch {
        Write-Host "WPF window failed: $_"
        if ($S.Phase -ne 'idle' -or $S.Done) { throw }   # OpenVPN already ran: do not start it twice
        $S.Ui = $null
    }
}
if (-not $shown) { Show-StatusClassic }

Complete-Vpn
$name = $S.Country.Name
switch ($S.Outcome) {
    'stopped' { exit 0 }
    'auth'    { Fail ("Proton דחה את שם המשתמש או הסיסמה.`n`n" +
                    "הריצו שוב את 1-setup.cmd והעתיקו את הפרטים מחדש.`n" +
                    "(אלה הפרטים מעמוד OpenVPN - לא הסיסמה הרגילה של החשבון.)") }
    'timeout' { Fail "החיבור ל$name לא הצליח תוך שתי דקות וחצי. בדקו שיש אינטרנט ונסו שוב." }
    'nostart' { Fail "תוכנת ה-VPN לא עלתה. נסו שוב." }
    'tap'     { Fail "התקנת רכיב הרשת לא הצליחה. נסו שוב, ואם זה חוזר - הפעילו מחדש את המחשב ונסו שוב." }
    'exited'  { Fail "תוכנת ה-VPN נסגרה לפני שהתחברה. נסו שוב." }
    'lost'    {
        $why = if ($S.AuthFailed) { "`n`nProton דחה את פרטי הכניסה. הריצו שוב את 1-setup.cmd." } else { '' }
        Show-Msg ("ה-VPN התנתק, והגלישה ממשיכה עכשיו בלי VPN.$why`n`n" +
            "כדי להתחבר שוב: לחיצה כפולה על 2-connect.cmd") 'Error' | Out-Null
    }
    'error'   { Fail "שגיאה לא צפויה:`n$($S.Error)" }
    default   { exit 0 }   # closed some other way after a clean stop
}
