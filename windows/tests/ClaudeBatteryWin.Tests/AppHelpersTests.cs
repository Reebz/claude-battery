using ClaudeBatteryWin.Models;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// The pure helpers on the composition root: the tray tooltip text (the square icon no longer
/// draws the countdown, so the tooltip is where the numbers live) and the crash-log entry format
/// (the CI smoke job and testers read crash.log, so its shape is pinned here).
/// </summary>
public class AppHelpersTests
{
    private const int ShellTooltipLimit = 127;

    private static UsageSnapshot Snapshot(double session, double weekly) =>
        new() { SessionRemaining = session, WeeklyRemaining = weekly };

    [Fact]
    public void BuildTooltip_NoUsage_IsAppNameOnly()
    {
        Assert.Equal("Claude Battery", App.BuildTooltip(null, ""));
    }

    [Fact]
    public void BuildTooltip_WithUsage_RoundsBothPercentages()
    {
        Assert.Equal(
            "Claude Battery - Session 75% - Weekly 44%",
            App.BuildTooltip(Snapshot(75.4, 43.6), ""));
    }

    [Fact]
    public void BuildTooltip_WithCountdown_AppendsResetsIn()
    {
        Assert.Equal(
            "Claude Battery - Session 75% - Weekly 44% - resets in 3h+",
            App.BuildTooltip(Snapshot(75.4, 43.6), "3h+"));
    }

    [Fact]
    public void BuildTooltip_NoUsageIgnoresCountdown()
    {
        // With no snapshot there is no reset to count down to, whatever the caller passed.
        Assert.Equal("Claude Battery", App.BuildTooltip(null, "3h+"));
    }

    [Theory]
    [InlineData(0, 0, "")]
    [InlineData(100, 100, "")]
    [InlineData(100, 100, "59m")]
    [InlineData(99.5, 99.5, "23h+")]
    [InlineData(75.4, 43.6, "3h+")]
    public void BuildTooltip_StaysUnderTheShellLimit(double session, double weekly, string countdown)
    {
        var text = App.BuildTooltip(Snapshot(session, weekly), countdown);
        Assert.True(text.Length < ShellTooltipLimit, $"{text.Length} chars: {text}");
        Assert.True(App.BuildTooltip(null, countdown).Length < ShellTooltipLimit);
    }

    [Fact]
    public void FormatCrashEntry_ThrownException_CarriesHeaderTypeMessageAndFrames()
    {
        Exception thrown;
        try
        {
            throw new InvalidOperationException("tray icon could not be created");
        }
        catch (InvalidOperationException ex)
        {
            thrown = ex;
        }

        var now = new DateTimeOffset(2026, 9, 3, 10, 30, 15, TimeSpan.FromHours(10));
        var entry = App.FormatCrashEntry(now, "1.50.3", "dispatcher", thrown);

        Assert.Contains("==== 2026-09-03T10:30:15.0000000+10:00 ClaudeBatteryWin v1.50.3 [dispatcher] ====", entry);
        Assert.Contains("InvalidOperationException", entry);
        Assert.Contains("tray icon could not be created", entry);
        Assert.Contains("at ", entry); // a stack frame from the throw above
        Assert.EndsWith(Environment.NewLine + Environment.NewLine, entry); // blank separator line
    }

    [Fact]
    public void FormatCrashEntry_NullException_WritesPlaceholder()
    {
        var now = new DateTimeOffset(2026, 9, 3, 0, 0, 0, TimeSpan.Zero);
        var entry = App.FormatCrashEntry(now, "unknown", "appdomain", null);

        Assert.Contains("2026-09-03T00:00:00.0000000+00:00", entry);
        Assert.Contains("vunknown", entry);
        Assert.Contains("[appdomain]", entry);
        Assert.Contains("(null exception)", entry);
    }

    [Fact]
    public void FormatCrashEntry_HeaderIsTheFirstLine()
    {
        var entry = App.FormatCrashEntry(DateTimeOffset.UnixEpoch, "1.0.0", "unobserved-task", null);
        var firstLine = entry.Split(Environment.NewLine)[0];

        Assert.StartsWith("==== ", firstLine);
        Assert.EndsWith(" [unobserved-task] ====", firstLine);
    }
}
