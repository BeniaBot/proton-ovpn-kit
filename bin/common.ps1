# Shared settings and helpers for the Proton VPN (OpenVPN) kit.
# Dot-sourced by setup.ps1, connect.ps1, disconnect.ps1 and choose.ps1.

Add-Type -AssemblyName System.Windows.Forms

$Bin       = $PSScriptRoot
$Kit       = Split-Path -Parent $Bin
$CredFile  = Join-Path $Bin 'creds.dat'        # DPAPI-encrypted, readable only by this Windows user
$Ipv6File  = Join-Path $Bin 'ipv6-off.txt'     # adapters whose IPv6 we switched off
$OpenVpn   = Join-Path $Bin 'openvpn.exe'
$Config    = 'base.ovpn'                        # relative to $Bin (openvpn runs with $Bin as working dir)
$CountriesFile = Join-Path $Bin 'countries.txt'
$CountryFile   = Join-Path $Bin 'country.txt'      # the chosen country (code)
$ConnectedFile = Join-Path $Bin 'connected.txt'    # country code, while connected
$StopFile      = Join-Path $Bin 'stop-request'     # 3-disconnect asks the connect window to stop
$AccountUrl = 'https://account.proton.me/vpn/OpenVpn'

# The plain dialog (WinForms), used when the modern one (ui.ps1) cannot run.
# Our own instead of MessageBox: on this Windows the stock message box ignores
# "topmost" and can open hidden behind the browser or the console window, where a user
# thinks the kit is stuck. A TopMost Form really stays in front.
function Show-MsgClassic([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK', [int]$AutoCloseSec = 0) {
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Proton VPN'; $f.TopMost = $true; $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.RightToLeft = 'Yes'; $f.RightToLeftLayout = $true
    $f.Font = New-Object Drawing.Font('Segoe UI', 11)
    $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'; $f.Padding = New-Object Windows.Forms.Padding(12)

    $layout = New-Object Windows.Forms.TableLayoutPanel -Property @{ AutoSize = $true; ColumnCount = 2; RowCount = 2 }
    $pic = New-Object Windows.Forms.PictureBox -Property @{ SizeMode = 'AutoSize'; Margin = (New-Object Windows.Forms.Padding(4, 4, 4, 4)) }
    $pic.Image = @{ Information = [Drawing.SystemIcons]::Information; Warning = [Drawing.SystemIcons]::Warning
                    Error = [Drawing.SystemIcons]::Error; Question = [Drawing.SystemIcons]::Question }[$Icon].ToBitmap()
    $label = New-Object Windows.Forms.Label -Property @{ Text = $Text; AutoSize = $true; MaximumSize = (New-Object Drawing.Size(460, 0)); Margin = (New-Object Windows.Forms.Padding(10, 6, 4, 14)) }
    $layout.Controls.Add($pic, 0, 0); $layout.Controls.Add($label, 1, 0)

    $row = New-Object Windows.Forms.FlowLayoutPanel -Property @{ AutoSize = $true; FlowDirection = 'LeftToRight'; Anchor = 'Left' }
    # the leading comma keeps a one-button list as a list of pairs; without it PowerShell
    # flattens it into two strings and the box shows two one-letter buttons
    $defs = @{ OK = ,@('אישור', 'OK'); OKCancel = @(@('אישור', 'OK'), @('ביטול', 'Cancel')); YesNo = @(@('כן', 'Yes'), @('לא', 'No')) }[$Buttons]
    $script:MsgResult = @{ OK = 'OK'; OKCancel = 'Cancel'; YesNo = 'No' }[$Buttons]   # closing with X
    foreach ($d in $defs) {
        $b = New-Object Windows.Forms.Button -Property @{ Text = $d[0]; Tag = $d[1]; AutoSize = $true; MinimumSize = (New-Object Drawing.Size(96, 34)) }
        $b.Add_Click({ $script:MsgResult = $this.Tag; $this.FindForm().Close() })
        $row.Controls.Add($b)
    }
    $f.AcceptButton = $row.Controls[0]
    $layout.Controls.Add($row, 1, 1)
    $f.Controls.Add($layout)
    $f.Add_Shown({ $this.TopMost = $true; $this.Activate() })
    if ($AutoCloseSec -le 0 -and $env:PROTON_KIT_TEST_CLOSE) { $AutoCloseSec = [int]$env:PROTON_KIT_TEST_CLOSE }   # automated tests
    if ($AutoCloseSec -gt 0) {   # for "all is well" notes that need no click
        $timer = New-Object Windows.Forms.Timer -Property @{ Interval = $AutoCloseSec * 1000; Tag = $f }
        $timer.Add_Tick({ $this.Stop(); if ($env:PROTON_KIT_TEST_ANSWER) { $script:MsgResult = $env:PROTON_KIT_TEST_ANSWER }; $this.Tag.Close() })
        $timer.Start()
    }
    [void]$f.ShowDialog()
    if ($AutoCloseSec -gt 0) { $timer.Dispose() }
    $f.Dispose()
    $script:MsgResult
}

# countries.txt: code | name | near/far | addresses. First line = default.
function Get-Countries {
    Get-Content $CountriesFile -Encoding UTF8 | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object {
        $p = $_ -split '\|'
        [pscustomobject]@{ Code = $p[0].Trim(); Name = $p[1].Trim(); Near = ($p[2].Trim() -eq 'near')
                           Servers = @($p[3].Trim() -split '\s+' | Where-Object { $_ }) }
    }
}

function Get-ChosenCountry {
    $all = @(Get-Countries)
    $code = if (Test-Path $CountryFile) { (Get-Content $CountryFile -Raw).Trim() } else { '' }
    $c = $all | Where-Object Code -eq $code | Select-Object -First 1
    if ($c) { $c } else { $all[0] }
}

# OpenVPN's local management port. Not a fixed number: Windows (Hyper-V, WSL, Docker)
# reserves blocks of ports that move around after each restart, and a reserved port
# cannot be opened at all, so OpenVPN came up without its port and the kit gave up.
# Each connect picks a port that is free right now.
function Find-FreePort {
    foreach ($p in 7505, 0) {   # 0 = let Windows pick one outside its reserved blocks
        try {
            $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $p)
            $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
            return $port
        } catch { }
    }
    throw 'no free local port for the OpenVPN management interface'
}

# The kit's own openvpn.exe. Through CIM, because Get-Process cannot read the path of
# an elevated process from a normal one (the country window is not elevated).
function Get-VpnProcess {
    Get-CimInstance Win32_Process -Filter "Name='openvpn.exe'" -ErrorAction SilentlyContinue |
        Where-Object { -not $_.ExecutablePath -or $_.ExecutablePath -eq $OpenVpn }
}

function Test-VpnRunning { [bool](Get-VpnProcess) }

# Only the connect window talks to OpenVPN: OpenVPN serves one management client at a
# time, and a second one just hangs. So others ask it through a file: "stop", or
# "switch" (reconnect to the country now in country.txt - see Request-VpnSwitch).
# Returns $true once OpenVPN is gone.
function Request-VpnSwitch { Set-Content $StopFile 'switch' -Encoding ASCII }

function Request-VpnStop([int]$WaitSec = 15) {
    Set-Content $StopFile 'stop' -Encoding ASCII
    for ($i = 0; $i -lt $WaitSec * 2 -and (Test-VpnRunning); $i++) { Start-Sleep -Milliseconds 500 }
    $gone = -not (Test-VpnRunning)
    if ($gone) { Remove-Item $StopFile -Force -ErrorAction SilentlyContinue }
    $gone
}

# Starts a kit button exactly like a double-click. Launching a .cmd straight from a
# hidden PowerShell once failed with 0xc0000142 (cmd.exe could not start).
function Start-KitButton([string]$Name) {
    Start-Process explorer.exe -ArgumentList ('"' + (Join-Path $Kit $Name) + '"')
}

# The tunnel carries IPv4 only, so while it is up IPv6 would go around it.
# Switch IPv6 off on the physical adapters and remember which ones we touched.
function Disable-Ipv6 {
    $names = @(Get-NetAdapter -Physical | Where-Object {
        (Get-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue).Enabled
    } | ForEach-Object Name)
    if ($names.Count -eq 0) { return }
    $existing = @(); if (Test-Path $Ipv6File) { $existing = @(Get-Content $Ipv6File -Encoding UTF8) }
    ($existing + $names) | Sort-Object -Unique | Set-Content $Ipv6File -Encoding UTF8
    foreach ($n in $names) { Disable-NetAdapterBinding -Name $n -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue }
}

function Restore-Ipv6 {
    if (-not (Test-Path $Ipv6File)) { return }
    foreach ($n in Get-Content $Ipv6File -Encoding UTF8) {
        if ($n) { Enable-NetAdapterBinding -Name $n -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue }
    }
    Remove-Item $Ipv6File -Force -ErrorAction SilentlyContinue
}

. (Join-Path $PSScriptRoot 'ui.ps1')
