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
        sensitivityRatio: Decimal? = 1.0,
        insulinSensitivity: Decimal? = 40,
        reason: String = "Autosens ratio: 1, ISF: 40→40"
    ) -> TherapyLoopSample {
        TherapyLoopSample(
            date: date(day: day, hour: hour, minute: minute),
            cob: cob,
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
                overrideHistoryStart: date(day: 1, hour: 0)
            )
        )
    }

    @Test("A night of microboluses and the zero temps offsetting them yields no basal suggestion")
    func smbZeroTempsProduceNoBasalSuggestion() {
        // The report shipped a -83% basal suggestion from exactly this history. A rise before
        // midnight is corrected by boluses; oref writes each microbolus with the low or zero temp
        // that offsets it, then keeps zero-temping while the surplus works off. Read as basal
        // requests those rates say "almost no basal needed" during the hours that received the
        // most insulin. Nothing about this history identifies the profile rate, so no rate may be
        // suggested from it.
        var loops: [TherapyLoopSample] = []
        var boluses: [TherapyBolus] = []
        var glucose: [TherapyGlucoseReading] = []
        for day in 1 ... 14 {
            for slot in 0 ..< 12 {
                let minute = slot * 5
                loops.append(loop(
                    day: day,
                    hour: 0,
                    minute: minute,
                    reason: "Autosens ratio: 1, ISF: 40→40, Basal ratio: 0.99;"
                        + " insulinReq 0.84; setting 30m low temp of 0U/h. Microbolusing 0.4U. "
                ))
                boluses.append(TherapyBolus(
                    date: date(day: day, hour: 0, minute: minute),
                    amount: Decimal(string: "0.4") ?? 0.4,
                    isSMB: true,
                    isExternal: false
                ))
                glucose.append(TherapyGlucoseReading(
                    date: date(day: day, hour: 0, minute: minute),
                    glucose: 170
                ))
            }
        }

        let result = report(loops: loops, glucose: glucose, boluses: boluses)
        #expect(result.basalRows.isEmpty)
        #expect(result.basalUnavailable == .requestedRateIsNotBasalNeed)
        #expect(result.highConfidenceFamilyToChange != .basal)
    }

    @Test("Parses basal TDD ratio from determination reason") func parseBasalRatio() {
        let reason =
            "Autosens ratio: 1.15, ISF: 40→35, Dynamic ISF: On, Sigmoid function, AF: 0.5, Basal ratio: 1.12; setting 1.2U/hr."
        #expect(TherapySettingsAnalyzer.parseBasalTddRatio(from: reason) == Decimal(string: "1.12"))
        #expect(TherapySettingsAnalyzer.parseBasalTddRatio(from: "no ratio here") == nil)
    }

    @Test("A loop is ISF context on its recorded ratio alone, with no basal rows produced")
    func isfUsesLoopsWithoutEnactedRate() {
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
        #expect(result.isfRows[0].sampleCount == 8)
        #expect(result.isfRows[0].suggested == 50)
        #expect(result.basalRows.isEmpty)
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
                reason: "Basal ratio: 1.0; setting 2.0U/hr."
            )
        }
        let window = DateInterval(start: date(day: 7, hour: 0), end: date(day: 8, hour: 0))
        let result = report(loops: loops, excludedWindows: [window])
        #expect(result.usableLoopCount == 0)
        #expect(result.basalRows.isEmpty)
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

    private func report(lookbackDays: Int, overrideHistoryStart: Date?) -> TherapySettingsReport {
        TherapySettingsAnalyzer.generate(
            from: TherapySettingsInput(
                lookbackDays: lookbackDays,
                now: date(day: 15, hour: 12),
                calendar: calendar,
                profile: profile,
                loops: [],
                glucose: [],
                carbs: [],
                boluses: [],
                excludedWindows: [],
                overrideHistoryStart: overrideHistoryStart
            )
        )
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
            let result = report(lookbackDays: lookback.rawValue, overrideHistoryStart: date(day: 1, hour: 0))
            #expect(result.overrideHistoryIncomplete == false)
        }
    }

    @Test("A window opening before override history began is disclosed rather than hidden")
    func reportDisclosesOverrideRetentionGap() {
        // The state a freshly upgraded install is in: retention now says 90 days, but the records
        // only start at the upgrade. Judging coverage by the policy would call the fortnight before
        // it verified, so the boundary is compared against the window instead.
        let upgraded = date(day: 14, hour: 12)
        let result = report(lookbackDays: 14, overrideHistoryStart: upgraded)
        #expect(result.overrideHistoryIncomplete)
        #expect(result.overrideHistoryStart == upgraded)
    }

    @Test("Override coverage stops being flagged once the window sits inside recorded history")
    func overrideGapClosesAsHistoryAccumulates() {
        // The same install a fortnight later: the flag has to clear on its own, or the caveat
        // becomes permanent furniture that readers learn to ignore.
        let upgraded = date(day: 2, hour: 12)
        #expect(report(lookbackDays: 14, overrideHistoryStart: upgraded).overrideHistoryIncomplete)
        #expect(report(lookbackDays: 7, overrideHistoryStart: upgraded).overrideHistoryIncomplete == false)
    }

    @Test("Unknown override history is treated as no coverage, never as full coverage")
    func unknownOverrideHistoryIsTreatedAsIncomplete() {
        // Failing open here would silently present unverifiable loops as verified, so absence of a
        // boundary has to read as the pessimistic case.
        #expect(report(lookbackDays: 7, overrideHistoryStart: nil).overrideHistoryIncomplete)
    }

    @Test("Rows in one family keep distinct identities across identical labels")
    func rowIdentityUsesSlotMinutes() {
        let result = report(loops: [loop(day: 3, hour: 1)])
        let ids = result.isfRows.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
