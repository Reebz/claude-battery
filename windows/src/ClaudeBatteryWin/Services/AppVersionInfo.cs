using System.Reflection;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// The one place the running version is read. The crash log, the diagnostics session-start record,
/// the panel footer, the tray menu's first row, and the Settings About row all read it from here, so
/// they can never disagree (KTD10).
///
/// Assembly metadata, not <c>Assembly.Location</c> or <c>FileVersionInfo</c>: those are empty or
/// throw under PublishSingleFile, which is how the app actually ships.
/// </summary>
public static class AppVersionInfo
{
    private const string Unknown = "unknown";

    /// <summary>Three-component marketing version, e.g. "1.72.0".</summary>
    public static string Version { get; } = ReadVersion();

    /// <summary>The full informational version, including any build suffix.</summary>
    public static string Build { get; } = ReadInformational();

    private static string ReadVersion()
    {
        try
        {
            return typeof(AppVersionInfo).Assembly.GetName().Version?.ToString(3) ?? Unknown;
        }
        catch (Exception)
        {
            return Unknown;
        }
    }

    private static string ReadInformational()
    {
        try
        {
            var attribute = typeof(AppVersionInfo).Assembly
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>();
            return string.IsNullOrWhiteSpace(attribute?.InformationalVersion)
                ? Unknown
                : attribute!.InformationalVersion;
        }
        catch (Exception)
        {
            return Unknown;
        }
    }
}
