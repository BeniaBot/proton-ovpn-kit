// A stand-in for openvpn.exe, for testing the kit without a network or admin rights.
// Speaks OpenVPN's management protocol the way the real one does with the kit's flags
// (--management-hold --management-query-passwords) and plays a scenario from FAKE_SCENARIO:
//   ok        connect and stay up
//   authfail  reject the credentials
//   drop      connect, drop after 3 s, ask the password again, come back
//   crash     connect, then exit without a word after 3 s
//   early     exit right after the hold is released (never connects)
//   hang      never connect (for the timeout)
//   routeerr  CONNECTED,ROUTE_ERROR on the first launch, then clean (launches counted in FAKE_LOG.count)
//   routeerr-always  CONNECTED,ROUTE_ERROR every time
// FAKE_LOG gets the remotes it was given and the credentials it received.
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

class FakeOpenVpn {
    static StreamWriter w; static readonly object gate = new object(); static string logPath;
    static int creds = 0;

    static void Say(string s) { lock (gate) { w.Write(s + "\r\n"); w.Flush(); } }
    static void Log(string s) { if (logPath != null) lock (gate) File.AppendAllText(logPath, s + "\n", new UTF8Encoding(false)); }
    static long Now() { return DateTimeOffset.UtcNow.ToUnixTimeSeconds(); }

    // "username "Auth" "va\"lue"" -> va"lue (OpenVPN's quoting: backslash escapes)
    static string Unquote(string cmd) {
        int i = cmd.IndexOf('"', cmd.IndexOf('"', cmd.IndexOf('"') + 1) + 1);
        var sb = new StringBuilder();
        for (int k = i + 1; k < cmd.Length; k++) {
            char ch = cmd[k];
            if (ch == '\\' && k + 1 < cmd.Length) { sb.Append(cmd[++k]); continue; }
            if (ch == '"') break;
            sb.Append(ch);
        }
        return sb.ToString();
    }

    static void Later(int ms, Action a) { new Thread(() => { Thread.Sleep(ms); a(); }) { IsBackground = true }.Start(); }

    static int Main(string[] args) {
        string scenario = Environment.GetEnvironmentVariable("FAKE_SCENARIO") ?? "ok";
        logPath = Environment.GetEnvironmentVariable("FAKE_LOG");
        int port = int.Parse(args[Array.IndexOf(args, "--management") + 2]);
        // like the real one: --log starts the file afresh
        int logArg = Array.IndexOf(args, "--log");
        if (logArg >= 0) File.WriteAllText(args[logArg + 1], "");
        for (int i = 0; i < args.Length; i++) if (args[i] == "--remote") Log("remote " + args[i + 1] + " " + args[i + 2] + " " + args[i + 3]);

        var l = new TcpListener(IPAddress.Loopback, port); l.Start();
        var c = l.AcceptTcpClient();
        var s = c.GetStream();
        w = new StreamWriter(s, new UTF8Encoding(false));
        var r = new StreamReader(s, Encoding.UTF8);
        Say(">INFO:OpenVPN Management Interface Version 5 -- type 'help' for more info");
        Say(">HOLD:Waiting for hold release:0");
        string line;
        while ((line = r.ReadLine()) != null) {
            Log("cmd " + (line.StartsWith("password") ? "password ..." : line));
            if (line == "state on") Say("SUCCESS: real-time state notification set to ON");
            else if (line == "log on") Say("SUCCESS: real-time log notification set to ON");
            else if (line == "hold release") {
                Say("SUCCESS: hold release succeeded");
                if (scenario == "early") { Say(">LOG:" + Now() + ",F,Exiting due to fatal error"); Thread.Sleep(200); return 1; }
                Say(">STATE:" + Now() + ",WAIT,,,,,,");
                Say(">PASSWORD:Need 'Auth' username/password");
            }
            else if (line.StartsWith("username ")) { Log("user=" + Unquote(line)); Say("SUCCESS: 'Auth' username entered, but not yet verified"); }
            else if (line.StartsWith("password ")) {
                Log("pass=" + Unquote(line));
                Say("SUCCESS: 'Auth' password entered, but not yet verified");
                creds++;
                if (scenario == "authfail") {
                    if (logArg >= 0) File.AppendAllText(args[logArg + 1], "AUTH: Received control message: AUTH_FAILED\n");
                    Say(">PASSWORD:Verification Failed: 'Auth'");
                    Say(">STATE:" + Now() + ",EXITING,auth-failure,,,,,");
                    Thread.Sleep(200); return 1;
                }
                if (scenario == "hang") continue;
                Say(">LOG:" + Now() + ",I,Peer Connection Initiated with [AF_INET]1.2.3.4:1194");
                string status = "SUCCESS";
                if (scenario.StartsWith("routeerr")) {
                    string counter = logPath + ".count";
                    int launches = File.Exists(counter) ? int.Parse(File.ReadAllText(counter)) : 0;
                    File.WriteAllText(counter, (launches + 1).ToString());
                    if (scenario == "routeerr-always" || launches == 0) status = "ROUTE_ERROR";
                }
                Say(">STATE:" + Now() + ",CONNECTED," + status + ",10.96.0.3,1.2.3.4,1194,,");
                if (scenario == "drop" && creds == 1) Later(3000, () => {
                    Say(">STATE:" + Now() + ",RECONNECTING,ping-restart,,,,,");
                    Say(">PASSWORD:Need 'Auth' username/password");
                });
                if (scenario == "crash") Later(3000, () => Environment.Exit(3));
            }
            else if (line == "signal SIGTERM") {
                Say("SUCCESS: signal SIGTERM thrown");
                Say(">STATE:" + Now() + ",EXITING,SIGTERM,,,,,");
                Thread.Sleep(200); return 0;
            }
            else Say("ERROR: unknown command [" + line + "]");
        }
        return 0;
    }
}
