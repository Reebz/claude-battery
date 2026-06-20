using System.Drawing;
using ClaudeBatteryWin.Icons;
using ClaudeBatteryWin.Models;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U9 tray-renderer tests: color thresholds at the 20/45 boundaries, the issue-#11 signature
/// short-circuit (suppressed-counter increments on a duplicate tuple), and the compact countdown
/// saturation/floor. These exercise the renderer's pure surface (<c>BatteryColor</c>,
/// <c>CountdownCellText</c>) and the cache (<c>Render</c> returning null + <c>SuppressedCount</c>),
/// none of which require pixel inspection -- the bitmaps the rasterizing tests produce are only
/// checked for non-null so GDI+ runs on the Windows CI host.
/// </summary>
public class IconRenderTests
{
    private static readonly DateTimeOffset Now = new(2026, 6, 19, 12, 0, 0, TimeSpan.Zero);

    private static UsageSnapshot Snapshot(double session, double weekly, DateTimeOffset? sessionReset = null) =>
        new()
        {
            SessionRemaining = session,
            WeeklyRemaining = weekly,
            SessionResetDate = sessionReset
        };

    // --- Color thresholds: <20 red, <45 orange, else green (clamped 0-100) ---

    [Theory]
    [InlineData(0, "Red")]
    [InlineData(19, "Red")]
    [InlineData(19.999, "Red")]
    [InlineData(20, "Orange")]   // boundary: 20 is NOT <20, so it is orange
    [InlineData(44, "Orange")]
    [InlineData(44.999, "Orange")]
    [InlineData(45, "Green")]    // boundary: 45 is NOT <45, so it is green
    [InlineData(100, "Green")]
    public void BatteryColor_MapsRemainingToColorAtBoundaries(double remaining, string expectedName)
    {
        Color color = DualHorizontalRenderer.BatteryColor(remaining);
        Assert.Equal(expectedName, color.Name);
    }

    [Theory]
    [InlineData(-5, "Red")]      // clamps up to 0 -> red
    [InlineData(150, "Green")]   // clamps down to 100 -> green
    public void BatteryColor_ClampsOutOfRangeBeforeBucketing(double remaining, string expectedName)
    {
        Assert.Equal(expectedName, DualHorizontalRenderer.BatteryColor(remaining).Name);
    }

    [Fact]
    public void BatteryColor_BoundariesHoldForBothSessionAndWeekly()
    {
        // The renderer applies one scale to both batteries; locking the function locks both nubs.
        foreach (double v in new[] { 19.0, 20.0, 44.0, 45.0 })
        {
            Color expected = v < 20 ? Color.Red : v < 45 ? Color.Orange : Color.Green;
            Assert.Equal(expected.Name, DualHorizontalRenderer.BatteryColor(v).Name);
        }
    }

    // --- Signature short-circuit (issue #11 port) ---

    [Fact]
    public void Render_IdenticalStateThemeCountdown_DoesNotReRender_SuppressedCounterIncrements()
    {
        using var renderer = new DualHorizontalRenderer();
        var state = new TrayRenderState.Battery(Snapshot(session: 75, weekly: 43));

        using Bitmap? first = renderer.Render(state, ThemeBucket.Dark, countdown: "");
        Assert.NotNull(first);
        Assert.Equal(0, renderer.SuppressedCount);

        // Same (state, theme, countdown) tuple: no bitmap, suppressed counter increments.
        Bitmap? second = renderer.Render(state, ThemeBucket.Dark, countdown: "");
        Assert.Null(second);
        Assert.Equal(1, renderer.SuppressedCount);

        Bitmap? third = renderer.Render(state, ThemeBucket.Dark, countdown: "");
        Assert.Null(third);
        Assert.Equal(2, renderer.SuppressedCount);
    }

    [Fact]
    public void Render_ChangedCountdownString_ReRendersExactlyOnce()
    {
        using var renderer = new DualHorizontalRenderer();
        var state = new TrayRenderState.Battery(Snapshot(session: 75, weekly: 43));

        using Bitmap? first = renderer.Render(state, ThemeBucket.Dark, countdown: "32m");
        Assert.NotNull(first);

        // A per-minute tick changes only the countdown string -> a single re-render, not suppressed.
        using Bitmap? next = renderer.Render(state, ThemeBucket.Dark, countdown: "31m");
        Assert.NotNull(next);
        Assert.Equal(0, renderer.SuppressedCount);

        // Holding the new string suppresses again.
        Bitmap? held = renderer.Render(state, ThemeBucket.Dark, countdown: "31m");
        Assert.Null(held);
        Assert.Equal(1, renderer.SuppressedCount);
    }

    [Fact]
    public void Render_ThemeFlip_ReRenders()
    {
        using var renderer = new DualHorizontalRenderer();
        var state = new TrayRenderState.Battery(Snapshot(session: 75, weekly: 43));

        using Bitmap? dark = renderer.Render(state, ThemeBucket.Dark, countdown: "");
        Assert.NotNull(dark);

        using Bitmap? light = renderer.Render(state, ThemeBucket.Light, countdown: "");
        Assert.NotNull(light);
        Assert.Equal(0, renderer.SuppressedCount);
    }

    [Fact]
    public void Render_SubPercentDriftBelowDrawnDigit_DoesNotReRender()
    {
        // 75.2 and 75.8 both render the digit "75"; the signature keys on the rounded percent, so
        // a drift that does not change a drawn digit is suppressed (matches the Mac Int() cast).
        using var renderer = new DualHorizontalRenderer();

        using Bitmap? first = renderer.Render(
            new TrayRenderState.Battery(Snapshot(session: 75.2, weekly: 43.9)),
            ThemeBucket.Dark, countdown: "");
        Assert.NotNull(first);

        Bitmap? second = renderer.Render(
            new TrayRenderState.Battery(Snapshot(session: 75.8, weekly: 43.1)),
            ThemeBucket.Dark, countdown: "");
        Assert.Null(second);
        Assert.Equal(1, renderer.SuppressedCount);
    }

    [Fact]
    public void ResetSignature_ForcesNextRenderEvenWhenTupleUnchanged()
    {
        using var renderer = new DualHorizontalRenderer();
        var state = new TrayRenderState.Battery(Snapshot(session: 75, weekly: 43));

        using Bitmap? first = renderer.Render(state, ThemeBucket.Dark, countdown: "");
        Assert.NotNull(first);

        renderer.ResetSignature(); // wake/button-loss analog

        using Bitmap? afterReset = renderer.Render(state, ThemeBucket.Dark, countdown: "");
        Assert.NotNull(afterReset); // not suppressed despite the identical tuple
        Assert.Equal(0, renderer.SuppressedCount);
    }

    [Fact]
    public void Render_StatusBranches_Rasterize()
    {
        using var renderer = new DualHorizontalRenderer();
        using Bitmap? unauth = renderer.Render(new TrayRenderState.Unauthenticated(), ThemeBucket.Dark, "");
        using Bitmap? authFailed = renderer.Render(new TrayRenderState.AuthFailed(), ThemeBucket.Dark, "");
        using Bitmap? error = renderer.Render(new TrayRenderState.StatusError(), ThemeBucket.Light, "");
        using Bitmap? stale = renderer.Render(new TrayRenderState.StatusStale(), ThemeBucket.Light, "");
        using Bitmap? loading = renderer.Render(new TrayRenderState.StatusLoading(), ThemeBucket.Dark, "");

        Assert.NotNull(unauth);
        Assert.NotNull(authFailed);
        Assert.NotNull(error);
        Assert.NotNull(stale);
        Assert.NotNull(loading);
    }

    [Fact]
    public void Render_NonBatteryStatesIgnoreCountdown_SuppressAcrossCountdownChange()
    {
        // R6 (U5): the countdown cell only rides the battery branch, so it must NOT be part of a
        // non-battery signature. A per-minute countdown tick on a status/auth glyph would otherwise
        // force a needless repaint every minute even though the drawn output is identical. Two
        // DIFFERENT countdown strings on the same non-battery state therefore produce equal
        // signatures -> the second render is suppressed (no repaint across the minute tick).
        TrayRenderState[] states =
        {
            new TrayRenderState.Unauthenticated(),
            new TrayRenderState.AuthFailed(),
            new TrayRenderState.StatusError(),
            new TrayRenderState.StatusStale(),
            new TrayRenderState.StatusLoading(),
        };

        foreach (var state in states)
        {
            using var renderer = new DualHorizontalRenderer();
            using Bitmap? first = renderer.Render(state, ThemeBucket.Dark, "5h+");
            Assert.NotNull(first);

            Bitmap? second = renderer.Render(state, ThemeBucket.Dark, "3h+");
            Assert.Null(second); // countdown ignored for non-battery -> identical signature -> suppressed
            Assert.Equal(1, renderer.SuppressedCount);
        }
    }

    [Fact]
    public void Render_BatteryCountdownChange_StillReRenders_ContrastToNonBattery()
    {
        // R6 contrast: the battery branch DOES re-render when the countdown changes (the cell rides
        // the battery), so the non-battery short-circuit above must not over-suppress the battery.
        using var renderer = new DualHorizontalRenderer();
        var state = new TrayRenderState.Battery(Snapshot(session: 75, weekly: 43));

        using Bitmap? first = renderer.Render(state, ThemeBucket.Dark, "5h+");
        Assert.NotNull(first);

        using Bitmap? second = renderer.Render(state, ThemeBucket.Dark, "3h+");
        Assert.NotNull(second); // a changed countdown on the battery branch repaints
        Assert.Equal(0, renderer.SuppressedCount);
    }

    // --- Compact countdown saturation / floor ---

    [Fact]
    public void CompactCountdown_SaturatesTo9hPlusAtOrAbove10Hours()
    {
        Assert.Equal("9h+", CountdownFormat.CompactCountdown(Now.AddHours(10), Now));
        Assert.Equal("9h+", CountdownFormat.CompactCountdown(Now.AddHours(23), Now));
        Assert.Equal("9h+", CountdownFormat.CompactCountdown(Now.AddDays(2), Now));
    }

    [Fact]
    public void CompactCountdown_NineHourBandIsNhPlus()
    {
        Assert.Equal("9h+", CountdownFormat.CompactCountdown(Now.AddHours(9).AddMinutes(59), Now));
        Assert.Equal("4h+", CountdownFormat.CompactCountdown(Now.AddHours(4).AddMinutes(30), Now));
        Assert.Equal("1h+", CountdownFormat.CompactCountdown(Now.AddHours(1), Now));
    }

    [Fact]
    public void CompactCountdown_MinuteBandIsNm()
    {
        Assert.Equal("59m", CountdownFormat.CompactCountdown(Now.AddMinutes(59).AddSeconds(59), Now));
        Assert.Equal("32m", CountdownFormat.CompactCountdown(Now.AddMinutes(32), Now));
        Assert.Equal("1m", CountdownFormat.CompactCountdown(Now.AddMinutes(1), Now));
    }

    [Fact]
    public void CompactCountdown_UnderOneMinuteIsLessThan1m()
    {
        Assert.Equal("<1m", CountdownFormat.CompactCountdown(Now.AddSeconds(59), Now));
        Assert.Equal("<1m", CountdownFormat.CompactCountdown(Now.AddSeconds(1), Now));
    }

    [Fact]
    public void CompactCountdown_NeverExceedsThreeCharacters()
    {
        foreach (var offset in new[]
        {
            TimeSpan.FromSeconds(1), TimeSpan.FromMinutes(59), TimeSpan.FromHours(9),
            TimeSpan.FromHours(10), TimeSpan.FromDays(7)
        })
        {
            string? s = CountdownFormat.CompactCountdown(Now + offset, Now);
            Assert.NotNull(s);
            Assert.True(s!.Length <= 3, $"'{s}' exceeds 3 chars");
        }
    }

    [Fact]
    public void CompactCountdown_NonPositiveOrNonFinite_ReturnsNull()
    {
        Assert.Null(CountdownFormat.CompactCountdown(Now, Now));            // exactly now
        Assert.Null(CountdownFormat.CompactCountdown(Now.AddSeconds(-1), Now)); // past
    }

    [Fact]
    public void CountdownCellText_OffOrNoResetDate_IsEmpty()
    {
        // Toggle off -> "" even with a reset date.
        Assert.Equal("", DualHorizontalRenderer.CountdownCellText(
            Snapshot(50, 50, Now.AddMinutes(30)), enabled: false, Now));
        // No reset date -> "".
        Assert.Equal("", DualHorizontalRenderer.CountdownCellText(
            Snapshot(50, 50, sessionReset: null), enabled: true, Now));
        // Null usage -> "".
        Assert.Equal("", DualHorizontalRenderer.CountdownCellText(usage: null, enabled: true, Now));
    }

    [Fact]
    public void CountdownCellText_EnabledWithFutureReset_IsCompactString()
    {
        Assert.Equal("30m", DualHorizontalRenderer.CountdownCellText(
            Snapshot(50, 50, Now.AddMinutes(30)), enabled: true, Now));
        Assert.Equal("9h+", DualHorizontalRenderer.CountdownCellText(
            Snapshot(50, 50, Now.AddHours(12)), enabled: true, Now));
    }

    [Fact]
    public void CountdownCellText_EnabledButPastReset_IsEmpty()
    {
        // A past reset date yields no countdown -> "" (so the cell disappears), not a crash.
        Assert.Equal("", DualHorizontalRenderer.CountdownCellText(
            Snapshot(50, 50, Now.AddMinutes(-5)), enabled: true, Now));
    }
}
