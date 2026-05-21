<#
.SYNOPSIS
    多线程翻译监控脚本 v2 - 新架构
.DESCRIPTION
    架构:
    - 文件监视线程: FileSystemWatcher 监视 cache 目录，检测 manual_request 和 chat_source 变更
    - 主线程: 50ms 轮询，缓存 + 待翻译数组 → 入队到工作队列
    - 自动翻译 Worker: 3 个常驻 Runspace，从 AutoWorkQueue 取消息翻译，写入 chat_result
    - 手动翻译 Worker: 1 个常驻 Runspace，从 ManualWorkQueue 取消息翻译，写入 manual_response
    - 翻译缓存: 100 条 LRU + 次数保底
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param ()

# 单实例检测（在 try 内创建，确保 finally 能清理）

# 初始化
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName "System.Web"
Add-Type -AssemblyName "System.Web.Extensions"
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

$trayFormsPath = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Windows.Forms' } | ForEach-Object { $_.Location } | Where-Object { $_ -and $_ -ne '' } | Select-Object -First 1
$trayDrawingPath = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Drawing' } | ForEach-Object { $_.Location } | Where-Object { $_ -and $_ -ne '' } | Select-Object -First 1
if (-not $trayDrawingPath) {
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    $trayDrawingPath = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Drawing' } | ForEach-Object { $_.Location } | Where-Object { $_ -and $_ -ne '' } | Select-Object -First 1
}

# 加载 System.Net.Http（C# Workers 需要）
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

$__asmWebEx = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Web.Extensions' } | ForEach-Object { $_.Location } | Select-Object -First 1
$__asmNetHttp = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Net.Http' } | ForEach-Object { $_.Location } | Select-Object -First 1

# ============================================================
# C# 子线程：文件监控 + 手动Worker + 自动Worker
# ============================================================
Add-Type -ReferencedAssemblies $__asmWebEx,$__asmNetHttp,$trayFormsPath,$trayDrawingPath -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

public static class TrayManager
{
    private const int  SW_HIDE       = 0;
    private const int  SW_RESTORE    = 9;

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    private static NotifyIcon _notifyIcon;
    private static ContextMenu _contextMenu;
    private static IntPtr _hWnd;
    private static System.Windows.Forms.Timer _pollTimer;
    private static bool _initialized = false;

    public static void Initialize()
    {
        if (_initialized) return;
        _initialized = true;

        _hWnd = GetConsoleWindow();
        if (_hWnd == IntPtr.Zero) return;

        Thread staThread = new Thread(StaWorker);
        staThread.IsBackground = true;
        staThread.SetApartmentState(ApartmentState.STA);
        staThread.Start();
    }

    private static void StaWorker()
    {
        _notifyIcon = new NotifyIcon();
        _notifyIcon.Icon = Icon.ExtractAssociatedIcon(
            System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName);
        _notifyIcon.Text = "AAFreeTranslation";
        _notifyIcon.Visible = true;

        _notifyIcon.DoubleClick += (s, e) =>
        {
            ShowWindow(_hWnd, SW_RESTORE);
            SetForegroundWindow(_hWnd);
        };

        System.Reflection.MethodInfo showMenu = typeof(NotifyIcon).GetMethod("ShowContextMenu",
            System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);

        _notifyIcon.MouseDown += (s, e) =>
        {
            if (e.Button == MouseButtons.Right)
            {
                showMenu.Invoke(_notifyIcon, null);
            }
        };

        _contextMenu = new ContextMenu();
        _contextMenu.MenuItems.Add("Exit", (s, e) =>
        {
            Cleanup();
            Environment.Exit(0);
        });
        _notifyIcon.ContextMenu = _contextMenu;

        _pollTimer = new System.Windows.Forms.Timer();
        _pollTimer.Interval = 200;
        _pollTimer.Tick += (s, e) =>
        {
            if (IsIconic(_hWnd))
            {
                ShowWindow(_hWnd, SW_HIDE);
            }
        };
        _pollTimer.Start();

        Application.Run();
    }

    public static void Cleanup()
    {
        if (_pollTimer != null)
        {
            _pollTimer.Stop();
            _pollTimer.Dispose();
            _pollTimer = null;
        }
        if (_notifyIcon != null)
        {
            _notifyIcon.Visible = false;
            _notifyIcon.Dispose();
            _notifyIcon = null;
        }
        if (_contextMenu != null)
        {
            _contextMenu.Dispose();
            _contextMenu = null;
        }
    }
}

public static class CSharpWorkers
{
    // ========== 线程管理 ==========
    private static volatile bool _running;
    private static Thread _fileWatcherThread;
    private static Thread _manualWorkerThread;
    private static Thread _mainThread;
    private static readonly Thread[] _autoWorkerThreads = new Thread[3];
    private static readonly HttpClient _http = new HttpClient();
    private static readonly Hashtable _fileWriteLocks = new Hashtable();
    private static readonly Hashtable _fileLastWrites = new Hashtable();
    private static readonly object _fileLockRoot = new object();

    public static void StartAll(Hashtable sync)
    {
        // 单实例 Mutex
        try
        {
            bool createdNew;
            var mutex = new Mutex(false, "Global\\AAFreeTranslation_Monitor_v2", out createdNew);
            if (!createdNew)
            {
                Console.Error.WriteLine("[Error] Another instance is already running!");
                Environment.Exit(1);
            }
            sync["AppMutex"] = mutex;
        }
        catch (AbandonedMutexException ex)
        {
            sync["AppMutex"] = ex.Mutex;
            Console.WriteLine("[Warning] Previous instance was terminated abnormally, taking over.");
        }

        // Admin 检测 + 窗口标题
        bool isAdmin = TestAdmin();
        sync["IsAdmin"] = isAdmin;
        Console.Title = isAdmin ? "[Admin] AAFreeTranslation" : "[User] AAFreeTranslation";

        // 托盘图标
        try { TrayManager.Initialize(); } catch { }

        // 启动信息
        Console.WriteLine("");
        Console.WriteLine("=== Running ===");
        Console.WriteLine("Auto messages: {0}", sync["AutoFilePath"]);
        Console.WriteLine("Manual requests: {0}", sync["RequestFilePath"]);
        Console.WriteLine("Input model (manual): {0}", sync["InputModel"]);
        Console.WriteLine("Input endpoint: {0}", sync["InputEndpoint"]);
        Console.WriteLine("Output model (auto): {0}", sync["OutputModel"]);
        Console.WriteLine("Output endpoint: {0}", sync["OutputEndpoint"]);
        Console.WriteLine("Max concurrency: {0} threads", sync["MaxConcurrent"]);
        Console.WriteLine("Cache limit: {0} entries", sync["CacheMaxSize"]);
        Console.WriteLine("{0}", isAdmin ? "[Main] Send Enabled" : "[Main] Send Disabled");
        Console.WriteLine("");

        // 启动子线程
        _running = true;

        _fileWatcherThread = new Thread(FileWatcherProc) { IsBackground = true };
        _fileWatcherThread.Start(sync);

        _manualWorkerThread = new Thread(ManualWorkerProc) { IsBackground = true };
        _manualWorkerThread.Start(sync);

        for (int i = 0; i < 3; i++)
        {
            int id = i + 1;
            _autoWorkerThreads[i] = new Thread(AutoWorkerProc) { IsBackground = true };
            _autoWorkerThreads[i].Start(new object[] { sync, id });
        }

        _mainThread = new Thread(MainProc) { IsBackground = true };
        _mainThread.Start(sync);

        Console.WriteLine("[Start] All C# workers running");
    }

    public static void StopAll()
    {
        _running = false;
    }

    public static void CleanupAll(Hashtable sync)
    {
        Console.WriteLine("\n[Cleanup] Stopping...");
        sync["StopFlag"] = true;
        _running = false;

        // TrayManager 清理
        try { TrayManager.Cleanup(); } catch { }

        // Mutex 释放
        try { var m = (Mutex)sync["AppMutex"]; if (m != null) m.Dispose(); } catch { }

        // 统计
        Console.WriteLine("");
        Console.WriteLine("=== Statistics ===");
        Console.WriteLine("Auto messages found: {0}", sync["AutoFound"]);
        Console.WriteLine("Cache hits:          {0}", sync["AutoCached"]);
        Console.WriteLine("Auto translations succeeded: {0}", sync["AutoSent"]);
        Console.WriteLine("Auto skipped (no translation needed): {0}", sync["AutoSkipped"]);
        Console.WriteLine("Manual translations succeeded: {0}", sync["ManualSent"]);
        Console.WriteLine("Translation failures: {0}", sync["Failed"]);
        Console.WriteLine("[Cleanup] Complete");
    }

    private static bool ShouldStop(Hashtable sync)
    {
        if (!_running) return true;
        try { return (bool)sync["StopFlag"]; } catch { return true; }
    }

    // ========== 文件操作 ==========
    private static void WriteFileLocked(string path, string content)
    {
        object fileLock;
        lock (_fileLockRoot)
        {
            fileLock = _fileWriteLocks[path];
            if (fileLock == null)
            {
                fileLock = new object();
                _fileWriteLocks[path] = fileLock;
            }
        }
        lock (fileLock)
        {
            using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                byte[] data = Encoding.UTF8.GetBytes(content);
                fs.Write(data, 0, data.Length);
            }
        }
    }

    private static void WriteChatResultLocked(string path, string content)
    {
        object fileLock;
        lock (_fileLockRoot)
        {
            fileLock = _fileWriteLocks[path];
            if (fileLock == null)
            {
                fileLock = new object();
                _fileWriteLocks[path] = fileLock;
            }
        }
        lock (fileLock)
        {
            int waitMs = 0;
            lock (_fileLockRoot)
            {
                object last = _fileLastWrites[path];
                if (last != null)
                    waitMs = 100 - (int)(DateTime.Now - (DateTime)last).TotalMilliseconds;
            }
            if (waitMs > 0) Thread.Sleep(waitMs);

            using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                byte[] data = Encoding.UTF8.GetBytes(content);
                fs.Write(data, 0, data.Length);
            }
            lock (_fileLockRoot)
            {
                _fileLastWrites[path] = DateTime.Now;
            }
        }
    }

    private static string ReadLuaFile(string path)
    {
        try
        {
            string raw = File.ReadAllText(path, Encoding.UTF8).Trim().Trim('"');
            if (string.IsNullOrEmpty(raw)) return "";
            // 如果包含 {chatMsg = "..."} 格式，提取内部内容
            var m = Regex.Match(raw, @"\{chatMsg\s*=\s*""(.*)""\}", RegexOptions.Singleline);
            if (m.Success) raw = m.Groups[1].Value.Trim();
            if (!raw.StartsWith("||||") || !raw.EndsWith("||||")) return "";
            string[] parts = raw.Split(new[] { "||||" }, StringSplitOptions.None);
            if (parts.Length < 6) return "";
            return raw;
        }
        catch { return ""; }
    }

    // ========== 缓存管理 ==========
    private static string GetCache(Hashtable cache, string key)
    {
        if (string.IsNullOrEmpty(key)) return null;
        lock (cache.SyncRoot)
        {
            if (cache.ContainsKey(key))
            {
                var entry = (Hashtable)cache[key];
                entry["hitCount"] = (int)entry["hitCount"] + 1;
                entry["lastHit"] = DateTime.Now;
                return (string)entry["translation"];
            }
        }
        return null;
    }

    private static void SetCache(Hashtable cache, int maxSize, string key, string translation)
    {
        if (string.IsNullOrEmpty(key)) return;
        lock (cache.SyncRoot)
        {
            if (cache.Count >= maxSize)
            {
                string newestKey = null;
                string secondNewestKey = null;
                int newestHitCount = 0;
                DateTime newestTime = DateTime.MinValue;
                DateTime secondNewestTime = DateTime.MinValue;
                foreach (DictionaryEntry kv in cache)
                {
                    var ent = (Hashtable)kv.Value;
                    DateTime t = (DateTime)ent["lastHit"];
                    if (t > newestTime)
                    {
                        secondNewestKey = newestKey;
                        secondNewestTime = newestTime;
                        newestKey = (string)kv.Key;
                        newestHitCount = (int)ent["hitCount"];
                        newestTime = t;
                    }
                    else if (t > secondNewestTime)
                    {
                        secondNewestKey = (string)kv.Key;
                        secondNewestTime = t;
                    }
                }
                if (newestHitCount >= 3 && cache.Count > 1 && secondNewestKey != null)
                    cache.Remove(secondNewestKey);
                else if (newestKey != null)
                    cache.Remove(newestKey);
            }
            var entry = new Hashtable();
            entry["hitCount"] = 0;
            entry["lastHit"] = DateTime.Now;
            entry["translation"] = translation;
            cache[key] = entry;
        }
    }

    // ========== 语言检测 ==========
    private static bool NeedTranslate(string text, string targetLang)
    {
        if (string.IsNullOrEmpty(text) || string.IsNullOrEmpty(targetLang)) return false;
        text = text.Replace("@^", "").Replace("@&", "");
        if (text.Trim() == "") return false;
        bool hasLetter = false;
        foreach (char c in text)
        {
            if (char.IsLetter(c)) { hasLetter = true; break; }
        }
        if (!hasLetter) return false;
        int charCount = 0, enCount = 0, zhCount = 0, ruCount = 0;
        foreach (char c in text)
        {
            int code = (int)c;
            if      (code >= 0x4E00 && code <= 0x9FFF) { zhCount++; charCount++; }
            else if (code >= 0x3400 && code <= 0x4DBF) { zhCount++; charCount++; }
            else if (code >= 0x0400 && code <= 0x04FF) { ruCount++; charCount++; }
            else if ((code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A)) { enCount++; charCount++; }
        }
        if (charCount == 0) return false;
        string detectedLang = "en";
        int maxCount = enCount;
        if (zhCount >= maxCount) { maxCount = zhCount; detectedLang = "zh"; }
        if (ruCount >= maxCount) { maxCount = ruCount; detectedLang = "ru"; }
        return detectedLang != targetLang;
    }

    // ========== Google 翻译 ==========
    public static string InvokeGoogleTranslate(int timeoutSec, string targetLang, string text)
    {
        try
        {
            string url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl="
                + targetLang + "&dt=t&q=" + Uri.EscapeDataString(text);
            var req = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(url);
            req.Timeout = timeoutSec * 1000;
            req.Method = "GET";
            using (var resp = req.GetResponse())
            using (var reader = new StreamReader(resp.GetResponseStream()))
            {
                string json = reader.ReadToEnd();
                var match = Regex.Match(json, @"\[\[\[""([^""]*)""");
                if (match.Success) return match.Groups[1].Value;
            }
            return "";
        }
        catch (System.Net.WebException)
        {
            Console.WriteLine("[Google:Error] Connection timeout (" + timeoutSec + "s)");
            return null;
        }
        catch (Exception ex)
        {
            Console.WriteLine("[Google:Error] " + ex.Message);
            return null;
        }
    }

    private static Hashtable AsHashtable(object obj)
    {
        var ht = obj as Hashtable;
        if (ht != null) return ht;
        var dict = obj as Dictionary<string, object>;
        if (dict != null)
        {
            ht = new Hashtable();
            foreach (var kv in dict) ht[kv.Key] = kv.Value;
            return ht;
        }
        return null;
    }

    private static ArrayList AsArrayList(object obj)
    {
        var list = obj as ArrayList;
        if (list != null) return list;
        var arr = obj as object[];
        if (arr != null) return new ArrayList(arr);
        return null;
    }

    // ========== ChatAPI 翻译 ==========
    public static string InvokeChatAPI(int timeoutSec, string endpoint, string apiKey, string model, ArrayList messages, Hashtable config)
    {
        try
        {
            var jss = new System.Web.Script.Serialization.JavaScriptSerializer();
            jss.MaxJsonLength = int.MaxValue;
            var body = new Hashtable();
            body["model"] = model;
            body["messages"] = messages;
            if (model != null && model.IndexOf("deepseek", StringComparison.OrdinalIgnoreCase) >= 0)
                body["thinking"] = new Hashtable { { "type", "disabled" } };
            if (config != null)
            {
                if (config.Contains("temperature")) body["temperature"] = config["temperature"];
                if (config.Contains("top_p")) body["top_p"] = config["top_p"];
                if (config.Contains("max_tokens")) body["max_tokens"] = config["max_tokens"];
            }
            string jsonBody = jss.Serialize(body);
            var req = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(endpoint);
            req.Method = "POST";
            req.ContentType = "application/json; charset=utf-8";
            req.Headers.Add("Authorization", "Bearer " + apiKey);
            req.Timeout = timeoutSec * 1000;
            byte[] payload = Encoding.UTF8.GetBytes(jsonBody);
            using (var stream = req.GetRequestStream()) { stream.Write(payload, 0, payload.Length); }
            using (var resp = req.GetResponse())
            using (var reader = new StreamReader(resp.GetResponseStream()))
            {
                string result = reader.ReadToEnd();
                var obj = AsHashtable(jss.DeserializeObject(result));
                if (obj == null) return "";
                var choices = AsArrayList(obj["choices"]);
                if (choices == null || choices.Count == 0) return "";
                var first = AsHashtable(choices[0]);
                if (first == null) return "";
                var msg = AsHashtable(first["message"]);
                if (msg == null) return "";
                string text = msg["content"] as string;
                if (text == null) return "";
                return text.Trim().TrimStart('[').TrimEnd(']');
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine("[ChatAPI:Error] " + ex.Message);
            return null;
        }
    }

    // ========== 文件监控线程 ==========
    private static void FileWatcherProc(object state)
    {
        var sync = (Hashtable)state;
        var manualQ = (Queue)sync["ManualWorkQueue"];
        string lastManual = ReadLuaFile((string)sync["RequestFilePath"]);
        string lastAuto = ReadLuaFile((string)sync["AutoFilePath"]);
        string lastSend = ReadLuaFile((string)sync["SendResultFile"]);
        DateTime lastSendTime = DateTime.MinValue;
        DateTime lastConfigTime = DateTime.MinValue;
        try { lastConfigTime = File.GetLastWriteTime((string)sync["ConfigFilePath"]); } catch { }

        // 启动时清理 send_result 残留，防止发脏数据到游戏
        try
        {
            string sendFile = (string)sync["SendResultFile"];
            string raw = File.ReadAllText(sendFile, Encoding.UTF8).Trim('"', ' ', '\t', '\r', '\n');
            if (!string.IsNullOrEmpty(raw)) WriteFileLocked(sendFile, "");
        }
        catch { }

        while (!ShouldStop(sync))
        {
            try
            {
                // ---- config.ini 热重载 ----
                try
                {
                    DateTime cfgTime = File.GetLastWriteTime((string)sync["ConfigFilePath"]);
                    if (cfgTime != lastConfigTime)
                    {
                        lastConfigTime = cfgTime;
                        ReadConfig(sync);
                    }
                }
                catch { }

                // ---- SendResult 检查 ----
                string sendFile = (string)sync["SendResultFile"];
                string sendContent = ReadLuaFile(sendFile);
                if (!string.IsNullOrEmpty(sendContent) && sendContent != lastSend)
                {
                    lastSend = sendContent;
                    if ((bool)sync["IsAdmin"])
                    {
                        WriteFileLocked(sendFile, "");
                        var now = DateTime.Now;
                        if ((now - lastSendTime).TotalMilliseconds >= 30)
                        {
                            lastSendTime = now;
                            lock (sync.SyncRoot)
                            {
                                sync["SendResultContent"] = sendContent;
                                sync["SendToGameReady"] = true;
                            }
                        }
                    }
                }

                // ---- manual_request 检查 ----
                string reqFile = (string)sync["RequestFilePath"];
                string reqContent = ReadLuaFile(reqFile);
                if (!string.IsNullOrEmpty(reqContent) && reqContent != lastManual)
                {
                    lastManual = reqContent;
                    lock (manualQ.SyncRoot) { manualQ.Enqueue(reqContent); }
                }

                // ---- chat_source 检查 ----
                string autoFile = (string)sync["AutoFilePath"];
                string autoContent = ReadLuaFile(autoFile);
                if (!string.IsNullOrEmpty(autoContent) && autoContent != lastAuto)
                {
                    lastAuto = autoContent;
                    autoContent = Encoding.UTF8.GetString(Encoding.UTF8.GetBytes(autoContent));
                    lock (sync.SyncRoot)
                    {
                        sync["NewAutoMessage"] = autoContent;
                        sync["NewAutoReady"] = true;
                        sync["AutoFound"] = (int)sync["AutoFound"] + 1;
                    }
                    try
                    {
                        string[] fs = autoContent.Split(new[] { "||||" }, StringSplitOptions.None);
                        string sender = fs.Length >= 3 ? fs[2] : "";
                        string rawText = "";
                        if (fs.Length >= 4) try { rawText = Encoding.UTF8.GetString(Convert.FromBase64String(fs[3])); } catch { rawText = fs[3]; }
                        string disp = Regex.Replace(rawText, @"[|]?i\d+,[^,]*,[^,]*,[^;]*;", "");
                        disp = Regex.Replace(disp, @"\|.*?;", "");
                        if (disp.Trim() == "") disp = rawText;
                        if (disp.Length > 50) disp = disp.Substring(0, 50);
                        Console.WriteLine("[Auto:NewMsg] {0}:{1}", sender, disp);
                    }
                    catch { }
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("[FileMonitor:Error] " + ex.Message);
            }
            Thread.Sleep(50);
        }
    }

    // ========== 手动翻译 Worker ==========
    private static void ManualWorkerProc(object state)
    {
        var sync = (Hashtable)state;
        var manualQ = (Queue)sync["ManualWorkQueue"];
        var cache = (Hashtable)sync["Cache"];
        var cmax = (int)sync["CacheMaxSize"];
        var tmo = (int)sync["HttpTimeoutSec"];

        while (!ShouldStop(sync))
        {
            string content = null;
            lock (manualQ.SyncRoot)
            {
                if (manualQ.Count > 0) content = (string)manualQ.Dequeue();
            }
            if (content == null) { Thread.Sleep(100); continue; }

            try
            {
                // 解析字段
                string[] fields = content.Split(new[] { "||||" }, StringSplitOptions.None);
                string typeStr = fields.Length >= 2 ? fields[1] : "";
                string playerName = fields.Length >= 3 ? fields[2] : "";
                string msgText = content;
                string timestamp = fields.Length >= 5 ? fields[4] : "";
                if (fields.Length >= 4)
                {
                    try { msgText = Encoding.UTF8.GetString(Convert.FromBase64String(fields[3])); }
                    catch { msgText = fields[3]; }
                }
                if (string.IsNullOrEmpty(msgText.Trim())) continue;

                int translateType = 0;
                int.TryParse(typeStr, out translateType);

                // 翻译
                string manualTargetLang = "en";
                switch (translateType)
                {
                    case 1: manualTargetLang = "en"; break;
                    case 2: manualTargetLang = "ru"; break;
                    case 3: manualTargetLang = "zh"; break;
                    case 4: manualTargetLang = "ru"; break;
                    case 5: manualTargetLang = "zh"; break;
                    case 6: manualTargetLang = "en"; break;
                }

                string result = null;
                int engine = (int)sync["TranslateEngine"];

                if (engine == 1)
                {
                    result = InvokeGoogleTranslate(tmo, manualTargetLang, msgText);
                }
                else if (engine == 2)
                {
                    string key = (string)sync["InputApiKey"];
                    if (string.IsNullOrEmpty(key))
                    {
                        Console.WriteLine("[Input:Error] No API Key configured");
                        continue;
                    }
                    // 构建 ChatAPI 消息
                    var aiPrompts = (Hashtable)sync["AiPrompts"];
                    var manualCfg = aiPrompts != null ? (Hashtable)aiPrompts["manual"] : null;
                    string systemMsg = "You are a translator. Translate the following text to " + manualTargetLang + ". Only return the translated text, nothing else, no explanations.";
                    if (manualCfg != null && manualCfg.Contains("by_type"))
                    {
                        var byType = (Hashtable)manualCfg["by_type"];
                        if (byType.Contains(typeStr))
                        {
                            var tc = (Hashtable)byType[typeStr];
                            if (tc.Contains("system_prompt")) systemMsg = (string)tc["system_prompt"];
                        }
                    }
                    var msgs = new ArrayList();
                    msgs.Add(new Hashtable { { "role", "system" }, { "content", systemMsg } });
                    if (manualCfg != null && manualCfg.Contains("examples"))
                    {
                        var examples = (ArrayList)manualCfg["examples"];
                        foreach (Hashtable ex in examples)
                        {
                            msgs.Add(new Hashtable { { "role", "user" }, { "content", ex["user"] } });
                            msgs.Add(new Hashtable { { "role", "assistant" }, { "content", ex["assistant"] } });
                        }
                    }
                    string wrapped = msgText;
                    if (manualCfg != null && manualCfg.Contains("wrap"))
                        wrapped = ((string)manualCfg["wrap"]).Replace("{text}", msgText);
                    msgs.Add(new Hashtable { { "role", "user" }, { "content", wrapped } });

                    var config = new Hashtable();
                    if (manualCfg != null)
                    {
                        if (manualCfg.Contains("temperature")) config["temperature"] = manualCfg["temperature"];
                        if (manualCfg.Contains("top_p")) config["top_p"] = manualCfg["top_p"];
                        if (manualCfg.Contains("max_tokens")) config["max_tokens"] = manualCfg["max_tokens"];
                    }
                    result = InvokeChatAPI(tmo,
                        (string)sync["InputEndpoint"],
                        (string)sync["InputApiKey"],
                        (string)sync["InputModel"],
                        msgs, config);
                }

                // 输出结果
                if (!string.IsNullOrEmpty(result))
                {
                    string utf8Result = Encoding.UTF8.GetString(Encoding.UTF8.GetBytes(result));
                    string b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(utf8Result));
                    string origB64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(msgText));
                    string output = "{chatMsg = \"||||" + playerName + "||||" + b64 + "||||" + origB64 + "||||" + timestamp + "||||\"}";

                    // 先打印
                    lock (sync.SyncRoot) { sync["ManualSent"] = (int)sync["ManualSent"] + 1; }
                    string display = (msgText.Replace(" ", "")).Substring(0, Math.Min(10, msgText.Replace(" ", "").Length));
                    Console.WriteLine("[Input:Done] [{0}] {1}", display,
                        result.Substring(0, Math.Min(50, result.Length)));

                    // 再写文件
                    WriteFileLocked((string)sync["ManualOutFile"], output);
                }
                else
                {
                    lock (sync.SyncRoot) { sync["Failed"] = (int)sync["Failed"] + 1; }
                    Console.WriteLine("[Input:Error]");
                    string errB64 = Convert.ToBase64String(Encoding.UTF8.GetBytes("[Error]"));
                    string errOut = "{chatMsg = \"||||" + playerName + "||||" + errB64 + "||||" + timestamp + "||||\"}";
                    WriteFileLocked((string)sync["ManualOutFile"], errOut);
                }
            }
            catch (Exception ex)
            {
                lock (sync.SyncRoot) { sync["Failed"] = (int)sync["Failed"] + 1; }
                Console.WriteLine("[Input:Error] " + ex.Message);
            }
        }
    }

    // ========== 自动翻译 Worker ==========
    private static void AutoWorkerProc(object state)
    {
        var args = (object[])state;
        var sync = (Hashtable)args[0];
        int wid = (int)args[1];
        var autoQ = (Queue)sync["AutoWorkQueue"];
        var cache = (Hashtable)sync["Cache"];
        var cmax = (int)sync["CacheMaxSize"];
        var tmo = (int)sync["HttpTimeoutSec"];

        while (!ShouldStop(sync))
        {
            string content = null;
            lock (autoQ.SyncRoot)
            {
                if (autoQ.Count > 0) content = (string)autoQ.Dequeue();
            }
            if (content == null) { Thread.Sleep(50); continue; }

            try
            {
                // 解析字段
                string[] fields = content.Split(new[] { "||||" }, StringSplitOptions.None);
                string channel = fields.Length >= 2 ? fields[1] : "";
                string senderName = fields.Length >= 3 ? fields[2] : "";
                string targetLang = fields.Length >= 5 ? fields[4] : "en";
                if (string.IsNullOrEmpty(targetLang)) targetLang = "en";
                string msgText = content;
                if (fields.Length >= 4)
                {
                    try { msgText = Encoding.UTF8.GetString(Convert.FromBase64String(fields[3])); }
                    catch { msgText = fields[3]; }
                }

                // 查缓存
                string cacheKey = fields.Length >= 4 ? fields[3] : content;
                string cached = GetCache(cache, cacheKey);
                if (cached != null)
                {
                    lock (sync.SyncRoot) { sync["AutoCached"] = (int)sync["AutoCached"] + 1; }
                    continue;
                }

                // 判断是否需要翻译
                if (!NeedTranslate(msgText, targetLang))
                {
                    lock (sync.SyncRoot) { sync["AutoSkipped"] = (int)sync["AutoSkipped"] + 1; }
                    continue;
                }

                // 提取物品链接和招募链接（保护特殊格式，防止被翻译破坏）
                string itemLinkPattern = @"[|]?i\d+,[^,]*,[^,]*,[^;]*;";
                var itemLinks = new ArrayList();
                var itemMatches = Regex.Matches(msgText, itemLinkPattern);
                foreach (Match m in itemMatches) itemLinks.Add(m.Value);
                string processText = Regex.Replace(msgText, itemLinkPattern, "@^");

                string recruitLinkPattern = @"\|.*?;";
                var recruitLinks = new ArrayList();
                var recruitMatches = Regex.Matches(processText, recruitLinkPattern);
                foreach (Match m in recruitMatches) recruitLinks.Add(m.Value);
                processText = Regex.Replace(processText, recruitLinkPattern, "@&");

                // 调用翻译
                string translation = null;
                int engine = (int)sync["TranslateEngine"];
                var aiPrompts = (Hashtable)sync["AiPrompts"];
                ArrayList msgs2 = null;
                Hashtable config2 = null;

                if (engine == 1)
                {
                    translation = InvokeGoogleTranslate(tmo, targetLang, processText);
                }
                else if (engine == 2)
                {
                    var autoCfg = aiPrompts != null ? (Hashtable)aiPrompts["chat"] : null;
                    Hashtable langCfg = null;
                    if (autoCfg != null && autoCfg.Contains("langs"))
                    {
                        var langs = (Hashtable)autoCfg["langs"];
                        if (langs != null && langs.Contains(targetLang))
                            langCfg = (Hashtable)langs[targetLang];
                    }
                    string systemMsg = "You are a translator. Translate the following text to " + targetLang + ". Only return the translated text, nothing else, no explanations.";
                    if (langCfg != null && langCfg.Contains("system_prompt"))
                        systemMsg = (string)langCfg["system_prompt"];
                    else if (autoCfg != null && autoCfg.Contains("system_prompt"))
                        systemMsg = (string)autoCfg["system_prompt"];

                    msgs2 = new ArrayList();
                    msgs2.Add(new Hashtable { { "role", "system" }, { "content", systemMsg } });
                    ArrayList examples = null;
                    if (langCfg != null && langCfg.Contains("examples"))
                        examples = (ArrayList)langCfg["examples"];
                    else if (autoCfg != null && autoCfg.Contains("examples"))
                        examples = (ArrayList)autoCfg["examples"];
                    if (examples != null)
                    {
                        foreach (Hashtable ex in examples)
                        {
                            msgs2.Add(new Hashtable { { "role", "user" }, { "content", ex["user"] } });
                            msgs2.Add(new Hashtable { { "role", "assistant" }, { "content", ex["assistant"] } });
                        }
                    }
                    string wrapped = processText;
                    if (autoCfg != null && autoCfg.Contains("wrap"))
                        wrapped = ((string)autoCfg["wrap"]).Replace("{text}", processText);
                    msgs2.Add(new Hashtable { { "role", "user" }, { "content", wrapped } });

                    config2 = new Hashtable();
                    if (autoCfg != null)
                    {
                        if (autoCfg.Contains("temperature")) config2["temperature"] = autoCfg["temperature"];
                        if (autoCfg.Contains("top_p")) config2["top_p"] = autoCfg["top_p"];
                        if (autoCfg.Contains("max_tokens")) config2["max_tokens"] = autoCfg["max_tokens"];
                    }
                    translation = InvokeChatAPI(tmo,
                        (string)sync["OutputEndpoint"],
                        (string)sync["OutputApiKey"],
                        (string)sync["OutputModel"],
                        msgs2, config2);
                }

                // 翻译失败时重试一次
                if (string.IsNullOrEmpty(translation))
                {
                    Thread.Sleep(1000);
                    if (engine == 1)
                    {
                        translation = InvokeGoogleTranslate(tmo, targetLang, processText);
                    }
                    else if (engine == 2)
                    {
                        translation = InvokeChatAPI(tmo,
                            (string)sync["OutputEndpoint"],
                            (string)sync["OutputApiKey"],
                            (string)sync["OutputModel"],
                            msgs2, config2);
                    }
                }

                if (!string.IsNullOrEmpty(translation))
                {
                    // 恢复物品链接和招募链接
                    for (int i = 0; i < itemLinks.Count; i++)
                        translation = Regex.Replace(translation, Regex.Escape("@^"), (string)itemLinks[i]);
                    for (int i = 0; i < recruitLinks.Count; i++)
                        translation = Regex.Replace(translation, Regex.Escape("@&"), (string)recruitLinks[i]);
                    translation = translation.Replace("<", "").Replace(">", "").Replace("[", "").Replace("]", "");
                    // 写文件
                    string prefix = "||||" + channel + "||||" + senderName + "||||";
                    string tB64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(translation));
                    string ts = fields.Length >= 6 ? fields[5] : "";
                    string logEntry = "{chatMsg = \"" + prefix + tB64 + "||||" + ts + "||||\"}";
                    WriteChatResultLocked((string)sync["AutoOutFile"], logEntry);

                    lock (sync.SyncRoot) { sync["AutoSent"] = (int)sync["AutoSent"] + 1; }

                    // 入缓存
                    SetCache(cache, cmax, cacheKey, translation);

                    string disp = translation;
                    Console.WriteLine("[Auto#{0}:Done] {1}:{2}", wid, senderName,
                        disp.Substring(0, Math.Min(50, disp.Length)));
                }
                else
                {
                    lock (sync.SyncRoot) { sync["Failed"] = (int)sync["Failed"] + 1; }
                    Console.WriteLine("[Auto#" + wid + ":Error]");
                }
            }
            catch (Exception ex)
            {
                lock (sync.SyncRoot) { sync["Failed"] = (int)sync["Failed"] + 1; }
                Console.WriteLine("[Auto#" + wid + ":Error] " + ex.Message);
            }
        }
    }

    // ========== Native P/Invoke 辅助类 ==========
    private static class NativeWin32
    {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int count);
        [DllImport("user32.dll")]
        public static extern IntPtr SendMessageA(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")]
        public static extern bool OpenClipboard(IntPtr hWndNewOwner);
        [DllImport("user32.dll")]
        public static extern bool EmptyClipboard();
        [DllImport("user32.dll")]
        public static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);
        [DllImport("user32.dll")]
        public static extern bool CloseClipboard();
        [DllImport("kernel32.dll")]
        public static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);
        [DllImport("kernel32.dll")]
        public static extern IntPtr GlobalLock(IntPtr hMem);
        [DllImport("kernel32.dll")]
        public static extern bool GlobalUnlock(IntPtr hMem);
        [DllImport("kernel32.dll")]
        public static extern IntPtr GlobalFree(IntPtr hMem);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GetCurrentProcess();
        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool GetTokenInformation(IntPtr TokenHandle, int TokenInformationClass, IntPtr TokenInformation, int TokenInformationLength, out int ReturnLength);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern void CloseHandle(IntPtr hObject);
        [DllImport("shell32.dll")]
        public static extern int SHQueryUserNotificationState(out QUERY_USER_NOTIFICATION_STATE pquns);
    }

    public enum QUERY_USER_NOTIFICATION_STATE
    {
        NOT_PRESENT = 1,
        BUSY = 2,
        RUNNING_D3D_FULL_SCREEN = 3,
        PRESENTATION_MODE = 4,
        ACCEPTS_NOTIFICATIONS = 5,
        QUIET_TIME = 6,
        APP_IMMERSIVE = 7
    }

    // ========== 配置读取 ==========
    public static void ReadConfig(Hashtable sync)
    {
        try
        {
            string path = (string)sync["ConfigFilePath"];
            string raw = File.ReadAllText(path, Encoding.UTF8);
            var cfg = new Hashtable();
            if (!string.IsNullOrEmpty(raw))
            {
                var matches = Regex.Matches(raw, @"(\w+)\s*=\s*""?([^"",}\s]+)""?");
                foreach (Match m in matches)
                    cfg[m.Groups[1].Value] = m.Groups[2].Value;
            }
            if (cfg.ContainsKey("inputBaseURL"))    sync["InputEndpoint"] = cfg["inputBaseURL"];
            if (cfg.ContainsKey("inputApiKey"))     sync["InputApiKey"] = cfg["inputApiKey"];
            if (cfg.ContainsKey("inputModelName"))  sync["InputModel"] = ((string)cfg["inputModelName"]).ToLower();
            if (cfg.ContainsKey("outputBaseURL"))   sync["OutputEndpoint"] = cfg["outputBaseURL"];
            if (cfg.ContainsKey("outputApiKey"))    sync["OutputApiKey"] = cfg["outputApiKey"];
            if (cfg.ContainsKey("outputModelName")) sync["OutputModel"] = ((string)cfg["outputModelName"]).ToLower();
            if (cfg.ContainsKey("translateEngine")) sync["TranslateEngine"] = int.Parse((string)cfg["translateEngine"]);
            Console.WriteLine("[Config] Reloaded Config.ini");
        }
        catch (Exception ex)
        {
            Console.WriteLine("[Config] Error: " + ex.Message);
        }
    }

    // ========== 字典转 Hashtable（递归） ==========
    private static object DeepToHashtable(object obj)
    {
        var dict = obj as Dictionary<string, object>;
        if (dict != null)
        {
            var ht = new Hashtable();
            foreach (var kv in dict)
                ht[kv.Key] = DeepToHashtable(kv.Value);
            return ht;
        }
        var arr = obj as object[];
        if (arr != null)
        {
            var list = new ArrayList(arr.Length);
            for (int i = 0; i < arr.Length; i++)
                list.Add(DeepToHashtable(arr[i]));
            return list;
        }
        var list2 = obj as ArrayList;
        if (list2 != null)
        {
            for (int i = 0; i < list2.Count; i++)
                list2[i] = DeepToHashtable(list2[i]);
            return list2;
        }
        return obj;
    }

    // ========== 创建共享数据 ==========
    public static Hashtable CreateSync()
    {
        var sync = Hashtable.Synchronized(new Hashtable());

        // 数据字段
        sync["StopFlag"] = false;
        sync["NewAutoMessage"] = null;
        sync["NewAutoReady"] = false;
        sync["PendingMessages"] = ArrayList.Synchronized(new ArrayList());
        sync["Cache"] = Hashtable.Synchronized(new Hashtable());
        sync["CacheMaxSize"] = 100;
        sync["AutoWorkQueue"] = Queue.Synchronized(new Queue());
        sync["ManualWorkQueue"] = Queue.Synchronized(new Queue());

        // 文件路径
        sync["AutoFilePath"] = ".\\cache\\chat_source";
        sync["RequestFilePath"] = ".\\cache\\manual_request";
        sync["ManualOutFile"] = ".\\cache\\manual_response";
        sync["AutoOutFile"] = Path.GetFullPath(".\\cache\\chat_result");
        sync["ConfigFilePath"] = Path.GetFullPath(".\\config.ini");
        sync["SendResultFile"] = Path.GetFullPath(".\\cache\\send_result");

        // 配置参数
        sync["HttpTimeoutSec"] = 5;
        sync["RetryIntervalSec"] = 5;
        sync["MaxConcurrent"] = 4;
        sync["SendToGameReady"] = false;
        sync["SendResultContent"] = null;
        sync["TranslateEngine"] = 1;
        sync["InputEndpoint"] = "";
        sync["InputApiKey"] = "";
        sync["InputModel"] = "";
        sync["OutputEndpoint"] = "";
        sync["OutputApiKey"] = "";
        sync["OutputModel"] = "";

        // 统计
        sync["AutoFound"] = 0;
        sync["AutoCached"] = 0;
        sync["AutoSent"] = 0;
        sync["ManualSent"] = 0;
        sync["AutoSkipped"] = 0;
        sync["Failed"] = 0;

        // 加载 ai_prompts.json
        try
        {
            string promptFile = ".\\ai_prompts.json";
            string raw = File.ReadAllText(promptFile, Encoding.UTF8);
            var jss = new System.Web.Script.Serialization.JavaScriptSerializer();
            jss.MaxJsonLength = int.MaxValue;
            var deserialized = jss.DeserializeObject(raw);
            sync["AiPrompts"] = DeepToHashtable(deserialized);
            Console.WriteLine("[Config] Loaded ai_prompts.json");
        }
        catch (Exception ex)
        {
            Console.WriteLine("[Config] Load ai_prompts.json Error: " + ex.Message);
        }

        // 读取 config.ini
        ReadConfig(sync);

        return sync;
    }

    // ========== 一站式入口：C# 内部管理完整生命周期（含 Ctrl+C 处理） ==========
    public static void Start()
    {
        Console.CancelKeyPress += (sender, args) =>
        {
            args.Cancel = true;
            _running = false;
        };

        var sync = CreateSync();
        try
        {
            StartAll(sync);
            while (_running)
            {
                try { if ((bool)sync["StopFlag"]) break; } catch { break; }
                Thread.Sleep(500);
            }
        }
        finally
        {
            CleanupAll(sync);
        }
    }

    // ========== 缓存命中写入 ==========
    public static void WriteCacheHit(Hashtable sync, string msg, Hashtable entry)
    {
        try
        {
            string[] fields = msg.Split(new[] { "||||" }, StringSplitOptions.None);
            string channel = fields.Length >= 2 ? fields[1] : "";
            string sender = fields.Length >= 3 ? fields[2] : "";
            string translation = (string)entry["translation"];
            string b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(translation));
            string ts = fields.Length >= 6 ? fields[5] : "";
            string output = "{chatMsg = \"||||" + channel + "||||" + sender + "||||" + b64 + "||||" + ts + "||||\"}";
            WriteChatResultLocked((string)sync["AutoOutFile"], output);
            lock (sync.SyncRoot) { sync["AutoCached"] = (int)sync["AutoCached"] + 1; }
            Console.WriteLine("[Auto:Cache] " + translation.Substring(0, Math.Min(50, translation.Length)));
        }
        catch (Exception ex)
        {
            Console.WriteLine("[Auto:CacheWriteError] " + ex.Message);
        }
    }

    // ========== Admin检测 ==========
    private const int TokenElevation = 20;
    private const uint TOKEN_QUERY = 0x0008;

    public static bool TestAdmin()
    {
        IntPtr hToken;
        if (!NativeWin32.OpenProcessToken(NativeWin32.GetCurrentProcess(), TOKEN_QUERY, out hToken))
            return false;
        try
        {
            IntPtr elevation = Marshal.AllocHGlobal(4);
            try
            {
                int retLen;
                if (!NativeWin32.GetTokenInformation(hToken, TokenElevation, elevation, 4, out retLen))
                    return false;
                return Marshal.ReadInt32(elevation) != 0;
            }
            finally { Marshal.FreeHGlobal(elevation); }
        }
        finally { NativeWin32.CloseHandle(hToken); }
    }

    // ========== 发送到游戏窗口 ==========
    public static void SendToGame(Hashtable sync, string sendData)
    {
        try
        {
            if (string.IsNullOrEmpty(sendData)) return;
            string[] fields = sendData.Split(new[] { "||||" }, StringSplitOptions.None);
            string sendContent = fields.Length >= 2 ? fields[1] : "";
            bool inputBoxState = fields.Length >= 3 && fields[2] == "1";
            string timestampField = fields.Length >= 5 ? fields[4] : "";
            if (!string.IsNullOrEmpty(timestampField) && timestampField.Length >= 10)
            {
                long tsSec = long.Parse(timestampField.Substring(0, 10));
                long nowSec = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                if (Math.Abs(nowSec - tsSec) > 3) return;
            }
            string sendText;
            try
            {
                byte[] sendBytes = Convert.FromBase64String(sendContent);
                sendText = Encoding.UTF8.GetString(sendBytes);
            }
            catch { return; }
            if (string.IsNullOrEmpty(sendText)) return;

            IntPtr hwnd = NativeWin32.GetForegroundWindow();
            var sbTitle = new StringBuilder(256);
            var sbClass = new StringBuilder(256);
            NativeWin32.GetWindowText(hwnd, sbTitle, 256);
            NativeWin32.GetClassName(hwnd, sbClass, 256);
            if (sbClass.ToString() != "ArcheAge" && !sbTitle.ToString().Contains("ArcheAge")) return;

            byte[] bytes = Encoding.Unicode.GetBytes(sendText + "\0");
            IntPtr hMem = NativeWin32.GlobalAlloc(0x0042, (UIntPtr)(ulong)bytes.Length);
            if (hMem == IntPtr.Zero) return;
            bool clipOpen = false;
            try
            {
                IntPtr pMem = NativeWin32.GlobalLock(hMem);
                if (pMem == IntPtr.Zero) return;
                Marshal.Copy(bytes, 0, pMem, bytes.Length);
                NativeWin32.GlobalUnlock(hMem);
                for (int retry = 0; retry < 10; retry++)
                {
                    if (NativeWin32.OpenClipboard(IntPtr.Zero)) { clipOpen = true; break; }
                    Thread.Sleep(50);
                }
                if (!clipOpen) return;
                NativeWin32.EmptyClipboard();
                NativeWin32.SetClipboardData(13, hMem);
                NativeWin32.CloseClipboard();
            }
            finally
            {
                if (!clipOpen) NativeWin32.GlobalFree(hMem);
            }

            const uint WM_ACTIVATE = 0x0006;
            const uint WM_KEYDOWN = 0x0100;
            const uint WM_KEYUP = 0x0101;
            const int VK_RETURN = 0x0D;
            const int VK_CONTROL = 0x11;
            const int VK_V = 0x56;
            const int VK_SHIFT = 0x10;
            // 全屏独占模式下 DirectX 接管了输入，不需要发 WM_ACTIVATE 重置状态
            QUERY_USER_NOTIFICATION_STATE nState;
            bool isFullscreen = NativeWin32.SHQueryUserNotificationState(out nState) == 0
                             && nState == QUERY_USER_NOTIFICATION_STATE.RUNNING_D3D_FULL_SCREEN;
            if (!isFullscreen)
            {
                NativeWin32.SendMessageA(hwnd, WM_ACTIVATE, IntPtr.Zero, IntPtr.Zero);
            }
            NativeWin32.SendMessageA(hwnd, WM_KEYUP, (IntPtr)VK_SHIFT, IntPtr.Zero);
            if (inputBoxState)
            {
                // 输入框状态为true.那么先关闭了再等待100ms
                NativeWin32.SendMessageA(hwnd, WM_KEYDOWN, (IntPtr)VK_RETURN, IntPtr.Zero);
                NativeWin32.SendMessageA(hwnd, WM_KEYUP, (IntPtr)VK_RETURN, IntPtr.Zero);
                Thread.Sleep(100);
            }
            Thread.Sleep(50);
            //打开 输入框
            NativeWin32.SendMessageA(hwnd, WM_KEYDOWN, (IntPtr)VK_RETURN, IntPtr.Zero);
            NativeWin32.SendMessageA(hwnd, WM_KEYUP, (IntPtr)VK_RETURN, IntPtr.Zero);
            Thread.Sleep(100);
            //按下ctrl+v发送内容再释放ctrl+v
            NativeWin32.SendMessageA(hwnd, WM_KEYDOWN, (IntPtr)VK_CONTROL, IntPtr.Zero);
            NativeWin32.SendMessageA(hwnd, WM_KEYDOWN, (IntPtr)VK_V, IntPtr.Zero);
            NativeWin32.SendMessageA(hwnd, WM_KEYUP, (IntPtr)VK_V, IntPtr.Zero);
            NativeWin32.SendMessageA(hwnd, WM_KEYUP, (IntPtr)VK_CONTROL, IntPtr.Zero);
            Thread.Sleep(30);
            //按下enter发送内容
            NativeWin32.SendMessageA(hwnd, WM_KEYDOWN, (IntPtr)VK_RETURN, IntPtr.Zero);
            NativeWin32.SendMessageA(hwnd, WM_KEYUP, (IntPtr)VK_RETURN, IntPtr.Zero);
        }
        catch (Exception ex)
        {
            Console.WriteLine("[SendToGame:Error] " + ex.Message);
        }
    }

    // ========== 主线程 ==========
    private static void MainProc(object state)
    {
        var sync = (Hashtable)state;
        var cache = (Hashtable)sync["Cache"];
        var autoQ = (Queue)sync["AutoWorkQueue"];
        var pending = (ArrayList)sync["PendingMessages"];

        while (!ShouldStop(sync))
        {
            // 1. 检查自动消息信号
            try
            {
                if ((bool)sync["NewAutoReady"])
                {
                    string msg = (string)sync["NewAutoMessage"];
                    sync["NewAutoReady"] = false;
                    sync["NewAutoMessage"] = null;

                    string[] fields = msg.Split(new[] { "||||" }, StringSplitOptions.None);
                    string cacheKey = fields.Length >= 4 ? fields[3] : msg;

                    lock (cache.SyncRoot)
                    {
                        if (cache.ContainsKey(cacheKey))
                        {
                            var entry = (Hashtable)cache[cacheKey];
                            entry["hitCount"] = (int)entry["hitCount"] + 1;
                            entry["lastHit"] = DateTime.Now;
                            WriteCacheHit(sync, msg, entry);
                        }
                        else
                        {
                            string msgText = cacheKey;
                            if (fields.Length >= 4) { try { msgText = Encoding.UTF8.GetString(Convert.FromBase64String(fields[3])); } catch { } }
                            string targetLang = fields.Length >= 5 ? fields[4] : "en";
                            if (string.IsNullOrEmpty(targetLang)) targetLang = "en";
                            if (NeedTranslate(msgText, targetLang))
                            {
                                lock (sync.SyncRoot) { pending.Add(msg); }
                                Console.WriteLine("[Auto:Cache] Add: {0}", msgText.Substring(0, Math.Min(50, msgText.Length)));
                            }
                        }
                    }
                }
            }
            catch (Exception ex) { Console.WriteLine("[ERR:AutoMsg] {0}: {1}", ex.GetType().Name, ex.Message); }

            // 3. 检查发送游戏信号
            try
            {
                if ((bool)sync["SendToGameReady"])
                {
                    sync["SendToGameReady"] = false;
                    string sendData = (string)sync["SendResultContent"];
                    sync["SendResultContent"] = null;
                    SendToGame(sync, sendData);
                }
            }
            catch (Exception ex) { Console.WriteLine("[ERR:SendToGame] {0}: {1}", ex.GetType().Name, ex.Message); }

            // 4. 处理待翻译数组
            try
            {
                lock (sync.SyncRoot)
                {
                    while (pending.Count > 0)
                    {
                        string msg = (string)pending[0];
                        pending.RemoveAt(0);

                        string[] fields2 = msg.Split(new[] { "||||" }, StringSplitOptions.None);
                        string cacheKey2 = fields2.Length >= 4 ? fields2[3] : msg;

                        lock (cache.SyncRoot)
                        {
                            if (cache.ContainsKey(cacheKey2))
                            {
                                var entry = (Hashtable)cache[cacheKey2];
                                entry["hitCount"] = (int)entry["hitCount"] + 1;
                                entry["lastHit"] = DateTime.Now;
                                WriteCacheHit(sync, msg, entry);
                                continue;
                            }
                        }

                        lock (autoQ.SyncRoot) { autoQ.Enqueue(msg); }
                    }
                }
            }
            catch (Exception ex) { Console.WriteLine("[ERR:Pending] {0}: {1}", ex.GetType().Name, ex.Message); }

            Thread.Sleep(50);
        }
    }
}

'@ -ErrorAction SilentlyContinue

mode con: cols=100 lines=30
[CSharpWorkers]::Start()