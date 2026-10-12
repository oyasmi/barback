using System.Runtime.InteropServices;
using Microsoft.Win32;
using D = System.Drawing;
using Forms = System.Windows.Forms;

namespace Barback.App;

public enum TrayState { Normal, Busy, Attention }

/// <summary>
/// The brand icon with a small status dot. The tray used to swap in the system Warning / Information icons, which replaced the
/// app's identity with a large generic glyph; a badge keeps the icon recognisable and still reads at a glance. The dot gets a
/// ring in the taskbar's own colour so it stays separate from the icon on light and dark taskbars alike.
/// </summary>
internal sealed class TrayIcons : IDisposable
{
    private readonly D.Icon brand;
    private D.Icon? busy, attention;
    [DllImport("user32.dll")] private static extern bool DestroyIcon(nint icon);

    public TrayIcons(D.Icon brand) { this.brand = brand; Rebuild(); }

    public D.Icon For(TrayState state) => state switch { TrayState.Attention => attention!, TrayState.Busy => busy!, _ => brand };

    /// <summary>Redraws the badges, e.g. after the taskbar switched between light and dark.</summary>
    public void Rebuild()
    {
        busy?.Dispose(); attention?.Dispose();
        var ring = TaskbarIsLight() ? D.Color.FromArgb(243, 243, 243) : D.Color.FromArgb(32, 32, 32);
        busy = Badge(D.Color.FromArgb(0xE0, 0x9B, 0x1A), ring);
        attention = Badge(D.Color.FromArgb(0xD1, 0x34, 0x38), ring);
    }

    private static bool TaskbarIsLight()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("SystemUsesLightTheme") is int value && value != 0;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException) { return false; }
    }

    private D.Icon Badge(D.Color dot, D.Color ring)
    {
        var size = Forms.SystemInformation.SmallIconSize; // follows the process DPI
        using var bitmap = new D.Bitmap(size.Width, size.Height, D.Imaging.PixelFormat.Format32bppArgb);
        using (var graphics = D.Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = D.Drawing2D.SmoothingMode.AntiAlias;
            graphics.InterpolationMode = D.Drawing2D.InterpolationMode.HighQualityBicubic;
            using (var source = new D.Icon(brand, size)) graphics.DrawIcon(source, new D.Rectangle(D.Point.Empty, size));
            float diameter = size.Width * 0.5f;
            var area = new D.RectangleF(size.Width - diameter, size.Height - diameter, diameter, diameter);
            using (var ringBrush = new D.SolidBrush(ring)) graphics.FillEllipse(ringBrush, area);
            float inset = Math.Max(1.5f, diameter * 0.16f); area.Inflate(-inset, -inset);
            using (var dotBrush = new D.SolidBrush(dot)) graphics.FillEllipse(dotBrush, area);
        }
        var handle = bitmap.GetHicon();
        try { using var temporary = D.Icon.FromHandle(handle); return (D.Icon)temporary.Clone(); } // Clone copies the handle
        finally { DestroyIcon(handle); }
    }

    public void Dispose() { busy?.Dispose(); attention?.Dispose(); }
}
