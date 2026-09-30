using System.Globalization;
using System.Resources;
using Barback.Core;
namespace Barback.App;

public static class Text
{
    private static readonly ResourceManager Resources = new("Barback.App.Resources.Strings", typeof(Text).Assembly);
    public static string Get(string key) => Resources.GetString(key, CultureInfo.CurrentUICulture) ?? key;
    public static string Status(Phase phase) => Get("Phase" + phase);
    public static string Option(object value) => Get("Option" + value);
}
