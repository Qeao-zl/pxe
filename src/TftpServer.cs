using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

// 极简 TFTP 服务（RFC 1350，仅 RRQ），支持 blksize / tsize / timeout 选项协商。
// 用法: tftpd.exe <根目录>
class Tftp
{
    static string root;
    static string logPath;
    static readonly object logLock = new object();

    static void Log(string s)
    {
        try
        {
            lock (logLock)
            {
                File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + s + Environment.NewLine, Encoding.UTF8);
            }
        }
        catch { }
    }

    static void Main(string[] args)
    {
        root = Path.GetFullPath(args.Length > 0 ? args[0] : @"C:\PXE\tftproot");
        Directory.CreateDirectory(root);
        logPath = Path.Combine(Path.GetDirectoryName(root), "logs", "tftp.log");
        try { Directory.CreateDirectory(Path.GetDirectoryName(logPath)); } catch { }
        Log("=== start root=" + root);

        UdpClient udp = null;
        while (udp == null)
        {
            try
            {
                udp = new UdpClient(new IPEndPoint(IPAddress.Any, 69));
                udp.Client.ReceiveBufferSize = 1 << 20;
            }
            catch (Exception ex)
            {
                Log("bind 69 failed (" + ex.Message + "), retry in 5s");
                Thread.Sleep(5000);
            }
        }

        while (true)
        {
            IPEndPoint remote = new IPEndPoint(IPAddress.Any, 0);
            byte[] pkt;
            try { pkt = udp.Receive(ref remote); }
            catch { continue; }
            if (pkt.Length < 4) continue;
            int op = (pkt[0] << 8) | pkt[1];
            if (op != 1 && op != 2) continue;

            byte[] body = pkt;
            IPEndPoint rem = remote;
            int opcode = op;
            ThreadPool.QueueUserWorkItem(delegate(object o)
            {
                try
                {
                    if (opcode == 1) Handle(body, rem);
                    else HandleWrite(body, rem);
                }
                catch (Exception ex) { Log("ERR " + ex.GetType().Name + " " + ex.Message); }
            });
        }
    }

    static List<string> ParseRequest(byte[] pkt, out string fileName)
    {
        List<string> parts = new List<string>();
        int start = 2;
        for (int i = 2; i < pkt.Length; i++)
        {
            if (pkt[i] == 0)
            {
                if (i > start) parts.Add(Encoding.ASCII.GetString(pkt, start, i - start));
                start = i + 1;
            }
        }
        fileName = parts.Count > 0 ? parts[0] : "";
        List<string> opts = new List<string>();
        if (parts.Count > 2) opts = parts.GetRange(2, parts.Count - 2);
        return opts;
    }

    static string Resolve(string name)
    {
        string n = name.Replace('\\', '/').TrimStart('/');
        if (n.Contains("..")) return null;
        string full = Path.GetFullPath(Path.Combine(root, n.Replace('/', Path.DirectorySeparatorChar)));
        if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return null;
        return full;
    }

    static byte[] BuildOack(List<string> pairs)
    {
        List<byte> b = new List<byte> { 0, 6 };
        foreach (string s in pairs) { b.AddRange(Encoding.ASCII.GetBytes(s)); b.Add(0); }
        return b.ToArray();
    }

    static void SendError(IPEndPoint remote, ushort code, string msg)
    {
        try
        {
            using (UdpClient s = new UdpClient(new IPEndPoint(IPAddress.Any, 0)))
            {
                byte[] body = Encoding.ASCII.GetBytes(msg);
                byte[] pkt = new byte[4 + body.Length + 1];
                pkt[0] = 0; pkt[1] = 5;
                pkt[2] = (byte)(code >> 8); pkt[3] = (byte)(code & 0xFF);
                Buffer.BlockCopy(body, 0, pkt, 4, body.Length);
                pkt[pkt.Length - 1] = 0;
                s.Send(pkt, pkt.Length, remote);
            }
        }
        catch { }
    }

    // Kylin's "trusted boot" GRUB writes a measurement log over TFTP before booting.
    // Only these names may be written, everything else stays read-only.
    static readonly string[] WritableNames = { ".bimalog", ".libkytrusted-security.conf", ".bimalog.bak" };

    static bool IsWritable(string file)
    {
        string n = Path.GetFileName(file.Replace('\\', '/'));
        foreach (string w in WritableNames)
        {
            if (n.Equals(w, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    static void HandleWrite(byte[] pkt, IPEndPoint remote)
    {
        string file;
        ParseRequest(pkt, out file);

        string path = Resolve(file);
        if (path == null || !IsWritable(file))
        {
            Log("WRQ-DENY " + file);
            SendError(remote, 2, "Access violation");
            return;
        }

        UdpClient sock = new UdpClient(new IPEndPoint(IPAddress.Any, 0));
        sock.Client.ReceiveTimeout = 4000;
        try
        {
            sock.Connect(remote);
            byte[] ack0 = { 0, 4, 0, 0 };
            sock.Send(ack0, ack0.Length);

            long total = 0;
            using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read))
            {
                ushort block = 1;
                while (true)
                {
                    IPEndPoint ep = new IPEndPoint(IPAddress.Any, 0);
                    byte[] data;
                    try { data = sock.Receive(ref ep); }
                    catch (SocketException) { Log("WRQ-TIMEOUT " + file + " block=" + block); break; }

                    if (data.Length < 4) break;
                    if (((data[0] << 8) | data[1]) != 3) break;

                    int b = (data[2] << 8) | data[3];
                    byte[] ack = new byte[] { 0, 4, (byte)(b >> 8), (byte)(b & 0xFF) };
                    if (b == block)
                    {
                        int n = data.Length - 4;
                        fs.Write(data, 4, n);
                        total += n;
                        sock.Send(ack, ack.Length);
                        block++;
                        if (n < 512) break;
                    }
                    else
                    {
                        sock.Send(ack, ack.Length); // duplicate, re-ack
                    }
                }
            }
            Log("WRQ-DONE " + file + " bytes=" + total);
        }
        catch (Exception ex) { Log("WRQ-ERR " + file + " " + ex.Message); }
        finally { try { sock.Close(); } catch { } }
    }

    static void Handle(byte[] pkt, IPEndPoint remote)
    {
        string file;
        List<string> opts = ParseRequest(pkt, out file);

        string path = Resolve(file);
        if (path == null) { Log("BADNAME " + file); SendError(remote, 1, "File not found"); return; }

        FileInfo fi = new FileInfo(path);
        if (!fi.Exists)
        {
            // GRUB probes /grub.cfg-<mac>, /grub.cfg-<ip>, /grub.cfg-<prefix>... before the plain
            // /grub.cfg. Answer those probes with the main menu so the client gets a menu instead
            // of hanging in a retry loop (which looks like a black screen).
            string baseName = Path.GetFileName(path);
            if (baseName.StartsWith("grub.cfg-", StringComparison.OrdinalIgnoreCase))
            {
                string alias = Path.Combine(root, "grub.cfg");
                if (File.Exists(alias))
                {
                    Log("ALIAS " + file + " -> grub.cfg");
                    path = alias;
                    fi = new FileInfo(alias);
                }
            }
        }

        if (!fi.Exists) { Log("NOTFOUND " + file); SendError(remote, 1, "File not found"); return; }

        int blksize = 512;
        bool needOack = false;
        List<string> oack = new List<string>();

        for (int i = 0; i + 1 < opts.Count; i += 2)
        {
            string k = opts[i].ToLowerInvariant();
            string v = opts[i + 1];
            if (k == "blksize")
            {
                int b;
                if (int.TryParse(v, out b) && b >= 8)
                {
                    blksize = Math.Min(b, 1468);
                    oack.Add("blksize"); oack.Add(blksize.ToString());
                    needOack = true;
                }
            }
            else if (k == "tsize")
            {
                oack.Add("tsize"); oack.Add(fi.Length.ToString());
                needOack = true;
            }
            else if (k == "timeout")
            {
                oack.Add("timeout"); oack.Add("5");
                needOack = true;
            }
        }

        UdpClient sock = new UdpClient(new IPEndPoint(IPAddress.Any, 0));
        sock.Client.ReceiveTimeout = 2000;
        try
        {
            sock.Connect(remote);

            if (needOack)
            {
                byte[] o = BuildOack(oack);
                if (!SendAndWaitAck(sock, o, 0)) { Log("OACK-FAIL " + file + " " + remote); return; }
            }

            byte[] buf = new byte[blksize];
            ushort block = 1;
            long total = 0;
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536))
            {
                while (true)
                {
                    int n = fs.Read(buf, 0, blksize);
                    byte[] data = new byte[4 + n];
                    data[0] = 0; data[1] = 3;
                    data[2] = (byte)(block >> 8); data[3] = (byte)(block & 0xFF);
                    Buffer.BlockCopy(buf, 0, data, 4, n);

                    if (!SendAndWaitAck(sock, data, block))
                    {
                        Log("TIMEOUT block=" + block + " " + file + " from " + remote);
                        return;
                    }
                    total += n;
                    block++;
                    if (n < blksize) break;
                }
            }
            if (total >= 65536) Log("DONE " + file + " bytes=" + total + " blk=" + blksize + " client=" + remote);
        }
        finally
        {
            try { sock.Close(); } catch { }
        }
    }

    static bool SendAndWaitAck(UdpClient sock, byte[] data, int expectBlock)
    {
        for (int attempt = 0; attempt < 12; attempt++)
        {
            try { sock.Send(data, data.Length); }
            catch (Exception ex) { Log("SEND-ERR " + ex.Message); return false; }

            try
            {
                IPEndPoint ep = new IPEndPoint(IPAddress.Any, 0);
                byte[] ack = sock.Receive(ref ep);
                if (ack.Length >= 4 && ack[0] == 0 && ack[1] == 4)
                {
                    int b = (ack[2] << 8) | ack[3];
                    if (b == expectBlock) return true;
                    if (expectBlock != 0 && b == expectBlock - 1) continue; // 重复 ACK，重发
                }
                else if (ack.Length >= 4 && ack[0] == 0 && ack[1] == 5)
                {
                    Log("ERROR-PKT from " + ep);
                    return false;
                }
            }
            catch (SocketException) { }
        }
        return false;
    }
}
