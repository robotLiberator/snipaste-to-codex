param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# One-file usage:
#   .\SnipasteToCodex.ps1 -Install
#   .\SnipasteToCodex.ps1 -SelfTest
#   .\SnipasteToCodex.ps1 -Uninstall

$installDir = Join-Path $env:LOCALAPPDATA 'SnipasteToCodex'
$installedScript = Join-Path $installDir 'SnipasteToCodex.ps1'
$bridgeExe = Join-Path $installDir 'SnipasteToCodex.exe'
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Snipaste to Codex.lnk'

$source = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        bool createdNew;
        using (System.Threading.Mutex mutex = new System.Threading.Mutex(true, @"Local\SnipasteToCodexBridge", out createdNew))
        {
            if (!createdNew) return;
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new SnipasteToCodexContext());
        }
    }
}

public sealed class SnipasteToCodexContext : ApplicationContext
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int VK_F1 = 0x70;
    private const int WM_CLIPBOARDUPDATE = 0x031D;
    private const uint CF_BITMAP = 2;
    private const uint CF_DIB = 8;
    private const uint CF_DIBV5 = 17;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private readonly ClipboardWindow clipboardWindow;
    private readonly Timer captureTimer;
    private readonly Timer deliveryTimer;
    private readonly Timer expiryTimer;
    private readonly NotifyIcon tray;
    private readonly LowLevelKeyboardProc keyboardProc;
    private IntPtr keyboardHook;
    private IntPtr targetWindow;
    private IntPtr targetFocus;
    private bool armed;
    private bool paused;
    private int captureRetries;
    private uint clipboardSequenceAtF1;
    private readonly string logPath;
    private readonly string queueDir;

    public SnipasteToCodexContext()
    {
        string dataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "SnipasteToCodex");
        Directory.CreateDirectory(dataDir);
        logPath = Path.Combine(dataDir, "bridge.log");
        queueDir = Path.Combine(dataDir, "Queue");
        Directory.CreateDirectory(queueDir);

        clipboardWindow = new ClipboardWindow(this);
        if (!AddClipboardFormatListener(clipboardWindow.Handle))
            throw new InvalidOperationException("Unable to register the clipboard listener.");

        captureTimer = new Timer();
        captureTimer.Interval = 350;
        captureTimer.Tick += CaptureTimerTick;

        deliveryTimer = new Timer();
        deliveryTimer.Interval = 750;
        deliveryTimer.Tick += DeliveryTimerTick;
        deliveryTimer.Start();

        expiryTimer = new Timer();
        expiryTimer.Interval = 120000;
        expiryTimer.Tick += delegate { Disarm("Timed out or screenshot was cancelled."); };

        ContextMenuStrip menu = new ContextMenuStrip();
        ToolStripMenuItem pauseItem = new ToolStripMenuItem("Pause");
        pauseItem.Click += delegate {
            paused = !paused;
            pauseItem.Text = paused ? "Resume" : "Pause";
            tray.Text = paused ? "Snipaste to Codex (paused)" : "Snipaste to Codex";
            Disarm("Paused state changed.");
        };
        menu.Items.Add(pauseItem);
        menu.Items.Add(new ToolStripSeparator());
        ToolStripMenuItem exitItem = new ToolStripMenuItem("Exit");
        exitItem.Click += delegate { ExitThread(); };
        menu.Items.Add(exitItem);

        tray = new NotifyIcon();
        tray.Icon = System.Drawing.SystemIcons.Application;
        tray.Text = "Snipaste to Codex";
        tray.ContextMenuStrip = menu;
        tray.Visible = true;

        keyboardProc = KeyboardHookCallback;
        keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, keyboardProc, GetModuleHandle(null), 0);
        if (keyboardHook == IntPtr.Zero)
            throw new InvalidOperationException("Unable to install the F1 observer.");

        UpdateTrayText();
        Log("Started in silent queue mode.");
    }

    protected override void ExitThreadCore()
    {
        if (keyboardHook != IntPtr.Zero) UnhookWindowsHookEx(keyboardHook);
        RemoveClipboardFormatListener(clipboardWindow.Handle);
        tray.Visible = false;
        tray.Dispose();
        clipboardWindow.DestroyHandle();
        captureTimer.Dispose();
        deliveryTimer.Dispose();
        expiryTimer.Dispose();
        Log("Stopped.");
        base.ExitThreadCore();
    }

    private IntPtr KeyboardHookCallback(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && !paused &&
            (wParam.ToInt32() == WM_KEYDOWN || wParam.ToInt32() == WM_SYSKEYDOWN))
        {
            KBDLLHOOKSTRUCT info = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(
                lParam, typeof(KBDLLHOOKSTRUCT));
            if (info.vkCode == VK_F1 && (info.flags & 0x40000000) == 0)
                Arm();
        }
        return CallNextHookEx(keyboardHook, code, wParam, lParam);
    }

    private void Arm()
    {
        IntPtr foreground = GetForegroundWindow();
        targetWindow = IsCodexWindow(foreground) ? foreground : FindCodexWindow();
        targetFocus = GetFocusedWindow(targetWindow);
        clipboardSequenceAtF1 = GetClipboardSequenceNumber();
        armed = true;
        captureRetries = 0;
        captureTimer.Stop();
        expiryTimer.Stop();
        expiryTimer.Start();
        Log("F1 observed; waiting for an image from Snipaste.");
    }

    internal void ClipboardChanged()
    {
        if (!armed || paused) return;
        if (GetClipboardSequenceNumber() == clipboardSequenceAtF1) return;
        if (!ClipboardContainsImage()) return;

        expiryTimer.Stop();
        captureTimer.Stop();
        captureTimer.Start();
        Log("Image detected; preparing to add it to the silent queue.");
    }

    private void CaptureTimerTick(object sender, EventArgs e)
    {
        captureTimer.Stop();
        if (!armed || paused) return;
        try
        {
            using (Image clipboardImage = Clipboard.GetImage())
            {
                if (clipboardImage == null) throw new InvalidOperationException("Clipboard image is unavailable.");
                string name = DateTime.Now.ToString("yyyyMMdd-HHmmss-fff") + "-" +
                    Guid.NewGuid().ToString("N").Substring(0, 6) + ".png";
                string path = Path.Combine(queueDir, name);
                using (Bitmap copy = new Bitmap(clipboardImage)) copy.Save(path, ImageFormat.Png);
                armed = false;
                UpdateTrayText();
                Log("Screenshot queued: " + name);
            }
        }
        catch (Exception error)
        {
            captureRetries++;
            if (captureRetries < 5)
            {
                captureTimer.Start();
                return;
            }
            armed = false;
            Log("Unable to queue screenshot: " + error.Message);
        }
    }

    private void DeliveryTimerTick(object sender, EventArgs e)
    {
        if (paused) return;
        IntPtr foreground = GetForegroundWindow();
        if (!IsCodexWindow(foreground)) return;

        string[] files = Directory.GetFiles(queueDir, "*.png");
        if (files.Length == 0) return;
        Array.Sort(files, StringComparer.OrdinalIgnoreCase);

        string path = files[0];
        try
        {
            if (!IsCodexWindow(GetForegroundWindow())) return;
            using (Image image = Image.FromFile(path))
            using (Bitmap copy = new Bitmap(image))
                Clipboard.SetImage(copy);

            RestoreFocus(foreground, targetFocus);
            if (!SendCtrlV()) throw new InvalidOperationException("Windows did not accept Ctrl+V.");
            File.Delete(path);
            UpdateTrayText();
            Log("Queued screenshot delivered to Codex: " + Path.GetFileName(path));
        }
        catch (Exception error)
        {
            Log("Queued screenshot retained after delivery failure: " + error.Message);
        }
    }

    private void Disarm(string reason)
    {
        armed = false;
        captureTimer.Stop();
        expiryTimer.Stop();
        Log(reason);
    }

    private void UpdateTrayText()
    {
        int count = Directory.GetFiles(queueDir, "*.png").Length;
        if (paused) tray.Text = "Snipaste to Codex (paused)";
        else if (count == 0) tray.Text = "Snipaste to Codex";
        else tray.Text = "Snipaste to Codex - queued: " + count;
    }

    private static bool ClipboardContainsImage()
    {
        uint png = RegisterClipboardFormat("PNG");
        return IsClipboardFormatAvailable(CF_BITMAP) ||
               IsClipboardFormatAvailable(CF_DIB) ||
               IsClipboardFormatAvailable(CF_DIBV5) ||
               (png != 0 && IsClipboardFormatAvailable(png));
    }

    public static IntPtr FindCodexWindow()
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr lParam) {
            if (IsWindowVisible(hwnd) && IsCodexWindow(hwnd))
            {
                found = hwnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    private static bool IsCodexWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return false;
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        try
        {
            Process process = Process.GetProcessById((int)pid);
            string path = process.MainModule.FileName;
            return string.Equals(Path.GetFileName(path), "ChatGPT.exe", StringComparison.OrdinalIgnoreCase) &&
                   path.IndexOf("OpenAI.Codex_", StringComparison.OrdinalIgnoreCase) >= 0;
        }
        catch { return false; }
    }

    private static IntPtr GetFocusedWindow(IntPtr mainWindow)
    {
        if (mainWindow == IntPtr.Zero) return IntPtr.Zero;
        uint pid;
        uint thread = GetWindowThreadProcessId(mainWindow, out pid);
        GUITHREADINFO info = new GUITHREADINFO();
        info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
        return GetGUIThreadInfo(thread, ref info) ? info.hwndFocus : IntPtr.Zero;
    }

    private static void RestoreFocus(IntPtr mainWindow, IntPtr previousFocus)
    {
        if (previousFocus == IntPtr.Zero || !IsWindow(previousFocus)) return;
        uint pid;
        uint targetThread = GetWindowThreadProcessId(mainWindow, out pid);
        uint currentThread = GetCurrentThreadId();
        bool attached = AttachThreadInput(currentThread, targetThread, true);
        try { SetFocus(previousFocus); }
        finally { if (attached) AttachThreadInput(currentThread, targetThread, false); }
    }

    private static bool SendCtrlV()
    {
        INPUT[] inputs = new INPUT[4];
        inputs[0] = INPUT.Key(0x11, 0);
        inputs[1] = INPUT.Key(0x56, 0);
        inputs[2] = INPUT.Key(0x56, KEYEVENTF_KEYUP);
        inputs[3] = INPUT.Key(0x11, KEYEVENTF_KEYUP);
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) == inputs.Length;
    }

    private void Log(string text)
    {
        try
        {
            File.AppendAllText(logPath,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + text + Environment.NewLine,
                Encoding.UTF8);
        }
        catch { }
    }

    internal sealed class ClipboardWindow : NativeWindow
    {
        private readonly SnipasteToCodexContext owner;
        internal ClipboardWindow(SnipasteToCodexContext owner)
        {
            this.owner = owner;
            CreateHandle(new CreateParams());
        }
        protected override void WndProc(ref Message message)
        {
            if (message.Msg == WM_CLIPBOARDUPDATE) owner.ClipboardChanged();
            base.WndProc(ref message);
        }
    }

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);
    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode, scanCode, flags, time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct GUITHREADINFO
    {
        public int cbSize;
        public int flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion data;
        public static INPUT Key(ushort key, uint flags)
        {
            INPUT value = new INPUT();
            value.type = 1;
            value.data = new InputUnion();
            value.data.ki = new KEYBDINPUT();
            value.data.ki.wVk = key;
            value.data.ki.dwFlags = flags;
            return value;
        }
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT { public uint uMsg; public ushort wParamL, wParamH; }

    [DllImport("user32.dll")] private static extern bool AddClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] private static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern uint RegisterClipboardFormat(string format);
    [DllImport("user32.dll")] private static extern IntPtr SetWindowsHookEx(int id, LowLevelKeyboardProc callback, IntPtr module, uint threadId);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] private static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint current, uint target, bool attach);
    [DllImport("user32.dll")] private static extern IntPtr SetFocus(IntPtr hwnd);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern uint SendInput(uint count, INPUT[] inputs, int size);
}
'@

function Get-BridgeProcesses {
    Get-CimInstance Win32_Process | Where-Object {
        ($_.Name -eq 'SnipasteToCodex.exe' -and $_.ExecutablePath -eq $bridgeExe) -or
        ($_.Name -eq 'powershell.exe' -and $_.ProcessId -ne $PID -and $_.CommandLine -like '*SnipasteToCodex.ps1*')
    }
}

if ($Install) {
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Get-BridgeProcesses | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

    $temporaryExe = Join-Path $installDir 'SnipasteToCodex.new.exe'
    $temporarySource = Join-Path $installDir 'SnipasteToCodex.generated.cs'
    if (Test-Path -LiteralPath $temporaryExe) { Remove-Item -LiteralPath $temporaryExe -Force }
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler)) {
        $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    }
    [IO.File]::WriteAllText($temporarySource, $source, (New-Object Text.UTF8Encoding($false)))
    & $compiler /nologo /target:winexe /optimize+ "/out:$temporaryExe" `
        /reference:System.Windows.Forms.dll /reference:System.Drawing.dll $temporarySource
    $compileExitCode = $LASTEXITCODE
    Remove-Item -LiteralPath $temporarySource -Force
    if ($compileExitCode -ne 0 -or -not (Test-Path -LiteralPath $temporaryExe)) {
        throw "Unable to compile the lightweight bridge (compiler exit code $compileExitCode)."
    }
    Move-Item -LiteralPath $temporaryExe -Destination $bridgeExe -Force

    if ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($installedScript)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $installedScript -Force
    }

    Unregister-ScheduledTask -TaskName 'SnipasteToCodex' -Confirm:$false -ErrorAction SilentlyContinue
    $shortcutShell = New-Object -ComObject WScript.Shell
    $shortcut = $shortcutShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $bridgeExe
    $shortcut.Arguments = ''
    $shortcut.WorkingDirectory = $installDir
    $shortcut.Description = 'Paste annotated Snipaste captures into the current Codex chat'
    $shortcut.Save()

    $shell = New-Object -ComObject Shell.Application
    $shell.ShellExecute($bridgeExe, '', $installDir, 'open', 0)
    "Installed lightweight bridge: $bridgeExe"
    exit
}

if ($Uninstall) {
    Get-BridgeProcesses | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
    Unregister-ScheduledTask -TaskName 'SnipasteToCodex' -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $installDir) { [IO.Directory]::Delete($installDir, $true) }
    'Snipaste to Codex has been removed.'
    exit
}

if ($SelfTest) {
    $codex = Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object {
        try { $_.MainModule.FileName -like '*OpenAI.Codex_*' } catch { $false }
    } | Select-Object -First 1
    $snipaste = Get-Process -Name Snipaste -ErrorAction SilentlyContinue
    $queueDir = Join-Path $installDir 'Queue'
    New-Item -ItemType Directory -Force -Path $queueDir | Out-Null
    $queueProbe = Join-Path $queueDir '.write-test'
    [IO.File]::WriteAllText($queueProbe, 'ok')
    [IO.File]::Delete($queueProbe)
    $bridgeProcess = Get-BridgeProcesses
    [pscustomobject]@{
        CodexRunning = ($null -ne $codex)
        SnipasteRunning = ($null -ne $snipaste)
        QueueWritable = $true
        QueuedImages = @(Get-ChildItem -LiteralPath $queueDir -Filter '*.png' -File).Count
        BackgroundRunning = ($null -ne $bridgeProcess)
        LightweightExeReady = (Test-Path -LiteralPath $bridgeExe)
        StartupShortcutReady = (Test-Path -LiteralPath $shortcutPath)
    }
    exit
}

'Use -Install, -SelfTest, or -Uninstall.'

