# Shared settings and helpers for the Proton VPN (OpenVPN) kit.
# Dot-sourced by setup.ps1, connect.ps1 and disconnect.ps1.

Add-Type -AssemblyName System.Windows.Forms

$Bin       = $PSScriptRoot
$Kit       = Split-Path -Parent $Bin
$CredFile  = Join-Path $Bin 'creds.dat'        # DPAPI-encrypted, readable only by this Windows user
$Ipv6File  = Join-Path $Bin 'ipv6-off.txt'     # adapters whose IPv6 we switched off
$OpenVpn   = Join-Path $Bin 'openvpn.exe'
$Config    = 'best.ovpn'                        # relative to $Bin (openvpn runs with $Bin as working dir)
$PortFile  = Join-Path $Bin 'mgmt-port.txt'    # management port of the running OpenVPN
$AccountUrl = 'https://account.proton.me/vpn/OpenVpn'

# Our own small dialog instead of MessageBox: on this Windows the stock message box
# ignores "topmost" and can open hidden behind the browser or the console window,
# where a user thinks the kit is stuck. A TopMost Form really stays in front.
function Show-Msg([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK') {
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
    [void]$f.ShowDialog()
    $f.Dispose()
    $script:MsgResult
}
# OpenVPN's local management port. Not a fixed number: Windows (Hyper-V, WSL, Docker)
# reserves blocks of ports that move around after each restart, and a reserved port
# cannot be opened at all, so OpenVPN came up without its port and the kit gave up.
# Each connect picks a port that is free right now and saves it for disconnect.
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

function Get-MgmtPort {
    if (Test-Path $PortFile) { [int](Get-Content $PortFile -Raw).Trim() } else { 0 }
}

function Test-VpnRunning {
    $port = Get-MgmtPort
    if (-not $port) { return $false }
    # the saved port may be stale (window closed with X) and since reused by another program
    [bool](Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
        Where-Object { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).Name -eq 'openvpn' })
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

function Send-VpnStop {
    try {
        $c = New-Object Net.Sockets.TcpClient('127.0.0.1', (Get-MgmtPort))
        $w = New-Object IO.StreamWriter($c.GetStream()); $w.NewLine = "`n"
        $w.WriteLine('signal SIGTERM'); $w.Flush()
        Start-Sleep -Milliseconds 500; $c.Close(); $true
    } catch { $false }
}
