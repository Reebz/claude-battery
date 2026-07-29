import XCTest
@testable import ClaudeBattery

// MARK: - UsageData Tests (pure value type, no mocks needed)

final class UsageDataTests: XCTestCase {

    /// Decode a UsageResponse from the given fixture JSON using the same
    /// decoder configuration as the production code.
    private func decodeFixture(_ name: String) throws -> UsageResponse {
        let url = Bundle(for: type(of: self)).url(
            forResource: name, withExtension: "json"
        ) ?? fixtureURL(named: name)

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UsageResponse.self, from: data)
    }

    /// Fallback when the fixture is not embedded in the test bundle.
    private func fixtureURL(named name: String) -> URL {
        // Walk up from the compiled test binary to find the source tree
        let file = URL(fileURLWithPath: #file)
        let testsDir = file.deletingLastPathComponent()
        return testsDir
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("\(name).json")
    }

    // MARK: - Happy path

    func testFullResponse_correctRemainingPercentages() throws {
        let response = try decodeFixture("usage_full")
        let usage = UsageData(from: response)

        // remaining = 100 - utilization
        XCTAssertEqual(usage.weeklyRemaining, 40.0, accuracy: 0.01)   // 100 - 60
        XCTAssertEqual(usage.sessionRemaining, 65.0, accuracy: 0.01)  // 100 - 35
        // Per-model now derives from seven_day_* gated on non-null (KTD3), in [Opus, Sonnet] order.
        XCTAssertEqual(usage.modelUsages.count, 2)
        XCTAssertEqual(usage.modelUsages[0].displayName, "Opus")
        XCTAssertEqual(usage.modelUsages[0].remainingPercent, 20.0, accuracy: 0.01)  // 100 - 80
        XCTAssertEqual(usage.modelUsages[1].displayName, "Sonnet")
        XCTAssertEqual(usage.modelUsages[1].remainingPercent, 90.0, accuracy: 0.01)  // 100 - 10
        XCTAssertNotNil(usage.weeklyResetDate)
        XCTAssertNotNil(usage.sessionResetDate)
    }

    // MARK: - Nil utilization -> 100% remaining

    func testNilUtilization_defaultsTo100Remaining() throws {
        let response = try decodeFixture("usage_nil_fields")
        let usage = UsageData(from: response)

        // When utilization is nil, formula is 100 - 0 = 100
        XCTAssertEqual(usage.weeklyRemaining, 100.0)
        XCTAssertEqual(usage.sessionRemaining, 100.0)
        // Null per-model now hides the bar entirely - no fabricated 100% (KTD3).
        XCTAssertTrue(usage.modelUsages.isEmpty)
        XCTAssertNil(usage.weeklyResetDate)
        XCTAssertNil(usage.sessionResetDate)
        // And the reading says so, so the measurement can refuse to difference against it.
        XCTAssertFalse(usage.sessionPercentWasRead)
        XCTAssertFalse(usage.weeklyPercentWasRead)
    }

    func testPercentageThatWasRead_isMarkedAsRead_onBothResponseShapes() throws {
        // The flag exists to separate a real 100 from a defaulted one, so it has to be true
        // wherever a percentage really arrived - in the newer limits[] shape as well as the legacy
        // per-field tiers - or the measurement would refuse readings it should be using.
        let legacy = UsageData(from: try decodeFixture("usage_full"))
        XCTAssertTrue(legacy.sessionPercentWasRead)
        XCTAssertTrue(legacy.weeklyPercentWasRead)

        let limits = UsageData(from: try decodeFixture("usage_limits_spend"))
        XCTAssertTrue(limits.sessionPercentWasRead)
        XCTAssertTrue(limits.weeklyPercentWasRead)
    }

    func testOnePercentageMissingWhileItsResetTimeIsPresent_isStillMarkedUnread() throws {
        // The shape that matters: a fabricated 100 carrying a genuine reset date would otherwise
        // look like any other reading to the accumulator, because the only check there is whether
        // both windows match.
        let json = """
        {
          "five_hour": { "resets_at": "2026-07-28T22:00:00Z" },
          "seven_day": { "utilization": 37.0, "resets_at": "2026-08-02T00:00:00Z" }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let usage = UsageData(from: try decoder.decode(UsageResponse.self, from: Data(json.utf8)))
        XCTAssertEqual(usage.sessionRemaining, 100, accuracy: 0.01)
        XCTAssertNotNil(usage.sessionResetDate)
        XCTAssertFalse(usage.sessionPercentWasRead)
        XCTAssertTrue(usage.weeklyPercentWasRead, "the other half of the response was read normally")
    }

    // MARK: - Clamping: utilization > 100

    func testUtilizationOver100_clampedToZeroRemaining() {
        let tier = makeTier(utilization: 150.0)
        let response = UsageResponse(
            fiveHour: tier,
            sevenDay: tier,
            sevenDayOpus: tier,
            sevenDaySonnet: tier,
            extraUsage: nil,
            limits: nil,
            spend: nil
        )
        let usage = UsageData(from: response)

        // max(0, min(100, 100 - 150)) = max(0, -50) = 0
        XCTAssertEqual(usage.weeklyRemaining, 0.0)
        XCTAssertEqual(usage.sessionRemaining, 0.0)
        XCTAssertEqual(usage.modelUsages.count, 2)
        XCTAssertTrue(usage.modelUsages.allSatisfy { $0.remainingPercent == 0.0 })
    }

    // MARK: - Clamping: utilization < 0

    func testNegativeUtilization_clampedTo100Remaining() {
        let tier = makeTier(utilization: -30.0)
        let response = UsageResponse(
            fiveHour: tier,
            sevenDay: tier,
            sevenDayOpus: tier,
            sevenDaySonnet: tier,
            extraUsage: nil,
            limits: nil,
            spend: nil
        )
        let usage = UsageData(from: response)

        // max(0, min(100, 100 - (-30))) = min(100, 130) = 100
        XCTAssertEqual(usage.weeklyRemaining, 100.0)
        XCTAssertEqual(usage.sessionRemaining, 100.0)
        XCTAssertEqual(usage.modelUsages.count, 2)
        XCTAssertTrue(usage.modelUsages.allSatisfy { $0.remainingPercent == 100.0 })
    }

    // MARK: - The plan ratio table

    func testPlanRatio_threeKnownTiers_haveTheirPublishedValues() {
        // The table itself, pinned so a typo in a constant is a failing test rather than a wrong
        // dial. The values are unvalidated (see PlanRatio's comment); pinning them is about
        // knowing WHICH number is in use, not about vouching for it.
        XCTAssertEqual(PlanRatio.forTier("default_claude_pro") ?? -1, 0.1100, accuracy: 0.00001)
        XCTAssertEqual(PlanRatio.forTier("default_claude_max_5x") ?? -1, 0.0792, accuracy: 0.00001)
        XCTAssertEqual(PlanRatio.forTier("default_claude_max_20x") ?? -1, 0.1320, accuracy: 0.00001)
    }

    func testPlanRatio_everythingElse_isNil() {
        // Free has no published capacities, so it gets no ratio (D2) - inventing one would be the
        // exact error this change fixes. auto_prepaid_tier_3 is an API billing tier, not a plan.
        // Unseen and differently-cased strings fall back rather than guess, which costs the
        // conversion instead of showing a wrong number.
        for tier in ["default_claude_free", "free", "auto_prepaid_tier_3", "",
                     "DEFAULT_CLAUDE_PRO", "default_claude_max_50x"] {
            XCTAssertNil(PlanRatio.forTier(tier), "\(tier) must not map to a ratio")
        }
        XCTAssertNil(PlanRatio.forTier(nil), "no stored tier must not map to a ratio")
    }

    // MARK: - Which of the two ratios the dial gets (R5, D3)

    func testResolve_measurementWinsWhenItAgreesWithTheTable() {
        // The ordinary case and the point of measuring: the account's own numbers replace the
        // unvalidated table. 0.10 against Max 5x's 0.0792 is a 26% correction, well inside the band.
        XCTAssertEqual(PlanRatio.resolve(measured: 0.10, tier: "default_claude_max_5x") ?? -1,
                       0.10, accuracy: 0.00001)
    }

    func testResolve_noMeasurement_fallsBackToTheTable() {
        XCTAssertEqual(PlanRatio.resolve(measured: nil, tier: "default_claude_pro") ?? -1,
                       PlanRatio.pro, accuracy: 0.00001)
        XCTAssertNil(PlanRatio.resolve(measured: nil, tier: "auto_prepaid_tier_3"),
                     "neither source has anything, so the dial stays unconverted (R3, D4)")
    }

    func testResolve_unrecognisedTier_takesTheMeasurementWhateverItSays() {
        // There is no table entry to disagree with, and refusing here would leave the dial
        // unconverted for exactly the accounts the measurement was built for.
        XCTAssertEqual(PlanRatio.resolve(measured: 0.40, tier: "auto_prepaid_tier_3") ?? -1,
                       0.40, accuracy: 0.00001)
        XCTAssertEqual(PlanRatio.resolve(measured: 0.40, tier: nil) ?? -1, 0.40, accuracy: 0.00001)
    }

    func testResolve_measurementThatContradictsAKnownTier_isRefused() {
        // Past its bar the measurement is good to a few percent, so a 2x disagreement is not
        // imprecision, it is a measurement of something else - and the table at least has a stated
        // origin. Both directions, and the edges of the band are still adopted.
        let table = PlanRatio.max5x
        XCTAssertEqual(PlanRatio.resolve(measured: table * 2.5, tier: "default_claude_max_5x") ?? -1,
                       table, accuracy: 0.00001, "far too high: the table stands")
        XCTAssertEqual(PlanRatio.resolve(measured: table / 2.5, tier: "default_claude_max_5x") ?? -1,
                       table, accuracy: 0.00001, "far too low: the table stands")
        XCTAssertEqual(PlanRatio.resolve(measured: table * 2, tier: "default_claude_max_5x") ?? -1,
                       table * 2, accuracy: 0.00001, "the band is inclusive")
        XCTAssertEqual(PlanRatio.resolve(measured: table / 2, tier: "default_claude_max_5x") ?? -1,
                       table / 2, accuracy: 0.00001)
    }

    func testAgreementBand_isWiderThanAnyCorrectionTheTableCouldNeed() {
        // The band has to stay out of the way of R5: every disagreement inside the material this
        // table came from has to fit in it, or a correct measurement would be thrown away for
        // disagreeing with a wrong constant. Widest disagreement in that material is the source's
        // prose against its own numbers, 12.63x against 9.09x, and the table's own span is Max 20x
        // over Max 5x.
        XCTAssertGreaterThan(PlanRatio.agreementFactor, 12.63 / 9.09)
        XCTAssertGreaterThan(PlanRatio.agreementFactor, PlanRatio.max20x / PlanRatio.max5x)
    }

    // MARK: - Session gauge: the weekly converted into session units before it caps anything

    /// Build a UsageData with session and weekly derived INDEPENDENTLY from the legacy tiers,
    /// so the conversion can be exercised across the (session, weekly) plane. `planRatio` nil
    /// models an account whose plan we cannot identify.
    private func makeUsage(session: Double, weekly: Double, planRatio: Double? = nil) -> UsageData {
        UsageData(from: UsageResponse(
            fiveHour: makeTier(utilization: 100 - session),
            sevenDay: makeTier(utilization: 100 - weekly),
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            extraUsage: nil,
            limits: nil,
            spend: nil
        ), planRatio: planRatio)
    }

    func testGauge_reportersNumbers_max5xSessionFullWeeklySix_reads76() {
        // The report this change exists for: a full 5h window with 6% of the week left read "6%"
        // on the Session dial, because the old code put a WEEKLY percentage on a dial measuring
        // SESSION percentage. 6% of a Max 5x week is 6 / 0.0792 = 75.8% of one session window.
        let usage = makeUsage(session: 100, weekly: 6, planRatio: PlanRatio.max5x)
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        XCTAssertEqual(usage.sessionDisplayRemaining, 75.76, accuracy: 0.01)
        // What the user actually reads: the popover prints with %.0f.
        XCTAssertEqual(String(format: "%.0f", usage.sessionDisplayRemaining), "76")
        // And the old answer is gone.
        XCTAssertNotEqual(usage.sessionDisplayRemaining, 6, accuracy: 1)
    }

    func testGauge_reportersNumbers_max20x_reads45() {
        // Same inputs, bigger plan: one session is a larger slice of a Max 20x week, so the same
        // 6% of the week fills less of a session. 6 / 0.132 = 45.5.
        let usage = makeUsage(session: 100, weekly: 6, planRatio: PlanRatio.max20x)
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        XCTAssertEqual(usage.sessionDisplayRemaining, 45.45, accuracy: 0.01)
        XCTAssertEqual(String(format: "%.0f", usage.sessionDisplayRemaining), "45")
    }

    func testGauge_reportersNumbers_pro_readsItsOwnConversion() {
        // Pro: 6 / 0.11 = 54.5. Locks that all three tiers run through the same conversion
        // rather than one being special-cased.
        let usage = makeUsage(session: 100, weekly: 6, planRatio: PlanRatio.pro)
        XCTAssertEqual(usage.sessionDisplayRemaining, 54.55, accuracy: 0.01)
    }

    func testGauge_unknownTier_showsTheTrueSessionValue() {
        // No ratio, no conversion: 100, not 6, and not a number derived from a guessed ratio.
        let usage = makeUsage(session: 100, weekly: 6, planRatio: PlanRatio.forTier("some_tier_we_have_not_seen"))
        XCTAssertNil(usage.planRatio)
        XCTAssertFalse(usage.isSessionWeeklyLimited)
        XCTAssertEqual(usage.sessionDisplayRemaining, 100, accuracy: 0.01)
    }

    func testGauge_freeAccount_showsTheTrueSessionValue() {
        // Free publishes no capacities at all (D2), so it lands on the same fallback.
        let usage = makeUsage(session: 100, weekly: 6, planRatio: PlanRatio.forTier("default_claude_free"))
        XCTAssertNil(usage.planRatio)
        XCTAssertEqual(usage.sessionDisplayRemaining, 100, accuracy: 0.01)
    }

    func testGauge_nonPositiveRatio_isTreatedAsUnknown() {
        // Defensive: a zero or negative ratio is not a ratio. Without this guard it would divide
        // into an infinity and put it on the dial. Matters once a MEASURED ratio can be supplied.
        XCTAssertEqual(makeUsage(session: 40, weekly: 6, planRatio: 0).sessionDisplayRemaining, 40, accuracy: 0.01)
        XCTAssertEqual(makeUsage(session: 40, weekly: 6, planRatio: -0.08).sessionDisplayRemaining, 40, accuracy: 0.01)
        XCTAssertFalse(makeUsage(session: 40, weekly: 6, planRatio: 0).isSessionWeeklyLimited)
    }

    func testGauge_sessionIsTighterLimit_showsSessionNotWeekly() {
        // Session 40, weekly 80: the week could fill ten sessions over, so the session is the
        // real binding limit. The gauge shows 40 and does NOT claim it is "weekly limited".
        let usage = makeUsage(session: 40, weekly: 80, planRatio: PlanRatio.max5x)
        XCTAssertFalse(usage.isSessionWeeklyLimited)
        XCTAssertEqual(usage.sessionDisplayRemaining, 40, accuracy: 0.01)
    }

    func testGauge_conversionAbove100_clampsRatherThanOverfilling() {
        // 20% of a Max 5x week converts to 252% of a session. The dial is a percentage of one
        // session, so that clamps at 100 instead of drawing an arc two and a half times round.
        let usage = makeUsage(session: 100, weekly: 20, planRatio: PlanRatio.max5x)
        XCTAssertEqual(usage.weeklyRemainingInSessionUnits ?? -1, 100, accuracy: 0.01)
        XCTAssertEqual(usage.sessionDisplayRemaining, 100, accuracy: 0.01)
        XCTAssertFalse(usage.isSessionWeeklyLimited)
    }

    func testGauge_weeklyExhausted_gaugeReadsZero() {
        // Nothing left in the week converts to nothing left of a session, on any ratio.
        let usage = makeUsage(session: 80, weekly: 0, planRatio: PlanRatio.max5x)
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        XCTAssertEqual(usage.sessionDisplayRemaining, 0, accuracy: 0.01)
    }

    func testGauge_weeklyExhausted_readsZeroWithNoRatioEither() {
        // "On any ratio" includes having none. Zero is the one weekly value that needs no plan to
        // convert, so it is answered rather than deferred to R3/D4's fallback. Without this the
        // dial read a full 100, in green, captioned "On Track", beside a Weekly card at 0% - the
        // state EVERY account carried over from v1.60 is in, since `AccountStore.updatePlan` runs
        // only on the sign-in and re-auth routes and a blocked user can never spend enough for the
        // measurement to reach its bar.
        let usage = makeUsage(session: 100, weekly: 0)
        XCTAssertNil(usage.planRatio, "precondition: nothing is known about this account's plan")
        XCTAssertEqual(usage.weeklyRemainingInSessionUnits ?? -1, 0, accuracy: 0.01)
        // The flag the popover reads for the "Limited by weekly" caption and to suppress the
        // session time arc; see RunOutForecastTests for the caption itself.
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        // The dial, and every menu-bar renderer, which all read this same value.
        XCTAssertEqual(usage.sessionDisplayRemaining, 0, accuracy: 0.01)
        XCTAssertEqual(usage.sessionRemaining, 100, accuracy: 0.01, "and the raw session survives")
    }

    func testGauge_weeklyAndSessionBothEmpty_isNotClaimedAsWeeklyLimited() {
        // The edge of the zero case, with or without a ratio: an empty week is not TIGHTER than an
        // already-empty session, so nothing defers to the weekly and the Session card keeps grading
        // its own emptiness (Danger) instead of saying "Limited by weekly". The number is 0 either
        // way, so this is about which caption shows, not about the dial.
        for ratio: Double? in [nil, PlanRatio.max5x] {
            let usage = makeUsage(session: 0, weekly: 0, planRatio: ratio)
            XCTAssertFalse(usage.isSessionWeeklyLimited,
                           "at ratio \(String(describing: ratio))")
            XCTAssertEqual(usage.sessionDisplayRemaining, 0, accuracy: 0.01)
        }
    }

    func testGauge_healthyWeek_doesNotDownRateSession() {
        // Regression lock: an unconditional min(session, weekly) would collapse this dial to 63.
        // Converted, 63% of the week is far more than one session, so the gauge stays at 94.
        let usage = makeUsage(session: 94, weekly: 63, planRatio: PlanRatio.max5x)
        XCTAssertFalse(usage.isSessionWeeklyLimited)
        XCTAssertEqual(usage.sessionDisplayRemaining, 94, accuracy: 0.01)
    }

    func testGauge_rawSessionSurvivesEveryConversion() {
        // The #31 run-out forecast and the Session pace read sessionRemaining and must keep
        // seeing the TRUE 5h value. The conversion is display-only; if it ever gets folded back
        // into the field, both of those start grading a weekly number on a session clock.
        for ratio: Double? in [nil, PlanRatio.pro, PlanRatio.max5x, PlanRatio.max20x, 0] {
            let usage = makeUsage(session: 94, weekly: 2, planRatio: ratio)
            XCTAssertEqual(usage.sessionRemaining, 94, accuracy: 0.01,
                           "raw session must survive ratio \(String(describing: ratio))")
            XCTAssertEqual(usage.weeklyRemaining, 2, accuracy: 0.01,
                           "raw weekly must survive ratio \(String(describing: ratio))")
        }
        // And the displayed value really did move, so the loop above is not passing on a no-op.
        XCTAssertEqual(makeUsage(session: 94, weekly: 2, planRatio: PlanRatio.max5x).sessionDisplayRemaining,
                       25.25, accuracy: 0.01)
    }

    func testGauge_oldTwentyPointFloor_noLongerChangesAnything() {
        // The deleted `weeklyGateFloor` made 20% weekly-remaining a cliff: at 19.99 the dial
        // dropped to 19.99, at 20.00 it jumped back to the full session value. Nothing special
        // happens there now, with a ratio or without one - which is the whole point of removing
        // it, since the floor only existed to contain a comparison that had no meaning.
        for ratio: Double? in [nil, PlanRatio.max5x, PlanRatio.max20x] {
            let below = makeUsage(session: 90, weekly: 19.99, planRatio: ratio)
            let at = makeUsage(session: 90, weekly: 20, planRatio: ratio)
            XCTAssertEqual(below.sessionDisplayRemaining, at.sessionDisplayRemaining, accuracy: 0.01,
                           "the old floor is still a cliff at ratio \(String(describing: ratio))")
            XCTAssertEqual(below.sessionDisplayRemaining, 90, accuracy: 0.01)
            XCTAssertFalse(below.isSessionWeeklyLimited)
        }
    }

    func testGauge_conversionIsMonotonicInTheWeekly() {
        // No threshold left anywhere: as the week drains the displayed session falls smoothly and
        // never jumps. A reintroduced gate of any size shows up here as a step.
        var previous = 0.0
        for weeklyTenths in 0...1000 {
            let usage = makeUsage(session: 100, weekly: Double(weeklyTenths) / 10, planRatio: PlanRatio.max5x)
            let shown = usage.sessionDisplayRemaining
            XCTAssertGreaterThanOrEqual(shown, previous - 0.0001,
                                        "displayed session fell as the weekly rose, at weekly \(Double(weeklyTenths) / 10)")
            XCTAssertLessThanOrEqual(shown - previous, 1.5,
                                     "displayed session stepped at weekly \(Double(weeklyTenths) / 10)")
            previous = shown
        }
    }

    func testGauge_realFixture_notGated_leavesSessionRaw() throws {
        // usage_limits_spend: session 94, weekly 63 -> healthy, gauge unchanged at 94, with and
        // without a ratio.
        let noRatio = UsageData(from: try decodeFixture("usage_limits_spend"))
        XCTAssertFalse(noRatio.isSessionWeeklyLimited)
        XCTAssertEqual(noRatio.sessionDisplayRemaining, noRatio.sessionRemaining, accuracy: 0.01)
        XCTAssertEqual(noRatio.sessionDisplayRemaining, 94, accuracy: 0.01)

        let withRatio = UsageData(from: try decodeFixture("usage_limits_spend"), planRatio: PlanRatio.max5x)
        XCTAssertFalse(withRatio.isSessionWeeklyLimited)
        XCTAssertEqual(withRatio.sessionDisplayRemaining, 94, accuracy: 0.01)
    }

    // MARK: - Helpers

    /// Build a UsageTier by round-tripping through JSON so Codable init is used.
    private func makeTier(utilization: Double, resetsAt: Date? = nil) -> UsageTier {
        var json: [String: Any] = ["utilization": utilization]
        if let date = resetsAt {
            let formatter = ISO8601DateFormatter()
            json["resets_at"] = formatter.string(from: date)
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(UsageTier.self, from: data)
    }

    /// Decode a UsageTier with a raw `resets_at` JSON value (number, string, or null)
    /// through the production decoder config, to lock the tolerant date parsing (#23).
    private func decodeTier(resetsAtRawJSON: String) -> UsageTier {
        let json = "{\"utilization\": 35, \"resets_at\": \(resetsAtRawJSON)}"
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(UsageTier.self, from: Data(json.utf8))
    }

    // MARK: - resets_at tolerant decoding (issue #23: blank Session/Weekly resets)

    func testResetsAt_epochSeconds_decodes() {
        // The live API returns resets_at as a UNIX epoch for some accounts; .iso8601
        // can never parse a JSON number, so the old try? nil-ed it and the card went blank.
        let tier = decodeTier(resetsAtRawJSON: "1775714400")
        XCTAssertEqual(tier.resetsAt?.timeIntervalSince1970 ?? 0, 1775714400, accuracy: 0.5)
    }

    func testResetsAt_epochMilliseconds_decodes() {
        let tier = decodeTier(resetsAtRawJSON: "1775714400000")
        XCTAssertEqual(tier.resetsAt?.timeIntervalSince1970 ?? 0, 1775714400, accuracy: 0.5)
    }

    func testResetsAt_epochString_decodes() {
        let tier = decodeTier(resetsAtRawJSON: "\"1775714400\"")
        XCTAssertEqual(tier.resetsAt?.timeIntervalSince1970 ?? 0, 1775714400, accuracy: 0.5)
    }

    func testResetsAt_iso8601Fractional_decodes() {
        let tier = decodeTier(resetsAtRawJSON: "\"2026-04-10T14:00:00.000Z\"")
        XCTAssertNotNil(tier.resetsAt)
    }

    func testResetsAt_iso8601BareZ_stillDecodes() {
        // Regression guard: the format that already worked must keep working.
        let tier = decodeTier(resetsAtRawJSON: "\"2026-04-10T14:00:00Z\"")
        XCTAssertNotNil(tier.resetsAt)
    }

    func testResetsAt_presentButUnparseable_isNil() {
        let tier = decodeTier(resetsAtRawJSON: "\"not-a-date\"")
        XCTAssertNil(tier.resetsAt)
        XCTAssertEqual(tier.utilization ?? -1, 35, accuracy: 0.01)
    }

    func testResetsAt_null_decodesNilButKeepsUtilization() {
        let tier = decodeTier(resetsAtRawJSON: "null")
        XCTAssertNil(tier.resetsAt)
        XCTAssertEqual(tier.utilization ?? -1, 35, accuracy: 0.01)
    }

    func testResetsAt_absent_decodesNilButKeepsUtilization() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let tier = try! decoder.decode(UsageTier.self, from: Data("{\"utilization\": 35}".utf8))
        XCTAssertNil(tier.resetsAt)
        XCTAssertEqual(tier.utilization ?? -1, 35, accuracy: 0.01)
    }

    func testResetsAt_nonFiniteAndHuge_isNilNoCrash() {
        // Regression guard: Double("inf")/"1e400" and a huge finite number used to flow into
        // Date(timeIntervalSince1970:) and trap Int(remaining) in formatCountdown (#23 follow-up).
        for raw in ["\"inf\"", "\"-inf\"", "\"nan\"", "\"1e400\"", "1e308", "9.9e21"] {
            XCTAssertNil(decodeTier(resetsAtRawJSON: raw).resetsAt,
                         "resets_at \(raw) must decode to nil, never a trapping Date")
        }
    }

    func testResetsAt_absurdEpoch_outOfRangeIsNil() {
        // Values mapping outside ~2001-2100 are not real reset times.
        XCTAssertNil(decodeTier(resetsAtRawJSON: "99999999999").resetsAt)  // ~year 5138 as seconds
        XCTAssertNil(decodeTier(resetsAtRawJSON: "0").resetsAt)            // 1970
        XCTAssertNil(decodeTier(resetsAtRawJSON: "-1775714400").resetsAt)  // pre-1970
    }

    func testResetsAt_wrongJSONType_isNilKeepsUtilization() {
        for raw in ["true", "[]", "{}"] {
            let tier = decodeTier(resetsAtRawJSON: raw)
            XCTAssertNil(tier.resetsAt, "resets_at \(raw) must be nil")
            XCTAssertEqual(tier.utilization ?? -1, 35, accuracy: 0.01, "utilization must still decode for \(raw)")
        }
    }

    func testResetsAt_emptyString_isNil() {
        XCTAssertNil(decodeTier(resetsAtRawJSON: "\"\"").resetsAt)
    }

    func testResetsAt_iso8601FractionalAndBareZ_sameExactInstant() {
        // Strong assertion: both ISO forms resolve to the exact same instant (no silent
        // formatter fallback to a wrong epoch).
        let reference = ISO8601DateFormatter().date(from: "2026-04-10T14:00:00Z")!
        let frac = decodeTier(resetsAtRawJSON: "\"2026-04-10T14:00:00.000Z\"").resetsAt
        let bare = decodeTier(resetsAtRawJSON: "\"2026-04-10T14:00:00Z\"").resetsAt
        XCTAssertEqual(frac?.timeIntervalSince1970 ?? -1, reference.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(bare?.timeIntervalSince1970 ?? -2, reference.timeIntervalSince1970, accuracy: 0.001)
    }
}

// MARK: - UsageService.pollUsage() Tests

final class UsageServicePollTests: XCTestCase {

    private var suiteName: String!
    private var mockSession: MockHTTPSession!
    private var storage: StorageService!
    private var accountStore: AccountStore!

    /// Shared test account.
    private let testAccount = Account(
        email: "test@example.com",
        sessionKey: "sk-ant-test-key",
        organizationId: "org-test-123"
    )

    @MainActor
    override func setUp() {
        super.setUp()
        mockSession = MockHTTPSession()

        // Isolated UserDefaults per test to avoid cross-contamination
        suiteName = "com.claudebattery.tests.usage.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        storage = StorageService(defaults: defaults, prefix: "test_")
        accountStore = AccountStore(storage: storage)

        // Seed an active account so pollUsage has something to work with
        _ = accountStore.addAccount(testAccount)
    }

    @MainActor
    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        mockSession = nil
        storage = nil
        accountStore = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Happy path: 200 with full JSON

    @MainActor
    func testPoll200_populatesLatestUsage() async {
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        let usage = try! XCTUnwrap(service.latestUsage)
        XCTAssertEqual(usage.weeklyRemaining, 40.0, accuracy: 0.01)
        XCTAssertEqual(usage.sessionRemaining, 65.0, accuracy: 0.01)
        XCTAssertEqual(service.consecutiveFailures, 0)
        XCTAssertFalse(service.authFailed)
        XCTAssertNotNil(service.lastSuccessfulFetch)
    }

    @MainActor
    func testPoll200_capturesRequestHeaders() async {
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        let request = mockSession.lastRequest
        XCTAssertNotNil(request)
        XCTAssertTrue(request!.url!.absoluteString.contains("org-test-123"))

        // Cookie is managed via ClaudeAPI's per-session jar (primed in setUp via
        // accountStore.addAccount -> ClaudeAPI.activateCookies). URLSession constructs
        // the Cookie header on dispatch, so URLRequest.Cookie is nil here by design.
        XCTAssertNil(request!.value(forHTTPHeaderField: "Cookie"))

        let cookies = ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: request!.url!) ?? []
        let sessionCookie = cookies.first { $0.name == "sessionKey" }
        XCTAssertNotNil(sessionCookie, "Cookie jar should have been primed with sessionKey on account activation")
        XCTAssertEqual(sessionCookie?.value, "sk-ant-test-key")
    }

    // MARK: - 401 auth failure

    @MainActor
    func testPoll401_setsAuthFailed() async {
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 401

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        var authCallbackFired = false
        service.onAuthFailure = { authCallbackFired = true }

        await service.pollUsage()

        XCTAssertTrue(service.authFailed)
        XCTAssertEqual(service.consecutiveFailures, 1)
        XCTAssertTrue(authCallbackFired)
        XCTAssertNil(service.latestUsage)
    }

    // MARK: - 403 auth failure (same behavior as 401)

    @MainActor
    func testPoll403_setsAuthFailed() async {
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 403

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        var authCallbackFired = false
        service.onAuthFailure = { authCallbackFired = true }

        await service.pollUsage()

        XCTAssertTrue(service.authFailed)
        XCTAssertEqual(service.consecutiveFailures, 1)
        XCTAssertTrue(authCallbackFired)
    }

    // MARK: - 500 server error

    @MainActor
    func testPoll500_incrementsConsecutiveFailures() async {
        mockSession.responseData = Data("{\"error\":\"internal\"}".utf8)
        mockSession.responseStatusCode = 500

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        XCTAssertEqual(service.consecutiveFailures, 1)
        XCTAssertFalse(service.authFailed)
        XCTAssertNil(service.latestUsage)
    }

    @MainActor
    func testPollMultiple500s_incrementsEachTime() async {
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 500

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        // pollUsage guards against concurrent calls via isPolling;
        // await ensures each call completes before the next starts.
        await service.pollUsage()
        await service.pollUsage()
        await service.pollUsage()

        XCTAssertEqual(service.consecutiveFailures, 3)
    }

    // MARK: - 200 after failures resets counter

    @MainActor
    func testPoll200AfterFailures_resetsConsecutiveFailures() async {
        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        // Cause some failures first
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 500
        await service.pollUsage()
        await service.pollUsage()
        XCTAssertEqual(service.consecutiveFailures, 2)

        // Now succeed
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200
        await service.pollUsage()

        XCTAssertEqual(service.consecutiveFailures, 0)
        XCTAssertNotNil(service.latestUsage)
    }

    // MARK: - No active account -> poll is a no-op

    @MainActor
    func testPollWithNoAccount_doesNothing() async {
        // Remove the seeded account
        accountStore.removeAccount(testAccount.id)
        XCTAssertNil(accountStore.activeAccount)

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        XCTAssertTrue(mockSession.capturedRequests.isEmpty)
        XCTAssertEqual(service.consecutiveFailures, 0)
    }

    // MARK: - Network error increments failures

    @MainActor
    func testPollNetworkError_incrementsFailures() async {
        mockSession.responseError = URLError(.notConnectedToInternet)

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        XCTAssertEqual(service.consecutiveFailures, 1)
        XCTAssertNil(service.latestUsage)
    }

    // MARK: - Prepaid credits integration

    @MainActor
    func testPoll200WithCredits401_creditsBalanceIsNil() async {
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200
        mockSession.urlOverrides["prepaid/credits"] = (
            data: Data(),
            statusCode: 401
        )

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        XCTAssertNotNil(service.latestUsage)
        XCTAssertNil(service.latestUsage?.usageCredits?.balance,
                     "Credits balance should be nil when credits endpoint returns 401")
        XCTAssertEqual(service.consecutiveFailures, 0,
                       "Credits 401 should not affect consecutiveFailures")
    }

    @MainActor
    func testPoll200WithPrepaidCredits_decodesBalance() async {
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200
        mockSession.urlOverrides["prepaid/credits"] = (
            data: """
            {"amount": 20000, "currency": "AUD"}
            """.data(using: .utf8)!,
            statusCode: 200
        )

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        // Currency + amount flow through the poll into the unified credits balance (KTD4/KTD6).
        XCTAssertEqual(service.latestUsage?.usageCredits?.balance?.currency, "AUD")
        XCTAssertEqual(service.latestUsage?.usageCredits?.balance?.major ?? .nan, 200.0, accuracy: 0.01)  // 20000 cents -> 200
    }

    @MainActor
    func testPoll200WithMalformedCredits_prepaidBalanceIsNil() async {
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200
        mockSession.urlOverrides["prepaid/credits"] = (
            data: "not json".data(using: .utf8)!,
            statusCode: 200
        )

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        XCTAssertNotNil(service.latestUsage)
        XCTAssertNil(service.latestUsage?.usageCredits?.balance,
                     "Credits balance should be nil when credits response is malformed")
    }

    // MARK: - Auth failure clears latestUsage

    @MainActor
    func testPoll401_clearsLatestUsage() async {
        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        // First, get some usage data
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200
        await service.pollUsage()
        XCTAssertNotNil(service.latestUsage, "Should have usage data after successful poll")

        // Now simulate auth failure
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 401
        await service.pollUsage()

        XCTAssertTrue(service.authFailed)
        XCTAssertNil(service.latestUsage,
                     "latestUsage should be cleared on auth failure so popover shows re-auth screen")
    }

    // MARK: - switchAccount resets authFailed

    @MainActor
    func testSwitchAccount_resetsAuthFailedAndConsecutiveFailures() async {
        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        // Simulate auth failure state
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 401
        await service.pollUsage()
        XCTAssertTrue(service.authFailed)
        XCTAssertEqual(service.consecutiveFailures, 1)

        // switchAccount should reset everything
        service.switchAccount()

        XCTAssertFalse(service.authFailed, "switchAccount should clear authFailed")
        XCTAssertEqual(service.consecutiveFailures, 0, "switchAccount should reset consecutiveFailures")
        XCTAssertNil(service.latestUsage, "switchAccount should clear latestUsage")
    }

    // MARK: - Issue #41 (R11): the polling pause across a sign-in's network window

    @MainActor
    func testSuspendPolling_inFlightPollIsNotAnsweredWithMidFlightCredentials() async {
        // What R11 is actually for. A usage request picks up its cookies from the shared jar when
        // it goes OUT, so a sign-in that re-primes that jar mid-flight can have this poll answered
        // with the pasted account's credentials - a 403 that marks a healthy account expired and
        // stops polling, on the one route that fires no success callback to start it again.
        // GatedSession parks the request in flight so the sign-in's suspend lands in the middle of
        // it, deterministically, instead of hoping two tasks interleave.
        let gate = GatedSession(data: Data(), statusCode: 403)
        let service = UsageService(storage: storage, accountStore: accountStore, session: gate)
        var authFailures = 0
        service.onAuthFailure = { authFailures += 1 }

        service.startPolling()
        let inFlight = await waitUntil { gate.started }
        XCTAssertTrue(inFlight, "the poll must be in flight before the sign-in begins")

        service.suspendPolling()
        gate.release()
        let answered = await waitUntil { gate.delivered }
        XCTAssertTrue(answered, "the response really was handed back")

        // Fails fast the moment the cancelled poll wrongly applies that response.
        let leaked = await waitUntil(timeout: 0.5) { service.authFailed || authFailures > 0 }
        XCTAssertFalse(leaked, "a poll cancelled by the sign-in must not read the response as its own account's")
        XCTAssertEqual(service.consecutiveFailures, 0, "and it must not count as a failure either")
    }

    @MainActor
    func testInFlightPoll_withoutTheSuspend_doesApplyTheResponse() async {
        // The control for the test above. Same harness, no suspend: if this did not trip the flag,
        // "nothing happened" over there would only mean the harness never delivered anything.
        let gate = GatedSession(data: Data(), statusCode: 403)
        let service = UsageService(storage: storage, accountStore: accountStore, session: gate)
        var authFailures = 0
        service.onAuthFailure = { authFailures += 1 }

        service.startPolling()
        let inFlight = await waitUntil { gate.started }
        XCTAssertTrue(inFlight)
        gate.release()

        let tripped = await waitUntil { service.authFailed }
        XCTAssertTrue(tripped, "an uncancelled poll does read the 403")
        XCTAssertEqual(authFailures, 1)
    }

    @MainActor
    func testSuspendThenResume_putsBackPollingThatWasRunning() async {
        // Every exit of a sign-in resumes, the failed ones included, so this is the ordinary case:
        // polling was running, a paste failed, and polling has to come back on its own.
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200
        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)

        service.startPolling()
        let polled = await waitUntil { usageRequestCount() >= 1 }
        XCTAssertTrue(polled, "the first poll ran")
        let before = usageRequestCount()

        service.suspendPolling()
        service.resumePolling()

        let polledAgain = await waitUntil { usageRequestCount() > before }
        XCTAssertTrue(polledAgain,
                      "resume puts back the poll the suspend cancelled, rather than leaving polling dead")
    }

    @MainActor
    func testSuspendThenResume_withAPollStillInFlight_stillPollsAgain() async {
        // Pins suspendPolling's "cancel but KEEP the handle" decision, which nothing could fail on
        // before: the resume test above waits for the first poll to FINISH, so there is no previous
        // task for restartPolling to chain behind and dropping the handle changes nothing there.
        // Here the first request is still parked when the sign-in suspends, which is the ordinary
        // case on the real path - the pause is taken with a poll on the wire.
        //
        // With the handle dropped, restartPolling has nothing to wait for, so the resumed poll runs
        // while the cancelled one is still inside the request with `isPolling` true and is thrown
        // away by the guard at the top of pollUsage. The user then waits a full interval for data
        // the resume was supposed to fetch immediately.
        let gate = GatedSession(data: Data(), statusCode: 403)
        let service = UsageService(storage: storage, accountStore: accountStore, session: gate)

        service.startPolling()
        let inFlight = await waitUntil { gate.started }
        XCTAssertTrue(inFlight, "the poll must be in flight before the sign-in begins")

        service.suspendPolling()
        service.resumePolling()
        gate.release()

        let polledAgain = await waitUntil { gate.usageRequests >= 2 }
        XCTAssertTrue(polledAgain,
                      "the resumed poll waits for the cancelled one to finish instead of being dropped by the isPolling guard")
    }

    @MainActor
    func testResume_doesNotStartPollingThatWasNotRunning() async {
        // The app stops polling when the active session goes authFailed. A sign-in that failed must
        // not turn that deliberate stop into a running poll against credentials still known bad.
        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200

        service.suspendPolling()
        service.resumePolling()

        let started = await waitUntil(timeout: 0.3) { usageRequestCount() > 0 }
        XCTAssertFalse(started, "nothing was running when the sign-in began, so there is nothing to put back")
    }

    @MainActor
    func testResumeAfterRepairOfTheActiveAccount_pollsAgain() async {
        // The other half of R11: the pause must not be a one-way door. The active session goes
        // authFailed, the app stops polling (its onAuthFailure wiring), the paste repairs that
        // account, and the success callback -> switchAccount is what starts polling again.
        //
        // What the resume at the end proves here is that it does not undo that restart. It cannot
        // prove HOW: polling was already stopped when the suspend was taken, so `resumeShouldRestart`
        // is false and the resume returns at its own guard, with or without the reset lines in
        // `restartPolling` (review finding - this comment used to claim it covered those lines).
        // Those lines save a redundant cancel-and-rechain that nothing observable comes of, so no
        // test can pin them; what is worth pinning is this route reaching data at all, since it is
        // the one the user is standing in front of after a repair.
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 401
        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)

        service.startPolling()
        let expired = await waitUntil { service.authFailed }
        XCTAssertTrue(expired, "precondition: the session is expired")
        service.stopPolling()  // exactly what ClaudeBatteryApp wires onAuthFailure to

        // The sign-in that repairs this account.
        service.suspendPolling()
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200
        service.switchAccount()  // what AuthManager.onAuthSuccess is wired to
        service.resumePolling()

        let fetched = await waitUntil { service.latestUsage != nil }
        XCTAssertTrue(fetched,
                      "a repaired active account fetches again without the user switching accounts by hand")
        XCTAssertFalse(service.authFailed)
    }

    // MARK: - The active account's plan reaching the dial (R1, R3)

    @MainActor
    func testPoll_knownTierOnTheActiveAccount_convertsTheDisplayedSession() async {
        // What this unit is for: the stored plan has to travel from the account into the UsageData
        // every surface reads, or the conversion has no way to run on real data. These are the
        // reporter's numbers, so this is the bug end to end rather than in the abstract.
        accountStore.updatePlan(testAccount.id,
                                rateLimitTier: "default_claude_max_5x",
                                capabilities: ["claude_max", "chat"])
        mockSession.responseData = reporterUsageResponse()
        mockSession.responseStatusCode = 200

        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)

        await service.pollUsage()

        let usage = try! XCTUnwrap(service.latestUsage)
        XCTAssertEqual(usage.planRatio ?? -1, PlanRatio.max5x, accuracy: 0.0001)
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        XCTAssertEqual(String(format: "%.0f", usage.sessionDisplayRemaining), "76",
                       "6% of a Max 5x week must reach the dial as 76% of a session, not as 6%")
        // The raw fields stay raw: the Session pace and the #31 run-out forecast read these and
        // must keep grading the true 5h window.
        XCTAssertEqual(usage.sessionRemaining, 100, accuracy: 0.01)
        XCTAssertEqual(usage.weeklyRemaining, 6, accuracy: 0.01)
    }

    @MainActor
    func testPoll_accountWithNoStoredTier_showsTheTrueSessionValue() async {
        // An account added before this release carries no tier at all, so nothing is known about
        // its capacities and no conversion happens: 100, not 6, and not a computed guess (R3, AE7).
        mockSession.responseData = reporterUsageResponse()
        mockSession.responseStatusCode = 200

        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)

        await service.pollUsage()

        let usage = try! XCTUnwrap(service.latestUsage)
        XCTAssertNil(usage.planRatio)
        XCTAssertFalse(usage.isSessionWeeklyLimited)
        XCTAssertEqual(usage.sessionDisplayRemaining, 100, accuracy: 0.01)
    }

    @MainActor
    func testPoll_exhaustedWeekOnAnAccountWithNoStoredTier_readsZero() async {
        // The upgraded-account state end to end, and the one case the fallback above must NOT
        // catch. Same account with no tier, but the week is spent rather than merely low: zero
        // converts to zero on every plan, so the dial reads empty without knowing the plan. This
        // account cannot rescue itself with a measurement either - it is blocked, so it cannot
        // spend, so neither accumulated total grows toward the bar.
        mockSession.responseData = usageResponse(session: 100, weekly: 0)
        mockSession.responseStatusCode = 200

        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)

        await service.pollUsage()

        let usage = try! XCTUnwrap(service.latestUsage)
        XCTAssertNil(usage.planRatio, "precondition: no stored tier and no measurement")
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        XCTAssertEqual(String(format: "%.0f", usage.sessionDisplayRemaining), "0",
                       "v1.60 read 0 here; an unconverted fallback reads a full 100")
        XCTAssertEqual(usage.sessionRemaining, 100, accuracy: 0.01)
    }

    @MainActor
    func testPoll_storedTierWeDoNotRecognise_showsTheTrueSessionValue() async {
        // The other half of the fallback, and the one a missing-tier test cannot reach: a tier IS
        // stored, it travels through the call site, and it still maps to nothing. auto_prepaid_tier_3
        // is a real observed string - an API billing tier rather than a plan.
        accountStore.updatePlan(testAccount.id, rateLimitTier: "auto_prepaid_tier_3", capabilities: ["api"])
        mockSession.responseData = reporterUsageResponse()
        mockSession.responseStatusCode = 200

        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)

        await service.pollUsage()

        let usage = try! XCTUnwrap(service.latestUsage)
        XCTAssertNil(usage.planRatio)
        XCTAssertEqual(usage.sessionDisplayRemaining, 100, accuracy: 0.01)
    }

    @MainActor
    func testPoll_switchingAccounts_switchesTheRatioWithThem() async {
        // The ratio belongs to the account, not to the service, so a multi-account user must not
        // see one account's plan applied to another's usage.
        accountStore.updatePlan(testAccount.id, rateLimitTier: "default_claude_max_20x", capabilities: ["claude_max"])
        let other = Account(email: "other@example.com",
                            sessionKey: "sk-ant-other-key",
                            organizationId: "org-other-456",
                            rateLimitTier: "default_claude_max_5x")
        XCTAssertTrue(accountStore.addAccount(other))
        mockSession.responseData = reporterUsageResponse()
        mockSession.responseStatusCode = 200

        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)

        await service.pollUsage()
        let onMax20x = try! XCTUnwrap(service.latestUsage)
        XCTAssertEqual(String(format: "%.0f", onMax20x.sessionDisplayRemaining), "45")

        accountStore.switchTo(other.id)
        await service.pollUsage()

        let onMax5x = try! XCTUnwrap(service.latestUsage)
        XCTAssertEqual(String(format: "%.0f", onMax5x.sessionDisplayRemaining), "76",
                       "the ratio must follow the active account rather than stay on whichever polled first")
    }

    @MainActor
    func testPoll_planChangedSinceTheLastPoll_isPickedUpOnTheNextOne() async {
        // The ratio is read from the account on every poll instead of captured once at start-up,
        // so a plan change written by a re-auth (`AccountStore.updatePlan`) takes effect within one
        // poll with no cache to invalidate.
        accountStore.updatePlan(testAccount.id, rateLimitTier: "default_claude_max_5x", capabilities: nil)
        mockSession.responseData = reporterUsageResponse()
        mockSession.responseStatusCode = 200

        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)

        await service.pollUsage()
        XCTAssertEqual(String(format: "%.0f", try! XCTUnwrap(service.latestUsage).sessionDisplayRemaining), "76")

        accountStore.updatePlan(testAccount.id, rateLimitTier: "default_claude_max_20x", capabilities: nil)
        await service.pollUsage()

        XCTAssertEqual(String(format: "%.0f", try! XCTUnwrap(service.latestUsage).sessionDisplayRemaining), "45",
                       "an upgraded plan must re-rate the dial rather than keep converting on the old capacities")
    }

    // MARK: - The measured ratio reaching the dial (R5, D3)

    @MainActor
    func testPoll_recordsTheSampleEvenWhenNothingCanBeAccumulatedYet() async {
        // The first poll on any account can only seed: there is nothing to difference against.
        mockSession.responseData = usageResponse(session: 100, weekly: 63)
        mockSession.responseStatusCode = 200

        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)
        await service.pollUsage()

        let measurement = try! XCTUnwrap(accountStore.activeAccount?.ratioMeasurement)
        XCTAssertEqual(measurement.lastSessionRemaining, 100, accuracy: 0.01)
        XCTAssertEqual(measurement.lastWeeklyRemaining, 63, accuracy: 0.01)
        XCTAssertEqual(measurement.sessionPointsConsumed, 0)
        XCTAssertNil(measurement.ratio)
        XCTAssertEqual(storage.readAccounts().first?.ratioMeasurement, measurement,
                       "written through to storage, not only to the in-memory copy")
    }

    @MainActor
    func testPoll_twoCleanPolls_accumulateIntoTheStoredMeasurement() async {
        mockSession.responseData = usageResponse(session: 100, weekly: 63)
        mockSession.responseStatusCode = 200
        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)
        await service.pollUsage()

        mockSession.responseData = usageResponse(session: 92, weekly: 62)
        await service.pollUsage()

        let measurement = try! XCTUnwrap(accountStore.activeAccount?.ratioMeasurement)
        XCTAssertEqual(measurement.sessionPointsConsumed, 8, accuracy: 0.01)
        XCTAssertEqual(measurement.weeklyPointsConsumed, 1, accuracy: 0.01)
    }

    @MainActor
    func testPoll_sessionWindowRolledBetweenPolls_accumulatesNothing() async {
        mockSession.responseData = usageResponse(session: 20, weekly: 63)
        mockSession.responseStatusCode = 200
        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)
        await service.pollUsage()

        // A new 5-hour window: full again, and resets_at five hours later.
        mockSession.responseData = usageResponse(session: 100, weekly: 63,
                                                 sessionResets: "2026-07-29T03:00:00Z")
        await service.pollUsage()

        let measurement = try! XCTUnwrap(accountStore.activeAccount?.ratioMeasurement)
        XCTAssertEqual(measurement.sessionPointsConsumed, 0,
                       "a window reset is not 80 points of usage running backwards")
        XCTAssertEqual(measurement.lastSessionRemaining, 100, accuracy: 0.01,
                       "and the sample moved to the new window")
    }

    @MainActor
    func testPoll_measurementBelowTheBar_dialStillUsesTheTableRatio() async {
        // AE9. Two polls is eight session points and no weekly movement at all, nowhere near the
        // bar, so the published table is what converts the dial and the reporter's 76 is what shows.
        accountStore.updatePlan(testAccount.id, rateLimitTier: "default_claude_max_5x", capabilities: nil)
        mockSession.responseData = usageResponse(session: 100, weekly: 6)
        mockSession.responseStatusCode = 200
        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)
        await service.pollUsage()
        mockSession.responseData = usageResponse(session: 92, weekly: 6)
        await service.pollUsage()

        let usage = try! XCTUnwrap(service.latestUsage)
        XCTAssertNil(accountStore.activeAccount?.ratioMeasurement?.ratio)
        XCTAssertEqual(usage.planRatio ?? -1, PlanRatio.max5x, accuracy: 0.0001)
    }

    @MainActor
    func testPoll_measurementAboveTheBar_overridesTheTableOnTheDial() async {
        // AE8, and the point of the whole unit: the account's own numbers beat a third party's
        // table (D3). Seeded with reset times from 1970 so this poll's reading cannot accumulate
        // into it and the ratio under test stays exactly what the test stated.
        accountStore.updatePlan(testAccount.id, rateLimitTier: "default_claude_max_5x", capabilities: nil)
        accountStore.updateRatioMeasurement(testAccount.id, measurementFromAnotherWindow(session: 400, weekly: 40))
        mockSession.responseData = reporterUsageResponse()
        mockSession.responseStatusCode = 200

        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)
        await service.pollUsage()

        let usage = try! XCTUnwrap(service.latestUsage)
        XCTAssertEqual(usage.planRatio ?? -1, 0.10, accuracy: 0.0001,
                       "the measured 40/400, not the table's 0.0792")
        XCTAssertEqual(String(format: "%.0f", usage.sessionDisplayRemaining), "60",
                       "6% of the week at the measured ratio is 60% of a session, not the table's 76")
        // The raw fields stay raw whichever ratio won: the pace and the #31 forecast read these.
        XCTAssertEqual(usage.sessionRemaining, 100, accuracy: 0.01)
        XCTAssertEqual(usage.weeklyRemaining, 6, accuracy: 0.01)
    }

    @MainActor
    func testPoll_measurementOnATierWeDoNotRecognise_stillConvertsTheDial() async {
        // The measurement needs no plan string at all, so it reaches accounts the table can never
        // help: same seeded numbers, a tier that maps to nothing, same converted dial.
        accountStore.updatePlan(testAccount.id, rateLimitTier: "auto_prepaid_tier_3", capabilities: ["api"])
        accountStore.updateRatioMeasurement(testAccount.id, measurementFromAnotherWindow(session: 400, weekly: 40))
        mockSession.responseData = reporterUsageResponse()
        mockSession.responseStatusCode = 200

        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)
        await service.pollUsage()

        let usage = try! XCTUnwrap(service.latestUsage)
        XCTAssertNil(PlanRatio.forTier("auto_prepaid_tier_3"), "precondition: the table has nothing for this")
        XCTAssertEqual(usage.planRatio ?? -1, 0.10, accuracy: 0.0001)
        XCTAssertEqual(String(format: "%.0f", usage.sessionDisplayRemaining), "60")
    }

    @MainActor
    func testPoll_measurementBelowTheBarOnAnUnrecognisedTier_leavesTheDialUnconverted() async {
        // Neither source has anything: the measurement is short of its bar (3 weekly points, not 30)
        // and the tier maps to nothing. The dial shows the true session number rather than a guess
        // (R3, D4).
        accountStore.updatePlan(testAccount.id, rateLimitTier: "auto_prepaid_tier_3", capabilities: ["api"])
        accountStore.updateRatioMeasurement(testAccount.id, measurementFromAnotherWindow(session: 37, weekly: 3))
        mockSession.responseData = reporterUsageResponse()
        mockSession.responseStatusCode = 200

        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)
        await service.pollUsage()

        let usage = try! XCTUnwrap(service.latestUsage)
        XCTAssertNil(usage.planRatio)
        XCTAssertFalse(usage.isSessionWeeklyLimited)
        XCTAssertEqual(usage.sessionDisplayRemaining, 100, accuracy: 0.01)
    }

    @MainActor
    func testPoll_implausibleMeasurement_handsBackToTheTableRatherThanShowingIt() async {
        // 400 session points and the weekly never moved. That is not a ratio of zero, it is a sign
        // the two limits are not measuring the same thing (A3), so the measurement is refused and
        // the table converts the dial as before.
        accountStore.updatePlan(testAccount.id, rateLimitTier: "default_claude_max_5x", capabilities: nil)
        accountStore.updateRatioMeasurement(testAccount.id, measurementFromAnotherWindow(session: 400, weekly: 0))
        mockSession.responseData = reporterUsageResponse()
        mockSession.responseStatusCode = 200

        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)
        await service.pollUsage()

        let usage = try! XCTUnwrap(service.latestUsage)
        XCTAssertEqual(usage.planRatio ?? -1, PlanRatio.max5x, accuracy: 0.0001)
        XCTAssertEqual(String(format: "%.0f", usage.sessionDisplayRemaining), "76")
    }

    @MainActor
    func testPoll_measurementThatContradictsTheStoredPlan_keepsTheTable() async {
        // Past the bar and inside the plausible band, but it says a week holds four 5-hour windows
        // when the account's own plan says twelve and a half. One of the two is measuring something
        // else, and the table is the one with a stated origin, so the dial keeps the reporter's 76.
        accountStore.updatePlan(testAccount.id, rateLimitTier: "default_claude_max_5x", capabilities: nil)
        accountStore.updateRatioMeasurement(testAccount.id, measurementFromAnotherWindow(session: 120, weekly: 30))
        mockSession.responseData = reporterUsageResponse()
        mockSession.responseStatusCode = 200

        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)
        await service.pollUsage()

        let usage = try! XCTUnwrap(service.latestUsage)
        XCTAssertEqual(accountStore.activeAccount?.ratioMeasurement?.ratio ?? -1, 0.25, accuracy: 0.0001,
                       "precondition: the measurement itself is still produced")
        XCTAssertEqual(usage.planRatio ?? -1, PlanRatio.max5x, accuracy: 0.0001)
        XCTAssertEqual(String(format: "%.0f", usage.sessionDisplayRemaining), "76")
    }

    @MainActor
    func testPoll_afterAPlanChange_theOldPlansMeasurementIsGoneAndTheDialReRates() async {
        // The measurement outranks the tier, so a plan change that only refreshed the tier would
        // leave the dial converting on the capacities the account no longer has - with the correct
        // value sitting unused beside it (R4).
        accountStore.updatePlan(testAccount.id, rateLimitTier: "default_claude_max_5x", capabilities: nil)
        accountStore.updateRatioMeasurement(testAccount.id, measurementFromAnotherWindow(session: 400, weekly: 32))
        mockSession.responseData = reporterUsageResponse()
        mockSession.responseStatusCode = 200

        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)
        await service.pollUsage()
        XCTAssertEqual(String(format: "%.0f", try! XCTUnwrap(service.latestUsage).sessionDisplayRemaining), "75",
                       "precondition: the Max 5x measurement is what converts the dial")

        accountStore.updatePlan(testAccount.id, rateLimitTier: "default_claude_max_20x", capabilities: nil)
        await service.pollUsage()

        let usage = try! XCTUnwrap(service.latestUsage)
        XCTAssertEqual(usage.planRatio ?? -1, PlanRatio.max20x, accuracy: 0.0001)
        XCTAssertEqual(String(format: "%.0f", usage.sessionDisplayRemaining), "45",
                       "the upgraded plan's table value, not a ratio measured on the old one")
    }

    @MainActor
    func testPoll_aReadingWithNoPercentageInIt_isNeverAccumulated() async {
        // A response that carries resets_at but no utilization reads as a full window for display,
        // which is a fabricated 100 rather than an observed one. Differencing the next real reading
        // against it would book a whole window of session points nobody spent.
        let noPercentage = Data("""
        {
          "five_hour": { "resets_at": "2026-07-28T22:00:00Z" },
          "seven_day": { "utilization": 37.0, "resets_at": "2026-08-02T00:00:00Z" }
        }
        """.utf8)
        mockSession.responseData = noPercentage
        mockSession.responseStatusCode = 200
        let service = UsageService(storage: storage, accountStore: accountStore, session: mockSession)
        await service.pollUsage()

        let seeded = try! XCTUnwrap(service.latestUsage)
        XCTAssertEqual(seeded.sessionRemaining, 100, accuracy: 0.01, "the display still shows a full window")
        XCTAssertNotNil(seeded.sessionResetDate, "and it keeps the real reset date the countdown reads")

        mockSession.responseData = usageResponse(session: 40, weekly: 63)
        await service.pollUsage()

        let measurement = try! XCTUnwrap(accountStore.activeAccount?.ratioMeasurement)
        XCTAssertEqual(measurement.sessionPointsConsumed, 0,
                       "60 points of nothing must not enter the accumulator")
        XCTAssertEqual(measurement.weeklyPointsConsumed, 0, "and neither half of that interval counts")
    }

    // MARK: - Helpers

    /// A usage response with both windows stated outright, so a test can hold a window fixed across
    /// two polls or roll one over between them.
    private func usageResponse(session: Double,
                               weekly: Double,
                               sessionResets: String = "2026-07-28T22:00:00Z",
                               weeklyResets: String = "2026-08-02T00:00:00Z") -> Data {
        Data("""
        {
          "five_hour": { "utilization": \(100 - session), "resets_at": "\(sessionResets)" },
          "seven_day": { "utilization": \(100 - weekly), "resets_at": "\(weeklyResets)" }
        }
        """.utf8)
    }

    /// An already-accumulated measurement whose stored sample belongs to windows from 1970, so a
    /// poll against any real response replaces the sample and accumulates nothing. That keeps a
    /// seeded ratio exactly what the test said it was.
    private func measurementFromAnotherWindow(session: Double, weekly: Double) -> RatioMeasurement {
        RatioMeasurement(lastSessionRemaining: 100,
                         lastSessionResetsAt: Date(timeIntervalSince1970: 1),
                         lastWeeklyRemaining: 100,
                         lastWeeklyResetsAt: Date(timeIntervalSince1970: 2),
                         sessionPointsConsumed: session,
                         weeklyPointsConsumed: weekly)
    }

    /// The reporter's numbers as a usage response: a full 5-hour window with 6% of the week left.
    /// Written inline rather than added to Fixtures/ because these two utilizations ARE the bug
    /// report, and they belong where the assertion that reads them can be checked against them.
    private func reporterUsageResponse() -> Data {
        Data("""
        {
          "five_hour": { "utilization": 0.0, "resets_at": "2026-07-28T22:00:00Z" },
          "seven_day": { "utilization": 94.0, "resets_at": "2026-08-02T00:00:00Z" }
        }
        """.utf8)
    }

    /// Usage requests only: `pollUsage` also fetches the prepaid-credits endpoint, so the raw
    /// captured count would move for reasons the pause tests are not asking about.
    @MainActor
    private func usageRequestCount() -> Int {
        mockSession.capturedRequests.filter { $0.url?.path.hasSuffix("/usage") ?? false }.count
    }

    /// Poll `condition` on the main actor until it is true or `timeout` elapses, returning whether
    /// it was met. The negative assertions use it as a fail-fast wait: it returns the moment the
    /// thing that must not happen happens.
    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func fixtureData(_ name: String) -> Data {
        let file = URL(fileURLWithPath: #file)
        let testsDir = file.deletingLastPathComponent()
        let url = testsDir
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("\(name).json")
        return try! Data(contentsOf: url)
    }
}

/// An `HTTPDataFetching` double that parks inside `data(for:)` until the test releases it, so a
/// poll can be held IN FLIGHT while the test does something to the service. R11's failure is a
/// race, and this is what makes it a fixed sequence instead of two tasks hoping to interleave.
/// Kept out of MockHTTPSession: nothing else needs a request that stops halfway.
///
/// The park is a plain checked continuation, which is deliberately not cancellation-aware - the
/// point is that cancelling the poll does NOT unblock the request, exactly as a real one in flight
/// keeps going until the server answers.
private final class GatedSession: HTTPDataFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _delivered = false
    private var _released = false
    private var _usageRequests = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private let responseData: Data
    private let statusCode: Int

    init(data: Data, statusCode: Int) {
        self.responseData = data
        self.statusCode = statusCode
    }

    /// The request has been received and is parked.
    var started: Bool { lock.withLock { _started } }
    /// The response has been handed back to the caller.
    var delivered: Bool { lock.withLock { _delivered } }
    /// How many usage requests have arrived. Counting is what a test needs to say a resume really
    /// polled AGAIN rather than just once, and the latches above cannot say it. Filtered to the
    /// usage path the same way the `usageRequestCount()` helper above is, because a 200 poll also
    /// fetches prepaid credits through this same double.
    var usageRequests: Int { lock.withLock { _usageRequests } }

    func release() {
        lock.lock()
        _released = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        _started = true
        if request.url?.path.hasSuffix("/usage") ?? false { _usageRequests += 1 }
        if _released {
            lock.unlock()
        } else {
            // The lock is held until the continuation is stored, so a release() racing this cannot
            // slip between the check and the park and leave the request stuck forever.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiter = continuation
                lock.unlock()
            }
        }
        lock.withLock { _delivered = true }
        let url = request.url ?? URL(string: "https://claude.ai")!
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (responseData, response)
    }
}

// MARK: - limits[] / spend decode (U1)

/// Locks the newer `/usage` `limits[]`/`spend` decode and the expanded `/prepaid/credits`
/// decode, plus the shared tolerant `resets_at` parser reaching `UsageLimit` (KTD1/KTD2).
final class UsageLimitsSpendDecodeTests: XCTestCase {

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func fixtureURL(named name: String) -> URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("\(name).json")
    }

    private func decodeUsage(_ name: String) throws -> UsageResponse {
        let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "json")
            ?? fixtureURL(named: name)
        return try decoder().decode(UsageResponse.self, from: Data(contentsOf: url))
    }

    private func decodePrepaid(_ name: String) throws -> PrepaidCreditsResponse {
        let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "json")
            ?? fixtureURL(named: name)
        return try decoder().decode(PrepaidCreditsResponse.self, from: Data(contentsOf: url))
    }

    /// Decode a single `UsageLimit` with a raw `resets_at` JSON value through the production
    /// decoder config, mirroring `decodeTier` so the shared `ResetDate` parser is locked for
    /// `UsageLimit` too.
    private func decodeLimit(resetsAtRawJSON: String) -> UsageLimit {
        let json = "{\"kind\": \"session\", \"resets_at\": \(resetsAtRawJSON)}"
        return try! decoder().decode(UsageLimit.self, from: Data(json.utf8))
    }

    // MARK: - Structure

    func testLimitsSpend_decodesStructure() throws {
        let r = try decodeUsage("usage_limits_spend")

        let limits = try XCTUnwrap(r.limits)
        XCTAssertEqual(limits.count, 3)
        XCTAssertEqual(limits.map(\.kind), ["session", "weekly_all", "weekly_scoped"])

        let scoped = try XCTUnwrap(limits.first { $0.kind == "weekly_scoped" })
        XCTAssertEqual(scoped.scope?.model?.displayName, "Sonnet")
        XCTAssertEqual(scoped.percent ?? -1, 3, accuracy: 0.01)

        let spend = try XCTUnwrap(r.spend)
        XCTAssertEqual(spend.enabled, false)
        XCTAssertEqual(spend.disabledReason, "org_level_disabled_until")
        XCTAssertEqual(spend.percent ?? -1, 0, accuracy: 0.01)
        XCTAssertNil(spend.limit)
        XCTAssertEqual(spend.used?.amountMinor, 0)
        XCTAssertEqual(spend.used?.currency, "USD")
        XCTAssertEqual(spend.used?.exponent, 2)
    }

    func testLimitsSpend_legacyFieldsStillDecode() throws {
        // KTD1: the newer shape must not break the existing per-field decode.
        let r = try decodeUsage("usage_limits_spend")
        XCTAssertEqual(r.fiveHour?.utilization ?? -1, 6, accuracy: 0.01)
        XCTAssertEqual(r.sevenDay?.utilization ?? -1, 37, accuracy: 0.01)
        XCTAssertEqual(r.sevenDaySonnet?.utilization ?? -1, 3, accuracy: 0.01)
        XCTAssertNil(r.sevenDayOpus)
        XCTAssertNotNil(r.fiveHour?.resetsAt)
    }

    func testLegacyFixture_hasNoLimitsOrSpend() throws {
        // No regression: a legacy body decodes with limits/spend absent.
        let r = try decodeUsage("usage_full")
        XCTAssertNil(r.limits)
        XCTAssertNil(r.spend)
    }

    func testUsageBodyLackingLimitsSpend_doesNotThrow() throws {
        let r = try decoder().decode(UsageResponse.self, from: Data("{}".utf8))
        XCTAssertNil(r.limits)
        XCTAssertNil(r.spend)
    }

    // MARK: - Shared resets_at parser reaches UsageLimit (KTD2, #23 matrix)

    func testLimitResetsAt_epochSeconds_decodes() {
        XCTAssertEqual(decodeLimit(resetsAtRawJSON: "1775714400").resetsAt?.timeIntervalSince1970 ?? 0,
                       1775714400, accuracy: 0.5)
    }

    func testLimitResetsAt_epochMilliseconds_decodes() {
        XCTAssertEqual(decodeLimit(resetsAtRawJSON: "1775714400000").resetsAt?.timeIntervalSince1970 ?? 0,
                       1775714400, accuracy: 0.5)
    }

    func testLimitResetsAt_epochString_decodes() {
        XCTAssertEqual(decodeLimit(resetsAtRawJSON: "\"1775714400\"").resetsAt?.timeIntervalSince1970 ?? 0,
                       1775714400, accuracy: 0.5)
    }

    func testLimitResetsAt_iso8601Fractional_decodes() {
        XCTAssertNotNil(decodeLimit(resetsAtRawJSON: "\"2026-04-10T14:00:00.000Z\"").resetsAt)
    }

    func testLimitResetsAt_iso8601BareZ_decodes() {
        XCTAssertNotNil(decodeLimit(resetsAtRawJSON: "\"2026-04-10T14:00:00Z\"").resetsAt)
    }

    func testLimitResetsAt_null_isNil() {
        XCTAssertNil(decodeLimit(resetsAtRawJSON: "null").resetsAt)
    }

    func testLimitResetsAt_nonFiniteAndOutOfRange_isNil() {
        for raw in ["\"inf\"", "\"nan\"", "\"1e400\"", "1e308", "99999999999", "0", "-1775714400"] {
            XCTAssertNil(decodeLimit(resetsAtRawJSON: raw).resetsAt,
                         "limit resets_at \(raw) must decode to nil, never a trapping Date")
        }
    }

    // MARK: - Prepaid credits (expanded shape)

    func testPrepaidCreditsAUD_decodes() throws {
        let p = try decodePrepaid("prepaid_credits_aud")
        XCTAssertEqual(p.amount, 7152)
        XCTAssertEqual(p.currency, "AUD")
    }

    // MARK: - Derivation: limits[]/spend -> UsageData (U2)

    func testLimitsPrimary_derivesSessionWeeklyModels() throws {
        // Covers R0.4: limits[] is the primary source when present.
        let usage = UsageData(from: try decodeUsage("usage_limits_spend"))
        XCTAssertEqual(usage.sessionRemaining, 94, accuracy: 0.01)  // 100 - 6 (session limit)
        XCTAssertEqual(usage.weeklyRemaining, 63, accuracy: 0.01)   // 100 - 37 (weekly_all)
        XCTAssertEqual(usage.modelUsages.count, 1)
        XCTAssertEqual(usage.modelUsages.first?.displayName, "Sonnet")
        XCTAssertEqual(usage.modelUsages.first?.remainingPercent ?? -1, 97, accuracy: 0.01)  // 100 - 3
        XCTAssertNotNil(usage.modelUsages.first?.resetDate)  // weekly_scoped resets_at wired through
        XCTAssertFalse(usage.modelUsages.contains { $0.displayName == "Opus" })
    }

    func testLegacyPerModel_presentTierWithNullUtilization_dropsBar() throws {
        // A present seven_day_opus tier whose utilization is null must hide the bar, not
        // render a fabricated 100% (KTD3) - the gate is on utilization, not just the tier.
        let json = """
        { "seven_day_opus": { "utilization": null },
          "seven_day_sonnet": { "utilization": 10.0 } }
        """
        let usage = UsageData(from: try decoder().decode(UsageResponse.self, from: Data(json.utf8)))
        XCTAssertEqual(usage.modelUsages.map(\.displayName), ["Sonnet"])
    }

    func testDisabledCredits_withPrepaidBalance() throws {
        // Reporter's live data: spend disabled, prepaid balance still shown (KTD5).
        let usage = UsageData(from: try decodeUsage("usage_limits_spend"),
                              prepaidCredits: try decodePrepaid("prepaid_credits_aud"))
        let credits = try XCTUnwrap(usage.usageCredits)
        guard case let .disabled(reason, resetDate) = credits.state else {
            return XCTFail("expected disabled state, got \(String(describing: credits.state))")
        }
        XCTAssertEqual(reason, "org_level_disabled_until")
        XCTAssertNil(resetDate)
        XCTAssertEqual(credits.balance?.major ?? -1, 71.52, accuracy: 0.001)  // 7152 cents -> A$71.52
        XCTAssertEqual(credits.balance?.currency, "AUD")
    }

    func testEnabledCredits_over100PercentUncapped() throws {
        // KTD7: spend.percent can exceed 100; the derived state keeps it uncapped.
        // KTD4: amount_minor / 10^exponent converts to major units exactly once.
        let json = """
        { "spend": { "used": { "amount_minor": 20513, "currency": "AUD", "exponent": 2 },
                     "limit": { "amount_minor": 20000, "currency": "AUD", "exponent": 2 },
                     "percent": 103, "severity": "normal", "enabled": true } }
        """
        let usage = UsageData(from: try decoder().decode(UsageResponse.self, from: Data(json.utf8)))
        let credits = try XCTUnwrap(usage.usageCredits)
        guard case let .enabled(spent, limit, percent, currency, _) = credits.state else {
            return XCTFail("expected enabled state, got \(String(describing: credits.state))")
        }
        XCTAssertEqual(spent, 205.13, accuracy: 0.001)   // 20513 minor / 10^2
        XCTAssertEqual(limit ?? -1, 200, accuracy: 0.001) // 20000 minor / 10^2
        XCTAssertEqual(percent, 103, accuracy: 0.01)      // uncapped
        XCTAssertEqual(currency, "AUD")
    }

    func testBalanceOnly_whenSpendAbsent() throws {
        // Legacy body (no spend) + prepaid balance -> credits carry only a balance.
        let usage = UsageData(from: try decodeUsage("usage_full"),
                              prepaidCredits: try decodePrepaid("prepaid_credits_aud"))
        let credits = try XCTUnwrap(usage.usageCredits)
        XCTAssertNil(credits.state)
        XCTAssertEqual(credits.balance?.major ?? -1, 71.52, accuracy: 0.001)
        XCTAssertEqual(credits.balance?.currency, "AUD")
    }
}

// MARK: - Measuring the account's real ratio (S4, R5, KTD4, KTD5, D3)

/// The accumulation rules, driven directly with synthetic sample sequences. Nothing here waits on
/// real polling, which could only ever show one interval anyway and would prove nothing about the
/// cases that matter: rollovers, corrections, and how long it takes to become trustworthy.
final class RatioMeasurementTests: XCTestCase {

    /// The two windows a reading belongs to. Fixed, so a test only names a date when a rollover is
    /// the point of the test.
    private let sessionWindow = Date(timeIntervalSince1970: 1_780_000_000)
    private let weeklyWindow = Date(timeIntervalSince1970: 1_780_500_000)

    /// Fold one poll's reading in. Percentages are REMAINING, as everywhere else in the app.
    private func fold(_ previous: RatioMeasurement?,
                      session: Double,
                      weekly: Double,
                      sessionResets: Date? = nil,
                      weeklyResets: Date? = nil) -> RatioMeasurement {
        RatioMeasurement.updated(from: previous,
                                 sessionRemaining: session,
                                 sessionResetsAt: sessionResets ?? sessionWindow,
                                 weeklyRemaining: weekly,
                                 weeklyResetsAt: weeklyResets ?? weeklyWindow)
    }

    /// A measurement holding the given totals, built the only way the app can really build them:
    /// by folding whole-number readings through the accumulator, rolling the 5-hour window whenever
    /// it runs out, with the weekly ticking down one point at a time.
    ///
    /// Writing the two totals down directly can state pairs the API can never send - a fractional
    /// weekly total most of all - and a test that does is testing arithmetic no user will ever
    /// reach. Every reading here is a whole number, which is what the confidence bar is sized
    /// against.
    private func accumulated(session: Int, weekly: Int) -> RatioMeasurement {
        var measurement = fold(nil, session: 100, weekly: 100)
        guard session > 0 else { return measurement }

        var window = sessionWindow
        var sessionRemaining = 100.0
        for point in 1...session {
            if sessionRemaining <= 0 {
                // The 5-hour window ran out. It rolls, and the interval straddling it is discarded
                // by the accumulator exactly as it is in the app (KTD4).
                window = window.addingTimeInterval(5 * 3600)
                sessionRemaining = 100
                measurement = fold(measurement, session: sessionRemaining,
                                   weekly: measurement.lastWeeklyRemaining, sessionResets: window)
            }
            sessionRemaining -= 1
            // The weekly moves in whole points, spread evenly over the run.
            let weeklyConsumed = (Double(point) * Double(weekly) / Double(session)).rounded(.down)
            measurement = fold(measurement, session: sessionRemaining,
                               weekly: 100 - weeklyConsumed, sessionResets: window)
        }
        return measurement
    }

    // MARK: - Accumulating

    func testFirstSample_recordsTheReadingAndAccumulatesNothing() {
        // There is nothing to difference against yet, so the first poll can only seed.
        let first = fold(nil, session: 100, weekly: 63)
        XCTAssertEqual(first.lastSessionRemaining, 100)
        XCTAssertEqual(first.lastWeeklyRemaining, 63)
        XCTAssertEqual(first.sessionPointsConsumed, 0)
        XCTAssertEqual(first.weeklyPointsConsumed, 0)
        XCTAssertNil(first.ratio)
    }

    func testCleanInterval_accumulatesBothDeltas() {
        // Same two windows, both remainders down: 8 session points bought 1 weekly point.
        let measurement = fold(fold(nil, session: 100, weekly: 63), session: 92, weekly: 62)
        XCTAssertEqual(measurement.sessionPointsConsumed, 8, accuracy: 0.0001)
        XCTAssertEqual(measurement.weeklyPointsConsumed, 1, accuracy: 0.0001)
        XCTAssertEqual(measurement.lastSessionRemaining, 92, "and the sample moved on to this reading")
    }

    func testConsecutiveCleanIntervals_addUp() {
        var measurement = fold(nil, session: 100, weekly: 63)
        measurement = fold(measurement, session: 92, weekly: 62)
        measurement = fold(measurement, session: 84, weekly: 62)
        measurement = fold(measurement, session: 76, weekly: 61)
        XCTAssertEqual(measurement.sessionPointsConsumed, 24, accuracy: 0.0001)
        XCTAssertEqual(measurement.weeklyPointsConsumed, 2, accuracy: 0.0001)
    }

    func testIdleInterval_isCleanAndAddsZero() {
        // Nothing used between two polls. That is a real interval carrying real information (zero
        // over zero contributes nothing either way), and it must not be mistaken for a rollover.
        let idle = fold(fold(nil, session: 92, weekly: 62), session: 92, weekly: 62)
        XCTAssertEqual(idle.sessionPointsConsumed, 0)
        XCTAssertEqual(idle.weeklyPointsConsumed, 0)
    }

    // MARK: - Rollovers

    func testSessionRollover_addsNothingAndKeepsTheTotals() {
        // The 5-hour window reset: remaining jumps back to 100 and resets_at moves. Recorded as
        // consumption that reads as a whole window drained at once; recorded as a change at all it
        // is a negative. Neither goes in.
        var measurement = fold(fold(nil, session: 100, weekly: 63), session: 20, weekly: 55)
        XCTAssertEqual(measurement.sessionPointsConsumed, 80, accuracy: 0.0001, "precondition")

        measurement = fold(measurement, session: 100, weekly: 55,
                           sessionResets: sessionWindow.addingTimeInterval(5 * 3600))

        XCTAssertEqual(measurement.sessionPointsConsumed, 80, accuracy: 0.0001,
                       "the straddling interval is discarded, and the history in front of it is kept")
        XCTAssertEqual(measurement.weeklyPointsConsumed, 8, accuracy: 0.0001)
    }

    func testWeeklyRollover_addsNothingAndKeepsTheTotals() {
        // Same rule from the other side: the session window is untouched and its delta looks
        // perfectly ordinary, but a paired measurement needs both halves of the interval.
        var measurement = fold(fold(nil, session: 100, weekly: 8), session: 60, weekly: 3)
        XCTAssertEqual(measurement.sessionPointsConsumed, 40, accuracy: 0.0001, "precondition")

        measurement = fold(measurement, session: 52, weekly: 100,
                           weeklyResets: weeklyWindow.addingTimeInterval(7 * 24 * 3600))

        XCTAssertEqual(measurement.sessionPointsConsumed, 40, accuracy: 0.0001,
                       "an 8-point session delta next to a weekly rollover is still an unusable interval")
        XCTAssertEqual(measurement.weeklyPointsConsumed, 5, accuracy: 0.0001)
    }

    func testRollover_stillReplacesTheSample_soTheNextIntervalIsMeasuredFromTheNewWindow() {
        // The half that is easy to leave out. Without replacing the sample, the poll after a
        // rollover is differenced against a reading from the window before last, which invents an
        // enormous delta out of nothing.
        let newWindow = sessionWindow.addingTimeInterval(5 * 3600)
        var measurement = fold(fold(nil, session: 100, weekly: 63), session: 20, weekly: 55)
        measurement = fold(measurement, session: 100, weekly: 55, sessionResets: newWindow)
        measurement = fold(measurement, session: 90, weekly: 54, sessionResets: newWindow)

        XCTAssertEqual(measurement.sessionPointsConsumed, 90, accuracy: 0.0001,
                       "80 before the rollover plus 10 after, not 80 plus a fabricated jump")
        XCTAssertEqual(measurement.weeklyPointsConsumed, 9, accuracy: 0.0001)
    }

    // MARK: - Changes that cannot be consumption

    func testSessionRemainingWentUp_isNeverAccumulated() {
        // Same window, more left than before. Not possible from use, so it is a correction on the
        // API's side, and a negative delta would subtract usage that really happened.
        let measurement = fold(fold(nil, session: 60, weekly: 55), session: 65, weekly: 54)
        XCTAssertEqual(measurement.sessionPointsConsumed, 0)
        XCTAssertEqual(measurement.weeklyPointsConsumed, 0, "and neither half of the interval is taken")
        XCTAssertEqual(measurement.lastSessionRemaining, 65, "the sample still moves on")
    }

    func testWeeklyRemainingWentUp_isNeverAccumulated() {
        let measurement = fold(fold(nil, session: 60, weekly: 55), session: 52, weekly: 56)
        XCTAssertEqual(measurement.sessionPointsConsumed, 0)
        XCTAssertEqual(measurement.weeklyPointsConsumed, 0)
    }

    // MARK: - Reset times

    func testMissingResetTimes_neverAccumulate() {
        // With no resets_at there is no way to tell a rollover from ordinary use, so an account
        // whose API returns null reset times measures nothing at all and keeps the table value.
        let first = RatioMeasurement.updated(from: nil, sessionRemaining: 100, sessionResetsAt: nil,
                                             weeklyRemaining: 63, weeklyResetsAt: nil)
        let second = RatioMeasurement.updated(from: first, sessionRemaining: 92, sessionResetsAt: nil,
                                              weeklyRemaining: 62, weeklyResetsAt: nil)
        XCTAssertEqual(second.sessionPointsConsumed, 0)
        XCTAssertEqual(second.weeklyPointsConsumed, 0)
    }

    func testOneMissingResetTime_alsoBlocksTheInterval() {
        // Half a window pair is no more usable than none.
        let first = fold(nil, session: 100, weekly: 63)
        let second = RatioMeasurement.updated(from: first, sessionRemaining: 92, sessionResetsAt: sessionWindow,
                                              weeklyRemaining: 62, weeklyResetsAt: nil)
        XCTAssertEqual(second.sessionPointsConsumed, 0)
    }

    func testSubSecondJitterInAResetTime_isStillTheSameWindow() {
        // The same instant arrives as bare ISO, fractional ISO, epoch seconds or epoch
        // milliseconds (see ResetDate), so the comparison allows a second of slack. A real
        // rollover moves resets_at by hours and cannot hide inside that.
        let measurement = fold(fold(nil, session: 100, weekly: 63),
                               session: 92, weekly: 62,
                               sessionResets: sessionWindow.addingTimeInterval(0.4))
        XCTAssertEqual(measurement.sessionPointsConsumed, 8, accuracy: 0.0001)
    }

    // MARK: - The confidence bar (KTD5)

    func testConfidenceBar_isTheNumberTheArithmeticGives() {
        // Re-derives the constant from what the ratio is USED for, so the comment beside it cannot
        // drift away from the value. Both totals are whole numbers, so the reachable ratios sit on
        // a grid one weekly point apart; the ratio is a divisor, so that grid step lands straight
        // on the displayed number as a fraction of itself.
        XCTAssertEqual(RatioMeasurement.confidenceBar, 30)
        let worstCaseAtTheBar = 1 / RatioMeasurement.confidenceBar

        for table in [PlanRatio.pro, PlanRatio.max5x, PlanRatio.max20x] {
            // The session points it takes to buy the bar, and what one weekly point is worth in
            // ratio units at that point.
            let sessionPoints = RatioMeasurement.confidenceBar / table
            let gridStep = 1 / sessionPoints

            XCTAssertEqual(gridStep / table, worstCaseAtTheBar, accuracy: 0.000001,
                           "the relative resolution is 1 / weekly points on every plan, which is why "
                           + "the bar counts weekly points and not session points")
            XCTAssertGreaterThan(sessionPoints, 200,
                                 "KTD5 asked for several hundred accumulated session points, and "
                                 + "\(table) reaches the bar at \(sessionPoints)")
        }

        XCTAssertLessThan(worstCaseAtTheBar, 0.034,
                          "a whole point of rounding stays inside a few percent of the displayed number")
    }

    func testAnAfternoonOfUse_isNotYetAMeasurement() {
        // The case a session-point bar got wrong. 38 session points on Max 5x buys about 3 whole
        // weekly points, and 3 can only be read as 2, 3 or 4, so the ratio would swing from 0.053
        // to 0.105 and take the dial from 57 to 100 with it. No number at all is the right answer.
        XCTAssertNil(accumulated(session: 38, weekly: 3).ratio)
    }

    func testBelowTheConfidenceBar_thereIsNoMeasuredRatio() {
        // AE9. One weekly point short is still short: the table value stands.
        let measurement = accumulated(session: 366, weekly: 29)
        XCTAssertEqual(measurement.weeklyPointsConsumed, 29, accuracy: 0.0001, "precondition")
        XCTAssertNil(measurement.ratio)
    }

    func testAtTheConfidenceBar_theMeasuredRatioIsAvailable() {
        // AE8. The bar is inclusive, and 30 weekly points off a Max 5x account is about 379 session
        // points, so this is the shape of run that really produces the first usable ratio.
        let measurement = accumulated(session: 379, weekly: 30)
        XCTAssertEqual(measurement.weeklyPointsConsumed, 30, accuracy: 0.0001, "precondition")
        XCTAssertEqual(measurement.ratio ?? -1, PlanRatio.max5x,
                       accuracy: PlanRatio.max5x / RatioMeasurement.confidenceBar,
                       "inside the one-weekly-point resolution the bar is sized for")
    }

    func testNothingMeasuredYet_hasNoRatioAndDoesNotDivideByZero() {
        XCTAssertNil(accumulated(session: 0, weekly: 0).ratio)
    }

    // MARK: - The plausible range

    func testImplausiblyHighRatio_isRejected() {
        // 0.6 would mean a whole week's capacity holds under two 5-hour windows. Nothing looks
        // like that, so it is a measurement of something other than what we think (A3), and the
        // dial gets the table value instead of a number nobody can defend.
        XCTAssertNil(accumulated(session: 50, weekly: 30).ratio)
        XCTAssertEqual(accumulated(session: 60, weekly: 30).ratio ?? -1, 0.5, accuracy: 0.0001,
                       "and the edge of the band is inside it")
    }

    func testImplausiblyLowRatio_isRejected() {
        // 30 weekly points spread over 4000 session points is a week holding 133 full windows.
        // Either the two limits do not share a credit unit (A3) or something upstream is broken;
        // either way it would divide the weekly remainder into an enormous number.
        XCTAssertNil(accumulated(session: 4000, weekly: 30).ratio)
        XCTAssertEqual(accumulated(session: 3000, weekly: 30).ratio ?? -1, 0.01, accuracy: 0.0001,
                       "and the edge of the band is inside it")
    }

    func testAWeeklyThatNeverMoved_neverReachesTheBandAtAll() {
        // The old shape of this case: 400 session points and a weekly that never ticked. The bar
        // counts weekly points now, so a measurement with nothing on that side is refused before
        // the band is ever consulted, which is the same answer one step earlier.
        let measurement = accumulated(session: 400, weekly: 0)
        XCTAssertEqual(measurement.weeklyPointsConsumed, 0)
        XCTAssertNil(measurement.ratio)
    }

    // MARK: - End to end on a synthetic run

    func testSyntheticRun_recoversTheRatioItWasGeneratedFrom() {
        // The whole claim in one test: generate polls from a KNOWN ratio, with the whole-number
        // rounding the API really applies and with the 5-hour window rolling over four times, and
        // the measurement should come back with that ratio.
        let trueRatio = PlanRatio.max5x     // 0.0792
        let pointsPerPoll = 7.0
        let weeklyWindow = Date(timeIntervalSince1970: 1_780_500_000)
        var sessionWindow = Date(timeIntervalSince1970: 1_780_000_000)
        var firstPollOfWindow = 0
        var measurement: RatioMeasurement?

        for poll in 0..<60 {
            if poll > 0, poll % 12 == 0 {
                // The 5-hour window rolls: usage inside it goes back to zero, resets_at moves on.
                sessionWindow = sessionWindow.addingTimeInterval(5 * 3600)
                firstPollOfWindow = poll
            }
            let sessionConsumed = Double(poll - firstPollOfWindow) * pointsPerPoll
            let weeklyConsumed = Double(poll) * pointsPerPoll * trueRatio
            measurement = RatioMeasurement.updated(from: measurement,
                                                   sessionRemaining: 100 - sessionConsumed.rounded(),
                                                   sessionResetsAt: sessionWindow,
                                                   weeklyRemaining: 100 - weeklyConsumed.rounded(),
                                                   weeklyResetsAt: weeklyWindow)
        }

        let result = measurement!
        // 59 intervals, 4 of them straddling a rollover: 55 x 7 points. A version that accumulated
        // through rollovers would land on some other number, whichever way it got the sign. The 30
        // weekly points are exactly the confidence bar, so this run is also what crossing it looks
        // like: a shorter run would produce no ratio to check at all.
        XCTAssertEqual(result.sessionPointsConsumed, 385, accuracy: 0.0001)
        XCTAssertEqual(result.weeklyPointsConsumed, 30, accuracy: 0.0001)

        let measured = try! XCTUnwrap(result.ratio)
        XCTAssertEqual(measured, trueRatio, accuracy: trueRatio / RatioMeasurement.confidenceBar,
                       "inside the one-weekly-point resolution the confidence bar was sized for")
        // And it identifies the right plan, which is what the number is for.
        let distances = [PlanRatio.pro, PlanRatio.max5x, PlanRatio.max20x].map { abs($0 - measured) }
        XCTAssertEqual(distances.min(), abs(PlanRatio.max5x - measured),
                       "the measured ratio is nearest Max 5x, the ratio it was generated from")
    }

    // MARK: - Storage (KTD2 pattern: optional and additive)

    func testMeasurementSurvivesAJSONRoundTrip() {
        let original = fold(fold(nil, session: 100, weekly: 63), session: 92, weekly: 62)
        let decoded = try! JSONDecoder().decode(RatioMeasurement.self,
                                                from: try! JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original, "including the reset times, or every relaunch looks like a rollover")
    }

    func testAccountStoredBeforeThisRelease_decodesWithNoMeasurement() {
        // Every upgrading user has accounts on disk written before the accumulator existed. They
        // must load rather than throw, and start measuring from their next poll.
        let stored = """
        {"id":"\(UUID().uuidString)","email":"old@x.com","sessionKey":"sk","organizationId":"org-1",\
        "addedDate":0,"notificationThreshold":20,"didNotifyBelowThreshold":false}
        """
        let account = try! JSONDecoder().decode(Account.self, from: Data(stored.utf8))
        XCTAssertNil(account.ratioMeasurement)
    }

    func testAccountCarryingAMeasurement_survivesARoundTrip() {
        var account = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-1")
        account.ratioMeasurement = accumulated(session: 385, weekly: 30)
        let decoded = try! JSONDecoder().decode(Account.self, from: try! JSONEncoder().encode(account))
        XCTAssertEqual(decoded.ratioMeasurement, account.ratioMeasurement,
                       "the accumulator has to outlive a relaunch or it never reaches the bar")
    }
}
