# Click-through tests: every button a user can press, pressed through UI Automation (the
# accessibility interface, the way a screen reader would), in both window kits.
# Same fake OpenVPN as run-tests.ps1; no admin or network needed.
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-ui-tests.ps1
# Windows pop up for a few minutes, and the 1-setup test uses the clipboard: leave both alone.
param([string]$Work = (Join-Path $env:TEMP 'pvk-ui'))

$ErrorActionPreference = 'Continue'
$Repo = Split-Path -Parent $PSScriptRoot
$Results = New-Object Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $Results.Add([pscustomobject]@{ Ok = $Ok; Name = $Name })
    Write-Host ("{0}  {1}{2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $(if ($Detail -and -not $Ok) { "  -- $Detail" } else { '' }))
}

# ------------------------------------------------------------ the throwaway kit
$leaf = Split-Path $Work -Leaf
function Stop-Leftovers {
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*\$leaf\*" -or $_.ExecutablePath -like "*\$leaf\*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
}
Stop-Leftovers
if (Test-Path $Work) { [IO.Directory]::Delete($Work, $true) }
$Kit = Join-Path $Work "בדיקה 'צ'רלי' & co (1)\kit"
New-Item -ItemType Directory -Force $Kit | Out-Null
Copy-Item "$Repo\*.cmd", "$Repo\0-README.txt" $Kit
Copy-Item "$Repo\bin" $Kit -Recurse
foreach ($f in 'creds.dat', 'country.txt', 'connected.txt', 'stop-request', 'ipv6-off.txt') { if (Test-Path "$Kit\bin\$f") { [IO.File]::Delete("$Kit\bin\$f") } }
[IO.File]::Delete("$Kit\bin\openvpn.exe")
Add-Type -TypeDefinition (Get-Content "$PSScriptRoot\FakeOpenVpn.cs" -Raw) -OutputAssembly "$Kit\bin\openvpn.exe" -OutputType ConsoleApplication
# "connect now?" must not raise a real UAC prompt here: 2-connect.cmd only leaves a mark
$Mark = "$Work\connect-pressed.txt"
[IO.File]::WriteAllText("$Kit\2-connect.cmd", "@echo off`r`necho pressed> ""$Mark""`r`n", [Text.Encoding]::Default)
function Set-Creds([string]$U, [string]$P) {
    @{ u = ConvertTo-SecureString $U -AsPlainText -Force | ConvertFrom-SecureString
       p = ConvertTo-SecureString $P -AsPlainText -Force | ConvertFrom-SecureString } | ConvertTo-Json | Set-Content "$Kit\bin\creds.dat" -Encoding UTF8
}
Set-Creds 'user1' 'pass1'

# ------------------------------------------------------------ UI Automation helpers
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class UiMsg { [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l); }'
$AE = [Windows.Automation.AutomationElement]
function Get-Elements([int]$ProcId) {
    $c = New-Object Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $ProcId)
    $AE::RootElement.FindAll('Descendants', $c)
}
# by exact name (a button's text) or a substring of a text block (-Like)
function Find-El([int]$ProcId, [string]$Name, [int]$Sec = 20, [switch]$Like, [string]$Type = '') {
    $end = (Get-Date).AddSeconds($Sec)
    while ((Get-Date) -lt $end) {
        try {
            foreach ($e in Get-Elements $ProcId) {
                $n = $e.Current.Name
                # WinForms buttons in a right-to-left window come through as 'Pane'
                if ($Type -and $e.Current.ControlType.ProgrammaticName -notin "ControlType.$Type", 'ControlType.Pane') { continue }
                if (($Like -and $n -like "*$Name*") -or (-not $Like -and $n -eq $Name)) { return $e }
            }
        } catch { }
        Start-Sleep -Milliseconds 300
    }
    $null
}
function Press([int]$ProcId, [string]$Name, [int]$Sec = 20) {
    $b = Find-El $ProcId $Name $Sec -Type 'Button'
    if (-not $b) { return $false }
    try { $b.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); return $true } catch { }
    # no Invoke pattern (those WinForms panes): the button's own click message
    $h = [IntPtr]$b.Current.NativeWindowHandle
    if ($h -eq [IntPtr]::Zero) { return $false }
    [void][UiMsg]::PostMessage($h, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero); $true
}
function Get-StatusWindow([int]$ProcId) {
    $c = New-Object Windows.Automation.AndCondition((New-Object Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $ProcId)),
        (New-Object Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [Windows.Automation.ControlType]::Window)))
    foreach ($w in $AE::RootElement.FindAll('Children', $c)) { if ($w.Current.Name -like 'Proton VPN ·*') { return $w } }
}

$Transcript = "$Kit\bin\connect-last.log"; $FakeLog = "$Work\fake.log"
function Read-Text($p) {
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    try { $fs = New-Object IO.FileStream($p, 'Open', 'Read', 'ReadWrite, Delete'); $sr = New-Object IO.StreamReader($fs, $true); $sr.ReadToEnd() } catch { '' } finally { if ($sr) { $sr.Dispose() } }
}
function Has([string]$Pattern) { (Read-Text $Transcript) -match $Pattern }
function Wait-For([scriptblock]$Cond, [int]$Sec) { $end = (Get-Date).AddSeconds($Sec); while ((Get-Date) -lt $end) { if (& $Cond) { return $true }; Start-Sleep -Milliseconds 300 }; $false }
function Test-Clean { -not (Test-Path -LiteralPath "$Kit\bin\connected.txt") -and -not (Test-Path -LiteralPath "$Kit\bin\stop-request") -and -not (Get-Process openvpn -ErrorAction SilentlyContinue | Where-Object Path -eq "$Kit\bin\openvpn.exe") }
function Start-Script([string]$Script, [string]$Mode, [hashtable]$Env = @{}) {
    Stop-Leftovers
    foreach ($f in $Transcript, $FakeLog) { if (Test-Path -LiteralPath $f) { [IO.File]::Delete($f) } }
    $vars = @{ FAKE_SCENARIO = 'ok'; FAKE_LOG = $FakeLog; PROTON_KIT_TEST_CLOSE = '60'; PROTON_KIT_TEST_NOBROWSER = '1'; PROTON_KIT_CLASSIC = $(if ($Mode -eq 'classic') { '1' } else { $null }) }
    foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
    foreach ($k in $vars.Keys) { if ($null -eq $vars[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } else { Set-Item "env:$k" $vars[$k] } }
    $p = Start-Process powershell -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + "$Kit\bin\$Script" + '"'))
    $null = $p.Handle; $p
}
# Copy like Proton's copy button, and make sure it really landed: another program may hold
# the clipboard for a moment, and a lost copy made a setup check fail at random.
function Copy-Text([string]$T) { for ($i = 0; $i -lt 10; $i++) { try { Set-Clipboard $T; if ((Get-Clipboard -Raw) -eq $T) { return } } catch { }; Start-Sleep -Milliseconds 200 } }

$CountryName = @{}; Get-Content "$Repo\bin\countries.txt" -Encoding UTF8 | Where-Object { $_ -match '^[A-Z]{2}\|' } | ForEach-Object { $x = $_ -split '\|'; $CountryName[$x[0]] = $x[1] }

foreach ($mode in 'wpf', 'classic') {
    $m = "[$mode] "
    if (Test-Path "$Kit\bin\country.txt") { [IO.File]::Delete("$Kit\bin\country.txt") }

    # --- the status window's own buttons
    $p = Start-Script 'connect.ps1' $mode
    Check "${m}connects" (Wait-For { Has '\[window\] connected' } 40)
    Check "${m}'החלפת מדינה' opens the country window" ((Press $p.Id 'החלפת מדינה') -and [bool](Find-El $p.Id $CountryName['US'] 15 -Type 'Button'))
    Check "${m}picking a country there switches to it" ((Press $p.Id $CountryName['US']) -and (Wait-For { (Has 'Connecting to US') -and ((Read-Text $Transcript) -split 'Connecting to US')[1] -match '\[window\] connected' } 40)) (Read-Text $Transcript)
    if ($mode -eq 'wpf') {
        $w = Get-StatusWindow $p.Id
        Check "${m}'מזעור' minimizes" ((Press $p.Id 'מזעור') -and (Wait-For { $w.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Current.WindowVisualState -eq 'Minimized' } 5))
        $w.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).SetWindowVisualState('Normal')
    }
    # X: in WPF our own button; in the plain window the title bar's (WindowPattern.Close = the X)
    $closeX = { if ($mode -eq 'wpf') { Press $p.Id 'סגירה' } else { (Get-StatusWindow $p.Id).GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close(); $true } }
    Check "${m}X asks before disconnecting" ((& $closeX) -and [bool](Find-El $p.Id 'לנתק את ה-VPN' 10 -Like))
    Check "${m}X then 'לא': stays connected" ((Press $p.Id 'לא') -and -not (Wait-For { $p.HasExited -or (Has 'Stop requested \(user\)') } 4))   # (the switch above logged 'Stop requested (switch)')
    Check "${m}X then 'כן': disconnects cleanly" ((& $closeX) -and (Press $p.Id 'כן') -and $p.WaitForExit(20000) -and (Test-Clean)) (Read-Text $Transcript)

    $p = Start-Script 'connect.ps1' $mode
    Wait-For { Has '\[window\] connected' } 40 | Out-Null
    Check "${m}'התנתקות' disconnects cleanly" ((Press $p.Id 'התנתקות') -and $p.WaitForExit(20000) -and (Test-Clean) -and -not (Has '\[message Error\]')) (Read-Text $Transcript)

    # --- 4-choose-country while not connected
    if (Test-Path $Mark) { [IO.File]::Delete($Mark) }
    $c = Start-Script 'choose.ps1' $mode
    Check "${m}country window: pick 'יפן', then 'לא' to connecting now" ((Press $c.Id $CountryName['JP']) -and (Press $c.Id 'לא') -and $c.WaitForExit(15000) -and (Get-Content "$Kit\bin\country.txt") -eq 'JP' -and -not (Test-Path $Mark))
    $c = Start-Script 'choose.ps1' $mode
    Check "${m}country window: the saved choice is shown as current" ([bool](Find-El $c.Id "נבחרה עכשיו: $($CountryName['JP'])" 15 -Like))
    Check "${m}country window: pick 'הולנד', then 'כן' starts 2-connect" ((Press $c.Id $CountryName['NL']) -and (Press $c.Id 'כן') -and $c.WaitForExit(15000) -and (Get-Content "$Kit\bin\country.txt") -eq 'NL' -and (Wait-For { Test-Path $Mark } 10))
    $c = Start-Script 'choose.ps1' $mode
    Check "${m}country window: closing it changes nothing" ((Press $c.Id 'סגירה') -and $c.WaitForExit(15000) -and (Get-Content "$Kit\bin\country.txt") -eq 'NL')

    # --- 4-choose-country while connected: the status window switches by itself
    $p = Start-Script 'connect.ps1' $mode
    Wait-For { Has '\[window\] connected' } 40 | Out-Null
    $c = Start-Process powershell -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + "$Kit\bin\choose.ps1" + '"'))
    Check "${m}country window while connected: says where it is connected" ([bool](Find-El $c.Id "מחוברים עכשיו: $($CountryName['NL'])" 15 -Like))
    Check "${m}country window while connected: picking switches the running VPN" ((Press $c.Id $CountryName['CA']) -and $c.WaitForExit(15000) -and (Wait-For { (Has 'Connecting to CA') -and ((Read-Text $Transcript) -split 'Connecting to CA')[1] -match '\[window\] connected' } 40)) (Read-Text $Transcript)
    Press $p.Id 'התנתקות' | Out-Null; $p.WaitForExit(20000) | Out-Null

    # --- 1-setup, the whole way, with the clipboard like Proton's copy buttons
    Set-Creds 'old' 'old'
    $s = Start-Script 'setup.ps1' $mode
    $ok = (Find-El $s.Id 'כבר שמורים' 20 -Like) -and (Press $s.Id 'כן') -and (Find-El $s.Id 'הגדרה ראשונה' 15 -Like) -and (Press $s.Id 'אישור')
    Check "${m}setup: replaces saved credentials, opens the steps" ([bool]$ok)
    Find-El $s.Id 'שלב 1 מתוך 2' 15 -Like | Out-Null; Start-Sleep -Milliseconds 400
    Copy-Text 'fresh-user1'; Press $s.Id 'אישור' | Out-Null
    Find-El $s.Id 'שלב 2 מתוך 2' 20 -Like | Out-Null; Start-Sleep -Milliseconds 800
    Copy-Text 'fresh-user1'; Press $s.Id 'אישור' | Out-Null
    Check "${m}setup: the username pasted twice is caught" ([bool](Find-El $s.Id 'זה שוב שם המשתמש' 20 -Like))
    Press $s.Id 'אישור' | Out-Null
    Find-El $s.Id 'שלב 2 מתוך 2' 20 -Like | Out-Null; Start-Sleep -Milliseconds 800
    Press $s.Id 'אישור' | Out-Null    # nothing copied
    Check "${m}setup: nothing copied is caught" ([bool](Find-El $s.Id 'לא מצאתי' 10 -Like))
    Press $s.Id 'אישור' | Out-Null
    Find-El $s.Id 'שלב 2 מתוך 2' 20 -Like | Out-Null; Start-Sleep -Milliseconds 800
    Copy-Text 'Pa"ss\w0rd'; Press $s.Id 'אישור' | Out-Null
    $done = [bool](Find-El $s.Id 'ההגדרה הושלמה' 15 -Like)
    Press $s.Id 'לא' | Out-Null
    $saved = try { $j = Get-Content "$Kit\bin\creds.dat" -Raw | ConvertFrom-Json
        $b = { param($x) $q = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $x)); [Runtime.InteropServices.Marshal]::PtrToStringBSTR($q) }
        (& $b $j.u) -eq 'fresh-user1' -and (& $b $j.p) -eq 'Pa"ss\w0rd' } catch { $false }
    Check "${m}setup: finishes and saves exactly what was copied" ($done -and $s.WaitForExit(15000) -and $saved)
    Check "${m}setup: leaves the clipboard empty" (-not (Get-Clipboard -Raw))
}

Stop-Leftovers
foreach ($k in 'FAKE_SCENARIO', 'FAKE_LOG', 'PROTON_KIT_TEST_CLOSE', 'PROTON_KIT_TEST_NOBROWSER', 'PROTON_KIT_CLASSIC') { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
$fail = @($Results | Where-Object { -not $_.Ok })
Write-Host ''
Write-Host ("{0} checks, {1} failed" -f $Results.Count, $fail.Count)
$fail | ForEach-Object { Write-Host "  FAIL: $($_.Name)" }
