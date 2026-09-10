using System.Globalization;
using System.Windows;
using System.Windows.Media;
using ClaudeBatteryWin.ViewModels;
using ClaudeBatteryWin.Views;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// Tests for the flyout's value converters and the WPF resource rule the theming fix relies on. None
/// of these instantiate a Window or need an STA thread: converters are plain objects, and the test
/// project has UseWPF=true so <see cref="SolidColorBrush"/> / <see cref="ResourceDictionary"/> load
/// without an Application.
///
/// The brush converters used to resolve their keys through <c>Application.Current.TryFindResource</c>,
/// which never sees a window's resources; in the app that returned Transparent for every gauge fill
/// and bar. They now return frozen constants, which these tests pin.
/// </summary>
public class FlyoutConvertersTests
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    // MARK: - UsageColor / SpendColor brushes are frozen constants, never resource lookups

    [Theory]
    [InlineData(UsageColor.Red, "#FFE74C3C")]
    [InlineData(UsageColor.Orange, "#FFF39C12")]
    [InlineData(UsageColor.Green, "#FF2ECC71")]
    public void UsageColorToBrush_ReturnsFrozenSemanticBrush(UsageColor color, string expectedHex)
    {
        var brush = new UsageColorToBrushConverter().Convert(color, typeof(Brush), null, Inv);

        var solid = Assert.IsType<SolidColorBrush>(brush);
        Assert.Equal(expectedHex, solid.Color.ToString(Inv));
        Assert.True(solid.IsFrozen, "converter brushes must be frozen (thread-free, shareable)");
    }

    [Fact]
    public void UsageColorToBrush_Null_IsTransparent()
    {
        // No color (an absent pace bar) draws nothing.
        var brush = new UsageColorToBrushConverter().Convert(null, typeof(Brush), null, Inv);
        Assert.Same(Brushes.Transparent, brush);
    }

    [Fact]
    public void SpendColorToBrush_Cyan_IsTheDarkCyanConstant()
    {
        var brush = new SpendColorToBrushConverter().Convert(SpendColor.Cyan, typeof(Brush), null, Inv);

        var solid = Assert.IsType<SolidColorBrush>(brush);
        Assert.Equal("#FF22C3E6", solid.Color.ToString(Inv));
        Assert.True(solid.IsFrozen);
    }

    [Fact]
    public void SpendColorToBrush_Null_IsTransparent_ForTheEmptyTrack()
    {
        var brush = new SpendColorToBrushConverter().Convert(null, typeof(Brush), null, Inv);
        Assert.Same(Brushes.Transparent, brush);
    }

    // MARK: - PercentOfWidthConverter: percent of the track's REAL width

    [Fact]
    public void PercentOfWidth_HalfOfTrack_IsHalfTheTrackWidth()
    {
        Assert.Equal(44.0, ConvertWidth(50, 88.0));
    }

    [Fact]
    public void PercentOfWidth_OverHundred_ClampsToTrackWidth()
    {
        Assert.Equal(88.0, ConvertWidth(150, 88.0));
    }

    [Fact]
    public void PercentOfWidth_UnsetPercent_IsZero()
    {
        // A MultiBinding hands DependencyProperty.UnsetValue for a source that has not resolved yet.
        Assert.Equal(0.0, ConvertWidth(DependencyProperty.UnsetValue, 88.0));
    }

    [Fact]
    public void PercentOfWidth_NullPercent_IsZero()
    {
        Assert.Equal(0.0, ConvertWidth(null, 88.0));
    }

    [Fact]
    public void PercentOfWidth_UnsetTrackWidth_IsZero()
    {
        // Before the track's first layout pass its ActualWidth is unavailable: draw nothing, not NaN.
        Assert.Equal(0.0, ConvertWidth(50, DependencyProperty.UnsetValue));
    }

    private static object ConvertWidth(object? percent, object? trackWidth)
        => new PercentOfWidthConverter().Convert(new[] { percent!, trackWidth! }, typeof(double), null, Inv);

    // MARK: - WPF resource precedence: the base dictionary shadows merged dictionaries

    [Fact]
    public void ResourceDictionary_BaseEntryShadowsMergedEntry_WithTheSameKey()
    {
        // Documents the WPF rule the theming fix relies on: a key defined in a dictionary's own
        // entries wins over the same key in any of its MergedDictionaries. FlyoutWindow therefore
        // keeps every theme token OUT of its base dictionary (only in the merged theme dictionary)
        // so ApplyTheme's MergedDictionaries[0] swap is what the DynamicResource consumers see.
        var merged = new ResourceDictionary { ["K"] = "merged" };
        var dict = new ResourceDictionary { ["K"] = "base" };
        dict.MergedDictionaries.Add(merged);

        Assert.Equal("base", dict["K"]);
    }

    [Fact]
    public void ResourceDictionary_MergedEntryResolves_WhenBaseLacksTheKey()
    {
        // The complementary half: with no base entry the merged dictionary supplies the value, and
        // replacing the merged dictionary changes what the key resolves to (the ApplyTheme mechanism).
        var dict = new ResourceDictionary();
        dict.MergedDictionaries.Add(new ResourceDictionary { ["K"] = "dark" });
        Assert.Equal("dark", dict["K"]);

        dict.MergedDictionaries[0] = new ResourceDictionary { ["K"] = "light" };
        Assert.Equal("light", dict["K"]);
    }
}
