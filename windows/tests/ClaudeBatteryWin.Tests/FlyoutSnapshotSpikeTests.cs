using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Xunit;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.ViewModels;
using ClaudeBatteryWin.Views;
using ShapePath = System.Windows.Shapes.Path;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U1 spike (R3): can the WPF flyout be rendered to an image inside a CI test run?
///
/// The tray icon is pure GDI+ and already renders to PNG artifacts (<see cref="IconRenderTests"/>),
/// but the panel is WPF, and <c>RenderTargetBitmap</c> has a documented history of returning blank
/// images on headless and service sessions (dotnet/wpf issues 2811 and 3765; the headless fix in
/// dotnet/wpf pull 11467 is unmerged and targets .NET 12). The only known mitigation is the
/// AppContext switch set in <see cref="EnableHeadlessRendering"/>.
///
/// Two renders live here. The first is the spike itself: the real gauge dial, built from the real
/// <see cref="GaugeCard"/> record through the real <see cref="GaugeArcConverter"/> and
/// <see cref="GaugeTicksConverter"/>, asserted not to be one flat colour. The second renders the
/// whole panel out of <see cref="FlyoutWindow"/> itself, which is the image the layout requirements
/// (R26, R30) are actually judged from. A fail means the fallback applies: layout is judged from the
/// smoke-launch desktop screenshots with the flyout open (KD12).
///
/// Set <c>CLAUDE_BATTERY_ICON_ARTIFACTS</c> (CI does) and the PNGs land beside the tray icons.
/// </summary>
public class FlyoutSnapshotSpikeTests
{
    /// <summary>The 58x58 dial host box the gauge template uses. The converters draw at these
    /// absolute coordinates, so the render surface has to be exactly that box.</summary>
    private const int DialBox = 58;

    /// <summary>
    /// The switch from dotnet/wpf issue 2811. Without it, WPF can refuse to compose on a session
    /// with no display device and <c>RenderTargetBitmap</c> comes back empty.
    /// </summary>
    private static void EnableHeadlessRendering() =>
        AppContext.SetSwitch("Switch.System.Windows.Media.ShouldRenderEvenWhenNoDisplayDevicesAreAvailable", true);

    private static GaugeCard SessionCardAt76Percent() => new()
    {
        Title = "Session",
        RemainingPercent = 76,
        Color = UsageColor.Green,
        TickCount = 5,
        TimeRemainingPercent = 40,
        Pace = PaceStatus.OnTrack,
        PaceCaption = "On Track",
        PaceCaptionColor = UsageColor.Green,
        Countdown = "Resets in 2h 00m"
    };

    /// <summary>
    /// The dial as the flyout draws it: track arc, ticks, fill arc, centred percent label, on an
    /// opaque panel background. Built in code rather than from the window's XAML because the template
    /// lives inside <c>FlyoutWindow.xaml</c> and instantiating the window needs the whole app.
    /// </summary>
    private static FrameworkElement BuildDial(GaugeCard card)
    {
        var arc = new GaugeArcConverter();
        var ticks = new GaugeTicksConverter();

        Geometry Arc(string which) =>
            (Geometry)arc.Convert(card, typeof(Geometry), which, System.Globalization.CultureInfo.InvariantCulture)!;

        var host = new Grid { Width = DialBox, Height = DialBox, Background = Brushes.White };

        host.Children.Add(new ShapePath
        {
            Stroke = new SolidColorBrush(Color.FromRgb(0xE0, 0xE0, 0xE0)),
            StrokeThickness = 5,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            Data = Arc("track")
        });
        host.Children.Add(new ShapePath
        {
            Stroke = new SolidColorBrush(Color.FromRgb(0x99, 0x99, 0x99)),
            StrokeThickness = 1.5,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            Data = (Geometry)ticks.Convert(card, typeof(Geometry), null, System.Globalization.CultureInfo.InvariantCulture)!
        });
        host.Children.Add(new ShapePath
        {
            Stroke = new SolidColorBrush(Color.FromRgb(0x2E, 0xA0, 0x43)),
            StrokeThickness = 5,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            Data = Arc("fill")
        });
        host.Children.Add(new TextBlock
        {
            Text = card.PercentLabel,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 4, 0, 0),
            FontSize = 15,
            FontWeight = FontWeights.Bold,
            Foreground = Brushes.Black
        });

        return host;
    }

    /// <summary>Lays the element out and renders it at the given DPI scale.</summary>
    private static RenderTargetBitmap RenderAtScale(FrameworkElement element, double scale)
    {
        var size = new Size(DialBox, DialBox);
        element.Measure(size);
        element.Arrange(new Rect(size));
        element.UpdateLayout();

        var dpi = 96 * scale;
        var target = new RenderTargetBitmap(
            (int)Math.Round(DialBox * scale),
            (int)Math.Round(DialBox * scale),
            dpi,
            dpi,
            PixelFormats.Pbgra32);
        target.Render(element);
        return target;
    }

    /// <summary>True when the bitmap holds more than one distinct pixel value.</summary>
    private static bool HasNonUniformPixels(BitmapSource bitmap)
    {
        int stride = bitmap.PixelWidth * 4;
        var pixels = new byte[stride * bitmap.PixelHeight];
        bitmap.CopyPixels(pixels, stride, 0);

        for (int i = 4; i < pixels.Length; i += 4)
        {
            if (pixels[i] != pixels[0] || pixels[i + 1] != pixels[1] ||
                pixels[i + 2] != pixels[2] || pixels[i + 3] != pixels[3])
            {
                return true;
            }
        }
        return false;
    }

    private static void SavePng(BitmapSource bitmap, string stem)
    {
        string? dir = Environment.GetEnvironmentVariable("CLAUDE_BATTERY_ICON_ARTIFACTS");
        if (string.IsNullOrEmpty(dir))
        {
            return; // no artifact directory: the assertion above is the whole point of the run
        }

        Directory.CreateDirectory(dir);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(System.IO.Path.Combine(dir, stem + ".png"));
        encoder.Save(stream);
    }

    /// <summary>
    /// The spike itself. Renders the Session dial at 76 percent remaining at 100 and 200 percent
    /// scaling and asserts each PNG has more than one pixel value. If this fails on the CI runner,
    /// KD12 applies: skip this test with the reason and judge layout from the smoke-launch shots.
    /// </summary>
    [WpfTheory]
    [InlineData(1.0)]
    [InlineData(2.0)]
    public void GaugeDial_RendersNonBlank(double scale)
    {
        EnableHeadlessRendering();

        var card = SessionCardAt76Percent();
        var bitmap = RenderAtScale(BuildDial(card), scale);

        SavePng(bitmap, $"flyout-dial-session-76-{(int)(scale * 100)}");

        Assert.True(
            HasNonUniformPixels(bitmap),
            $"RenderTargetBitmap produced a uniform image at {scale:0.#}x scale. " +
            "The headless render path is unavailable on this runner; apply the KD12 fallback.");
    }

    // --- The whole panel, as the user sees it -----------------------------------------------------

    /// <summary>
    /// The panel image the layout requirements are judged from: the real <see cref="FlyoutWindow"/>
    /// content, with its real templates, converters and theme tokens, rendered at 100 and 200 percent
    /// scaling (R3, R26, R30).
    ///
    /// The dial spike above proves the render path works; this proves the layout. It is the only way
    /// anyone sees the Windows panel without a Windows machine, so the reading it carries is
    /// deliberately busy: both dials with a pace word, a countdown and a run-out line, an update
    /// notice at the top, model bars, a credits row and two accounts.
    /// </summary>
    [WpfTheory]
    [InlineData(1.0)]
    [InlineData(2.0)]
    public void FlyoutPanel_RendersTheWholeCard(double scale)
    {
        EnableHeadlessRendering();
        EnsureApplication();

        var window = new FlyoutWindow { DataContext = BusyPanelViewModel() };
        var root = (FrameworkElement)window.Content;

        // The window is 300 DIP wide with SizeToContent=Height; measure against that, unbounded down.
        root.Measure(new Size(300, double.PositiveInfinity));
        var size = new Size(300, root.DesiredSize.Height);
        root.Arrange(new Rect(size));
        root.UpdateLayout();

        var dpi = 96 * scale;
        var target = new RenderTargetBitmap(
            (int)Math.Round(size.Width * scale),
            (int)Math.Round(size.Height * scale),
            dpi,
            dpi,
            PixelFormats.Pbgra32);
        target.Render(root);

        SavePng(target, $"flyout-panel-{(int)(scale * 100)}");

        Assert.True(size.Height > 200, $"the panel laid out only {size.Height:0} DIP tall; it is not showing its content");
        Assert.True(
            HasNonUniformPixels(target),
            $"the panel rendered as one flat colour at {scale:0.#}x scale; apply the KD12 fallback.");
    }

    /// <summary>The window expects an Application instance to resolve its resources through. The
    /// test host has none, so make one; it is never started.</summary>
    private static void EnsureApplication()
    {
        if (Application.Current is null)
        {
            _ = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        }
    }

    /// <summary>A reading with something in every row, so nothing in the panel is left undrawn.</summary>
    private static FlyoutViewModel BusyPanelViewModel()
    {
        var now = new DateTimeOffset(2026, 9, 14, 12, 0, 0, TimeSpan.Zero);
        var vm = new FlyoutViewModel(() => now)
        {
            IsAuthenticated = true,
            LastSuccessfulFetch = now.AddMinutes(-2),
            AvailableUpdateVersion = "1.73",
        };

        var account = new Account
        {
            Email = "you@example.com",
            SessionKey = "sk",
            OrganizationId = "org-1",
            OrganizationName = "Personal",
        };
        var other = new Account
        {
            Email = "work@example.com",
            SessionKey = "sk",
            OrganizationId = "org-2",
            OrganizationName = "Acme",
        };

        vm.Accounts = new[] { account, other };
        vm.ActiveAccountId = account.Id;
        vm.LatestReading = new UsageReading(
            new UsageSnapshot
            {
                SessionRemaining = 76,
                SessionResetDate = now.AddHours(2),
                SessionPercentWasRead = true,
                WeeklyRemaining = 38,
                WeeklyResetDate = now.AddDays(3),
                WeeklyPercentWasRead = true,
                ModelUsages = new[]
                {
                    new ModelUsage { DisplayName = "Opus", RemainingPercent = 12, ResetDate = now.AddDays(3) },
                    new ModelUsage { DisplayName = "Sonnet", RemainingPercent = 64, ResetDate = now.AddDays(3) },
                },
                Credits = new UsageCredits
                {
                    StateKind = CreditsStateKind.Enabled,
                    Spent = 12.5,
                    SpendPercent = 25,
                    SpendCurrency = "USD",
                    StateResetDate = now.AddDays(17),
                },
            },
            PlanRatio: null);

        return vm;
    }

    /// <summary>
    /// With no artifact directory set the spike writes nothing and still runs its assertion, so a
    /// local run never litters the working tree.
    /// </summary>
    [WpfFact]
    public void SavePng_WithoutArtifactDirectory_WritesNothing()
    {
        EnableHeadlessRendering();

        string? previous = Environment.GetEnvironmentVariable("CLAUDE_BATTERY_ICON_ARTIFACTS");
        Environment.SetEnvironmentVariable("CLAUDE_BATTERY_ICON_ARTIFACTS", null);
        try
        {
            var bitmap = RenderAtScale(BuildDial(SessionCardAt76Percent()), 1.0);
            SavePng(bitmap, "should-not-exist");
            Assert.False(File.Exists("should-not-exist.png"));
        }
        finally
        {
            Environment.SetEnvironmentVariable("CLAUDE_BATTERY_ICON_ARTIFACTS", previous);
        }
    }
}
