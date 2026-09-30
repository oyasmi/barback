using System.ComponentModel;
using System.Windows.Media;
using Microsoft.Win32;

namespace Barback.App;

public static class WorkbenchTheme
{
    public static event Action? Changed;
    private static string preference = "System";
    public static void Initialize()
    {
        SystemEvents.UserPreferenceChanged += PreferenceChanged;
        SystemParameters.StaticPropertyChanged += SystemChanged;
        Apply();
    }
    public static void Set(string value) { preference = value; Apply(); }
    public static void Dispose()
    {
        SystemEvents.UserPreferenceChanged -= PreferenceChanged;
        SystemParameters.StaticPropertyChanged -= SystemChanged;
    }
    private static void PreferenceChanged(object sender, UserPreferenceChangedEventArgs e) => Application.Current.Dispatcher.BeginInvoke(Apply);
    private static void SystemChanged(object? sender, PropertyChangedEventArgs e) => Application.Current.Dispatcher.BeginInvoke(Apply);
    private static void Apply()
    {
        if (Application.Current is not { } application) return;
        bool dark = preference == "Dark";
        if (preference == "System")
        {
            using var settings = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            dark = settings?.GetValue("AppsUseLightTheme") is int value && value == 0;
        }
        // Official Fluent API is experimental; this application pins its WPF SDK.
#pragma warning disable WPF0001
        var mode = preference == "System" ? ThemeMode.System : dark ? ThemeMode.Dark : ThemeMode.Light;
        if (application.ThemeMode != mode) application.ThemeMode = mode;
#pragma warning restore WPF0001
        var light = new[] { "#F3F4F7", "#FFFFFF", "#F8F9FB", "#25282E", "#656B77", "#E7E9EE", "#0067B8", "#FFFFFF", "#EAF3FC", "#16794D", "#996718", "#B63C36", "#FFF8E8", "#FFF2EF" };
        var night = new[] { "#202126", "#28292F", "#23242A", "#F2F2F5", "#B2B5BF", "#3B3D45", "#77BFFF", "#102638", "#273D51", "#79D4A3", "#E9C17D", "#FF9C95", "#40372A", "#422F30" };
        var names = new[] { "ShellBrush", "SurfaceBrush", "DetailBrush", "PrimaryTextBrush", "SecondaryTextBrush", "LineBrush", "AccentBrush", "AccentForegroundBrush", "SelectedBrush", "SuccessBrush", "WarningBrush", "DangerBrush", "NoticeBrush", "ErrorSurfaceBrush" };
        for (int i = 0; i < names.Length; i++)
        {
            Color color;
            if (SystemParameters.HighContrast)
                color = names[i] switch
                {
                    "AccentBrush" => SystemColors.HighlightColor,
                    "SelectedBrush" => SystemColors.ControlColor,
                    "AccentForegroundBrush" => SystemColors.HighlightTextColor,
                    "PrimaryTextBrush" or "SecondaryTextBrush" or "LineBrush" or "SuccessBrush" or "WarningBrush" or "DangerBrush" => SystemColors.WindowTextColor,
                    _ => SystemColors.WindowColor
                };
            else color = (Color)ColorConverter.ConvertFromString((dark ? night : light)[i]);
            if (application.Resources[names[i]] is SolidColorBrush existing && existing.Color == color) continue;
            var brush = new SolidColorBrush(color); brush.Freeze(); application.Resources[names[i]] = brush;
        }
        Changed?.Invoke();
    }
}
