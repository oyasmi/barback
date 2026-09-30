using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Interop;
using Barback.Storage;
using Forms = System.Windows.Forms;
namespace Barback.App;

public static class WindowPlacement
{
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    private sealed record Placement(int X, int Y, int Width, int Height, string Monitor);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint window, out Rect rect);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    public static async Task RestoreAsync(Window window, SqliteStore store)
    {
        var saved = await store.GetSettingAsync("window_placement"); if (saved is null) return;
        Placement? p; try { p = JsonSerializer.Deserialize<Placement>(saved); } catch (JsonException) { return; }
        if (p is null) return;
        var screen = Forms.Screen.AllScreens.FirstOrDefault(s => s.DeviceName == p.Monitor) ?? Forms.Screen.FromRectangle(new System.Drawing.Rectangle(p.X, p.Y, Math.Max(1, p.Width), Math.Max(1, p.Height)));
        var work = screen.WorkingArea; var handle = new WindowInteropHelper(window).Handle;
        SetWindowPos(handle, 0, work.Left, work.Top, 0, 0, 0x15); double dpi = Math.Max(96, GetDpiForWindow(handle)) / 96d;
        window.MinWidth = Math.Min(800, work.Width / dpi); window.MinHeight = Math.Min(560, work.Height / dpi);
        var width = Math.Clamp(p.Width, Math.Min((int)(800 * dpi), work.Width), work.Width); var height = Math.Clamp(p.Height, Math.Min((int)(560 * dpi), work.Height), work.Height);
        var x = Math.Clamp(p.X, work.Left, work.Right - width); var y = Math.Clamp(p.Y, work.Top, work.Bottom - height);
        SetWindowPos(handle, 0, x, y, width, height, 0x14);
    }
    public static Task SaveAsync(Window window, SqliteStore store)
    {
        if (window.WindowState != WindowState.Normal) return Task.CompletedTask;
        var handle = new WindowInteropHelper(window).Handle; if (!GetWindowRect(handle, out var rect)) return Task.CompletedTask;
        return store.SetSettingAsync("window_placement", JsonSerializer.Serialize(new Placement(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top, Forms.Screen.FromHandle(handle).DeviceName)));
    }
}
