using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Threading;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;

[ComImport]
[Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IGraphicsCaptureItemInterop
{
    [PreserveSig]
    int CreateForWindow(IntPtr window, ref Guid iid, out IntPtr item);
}

[ComImport]
[Guid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IDirect3DDxgiInterfaceAccess
{
    IntPtr GetInterface(ref Guid iid);
}

[StructLayout(LayoutKind.Sequential)]
internal struct DxgiSampleDesc
{
    public uint Count;
    public uint Quality;
}

[StructLayout(LayoutKind.Sequential)]
internal struct D3D11Texture2DDesc
{
    public uint Width;
    public uint Height;
    public uint MipLevels;
    public uint ArraySize;
    public uint Format;
    public DxgiSampleDesc SampleDesc;
    public uint Usage;
    public uint BindFlags;
    public uint CpuAccessFlags;
    public uint MiscFlags;
}

[StructLayout(LayoutKind.Sequential)]
internal struct D3D11MappedSubresource
{
    public IntPtr Data;
    public uint RowPitch;
    public uint DepthPitch;
}

[UnmanagedFunctionPointer(CallingConvention.StdCall)]
internal delegate int CreateTexture2DDelegate(
    IntPtr self,
    ref D3D11Texture2DDesc description,
    IntPtr initialData,
    out IntPtr texture
);

[UnmanagedFunctionPointer(CallingConvention.StdCall)]
internal delegate void CopyResourceDelegate(
    IntPtr self,
    IntPtr destinationResource,
    IntPtr sourceResource
);

[UnmanagedFunctionPointer(CallingConvention.StdCall)]
internal delegate int MapDelegate(
    IntPtr self,
    IntPtr resource,
    uint subresource,
    uint mapType,
    uint mapFlags,
    out D3D11MappedSubresource mapped
);

[UnmanagedFunctionPointer(CallingConvention.StdCall)]
internal delegate void UnmapDelegate(IntPtr self, IntPtr resource, uint subresource);

internal sealed class DeviceResources : IDisposable
{
    public IDirect3DDevice CaptureDevice;
    public IntPtr NativeDevice;
    public IntPtr NativeContext;
    private IntPtr _dxgiDevice;

    [DllImport("d3d11.dll", ExactSpelling = true)]
    private static extern int D3D11CreateDevice(
        IntPtr adapter,
        int driverType,
        IntPtr software,
        uint flags,
        IntPtr featureLevels,
        uint featureLevelsCount,
        uint sdkVersion,
        out IntPtr device,
        out int featureLevel,
        out IntPtr immediateContext
    );

    [DllImport("d3d11.dll", ExactSpelling = true)]
    private static extern int CreateDirect3D11DeviceFromDXGIDevice(
        IntPtr dxgiDevice,
        out IntPtr graphicsDevice
    );

    public static DeviceResources Create()
    {
        const int D3D_DRIVER_TYPE_HARDWARE = 1;
        const uint D3D11_CREATE_DEVICE_BGRA_SUPPORT = 0x20;
        const uint D3D11_SDK_VERSION = 7;
        var resources = new DeviceResources();
        IntPtr graphicsDevice = IntPtr.Zero;

        try
        {
            int featureLevel;
            Marshal.ThrowExceptionForHR(D3D11CreateDevice(
                IntPtr.Zero,
                D3D_DRIVER_TYPE_HARDWARE,
                IntPtr.Zero,
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                IntPtr.Zero,
                0,
                D3D11_SDK_VERSION,
                out resources.NativeDevice,
                out featureLevel,
                out resources.NativeContext
            ));

            Guid idxgiDevice = new Guid("54EC77FA-1377-44E6-8C32-88FD5F44C84C");
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(
                resources.NativeDevice,
                ref idxgiDevice,
                out resources._dxgiDevice
            ));
            Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(
                resources._dxgiDevice,
                out graphicsDevice
            ));
            resources.CaptureDevice =
                (IDirect3DDevice)Marshal.GetObjectForIUnknown(graphicsDevice);
            return resources;
        }
        catch
        {
            resources.Dispose();
            throw;
        }
        finally
        {
            if (graphicsDevice != IntPtr.Zero)
            {
                Marshal.Release(graphicsDevice);
            }
        }
    }

    public void Dispose()
    {
        if (_dxgiDevice != IntPtr.Zero)
        {
            Marshal.Release(_dxgiDevice);
            _dxgiDevice = IntPtr.Zero;
        }
        if (NativeContext != IntPtr.Zero)
        {
            Marshal.Release(NativeContext);
            NativeContext = IntPtr.Zero;
        }
        if (NativeDevice != IntPtr.Zero)
        {
            Marshal.Release(NativeDevice);
            NativeDevice = IntPtr.Zero;
        }
        CaptureDevice = null;
    }
}

internal static class GraphicsCaptureSnapshot
{
    [StructLayout(LayoutKind.Sequential)]
    private struct WindowRect
    {
        public int Left, Top, Right, Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr hwnd, out WindowRect rect);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PrintWindow(IntPtr hwnd, IntPtr dc, uint flags);

    [DllImport("user32.dll")]
    private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);

    private static void SaveToolWindow(IntPtr hwnd, string outputPath)
    {
        // GraphicsCaptureItem rejects tool windows excluded from Alt+Tab.
        // PrintWindow renders the same HWND, including its WebView2 content,
        // without changing visibility, z-order, focus or task-switcher styles.
        IntPtr previousDpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try
        {
            WindowRect rect;
            if (!GetWindowRect(hwnd, out rect))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            int width = rect.Right - rect.Left;
            int height = rect.Bottom - rect.Top;
            using (var bitmap = new Bitmap(width, height, PixelFormat.Format32bppRgb))
            {
                using (var graphics = Graphics.FromImage(bitmap))
                {
                    IntPtr dc = graphics.GetHdc();
                    try
                    {
                        const uint PW_RENDERFULLCONTENT = 2;
                        if (!PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT))
                            throw new InvalidOperationException("PrintWindow did not render the target HWND.");
                    }
                    finally { graphics.ReleaseHdc(dc); }
                }
                // Reject a blank/solid client area; window chrome alone is not evidence.
                var colors = new System.Collections.Generic.HashSet<int>();
                for (int y = height / 5; y < height * 4 / 5; y += 7)
                    for (int x = width / 5; x < width * 4 / 5; x += 7)
                        colors.Add(bitmap.GetPixel(x, y).ToArgb());
                if (colors.Count < 8)
                    throw new InvalidOperationException("PrintWindow returned a blank or solid client area.");
                bitmap.Save(outputPath, ImageFormat.Png);
                Console.WriteLine("CAPTURE_OK " + width + "x" + height + " PrintWindow");
            }
        }
        finally
        {
            if (previousDpi != IntPtr.Zero) SetThreadDpiAwarenessContext(previousDpi);
        }
    }

    private const uint DxgiFormatB8G8R8A8Unorm = 87;
    private const uint D3D11UsageStaging = 3;
    private const uint D3D11CpuAccessRead = 0x20000;
    private const uint D3D11MapRead = 1;

    [DllImport("combase.dll", CharSet = CharSet.Unicode)]
    private static extern int WindowsCreateString(
        string sourceString,
        uint length,
        out IntPtr hstring
    );

    [DllImport("combase.dll")]
    private static extern int WindowsDeleteString(IntPtr hstring);

    [DllImport("combase.dll")]
    private static extern int RoGetActivationFactory(
        IntPtr activatableClassId,
        ref Guid iid,
        out IntPtr factory
    );

    private static IntPtr GetVtableFunction(IntPtr comObject, int index)
    {
        var vtable = Marshal.ReadIntPtr(comObject);
        return Marshal.ReadIntPtr(vtable, index * IntPtr.Size);
    }

    private static TDelegate GetVtableDelegate<TDelegate>(IntPtr comObject, int index)
        where TDelegate : class
    {
        return Marshal.GetDelegateForFunctionPointer(
            GetVtableFunction(comObject, index),
            typeof(TDelegate)
        ) as TDelegate;
    }

    private static GraphicsCaptureItem CreateCaptureItem(IntPtr hwnd)
    {
        const string runtimeClass = "Windows.Graphics.Capture.GraphicsCaptureItem";
        IntPtr className = IntPtr.Zero;
        IntPtr factory = IntPtr.Zero;
        IntPtr item = IntPtr.Zero;

        try
        {
            Marshal.ThrowExceptionForHR(WindowsCreateString(
                runtimeClass,
                (uint)runtimeClass.Length,
                out className
            ));
            var interopId = new Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");
            Marshal.ThrowExceptionForHR(RoGetActivationFactory(
                className,
                ref interopId,
                out factory
            ));
            var interop = (IGraphicsCaptureItemInterop)Marshal.GetObjectForIUnknown(factory);
            var itemId = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760");
            Marshal.ThrowExceptionForHR(interop.CreateForWindow(
                hwnd,
                ref itemId,
                out item
            ));
            return (GraphicsCaptureItem)Marshal.GetObjectForIUnknown(item);
        }
        finally
        {
            if (item != IntPtr.Zero)
            {
                Marshal.Release(item);
            }
            if (factory != IntPtr.Zero)
            {
                Marshal.Release(factory);
            }
            if (className != IntPtr.Zero)
            {
                WindowsDeleteString(className);
            }
        }
    }

    private static void SaveFrame(
        Direct3D11CaptureFrame frame,
        DeviceResources resources,
        string outputPath
    )
    {
        var size = frame.ContentSize;
        if (size.Width <= 0 || size.Height <= 0)
        {
            throw new InvalidOperationException("Captured frame has an invalid size.");
        }

        var access = (IDirect3DDxgiInterfaceAccess)frame.Surface;
        var textureGuid = new Guid("6F15AAF2-D208-4E89-9AB4-489535D34F9C");
        IntPtr sourceTexture = access.GetInterface(ref textureGuid);
        IntPtr stagingTexture = IntPtr.Zero;

        try
        {
            var description = new D3D11Texture2DDesc
            {
                Width = (uint)size.Width,
                Height = (uint)size.Height,
                MipLevels = 1,
                ArraySize = 1,
                Format = DxgiFormatB8G8R8A8Unorm,
                SampleDesc = new DxgiSampleDesc { Count = 1, Quality = 0 },
                Usage = D3D11UsageStaging,
                BindFlags = 0,
                CpuAccessFlags = D3D11CpuAccessRead,
                MiscFlags = 0,
            };

            var createTexture = GetVtableDelegate<CreateTexture2DDelegate>(
                resources.NativeDevice,
                5
            );
            Marshal.ThrowExceptionForHR(createTexture(
                resources.NativeDevice,
                ref description,
                IntPtr.Zero,
                out stagingTexture
            ));

            var copyResource = GetVtableDelegate<CopyResourceDelegate>(
                resources.NativeContext,
                47
            );
            copyResource(resources.NativeContext, stagingTexture, sourceTexture);

            var map = GetVtableDelegate<MapDelegate>(resources.NativeContext, 14);
            var unmap = GetVtableDelegate<UnmapDelegate>(resources.NativeContext, 15);
            D3D11MappedSubresource mapped;
            Marshal.ThrowExceptionForHR(map(
                resources.NativeContext,
                stagingTexture,
                0,
                D3D11MapRead,
                0,
                out mapped
            ));

            try
            {
                using (var bitmap = new Bitmap(
                    size.Width,
                    size.Height,
                    PixelFormat.Format32bppArgb
                ))
                {
                    var bitmapData = bitmap.LockBits(
                        new Rectangle(0, 0, size.Width, size.Height),
                        ImageLockMode.WriteOnly,
                        PixelFormat.Format32bppArgb
                    );
                    try
                    {
                        var row = new byte[size.Width * 4];
                        for (int y = 0; y < size.Height; y++)
                        {
                            Marshal.Copy(
                                IntPtr.Add(mapped.Data, checked((int)(y * mapped.RowPitch))),
                                row,
                                0,
                                row.Length
                            );
                            Marshal.Copy(
                                row,
                                0,
                                IntPtr.Add(bitmapData.Scan0, y * bitmapData.Stride),
                                row.Length
                            );
                        }
                    }
                    finally
                    {
                        bitmap.UnlockBits(bitmapData);
                    }
                    bitmap.Save(outputPath, ImageFormat.Png);
                }
            }
            finally
            {
                unmap(resources.NativeContext, stagingTexture, 0);
            }
        }
        finally
        {
            if (stagingTexture != IntPtr.Zero)
            {
                Marshal.Release(stagingTexture);
            }
            if (sourceTexture != IntPtr.Zero)
            {
                Marshal.Release(sourceTexture);
            }
        }
    }

    private static int Main(string[] args)
    {
        if (args.Length != 2)
        {
            Console.Error.WriteLine(
                "Usage: GraphicsCaptureSnapshot.exe <hwnd> <output-png>"
            );
            return 64;
        }

        try
        {
            var hwnd = new IntPtr(long.Parse(args[0]));
            var outputPath = args[1];
            const int GWL_EXSTYLE = -20;
            const long WS_EX_TOOLWINDOW = 0x80;
            if ((GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64() & WS_EX_TOOLWINDOW) != 0)
            {
                SaveToolWindow(hwnd, outputPath);
                return 0;
            }
            using (var resources = DeviceResources.Create())
            {
                var item = CreateCaptureItem(hwnd);
                using (var framePool = Direct3D11CaptureFramePool.CreateFreeThreaded(
                    resources.CaptureDevice,
                    DirectXPixelFormat.B8G8R8A8UIntNormalized,
                    1,
                    item.Size
                ))
                using (var session = framePool.CreateCaptureSession(item))
                {
                    session.StartCapture();
                    Thread.Sleep(500);

                    Direct3D11CaptureFrame frame = null;
                    var deadline = DateTime.UtcNow.AddSeconds(5);
                    while (frame == null && DateTime.UtcNow < deadline)
                    {
                        frame = framePool.TryGetNextFrame();
                        if (frame == null)
                        {
                            Thread.Sleep(100);
                        }
                    }
                    if (frame == null)
                    {
                        throw new TimeoutException(
                            "Timed out waiting for a graphics capture frame."
                        );
                    }
                    using (frame)
                    {
                        SaveFrame(frame, resources, outputPath);
                        Console.WriteLine(
                            "CAPTURE_OK " +
                            frame.ContentSize.Width +
                            "x" +
                            frame.ContentSize.Height + " Windows.Graphics.Capture"
                        );
                        return 0;
                    }
                }
            }
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.GetType().Name + ": " + error.Message +
                " (HRESULT 0x" + error.HResult.ToString("X8") + ")");
            var frames = new System.Diagnostics.StackTrace(error, false).GetFrames();
            if (frames != null)
            {
                foreach (var frame in frames)
                {
                    var method = frame.GetMethod();
                    Console.Error.WriteLine("Capture call: " + method.DeclaringType.Name + "." + method.Name);
                }
            }
            return 1;
        }
    }
}
