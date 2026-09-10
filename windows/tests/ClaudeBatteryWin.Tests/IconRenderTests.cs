using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using ClaudeBatteryWin.Icons;
using ClaudeBatteryWin.Models;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U9 tray-renderer tests: color thresholds at the 20/45 boundaries, the issue-#11 signature
/// short-circuit (suppressed-counter increments on a duplicate tuple), the compact countdown
/// saturation/floor, and the square-cell geometry (every branch renders size x size at 16/24/32,
/// the fill run grows with remaining percent). These exercise the renderer's pure surface
/// (<c>BatteryColor</c>, <c>CountdownCellText</c>), the cache (<c>Render</c> returning null +
/// <c>SuppressedCount</c>), and the bitmap dimensions; GDI+ runs on the Windows CI host.
///
/// <see cref="RenderAllStates_WritesArtifactsWhenRequested"/> doubles as the developer's only way to
/// SEE the icon without a Windows box: set <c>CLAUDE_BATTERY_ICON_ARTIFACTS</c> to a directory and
/// CI writes one PNG per state x theme x size plus an 8x nearest-neighbour upscale of each.
/// </summary>
public class IconRenderTests
{
    private static readonly DateTimeOffset Now = new(2026, 6, 19, 12, 0, 0, TimeSpan.Zero);

    private static readonly int[] CellSizes = { 16, 24, 32 };

    /// <summary>Every render branch, named, for the geometry theories and the artifact dump.</summary>
    private static IEnumerable<(string Name, TrayRenderState State)> AllStates()
    {
        yield return ("battery-100-100", new TrayRenderState.Battery(Snapshot(100, 100)));
        yield return ("battery-75-40", new TrayRenderState.Battery(Snapshot(75, 40)));
        yield return ("battery-44-19", new TrayRenderState.Battery(Snapshot(44, 19)));
        yield return ("battery-10-5", new TrayRenderState.Battery(Snapshot(10, 5)));
        yield return ("battery-0-0", new TrayRenderState.Battery(Snapshot(0, 0)));
        yield return ("unauthenticated", new TrayRenderState.Unauthenticated());
        yield return ("authfailed", new TrayRenderState.AuthFailed());
        yield return ("statuserror", new TrayRenderState.StatusError());
        yield return ("statusstale", new TrayRenderState.StatusStale());
        yield return ("statusloading", new TrayRenderState.StatusLoading());
    }

    public static IEnumerable<object[]> StateNamesBySize()
    {
        foreach (int size in CellSizes)
        {
            foreach (var (name, _) in AllStates())
            {
                yield return new object[] { name, size };
            }
        }
    }

    private static TrayRenderState StateNamed(string name)
    {
        foreach (var (candidate, state) in AllStates())
        {
            if (candidate == name)
            {
                return state;
            }
        }
        throw new ArgumentOutOfRangeException(nameof(name), name, "unknown state name");
    }

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
    public void Render_ChangedCountdownString_OnBattery_IsSuppressed()
    {
        // The square icon draws no countdown cell, so a per-minute tick that changes only the
        // countdown string must NOT re-rasterize the battery: every such call is suppressed.
        using var renderer = new DualHorizontalRenderer();
        var state = new TrayRenderState.Battery(Snapshot(session: 75, weekly: 43));

        using Bitmap? first = renderer.Render(state, ThemeBucket.Dark, countdown: "32m");
        Assert.NotNull(first);

        Bitmap? next = renderer.Render(state, ThemeBucket.Dark, countdown: "31m");
        Assert.Null(next);
        Assert.Equal(1, renderer.SuppressedCount);

        Bitmap? cleared = renderer.Render(state, ThemeBucket.Dark, countdown: "");
        Assert.Null(cleared);
        Assert.Equal(2, renderer.SuppressedCount);
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
    public void Render_SizeOnlyChange_ReRenders_ContrastToCountdown()
    {
        // The cell size (SM_CXSMICON, a DPI-scaling change) IS part of the signature: the same
        // state/theme/countdown at a new size must repaint, while (above) a countdown-only change on
        // the same battery state must not.
        using var renderer = new DualHorizontalRenderer();
        var state = new TrayRenderState.Battery(Snapshot(session: 75, weekly: 43));

        using Bitmap? at16 = renderer.Render(state, ThemeBucket.Dark, "5h+", size: 16);
        Assert.NotNull(at16);

        using Bitmap? at24 = renderer.Render(state, ThemeBucket.Dark, "5h+", size: 24);
        Assert.NotNull(at24); // a scaling change repaints
        Assert.Equal(24, at24!.Width);
        Assert.Equal(0, renderer.SuppressedCount);

        Bitmap? held = renderer.Render(state, ThemeBucket.Dark, "3h+", size: 24);
        Assert.Null(held); // same size, countdown-only change -> suppressed
        Assert.Equal(1, renderer.SuppressedCount);
    }

    // --- Square cell geometry ---

    [Theory]
    [MemberData(nameof(StateNamesBySize))]
    public void Render_EveryBranch_IsSquareAtTheRequestedCellSize(string stateName, int size)
    {
        // The Windows notification area draws each icon into a square SM_CXSMICON cell and stretches
        // whatever it gets; a non-square bitmap is squashed, so every branch must be size x size.
        foreach (ThemeBucket theme in new[] { ThemeBucket.Light, ThemeBucket.Dark })
        {
            using var renderer = new DualHorizontalRenderer();
            using Bitmap? bitmap = renderer.Render(StateNamed(stateName), theme, "", size);
            Assert.NotNull(bitmap);
            Assert.Equal(size, bitmap!.Width);
            Assert.Equal(size, bitmap.Height);
        }
    }

    [Fact]
    public void Render_DefaultSize_Is16()
    {
        using var renderer = new DualHorizontalRenderer();
        using Bitmap? bitmap = renderer.Render(new TrayRenderState.Battery(Snapshot(50, 50)), ThemeBucket.Dark, "");
        Assert.NotNull(bitmap);
        Assert.Equal(16, bitmap!.Width);
        Assert.Equal(16, bitmap.Height);
    }

    [Fact]
    public void Render_TopBarFillRun_GrowsWithSessionRemaining()
    {
        // At 32 px the session bar is the top bar; count the fill pixels (opaque, not the white
        // outline/nub) along its middle row. 75% remaining must paint a longer run than 25%.
        const int size = 32;
        int run25 = TopBarFillRun(Snapshot(session: 25, weekly: 50), size);
        int run75 = TopBarFillRun(Snapshot(session: 75, weekly: 50), size);

        Assert.True(run25 > 0, $"25% painted no fill pixels (run {run25})");
        Assert.True(run75 > run25, $"75% run ({run75}) is not longer than 25% run ({run25})");
    }

    [Fact]
    public void Render_ZeroRemaining_PaintsNoFillOnTopBar()
    {
        Assert.Equal(0, TopBarFillRun(Snapshot(session: 0, weekly: 0), 32));
    }

    private static int TopBarFillRun(UsageSnapshot usage, int size)
    {
        using var renderer = new DualHorizontalRenderer(); // fresh: the signature cache must not suppress
        using Bitmap? bitmap = renderer.Render(new TrayRenderState.Battery(usage), ThemeBucket.Dark, "", size);
        Assert.NotNull(bitmap);

        // Top bar: y = round(0.08 * size), height = round(0.36 * size); sample its middle row.
        int barTop = (int)Math.Round(size * 0.08);
        int barHeight = (int)Math.Round(size * 0.36);
        int row = barTop + barHeight / 2;

        int fill = 0;
        for (int x = 0; x < size; x++)
        {
            Color px = bitmap!.GetPixel(x, row);
            bool opaque = px.A > 127;
            bool baseWhite = px.R > 200 && px.G > 200 && px.B > 200; // the dark-taskbar outline/nub
            if (opaque && !baseWhite)
            {
                fill++;
            }
        }
        return fill;
    }

    // --- Icon artifacts for CI (the developer has no Windows box; this is how the icon is seen) ---

    [Fact]
    public void RenderAllStates_WritesArtifactsWhenRequested()
    {
        string? dir = Environment.GetEnvironmentVariable("CLAUDE_BATTERY_ICON_ARTIFACTS");
        bool write = !string.IsNullOrEmpty(dir);
        if (write)
        {
            Directory.CreateDirectory(dir!);
        }

        foreach (int size in CellSizes)
        {
            foreach (ThemeBucket theme in new[] { ThemeBucket.Light, ThemeBucket.Dark })
            {
                foreach (var (name, state) in AllStates())
                {
                    using var renderer = new DualHorizontalRenderer(); // fresh per state: no cache suppression
                    using Bitmap? bitmap = renderer.Render(state, theme, "", size);
                    Assert.NotNull(bitmap);
                    Assert.Equal(size, bitmap!.Width);
                    Assert.Equal(size, bitmap.Height);

                    if (!write)
                    {
                        continue;
                    }

                    string themeName = theme.ToString().ToLowerInvariant();
                    string stem = $"icon-{name}-{themeName}-{size}";
                    bitmap.Save(Path.Combine(dir!, stem + ".png"), ImageFormat.Png);

                    // The upscale sits on the taskbar colour the theme bucket targets, because a
                    // light outline on a transparent PNG is invisible in an image viewer.
                    using Bitmap upscaled = UpscaleNearest(bitmap, factor: 8, TaskbarColorFor(theme));
                    upscaled.Save(Path.Combine(dir!, stem + "-x8.png"), ImageFormat.Png);
                }
            }
        }
    }

    /// <summary>The stock Windows 11 taskbar colour for each theme bucket, for artifact backgrounds.</summary>
    private static Color TaskbarColorFor(ThemeBucket theme) =>
        theme == ThemeBucket.Dark ? Color.FromArgb(0x20, 0x20, 0x20) : Color.FromArgb(0xF3, 0xF3, 0xF3);

    /// <summary>Blocky nearest-neighbour upscale so a 16 px icon is readable in a PR artifact.</summary>
    private static Bitmap UpscaleNearest(Bitmap source, int factor, Color background)
    {
        var scaled = new Bitmap(source.Width * factor, source.Height * factor, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(scaled);
        g.InterpolationMode = InterpolationMode.NearestNeighbor;
        g.PixelOffsetMode = PixelOffsetMode.Half;
        g.Clear(background);
        g.DrawImage(source, new Rectangle(0, 0, scaled.Width, scaled.Height));
        return scaled;
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
