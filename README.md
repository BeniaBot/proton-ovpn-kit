# proton-ovpn-kit

<div dir="rtl">

ערכה קטנה לווינדוס 10/11: חיבור לשרתים החינמיים של Proton VPN דרך OpenVPN, בלי האפליקציה.

* חלון קטן שמראה את המדינה ואת מצב החיבור, ומתריע אם החיבור נופל.
* 10 מדינות לבחירה.

**הורדה:** בעמוד [Releases](../../releases/latest) ← `proton-ovpn-kit.zip` ← לחיצה ימנית ← "חלץ הכול" ← לפתוח את `0-README.txt`.

צריך חשבון Proton חינמי.

</div>

---

Bundles `openvpn.exe` and the TAP-Windows driver exactly as shipped inside Proton VPN for Windows (signed by Proton AG). Both are open source under GPLv2:
[OpenVPN](https://github.com/OpenVPN/openvpn) · [tap-windows6](https://github.com/OpenVPN/tap-windows6).
Flags: [flagcdn.com](https://flagcdn.com) (public domain).

The rest is PowerShell, readable as is. `tests\` checks it without admin rights or a network:
`run-tests.ps1` (behavior, against a stand-in OpenVPN) and `run-ui-tests.ps1` (presses every button).
`tools\build-zip.ps1` builds the release zip.
