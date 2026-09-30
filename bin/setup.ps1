# One-time setup. The user clicks Proton's own "copy" buttons; this script reads
# the clipboard, stores the OpenVPN username/password encrypted for this Windows
# user only (DPAPI), and clears the clipboard. Nothing is saved in plain text.

. (Join-Path $PSScriptRoot 'common.ps1')

# Files from a downloaded zip carry a "from the internet" mark that makes Windows
# ask again for every script and exe; clear it once for the whole kit.
Get-ChildItem $Kit -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

if (Test-Path $CredFile) {
    $r = Show-Msg "פרטי הכניסה כבר שמורים במחשב הזה.`n`nלהחליף אותם בפרטים חדשים?" 'Question' 'YesNo'
    if ($r -ne 'Yes') { exit 0 }
}

$r = Show-Msg ("הגדרה ראשונה - פעם אחת בלבד.`n`n" +
    "עכשיו ייפתח הדפדפן בעמוד OpenVPN של חשבון Proton.`n" +
    "אם צריך - התחברו לחשבון Proton שלכם.`n`n" +
    "אחרי שהעמוד נפתח ורואים בו 'OpenVPN username', לחצו כאן על אישור.") 'Information' 'OKCancel'
if ($r -ne 'OK') { exit 1 }
Start-Process $AccountUrl

function Read-FromClipboard([string]$Label, [string]$Prompt) {
    while ($true) {
        [Windows.Forms.Clipboard]::Clear()
        $r = Show-Msg $Prompt 'Information' 'OKCancel'
        if ($r -ne 'OK') { [Windows.Forms.Clipboard]::Clear(); exit 1 }
        $v = Get-Clipboard -Raw
        if ($v) { $v = $v.Trim() }
        if ($v -and $v -notmatch '\s' -and $v.Length -ge 6 -and $v.Length -le 128) { return $v }
        Show-Msg ("לא מצאתי $Label בהעתקה.`n`n" +
            "צריך ללחוץ על כפתור ההעתקה (שני ריבועים) שליד $Label בעמוד של Proton, ורק אז על אישור.") 'Warning' | Out-Null
    }
}

$user = Read-FromClipboard 'OpenVPN username' ("שלב 1 מתוך 2`n`n" +
    "בעמוד של Proton, לחצו על כפתור ההעתקה (שני ריבועים) שליד`n'OpenVPN username'`n`n" +
    "ואז לחצו כאן על אישור.")

do {
    $pass = Read-FromClipboard 'OpenVPN password' ("שלב 2 מתוך 2`n`n" +
        "עכשיו לחצו על כפתור ההעתקה שליד`n'OpenVPN password'`n`n" +
        "ואז לחצו כאן על אישור.")
    $same = $pass -ceq $user
    if ($same) { Show-Msg "זה שוב שם המשתמש. צריך להעתיק את הסיסמה - הכפתור שבשורה של OpenVPN password." 'Warning' | Out-Null }
} while ($same)

[Windows.Forms.Clipboard]::Clear()

$data = [ordered]@{
    u = ConvertTo-SecureString $user -AsPlainText -Force | ConvertFrom-SecureString
    p = ConvertTo-SecureString $pass -AsPlainText -Force | ConvertFrom-SecureString
}
$user = $null; $pass = $null
$data | ConvertTo-Json | Set-Content $CredFile -Encoding UTF8

$r = Show-Msg ("ההגדרה הושלמה.`n`n" +
    "פרטי הכניסה נשמרו מוצפנים, ורק המשתמש שלכם בווינדוס יכול לפתוח אותם.`n`n" +
    "להתחבר עכשיו?") 'Information' 'YesNo'
# Through Explorer, exactly like a double-click: launching the .cmd straight from this
# hidden process once failed with 0xc0000142 (cmd.exe could not start).
if ($r -eq 'Yes') { Start-Process explorer.exe -ArgumentList ('"' + (Join-Path $Kit '2-connect.cmd') + '"') }
