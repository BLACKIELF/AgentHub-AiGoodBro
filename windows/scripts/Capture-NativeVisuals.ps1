#Requires -Version 5.1

[CmdletBinding()]
param(
  [string] $OutputRoot,
  [switch] $PreflightOnly,
  [switch] $SkipBuild,
  [Alias('Surface')]
  [ValidateSet('All', 'Overview', 'Tasks', 'AI Leadership', 'Usage', 'Projects', 'Skills')]
  [string] $RequestedSurface = 'All'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$windowsRoot = Join-Path $repositoryRoot 'windows'
$artifactBase = Join-Path $repositoryRoot '.local-artifacts\windows-visual-captures'
$helperSource = Join-Path $PSScriptRoot 'native-visual-capture\GraphicsCaptureSnapshot.cs'
$appPath = Join-Path $windowsRoot 'target\release\codexu-tauri.exe'
$requiredRustToolchain = '1.97.1-x86_64-pc-windows-msvc'
$captureRuns = @('fullscreen')
$segmentOverlapRatio = 0.2
$maxSegmentsPerSurface = 12
$surfaceFilePattern = '<surface>-<segment:00>.png'
$surfaces = @(
  [ordered]@{
    name = 'Tasks'
    slug = 'tasks'
    tab = 'dashboard-home-tab-tasks'
    panel = 'dashboard-home-panel-tasks'
  },
  [ordered]@{
    name = 'AI Leadership'
    slug = 'ai-leadership'
    tab = 'dashboard-home-tab-leadership'
    panel = 'dashboard-home-panel-leadership'
  },
  [ordered]@{
    name = 'Usage'
    slug = 'usage'
    tab = 'dashboard-home-tab-usage'
    panel = 'dashboard-home-panel-usage'
  },
  [ordered]@{
    name = 'Projects'
    slug = 'projects'
    tab = 'dashboard-home-tab-projects'
    panel = 'dashboard-home-panel-projects'
  },
  [ordered]@{
    name = 'Skills'
    slug = 'skills'
    tab = 'dashboard-home-tab-skills'
    panel = 'dashboard-home-panel-skills'
  }
)
$captureOverview = $RequestedSurface -in @('All', 'Overview')
$selectedPanelSurfaces = if ($RequestedSurface -eq 'All') {
  @($surfaces)
} elseif ($RequestedSurface -eq 'Overview') {
  @()
} else {
  @($surfaces | Where-Object { $_.name -eq $RequestedSurface })
}
$requestedSurfaces = @()
if ($captureOverview) {
  $requestedSurfaces += 'Overview'
}
$requestedSurfaces += @($selectedPanelSurfaces | ForEach-Object { $_.name })
$singlePanelCapture = $RequestedSurface -notin @('All', 'Overview')

function Get-NormalizedOutputRoot {
  param([string] $RequestedPath)

  if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
    $leaf = (Get-Date).ToString('yyyy-MM-dd-HHmmss-fff') + '-native-workflow'
    $RequestedPath = Join-Path $artifactBase $leaf
  } elseif (-not [System.IO.Path]::IsPathRooted($RequestedPath)) {
    $RequestedPath = Join-Path $repositoryRoot $RequestedPath
  }

  $fullPath = [System.IO.Path]::GetFullPath($RequestedPath)
  $basePath = [System.IO.Path]::GetFullPath($artifactBase)
  $basePrefix = $basePath.TrimEnd([char[]]"\/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith(
    $basePrefix,
    [System.StringComparison]::OrdinalIgnoreCase
  )) {
    throw 'OutputRoot must be a new child of .local-artifacts/windows-visual-captures.'
  }
  return $fullPath
}

function Get-CaptureCompiler {
  $windowsDirectory = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::Windows
  )
  $frameworkCandidates = @(
    (Join-Path $windowsDirectory 'Microsoft.NET\Framework64\v4.0.30319'),
    (Join-Path $windowsDirectory 'Microsoft.NET\Framework\v4.0.30319')
  )
  $frameworkDirectory = @(
    $frameworkCandidates | Where-Object {
      Test-Path -LiteralPath (Join-Path $_ 'csc.exe') -PathType Leaf
    }
  ) | Select-Object -First 1

  $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
  $metadataCandidates = @()
  if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
    $unionMetadata = Join-Path $programFilesX86 'Windows Kits\10\UnionMetadata'
    if (Test-Path -LiteralPath $unionMetadata -PathType Container) {
      $metadataCandidates = @(
        Get-ChildItem -LiteralPath $unionMetadata -Directory |
          Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
          Sort-Object { [version]$_.Name } -Descending |
          ForEach-Object {
            Get-Item -LiteralPath (Join-Path $_.FullName 'Windows.winmd') `
              -ErrorAction SilentlyContinue
          }
      )
    }
  }
  $windowsMetadataItem = @($metadataCandidates) | Select-Object -First 1
  $windowsMetadata = $null
  $windowsMetadataVersion = $null
  if ($null -ne $windowsMetadataItem) {
    $windowsMetadata = $windowsMetadataItem.FullName
    $windowsMetadataVersion = $windowsMetadataItem.Directory.Name
  }

  $compiler = $null
  $runtimeWindows = $null
  $runtime = $null
  $drawing = $null
  if ($null -ne $frameworkDirectory) {
    $compiler = Join-Path $frameworkDirectory 'csc.exe'
    $runtimeWindows = Join-Path $frameworkDirectory 'System.Runtime.WindowsRuntime.dll'
    $runtime = Join-Path $frameworkDirectory 'System.Runtime.dll'
    $drawing = Join-Path $frameworkDirectory 'System.Drawing.dll'
  }

  return [pscustomobject]@{
    compiler = $compiler
    windows_metadata = $windowsMetadata
    windows_metadata_version = $windowsMetadataVersion
    runtime_windows = $runtimeWindows
    runtime = $runtime
    drawing = $drawing
  }
}

function Test-CompilerReady {
  param([pscustomobject] $Compiler)
  return (
    $null -ne $Compiler.compiler -and
    $null -ne $Compiler.windows_metadata -and
    (Test-Path -LiteralPath $Compiler.compiler -PathType Leaf) -and
    (Test-Path -LiteralPath $Compiler.windows_metadata -PathType Leaf) -and
    (Test-Path -LiteralPath $Compiler.runtime_windows -PathType Leaf) -and
    (Test-Path -LiteralPath $Compiler.runtime -PathType Leaf) -and
    (Test-Path -LiteralPath $Compiler.drawing -PathType Leaf)
  )
}

function Initialize-NativeVisualDriver {
  if ($null -ne ('NativeVisualCaptureDriver' -as [type])) {
    return
  }

  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class NativeVisualCaptureDriver
{
    private const uint WM_MOUSEWHEEL = 0x020A;
    private const uint WM_MOUSEHWHEEL = 0x020E;

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WINDOWPLACEMENT
    {
        public int Length;
        public int Flags;
        public int ShowCmd;
        public POINT MinPosition;
        public POINT MaxPosition;
        public RECT NormalPosition;
    }

    private delegate bool EnumChildProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetClientRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hwnd, int command);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowPlacement(
        IntPtr hwnd,
        ref WINDOWPLACEMENT placement
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPlacement(
        IntPtr hwnd,
        ref WINDOWPLACEMENT placement
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(
        IntPtr hwnd,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags
    );

    [DllImport(
        "user32.dll",
        EntryPoint = "GetWindowLongPtrW",
        SetLastError = true
    )]
    private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);

    [DllImport(
        "user32.dll",
        EntryPoint = "SetWindowLongPtrW",
        SetLastError = true
    )]
    private static extern IntPtr SetWindowLongPtr(
        IntPtr hwnd,
        int index,
        IntPtr value
    );

    [DllImport("user32.dll")]
    private static extern bool IsZoomed(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(
        IntPtr parent,
        EnumChildProc callback,
        IntPtr lParam
    );

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(
        IntPtr hwnd,
        StringBuilder text,
        int maxCount
    );

    [DllImport("user32.dll")]
    private static extern bool PostMessage(
        IntPtr hwnd,
        uint message,
        IntPtr wParam,
        IntPtr lParam
    );

    private static RECT ReadWindowRect(IntPtr hwnd)
    {
        RECT rect;
        if (!GetWindowRect(hwnd, out rect))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return rect;
    }

    private static RECT ReadClientRect(IntPtr hwnd)
    {
        RECT rect;
        if (!GetClientRect(hwnd, out rect))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return rect;
    }

    public static IntPtr GetForegroundWindowHandle()
    {
        return GetForegroundWindow();
    }

    public static bool ApplyCaptureWindowStyle(IntPtr hwnd)
    {
        const int GWL_EXSTYLE = -20;
        const long WS_EX_TOOLWINDOW = 0x00000080L;
        const long WS_EX_APPWINDOW = 0x00040000L;
        const uint SWP_NOSIZE = 0x0001;
        const uint SWP_NOMOVE = 0x0002;
        const uint SWP_NOZORDER = 0x0004;
        const uint SWP_NOACTIVATE = 0x0010;
        const uint SWP_FRAMECHANGED = 0x0020;

        long current = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
        long updated = (current | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW;
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr(updated));
        long applied = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
        if (applied != updated)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        if (!SetWindowPos(
            hwnd,
            IntPtr.Zero,
            0,
            0,
            0,
            0,
            SWP_NOSIZE |
            SWP_NOMOVE |
            SWP_NOZORDER |
            SWP_NOACTIVATE |
            SWP_FRAMECHANGED
        ))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return (
            (updated & WS_EX_TOOLWINDOW) != 0 &&
            (updated & WS_EX_APPWINDOW) == 0
        );
    }

    private static int UnscaleForDpi(int physicalValue, uint dpi)
    {
        return checked((int)Math.Round(
            physicalValue * 96.0 / dpi,
            MidpointRounding.AwayFromZero
        ));
    }

    public static string GetClientScreenBounds(IntPtr hwnd)
    {
        IntPtr previousDpiContext = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try
        {
            RECT client = ReadClientRect(hwnd);
            var origin = new POINT { X = 0, Y = 0 };
            if (!ClientToScreen(hwnd, ref origin))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return String.Format(
                "left={0};top={1};right={2};bottom={3}",
                origin.X,
                origin.Y,
                origin.X + client.Right - client.Left,
                origin.Y + client.Bottom - client.Top
            );
        }
        finally
        {
            if (previousDpiContext != IntPtr.Zero)
            {
                SetThreadDpiAwarenessContext(previousDpiContext);
            }
        }
    }

    public static IntPtr FindRenderer(IntPtr parent)
    {
        IntPtr result = IntPtr.Zero;
        EnumChildWindows(
            parent,
            delegate(IntPtr hwnd, IntPtr lParam)
            {
                var name = new StringBuilder(256);
                GetClassName(hwnd, name, name.Capacity);
                if (name.ToString() == "Chrome_RenderWidgetHostHWND")
                {
                    result = hwnd;
                    return false;
                }
                return true;
            },
            IntPtr.Zero
        );
        return result;
    }

    public static bool ScrollRenderer(IntPtr renderer, int wheelDelta, int count)
    {
        RECT rect = ReadWindowRect(renderer);
        int x = (rect.Left + rect.Right) / 2;
        int y = rect.Top + ((rect.Bottom - rect.Top) * 3 / 4);
        long lParamValue =
            ((long)(y & 0xffff) << 16) | (uint)(x & 0xffff);
        long wParamValue = ((long)(wheelDelta & 0xffff) << 16);
        bool delivered = true;
        for (int index = 0; index < count; index++)
        {
            delivered =
                PostMessage(
                    renderer,
                    WM_MOUSEWHEEL,
                    new IntPtr(wParamValue),
                    new IntPtr(lParamValue)
                ) && delivered;
        }
        return delivered;
    }

    public static string MaximizeInBackground(
        IntPtr hwnd,
        IntPtr expectedForeground
    )
    {
        IntPtr previousDpiContext = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try
        {
            bool toolWindow = ApplyCaptureWindowStyle(hwnd);
            var placement = new WINDOWPLACEMENT
            {
                Length = Marshal.SizeOf(typeof(WINDOWPLACEMENT)),
            };
            if (!GetWindowPlacement(hwnd, ref placement))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            placement.ShowCmd = 3;
            if (!SetWindowPlacement(hwnd, ref placement))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            const uint SWP_NOSIZE = 0x0001;
            const uint SWP_NOMOVE = 0x0002;
            const uint SWP_NOACTIVATE = 0x0010;
            const uint SWP_NOOWNERZORDER = 0x0200;
            ShowWindow(hwnd, 8);
            if (!SetWindowPos(
                hwnd,
                new IntPtr(1),
                0,
                0,
                0,
                0,
                SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOOWNERZORDER
            ))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            Thread.Sleep(750);
            if (!IsZoomed(hwnd))
            {
                throw new InvalidOperationException("The target window did not maximize.");
            }

            IntPtr actualForeground = GetForegroundWindow();
            if (
                expectedForeground != IntPtr.Zero &&
                actualForeground != expectedForeground
            )
            {
                throw new InvalidOperationException(
                    "Background capture changed the active foreground window."
                );
            }

            uint dpi = GetDpiForWindow(hwnd);
            RECT window = ReadWindowRect(hwnd);
            RECT client = ReadClientRect(hwnd);
            int physicalWidth = client.Right - client.Left;
            int physicalHeight = client.Bottom - client.Top;
            return String.Format(
                "maximized=true;foregroundPreserved={0};toolWindow={1};client={2}x{3};clientPhysical={4}x{5};outer={6}x{7};dpi={8}",
                expectedForeground == IntPtr.Zero || actualForeground == expectedForeground,
                toolWindow,
                UnscaleForDpi(physicalWidth, dpi),
                UnscaleForDpi(physicalHeight, dpi),
                physicalWidth,
                physicalHeight,
                window.Right - window.Left,
                window.Bottom - window.Top,
                dpi
            );
        }
        finally
        {
            if (previousDpiContext != IntPtr.Zero)
            {
                SetThreadDpiAwarenessContext(previousDpiContext);
            }
        }
    }

    public static bool ScrollRendererPage(IntPtr renderer, int wheelDelta, int count)
    {
        RECT rect = ReadWindowRect(renderer);
        int x = rect.Right - 12;
        int y = (rect.Top + rect.Bottom) / 2;
        long lParamValue =
            ((long)(y & 0xffff) << 16) | (uint)(x & 0xffff);
        long wParamValue = ((long)(wheelDelta & 0xffff) << 16);
        bool delivered = true;
        for (int index = 0; index < count; index++)
        {
            delivered =
                PostMessage(
                    renderer,
                    WM_MOUSEWHEEL,
                    new IntPtr(wParamValue),
                    new IntPtr(lParamValue)
                ) && delivered;
        }
        return delivered;
    }

    public static bool ScrollRendererHorizontal(
        IntPtr renderer,
        int wheelDelta,
        int count
    )
    {
        IntPtr previousDpiContext = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try
        {
            RECT rect = ReadWindowRect(renderer);
            int x = (rect.Left + rect.Right) / 2;
            int y = (rect.Top + rect.Bottom) / 2;
            long lParamValue =
                ((long)(y & 0xffff) << 16) | (uint)(x & 0xffff);
            long wParamValue = ((long)(wheelDelta & 0xffff) << 16);
            bool delivered = true;
            for (int index = 0; index < count; index++)
            {
                delivered =
                    PostMessage(
                        renderer,
                        WM_MOUSEHWHEEL,
                        new IntPtr(wParamValue),
                        new IntPtr(lParamValue)
                    ) && delivered;
            }
            return delivered;
        }
        finally
        {
            if (previousDpiContext != IntPtr.Zero)
            {
                SetThreadDpiAwarenessContext(previousDpiContext);
            }
        }
    }
}
'@
}

function Test-CargoToolchain {
  param(
    [System.Management.Automation.CommandInfo] $Cargo,
    [string] $Toolchain
  )

  if ($null -eq $Cargo) {
    return $false
  }

  try {
    & $Cargo.Source "+$Toolchain" --version *> $null
    return $LASTEXITCODE -eq 0
  } catch {
    return $false
  }
}

function Get-PreflightManifest {
  param([string] $ResolvedOutputRoot, [pscustomobject] $Compiler)

  $uiAutomationReady = $true
  try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
  } catch {
    $uiAutomationReady = $false
  }
  $nativeDriverReady = $true
  try {
    Initialize-NativeVisualDriver
  } catch {
    $nativeDriverReady = $false
  }

  $cargo = Get-Command cargo.exe -ErrorAction SilentlyContinue
  if ($null -eq $cargo) {
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
  }
  $cargoToolchainReady = Test-CargoToolchain `
    -Cargo $cargo `
    -Toolchain $requiredRustToolchain
  $git = Get-Command git.exe -ErrorAction SilentlyContinue
  if ($null -eq $git) {
    $git = Get-Command git -ErrorAction SilentlyContinue
  }

  return [ordered]@{
    capture_engine = 'Windows.Graphics.Capture'
    targeting = 'exact HWND'
    activation_mode = 'non-activating'
    foreground_policy = 'preserve active window'
    z_order_policy = 'background'
    startup_window_mode = 'hidden until explicitly shown; background activation forbidden'
    capture_argument = '--codexu-native-capture-background'
    taskbar_policy = 'excluded'
    alt_tab_policy = 'excluded'
    capture_runs = @($captureRuns)
    client_sizes = @()
    surfaces = @($requestedSurfaces)
    window_mode = 'maximized exact HWND'
    overview_file = if ($captureOverview) { 'fullscreen/overview.png' } else { $null }
    surface_capture_mode = if ($singlePanelCapture) {
      'maximized first panel viewport'
    } else {
      'maximized panel viewport sequence'
    }
    projects_capture_mode = 'first panel viewport'
    segment_overlap_ratio = $segmentOverlapRatio
    max_segments_per_surface = $maxSegmentsPerSurface
    surface_file_pattern = $surfaceFilePattern
    required_rust_toolchain = $requiredRustToolchain
    build_command = "cargo +$requiredRustToolchain tauri build --no-bundle"
    app_executable_relative = 'windows/target/release/codexu-tauri.exe'
    output_root = $ResolvedOutputRoot
    prerequisites = [ordered]@{
      windows = (
        [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
      )
      cargo = ($null -ne $cargo)
      cargo_toolchain = $cargoToolchainReady
      git = ($null -ne $git)
      helper_source = (Test-Path -LiteralPath $helperSource -PathType Leaf)
      csharp_compiler = (Test-CompilerReady -Compiler $Compiler)
      windows_metadata = (
        $null -ne $Compiler.windows_metadata -and
        (Test-Path -LiteralPath $Compiler.windows_metadata -PathType Leaf)
      )
      windows_metadata_version = $Compiler.windows_metadata_version
      ui_automation = $uiAutomationReady
      native_driver = $nativeDriverReady
    }
    writes_performed = $false
  }
}

function Assert-PreflightReady {
  param([System.Collections.IDictionary] $Preflight)
  $problems = @()
  if (-not [bool]$Preflight.prerequisites.cargo) {
    $problems += 'cargo was not found in PATH; install Rust with rustup and reopen the shell'
  } elseif (-not [bool]$Preflight.prerequisites.cargo_toolchain) {
    $toolchain = $Preflight.required_rust_toolchain
    $problems += (
      "required Rust toolchain '$toolchain' is unavailable; run " +
      "'rustup toolchain install $toolchain --profile minimal --component rustfmt'"
    )
  }

  $problems += @(
    $Preflight.prerequisites.GetEnumerator() |
      Where-Object {
        $_.Key -notin @('cargo', 'cargo_toolchain') -and
        -not [bool]$_.Value
      } |
      ForEach-Object { $_.Key }
  )
  if ($problems.Count -gt 0) {
    throw ('Native visual preflight failed: ' + ($problems -join '; '))
  }
}

function Test-OutputRootIgnored {
  param([string] $ResolvedOutputRoot)
  $relative = $ResolvedOutputRoot.Substring($repositoryRoot.Length).TrimStart([char[]]"\/")
  $relative = $relative.Replace('\', '/')
  Push-Location $repositoryRoot
  try {
    & git check-ignore -q -- $relative
    if ($LASTEXITCODE -ne 0) {
      throw 'The local native visual output root is not covered by Git ignore rules.'
    }
  } finally {
    Pop-Location
  }
}

function Invoke-LoggedProcess {
  param(
    [string] $FileName,
    [string[]] $Arguments,
    [string] $WorkingDirectory,
    [string] $LogPath
  )

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FileName
  $startInfo.Arguments = ($Arguments -join ' ')
  $startInfo.WorkingDirectory = $WorkingDirectory
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    throw "Could not start $FileName."
  }
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  $stdout = $stdoutTask.Result
  $stderr = $stderrTask.Result
  [System.IO.File]::WriteAllText(
    $LogPath,
    $stdout + [Environment]::NewLine + $stderr,
    [System.Text.UTF8Encoding]::new($false)
  )
  if ($process.ExitCode -ne 0) {
    throw "$FileName failed with exit code $($process.ExitCode). See the local run log."
  }
}

function Build-CaptureHelper {
  param(
    [pscustomobject] $Compiler,
    [string] $OutputPath,
    [string] $LogPath
  )
  $arguments = @(
    '/nologo',
    '/target:exe',
    "/out:$OutputPath",
    "/reference:$($Compiler.windows_metadata)",
    "/reference:$($Compiler.runtime_windows)",
    "/reference:$($Compiler.runtime)",
    "/reference:$($Compiler.drawing)",
    $helperSource
  )
  $compilerOutput = @(& $Compiler.compiler @arguments 2>&1)
  $compilerExitCode = $LASTEXITCODE
  $compilerOutput | Out-File -LiteralPath $LogPath -Encoding utf8
  if ($compilerExitCode -ne 0) {
    throw "Graphics capture helper compilation failed with exit code $compilerExitCode."
  }
  if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    throw 'Graphics capture helper compilation did not create the expected executable.'
  }
}

function Get-ProcessIdentity {
  param([int] $ProcessId)
  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" `
    -ErrorAction SilentlyContinue
  if ($null -eq $process) {
    return $null
  }
  $creation = $null
  if ($null -ne $process.CreationDate) {
    $creation = ([datetime]$process.CreationDate).ToUniversalTime().ToString('o')
  }
  return [pscustomobject]@{
    process_id = [int]$process.ProcessId
    parent_process_id = [int]$process.ParentProcessId
    name = [string]$process.Name
    executable_path = [string]$process.ExecutablePath
    creation_utc = $creation
  }
}

function Get-TaskDescendantIdentities {
  param([int] $RootProcessId)
  $all = @(Get-CimInstance Win32_Process)
  $known = [System.Collections.Generic.HashSet[int]]::new()
  $queue = [System.Collections.Generic.Queue[int]]::new()
  [void]$known.Add($RootProcessId)
  $queue.Enqueue($RootProcessId)
  $results = [System.Collections.ArrayList]::new()

  while ($queue.Count -gt 0) {
    $parent = $queue.Dequeue()
    foreach ($candidate in @($all | Where-Object {
      [int]$_.ParentProcessId -eq $parent
    })) {
      $candidateId = [int]$candidate.ProcessId
      if ($known.Add($candidateId)) {
        $queue.Enqueue($candidateId)
        $identity = Get-ProcessIdentity -ProcessId $candidateId
        if ($null -ne $identity) {
          [void]$results.Add($identity)
        }
      }
    }
  }
  return @($results)
}

function Add-RecordedIdentity {
  param(
    [System.Collections.ArrayList] $Records,
    [pscustomobject] $Identity
  )
  if ($null -eq $Identity) {
    return
  }
  $alreadyRecorded = @($Records | Where-Object {
    $_.process_id -eq $Identity.process_id -and
    $_.creation_utc -eq $Identity.creation_utc
  }).Count -gt 0
  if (-not $alreadyRecorded) {
    [void]$Records.Add($Identity)
  }
}

function Update-TaskProcessRecords {
  param(
    [int] $RootProcessId,
    [System.Collections.ArrayList] $Records
  )
  Add-RecordedIdentity -Records $Records -Identity (
    Get-ProcessIdentity -ProcessId $RootProcessId
  )
  foreach ($identity in @(Get-TaskDescendantIdentities -RootProcessId $RootProcessId)) {
    Add-RecordedIdentity -Records $Records -Identity $identity
  }
}

function Test-RecordedIdentity {
  param([pscustomobject] $Recorded, [pscustomobject] $Current)
  if ($null -eq $Current) {
    return $false
  }
  return (
    $Recorded.process_id -eq $Current.process_id -and
    $Recorded.name -eq $Current.name -and
    $Recorded.creation_utc -eq $Current.creation_utc -and
    $Recorded.executable_path -eq $Current.executable_path
  )
}

function Stop-RecordedTaskProcesses {
  param(
    [int] $RootProcessId,
    [System.Collections.ArrayList] $Records
  )

  Update-TaskProcessRecords -RootProcessId $RootProcessId -Records $Records
  $stopped = [System.Collections.ArrayList]::new()
  $alreadyExited = [System.Collections.ArrayList]::new()
  $identityMismatches = [System.Collections.ArrayList]::new()

  $rootRecord = @($Records | Where-Object {
    $_.process_id -eq $RootProcessId
  } | Select-Object -First 1)
  if ($rootRecord.Count -eq 1) {
    $currentRoot = Get-ProcessIdentity -ProcessId $RootProcessId
    if ($null -eq $currentRoot) {
      [void]$alreadyExited.Add($RootProcessId)
    } elseif (Test-RecordedIdentity -Recorded $rootRecord[0] -Current $currentRoot) {
      Stop-Process -Id $RootProcessId -Force -ErrorAction SilentlyContinue
      [void]$stopped.Add($RootProcessId)
    } else {
      [void]$identityMismatches.Add($RootProcessId)
    }
  }

  $rootDeadline = (Get-Date).AddSeconds(8)
  while ((Get-Date) -lt $rootDeadline -and $null -ne (
    Get-ProcessIdentity -ProcessId $RootProcessId
  )) {
    Start-Sleep -Milliseconds 100
  }

  foreach ($record in @($Records | Where-Object {
    $_.process_id -ne $RootProcessId
  } | Sort-Object process_id -Descending)) {
    $current = Get-ProcessIdentity -ProcessId $record.process_id
    if ($null -eq $current) {
      [void]$alreadyExited.Add($record.process_id)
    } elseif (Test-RecordedIdentity -Recorded $record -Current $current) {
      Stop-Process -Id $record.process_id -Force -ErrorAction SilentlyContinue
      [void]$stopped.Add($record.process_id)
    } else {
      [void]$identityMismatches.Add($record.process_id)
    }
  }

  $deadline = (Get-Date).AddSeconds(8)
  do {
    $remaining = @(
      $Records | Where-Object {
        $current = Get-ProcessIdentity -ProcessId $_.process_id
        Test-RecordedIdentity -Recorded $_ -Current $current
      }
    )
    if ($remaining.Count -eq 0) {
      break
    }
    Start-Sleep -Milliseconds 100
  } while ((Get-Date) -lt $deadline)

  return [ordered]@{
    recorded_count = $Records.Count
    stopped_process_ids = @($stopped)
    already_exited_process_ids = @($alreadyExited)
    identity_mismatch_process_ids = @($identityMismatches)
    remaining_matching_process_ids = @($remaining | ForEach-Object { $_.process_id })
  }
}

function Get-ExactExecutableProcesses {
  param([string] $ExecutablePath)
  if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
    return @()
  }
  $name = [System.IO.Path]::GetFileName($ExecutablePath).Replace("'", "''")
  return @(
    Get-CimInstance Win32_Process -Filter "Name = '$name'" |
      Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
        [string]::Equals(
          [System.IO.Path]::GetFullPath($_.ExecutablePath),
          [System.IO.Path]::GetFullPath($ExecutablePath),
          [System.StringComparison]::OrdinalIgnoreCase
        )
      }
  )
}

function Wait-TaskWindow {
  param(
    [System.Diagnostics.Process] $Process,
    [IntPtr] $ExpectedForeground
  )
  $deadline = (Get-Date).AddSeconds(60)
  do {
    if ($Process.HasExited) {
      throw 'The task application exited before its main window was ready.'
    }
    Start-Sleep -Milliseconds 25
    Assert-ForegroundPreserved `
      -ExpectedForeground $ExpectedForeground `
      -Stage 'startup polling before window preparation'
    $Process.Refresh()
  } while ($Process.MainWindowHandle -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline)
  if ($Process.MainWindowHandle -eq [IntPtr]::Zero) {
    throw 'Timed out waiting for the task application main window.'
  }
  return $Process.MainWindowHandle
}

function Assert-ForegroundPreserved {
  param(
    [IntPtr] $ExpectedForeground,
    [string] $Stage
  )
  if ($ExpectedForeground -eq [IntPtr]::Zero) {
    return
  }
  $actualForeground = [NativeVisualCaptureDriver]::GetForegroundWindowHandle()
  if ($actualForeground -ne $ExpectedForeground) {
    throw "Background capture changed the active foreground window during $Stage."
  }
}

function Find-ElementByAutomationId {
  param([IntPtr] $Window, [string] $AutomationId)
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($Window)
  $condition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
    $AutomationId
  )
  return $root.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    $condition
  )
}

function Wait-ForElement {
  param(
    [IntPtr] $Window,
    [string] $AutomationId,
    [int] $TimeoutSeconds = 30
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $element = Find-ElementByAutomationId -Window $Window -AutomationId $AutomationId
    if ($null -ne $element) {
      return $element
    }
    Start-Sleep -Milliseconds 150
  } while ((Get-Date) -lt $deadline)
  throw "Timed out waiting for UI element $AutomationId."
}

function Select-DashboardTab {
  param([IntPtr] $Window, [string] $TabId, [string] $PanelId)
  $tab = Wait-ForElement -Window $Window -AutomationId $TabId
  $pattern = $tab.GetCurrentPattern(
    [System.Windows.Automation.SelectionItemPattern]::Pattern
  )
  $pattern.Select()
  [void](Wait-ForElement -Window $Window -AutomationId $PanelId -TimeoutSeconds 20)
}

function Move-DashboardScrollToTop {
  param([IntPtr] $Renderer)
  [void][NativeVisualCaptureDriver]::ScrollRendererPage($Renderer, 120, 40)
  Start-Sleep -Milliseconds 650
}

function Get-ClientScreenBounds {
  param([IntPtr] $Window)
  $description = [NativeVisualCaptureDriver]::GetClientScreenBounds($Window)
  if ($description -notmatch '^left=(?<left>-?\d+);top=(?<top>-?\d+);right=(?<right>-?\d+);bottom=(?<bottom>-?\d+)$') {
    throw "Could not parse client screen bounds: $description"
  }
  return [pscustomobject]@{
    left = [int]$Matches.left
    top = [int]$Matches.top
    right = [int]$Matches.right
    bottom = [int]$Matches.bottom
  }
}

function Move-RendererToLeft {
  param([IntPtr] $Renderer)
  [void][NativeVisualCaptureDriver]::ScrollRendererHorizontal(
    $Renderer,
    -120,
    32
  )
  Start-Sleep -Milliseconds 250
}

$script:dashboardPanelElementCache = @{}

function Get-DashboardPanelObservation {
  param(
    [IntPtr] $Window,
    [string] $PanelId
  )
  $client = Get-ClientScreenBounds -Window $Window
  # WebView2 can briefly rebuild the accessibility subtree after a wheel scroll.
  # Keep this wait bounded, but do not treat that normal rebuild window as a
  # missing Dashboard panel.
  try {
    $panel = Wait-ForElement -Window $Window -AutomationId $PanelId -TimeoutSeconds 20
    $script:dashboardPanelElementCache[$PanelId] = $panel
  } catch {
    if (-not $script:dashboardPanelElementCache.ContainsKey($PanelId)) {
      throw
    }
    # WebView2 may replace the accessibility node while processing a wheel
    # event. The first successful AutomationElement remains a valid live
    # provider for Current.BoundingRectangle during that transition.
    $panel = $script:dashboardPanelElementCache[$PanelId]
  }
  $panelRect = $panel.Current.BoundingRectangle
  $panelVisible = (
    -not $panel.Current.IsOffscreen -and
    $panelRect.Height -gt 0 -and
    $panelRect.Bottom -gt $client.top -and
    $panelRect.Top -lt $client.bottom
  )
  return [ordered]@{
    panel_visible = $panelVisible
    panel_start_visible = (
      $panelVisible -and
      $panelRect.Top -ge $client.top -and
      $panelRect.Top -lt $client.bottom
    )
    panel_end_visible = (
      $panelVisible -and
      $panelRect.Bottom -gt $client.top -and
      $panelRect.Bottom -le $client.bottom
    )
    panel_top = [int]$panelRect.Top
    panel_bottom = [int]$panelRect.Bottom
    client_top = $client.top
    client_bottom = $client.bottom
    client_height = [int]($client.bottom - $client.top)
  }
}

function Align-DashboardPanelStart {
  param(
    [IntPtr] $Window,
    [IntPtr] $Renderer,
    [string] $PanelId
  )
  $scrollSettleMilliseconds = 650
  $lastObservation = $null
  $previousPanelTop = $null
  $stablePanelTopCount = 0
  for ($step = 0; $step -le 18; $step++) {
    $observation = Get-DashboardPanelObservation -Window $Window -PanelId $PanelId
    $alignmentBottom = $observation.client_top + [int]($observation.client_height * 0.24)
    $lastObservation = $observation
    if (
      $null -ne $previousPanelTop -and
      [math]::Abs($observation.panel_top - $previousPanelTop) -le 1
    ) {
      $stablePanelTopCount++
    } else {
      $stablePanelTopCount = 0
    }
    $previousPanelTop = $observation.panel_top
    if ($observation.panel_start_visible -and $observation.panel_top -le $alignmentBottom) {
      return [ordered]@{
        scroll_steps = $step
        panel_start_visible = $true
        panel_top_in_client = [int]($observation.panel_top - $observation.client_top)
        limited_by_page_end = $false
      }
    }
    if ($observation.panel_start_visible -and $stablePanelTopCount -ge 3) {
      return [ordered]@{
        scroll_steps = $step
        panel_start_visible = $true
        panel_top_in_client = [int]($observation.panel_top - $observation.client_top)
        limited_by_page_end = $true
      }
    }
    [void][NativeVisualCaptureDriver]::ScrollRendererPage($Renderer, -120, 1)
    Start-Sleep -Milliseconds $scrollSettleMilliseconds
  }
  throw (
    "Could not align the beginning of $PanelId in the client area. " +
    ($lastObservation | ConvertTo-Json -Compress)
  )
}

function Move-DashboardPanelViewport {
  param(
    [IntPtr] $Window,
    [IntPtr] $Renderer,
    [string] $PanelId
  )
  $scrollSettleMilliseconds = 650
  $initial = Get-DashboardPanelObservation -Window $Window -PanelId $PanelId
  $targetDistance = [int]($initial.client_height * (1.0 - $segmentOverlapRatio))
  $previousTop = $initial.panel_top
  $distance = 0
  $stableCount = 0
  $moved = $false

  for ($message = 1; $message -le 12; $message++) {
    [void][NativeVisualCaptureDriver]::ScrollRendererPage($Renderer, -120, 1)
    Start-Sleep -Milliseconds $scrollSettleMilliseconds
    $current = Get-DashboardPanelObservation -Window $Window -PanelId $PanelId
    $delta = $previousTop - $current.panel_top
    if ([math]::Abs($delta) -le 1) {
      $stableCount++
    } else {
      $stableCount = 0
      $moved = $true
      $distance += [math]::Max(0, $delta)
    }
    $previousTop = $current.panel_top

    if ($distance -ge $targetDistance) {
      return [ordered]@{
        moved = $moved
        page_end = $false
        scroll_messages = $message
        distance = $distance
      }
    }
    if ($stableCount -ge 3) {
      return [ordered]@{
        moved = $moved
        page_end = $true
        scroll_messages = $message
        distance = $distance
      }
    }
  }

  return [ordered]@{
    moved = $moved
    page_end = $false
    scroll_messages = 12
    distance = $distance
  }
}

function Capture-DashboardSurfaceSegments {
  param(
    [IntPtr] $Window,
    [IntPtr] $Renderer,
    [System.Collections.IDictionary] $Surface,
    [string] $CaptureTool,
    [string] $OutputDirectory,
    [string] $LogPath,
    [System.Collections.IDictionary] $SizeRecord
  )

  $alignment = Align-DashboardPanelStart `
    -Window $Window `
    -Renderer $Renderer `
    -PanelId $Surface.panel
  $scrollSteps = [int]$alignment.scroll_steps
  $atPageEnd = [bool]$alignment.limited_by_page_end
  $firstViewportOnly = $singlePanelCapture -or $Surface.name -eq 'Projects'
  $coverageMode = if ($firstViewportOnly) {
    'first panel viewport'
  } else {
    'panel viewport sequence'
  }
  $records = @()

  for ($segment = 1; $segment -le $maxSegmentsPerSurface; $segment++) {
    $observation = Get-DashboardPanelObservation `
      -Window $Window `
      -PanelId $Surface.panel
    if ($segment -eq 1 -and -not $observation.panel_start_visible) {
      throw "The first $($Surface.name) segment does not cover the panel start."
    }

    $outputPath = Join-Path $OutputDirectory (
      '{0}-{1:D2}.png' -f $Surface.slug, $segment
    )
    $capture = Invoke-GraphicsCapture `
      -CaptureTool $CaptureTool `
      -Window $Window `
      -OutputPath $outputPath `
      -LogPath $LogPath
    $record = [ordered]@{
      surface = $Surface.name
      segment = $segment
      is_first = ($segment -eq 1)
      is_last = $false
      coverage_mode = $coverageMode
      panel_visible = [bool]$observation.panel_visible
      panel_start_visible = [bool]$observation.panel_start_visible
      panel_end_visible = [bool]$observation.panel_end_visible
      scroll_steps = $scrollSteps
      panel_top_in_client = [int]($observation.panel_top - $observation.client_top)
      panel_bottom_in_client = [int]($observation.panel_bottom - $observation.client_top)
      client_height = [int]$observation.client_height
      limited_by_page_end = $atPageEnd
      file = $outputPath
      physical_frame = $capture.physical_frame
      bytes = $capture.bytes
    }
    $records += $record
    $SizeRecord.captures += $record
    Save-WorkflowManifest

    if ($firstViewportOnly) {
      $records[-1].is_last = $true
      Save-WorkflowManifest
      return @($records)
    }

    if ($observation.panel_end_visible) {
      $records[-1].is_last = $true
      Save-WorkflowManifest
      return @($records)
    }
    if ($atPageEnd) {
      throw "Reached a stable page end before the bottom of $($Surface.name) was visible."
    }

    $advance = Move-DashboardPanelViewport `
      -Window $Window `
      -Renderer $Renderer `
      -PanelId $Surface.panel
    $scrollSteps += [int]$advance.scroll_messages
    if (-not [bool]$advance.moved) {
      $records[-1].limited_by_page_end = $true
      Save-WorkflowManifest
      throw "Could not advance $($Surface.name) before its panel end was visible."
    }
    $atPageEnd = [bool]$advance.page_end
  }

  throw "Exceeded $maxSegmentsPerSurface segments while capturing $($Surface.name)."
}

function Set-MaximizedWindow {
  param(
    [IntPtr] $Window,
    [IntPtr] $ExpectedForeground
  )
  $description = [NativeVisualCaptureDriver]::MaximizeInBackground(
    $Window,
    $ExpectedForeground
  )
  if ($description -notmatch '^maximized=(?<maximized>true);foregroundPreserved=(?<foregroundPreserved>true|false);toolWindow=(?<toolWindow>true|false);client=(?<width>\d+)x(?<height>\d+);clientPhysical=(?<physicalWidth>\d+)x(?<physicalHeight>\d+);outer=(?<outerWidth>\d+)x(?<outerHeight>\d+);dpi=(?<dpi>\d+)$') {
    throw "Could not parse maximized window dimensions: $description"
  }
  return [ordered]@{
    maximized = $true
    activation_mode = 'non-activating'
    foreground_policy = 'preserve active window'
    foreground_preserved = [bool]::Parse($Matches.foregroundPreserved)
    z_order_policy = 'background'
    taskbar_policy = 'excluded'
    alt_tab_policy = 'excluded'
    tool_window = [bool]::Parse($Matches.toolWindow)
    verified_client = "$($Matches.width)x$($Matches.height)"
    physical_client = "$($Matches.physicalWidth)x$($Matches.physicalHeight)"
    outer_window = "$($Matches.outerWidth)x$($Matches.outerHeight)"
    dpi = [int]$Matches.dpi
  }
}

function Invoke-GraphicsCapture {
  param(
    [string] $CaptureTool,
    [IntPtr] $Window,
    [string] $OutputPath,
    [string] $LogPath
  )
  $output = @(& $CaptureTool ([long]$Window) $OutputPath 2>&1)
  $exitCode = $LASTEXITCODE
  $output | Add-Content -LiteralPath $LogPath -Encoding utf8
  if ($exitCode -ne 0) {
    throw "Windows Graphics Capture failed with exit code $exitCode."
  }
  if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    throw 'Windows Graphics Capture did not create the expected local PNG.'
  }
  $file = Get-Item -LiteralPath $OutputPath
  if ($file.Length -le 0) {
    throw 'Windows Graphics Capture created an empty PNG.'
  }
  $captureLine = @($output | Where-Object { "$_" -match '^CAPTURE_OK ' }) |
    Select-Object -Last 1
  if ($null -eq $captureLine -or "$captureLine" -notmatch '^CAPTURE_OK (?<size>\d+x\d+)$') {
    throw 'Windows Graphics Capture did not report a physical frame size.'
  }
  return [ordered]@{
    physical_frame = $Matches.size
    bytes = $file.Length
  }
}

function Save-WorkflowManifest {
  if ($null -ne $script:workflowManifest -and $null -ne $script:manifestPath) {
    $json = $script:workflowManifest | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText(
      $script:manifestPath,
      $json,
      [System.Text.UTF8Encoding]::new($false)
    )
  }
}

function Invoke-MaximizedCapture {
  param(
    [string] $CaptureTool,
    [string] $ScreenshotsRoot,
    [string] $RuntimeRoot,
    [string] $LogsRoot
  )

  $label = 'fullscreen'
  $sizeScreenshots = Join-Path $ScreenshotsRoot $label
  $sizeRuntime = Join-Path $RuntimeRoot $label
  New-Item -ItemType Directory -Path $sizeScreenshots, $sizeRuntime | Out-Null

  $sizeRecord = [ordered]@{
    run = $label
    status = 'starting'
    window = $null
    captures = @()
    process_records = @()
    cleanup = $null
  }
  $script:workflowManifest.fullscreen_run = $sizeRecord
  Save-WorkflowManifest

  $process = $null
  $stdoutTask = $null
  $stderrTask = $null
  $records = [System.Collections.ArrayList]::new()
  $foregroundBefore = [NativeVisualCaptureDriver]::GetForegroundWindowHandle()
  try {
    $appData = Join-Path $sizeRuntime 'appdata'
    $localAppData = Join-Path $sizeRuntime 'localappdata'
    $webViewData = Join-Path $sizeRuntime 'webview2'
    New-Item -ItemType Directory -Path $appData, $localAppData, $webViewData | Out-Null

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $appPath
    $startInfo.WorkingDirectory = Split-Path -Parent $appPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.Arguments = '--codexu-native-capture-background'
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['APPDATA'] = $appData
    $startInfo.EnvironmentVariables['LOCALAPPDATA'] = $localAppData
    $startInfo.EnvironmentVariables['WEBVIEW2_USER_DATA_FOLDER'] = $webViewData

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
      throw 'Could not start the task application.'
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    Update-TaskProcessRecords -RootProcessId $process.Id -Records $records

    $window = Wait-TaskWindow `
      -Process $process `
      -ExpectedForeground $foregroundBefore
    Assert-ForegroundPreserved `
      -ExpectedForeground $foregroundBefore `
      -Stage 'startup before window preparation'
    $sizeRecord.window = Set-MaximizedWindow `
      -Window $window `
      -ExpectedForeground $foregroundBefore
    [void](Wait-ForElement -Window $window -AutomationId 'dashboard-home-tab-tasks')
    $renderer = [NativeVisualCaptureDriver]::FindRenderer($window)
    if ($renderer -eq [IntPtr]::Zero) {
      throw 'Could not identify the task application renderer child HWND.'
    }
    Update-TaskProcessRecords -RootProcessId $process.Id -Records $records

    if ($captureOverview) {
      Move-DashboardScrollToTop -Renderer $renderer
      Move-RendererToLeft -Renderer $renderer
      Start-Sleep -Milliseconds 700
      $overviewPath = Join-Path $sizeScreenshots 'overview.png'
      $overviewCapture = Invoke-GraphicsCapture `
        -CaptureTool $CaptureTool `
        -Window $window `
        -OutputPath $overviewPath `
        -LogPath (Join-Path $LogsRoot 'graphics-capture.log')
      $sizeRecord.captures += [ordered]@{
        surface = 'Overview'
        framing = 'page top in maximized window'
        file = $overviewPath
        physical_frame = $overviewCapture.physical_frame
        bytes = $overviewCapture.bytes
      }
      Save-WorkflowManifest
    }

    foreach ($surface in $selectedPanelSurfaces) {
      Select-DashboardTab `
        -Window $window `
        -TabId $surface.tab `
        -PanelId $surface.panel
      Move-DashboardScrollToTop -Renderer $renderer
      Move-RendererToLeft -Renderer $renderer
      [void](Capture-DashboardSurfaceSegments `
        -Window $window `
        -Renderer $renderer `
        -Surface $surface `
        -CaptureTool $CaptureTool `
        -OutputDirectory $sizeScreenshots `
        -LogPath (Join-Path $LogsRoot 'graphics-capture.log') `
        -SizeRecord $sizeRecord)
      Update-TaskProcessRecords -RootProcessId $process.Id -Records $records
      Save-WorkflowManifest
    }
    $sizeRecord.status = 'captured'
  } catch {
    $sizeRecord.status = 'failed'
    $sizeRecord.error = $_.Exception.Message
    throw
  } finally {
    if ($null -ne $process) {
      $sizeRecord.cleanup = Stop-RecordedTaskProcesses `
        -RootProcessId $process.Id `
        -Records $records
      $sizeRecord.process_records = @($records)
      if ($null -ne $stdoutTask) {
        [void]$stdoutTask.Wait(5000)
        if ($stdoutTask.IsCompleted) {
          [System.IO.File]::WriteAllText(
            (Join-Path $LogsRoot "app-$label.stdout.log"),
            $stdoutTask.Result,
            [System.Text.UTF8Encoding]::new($false)
          )
        }
      }
      if ($null -ne $stderrTask) {
        [void]$stderrTask.Wait(5000)
        if ($stderrTask.IsCompleted) {
          [System.IO.File]::WriteAllText(
            (Join-Path $LogsRoot "app-$label.stderr.log"),
            $stderrTask.Result,
            [System.Text.UTF8Encoding]::new($false)
          )
        }
      }
      if ($sizeRecord.cleanup.remaining_matching_process_ids.Count -gt 0) {
        $sizeRecord.status = 'cleanup-failed'
        Save-WorkflowManifest
        throw "Task-owned processes remained after the $label capture."
      }
      if ($sizeRecord.status -eq 'captured') {
        $sizeRecord.status = 'complete'
      }
    }
    Save-WorkflowManifest
  }
}

$resolvedOutputRoot = Get-NormalizedOutputRoot -RequestedPath $OutputRoot
$compiler = Get-CaptureCompiler
$preflight = Get-PreflightManifest `
  -ResolvedOutputRoot $resolvedOutputRoot `
  -Compiler $compiler
Assert-PreflightReady -Preflight $preflight

if ($PreflightOnly) {
  Write-Output (
    'NATIVE_VISUAL_PREFLIGHT=' +
    ($preflight | ConvertTo-Json -Depth 6 -Compress)
  )
  return
}

if (Test-Path -LiteralPath $resolvedOutputRoot) {
  throw "Refusing to overwrite an existing native visual output directory."
}
Test-OutputRootIgnored -ResolvedOutputRoot $resolvedOutputRoot

$screenshotsRoot = Join-Path $resolvedOutputRoot 'screenshots'
$logsRoot = Join-Path $resolvedOutputRoot 'logs'
$runtimeRoot = Join-Path $resolvedOutputRoot 'runtime'
$toolsRoot = Join-Path $resolvedOutputRoot 'tools'
New-Item -ItemType Directory -Path (
  $resolvedOutputRoot,
  $screenshotsRoot,
  $logsRoot,
  $runtimeRoot,
  $toolsRoot
) | Out-Null

$script:manifestPath = Join-Path $resolvedOutputRoot 'manifest.json'
$branch = (& git -C $repositoryRoot branch --show-current).Trim()
$sha = (& git -C $repositoryRoot rev-parse HEAD).Trim()
$script:workflowManifest = [ordered]@{
  status = 'running'
  started_utc = (Get-Date).ToUniversalTime().ToString('o')
  completed_utc = $null
  checkout = [ordered]@{
    branch = $branch
    sha = $sha
  }
  capture_engine = 'Windows.Graphics.Capture'
  targeting = 'exact HWND'
  activation_mode = 'non-activating'
  foreground_policy = 'preserve active window'
  z_order_policy = 'background'
  startup_window_mode = 'hidden until explicitly shown; background activation forbidden'
  capture_argument = '--codexu-native-capture-background'
  taskbar_policy = 'excluded'
  alt_tab_policy = 'excluded'
  real_local_codex_input = 'read-only'
  app_runtime_storage = 'task-local under .local-artifacts'
  build = [ordered]@{
    command = $preflight.build_command
    skipped = [bool]$SkipBuild
    result = 'pending'
  }
  fullscreen_run = $null
  size_runs = @()
  screenshot_count = 0
  final_process_cleanup = 'pending'
  error = $null
}
Save-WorkflowManifest

try {
  $existingBeforeBuild = @(Get-ExactExecutableProcesses -ExecutablePath $appPath)
  if ($existingBeforeBuild.Count -gt 0) {
    throw 'The exact target release executable is already running; refusing to manage it.'
  }

  $captureTool = Join-Path $toolsRoot 'GraphicsCaptureSnapshot.exe'
  Build-CaptureHelper `
    -Compiler $compiler `
    -OutputPath $captureTool `
    -LogPath (Join-Path $logsRoot 'capture-helper-build.log')

  if ($SkipBuild) {
    if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) {
      throw 'SkipBuild was requested but the release executable does not exist.'
    }
    $script:workflowManifest.build.result = 'skipped by explicit switch'
  } else {
    $cargo = Get-Command cargo.exe -ErrorAction SilentlyContinue
    if ($null -eq $cargo) {
      $cargo = Get-Command cargo -ErrorAction Stop
    }
    Invoke-LoggedProcess `
      -FileName $cargo.Source `
      -Arguments @(
        "+$requiredRustToolchain",
        'tauri',
        'build',
        '--no-bundle'
      ) `
      -WorkingDirectory $windowsRoot `
      -LogPath (Join-Path $logsRoot 'tauri-release-build.log')
    $script:workflowManifest.build.result = 'passed'
  }
  if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) {
    throw 'The Tauri release build did not create the expected executable.'
  }
  Save-WorkflowManifest

  $existingBeforeLaunch = @(Get-ExactExecutableProcesses -ExecutablePath $appPath)
  if ($existingBeforeLaunch.Count -gt 0) {
    throw 'The exact target release executable became active before capture; refusing to manage it.'
  }

  Invoke-MaximizedCapture `
    -CaptureTool $captureTool `
    -ScreenshotsRoot $screenshotsRoot `
    -RuntimeRoot $runtimeRoot `
    -LogsRoot $logsRoot

  $pngFiles = @(
    Get-ChildItem -LiteralPath $screenshotsRoot -Filter '*.png' -File -Recurse
  )
  if (@($script:workflowManifest.size_runs).Count -ne 0) {
    throw 'Native capture unexpectedly recorded a fixed client-size run.'
  }
  $fullscreenRun = $script:workflowManifest.fullscreen_run
  if (
    $null -eq $fullscreenRun -or
    $fullscreenRun.status -ne 'complete' -or
    -not [bool]$fullscreenRun.window.maximized
  ) {
    throw 'Native capture did not complete one maximized exact-HWND run.'
  }
  $overviewCaptureCount = @(
    $fullscreenRun.captures | Where-Object { $_.surface -eq 'Overview' }
  ).Count
  if ($captureOverview -and $overviewCaptureCount -ne 1) {
    throw 'Native capture did not complete exactly one requested Overview capture.'
  }
  if (-not $captureOverview -and $overviewCaptureCount -ne 0) {
    throw 'Native capture recorded an unrequested Overview capture.'
  }
  $unexpectedCaptures = @(
    $fullscreenRun.captures |
      Where-Object { $requestedSurfaces -notcontains $_.surface }
  )
  if ($unexpectedCaptures.Count -ne 0) {
    throw 'Native capture recorded an unrequested Dashboard surface.'
  }
  $recordedCaptureCount = @($fullscreenRun.captures).Count
  foreach ($surface in $selectedPanelSurfaces) {
    $surfaceCaptures = @(
      $fullscreenRun.captures | Where-Object { $_.surface -eq $surface.name }
    )
    if ($surfaceCaptures.Count -lt 1) {
      throw "Maximized run did not record $($surface.name) coverage."
    }
    $actualSegments = @(
      $surfaceCaptures | ForEach-Object { [int]$_.segment }
    )
    $expectedSegments = @(1..$surfaceCaptures.Count)
    if (($actualSegments -join ',') -ne ($expectedSegments -join ',')) {
      throw "Maximized run recorded non-contiguous $($surface.name) segments."
    }
    if (
      -not [bool]$surfaceCaptures[0].is_first -or
      -not [bool]$surfaceCaptures[0].panel_start_visible
    ) {
      throw "Maximized run did not cover the beginning of $($surface.name)."
    }
    $finalCapture = $surfaceCaptures[-1]
    if ($singlePanelCapture -or $surface.name -eq 'Projects') {
      if (
        $surfaceCaptures.Count -ne 1 -or
        $finalCapture.coverage_mode -ne 'first panel viewport' -or
        -not [bool]$finalCapture.is_last
      ) {
        throw "Maximized run did not keep $($surface.name) to its first viewport."
      }
    } elseif (
      -not [bool]$finalCapture.is_last -or
      -not [bool]$finalCapture.panel_end_visible
    ) {
      throw "Maximized run did not establish the end of $($surface.name)."
    }
  }
  if ($pngFiles.Count -ne $recordedCaptureCount) {
    throw (
      "Native screenshot files ($($pngFiles.Count)) did not match manifest records " +
      "($recordedCaptureCount)."
    )
  }
  $script:workflowManifest.screenshot_count = $pngFiles.Count

  $remainingExactApp = @(Get-ExactExecutableProcesses -ExecutablePath $appPath)
  $remainingOwned = @(
    @($script:workflowManifest.fullscreen_run.cleanup.remaining_matching_process_ids)
  )
  if ($remainingExactApp.Count -ne 0 -or $remainingOwned.Count -ne 0) {
    throw 'Task app or recorded task-owned WebView2 processes remained after capture.'
  }

  $script:workflowManifest.final_process_cleanup = 'confirmed'
  $script:workflowManifest.status = 'complete'
} catch {
  $script:workflowManifest.status = 'failed'
  $script:workflowManifest.error = $_.Exception.Message
  throw
} finally {
  $script:workflowManifest.completed_utc = (Get-Date).ToUniversalTime().ToString('o')
  Save-WorkflowManifest
}

$summary = [ordered]@{
  status = $script:workflowManifest.status
  screenshots = $script:workflowManifest.screenshot_count
  capture_runs = @($preflight.capture_runs)
  surfaces = @($preflight.surfaces)
  process_cleanup = $script:workflowManifest.final_process_cleanup
  output_root = $resolvedOutputRoot
}
Write-Output (
  'NATIVE_VISUAL_CAPTURE_COMPLETE=' +
  ($summary | ConvertTo-Json -Depth 5 -Compress)
)
