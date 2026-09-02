import Foundation
import Testing
@testable import Trio

@Suite("Therapy settings compensation report") struct TherapySettingsAnalyzerTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: hour, minute: minute))!
    }

    private var profile: TherapyProfileSnapshot {
        TherapyProfileSnapshot(
            basal: [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1.0)],
            isf: [InsulinSensitivityEntry(sensitivity: 40, offset: 0, start: "00:00")],
            carbRatios: CarbRatios(
                units: .grams,
                schedule: [CarbRatioEntry(start: "00:00", offset: 0, ratio: 8)]
            ),
            units: .mgdL,
            basalIncrement: Decimal(string: "0.05") ?? 0.05
        )
    }

    private func loop(
        day: Int,
        hour: Int,
        minute: Int = 0,
        cob: Decimal = 0,
        requestedRate: Decimal? = 1.0,
        duration: Decimal? = 30,
        sensitivityRatio: Decimal? = 1.0,
        insulinSensitivity: Decimal? = 40,
        reason: String = "Autosens ratio: 1, ISF: 40→40"
    ) -> TherapyLoopSample {
        TherapyLoopSample(
            date: date(day: day, hour: hour, minute: minute),
            cob: cob,
            requestedRate: requestedRate,
            duration: duration,
            sensitivityRatio: sensitivityRatio,
            insulinSensitivity: insulinSensitivity,
            reason: reason
        )
    }

    private func report(
        loops: [TherapyLoopSample],
        glucose: [TherapyGlucoseReading] = [],
        carbs: [TherapyCarbEntry] = [],
        boluses: [TherapyBolus] = [],
        excludedWindows: [DateInterval] = []
    ) -> TherapySettingsReport {
        TherapySettingsAnalyzer.generate(
            from: TherapySettingsInput(
                lookbackDays: 14,
                now: date(day: 15, hour: 12),
                calendar: calendar,
                profile: profile,
                loops: loops,
                glucose: glucose,
                carbs: carbs,
                boluses: boluses,
                excludedWindows: excludedWindows,
                overrideHistoryRetentionDays: OverrideRunStored.historyRetentionDays
            )
        )
    }

    @Test("Parses basal TDD ratio from determination reason") func parseBasalRatio() {
        let reason =
            "Autosens ratio: 1.15, ISF: 40→35, Dynamic ISF: On, Sigmoid function, AF: 0.5, Basal ratio: 1.12; setting 1.2U/hr."
        #expect(TherapySettingsAnalyzer.parseBasalTddRatio(from: reason) == Decimal(string: "1.12"))
        #expect(TherapySettingsAnalyzer.parseBasalTddRatio(from: "no ratio here") == nil)
        #expect(TherapySettingsAnalyzer.parseAutosensRatio(from: reason) == Decimal(string: "1.15"))
    }

    @Test("Basal scale uses only a ratio the loop actually recorded")
    func basalScaleRatioFromRecordedReason() {
        #expect(
            TherapySettingsAnalyzer.basalScaleRatio(
                from: "Dynamic ISF: On, Sigmoid function, Basal ratio: 1.2; setting 1.2U/hr."
            ) == Decimal(string: "1.2")
        )
        #expect(
            TherapySettingsAnalyzer.basalScaleRatio(
                from: "Autosens ratio: 1.15, Dynamic ISF: On, Sigmoid function"
            ) == 1
        )
        #expect(
            TherapySettingsAnalyzer.basalScaleRatio(from: "Autosens ratio: 1.2, ISF: 40→33")
                == Decimal(string: "1.2")
        )
        #expect(TherapySettingsAnalyzer.basalScaleRatio(from: "Basal ratio: ; setting 1.32U/hr.") == nil)
        #expect(TherapySettingsAnalyzer.basalScaleRatio(from: "no recorded scale") == nil)
    }

    @Test("Basal uses enacted / recorded TDD ratio and does not copy Adjust Basal into the profile")
    func basalNotCopiedFromTddRatio() {
        let loops = (1 ... 60).map { index in
            loop(
                day: 2 + (index / 24),
                hour: index % 24,
                requestedRate: 1.2,
                reason: "Dynamic ISF: On, Sigmoid function, Basal ratio: 1.2; setting 1.2U/hr."
            )
        }
        let result = report(loops: loops)
        #expect(result.medianTddRatio == Decimal(string: "1.2"))
        #expect(result.basalRows[0].current == 1)
        #expect(result.basalRows[0].suggested == 1)
        #expect(result.basalRows[0].hasChange == false)
        if case let .basalMatchesTddAdjusted(ratio, count) = result.basalRows[0].rationale {
            #expect(ratio == Decimal(string: "1.2"))
            #expect(count == 60)
        } else {
            Issue.record("Expected TDD-adjusted match rationale, got \(result.basalRows[0].rationale)")
        }
    }

    @Test("Basal suggestion is the median enacted/TDD-ratio, not a half-step guess")
    func basalRaisesFromRecordedRates() {
        let loops = (0 ..< 50).map { index in
            loop(
                day: 3,
                hour: min(index, 23),
                requestedRate: 1.32,
                reason: "Dynamic ISF: On, Sigmoid function, Basal ratio: 1.2; setting 1.32U/hr."
            )
        }
        let result = report(loops: loops)
        // 1.32 / 1.2 = 1.10 — the recorded implied profile rate
        #expect(result.basalRows[0].suggested == Decimal(string: "1.10"))
        if case let .basalImplied(medianRate, tddRatio, count) = result.basalRows[0].rationale {
            #expect(medianRate == Decimal(string: "1.1"))
            #expect(tddRatio == Decimal(string: "1.2"))
            #expect(count == 50)
        } else {
            Issue.record("Expected implied basal rationale, got \(result.basalRows[0].rationale)")
        }
    }

    @Test("Unreadable Basal ratio token is skipped rather than treated as 1")
    func basalSkipsBrokenTddRatioToken() {
        let loops = (0 ..< 40).map { index in
            loop(
                day: 4,
                hour: min(index, 23),
                requestedRate: 1.32,
                reason: "Dynamic ISF: On, Sigmoid function, Basal ratio: ; setting 1.32U/hr."
            )
        }
        let result = report(loops: loops)
        #expect(result.basalRows[0].sampleCount == 0)
        #expect(result.basalRows[0].suggested == 1)
        #expect(result.basalRows[0].rationale == .insufficientEvidence)
    }

    @Test("Loops with no recorded basal scale are skipped")
    func basalSkipsMissingScale() {
        let loops = (0 ..< 40).map { index in
            loop(
                day: 4,
                hour: min(index, 23),
                requestedRate: 1.32,
                reason: "setting 1.32U/hr."
            )
        }
        let result = report(loops: loops)
        #expect(result.basalRows[0].sampleCount == 0)
        #expect(result.basalRows[0].suggested == 1)
    }

    @Test("A slot with no recorded TDD ratio does not borrow one from other slots")
    func basalDoesNotBorrowTddRatioAcrossSlots() {
        let morningProfile = TherapyProfileSnapshot(
            basal: [
                BasalProfileEntry(start: "00:00", minutes: 0, rate: 1.0),
                BasalProfileEntry(start: "12:00", minutes: 720, rate: 1.0)
            ],
            isf: [InsulinSensitivityEntry(sensitivity: 40, offset: 0, start: "00:00")],
            carbRatios: CarbRatios(units: .grams, schedule: [CarbRatioEntry(start: "00:00", offset: 0, ratio: 8)]),
            units: .mgdL,
            basalIncrement: Decimal(string: "0.05") ?? 0.05
        )
        var loops: [TherapyLoopSample] = []
        for day in 2 ... 9 {
            // Morning: Adjust Basal on and recording a ratio.
            for hour in 0 ..< 12 {
                loops.append(
                    loop(
                        day: day,
                        hour: hour,
                        requestedRate: Decimal(string: "1.2") ?? 1.2,
                        reason: "Dynamic ISF: On, Sigmoid function, Basal ratio: 1.2; setting 1.2U/hr."
                    )
                )
            }
            // Afternoon: Adjust Basal off, so no ratio was ever recorded for this slot.
            for hour in 12 ..< 24 {
                loops.append(
                    loop(
                        day: day,
                        hour: hour,
                        requestedRate: 1.0,
                        reason: "Dynamic ISF: On, Sigmoid function; setting 1.0U/hr."
                    )
                )
            }
        }
        let result = TherapySettingsAnalyzer.generate(
            from: TherapySettingsInput(
                lookbackDays: 14,
                now: date(day: 15, hour: 12),
                calendar: calendar,
                profile: morningProfile,
                loops: loops,
                glucose: [],
                carbs: [],
                boluses: [],
                excludedWindows: [],
                overrideHistoryRetentionDays: OverrideRunStored.historyRetentionDays
            )
        )
        #expect(result.medianTddRatio == Decimal(string: "1.2"))
        if case .basalMatchesTddAdjusted = result.basalRows[0].rationale {} else {
            Issue.record("Expected the morning slot to credit its own recorded ratio")
        }
        // The afternoon slot recorded no ratio, so it must not claim one.
        if case let .basalMatchesTddAdjusted(ratio, _) = result.basalRows[1].rationale {
            Issue.record("Afternoon slot claimed an unrecorded TDD ratio of \(ratio)")
        }
    }

    @Test("Determinations without an enacted rate still count as ISF context")
    func isfUsesLoopsWithoutEnactedRate() {
        var loops: [TherapyLoopSample] = []
        var glucose: [TherapyGlucoseReading] = []
        var boluses: [TherapyBolus] = []
        for day in 2 ... 9 {
            let start = date(day: day, hour: 8)
            loops.append(
                loop(day: day, hour: 8, cob: 0, requestedRate: nil, sensitivityRatio: 1.0)
            )
            boluses.append(TherapyBolus(date: start, amount: 1, isSMB: true, isExternal: false))
            glucose.append(TherapyGlucoseReading(date: start, glucose: 150))
            glucose.append(TherapyGlucoseReading(date: start.addingTimeInterval(3.5 * 3600), glucose: 100))
        }
        let result = report(loops: loops, glucose: glucose, boluses: boluses)
        #expect(result.isfRows[0].sampleCount == 8)
        #expect(result.isfRows[0].suggested == 50)
        // No enacted rate anywhere, so basal has no evidence of its own.
        #expect(result.basalRows[0].sampleCount == 0)
    }

    @Test("A small hypo treatment disqualifies a carb-free ISF correction")
    func isfRejectsAnyCarbsInWindow() {
        var loops: [TherapyLoopSample] = []
        var glucose: [TherapyGlucoseReading] = []
        var boluses: [TherapyBolus] = []
        var carbs: [TherapyCarbEntry] = []
        for day in 2 ... 9 {
            let start = date(day: day, hour: 8)
            loops.append(loop(day: day, hour: 8, cob: 0, sensitivityRatio: 1.0))
            boluses.append(TherapyBolus(date: start, amount: 1, isSMB: true, isExternal: false))
            glucose.append(TherapyGlucoseReading(date: start, glucose: 150))
            glucose.append(TherapyGlucoseReading(date: start.addingTimeInterval(3.5 * 3600), glucose: 100))
            // 6 g is below the meal threshold but still raises glucose.
            carbs.append(TherapyCarbEntry(date: start.addingTimeInterval(3600), carbs: 6, isFPU: false))
        }
        let result = report(loops: loops, glucose: glucose, carbs: carbs, boluses: boluses)
        #expect(result.isfRows[0].sampleCount == 0)
        #expect(result.isfRows[0].rationale == .insufficientEvidence)
    }

    @Test("Another bolus inside the window disqualifies an ISF correction")
    func isfRejectsOtherInsulinInWindow() {
        var loops: [TherapyLoopSample] = []
        var glucose: [TherapyGlucoseReading] = []
        var boluses: [TherapyBolus] = []
        for day in 2 ... 9 {
            let start = date(day: day, hour: 8)
            loops.append(loop(day: day, hour: 8, cob: 0, sensitivityRatio: 1.0))
            boluses.append(TherapyBolus(date: start, amount: 1, isSMB: true, isExternal: false))
            // 90 minutes later: lands inside the 3-4h drop but outside the 30-minute divisor.
            boluses.append(
                TherapyBolus(date: start.addingTimeInterval(90 * 60), amount: 1, isSMB: true, isExternal: false)
            )
            glucose.append(TherapyGlucoseReading(date: start, glucose: 150))
            glucose.append(TherapyGlucoseReading(date: start.addingTimeInterval(3.5 * 3600), glucose: 100))
        }
        let result = report(loops: loops, glucose: glucose, boluses: boluses)
        #expect(result.isfRows[0].sampleCount == 0)
        #expect(result.isfRows[0].rationale == .insufficientEvidence)
    }

    @Test("Sitting high with no correction insulin is not an ISF recommendation")
    func isfDoesNotInventFromGlucoseAlone() {
        let loops = (0 ..< 30).map { index in
            loop(
                day: 5,
                hour: index % 24,
                sensitivityRatio: 1.0
            )
        }
        let result = report(loops: loops)
        #expect(result.isfRows[0].sampleCount == 0)
        #expect(result.isfRows[0].suggested == 40)
        #expect(result.isfRows[0].rationale == .insufficientEvidence)
    }

    @Test("High-BG sigmoid loops are not used as profile ISF evidence")
    func isfIgnoresHighGlucoseSigmoid() {
        let loops = (0 ..< 8).map { day in
            loop(
                day: 4 + day,
                hour: 8,
                sensitivityRatio: 1.3
            )
        }
        let boluses = (0 ..< 8).map { day in
            TherapyBolus(date: date(day: 4 + day, hour: 8), amount: 1, isSMB: true, isExternal: false)
        }
        var glucose: [TherapyGlucoseReading] = []
        for day in 4 ..< 12 {
            let start = date(day: day, hour: 8)
            glucose.append(TherapyGlucoseReading(date: start, glucose: 180))
            glucose.append(TherapyGlucoseReading(date: start.addingTimeInterval(3.5 * 3600), glucose: 120))
        }
        let result = report(loops: loops, glucose: glucose, boluses: boluses)
        #expect(result.isfRows[0].sampleCount == 0)
        #expect(result.isfRows[0].rationale == .insufficientEvidence)
    }

    @Test("ISF suggestion is glucose drop / recorded insulin from carb-free near-target corrections")
    func isfFromRecordedCorrections() {
        var loops: [TherapyLoopSample] = []
        var glucose: [TherapyGlucoseReading] = []
        var boluses: [TherapyBolus] = []
        for day in 2 ... 9 {
            let start = date(day: day, hour: 8)
            loops.append(
                loop(day: day, hour: 8, cob: 0, sensitivityRatio: 1.0)
            )
            boluses.append(TherapyBolus(date: start, amount: 1, isSMB: true, isExternal: false))
            glucose.append(TherapyGlucoseReading(date: start, glucose: 150))
            glucose.append(TherapyGlucoseReading(date: start.addingTimeInterval(3.5 * 3600), glucose: 100))
        }
        let result = report(loops: loops, glucose: glucose, boluses: boluses)
        // (150-100) / 1.0 U = 50
        #expect(result.isfRows[0].suggested == 50)
        if case let .isfObserved(medianISF, medianDelta, medianInsulin, count) = result.isfRows[0].rationale {
            #expect(medianISF == 50)
            #expect(medianDelta == 50)
            #expect(medianInsulin == 1)
            #expect(count == 8)
        } else {
            Issue.record("Expected observed ISF rationale, got \(result.isfRows[0].rationale)")
        }
    }

    @Test("ISF does not assume a missing sigmoid ratio is 1")
    func isfRequiresRecordedSensitivityRatio() {
        var loops: [TherapyLoopSample] = []
        var glucose: [TherapyGlucoseReading] = []
        var boluses: [TherapyBolus] = []
        for day in 2 ... 9 {
            let start = date(day: day, hour: 8)
            loops.append(
                loop(day: day, hour: 8, cob: 0, sensitivityRatio: nil)
            )
            boluses.append(TherapyBolus(date: start, amount: 1, isSMB: true, isExternal: false))
            glucose.append(TherapyGlucoseReading(date: start, glucose: 150))
            glucose.append(TherapyGlucoseReading(date: start.addingTimeInterval(3.5 * 3600), glucose: 100))
        }
        let result = report(loops: loops, glucose: glucose, boluses: boluses)
        #expect(result.isfRows[0].sampleCount == 0)
        #expect(result.isfRows[0].suggested == 40)
        #expect(result.isfRows[0].rationale == .insufficientEvidence)
    }

    @Test("CR 8 recommends 7.8 from recorded carbs, insulin, 4h glucose, and recorded ISF")
    func carbRatioFromRecordedMealInsulin() {
        var carbs: [TherapyCarbEntry] = []
        var glucose: [TherapyGlucoseReading] = []
        var loops: [TherapyLoopSample] = []
        var boluses: [TherapyBolus] = []
        for day in 2 ... 9 {
            let meal = date(day: day, hour: 18)
            carbs.append(TherapyCarbEntry(date: meal, carbs: 60, isFPU: false))
            glucose.append(TherapyGlucoseReading(date: meal, glucose: 100))
            glucose.append(TherapyGlucoseReading(date: meal.addingTimeInterval(3.5 * 3600), glucose: 110))
            loops.append(
                loop(
                    day: day,
                    hour: 18,
                    insulinSensitivity: 50
                )
            )
            boluses.append(TherapyBolus(date: meal, amount: Decimal(string: "7.5") ?? 7.5, isSMB: false, isExternal: false))
        }
        let result = report(loops: loops, glucose: glucose, carbs: carbs, boluses: boluses)
        // leftover = 10 mg/dL / 50 ISF = 0.2 U; CR = 60 / (7.5 + 0.2) ≈ 7.79 → 7.8
        #expect(result.crRows[0].current == 8)
        #expect(result.crRows[0].suggested == Decimal(string: "7.8"))
        if case let .crObserved(medianCR, medianCarbs, _, _, count) = result.crRows[0].rationale {
            #expect(medianCarbs == 60)
            #expect(count == 8)
            #expect(abs(medianCR - Decimal(string: "7.7922")!) < Decimal(string: "0.01")!)
        } else {
            Issue.record("Expected observed CR rationale, got \(result.crRows[0].rationale)")
        }
    }

    @Test("Meals missing 4h glucose or insulin are skipped rather than filled in")
    func crSkipsIncompleteMeals() {
        let meal = date(day: 3, hour: 18)
        let result = report(
            loops: [loop(day: 3, hour: 18, insulinSensitivity: 40)],
            glucose: [TherapyGlucoseReading(date: meal, glucose: 100)],
            carbs: [TherapyCarbEntry(date: meal, carbs: 60, isFPU: false)],
            boluses: []
        )
        #expect(result.crRows[0].sampleCount == 0)
        #expect(result.crRows[0].suggested == 8)
        #expect(result.crRows[0].rationale == .insufficientEvidence)
    }

    @Test("CR measures the residual against the pre-meal glucose, not the target")
    func crUsesStartingGlucoseNotTarget() {
        var carbs: [TherapyCarbEntry] = []
        var glucose: [TherapyGlucoseReading] = []
        var loops: [TherapyLoopSample] = []
        var boluses: [TherapyBolus] = []
        for day in 2 ... 9 {
            let meal = date(day: day, hour: 18)
            carbs.append(TherapyCarbEntry(date: meal, carbs: 60, isFPU: false))
            // Starts 80 mg/dL above target and returns to exactly where it started: the meal was
            // fully covered by the recorded bolus, so CR must come out at the profile value.
            glucose.append(TherapyGlucoseReading(date: meal, glucose: 180))
            glucose.append(TherapyGlucoseReading(date: meal.addingTimeInterval(3.5 * 3600), glucose: 180))
            boluses.append(
                TherapyBolus(date: meal, amount: Decimal(string: "7.5") ?? 7.5, isSMB: false, isExternal: false)
            )
            loops.append(loop(day: day, hour: 18, insulinSensitivity: 50))
        }
        let result = report(loops: loops, glucose: glucose, carbs: carbs, boluses: boluses)
        // 60 g / 7.5 U = 8 g/U. Measuring against the 100 target instead would charge the meal
        // 80/50 = 1.6 U it did not need and report 60 / 9.1 ≈ 6.6 g/U.
        #expect(result.crSampleCount == 8)
        #expect(result.crRows[0].suggested == 8)
        if case let .crObserved(medianCR, _, medianInsulin, _, _) = result.crRows[0].rationale {
            #expect(medianCR == 8)
            #expect(medianInsulin == Decimal(string: "7.5"))
        } else {
            Issue.record("Expected observed CR rationale, got \(result.crRows[0].rationale)")
        }
    }

    @Test("Meals covered by an external bolus are not carb ratio evidence")
    func crSkipsExternalInsulin() {
        var carbs: [TherapyCarbEntry] = []
        var glucose: [TherapyGlucoseReading] = []
        var loops: [TherapyLoopSample] = []
        var boluses: [TherapyBolus] = []
        for day in 2 ... 9 {
            let meal = date(day: day, hour: 18)
            carbs.append(TherapyCarbEntry(date: meal, carbs: 60, isFPU: false))
            glucose.append(TherapyGlucoseReading(date: meal, glucose: 100))
            glucose.append(TherapyGlucoseReading(date: meal.addingTimeInterval(3.5 * 3600), glucose: 110))
            boluses.append(
                TherapyBolus(date: meal, amount: Decimal(string: "7.5") ?? 7.5, isSMB: false, isExternal: false)
            )
            boluses.append(TherapyBolus(date: meal, amount: 2, isSMB: false, isExternal: true))
            loops.append(loop(day: day, hour: 18, insulinSensitivity: 50))
        }
        let result = report(loops: loops, glucose: glucose, carbs: carbs, boluses: boluses)
        #expect(result.crSampleCount == 0)
        #expect(result.crRows[0].rationale == .insufficientEvidence)
    }

    @Test("CR leftover is skipped when recorded ISF is missing")
    func crRequiresRecordedISFWhenGlucoseRemains() {
        let meal = date(day: 3, hour: 18)
        let result = report(
            loops: [loop(day: 3, hour: 18, insulinSensitivity: nil)],
            glucose: [
                TherapyGlucoseReading(date: meal, glucose: 100),
                TherapyGlucoseReading(date: meal.addingTimeInterval(3.5 * 3600), glucose: 110)
            ],
            carbs: [TherapyCarbEntry(date: meal, carbs: 60, isFPU: false)],
            boluses: [TherapyBolus(date: meal, amount: Decimal(string: "7.5") ?? 7.5, isSMB: false, isExternal: false)]
        )
        #expect(result.crRows[0].sampleCount == 0)
        #expect(result.crRows[0].suggested == 8)
        #expect(result.crRows[0].rationale == .insufficientEvidence)
    }

    @Test("A meal following an earlier meal within 4h is not treated as isolated")
    func crIsolationLooksBackwards() {
        var carbs: [TherapyCarbEntry] = []
        var glucose: [TherapyGlucoseReading] = []
        var loops: [TherapyLoopSample] = []
        var boluses: [TherapyBolus] = []
        for day in 2 ... 9 {
            let first = date(day: day, hour: 17)
            let second = date(day: day, hour: 18)
            carbs.append(TherapyCarbEntry(date: first, carbs: 40, isFPU: false))
            carbs.append(TherapyCarbEntry(date: second, carbs: 60, isFPU: false))
            for meal in [first, second] {
                glucose.append(TherapyGlucoseReading(date: meal, glucose: 100))
                glucose.append(TherapyGlucoseReading(date: meal.addingTimeInterval(3.5 * 3600), glucose: 110))
                boluses.append(
                    TherapyBolus(date: meal, amount: Decimal(string: "7.5") ?? 7.5, isSMB: false, isExternal: false)
                )
            }
            loops.append(loop(day: day, hour: 17, insulinSensitivity: 50))
            loops.append(loop(day: day, hour: 18, insulinSensitivity: 50))
        }
        let result = report(loops: loops, glucose: glucose, carbs: carbs, boluses: boluses)
        #expect(result.crSampleCount == 0)
        #expect(result.crRows[0].suggested == 8)
        #expect(result.crRows[0].rationale == .insufficientEvidence)
    }

    @Test("An FPU entry logged with the meal disqualifies it as a carb ratio sample")
    func crSkipsMealsWithFPUs() {
        var carbs: [TherapyCarbEntry] = []
        var glucose: [TherapyGlucoseReading] = []
        var loops: [TherapyLoopSample] = []
        var boluses: [TherapyBolus] = []
        for day in 2 ... 9 {
            let meal = date(day: day, hour: 18)
            carbs.append(TherapyCarbEntry(date: meal, carbs: 60, isFPU: false))
            // Trio logs fat/protein units alongside the meal; they keep absorbing past 4h.
            carbs.append(TherapyCarbEntry(date: meal, carbs: 12, isFPU: true))
            glucose.append(TherapyGlucoseReading(date: meal, glucose: 100))
            glucose.append(TherapyGlucoseReading(date: meal.addingTimeInterval(3.5 * 3600), glucose: 110))
            boluses.append(
                TherapyBolus(date: meal, amount: Decimal(string: "7.5") ?? 7.5, isSMB: false, isExternal: false)
            )
            loops.append(loop(day: day, hour: 18, insulinSensitivity: 50))
        }
        let result = report(loops: loops, glucose: glucose, carbs: carbs, boluses: boluses)
        #expect(result.crSampleCount == 0)
        #expect(result.crRows[0].rationale == .insufficientEvidence)
    }

    @Test("Unannounced-meal stretches without logged carbs are ignored for CR")
    func crIgnoresUnloggedMeals() {
        let result = report(
            loops: [loop(day: 6, hour: 18, sensitivityRatio: 1.2)],
            boluses: [TherapyBolus(date: date(day: 6, hour: 18), amount: 1.2, isSMB: true, isExternal: false)]
        )
        #expect(result.crRows[0].sampleCount == 0)
        #expect(result.crRows[0].suggested == 8)
    }

    @Test("Loops inside override windows are dropped")
    func excludesOverrideWindows() {
        let loops = (0 ..< 20).map { index in
            loop(
                day: 7,
                hour: index % 24,
                requestedRate: 2.0,
                reason: "Basal ratio: 1.0; setting 2.0U/hr."
            )
        }
        let window = DateInterval(start: date(day: 7, hour: 0), end: date(day: 8, hour: 0))
        let result = report(loops: loops, excludedWindows: [window])
        #expect(result.usableLoopCount == 0)
        #expect(result.basalRows[0].sampleCount == 0)
    }

    @Test("High-confidence family prefers basal, then ISF, then CR")
    func isolationOrder() {
        var loops: [TherapyLoopSample] = []
        for day in 1 ... 10 {
            for hour in 0 ..< 24 where hour != 8 && hour != 18 {
                loops.append(
                    loop(
                        day: day,
                        hour: hour,
                        reason: "Basal ratio: 1.0; setting 1.0U/hr."
                    )
                )
            }
        }

        var glucose: [TherapyGlucoseReading] = []
        var boluses: [TherapyBolus] = []
        var carbs: [TherapyCarbEntry] = []
        for day in 2 ... 9 {
            let correction = date(day: day, hour: 8)
            loops.append(loop(day: day, hour: 8, cob: 0, sensitivityRatio: 1.0))
            boluses.append(TherapyBolus(date: correction, amount: 1, isSMB: true, isExternal: false))
            glucose.append(TherapyGlucoseReading(date: correction, glucose: 150))
            glucose.append(TherapyGlucoseReading(date: correction.addingTimeInterval(3.5 * 3600), glucose: 100))

            let meal = date(day: day, hour: 18)
            loops.append(
                loop(
                    day: day,
                    hour: 18,
                    insulinSensitivity: 50
                )
            )
            carbs.append(TherapyCarbEntry(date: meal, carbs: 60, isFPU: false))
            glucose.append(TherapyGlucoseReading(date: meal, glucose: 100))
            glucose.append(TherapyGlucoseReading(date: meal.addingTimeInterval(3.5 * 3600), glucose: 110))
            boluses.append(
                TherapyBolus(date: meal, amount: Decimal(string: "7.5") ?? 7.5, isSMB: false, isExternal: false)
            )
        }

        let result = report(loops: loops, glucose: glucose, carbs: carbs, boluses: boluses)
        #expect(result.basalRows[0].hasChange == false)
        #expect(result.isfRows[0].hasChange)
        #expect(result.isfRows[0].confidence == .high)
        #expect(result.crRows[0].hasChange)
        #expect(result.highConfidenceFamilyToChange == .isf)
    }

    @Test("Rounding snaps to the pump increment, including down to zero")
    func roundBasalIncrement() {
        #expect(
            TherapySettingsAnalyzer.roundToIncrement(Decimal(string: "1.03") ?? 0, increment: 0.05)
                == Decimal(string: "1.05")
        )
        // Rounding alone does reach 0; `makeRow`'s floor is what keeps it out of a suggestion,
        // which `basalBelowIncrementKeepsCurrentAndSaysSo` covers.
        #expect(TherapySettingsAnalyzer.roundToIncrement(0.02, increment: 0.05) == 0)
    }

    // MARK: - Basal evidence set

    @Test("A recorded agreement with the profile rate is read as evidence, not discarded")
    func basalReadsNeutralAndZeroTempDecisions() {
        // With skipNeutralTemps on, "the profile rate is right" is written as rate 0 / duration 0,
        // and a real zero temp as rate 0 / duration > 0. Neither may be dropped.
        #expect(
            TherapySettingsAnalyzer.basalEvidence(
                reason: "Suggested rate is same as profile rate, a temp basal is active, canceling current temp",
                rate: 0,
                duration: 0
            ) == .matchesProfile
        )
        #expect(
            TherapySettingsAnalyzer.basalEvidence(
                reason: "Suggested rate is same as profile rate, no temp basal is active, doing nothing",
                rate: nil,
                duration: nil
            ) == .matchesProfile
        )
        #expect(
            TherapySettingsAnalyzer.basalEvidence(
                reason: ". Setting neutral temp basal of 1.1U/hr",
                rate: Decimal(string: "1.1"),
                duration: 30
            ) == .matchesProfile
        )
        #expect(
            TherapySettingsAnalyzer.basalEvidence(
                reason: " 25m left and 1.2 ~ req 1.25U/hr: no temp required",
                rate: nil,
                duration: nil
            ) == .requested(Decimal(string: "1.25") ?? 1.25)
        )
        #expect(
            TherapySettingsAnalyzer.basalEvidence(reason: "setting 0U/hr.", rate: 0, duration: 30) == .zeroTemp
        )
        // A bare cancel never recorded the rate it wanted.
        #expect(TherapySettingsAnalyzer.basalEvidence(reason: "setting 0U/hr.", rate: 0, duration: 0) == nil)
        #expect(TherapySettingsAnalyzer.basalEvidence(reason: "no rate here", rate: nil, duration: nil) == nil)
    }

    @Test("Zero temps count against the basal rate instead of being filtered out")
    func basalCountsZeroTemps() {
        // Half the loops wanted the profile rate, half wanted nothing at all. Reading only
        // positive rates would leave no evidence at all and report the profile as confirmed.
        var loops: [TherapyLoopSample] = []
        for day in 2 ... 9 {
            for hour in 0 ..< 24 {
                let wantsZero = hour.isMultiple(of: 2)
                loops.append(
                    loop(
                        day: day,
                        hour: hour,
                        requestedRate: 0,
                        duration: wantsZero ? 30 : 0,
                        reason: wantsZero
                            ? "Basal ratio: 1.0; setting 0U/hr."
                            : "Basal ratio: 1.0. Suggested rate is same as profile rate, a temp basal is active, canceling current temp"
                    )
                )
            }
        }
        let result = report(loops: loops)
        #expect(result.basalRows[0].sampleCount == 192)
        // Median of {0 …, 1.0 …} split evenly is 0.5, which is a real downward signal.
        if case let .basalImplied(medianRate, _, _) = result.basalRows[0].rationale {
            #expect(medianRate == Decimal(string: "0.5"))
        } else {
            Issue.record("Expected implied basal rationale, got \(result.basalRows[0].rationale)")
        }
        #expect(result.basalRows[0].suggested == Decimal(string: "0.5"))
    }

    @Test("Evidence below the pump increment keeps the current rate and says why")
    func basalBelowIncrementKeepsCurrentAndSaysSo() {
        let loops = (2 ... 9).flatMap { day in
            (0 ..< 24).map { hour in
                loop(day: day, hour: hour, requestedRate: 0, duration: 30, reason: "Basal ratio: 1.0; setting 0U/hr.")
            }
        }
        let result = report(loops: loops)
        #expect(result.basalRows[0].suggested == 1)
        #expect(result.basalRows[0].hasChange == false)
        // Must not read as agreement: the evidence pointed below what can be suggested.
        if case let .belowSafetyFloor(medianImplied, floor) = result.basalRows[0].rationale {
            #expect(medianImplied == 0)
            #expect(floor == Decimal(string: "0.05"))
        } else {
            Issue.record("Expected a safety-floor rationale, got \(result.basalRows[0].rationale)")
        }
    }

    @Test("A slot mixing loops with and without a recorded TDD ratio claims no ratio")
    func basalWithholdsTddRatioFromMixedSlot() {
        var loops: [TherapyLoopSample] = []
        for day in 2 ... 9 {
            for hour in 0 ..< 24 {
                let recordsRatio = hour < 12
                loops.append(
                    loop(
                        day: day,
                        hour: hour,
                        requestedRate: Decimal(string: "1.2") ?? 1.2,
                        reason: recordsRatio
                            ? "Dynamic ISF: On, Sigmoid function, Basal ratio: 1.2; setting 1.2U/hr."
                            : "Autosens ratio: 1.2, ISF: 40→33"
                    )
                )
            }
        }
        let result = report(loops: loops)
        // Every loop implies 1.0, so the row agrees with the profile — but only half recorded a
        // ratio, so the TDD wording would attribute one to samples that never had it.
        #expect(result.basalRows[0].rationale == .roundedToUnchanged(medianImplied: 1))
    }

    // MARK: - ISF and CR contamination

    @Test("An external dose in the window disqualifies an ISF correction")
    func isfSeesExternalInsulinAsContamination() {
        var loops: [TherapyLoopSample] = []
        var glucose: [TherapyGlucoseReading] = []
        var boluses: [TherapyBolus] = []
        for day in 2 ... 9 {
            let start = date(day: day, hour: 8)
            loops.append(loop(day: day, hour: 8, cob: 0, sensitivityRatio: 1.0))
            boluses.append(TherapyBolus(date: start, amount: 1, isSMB: true, isExternal: false))
            // An injected dose the report will not measure, but which still moved glucose.
            boluses.append(
                TherapyBolus(date: start.addingTimeInterval(90 * 60), amount: 2, isSMB: false, isExternal: true)
            )
            glucose.append(TherapyGlucoseReading(date: start, glucose: 150))
            glucose.append(TherapyGlucoseReading(date: start.addingTimeInterval(3.5 * 3600), glucose: 100))
        }
        let result = report(loops: loops, glucose: glucose, boluses: boluses)
        #expect(result.isfRows[0].sampleCount == 0)
        #expect(result.isfRows[0].rationale == .insufficientEvidence)
    }

    @Test("An override starting inside the outcome window disqualifies the sample")
    func isfExcludesOverrideOverlappingTheWindow() {
        var loops: [TherapyLoopSample] = []
        var glucose: [TherapyGlucoseReading] = []
        var boluses: [TherapyBolus] = []
        var windows: [DateInterval] = []
        for day in 2 ... 9 {
            let start = date(day: day, hour: 8)
            loops.append(loop(day: day, hour: 8, cob: 0, sensitivityRatio: 1.0))
            boluses.append(TherapyBolus(date: start, amount: 1, isSMB: true, isExternal: false))
            glucose.append(TherapyGlucoseReading(date: start, glucose: 150))
            glucose.append(TherapyGlucoseReading(date: start.addingTimeInterval(3.5 * 3600), glucose: 100))
            // Begins an hour after the dose: the instant of the dose is clean, the drop is not.
            windows.append(
                DateInterval(start: start.addingTimeInterval(3600), end: start.addingTimeInterval(5 * 3600))
            )
        }
        let result = report(loops: loops, glucose: glucose, boluses: boluses, excludedWindows: windows)
        #expect(result.isfRows[0].sampleCount == 0)
    }

    @Test("A pre-bolus counts as meal insulin rather than inflating the carb ratio")
    func crCountsPreBolusAsMealInsulin() {
        var carbs: [TherapyCarbEntry] = []
        var glucose: [TherapyGlucoseReading] = []
        var loops: [TherapyLoopSample] = []
        var boluses: [TherapyBolus] = []
        for day in 2 ... 9 {
            let meal = date(day: day, hour: 18)
            carbs.append(TherapyCarbEntry(date: meal, carbs: 60, isFPU: false))
            glucose.append(TherapyGlucoseReading(date: meal, glucose: 100))
            glucose.append(TherapyGlucoseReading(date: meal.addingTimeInterval(3.5 * 3600), glucose: 100))
            // Dosed 20 minutes ahead of the entry, as a pre-bolus normally is.
            boluses.append(
                TherapyBolus(
                    date: meal.addingTimeInterval(-20 * 60),
                    amount: Decimal(string: "7.5") ?? 7.5,
                    isSMB: false,
                    isExternal: false
                )
            )
            loops.append(loop(day: day, hour: 18, insulinSensitivity: 50))
        }
        let result = report(loops: loops, glucose: glucose, carbs: carbs, boluses: boluses)
        // 60 g / 7.5 U = 8 g/U. Ignoring the pre-bolus would leave no meal insulin at all.
        #expect(result.crSampleCount == 8)
        #expect(result.crRows[0].suggested == 8)
    }

    @Test("A correction still acting before the meal disqualifies it as carb ratio evidence")
    func crSkipsMealsFollowingAnEarlierCorrection() {
        var carbs: [TherapyCarbEntry] = []
        var glucose: [TherapyGlucoseReading] = []
        var loops: [TherapyLoopSample] = []
        var boluses: [TherapyBolus] = []
        for day in 2 ... 9 {
            let meal = date(day: day, hour: 18)
            carbs.append(TherapyCarbEntry(date: meal, carbs: 60, isFPU: false))
            glucose.append(TherapyGlucoseReading(date: meal, glucose: 100))
            glucose.append(TherapyGlucoseReading(date: meal.addingTimeInterval(3.5 * 3600), glucose: 110))
            boluses.append(
                TherapyBolus(date: meal, amount: Decimal(string: "7.5") ?? 7.5, isSMB: false, isExternal: false)
            )
            // 90 minutes before the meal: too old to be meal insulin, too recent to ignore.
            boluses.append(
                TherapyBolus(date: meal.addingTimeInterval(-90 * 60), amount: 2, isSMB: true, isExternal: false)
            )
            loops.append(loop(day: day, hour: 18, insulinSensitivity: 50))
        }
        let result = report(loops: loops, glucose: glucose, carbs: carbs, boluses: boluses)
        #expect(result.crSampleCount == 0)
        #expect(result.crRows[0].rationale == .insufficientEvidence)
    }

    @Test("Completed override runs are kept at least as long as the longest report lookback")
    func overrideRetentionCoversEveryLookback() {
        // The report can only exclude overridden loops while their run records still exist. If this
        // fails, the store is dropping override history inside a window the report reads, and
        // adjusted loops are silently counted as ordinary evidence.
        //
        // Asserted against the run table on purpose. `OverrideStored` retention is read by
        // `NSPredicate.lastActiveOverride` on every loop cycle, so this report must not be a reason
        // to change it; the historical windows come from completed runs instead.
        let longestLookback = TherapyLookback.allCases.map(\.rawValue).max() ?? 0
        #expect(OverrideRunStored.historyRetentionDays >= longestLookback)

        for lookback in TherapyLookback.allCases {
            let result = TherapySettingsAnalyzer.generate(
                from: TherapySettingsInput(
                    lookbackDays: lookback.rawValue,
                    now: date(day: 15, hour: 12),
                    calendar: calendar,
                    profile: profile,
                    loops: [],
                    glucose: [],
                    carbs: [],
                    boluses: [],
                    excludedWindows: [],
                    overrideHistoryRetentionDays: OverrideRunStored.historyRetentionDays
                )
            )
            #expect(result.overrideHistoryIncomplete == false)
        }
    }

    @Test("A lookback outrunning override retention is disclosed rather than hidden")
    func reportDisclosesOverrideRetentionGap() {
        let result = TherapySettingsAnalyzer.generate(
            from: TherapySettingsInput(
                lookbackDays: 14,
                now: date(day: 15, hour: 12),
                calendar: calendar,
                profile: profile,
                loops: [],
                glucose: [],
                carbs: [],
                boluses: [],
                excludedWindows: [],
                overrideHistoryRetentionDays: 3
            )
        )
        #expect(result.overrideHistoryIncomplete)
        #expect(result.overrideHistoryRetentionDays == 3)
    }

    @Test("Rows in one family keep distinct identities across identical labels")
    func rowIdentityUsesSlotMinutes() {
        let result = report(loops: [loop(day: 3, hour: 1)])
        let ids = result.basalRows.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
