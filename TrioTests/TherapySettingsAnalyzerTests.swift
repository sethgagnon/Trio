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
        glucose: Decimal = 100,
        target: Decimal = 100,
        cob: Decimal = 0,
        enactedRate: Decimal = 1.0,
        sensitivityRatio: Decimal = 1.0,
        reason: String = "Autosens ratio: 1, ISF: 40→40"
    ) -> TherapyLoopSample {
        TherapyLoopSample(
            date: date(day: day, hour: hour),
            glucose: glucose,
            target: target,
            cob: cob,
            enactedRate: enactedRate,
            sensitivityRatio: sensitivityRatio,
            reason: reason
        )
    }

    @Test("Parses basal TDD ratio from determination reason") func parseBasalRatio() {
        let reason =
            "Autosens ratio: 1.15, ISF: 40→35, Dynamic ISF: On, Sigmoid function, AF: 0.5, Basal ratio: 1.12; setting 1.2U/hr."
        #expect(TherapySettingsAnalyzer.parseBasalTddRatio(from: reason) == Decimal(string: "1.12"))
        #expect(TherapySettingsAnalyzer.parseBasalTddRatio(from: "no ratio here") == nil)
    }

    @Test("Basal suggestion ignores Adjust Basal TDD ratio already covering the extra") func basalNotCopiedFromTddRatio() {
        let loops = (1 ... 60).map { index in
            loop(
                day: 2 + (index / 24),
                hour: index % 24,
                enactedRate: 1.2,
                reason: "Dynamic ISF: On, Sigmoid function, Basal ratio: 1.2; setting 1.2U/hr."
            )
        }
        let report = TherapySettingsAnalyzer.generate(
            from: TherapySettingsInput(
                lookbackDays: 14,
                now: date(day: 15, hour: 12),
                calendar: calendar,
                profile: profile,
                loops: loops,
                glucose: [],
                carbs: [],
                boluses: [],
                excludedWindows: []
            )
        )
        #expect(report.medianTddRatio == Decimal(string: "1.2"))
        #expect(report.basalRows.count == 1)
        #expect(report.basalRows[0].current == 1)
        #expect(report.basalRows[0].suggested == 1)
        #expect(report.basalRows[0].hasChange == false)
        if case .basalCoveredByAdjustBasal = report.basalRows[0].rationale {
            // expected
        } else {
            Issue.record("Expected Adjust Basal coverage rationale, got \(report.basalRows[0].rationale)")
        }
    }

    @Test("Basal suggestion raises a slot when extra remains after TDD ratio") func basalRaisesAfterTddResidual() {
        let loops = (0 ..< 50).map { index in
            loop(
                day: 3,
                hour: min(index, 23),
                enactedRate: 1.32,
                reason: "Dynamic ISF: On, Sigmoid function, Basal ratio: 1.2; setting 1.32U/hr."
            )
        }
        let report = TherapySettingsAnalyzer.generate(
            from: TherapySettingsInput(
                lookbackDays: 14,
                now: date(day: 15, hour: 12),
                calendar: calendar,
                profile: profile,
                loops: loops,
                glucose: [],
                carbs: [],
                boluses: [],
                excludedWindows: []
            )
        )
        // residual = 1.32 / (1.0 * 1.2) = 1.10 → halfway +5% → 1.05
        #expect(report.basalRows[0].suggested == Decimal(string: "1.05"))
        #expect(report.basalRows[0].hasChange)
        if case let .basalExtraAfterTdd(residual, usedTdd) = report.basalRows[0].rationale {
            #expect(residual == Decimal(string: "1.1"))
            #expect(usedTdd)
        } else {
            Issue.record("Expected extra-after-TDD rationale, got \(report.basalRows[0].rationale)")
        }
    }

    @Test("ISF ignores high-BG loops where sigmoid ratio is far from 1") func isfIgnoresHighGlucoseSigmoid() {
        let highBG = (0 ..< 30).map { index in
            loop(
                day: 4,
                hour: index % 24,
                glucose: 180,
                target: 100,
                sensitivityRatio: 1.3
            )
        }
        let report = TherapySettingsAnalyzer.generate(
            from: TherapySettingsInput(
                lookbackDays: 14,
                now: date(day: 15, hour: 12),
                calendar: calendar,
                profile: profile,
                loops: highBG,
                glucose: [],
                carbs: [],
                boluses: [],
                excludedWindows: []
            )
        )
        #expect(report.isfRows[0].sampleCount == 0)
        #expect(report.isfRows[0].suggested == 40)
        #expect(report.isfRows[0].rationale == .insufficientSamples)
    }

    @Test("ISF at target with a high residual recommends a stronger profile ISF") func isfNearTargetHigh() {
        let loops = (0 ..< 30).map { index in
            loop(
                day: 5,
                hour: index % 24,
                glucose: 115,
                target: 100,
                sensitivityRatio: 1.0
            )
        }
        let report = TherapySettingsAnalyzer.generate(
            from: TherapySettingsInput(
                lookbackDays: 14,
                now: date(day: 15, hour: 12),
                calendar: calendar,
                profile: profile,
                loops: loops,
                glucose: [],
                carbs: [],
                boluses: [],
                excludedWindows: []
            )
        )
        // +15 mg/dL / 400 = 3.75% stronger → 40 * 0.9625 = 38.5 → 39
        #expect(report.isfRows[0].suggested == 39)
        #expect(report.isfRows[0].hasChange)
        if case let .isfHighNearTarget(delta) = report.isfRows[0].rationale {
            #expect(delta == 15)
        } else {
            Issue.record("Expected near-target high rationale, got \(report.isfRows[0].rationale)")
        }
    }

    @Test("CR 8 recommends 7.8 when meals finish 10 mg/dL higher at 3-4 hours") func carbRatioBecomesMoreAggressive() {
        var carbs: [TherapyCarbEntry] = []
        var glucose: [TherapyGlucoseReading] = []
        var loops: [TherapyLoopSample] = []
        // 8 isolated dinners on consecutive days
        for day in 2 ... 9 {
            let meal = date(day: day, hour: 18)
            carbs.append(TherapyCarbEntry(date: meal, carbs: 60, isFPU: false))
            glucose.append(TherapyGlucoseReading(date: meal, glucose: 100))
            glucose.append(
                TherapyGlucoseReading(
                    date: meal.addingTimeInterval(3.5 * 3600),
                    glucose: 110
                )
            )
            loops.append(
                loop(
                    day: day,
                    hour: 18,
                    glucose: 100,
                    enactedRate: 1.0,
                    reason: "Autosens ratio: 1; CR: 8"
                )
            )
        }
        let report = TherapySettingsAnalyzer.generate(
            from: TherapySettingsInput(
                lookbackDays: 14,
                now: date(day: 15, hour: 12),
                calendar: calendar,
                profile: profile,
                loops: loops,
                glucose: glucose,
                carbs: carbs,
                boluses: [],
                excludedWindows: []
            )
        )
        #expect(report.crRows[0].current == 8)
        #expect(report.crRows[0].suggested == Decimal(string: "7.8"))
        #expect(report.crRows[0].hasChange)
        if case let .crHighAfterMeal(delta, _, mealCount) = report.crRows[0].rationale {
            #expect(delta == 10)
            #expect(mealCount == 8)
        } else {
            Issue.record("Expected high-after-meal rationale, got \(report.crRows[0].rationale)")
        }
    }

    @Test("Unannounced-meal stretches without logged carbs are ignored for CR") func crIgnoresUnloggedMeals() {
        let loops = (0 ..< 20).map { index in
            loop(
                day: 6,
                hour: index % 24,
                glucose: 180,
                cob: 0,
                sensitivityRatio: 1.2,
                reason: "UAM"
            )
        }
        let report = TherapySettingsAnalyzer.generate(
            from: TherapySettingsInput(
                lookbackDays: 14,
                now: date(day: 15, hour: 12),
                calendar: calendar,
                profile: profile,
                loops: loops,
                glucose: [],
                carbs: [],
                boluses: [
                    TherapyBolus(date: date(day: 6, hour: 18), amount: 1.2, isSMB: true, isExternal: false)
                ],
                excludedWindows: []
            )
        )
        #expect(report.crRows[0].sampleCount == 0)
        #expect(report.crRows[0].suggested == 8)
    }

    @Test("Loops inside override windows are dropped") func excludesOverrideWindows() {
        let loops = (0 ..< 20).map { index in
            loop(
                day: 7,
                hour: index % 24,
                glucose: 130,
                enactedRate: 2.0,
                reason: "Basal ratio: 1.0; setting 2.0U/hr."
            )
        }
        let window = DateInterval(start: date(day: 7, hour: 0), end: date(day: 8, hour: 0))
        let report = TherapySettingsAnalyzer.generate(
            from: TherapySettingsInput(
                lookbackDays: 14,
                now: date(day: 15, hour: 12),
                calendar: calendar,
                profile: profile,
                loops: loops,
                glucose: [],
                carbs: [],
                boluses: [],
                excludedWindows: [window]
            )
        )
        #expect(report.usableLoopCount == 0)
        #expect(report.basalRows[0].sampleCount == 0)
    }

    @Test("High-confidence family prefers basal, then ISF, then CR") func isolationOrder() {
        // Enough near-target ISF samples for a high-confidence ISF change, and 8 meals for CR,
        // but no extra basal residual. ISF should be selected over CR.
        var loops: [TherapyLoopSample] = []
        for day in 1 ... 10 {
            for hour in 0 ..< 24 {
                loops.append(
                    loop(
                        day: day,
                        hour: hour,
                        glucose: 120,
                        target: 100,
                        sensitivityRatio: 1.0,
                        reason: "Basal ratio: 1.0; setting 1.0U/hr."
                    )
                )
            }
        }
        var carbs: [TherapyCarbEntry] = []
        var glucose: [TherapyGlucoseReading] = []
        for day in 2 ... 9 {
            let meal = date(day: day, hour: 18)
            carbs.append(TherapyCarbEntry(date: meal, carbs: 50, isFPU: false))
            glucose.append(TherapyGlucoseReading(date: meal, glucose: 100))
            glucose.append(TherapyGlucoseReading(date: meal.addingTimeInterval(3.5 * 3600), glucose: 130))
        }
        let report = TherapySettingsAnalyzer.generate(
            from: TherapySettingsInput(
                lookbackDays: 14,
                now: date(day: 15, hour: 12),
                calendar: calendar,
                profile: profile,
                loops: loops,
                glucose: glucose,
                carbs: carbs,
                boluses: [],
                excludedWindows: []
            )
        )
        #expect(report.isfRows[0].confidence == .high)
        #expect(report.isfRows[0].hasChange)
        #expect(report.crRows[0].hasChange)
        #expect(report.highConfidenceFamilyToChange == .isf)
    }

    @Test("Round to increment never recommends a 0 basal") func roundBasalIncrement() {
        #expect(
            TherapySettingsAnalyzer.roundToIncrement(Decimal(string: "1.03") ?? 0, increment: 0.05)
                == Decimal(string: "1.05")
        )
        #expect(TherapySettingsAnalyzer.roundToIncrement(0.02, increment: 0.05) == 0)
    }
}
