# Builds proton-ovpn-kit.zip for the release: the kit files only (no tests, no tools,
# no repo files), under one top folder "proton-ovpn-kit", like every release so far.
# Anything a test run or a real run leaves in bin (credentials, logs, state) stays out.
param([string]$Out = (Join-Path (Split-Path -Parent $PSScriptRoot) 'proton-ovpn-kit.zip'))

$Repo = Split-Path -Parent $PSScriptRoot
$stage = Join-Path $env:TEMP ('pvk-stage-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$top = Join-Path $stage 'proton-ovpn-kit'
New-Item -ItemType Directory -Force $top | Out-Null

Copy-Item "$Repo\0-README.txt", "$Repo\*.cmd" $top
$skip = 'creds.dat', 'country.txt', 'connected.txt', 'stop-request', 'ipv6-off.txt', 'mgmt-port.txt'
Get-ChildItem "$Repo\bin" -Recurse -File | Where-Object { $_.Name -notin $skip -and $_.Extension -ne '.log' } | ForEach-Object {
    $rel = $_.FullName.Substring($Repo.Length + 1)
    $dest = Join-Path $top $rel
    New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
    Copy-Item $_.FullName $dest
}

$names = Get-ChildItem $stage -Recurse -File | ForEach-Object { $_.FullName.Substring($stage.Length + 1) }
$bad = $names | Where-Object { $_ -match '[^\x20-\x7E]' }
if ($bad) { throw "non-ASCII names would show garbled in Explorer: $bad" }
if ($names | Where-Object { $_ -match '\\(tests|tools)\\|README\.md$|\.git' }) { throw 'repo-only files in the stage' }

if (Test-Path $Out) { Remove-Item $Out }
Compress-Archive -Path $top -DestinationPath $Out
Remove-Item $stage -Recurse -Force
"{0}  {1:N0} bytes, {2} files" -f $Out, (Get-Item $Out).Length, $names.Count
$names | Sort-Object
