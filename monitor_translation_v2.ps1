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
$mutexName = "Global\AAFreeTranslation_Monitor_v2"

# 初始化
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName "System.Web"
Add-Type -AssemblyName "System.Web.Extensions"
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -Name Win32 -Namespace Native -MemberDefinition @'
[DllImport("user32.dll")]
public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")]
public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
[DllImport("user32.dll")]
public static extern uint GetClassName(IntPtr hWnd, System.Text.StringBuilder className, int count);
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
[DllImport("kernel32.dll", SetLastError=true)]
public static extern IntPtr GetCurrentProcess();
[DllImport("advapi32.dll", SetLastError=true)]
public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
[DllImport("advapi32.dll", SetLastError=true)]
public static extern bool GetTokenInformation(IntPtr TokenHandle, int TokenInformationClass, IntPtr TokenInformation, int TokenInformationLength, out int ReturnLength);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern void CloseHandle(IntPtr hObject);
'@ -ErrorAction SilentlyContinue

$trayFormsPath = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Windows.Forms' } | ForEach-Object { $_.Location } | Where-Object { $_ -and $_ -ne '' } | Select-Object -First 1
$trayDrawingPath = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Drawing' } | ForEach-Object { $_.Location } | Where-Object { $_ -and $_ -ne '' } | Select-Object -First 1
if (-not $trayDrawingPath) {
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    $trayDrawingPath = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Drawing' } | ForEach-Object { $_.Location } | Where-Object { $_ -and $_ -ne '' } | Select-Object -First 1
}

Add-Type -ReferencedAssemblies $trayFormsPath,$trayDrawingPath -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
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
    private static Timer _pollTimer;
    private static bool _initialized = false;

    public static void Initialize()
    {
        if (_initialized) return;
        _initialized = true;

        _hWnd = GetConsoleWindow();
        if (_hWnd == IntPtr.Zero) return;

        System.Threading.Thread staThread = new System.Threading.Thread(StaWorker);
        staThread.IsBackground = true;
        staThread.SetApartmentState(System.Threading.ApartmentState.STA);
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

        _pollTimer = new Timer();
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
'@ -ErrorAction SilentlyContinue

[Console]::OutputEncoding = [Text.Encoding]::UTF8

# 全局配置
[string]$AutoFilePath         = ".\cache\chat_source"
[string]$RequestFilePath      = ".\cache\manual_request"
[string]$ManualOutFile        = ".\cache\manual_response"
[string]$AutoOutFile           = ".\cache\chat_result"
[string]$ConfigFile           = ".\config.ini"
[string]$PromptFile           = ".\ai_prompts.json"
[string]$SendResultFile        = ".\cache\send_result"
[int]$MaxConcurrentThreads    = 4
[int]$CacheMaxSize            = 100
[int]$HttpTimeoutSec          = 60
[int]$RetryIntervalSec        = 5
mode con: cols=100 lines=30
# 从 config.ini 读取 AI 配置（Lua 表格式，区分 input/output）
# config.ini 在 $sync 初始化后通过 Read-Config 加载

# 从 ai_prompts.json 读取提示词配置
$AiPrompts = $null
try {
    $rawJson = [System.IO.File]::ReadAllText($PromptFile, [System.Text.UTF8Encoding]::new($false))
    $jss = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $jss.MaxJsonLength = [int]::MaxValue
    $AiPrompts = $jss.DeserializeObject($rawJson)
    [System.Console]::WriteLine("[ConFig] Loaded Done $PromptFile")
} catch {
    [System.Console]::WriteLine("[ConFig] ReadFile: $PromptFile Error: $_")
}
if (-not $AiPrompts) {
    [System.Console]::WriteLine("[ConFig] $PromptFile Prompt not loaded. Using default prompt.")
}

# ============================================================
# 管理员权限检测
# ============================================================
function Test-Admin {
    $hToken = [IntPtr]::Zero
    try {
        if (-not [Native.Win32]::OpenProcessToken([Native.Win32]::GetCurrentProcess(),0x0008,[ref] $hToken)) {return $false}
        $pElevation = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        try {
            $returnLength = 0
            if (-not [Native.Win32]::GetTokenInformation($hToken,20,$pElevation,4,[ref] $returnLength)) {return $false}
            $elevated = [System.Runtime.InteropServices.Marshal]::ReadInt32($pElevation) -ne 0
            return $elevated
        } finally {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($pElevation)
        }
    } finally {
        if ($hToken -ne [IntPtr]::Zero) {
            [Native.Win32]::CloseHandle($hToken)
        }
    }
}

# ============================================================
# 发送内容函数
# ============================================================
function Send-ToGame {
    param([string]$sendData)
    try {
        [System.Console]::WriteLine("[SendToGame] Enter")
        #if (-not $sync.IsAdmin) { return }
        [System.Console]::WriteLine($data)
        # $sendData 已经是文件内容，不需要再读文件
        $data = $sendData
        if ([string]::IsNullOrEmpty($data)) { return }

        # 解析字段
        $fields = $data -split '\|\|\|\|'
        $sendContent = if ($fields.Count -ge 2) { $fields[1] } else { "" }
        $inputBoxState = if ($fields.Count -ge 3) { $fields[2] -eq "1" } else { $false }
        $targetLang = if ($fields.Count -ge 4) { $fields[3] } else { "" }

        # 时间戳验证（13位时间戳，取前10位秒数与当前时间比较，超过3秒则丢弃）
        $timestampField = if ($fields.Count -ge 5) { $fields[4] } else { "" }
        if (-not [string]::IsNullOrEmpty($timestampField) -and $timestampField.Length -ge 10) {
            $tsSec = [long]$timestampField.Substring(0, 10)
            $nowSec = [DateTimeOffset]::Now.ToUnixTimeSeconds()
            [System.Console]::WriteLine("[SendToGame] TimeDiff: {0}s" -f ($nowSec - $tsSec))
            if ([Math]::Abs($nowSec - $tsSec) -gt 3) { 
                [System.Console]::WriteLine("[SendToGame] TimeOut 3s")
                return 
            }

        }

        # Base64 解码
        $sendText = ""
        if (-not [string]::IsNullOrEmpty($sendContent)) {
            try {
                $sendBytes = [Convert]::FromBase64String($sendContent)
                $sendText = [System.Text.Encoding]::UTF8.GetString($sendBytes)
            } catch { return }
        } else { return }
        [System.Console]::WriteLine("[SendToGame] SendText: $sendText")

        # 根据语言判断是否需要发送原文（翻译不完整时）
        # $targetLang 可能为 zh、en、ru
        # 这里先留空，用户补充逻辑

        # 获取前台窗口
        $hwnd = [Native.Win32]::GetForegroundWindow()
        $sbTitle = [System.Text.StringBuilder]::new(256)
        $sbClass = [System.Text.StringBuilder]::new(256)
        [Native.Win32]::GetWindowText($hwnd, $sbTitle, 256) | Out-Null
        [Native.Win32]::GetClassName($hwnd, $sbClass, 256) | Out-Null
        $fgTitle = $sbTitle.ToString()
        $fgClass = $sbClass.ToString()

        if ($fgClass -ne "ArcheAge" -or $fgTitle -notmatch "ArcheAge") { return }

        # 放入剪贴板（带重试，防止瞬间被占用）
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($sendText + "`0")
        $hMem = [Native.Win32]::GlobalAlloc(0x0042, [UIntPtr]::new($bytes.Length))
        if ($hMem -eq [IntPtr]::Zero) { return }
        try {
            $pMem = [Native.Win32]::GlobalLock($hMem)
            if ($pMem -eq [IntPtr]::Zero) { return }
            [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $pMem, $bytes.Length)
            [Native.Win32]::GlobalUnlock($hMem) | Out-Null

            $clipOpen = $false
            for ($retry = 0; $retry -lt 10; $retry++) {
                if ([Native.Win32]::OpenClipboard([IntPtr]::Zero)) {
                    $clipOpen = $true
                    break
                }
                [System.Threading.Thread]::Sleep(50)
            }
            if (-not $clipOpen) { return }

            [Native.Win32]::EmptyClipboard() | Out-Null
            [Native.Win32]::SetClipboardData(13, $hMem) | Out-Null
            [Native.Win32]::CloseClipboard() | Out-Null
        } finally {
            # 如果剪贴板打开失败，hMem 需要释放
            if (-not $clipOpen) {
                [Native.Win32]::GlobalFree($hMem) | Out-Null
            }
            # 注意：如果 SetClipboardData 成功，剪贴板接管了 hMem，不能再释放
        }
        $WM_ACTIVATE = 0x0006
        $WM_KEYDOWN  = 0x0100
        $WM_KEYUP    = 0x0101
        $VK_RETURN   = 0x0D
        $VK_CONTROL  = 0x11
        $VK_V        = 0x56
        $VK_SHIFT    = 0x10
        [System.Threading.Thread]::Sleep(50)
        [System.Console]::WriteLine("[SendToGame] TO Game")
        # 激活窗口
        $null = [Native.Win32]::SendMessageA($hwnd, $WM_ACTIVATE, [IntPtr]::Zero, [IntPtr]::Zero)
        # 放开 Shift 键
        $null = [Native.Win32]::SendMessageA($hwnd, $WM_KEYUP, [IntPtr]$VK_SHIFT, [IntPtr]::Zero)
        # 如果编辑框已开启，先关再开
        if ($inputBoxState) {
            $null = [Native.Win32]::SendMessageA($hwnd, $WM_KEYDOWN, [IntPtr]$VK_RETURN, [IntPtr]::Zero)
            $null = [Native.Win32]::SendMessageA($hwnd, $WM_KEYUP,   [IntPtr]$VK_RETURN, [IntPtr]::Zero)
            [System.Threading.Thread]::Sleep(100)
        }
        [System.Threading.Thread]::Sleep(50)
        
        # 回车（打开聊天框）
        $null = [Native.Win32]::SendMessageA($hwnd, $WM_KEYDOWN, [IntPtr]$VK_RETURN, [IntPtr]::Zero)
        $null = [Native.Win32]::SendMessageA($hwnd, $WM_KEYUP,   [IntPtr]$VK_RETURN, [IntPtr]::Zero)

        [System.Threading.Thread]::Sleep(80)

        # 安全释放 V 键
        $null = [Native.Win32]::SendMessageA($hwnd, $WM_KEYUP,   [IntPtr]$VK_V, [IntPtr]::Zero)
        # Ctrl + V：Ctrl 按下 → V 按下 → V 释放 → Ctrl 释放
        $null = [Native.Win32]::SendMessageA($hwnd, $WM_KEYDOWN, [IntPtr]$VK_CONTROL, [IntPtr]::Zero)
        $null = [Native.Win32]::SendMessageA($hwnd, $WM_KEYDOWN, [IntPtr]$VK_V, [IntPtr]::Zero)
        $null = [Native.Win32]::SendMessageA($hwnd, $WM_KEYUP,   [IntPtr]$VK_V, [IntPtr]::Zero)
        $null = [Native.Win32]::SendMessageA($hwnd, $WM_KEYUP,   [IntPtr]$VK_CONTROL, [IntPtr]::Zero)

        [System.Threading.Thread]::Sleep(50)

        # 回车（发送）
        $null = [Native.Win32]::SendMessageA($hwnd, $WM_KEYDOWN, [IntPtr]$VK_RETURN, [IntPtr]::Zero)
        $null = [Native.Win32]::SendMessageA($hwnd, $WM_KEYUP,   [IntPtr]$VK_RETURN, [IntPtr]::Zero)
        [System.Console]::WriteLine("[SendToGame] END")
    } catch { $null = $_ }
}

# ============================================================
# 翻译工具函数 (from google_translate.ps1)
# ============================================================

function NeedTranslate {
    param ([string]$text, [string]$lang)
    $cleanText = $text -replace '@\^', ''
    if ($cleanText.Trim() -eq "") { return $false }
    if ($cleanText -match '^[0-9\s\p{P}\p{S}]+$') { return $false }
    $charCount = 0
    $langCounts = @{ en = 0; zh = 0; ru = 0 }
    foreach ($c in $cleanText.ToCharArray()) {
        $code = [int]$c
        if      ($code -ge 0x4E00 -and $code -le 0x9FFF) { $langCounts.zh++; $charCount++ }
        elseif  ($code -ge 0x0400 -and $code -le 0x04FF) { $langCounts.ru++; $charCount++ }
        elseif (($code -ge 0x41 -and $code -le 0x5A) -or ($code -ge 0x61 -and $code -le 0x7A)) { $langCounts.en++; $charCount++ }
    }
    if ($charCount -eq 0) { return $false }
    $detectedLang = $null; $maxCount = -1
    foreach ($entry in $langCounts.GetEnumerator()) {
        if ($entry.Value -gt $maxCount) { $maxCount = $entry.Value; $detectedLang = $entry.Key }
    }
    return $detectedLang -ne $lang
}

function GetItemLinkCount {
    param ([ref]$text, [string]$replaceWith, [ref]$replacedItems, [string]$pattern)
    $matchResults = [regex]::Matches($text.Value, $pattern)
    if ($PSBoundParameters.ContainsKey('replacedItems')) {
        $replacedItems.Value = @()
        foreach ($m in $matchResults) { $replacedItems.Value += $m.Value }
    }
    if ($PSBoundParameters.ContainsKey('replaceWith')) {
        $text.Value = [regex]::Replace($text.Value, $pattern, $replaceWith)
    }
    return $matchResults.Count
}
# ============================================================
# 缓存辅助函数
# ============================================================
function Add-ToCache {
    param ([hashtable]$cache, [string]$key, [string]$translation, [int]$maxSize)
    if ($cache.ContainsKey($key)) { return }
    if ($cache.Count -ge $maxSize) {
        $newestKey = $null; $newestHitCount = 0; $newestTime = [DateTime]::MinValue
        $secondNewestKey = $null; $secondNewestTime = [DateTime]::MinValue
        foreach ($entry in $cache.GetEnumerator()) {
            $t = $entry.Value.lastHit
            if ($t -gt $newestTime) {
                $secondNewestKey = $newestKey; $secondNewestTime = $newestTime
                $newestKey = $entry.Key; $newestHitCount = $entry.Value.hitCount; $newestTime = $t
            } elseif ($t -gt $secondNewestTime) {
                $secondNewestKey = $entry.Key; $secondNewestTime = $t
            }
        }
        if ($newestHitCount -ge 3 -and $cache.Count -gt 1) {
            $cache.Remove($secondNewestKey)
        } else {
            $cache.Remove($newestKey)
        }
    }
    $cache[$key] = @{
        translation = $translation
        hitCount    = 0
        lastHit     = [DateTime]::Now
    }
}

# ============================================================
# 共享数据
# ============================================================
$sync = [Hashtable]::Synchronized(@{})
$sync.StopFlag           = $false
$sync.NewAutoMessage     = $null       # 文件线程 → 主线程：新的自动消息
$sync.NewAutoReady       = $false      # 自动消息信号
# $sync.ActiveThreadCount 已废弃（改用固定 3+1 工作线程）
$sync.PendingMessages    = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
$sync.StatusMessages     = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())  # Runspace → 主线程 状态消息
$sync.Cache              = [Hashtable]::Synchronized(@{})  # 翻译缓存
$sync.CacheMaxSize       = $CacheMaxSize
$sync.AutoWorkQueue      = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())   # 自动翻译工作队列
$sync.ManualWorkQueue    = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())   # 手动翻译工作队列

$sync.AutoFilePath     = $AutoFilePath
$sync.RequestFilePath  = $RequestFilePath
$sync.ManualOutFile = $ManualOutFile

$sync.HttpTimeoutSec  = $HttpTimeoutSec
$sync.RetryIntervalSec = $RetryIntervalSec
$sync.MaxConcurrent   = $MaxConcurrentThreads
$sync.AiPrompts       = $AiPrompts
$sync.AutoOutFile     = [System.IO.Path]::GetFullPath($AutoOutFile)
$sync.ConfigFilePath  = [System.IO.Path]::GetFullPath($ConfigFile)
$sync.SendResultFile = [System.IO.Path]::GetFullPath($SendResultFile)
$sync.SendToGame     = ${function:Send-ToGame}
$sync.SendToGameReady = $false
$sync.SendResultContent = $null

function Read-Config {
    param([hashtable]$sync)
    try {
        $cfg = @{}
    $raw = [System.IO.File]::ReadAllText($sync.ConfigFilePath, [System.Text.UTF8Encoding]::new($false))
    if ($raw) {
        $matchedItems = [regex]::Matches($raw, '(\w+)\s*=\s*"?([^",}\s]+)"?')
        foreach ($m in $matchedItems) {
            $cfg[$m.Groups[1].Value] = $m.Groups[2].Value
        }
    }
        if ($cfg['inputBaseURL'])   { $sync.InputEndpoint = $cfg['inputBaseURL'] }
        if ($cfg['inputApiKey'])    { $sync.InputApiKey   = $cfg['inputApiKey'] }
        if ($cfg['inputModelName']) { $sync.InputModel    = $cfg['inputModelName'].ToLower() }
        if ($cfg['outputBaseURL'])  { $sync.OutputEndpoint = $cfg['outputBaseURL'] }
        if ($cfg['outputApiKey'])   { $sync.OutputApiKey   = $cfg['outputApiKey'] }
        if ($cfg['outputModelName']){ $sync.OutputModel    = $cfg['outputModelName'].ToLower() }
        if ($cfg['translateEngine']){ $sync.TranslateEngine = [int]$cfg['translateEngine'] }
        $sync.StatusMessages.Enqueue("[Config] Reloaded Config.ini")
    } catch {
        $sync.StatusMessages.Enqueue("[Config] Error: $_")
    }
}
$sync.ReadConfig = ${function:Read-Config}

# 加载配置（不校验 key，客户端后续更新）
Read-Config -sync $sync

# 统计
$sync.AutoFound   = 0
$sync.AutoCached  = 0
$sync.AutoSent    = 0
$sync.ManualSent  = 0
$sync.AutoSkipped = 0
$sync.Failed      = 0

# 共享函数
$sync.NeedTranslate = ${function:NeedTranslate}

function Invoke-ChatAPI {
    param($sync, $endpoint, $apiKey, $model, $messages, $config)
    $body = @{ model = $model; messages = $messages }
    if ($config) {
        if ($config.temperature) { $body.temperature = $config.temperature }
        if ($config.top_p)       { $body.top_p = $config.top_p }
        if ($config.max_tokens)  { $body.max_tokens = $config.max_tokens }
    }
    if ($model -like '*deepseek*') { $body.thinking = @{ type = "disabled" } }
    $jss = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $jss.MaxJsonLength = [int]::MaxValue
    $jsonBody = $jss.Serialize($body)
    $utf8Body = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
    try {
        $req = [System.Net.WebRequest]::Create($endpoint)
        $req.Method = "POST"
        $req.ContentType = "application/json; charset=utf-8"
        $req.Headers.Add("Authorization", "Bearer $apiKey")
        $req.Timeout = $sync.HttpTimeoutSec * 1000
        $reqStream = $req.GetRequestStream()
        $reqStream.Write($utf8Body, 0, $utf8Body.Length)
        $reqStream.Dispose()
        $resp = $req.GetResponse()
        $reader = [System.IO.StreamReader]::new($resp.GetResponseStream())
        $jsonResult = $reader.ReadToEnd()
        $reader.Dispose()
        $resp.Dispose()
        $deserialized = $jss.DeserializeObject($jsonResult)
        $text = $deserialized['choices'][0]['message']['content']
        return ($text.Trim() -replace '^\[|\]$', '')
    } catch { 
        [System.Console]::WriteLine("[ChatAPI:Error] $_")
        return $null 
    }
}
$sync.InvokeChatAPI = ${function:Invoke-ChatAPI}

function Invoke-GoogleTranslate {
    param($sync, [string]$targetLang, [string]$text)
    try {
        $uri = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=$targetLang&dt=t&q=$([System.Web.HttpUtility]::UrlEncode($text))"
        $req = [System.Net.WebRequest]::Create($uri)
        $req.Timeout = 5000
        $req.Method = "GET"
        $resp = $req.GetResponse()
        $reader = [System.IO.StreamReader]::new($resp.GetResponseStream())
        $json = $reader.ReadToEnd()
        $reader.Dispose()
        $resp.Dispose()
        if ($json -match '\[\[\["([^"]*)"' -and $Matches[1]) { return $Matches[1] }
        return ""
    } catch [System.Net.WebException] {
        try { $sync.StatusMessages.Enqueue("[Google:Error] Connection timeout (5s)") } catch { $null = $_ }
        return $null
    } catch {
        try { $sync.StatusMessages.Enqueue(("[Google:Error] $_")) } catch { $null = $_ }
        return $null
    }
}
$sync.InvokeGoogleTranslate = ${function:Invoke-GoogleTranslate}

# ============================================================
# 手动翻译工作线程代码（1 个常驻 Runspace，从 ManualWorkQueue 取消息）
# ============================================================
$manualWorkerCode = {
    param($sync)

    while (-not $sync.StopFlag) {
        $content = $null
        [System.Threading.Monitor]::Enter($sync.ManualWorkQueue.SyncRoot)
        try {
            if ($sync.ManualWorkQueue.Count -gt 0) {
                $content = $sync.ManualWorkQueue.Dequeue()
            }
        } finally {
            [System.Threading.Monitor]::Exit($sync.ManualWorkQueue.SyncRoot)
        }
        if ($null -eq $content) {
            [System.Threading.Thread]::Sleep(100)
            continue
        }

        try {
        # 解析手动请求内容
        $fields = $content -split '\|\|\|\|'
        $translateType = ""
        $playerName = ""
        $msgText = $content
        $timestamp = ""
        if ($fields.Count -ge 5) {
            $translateType = $fields[1]
            $playerName    = $fields[2]
            $msgText       = $fields[3]
            $timestamp     = $fields[4]
        }
        if ($msgText.Trim() -eq "") { continue }

        if ($translateType -eq "0" -or [int]$translateType -gt 6) {
            try {
                $errB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("[Error]"))
                $output = '{chatMsg = "||||' + $playerName + '||||' + $errB64 + '||||' + $timestamp + '||||"}'
                [System.IO.File]::WriteAllText($sync.ManualOutFile, $output, [System.Text.UTF8Encoding]::new($false))
            } catch { $null = $_ }
            continue
        }

        if ($sync.TranslateEngine -eq 2 -and -not $sync.InputApiKey) {
            $sync.StatusMessages.Enqueue("[Input:Error] No API Key configured")
            continue
        }

        $manualTargetLang = switch ([int]$translateType) {
            1 { "en" }
            2 { "ru" }
            3 { "zh" }
            4 { "ru" }
            5 { "zh" }
            6 { "en" }
            default { "en" }
        }

        # 翻译逻辑（原 Invoke-ManualRequest 内部 scriptblock）
        $manualCfg = $sync.AiPrompts.manual
        $typeCfg = $null
        if ($manualCfg.by_type) { $typeCfg = $manualCfg.by_type.$translateType }
        $systemMsg = "You are a translator. Translate the following text to $manualTargetLang. Only return the translated text, nothing else, no explanations."
        if ($typeCfg) { $systemMsg = $typeCfg.system_prompt }

        $msgs = @()
        $msgs += @{ role = "system"; content = $systemMsg }
        if ($manualCfg.examples) {
            foreach ($ex in $manualCfg.examples) {
                $msgs += @{ role = "user";      content = $ex.user }
                $msgs += @{ role = "assistant"; content = $ex.assistant }
            }
        }
        $wrapped = $msgText
        if ($manualCfg.wrap) { $wrapped = $manualCfg.wrap -replace '{text}', $msgText }
        $msgs += @{ role = "user"; content = $wrapped }

        if ($sync.TranslateEngine -eq 1) {
            $result = & $sync.InvokeGoogleTranslate -sync $sync -targetLang $manualTargetLang -text $msgText
        } elseif ($sync.TranslateEngine -eq 2) {
            $config = @{}
            if ($manualCfg.temperature) { $config.temperature = $manualCfg.temperature }
            if ($manualCfg.top_p)       { $config.top_p = $manualCfg.top_p }
            if ($manualCfg.max_tokens)  { $config.max_tokens = $manualCfg.max_tokens }
            $result = & $sync.InvokeChatAPI -sync $sync -endpoint $sync.InputEndpoint -apiKey $sync.InputApiKey -model $sync.InputModel -messages $msgs -config $config
        }

        if ($null -ne $result -and $result -ne "") {
            try {
                $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($result)
                $b64 = [Convert]::ToBase64String($utf8Bytes)
                $origBytes = [System.Text.Encoding]::UTF8.GetBytes($msgText)
                $origB64 = [Convert]::ToBase64String($origBytes)
                $output = '{chatMsg = "||||' + $playerName + '||||' + $b64 + '||||' + $origB64 + '||||' + $timestamp + '||||"}'
                [System.IO.File]::WriteAllText($sync.ManualOutFile, $output, [System.Text.UTF8Encoding]::new($false))
            } catch { $null = $_ }
            $sync.ManualSent++
            $sync.StatusMessages.Enqueue(("[Input:Done] {0}" -f $result.Substring(0, [Math]::Min(50, $result.Length))))
        } else {
            try {
                $errB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("[Error]"))
                $output = '{chatMsg = "||||' + $playerName + '||||' + $errB64 + '||||' + $timestamp + '||||"}'
                [System.IO.File]::WriteAllText($sync.ManualOutFile, $output, [System.Text.UTF8Encoding]::new($false))
            } catch { $null = $_ }
            $sync.Failed++
            $sync.StatusMessages.Enqueue("[Input:Error]")
        }
        } catch {
            $sync.Failed++
            $sync.StatusMessages.Enqueue(("[Input:Error] $_"))
        }
    }
}

# ============================================================
# Ctrl+C 直接退出
# ============================================================

# ============================================================
# 文件监视线程代码
#   监视 cache 目录内所有文件的 LastWrite 变更
#   - manual_request:   触发手动翻译（入队到 ManualWorkQueue）
#   - chat_source:      提取聊天消息 → 发信号给主线程处理
# ============================================================
$fileMonitorCode = {
    param($sync)

    # Watcher 监视 AutoFilePath 所在目录
    $autoDir = [System.IO.Path]::GetDirectoryName($sync.AutoFilePath)
    if ([string]::IsNullOrEmpty($autoDir)) { $autoDir = "." }

    $watcher = [System.IO.FileSystemWatcher]::new()
    $watcher.Path         = $autoDir
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
    $watcher.EnableRaisingEvents = $true
    $lastSendToGameTime = [DateTime]::MinValue

    $lastAutoContent     = $null
    $lastRequestContent  = $null

    # 读取文件当前内容到历史（文件不存在时初始化为空），避免首次触发翻译
    try {
        $lastRequestContent = [System.IO.File]::ReadAllText($sync.RequestFilePath, [System.Text.UTF8Encoding]::new($false)).Trim()
    } catch { $lastRequestContent = "" }
    try {
        $lastAutoContent = [System.IO.File]::ReadAllText($sync.AutoFilePath, [System.Text.UTF8Encoding]::new($false)).Trim()
    } catch { $lastAutoContent = "" }

    # 启动前检查 send_result 是否有残留内容，有则清空
    try {
        $initContent = [System.IO.File]::ReadAllText($sync.SendResultFile, [System.Text.UTF8Encoding]::new($false))
        if (-not [string]::IsNullOrEmpty($initContent.Trim('"', ' ', "`t", "`r", "`n"))) {
            [System.IO.File]::WriteAllText($sync.SendResultFile, "", [System.Text.UTF8Encoding]::new($false))
        }
    } catch { $null = $_ }

    try { $lastConfigTime = ([System.IO.FileInfo]::new($sync.ConfigFilePath)).LastWriteTime } catch { $lastConfigTime = [DateTime]::MinValue }

    while (-not $sync.StopFlag) {
        $result = $watcher.WaitForChanged('Changed', 1000)
        if ($sync.StopFlag) { break }
        try {
        if ($result.TimedOut) {
            try {
                $cfgFile = [System.IO.FileInfo]::new($sync.ConfigFilePath)
                if ($cfgFile.Exists -and $cfgFile.LastWriteTime -ne $lastConfigTime) {
                    $lastConfigTime = $cfgFile.LastWriteTime
                    & $sync.ReadConfig -sync $sync
                }
            } catch { $null = $_ }
            continue
        }

# ---- 检查 send_result（发送内容到游戏）----
        try {
            $content = [System.IO.File]::ReadAllText($sync.SendResultFile, [System.Text.UTF8Encoding]::new($false))
            $trimmed = $content.Trim('"', ' ', "`t", "`r", "`n")
            if (-not [string]::IsNullOrEmpty($trimmed)) {
                $sync.SendResultContent = $content
                [System.IO.File]::WriteAllText($sync.SendResultFile, "", [System.Text.UTF8Encoding]::new($false))
                $now = [DateTime]::Now
                if (($now - $lastSendToGameTime).TotalMilliseconds -ge 30) {
                    $lastSendToGameTime = $now
                    $sync.SendToGameReady = $true
                }
            }
        } catch { $null = $_ }
        [System.Threading.Thread]::Sleep(50)

        # ---- 检查 manual_request（内容比较，避免重复触发）----
        try {
            $content = [System.IO.File]::ReadAllText($sync.RequestFilePath, [System.Text.UTF8Encoding]::new($false))
            if ($null -ne $content) { $content = $content.Trim() }
            if ($content -ne "" -and $content -ne $lastRequestContent) {
                $lastRequestContent = $content
                $sync.ManualWorkQueue.Enqueue($content)
            }
        } catch { $null = $_ }

        # ---- 检查 chat_source（内容比较，避免重复触发）----
        try {
            $content = [System.IO.File]::ReadAllText($sync.AutoFilePath, [System.Text.UTF8Encoding]::new($false))
            if ($null -ne $content) { $content = $content.Trim() }
            $content = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::UTF8.GetBytes($content))
            if ($content -ne $lastAutoContent -and $content -ne "") {
                $lastAutoContent = $content
                $chatMsg = $content
                $autoFields = $chatMsg -split '\|\|\|\|'
                $autoText   = $autoFields[3]

                $sync.NewAutoMessage = $chatMsg
                $sync.NewAutoReady = $true
                $sync.AutoFound++
                $autoSender = if ($autoFields.Count -ge 3) { $autoFields[2] } else { "" }
                $autoDisplay = $autoText -replace '[|]?i\d+,[^,]*,[^,]*,[^;]*;', '' -replace '\|.*?;', ''
                if ($autoDisplay.Trim() -eq '') { $autoDisplay = $autoText }
                $sync.StatusMessages.Enqueue(("[Auto:NewMsg] {0}:{1}" -f $autoSender, $autoDisplay.Substring(0, [Math]::Min(50, $autoDisplay.Length))))
            }
        } catch { $null = $_ }
        } catch {
            $sync.StatusMessages.Enqueue(("[FileMonitor:Error] $_"))
        }
    }

    $watcher.Dispose()
}

# ============================================================
# 自动翻译工作线程代码（3 个常驻 Runspace，从 AutoWorkQueue 取消息）
# ============================================================
$autoWorkerCode = {
    param($sync, $workerId)
    # 用一次避免 PSReviewUnusedParameter 假阳性
    $null = $workerId

    # 翻译尝试（最多重试一次）
    function Invoke-Translate {
        param([string]$txt, [string]$targetLang)
        if ($sync.TranslateEngine -eq 1) { return (& $sync.InvokeGoogleTranslate -sync $sync -targetLang $targetLang -text $txt) }
        if ($sync.TranslateEngine -ne 2) { return $null }
        if (-not $sync.OutputApiKey) { return $null }
        $chatCfg = $sync.AiPrompts.chat
        $langCfg = $null
        if ($chatCfg.langs) { $langCfg = $chatCfg.langs[$targetLang] }
        $systemMsg = "You are a translator. Translate the following text to $targetLang. Only return the translated text, nothing else, no explanations."
        if ($langCfg) { $systemMsg = $langCfg.system_prompt }

        $msgs = @()
        $msgs += @{ role = "system"; content = $systemMsg }
        if ($langCfg.examples) {
            foreach ($ex in $langCfg.examples) {
                $msgs += @{ role = "user";      content = $ex.user }
                $msgs += @{ role = "assistant"; content = $ex.assistant }
            }
        }
        $wrapped = $txt
        if ($chatCfg.wrap) { $wrapped = $chatCfg.wrap -replace '{text}', $txt }
        $msgs += @{ role = "user"; content = $wrapped }

        $config = @{}
        if ($chatCfg.temperature) { $config.temperature = $chatCfg.temperature }
        if ($chatCfg.top_p)       { $config.top_p = $chatCfg.top_p }
        if ($chatCfg.max_tokens)  { $config.max_tokens = $chatCfg.max_tokens }
        return (& $sync.InvokeChatAPI -sync $sync -endpoint $sync.OutputEndpoint -apiKey $sync.OutputApiKey -model $sync.OutputModel -messages $msgs -config $config)
    }

    while (-not $sync.StopFlag) {
        # 从队列取消息（非阻塞，加锁保证 Count 检查和 Dequeue 原子性）
        $messageText = $null
        [System.Threading.Monitor]::Enter($sync.AutoWorkQueue.SyncRoot)
        try {
            if ($sync.AutoWorkQueue.Count -gt 0) {
                $messageText = $sync.AutoWorkQueue.Dequeue()
            }
        } finally {
            [System.Threading.Monitor]::Exit($sync.AutoWorkQueue.SyncRoot)
        }
        if ($null -eq $messageText) {
            [System.Threading.Thread]::Sleep(100)
            continue
        }

        try {
        # 提取消息内容（去掉 |||| 格式）
        $msgFields = $messageText -split "\|\|\|\|"
        $rawMessage = ""
        $channel = ""
        $senderName = ""
        $targetLang = ""
        if ($msgFields.Count -ge 4) {
            $channel    = $msgFields[1]
            $senderName = $msgFields[2]
            $rawMessage = $msgFields[3]
            if ($msgFields.Count -ge 5) { $targetLang = $msgFields[4] }
        } else {
            $rawMessage = $messageText
        }

        # 提取物品链接 → 替换为占位符 @^，翻译完恢复
        $itemLinkPattern = '[|]?i\d+,[^,]*,[^,]*,[^;]*;'
        $itemLinks = @()
        $matchedItems = [regex]::Matches($rawMessage, $itemLinkPattern)
        foreach ($m in $matchedItems) { $itemLinks += $m.Value }
        $processedMessage = [regex]::Replace($rawMessage, $itemLinkPattern, "@^")

        # 提取招募链接 → 替换为占位符 @&，翻译完恢复
        $recruitLinkPattern = '\|.*?;'
        $recruitLinks = @()
        $matchedItems = [regex]::Matches($processedMessage, $recruitLinkPattern)
        foreach ($m in $matchedItems) { $recruitLinks += $m.Value }
        $processedMessage = [regex]::Replace($processedMessage, $recruitLinkPattern, "@&")

        # 去掉占位符检查是否还有实际文本内容，如果只有链接则跳过翻译
        $textToTranslate = $processedMessage -replace '@\^', '' -replace '@&', '' -replace '\s', ''
        if ($textToTranslate -eq "") {
            $sync.AutoSkipped++
            continue
        }

        # 判断是否需要翻译（检测文本语言是否与目标语言相同）
        if (-not (& $sync.NeedTranslate -text $textToTranslate -lang $targetLang)) {
            $sync.AutoSkipped++
            continue
        }

        $translation = Invoke-Translate -txt $processedMessage -targetLang $targetLang
        if ($null -eq $translation -or $translation -eq "") {
            [System.Threading.Thread]::Sleep(1000)
            $translation = Invoke-Translate -txt $processedMessage -targetLang $targetLang
        }

        # 恢复物品链接和招募链接
        if ($null -ne $translation -and $translation -ne "") {
            for ($i = 0; $i -lt $itemLinks.Count; $i++) {
                $translation = [regex]::Replace($translation, [regex]::Escape("@^"), $itemLinks[$i], 1)
            }
            for ($i = 0; $i -lt $recruitLinks.Count; $i++) {
                $translation = [regex]::Replace($translation, [regex]::Escape("@&"), $recruitLinks[$i], 1)
            }
            # 移除 AI 可能保留的 <> 包裹符号
            $translation = $translation -replace '[<>\[\]]', ''
        }

        if ($null -ne $translation -and $translation -ne "") {
            # 成功：写缓存 + 写 response 文件
            [System.Threading.Monitor]::Enter($sync.Cache.SyncRoot)
            try {
                if (-not $sync.Cache.ContainsKey($rawMessage)) {
                    if ($sync.Cache.Count -ge $sync.CacheMaxSize) {
                        $newestKey = $null; $newestHitCount = 0; $newestTime = [DateTime]::MinValue
                        $secondNewestKey = $null; $secondNewestTime = [DateTime]::MinValue
                        foreach ($entry in $sync.Cache.GetEnumerator()) {
                            $t = $entry.Value.lastHit
                            if ($t -gt $newestTime) {
                                $secondNewestKey = $newestKey; $secondNewestTime = $newestTime
                                $newestKey = $entry.Key; $newestHitCount = $entry.Value.hitCount; $newestTime = $t
                            } elseif ($t -gt $secondNewestTime) {
                                $secondNewestKey = $entry.Key; $secondNewestTime = $t
                            }
                        }
                        if ($newestHitCount -ge 3 -and $sync.Cache.Count -gt 1) {
                            $sync.Cache.Remove($secondNewestKey)
                        } else {
                            $sync.Cache.Remove($newestKey)
                        }
                    }
                    $sync.Cache[$rawMessage] = @{
                        translation = $translation
                        hitCount    = 0
                        lastHit     = [DateTime]::Now
                    }
                }
            } finally {
                [System.Threading.Monitor]::Exit($sync.Cache.SyncRoot)
            }
            # 写 translated_messages（main.lua 读取并显示在聊天框）
            try {
                $prefix = "||||" + $channel + "||||" + $senderName + "||||"
                $translationBytes = [System.Text.Encoding]::UTF8.GetBytes($translation)
                $b64 = [Convert]::ToBase64String($translationBytes)
                $timestamp = if ($msgFields.Count -ge 6) { $msgFields[5] } else { "" }
                $logEntry = "{chatMsg = `"$prefix$b64||||$timestamp||||`"}"
                [System.IO.File]::WriteAllText($sync.AutoOutFile, $logEntry, [System.Text.UTF8Encoding]::new($false))
            } catch { $null = $_ }
            $sync.AutoSent++
            $translationDisplay = $translation -replace '[|]?i\d+,[^,]*,[^,]*,[^;]*;', ''

            $sync.StatusMessages.Enqueue(("[Auto#$($workerId):Done] {0}:{1}" -f $senderName, $translationDisplay.Substring(0, [Math]::Min(50, $translationDisplay.Length))))
        } else {
            $sync.Failed++
            $sync.StatusMessages.Enqueue("[Auto#$($workerId):Error]")
        }
        } catch {
            $sync.Failed++
            $sync.StatusMessages.Enqueue(("[Auto#$($workerId):Error] $_"))
        }
    }
}

# ============================================================
# 启动文件监视线程
# ============================================================
# ============================================================
$fileMonitorRS = [RunspaceFactory]::CreateRunspace([InitialSessionState]::CreateDefault())
$fileMonitorRS.Open()
$fileMonitorPS = [PowerShell]::Create()
$fileMonitorPS.Runspace = $fileMonitorRS
$fileMonitorPS.AddScript($fileMonitorCode).AddArgument($sync) | Out-Null
$fileMonitorPS.BeginInvoke() | Out-Null
[System.Console]::WriteLine("[Start] File monitoring thread")

# ============================================================
# 启动 3 个自动翻译 Worker + 1 个手动翻译 Worker（长驻 Runspace）
# ============================================================
$workers = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
foreach ($id in 1..3) {
    $rs = [RunspaceFactory]::CreateRunspace([InitialSessionState]::CreateDefault())
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript($autoWorkerCode).AddArgument($sync).AddArgument($id) | Out-Null
    $ps.BeginInvoke() | Out-Null
    $workers.Add(@{ PS = $ps; RS = $rs; Type = "Auto"; Id = $id }) | Out-Null
    [System.Console]::WriteLine("[Start] Auto worker #${id} started")
}
$manualRS = [RunspaceFactory]::CreateRunspace([InitialSessionState]::CreateDefault())
$manualRS.Open()
$manualPS = [PowerShell]::Create()
$manualPS.Runspace = $manualRS
$manualPS.AddScript($manualWorkerCode).AddArgument($sync) | Out-Null
$manualPS.BeginInvoke() | Out-Null
$workers.Add(@{ PS = $manualPS; RS = $manualRS; Type = "Manual" }) | Out-Null
[System.Console]::WriteLine("[Start] Manual worker started")
# ============================================================
# 主线程循环
#   50ms 轮询 → 查缓存 → 待翻译数组 → 入队到工作队列
# ============================================================
[System.Console]::WriteLine("")
[System.Console]::WriteLine("=== Running ===")
[System.Console]::WriteLine("Auto messages: $AutoFilePath")
[System.Console]::WriteLine("Manual requests: $RequestFilePath")
[System.Console]::WriteLine("Input model (manual): $($sync.InputModel)")
[System.Console]::WriteLine("Input endpoint: $($sync.InputEndpoint)")
[System.Console]::WriteLine("Output model (auto): $($sync.OutputModel)")
[System.Console]::WriteLine("Output endpoint: $($sync.OutputEndpoint)")
[System.Console]::WriteLine("Max concurrency: ${MaxConcurrentThreads} threads")
[System.Console]::WriteLine("Cache limit: ${CacheMaxSize} entries")
[System.Console]::WriteLine("")
try {
    # 单实例 Mutex 创建（与 finally 中的 Dispose 配对，确保清理）
    $createdNew = $false
    try {
        $script:appMutex = [System.Threading.Mutex]::new($false, $mutexName, [ref]$createdNew)
        if (-not $createdNew) {
            [System.Console]::WriteLine("[Error] Another instance is already running!")
            exit 1
        }
    } catch [System.Threading.AbandonedMutexException] {
        $script:appMutex = $_.Mutex
        [System.Console]::WriteLine("[Warning] Previous instance was terminated abnormally, taking over.")
    }

    $mainLoopMs = 20  # 20ms 轮询间隔
    $sync.IsAdmin = Test-Admin
    if ($sync.IsAdmin) {
            [System.Console]::Title = "[Admin] AAFreeTranslation"
        [System.Console]::WriteLine("[Main Thread] Send Enabled")
    } else {
            [System.Console]::Title = "[User] AAFreeTranslation"
        [System.Console]::WriteLine("[Main Thread] Send Disabled")
    }


    try { [TrayManager]::Initialize() } catch {$null = $_ }

    while ($true) {
        try {
            # 检查自动消息信号
            if ($sync.NewAutoReady) {
                $msg = $sync.NewAutoMessage
                $sync.NewAutoReady = $false
                $sync.NewAutoMessage = $null

                # 查缓存（使用实际消息内容作为 key）
                $cacheFields = $msg -split '\|\|\|\|'
                $cacheKey = if ($cacheFields.Count -ge 4) { $cacheFields[3] } else { $msg }
                if ($sync.Cache.ContainsKey($cacheKey)) {
                    $entry = $sync.Cache[$cacheKey]
                    $entry.hitCount++
                    $entry.lastHit = [DateTime]::Now
                    # 缓存命中 → 直接写结果
                    try {
                        $cacheChannel = if ($cacheFields.Count -ge 2) { $cacheFields[1] } else { "" }
                        $cacheSender = if ($cacheFields.Count -ge 3) { $cacheFields[2] } else { "" }
                        $cacheBytes = [System.Text.Encoding]::UTF8.GetBytes($entry.translation)
                        $cacheB64 = [Convert]::ToBase64String($cacheBytes)
                        $cacheTimestamp = if ($cacheFields.Count -ge 6) { $cacheFields[5] } else { "" }
                        $cacheOutput = "{chatMsg = `"||||" + $cacheChannel + "||||" + $cacheSender + "||||" + $cacheB64 + "||||" + $cacheTimestamp + "||||`"}"
                        [System.IO.File]::WriteAllText($sync.AutoOutFile, $cacheOutput, [System.Text.UTF8Encoding]::new($false))
                    } catch { $null = $_ }
                    $sync.AutoCached++
                    [System.Console]::WriteLine(("[Auto:Cache] {0}" -f $entry.translation.Substring(0, [Math]::Min(50, $entry.translation.Length))))
                } else {
                    # 未命中 → 加入待翻译数组
                    $sync.PendingMessages.Add($msg) | Out-Null
                    $addFields = $msg -split '\|\|\|\|'
                    $addText = if ($addFields.Count -ge 4) { $addFields[3] } else { $msg }
                    [System.Console]::WriteLine(("[Auto:Cache] add: {0}" -f $addText.Substring(0, [Math]::Min(50, $addText.Length))))
                }
            }

            # 检查发送游戏信号
            if ($sync.SendToGameReady) {
                $sync.SendToGameReady = $false
                $sendData = $sync.SendResultContent
                $sync.SendResultContent = $null
                & $sync.SendToGame -sendData $sendData
            }

            # 从待翻译数组取消息，入队到自动翻译工作队列（3 个常驻 Worker 消费）
            while ($sync.PendingMessages.Count -gt 0) {
                $msg = $sync.PendingMessages[0]
                $sync.PendingMessages.RemoveAt(0)

                # 再次查缓存（使用实际消息内容作为 key）
                $cacheFields2 = $msg -split '\|\|\|\|'
                $cacheKey2 = if ($cacheFields2.Count -ge 4) { $cacheFields2[3] } else { $msg }
                if ($sync.Cache.ContainsKey($cacheKey2)) {
                    $entry = $sync.Cache[$cacheKey2]
                    $entry.hitCount++
                    $entry.lastHit = [DateTime]::Now
                    try {
                        $cacheChannel2 = if ($cacheFields2.Count -ge 2) { $cacheFields2[1] } else { "" }
                        $cacheSender2 = if ($cacheFields2.Count -ge 3) { $cacheFields2[2] } else { "" }
                        $cacheBytes2 = [System.Text.Encoding]::UTF8.GetBytes($entry.translation)
                        $cacheB642 = [Convert]::ToBase64String($cacheBytes2)
                        $cacheTimestamp2 = if ($cacheFields2.Count -ge 6) { $cacheFields2[5] } else { "" }
                        $cacheOutput2 = "{chatMsg = `"||||" + $cacheChannel2 + "||||" + $cacheSender2 + "||||" + $cacheB642 + "||||" + $cacheTimestamp2 + "||||`"}"
                        [System.IO.File]::WriteAllText($sync.AutoOutFile, $cacheOutput2, [System.Text.UTF8Encoding]::new($false))
                    } catch { $null = $_ }
                    $sync.AutoCached++
                    [System.Console]::WriteLine(("[Auto:Cache] {0}" -f $entry.translation.Substring(0, [Math]::Min(50, $entry.translation.Length))))
                    continue
                }

                # 入队到自动翻译工作队列（Worker 空闲时自动取出翻译）
                $sync.AutoWorkQueue.Enqueue($msg)
            }

            # 打印所有 Runspace 传来的状态消息
            while ($sync.StatusMessages.Count -gt 0) {
                $msg = $sync.StatusMessages.Dequeue()
                [System.Console]::WriteLine("$msg")
            }
        } catch {
            # 循环内异常 → 记录错误后继续运行
            try { $sync.StatusMessages.Enqueue(("[MainThread:Error] $_")) } catch { $null = $_ }
        }

        try {
            [System.Threading.Thread]::Sleep($mainLoopMs)
        } catch {
            try { $sync.StatusMessages.Enqueue(("[MainThread:SleepError] $_")) } catch { $null = $_ }
        }
    }
} catch {
    try { $sync.StatusMessages.Enqueue(("[MainThread:Fatal] $_")) } catch { $null = $_ }
} finally {
    # ============================================================
    # 清理
    # ============================================================
    [System.Console]::WriteLine("`n[Cleanup] Stopping...")
    $sync.StopFlag = $true

    # 停止所有工作线程（文件监控 + 自动翻译 ×3 + 手动翻译 ×1）
    try {
        if ($fileMonitorPS) { $fileMonitorPS.Stop(); $fileMonitorPS.Dispose() }
        if ($fileMonitorRS) { $fileMonitorRS.Close(); $fileMonitorRS.Dispose() }
    } catch { $null = $_ }
    if ($workers) {
        foreach ($w in $workers) {
            try {
                if ($w.PS) { $w.PS.Stop(); $w.PS.Dispose() }
                if ($w.RS) { $w.RS.Close(); $w.RS.Dispose() }
            } catch { $null = $_ }
        }
    }

    try { [TrayManager]::Cleanup() } catch {$null = $_ }

[System.Console]::WriteLine("")
[System.Console]::WriteLine("=== Statistics ===")
[System.Console]::WriteLine("Auto messages found: $($sync.AutoFound)")
[System.Console]::WriteLine("Cache hits:          $($sync.AutoCached)")
[System.Console]::WriteLine("Auto translations succeeded: $($sync.AutoSent)")
[System.Console]::WriteLine("Auto skipped (no translation needed): $($sync.AutoSkipped)")
[System.Console]::WriteLine("Manual translations succeeded: $($sync.ManualSent)")
[System.Console]::WriteLine("Translation failures: $($sync.Failed)")
[System.Console]::WriteLine("[Cleanup] Complete")
    if ($script:appMutex) {
        try { $script:appMutex.Dispose() } catch { $null = $_ }
    }
}