# Edge-case tests for the kit. No admin rights, no network, no real VPN:
# a throwaway copy of the kit goes into a folder whose name has spaces, Hebrew, an
# apostrophe, an ampersand and parentheses, and its openvpn.exe is swapped for
# FakeOpenVpn.cs, which plays scripted scenarios over the real management protocol.
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
# Windows appear for a few seconds each; leave the mouse alone meanwhile.
param([string]$Work = (Join-Path $env:TEMP 'pvk-tests'))

$ErrorActionPreference = 'Continue'
$Repo = Split-Path -Parent $PSScriptRoot
$Results = New-Object Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $Results.Add([pscustomobject]@{ Ok = $Ok; Name = $Name; Detail = $Detail })
    Write-Host ("{0}  {1}{2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $(if ($Detail -and -not $Ok) { "  -- $Detail" } else { '' }))
}

# ------------------------------------------------------------ static checks
foreach ($f in Get-ChildItem "$Repo\bin\*.ps1") {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    Check "BOM: $($f.Name)" ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) 'Windows PowerShell 5.1 reads a file without BOM as ANSI and the Hebrew breaks'
    $r = powershell -NoProfile -Command "try { (Get-Command -LiteralPath '$($f.FullName)').ScriptBlock | Out-Null; 'ok' } catch { `$_.Exception.Message }"
    Check "loads in PowerShell 5.1: $($f.Name)" ($r -eq 'ok') "$r"
}
foreach ($f in Get-ChildItem "$Repo\*.cmd") {
    $b = [IO.File]::ReadAllBytes($f.FullName); $t = [Text.Encoding]::ASCII.GetString($b)
    Check "cmd is ASCII: $($f.Name)" (-not ($b | Where-Object { $_ -gt 127 })) 'cmd.exe reads .cmd in the OEM code page'
    Check "cmd has CRLF only: $($f.Name)" (($t -split "`r`n").Count -eq ($t -split "`n").Count) 'LF-only lines break labels in cmd.exe'
    Check "cmd guards against running inside the zip: $($f.Name)" ($t -match 'if exist "%~dp0bin\\common.ps1"')
}
$lines = Get-Content "$Repo\bin\countries.txt" -Encoding UTF8 | Where-Object { $_ -and $_ -notmatch '^\s*#' }
$codes = @()
foreach ($l in $lines) {
    $p = $l -split '\|'
    $ok = $p.Count -eq 4 -and $p[0] -match '^[A-Z]{2}$' -and $p[1].Trim() -and $p[2] -in 'near', 'far'
    $ips = @($p[3].Trim() -split '\s+')
    $ipsOk = -not ($ips | Where-Object { -not ($_ -as [ipaddress]) -or $_ -notmatch '^\d+\.\d+\.\d+\.\d+$' })
    Check "countries.txt line $($p[0])" ($ok -and $ipsOk -and $ips.Count -ge 1) $l
    Check "flag exists: $($p[0])" (Test-Path "$Repo\bin\flags\$($p[0].ToLower()).png")
    $codes += $p[0]
}
Check 'countries.txt: codes unique' (($codes | Sort-Object -Unique).Count -eq $codes.Count)
Check 'countries.txt: default is NL with the proven server first' ($lines[0] -like 'NL|*|190.2.149.6 *')

# ------------------------------------------------------------ the throwaway kit
$Kit = Join-Path $Work "בדיקה 'צ'רלי' & co (1)\kit"
if (Test-Path $Work) { Get-ChildItem $Work -Recurse -Filter openvpn.exe | ForEach-Object { Get-Process openvpn -ErrorAction SilentlyContinue | Where-Object Path -eq $_.FullName | Stop-Process -Force } ; [IO.Directory]::Delete($Work, $true) }
New-Item -ItemType Directory -Force $Kit | Out-Null
Copy-Item "$Repo\*.cmd", "$Repo\0-README.txt" $Kit
Copy-Item "$Repo\bin" $Kit -Recurse
Remove-Item "$Kit\bin\creds.dat", "$Kit\bin\*.log", "$Kit\bin\country.txt", "$Kit\bin\ipv6-off.txt" -ErrorAction SilentlyContinue
Remove-Item "$Kit\bin\openvpn.exe"
Add-Type -TypeDefinition (Get-Content "$PSScriptRoot\FakeOpenVpn.cs" -Raw) -OutputAssembly "$Kit\bin\openvpn.exe" -OutputType ConsoleApplication
Check 'fake openvpn.exe built' (Test-Path "$Kit\bin\openvpn.exe")

# credentials with every character that needs escaping on the management line
$User = 'te"st\u $1 ש'; $Pass = 'p\"a`ss'' {x}'
@{ u = ConvertTo-SecureString $User -AsPlainText -Force | ConvertFrom-SecureString
   p = ConvertTo-SecureString $Pass -AsPlainText -Force | ConvertFrom-SecureString } | ConvertTo-Json | Set-Content "$Kit\bin\creds.dat" -Encoding UTF8

# ------------------------------------------------------------ unit checks (in a child process, from the odd path)
$unit = @'
param($Kit)
. (Join-Path $Kit 'bin\common.ps1')
$src = [IO.File]::ReadAllText((Join-Path $Kit 'bin\connect.ps1'))
$ast = [Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$o = [ordered]@{}
Remove-Item $CountryFile -ErrorAction SilentlyContinue
$o.noFile = (Get-ChosenCountry).Code
'US' | Set-Content $CountryFile; $o.us = (Get-ChosenCountry).Code
"us`r`n`r`n" | Set-Content $CountryFile; $o.lowerNewlines = (Get-ChosenCountry).Code
'ZZ garbage' | Set-Content $CountryFile; $o.garbage = (Get-ChosenCountry).Code
'' | Set-Content $CountryFile; $o.empty = (Get-ChosenCountry).Code
[IO.File]::WriteAllText($CountryFile, 'JP', (New-Object Text.UTF8Encoding $true)); $o.bom = (Get-ChosenCountry).Code
Remove-Item $CountryFile
foreach ($c in Get-Countries) {
    $r = @(Get-RemoteArgs $c); $ips = for ($i = 0; $i -lt $r.Count; $i += 4) { $r[$i + 1] }
    $o["remote-$($c.Code)"] = ($r[1] -eq $c.Servers[0] -and $r[2] -eq '1194' -and $r[3] -eq 'udp' -and
        -not (Compare-Object @($ips | Sort-Object -Unique) @($c.Servers | Sort-Object -Unique)) -and $r[0] -eq '--remote')
}
$orders = 1..12 | ForEach-Object { (Get-RemoteArgs (Get-Countries | Where-Object Code -eq 'US') | Select-Object -Index 5) }
$o.shuffles = (@($orders | Sort-Object -Unique).Count -gt 1)
$L = [char]0x200E
$o.latin1 = (Protect-LatinNames 'על 2-connect.cmd') -eq "על ${L}2-connect.cmd$L"
$o.latin2 = (Protect-LatinNames 'בקבצים connect-last.log ו-openvpn-last.log') -eq "בקבצים ${L}connect-last.log$L ו-${L}openvpn-last.log$L"
$o.latin3 = (Protect-LatinNames 'ה-VPN נותק.') -eq 'ה-VPN נותק.'
$o.elapsed = $(Set-Variable S @{ UpSince = (Get-Date).AddSeconds(-3725) }; Format-Elapsed) -eq '1:02:05'
$o | ConvertTo-Json -Compress
'@
[IO.File]::WriteAllText("$Work\unit.ps1", $unit, (New-Object Text.UTF8Encoding $true))
$u = powershell -NoProfile -ExecutionPolicy Bypass -File "$Work\unit.ps1" $Kit | Select-Object -Last 1 | ConvertFrom-Json
Check 'country: no file -> NL' ($u.noFile -eq 'NL')
Check 'country: US' ($u.us -eq 'US')
Check 'country: lower case and blank lines' ($u.lowerNewlines -eq 'US')
Check 'country: garbage -> NL' ($u.garbage -eq 'NL')
Check 'country: empty file -> NL' ($u.empty -eq 'NL')
Check 'country: file with BOM (saved by Notepad)' ($u.bom -eq 'JP')
foreach ($c in $codes) { Check "server list for $c (proven first, UDP 1194, every server)" ([bool]$u."remote-$c") }
Check 'server order is shuffled between connects' ([bool]$u.shuffles)
Check 'file names kept left-to-right in Hebrew text' ($u.latin1 -and $u.latin2 -and $u.latin3)
Check 'elapsed time format' ([bool]$u.elapsed)

# ------------------------------------------------------------ scenarios against the real connect.ps1
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class TW {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    public static IntPtr Find(uint pid, string prefix) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); var sb = new StringBuilder(256); GetWindowText(h, sb, 256);
            if (p == pid && IsWindowVisible(h) && sb.ToString().StartsWith(prefix)) { found = h; return false; } return true; }, IntPtr.Zero);
        return found;
    }
}
'@
$Transcript = "$Kit\bin\connect-last.log"; $FakeLog = "$Work\fake.log"
# shared read: the transcript is still open for writing while connect.ps1 runs
function Read-Text($p) {
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    try { $fs = New-Object IO.FileStream($p, 'Open', 'Read', 'ReadWrite, Delete'); $sr = New-Object IO.StreamReader($fs, $true); $sr.ReadToEnd() } catch { '' } finally { if ($sr) { $sr.Dispose() } }
}
function Wait-For([scriptblock]$Cond, [int]$Sec) { $end = (Get-Date).AddSeconds($Sec); while ((Get-Date) -lt $end) { if (& $Cond) { return $true }; Start-Sleep -Milliseconds 250 }; $false }

# A scenario that failed may have left its window or fake running; that must not spill into the next one.
function Reset-Kit {
    # by folder name: $env:TEMP may be the short 8.3 form while process paths are long
    $leaf = Split-Path $Work -Leaf
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*\$leaf\*" -or $_.ExecutablePath -like "*\$leaf\*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($f in 'connected.txt', 'stop-request', 'ipv6-off.txt') { if (Test-Path -LiteralPath "$Kit\bin\$f") { [IO.File]::Delete("$Kit\bin\$f") } }
    Start-Sleep -Milliseconds 300
}

function Join-Env([hashtable]$a, [hashtable]$b) { $r = @{}; foreach ($h in $a, $b) { foreach ($k in $h.Keys) { $r[$k] = $h[$k] } }; $r }

function Start-Connect([string]$Scenario, [hashtable]$Env = @{}, [switch]$KeepState) {
    if (-not $KeepState) { Reset-Kit }
    Remove-Item -LiteralPath $Transcript, $FakeLog -ErrorAction SilentlyContinue
    $vars = @{ FAKE_SCENARIO = $Scenario; FAKE_LOG = $FakeLog; PROTON_KIT_TEST_CLOSE = '2'; PROTON_KIT_CONNECT_TIMEOUT = '8'; PROTON_KIT_CLASSIC = $null; PROTON_KIT_TEST_ANSWER = $null }
    foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }   # (hashtable + hashtable throws on a repeated key)
    foreach ($k in $vars.Keys) { Set-Item "env:$k" $vars[$k] -ErrorAction SilentlyContinue; if ($null -eq $vars[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } }
    Start-Process powershell -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + "$Kit\bin\connect.ps1" + '"'))
}
function Stop-Kit([string]$Kind = 'stop') { Set-Content -LiteralPath "$Kit\bin\stop-request" $Kind -Encoding ASCII }
function Test-Clean { -not (Test-Path -LiteralPath "$Kit\bin\connected.txt") -and -not (Test-Path -LiteralPath "$Kit\bin\stop-request") -and -not (Get-Process openvpn -ErrorAction SilentlyContinue | Where-Object Path -eq "$Kit\bin\openvpn.exe") }
function Has([string]$Pattern) { (Read-Text $Transcript) -match $Pattern }

foreach ($mode in 'wpf', 'classic') {
    $envMode = if ($mode -eq 'classic') { @{ PROTON_KIT_CLASSIC = '1' } } else { @{} }
    $m = "[$mode] "

    # connect, then disconnect the way 3-disconnect does it
    $p = Start-Connect 'ok' $envMode
    Check "${m}connects" (Wait-For { Has '\[window\] connected' } 40) (Read-Text $Transcript)
    Check "${m}status window is on screen" ((Wait-For { [TW]::Find($p.Id, 'Proton VPN') -ne [IntPtr]::Zero } 5))
    Check "${m}connected.txt written" (Test-Path -LiteralPath "$Kit\bin\connected.txt")
    $f = Read-Text $FakeLog
    Check "${m}credentials arrive intact (quotes, backslashes, Hebrew)" ($f.Contains("user=$User`n") -and $f.Contains("pass=$Pass`n")) $f
    Check "${m}commands one at a time, in order" ($f -match '(?s)cmd state on.*cmd log on.*cmd hold release.*cmd username')
    Check "${m}first server tried: NL proven, UDP 1194" ($f -match '^remote 190\.2\.149\.6 1194 udp')
    Stop-Kit
    Check "${m}disconnects on request" ($p.WaitForExit(15000))
    Check "${m}leaves nothing behind" (Test-Clean)
    Check "${m}no error shown on a clean stop" (-not (Has '\[message Error\]'))

    # wrong credentials
    $p = Start-Connect 'authfail' $envMode
    Check "${m}wrong credentials: exits" ($p.WaitForExit(40000))
    Check "${m}wrong credentials: says so" (Has '\[message Error\] Proton דחה') (Read-Text $Transcript)
    Check "${m}wrong credentials: leaves nothing behind" (Test-Clean)

    # the connection drops and comes back; OpenVPN asks for the password again
    $p = Start-Connect 'drop' $envMode
    Check "${m}drop: warns" (Wait-For { Has '\[window\] dropped' } 40) (Read-Text $Transcript)
    Check "${m}drop: comes back by itself" (Wait-For { Has '\[window\] back' } 15) (Read-Text $Transcript)
    Check "${m}drop: password given again" (([regex]::Matches((Read-Text $FakeLog), 'user=')).Count -eq 2)
    Stop-Kit; Check "${m}drop: then disconnects" ($p.WaitForExit(15000))

    # OpenVPN dies while connected
    $p = Start-Connect 'crash' $envMode
    Check "${m}crash: tells the user the VPN is off" ((Wait-For { Has '\[message Error\] ה-VPN התנתק' } 45) -and $p.WaitForExit(15000)) (Read-Text $Transcript)
    Check "${m}crash: leaves nothing behind" (Test-Clean)

    # OpenVPN exits before connecting
    $p = Start-Connect 'early' $envMode
    Check "${m}early exit: explained" ($p.WaitForExit(40000) -and (Has 'נסגרה לפני שהתחברה')) (Read-Text $Transcript)

    # never connects
    $p = Start-Connect 'hang' $envMode
    Check "${m}timeout: gives up and explains" ($p.WaitForExit(50000) -and (Has 'לא הצליח תוך')) (Read-Text $Transcript)
    Check "${m}timeout: leaves nothing behind" (Test-Clean)

    # stop while still connecting
    $p = Start-Connect 'hang' (Join-Env $envMode @{ PROTON_KIT_CONNECT_TIMEOUT = '60' })
    Wait-For { Has 'Connecting to' } 30 | Out-Null; Start-Sleep 2; Stop-Kit
    Check "${m}stop while connecting: quick and quiet" ($p.WaitForExit(15000) -and -not (Has '\[message Error\]')) (Read-Text $Transcript)

    # switch country while connected (what 4-choose-country does)
    $p = Start-Connect 'ok' $envMode
    Wait-For { Has '\[window\] connected' } 40 | Out-Null
    Set-Content -LiteralPath "$Kit\bin\country.txt" 'US' -Encoding ASCII; Stop-Kit 'switch'
    Check "${m}switch: reconnects to the new country" (Wait-For { (Has 'Connecting to US') -and ((Read-Text $Transcript) -split 'Connecting to US')[1] -match '\[window\] connected' } 45) (Read-Text $Transcript)
    Check "${m}switch: new country's servers used" ((Read-Text $FakeLog) -match 'remote 146\.70\.230\.114 1194 udp')
    Stop-Kit; Check "${m}switch: then disconnects" ($p.WaitForExit(15000))
    Remove-Item -LiteralPath "$Kit\bin\country.txt"

    # close with X, answer "No": stays connected; then X and "Yes": disconnects
    $p = Start-Connect 'ok' (Join-Env $envMode @{ PROTON_KIT_TEST_ANSWER = 'No' })
    Wait-For { Has '\[window\] connected' } 40 | Out-Null
    $h = [TW]::Find($p.Id, 'Proton VPN'); [void][TW]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    Start-Sleep 5
    Check "${m}X then No: still connected" (-not $p.HasExited -and (Has 'לנתק את ה-VPN') -and -not (Has 'Stop requested')) (Read-Text $Transcript)
    Stop-Kit; Check "${m}X then No: can still disconnect" ($p.WaitForExit(15000))

    $p = Start-Connect 'ok' (Join-Env $envMode @{ PROTON_KIT_TEST_ANSWER = 'Yes' })
    Wait-For { Has '\[window\] connected' } 40 | Out-Null
    $h = [TW]::Find($p.Id, 'Proton VPN'); [void][TW]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    Check "${m}X then Yes: disconnects cleanly" ($p.WaitForExit(30000) -and (Has 'Stop requested \(user\)') -and (Test-Clean)) (Read-Text $Transcript)
}

# leftovers of a crashed run must not stop the next one
Reset-Kit; Stop-Kit; 'NL' | Set-Content -LiteralPath "$Kit\bin\connected.txt"
$p = Start-Connect 'ok' -KeepState
Check 'stale stop-request is ignored' ((Wait-For { Has '\[window\] connected' } 40) -and -not $p.HasExited)
# a second 2-connect while connected: must leave the first one alone
$p2 = Start-Process powershell -PassThru -RedirectStandardOutput "$Work\second.txt" -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + "$Kit\bin\connect.ps1" + '"'))
$null = $p2.Handle   # without touching Handle early, ExitCode stays empty after exit
# (its stdout is in the console code page, so look for the marker, not the Hebrew)
Check 'second connect says "already connected" and leaves the first alone' ($p2.WaitForExit(30000) -and $p2.ExitCode -eq 0 -and (Read-Text "$Work\second.txt") -match '\[message Information\]' -and -not $p.HasExited) (Read-Text "$Work\second.txt")
# 3-disconnect's script (not elevated here, so only the stop-request path is exercised)
$d = Start-Process powershell -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + "$Kit\bin\disconnect.ps1" + '"'))
Check 'disconnect.ps1 stops a running connection' ($p.WaitForExit(20000) -and $d.WaitForExit(20000) -and (Test-Clean))

# the country window, from the odd path, in both looks
foreach ($mode in 'wpf', 'classic') {
    if ($mode -eq 'classic') { $env:PROTON_KIT_CLASSIC = '1' } else { Remove-Item env:PROTON_KIT_CLASSIC -ErrorAction SilentlyContinue }
    $env:PROTON_KIT_TEST_CLOSE = '3'
    $c = Start-Process powershell -PassThru -RedirectStandardError "$Work\choose-err.txt" -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + "$Kit\bin\choose.ps1" + '"'))
    $seen = Wait-For { [TW]::Find($c.Id, 'Proton VPN') -ne [IntPtr]::Zero } 10
    if ($mode -eq 'classic') { Start-Sleep 1; $h = [TW]::Find($c.Id, 'Proton VPN'); [void][TW]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) }
    Check "[$mode] country window opens from the odd path" ($seen -and $c.WaitForExit(15000) -and -not (Read-Text "$Work\choose-err.txt")) (Read-Text "$Work\choose-err.txt")
}
Remove-Item env:PROTON_KIT_CLASSIC -ErrorAction SilentlyContinue

# the elevation line keeps the odd path whole (the part before Start-Process -Verb RunAs)
$probe = "@echo off`r`nset ""KIT_SELF=%~f0"" & powershell -NoProfile -Command ""[IO.File]::WriteAllText(`$env:TEMP + '\pvk-probe.txt', `$env:KIT_SELF)""`r`n"
[IO.File]::WriteAllText("$Kit\probe.cmd", $probe, [Text.Encoding]::ASCII)
# launched like a double-click (cmd /c mangles quoted paths that contain &, which a double-click never does)
$probeOut = "$env:TEMP\pvk-probe.txt"; if (Test-Path $probeOut) { [IO.File]::Delete($probeOut) }
Start-Process explorer.exe -ArgumentList ('"' + "$Kit\probe.cmd" + '"')
Wait-For { Test-Path $probeOut } 15 | Out-Null; Start-Sleep -Milliseconds 300
$out = if (Test-Path $probeOut) { [IO.File]::ReadAllText($probeOut) } else { '' }
Check 'admin re-launch gets the exact path (apostrophe, &, parentheses, Hebrew)' ($out.EndsWith("\pvk-tests\בדיקה 'צ'רלי' & co (1)\kit\probe.cmd")) "$out"   # (temp may show as the long or the 8.3 form)

# 4-choose-country.cmd itself, double-click style, from the odd path
$env:PROTON_KIT_TEST_CLOSE = '3'
$before = @(Get-Process powershell | ForEach-Object Id)
Start-Process explorer.exe -ArgumentList ('"' + "$Kit\4-choose-country.cmd" + '"')
$seen = Wait-For { Get-Process powershell | Where-Object { $_.Id -notin $before -and [TW]::Find($_.Id, 'Proton VPN') -ne [IntPtr]::Zero } } 15
Check '4-choose-country.cmd opens the window (double-click from the odd path)' ([bool]$seen)
Start-Sleep 4

foreach ($k in 'FAKE_SCENARIO', 'FAKE_LOG', 'PROTON_KIT_TEST_CLOSE', 'PROTON_KIT_CONNECT_TIMEOUT', 'PROTON_KIT_TEST_ANSWER') { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
$fail = @($Results | Where-Object { -not $_.Ok })
Write-Host ''
Write-Host ("{0} checks, {1} failed" -f $Results.Count, $fail.Count)
$fail | ForEach-Object { Write-Host "  FAIL: $($_.Name)" }
