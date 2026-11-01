import XCTest
import AppKit
@testable import ClaudeBattery

final class IconStyleTests: XCTestCase {

    // MARK: - Happy Path: Every case returns a non-nil renderer

    func testAllCasesReturnNonNilRenderer() {
        for style in IconStyle.allCases {
            let renderer = style.renderer
            // IconRenderer is a protocol, so a non-nil concrete instance satisfies this
            XCTAssertTrue(renderer is IconRenderer, "\(style.rawValue) should return a valid renderer")
        }
    }

    // MARK: - Happy Path: Expected renderer types per case

    func testDualHorizontalRendererType() {
        let renderer = IconStyle.dualHorizontal.renderer
        XCTAssertTrue(renderer is DualHorizontalRenderer, "dualHorizontal should return DualHorizontalRenderer")
    }

    func testMinimalRendererType() {
        let renderer = IconStyle.minimal.renderer
        XCTAssertTrue(renderer is MinimalRenderer, "minimal should return MinimalRenderer")
    }

    func testDualArcGaugeRendererType() {
        let renderer = IconStyle.dualArcGauge.renderer
        XCTAssertTrue(renderer is DualArcGaugeRenderer, "dualArcGauge should return DualArcGaugeRenderer")
    }

    func testTextOnlyRendererType() {
        let renderer = IconStyle.textOnly.renderer
        XCTAssertTrue(renderer is TextOnlyRenderer, "textOnly should return TextOnlyRenderer")
    }

    func testStackedBarsRendererType() {
        let renderer = IconStyle.stackedBars.renderer
        XCTAssertTrue(renderer is StackedBarsRenderer, "stackedBars should return StackedBarsRenderer")
    }

    // MARK: - CaseIterable completeness

    func testAllCasesCountMatchesExpected() {
        // If a new case is added to IconStyle but tests aren't updated,
        // this will flag it
        XCTAssertEqual(IconStyle.allCases.count, 5, "Expected five icon styles")
    }

    // MARK: - Raw values match display strings

    func testRawValuesAreHumanReadable() {
        let expectedRawValues: Set<String> = [
            "Dual Horizontal",
            "Minimal",
            "Dual Arc Gauge",
            "Text Only",
            "Stacked Bars",
        ]
        let actualRawValues = Set(IconStyle.allCases.map(\.rawValue))
        XCTAssertEqual(actualRawValues, expectedRawValues)
    }

    // MARK: - Weekly cap: the menu bar shows what the popover shows

    /// When the weekly limit binds, every menu-bar renderer must draw the same weekly-capped
    /// session value the popover dial shows (`sessionDisplayRemaining`). Two snapshots sharing a
    /// low weekly but differing wildly in raw session collapse to the same displayed value, so
    /// their icons must come out identical. A renderer that slipped back to raw `sessionRemaining`
    /// re-opens the reported mismatch: 51 in the menu bar next to 15 in the popover.
    func testWeeklyLimited_allRenderersDrawTheCappedSession() {
        // Weekly 5 on a Max 5x ratio is 63.1% of a session, so both sessions above it collapse
        // onto that one displayed value. Without a plan ratio there is nothing to convert and no
        // cap happens at all, which is why the fixtures carry one.
        let high = RenderStateTests.makeUsage(sessionUtilization: 20, weeklyUtilization: 95,
                                              planRatio: PlanRatio.max5x) // session 80, weekly 5
        let low = RenderStateTests.makeUsage(sessionUtilization: 30, weeklyUtilization: 95,
                                             planRatio: PlanRatio.max5x)  // session 70, weekly 5

        XCTAssertTrue(high.isSessionWeeklyLimited)
        XCTAssertTrue(low.isSessionWeeklyLimited)
        XCTAssertNotEqual(high.sessionRemaining, low.sessionRemaining, accuracy: 0.01)
        XCTAssertEqual(high.sessionDisplayRemaining, low.sessionDisplayRemaining, accuracy: 0.01)

        for style in IconStyle.allCases {
            let fromHighSession = style.renderer.makeBatteryIcon(usage: high, color: .white).tiffRepresentation
            let fromLowSession = style.renderer.makeBatteryIcon(usage: low, color: .white).tiffRepresentation
            XCTAssertNotNil(fromHighSession, "\(style.rawValue) produced no image data")
            XCTAssertEqual(fromHighSession, fromLowSession,
                           "\(style.rawValue) draws the raw session, not the weekly-capped value")
        }
    }

    /// An exhausted week caps the session to empty on every plan, so it does so with no plan too.
    /// The popover and the menu bar have to agree there like anywhere else: this is the state every
    /// account carried over from v1.60 is in (no stored tier, and blocked so it cannot accumulate a
    /// measurement), and the menu bar is where most users would see it first.
    func testWeeklyExhaustedWithNoRatio_allRenderersDrawEmpty() {
        // No plan ratio on either fixture. A full session and an empty one both display 0 once the
        // week is spent, so their icons must be identical; without the zero case the first draws a
        // full session pill and the second an empty one.
        let fullSession = RenderStateTests.makeUsage(sessionUtilization: 0, weeklyUtilization: 100)
        let emptySession = RenderStateTests.makeUsage(sessionUtilization: 100, weeklyUtilization: 100)

        XCTAssertNil(fullSession.planRatio)
        XCTAssertNotEqual(fullSession.sessionRemaining, emptySession.sessionRemaining, accuracy: 0.01)
        XCTAssertEqual(fullSession.sessionDisplayRemaining, 0, accuracy: 0.01)
        XCTAssertEqual(emptySession.sessionDisplayRemaining, 0, accuracy: 0.01)

        for style in IconStyle.allCases {
            let fromFull = style.renderer.makeBatteryIcon(usage: fullSession, color: .white).tiffRepresentation
            let fromEmpty = style.renderer.makeBatteryIcon(usage: emptySession, color: .white).tiffRepresentation
            XCTAssertNotNil(fromFull, "\(style.rawValue) produced no image data")
            XCTAssertEqual(fromFull, fromEmpty,
                           "\(style.rawValue) draws a full session on a spent week, so it is reading the raw value")
        }
    }

    /// The cap is gated, not unconditional. In a healthy week the renderers keep showing the true
    /// session, so two different sessions must still produce different icons.
    ///
    /// The `aboveWeekly` pair is what rules out an unconditional `min(session, weekly)`: both its
    /// sessions sit ABOVE the same healthy weekly, so a renderer taking the minimum would draw 60
    /// for both and the two icons would come out identical. The high/low pair alone cannot catch
    /// that - min() leaves 8 alone, so those icons differ either way.
    ///
    /// Proving it by holding the session fixed and varying only the weekly is not an option: all
    /// five styles draw the weekly into the same image, so a different weekly always changes the
    /// bytes even when the session is drawn correctly.
    func testHealthyWeekly_renderersStillShowTheRawSession() {
        // All three carry a plan ratio, so the cap is live and genuinely declines to fire: 60% of
        // a Max 5x week is more than a full session, so it caps nothing.
        let high = RenderStateTests.makeUsage(sessionUtilization: 20, weeklyUtilization: 40,
                                              planRatio: PlanRatio.max5x) // session 80, weekly 60
        let low = RenderStateTests.makeUsage(sessionUtilization: 92, weeklyUtilization: 40,
                                             planRatio: PlanRatio.max5x)  // session 8,  weekly 60
        let aboveWeekly = RenderStateTests.makeUsage(sessionUtilization: 39, weeklyUtilization: 40,
                                                     planRatio: PlanRatio.max5x) // session 61, weekly 60

        XCTAssertFalse(high.isSessionWeeklyLimited)
        XCTAssertFalse(low.isSessionWeeklyLimited)
        XCTAssertFalse(aboveWeekly.isSessionWeeklyLimited)
        // Same weekly, and both sessions clear it, so min() would flatten both onto that weekly.
        XCTAssertEqual(high.weeklyRemaining, aboveWeekly.weeklyRemaining, accuracy: 0.01)
        XCTAssertGreaterThan(high.sessionRemaining, high.weeklyRemaining)
        XCTAssertGreaterThan(aboveWeekly.sessionRemaining, aboveWeekly.weeklyRemaining)

        for style in IconStyle.allCases {
            let fromHighSession = style.renderer.makeBatteryIcon(usage: high, color: .white).tiffRepresentation
            let fromLowSession = style.renderer.makeBatteryIcon(usage: low, color: .white).tiffRepresentation
            XCTAssertNotEqual(fromHighSession, fromLowSession,
                              "\(style.rawValue) should still tell 80% and 8% apart in a healthy week")

            let fromAboveWeekly = style.renderer.makeBatteryIcon(usage: aboveWeekly, color: .white).tiffRepresentation
            XCTAssertNotNil(fromAboveWeekly, "\(style.rawValue) produced no image data")
            XCTAssertNotEqual(fromHighSession, fromAboveWeekly,
                              "\(style.rawValue) collapses 80% and 61% onto their shared 60% weekly, so it is capping unconditionally instead of only when the weekly is low")
        }
    }

    // MARK: - Fractional percentages: the menu bar rounds the way the popover does

    /// The popover prints its numbers with `%.0f`, which ROUNDS. The renderers that turn the
    /// percentage into an `Int` must round too, or 15.6% remaining draws 15 in the menu bar while
    /// the popover reads 16% - the same cross-surface mismatch this branch exists to close, one
    /// digit smaller. So a fractional session must draw the icon its ROUNDED whole value draws,
    /// and not the icon its TRUNCATED value draws.
    ///
    /// Only the `Int`-converting styles are checked. Stacked Bars and Dual Arc Gauge scale their
    /// fills straight from the Double, so 15.6 legitimately draws slightly differently from both
    /// 16 and 15 and there is no rounding choice to lock.
    func testFractionalSession_renderersRoundRatherThanTruncate() {
        // Weekly is healthy and identical across all three fixtures, so the cap gate stays off and
        // the session value is the only thing moving.
        let fractional = RenderStateTests.makeUsage(sessionUtilization: 84.4, weeklyUtilization: 40) // session 15.6
        let rounded = RenderStateTests.makeUsage(sessionUtilization: 84, weeklyUtilization: 40)      // session 16
        let truncated = RenderStateTests.makeUsage(sessionUtilization: 85, weeklyUtilization: 40)    // session 15

        XCTAssertFalse(fractional.isSessionWeeklyLimited)
        XCTAssertEqual(fractional.sessionDisplayRemaining, 15.6, accuracy: 0.001)
        XCTAssertEqual(rounded.sessionDisplayRemaining, 16, accuracy: 0.001)
        XCTAssertEqual(truncated.sessionDisplayRemaining, 15, accuracy: 0.001)

        for style in Self.digitDrawingStyles {
            let fromFraction = style.renderer.makeBatteryIcon(usage: fractional, color: .white).tiffRepresentation
            let fromRounded = style.renderer.makeBatteryIcon(usage: rounded, color: .white).tiffRepresentation
            let fromTruncated = style.renderer.makeBatteryIcon(usage: truncated, color: .white).tiffRepresentation
            XCTAssertNotNil(fromFraction, "\(style.rawValue) produced no image data")
            XCTAssertEqual(fromFraction, fromRounded,
                           "\(style.rawValue) draws 15.6% as something other than 16, but the popover reads 16%")
            XCTAssertNotEqual(fromFraction, fromTruncated,
                              "\(style.rawValue) truncates 15.6% down to 15 while the popover reads 16%")
        }
    }

    /// The weekly pill has to round the same way the session pill does. Without this, reverting the
    /// weekly half of the rounding fix leaves the whole suite green, because every other fixture in
    /// this file passes a whole-number weekly where truncating and rounding agree.
    func testFractionalWeekly_renderersRoundItToo() {
        // Session is healthy, whole, and well above the weekly, so the gate stays off and the
        // weekly value is the only thing moving.
        let fractional = RenderStateTests.makeUsage(sessionUtilization: 16, weeklyUtilization: 59.4) // weekly 40.6
        let rounded = RenderStateTests.makeUsage(sessionUtilization: 16, weeklyUtilization: 59)      // weekly 41
        let truncated = RenderStateTests.makeUsage(sessionUtilization: 16, weeklyUtilization: 60)    // weekly 40

        XCTAssertFalse(fractional.isSessionWeeklyLimited)
        XCTAssertEqual(fractional.weeklyRemaining, 40.6, accuracy: 0.001)

        for style in Self.digitDrawingStyles {
            let fromFraction = style.renderer.makeBatteryIcon(usage: fractional, color: .white).tiffRepresentation
            let fromRounded = style.renderer.makeBatteryIcon(usage: rounded, color: .white).tiffRepresentation
            let fromTruncated = style.renderer.makeBatteryIcon(usage: truncated, color: .white).tiffRepresentation
            XCTAssertNotNil(fromFraction, "\(style.rawValue) produced no image data")
            XCTAssertEqual(fromFraction, fromRounded,
                           "\(style.rawValue) draws a weekly of 40.6% as something other than 41")
            XCTAssertNotEqual(fromFraction, fromTruncated,
                              "\(style.rawValue) truncates the weekly 40.6% down to 40")
        }
    }

    /// An exact half is where the two surfaces are easiest to split apart: `%.0f` rounds half to
    /// EVEN, so 16.5% prints as "16%" in the popover. A renderer using plain `.rounded()`
    /// (half away from zero) would draw 17 beside it - the same cross-surface mismatch this branch
    /// exists to close. Locks `.toNearestOrEven` specifically, not just "rounds somehow".
    func testExactHalfSession_roundsHalfToEvenLikeThePopover() {
        let half = RenderStateTests.makeUsage(sessionUtilization: 83.5, weeklyUtilization: 40)  // session 16.5
        let even = RenderStateTests.makeUsage(sessionUtilization: 84, weeklyUtilization: 40)    // session 16
        let awayFromZero = RenderStateTests.makeUsage(sessionUtilization: 83, weeklyUtilization: 40) // session 17

        XCTAssertEqual(half.sessionDisplayRemaining, 16.5, accuracy: 0.001)
        // The popover's own formatter is the contract this pins the renderers against.
        XCTAssertEqual(String(format: "%.0f", half.sessionDisplayRemaining), "16")

        for style in Self.digitDrawingStyles {
            let fromHalf = style.renderer.makeBatteryIcon(usage: half, color: .white).tiffRepresentation
            let fromEven = style.renderer.makeBatteryIcon(usage: even, color: .white).tiffRepresentation
            let fromAway = style.renderer.makeBatteryIcon(usage: awayFromZero, color: .white).tiffRepresentation
            XCTAssertEqual(fromHalf, fromEven,
                           "\(style.rawValue) does not draw 16.5% as 16, but the popover's %.0f does")
            XCTAssertNotEqual(fromHalf, fromAway,
                              "\(style.rawValue) rounds 16.5% away from zero to 17 while the popover reads 16%")
        }
    }

    /// Styles that turn the percentage into an `Int` and draw it as digits, so a rounding change
    /// moves whole glyphs. Minimal is excluded on purpose: it converts to `Int` too, but its only
    /// visible output is a fill height of `5.0 * percent / 100`, so one percentage point is a
    /// 0.05pt difference decided by antialiasing - a flake risk, not a reliable assertion.
    private static let digitDrawingStyles: [IconStyle] = [.textOnly, .dualHorizontal]

    // MARK: - No 5-hour limit: the weekly value alone

    /// An account with no 5-hour limit reads session 100 by default. A has-limit account with a full
    /// session and the same weekly therefore has the same numbers, so the only way the two icons can
    /// differ is if the session element really was left out.
    func testNoSessionLimit_everyRendererLeavesTheSessionOut() {
        let weeklyOnly = RenderStateTests.makeWeeklyOnlyUsage(weeklyUtilization: 60)
        let withSession = RenderStateTests.makeUsage(sessionUtilization: 0, weeklyUtilization: 60)
        XCTAssertFalse(weeklyOnly.hasSessionLimit)
        XCTAssertTrue(withSession.hasSessionLimit)
        XCTAssertEqual(weeklyOnly.weeklyRemaining, withSession.weeklyRemaining, accuracy: 0.01)
        XCTAssertEqual(weeklyOnly.sessionDisplayRemaining, withSession.sessionDisplayRemaining, accuracy: 0.01)

        for style in IconStyle.allCases {
            let single = style.renderer.makeBatteryIcon(usage: weeklyOnly, color: .white).tiffRepresentation
            let dual = style.renderer.makeBatteryIcon(usage: withSession, color: .white).tiffRepresentation
            XCTAssertNotNil(single, "\(style.rawValue) produced no image data")
            XCTAssertNotEqual(single, dual, "\(style.rawValue) still draws a session element with no 5-hour limit")
        }
    }

    func testNoSessionLimit_everyRendererStillDrawsTheWeekly() {
        let half = RenderStateTests.makeWeeklyOnlyUsage(weeklyUtilization: 50)  // weekly 50 left
        let low = RenderStateTests.makeWeeklyOnlyUsage(weeklyUtilization: 90)   // weekly 10 left

        for style in IconStyle.allCases {
            let fromHalf = style.renderer.makeBatteryIcon(usage: half, color: .white).tiffRepresentation
            let fromLow = style.renderer.makeBatteryIcon(usage: low, color: .white).tiffRepresentation
            XCTAssertNotEqual(fromHalf, fromLow, "\(style.rawValue) does not draw the weekly value")
        }
    }

    /// An empty week on a lone weekly icon must still read as a warning. The digit styles show it as
    /// a red number; with a 5-hour limit the icon is unchanged, so its empty weekly keeps the neutral
    /// colour it always had.
    func testNoSessionLimit_emptyWeek_digitStylesDrawARedNumber() {
        let empty = RenderStateTests.makeWeeklyOnlyUsage(weeklyUtilization: 100)
        for style in Self.digitDrawingStyles {
            let image = style.renderer.makeBatteryIcon(usage: empty, color: .white)
            XCTAssertTrue(Self.containsRed(image), "\(style.rawValue) draws an empty week without red")
        }
        let withSession = RenderStateTests.makeUsage(sessionUtilization: 0, weeklyUtilization: 100)
        XCTAssertFalse(Self.containsRed(IconStyle.dualHorizontal.renderer.makeBatteryIcon(usage: withSession, color: .white)),
                       "the two-battery icon must look as it did before")
    }

    /// Whether any pixel is clearly red (strong red channel, weak green and blue).
    private static func containsRed(_ image: NSImage) -> Bool {
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else { return false }
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { continue }
                if c.redComponent > 0.7, c.greenComponent < 0.35, c.blueComponent < 0.35 { return true }
            }
        }
        return false
    }

    func testNoSessionLimit_dualHorizontalIsOneBatteryWide() {
        let renderer = IconStyle.dualHorizontal.renderer
        let single = renderer.makeBatteryIcon(usage: RenderStateTests.makeWeeklyOnlyUsage(weeklyUtilization: 60),
                                              color: .white)
        let dual = renderer.makeBatteryIcon(usage: RenderStateTests.makeUsage(sessionUtilization: 0, weeklyUtilization: 60),
                                            color: .white)
        XCTAssertLessThan(single.size.width, dual.size.width)
        XCTAssertEqual(single.size.height, dual.size.height, "the countdown cell centres against this height")
    }

    // MARK: - Each renderer call returns a fresh instance (struct value type)

    func testRendererReturnsSameTypeEachCall() {
        // Since renderers are structs, each `.renderer` access creates a new value.
        // Verify the two calls produce equivalent but distinct values by checking
        // they're both valid (struct identity isn't reference-comparable).
        for style in IconStyle.allCases {
            let r1 = style.renderer
            let r2 = style.renderer
            XCTAssertTrue(type(of: r1) == type(of: r2), "\(style.rawValue) should return the same type each time")
        }
    }
}
