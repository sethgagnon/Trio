import Foundation

enum TherapySettingsAnalyzer {
    static let maxPercentChange: Decimal = 0.10
    static let basalHalfStep: Decimal = 0.5
    static let glucoseErrorScale: Decimal = 400
    static let maxCOBForBasalAndISF: Decimal = 10
    static let minMealCarbs: Decimal = 10
    static let mealIsolationHours: Decimal = 4
    static let mealOutcomeStartHours: Decimal = 3
    static let mealOutcomeEndHours: Decimal = 4
    static let minHistoryDays: Int = 6
    static let minUsableLoops: Int = 200

    static func generate(from input: TherapySettingsInput) -> TherapySettingsReport {
        let windowStart = input.calendar.date(byAdding: .day, value: -input.lookbackDays, to: input.now) ?? input.now
        let loopsInWindow = input.loops.filter { $0.date >= windowStart && $0.date <= input.now }
        let usableLoops = loopsInWindow.filter { sample in
            isUsableLoop(sample) && !isExcluded(sample.date, windows: input.excludedWindows)
        }

        let tddRatios = usableLoops.compactMap { parseBasalTddRatio(from: $0.reason) }
        let medianTddRatio = median(tddRatios)

        let glucose = input.glucose
            .filter { $0.date >= windowStart && $0.date <= input.now }
            .sorted { $0.date < $1.date }
        let carbs = input.carbs.filter { $0.date >= windowStart && $0.date <= input.now }
        let boluses = input.boluses.filter { $0.date >= windowStart && $0.date <= input.now }

        let basalRows = makeBasalRows(
            loops: usableLoops,
            profile: input.profile,
            calendar: input.calendar,
            medianTddRatio: medianTddRatio
        )
        let isfRows = makeISFRows(
            loops: usableLoops,
            profile: input.profile,
            calendar: input.calendar
        )
        let crRows = makeCRRows(
            carbs: carbs,
            glucose: glucose,
            boluses: boluses,
            loops: usableLoops,
            profile: input.profile,
            calendar: input.calendar,
            excludedWindows: input.excludedWindows
        )

        let earliest = usableLoops.map(\.date).min() ?? carbs.map(\.date).min()
        let latest = usableLoops.map(\.date).max() ?? carbs.map(\.date).max()
        let spanDays: Double = {
            guard let earliest, let latest else { return 0 }
            return latest.timeIntervalSince(earliest) / 86_400
        }()
        let insufficientHistory = spanDays < Double(minHistoryDays) || usableLoops.count < minUsableLoops

        let familyToChange = preferredHighConfidenceFamily(basal: basalRows, isf: isfRows, cr: crRows)

        return TherapySettingsReport(
            lookbackDays: input.lookbackDays,
            loopCount: loopsInWindow.count,
            usableLoopCount: usableLoops.count,
            mealCount: crRows.reduce(0) { $0 + $1.sampleCount },
            earliestSample: earliest,
            latestSample: latest,
            insufficientHistory: insufficientHistory,
            medianTddRatio: medianTddRatio,
            basalRows: basalRows,
            isfRows: isfRows,
            crRows: crRows,
            highConfidenceFamilyToChange: insufficientHistory ? nil : familyToChange
        )
    }

    /// Parses `Basal ratio: 1.12` from an oref determination reason string.
    static func parseBasalTddRatio(from reason: String) -> Decimal? {
        guard let range = reason.range(of: "Basal ratio:") else { return nil }
        let remainder = reason[range.upperBound...]
            .drop(while: { $0 == " " })
        let token = remainder.prefix(while: { $0.isNumber || $0 == "." })
        guard !token.isEmpty, let value = Decimal(string: String(token)), value > 0 else {
            return nil
        }
        return value
    }

    // MARK: - Basal

    private static func makeBasalRows(
        loops: [TherapyLoopSample],
        profile: TherapyProfileSnapshot,
        calendar: Calendar,
        medianTddRatio: Decimal?
    ) -> [TherapySettingRow] {
        let slots = basalSlots(profile.basal)
        return slots.map { slot in
            let samples = loops.compactMap { loop -> Decimal? in
                guard loop.cob <= maxCOBForBasalAndISF,
                      let enacted = loop.enactedRate, enacted > 0,
                      minutesFromMidnight(loop.date, calendar: calendar) >= slot.startMinutes,
                      minutesFromMidnight(loop.date, calendar: calendar) < slot.endMinutes
                else { return nil }
                let tddRatio = parseBasalTddRatio(from: loop.reason) ?? 1
                guard slot.value > 0, tddRatio > 0 else { return nil }
                return enacted / (slot.value * tddRatio)
            }
            let medianResidual = median(samples)
            let usedTdd = loops.contains {
                minutesFromMidnight($0.date, calendar: calendar) >= slot.startMinutes
                    && minutesFromMidnight($0.date, calendar: calendar) < slot.endMinutes
                    && parseBasalTddRatio(from: $0.reason) != nil
            }
            let moreInsulin: Decimal = {
                guard let medianResidual else { return 0 }
                return (medianResidual - 1) * basalHalfStep
            }()
            return makeRow(
                family: .basal,
                startLabel: slot.label,
                current: slot.value,
                moreInsulinFraction: moreInsulin,
                lowersValue: false,
                increment: profile.basalIncrement,
                minValue: profile.basalIncrement,
                sampleCount: samples.count,
                highThreshold: 48,
                mediumThreshold: 18,
                lowThreshold: 6,
                rationaleForChange: { fraction in
                    guard let medianResidual else { return .insufficientSamples }
                    if abs(medianResidual - 1) < 0.02, let medianTddRatio, medianTddRatio != 1 {
                        return .basalCoveredByAdjustBasal(medianTddRatio: medianTddRatio)
                    }
                    if fraction > 0 {
                        return .basalExtraAfterTdd(medianResidual: medianResidual, usedTddRatio: usedTdd)
                    }
                    if fraction < 0 {
                        return .basalTooHigh(medianResidual: medianResidual, usedTddRatio: usedTdd)
                    }
                    if let medianTddRatio, medianTddRatio != 1 {
                        return .basalCoveredByAdjustBasal(medianTddRatio: medianTddRatio)
                    }
                    return .noConsistentSignal
                },
                unit: String(localized: "U/hr", comment: "Basal unit")
            )
        }
    }

    // MARK: - ISF

    private static func makeISFRows(
        loops: [TherapyLoopSample],
        profile: TherapyProfileSnapshot,
        calendar: Calendar
    ) -> [TherapySettingRow] {
        let slots = isfSlots(profile.isf)
        return slots.map { slot in
            let deltas = loops.compactMap { loop -> Decimal? in
                guard loop.cob <= maxCOBForBasalAndISF,
                      let glucose = loop.glucose,
                      let target = loop.target, target > 0,
                      minutesFromMidnight(loop.date, calendar: calendar) >= slot.startMinutes,
                      minutesFromMidnight(loop.date, calendar: calendar) < slot.endMinutes
                else { return nil }
                // Near target only: sigmoid ratio ≈ 1 at the glucose target.
                // High-BG ISF is Adjustment Factor / Autosens Max, not profile ISF.
                let ratio = loop.sensitivityRatio ?? 1
                guard ratio >= 0.85, ratio <= 1.15 else { return nil }
                return glucose - target
            }
            let medianDelta = median(deltas)
            let moreInsulin = (medianDelta ?? 0) / glucoseErrorScale
            return makeRow(
                family: .isf,
                startLabel: slot.label,
                current: slot.value,
                moreInsulinFraction: moreInsulin,
                lowersValue: true,
                increment: 1,
                minValue: 9,
                sampleCount: deltas.count,
                highThreshold: 24,
                mediumThreshold: 10,
                lowThreshold: 5,
                rationaleForChange: { fraction in
                    guard let medianDelta else { return .insufficientSamples }
                    if fraction > 0 { return .isfHighNearTarget(medianDelta: medianDelta) }
                    if fraction < 0 { return .isfLowNearTarget(medianDelta: medianDelta) }
                    return .noConsistentSignal
                },
                unit: profile.units.rawValue + "/U"
            )
        }
    }

    // MARK: - Carb ratio

    private static func makeCRRows(
        carbs: [TherapyCarbEntry],
        glucose: [TherapyGlucoseReading],
        boluses: [TherapyBolus],
        loops: [TherapyLoopSample],
        profile: TherapyProfileSnapshot,
        calendar: Calendar,
        excludedWindows: [DateInterval]
    ) -> [TherapySettingRow] {
        let meals = isolatedMeals(from: carbs, excludedWindows: excludedWindows)
        let slots = crSlots(profile.carbRatios)
        return slots.map { slot in
            let outcomes: [(delta: Decimal, extraSmb: Decimal)] = meals.compactMap { meal in
                guard minutesFromMidnight(meal.date, calendar: calendar) >= slot.startMinutes,
                      minutesFromMidnight(meal.date, calendar: calendar) < slot.endMinutes
                else { return nil }
                guard let outcome = glucoseAround(
                    start: meal.date.addingTimeInterval(hours: mealOutcomeStartHours),
                    end: meal.date.addingTimeInterval(hours: mealOutcomeEndHours),
                    in: glucose
                ) else { return nil }
                let baseline = glucoseAround(
                    start: meal.date.addingTimeInterval(-10 * 60),
                    end: meal.date.addingTimeInterval(10 * 60),
                    in: glucose
                ) ?? targetNear(meal.date, loops: loops) ?? 100
                let extraSmb = boluses.reduce(Decimal(0)) { sum, bolus in
                    guard bolus.isSMB, !bolus.isExternal,
                          bolus.date > meal.date,
                          bolus.date <= meal.date.addingTimeInterval(hours: mealOutcomeEndHours)
                    else { return sum }
                    return sum + bolus.amount
                }
                let userBolus = boluses.reduce(Decimal(0)) { sum, bolus in
                    guard !bolus.isSMB, !bolus.isExternal,
                          bolus.date > meal.date.addingTimeInterval(15 * 60),
                          bolus.date <= meal.date.addingTimeInterval(hours: mealOutcomeEndHours)
                    else { return sum }
                    return sum + bolus.amount
                }
                // A later user correction confounds the meal outcome.
                guard userBolus < 0.5 else { return nil }
                return (outcome - baseline, extraSmb)
            }
            let medianDelta = median(outcomes.map(\.delta))
            let medianSmb = median(outcomes.map(\.extraSmb)) ?? 0
            let moreInsulin = (medianDelta ?? 0) / glucoseErrorScale
            return makeRow(
                family: .cr,
                startLabel: slot.label,
                current: slot.value,
                moreInsulinFraction: moreInsulin,
                lowersValue: true,
                increment: Decimal(string: "0.1") ?? 0.1,
                minValue: 1,
                sampleCount: outcomes.count,
                highThreshold: 8,
                mediumThreshold: 4,
                lowThreshold: 2,
                rationaleForChange: { fraction in
                    guard let medianDelta else { return .insufficientSamples }
                    if fraction > 0 {
                        return .crHighAfterMeal(
                            medianDelta: medianDelta,
                            extraSmb: medianSmb,
                            mealCount: outcomes.count
                        )
                    }
                    if fraction < 0 {
                        return .crLowAfterMeal(
                            medianDelta: medianDelta,
                            extraSmb: medianSmb,
                            mealCount: outcomes.count
                        )
                    }
                    return .noConsistentSignal
                },
                unit: String(localized: "g/U", comment: "Carb ratio unit")
            )
        }
    }

    // MARK: - Row construction

    private static func makeRow(
        family: TherapySettingFamily,
        startLabel: String,
        current: Decimal,
        moreInsulinFraction: Decimal,
        lowersValue: Bool,
        increment: Decimal,
        minValue: Decimal,
        sampleCount: Int,
        highThreshold: Int,
        mediumThreshold: Int,
        lowThreshold: Int,
        rationaleForChange: (Decimal) -> TherapyRationale,
        unit: String
    ) -> TherapySettingRow {
        let confidence = confidence(for: sampleCount, high: highThreshold, medium: mediumThreshold, low: lowThreshold)
        let clamped = moreInsulinFraction.clamp(lowerBound: -maxPercentChange, upperBound: maxPercentChange)
        let suggested: Decimal
        if confidence == .insufficient {
            suggested = current
        } else {
            let direction: Decimal = lowersValue ? -1 : 1
            let raw = current * (1 + direction * clamped)
            suggested = max(minValue, roundToIncrement(raw, increment: increment))
        }
        let percentChange: Decimal = {
            guard current != 0 else { return 0 }
            return ((suggested - current) / current).rounded(toPlaces: 4)
        }()
        let rationale: TherapyRationale
        if confidence == .insufficient {
            rationale = .insufficientSamples
        } else if suggested == current, clamped != 0 {
            rationale = .roundedToUnchanged
        } else {
            rationale = rationaleForChange(clamped)
        }
        return TherapySettingRow(
            family: family,
            startLabel: startLabel,
            current: current,
            suggested: suggested,
            percentChange: percentChange,
            sampleCount: sampleCount,
            confidence: confidence,
            rationale: rationale,
            unit: unit
        )
    }

    static func roundToIncrement(_ value: Decimal, increment: Decimal) -> Decimal {
        guard increment > 0 else { return value }
        return (value / increment).rounded(scale: 0) * increment
    }

    static func confidence(for count: Int, high: Int, medium: Int, low: Int) -> TherapyConfidence {
        if count >= high { return .high }
        if count >= medium { return .medium }
        if count >= low { return .low }
        return .insufficient
    }

    static func preferredHighConfidenceFamily(
        basal: [TherapySettingRow],
        isf: [TherapySettingRow],
        cr: [TherapySettingRow]
    ) -> TherapySettingFamily? {
        let families: [(TherapySettingFamily, [TherapySettingRow])] = [
            (.basal, basal),
            (.isf, isf),
            (.cr, cr)
        ]
        for (family, rows) in families {
            if rows.contains(where: { $0.confidence == .high && $0.hasChange }) {
                return family
            }
        }
        return nil
    }

    // MARK: - Helpers

    static func median(_ values: [Decimal]) -> Decimal? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func isUsableLoop(_ sample: TherapyLoopSample) -> Bool {
        guard sample.enactedRate != nil, sample.glucose != nil else { return false }
        let reason = sample.reason.lowercased()
        if reason.contains("calibrat") { return false }
        if reason.contains("???") { return false }
        return true
    }

    private static func isExcluded(_ date: Date, windows: [DateInterval]) -> Bool {
        windows.contains { $0.contains(date) }
    }

    private static func minutesFromMidnight(_ date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private struct Slot {
        let label: String
        let startMinutes: Int
        let endMinutes: Int
        let value: Decimal
    }

    private static func basalSlots(_ entries: [BasalProfileEntry]) -> [Slot] {
        let sorted = entries.sorted { $0.minutes < $1.minutes }
        return zipSlots(
            sorted.map { (label: displayStart($0.start), minutes: $0.minutes, value: $0.rate) }
        )
    }

    private static func isfSlots(_ entries: [InsulinSensitivityEntry]) -> [Slot] {
        let sorted = entries.sorted { $0.offset < $1.offset }
        return zipSlots(
            sorted.map { (label: displayStart($0.start), minutes: $0.offset, value: $0.sensitivity) }
        )
    }

    private static func crSlots(_ ratios: CarbRatios) -> [Slot] {
        let sorted = ratios.schedule.sorted { $0.offset < $1.offset }
        return zipSlots(
            sorted.map { (label: displayStart($0.start), minutes: $0.offset, value: $0.ratio) }
        )
    }

    private static func zipSlots(_ entries: [(label: String, minutes: Int, value: Decimal)]) -> [Slot] {
        guard !entries.isEmpty else { return [] }
        var slots: [Slot] = []
        for (index, entry) in entries.enumerated() {
            let end = index + 1 < entries.count ? entries[index + 1].minutes : 24 * 60
            slots.append(
                Slot(label: entry.label, startMinutes: entry.minutes, endMinutes: end, value: entry.value)
            )
        }
        return slots
    }

    private static func displayStart(_ start: String) -> String {
        String(start.prefix(5))
    }

    private static func isolatedMeals(
        from carbs: [TherapyCarbEntry],
        excludedWindows: [DateInterval]
    ) -> [TherapyCarbEntry] {
        let meals = carbs
            .filter { !$0.isFPU && $0.carbs >= minMealCarbs && !isExcluded($0.date, windows: excludedWindows) }
            .sorted { $0.date < $1.date }
        let isolation = TimeInterval(NSDecimalNumber(decimal: mealIsolationHours * 3600).doubleValue)
        return meals.filter { meal in
            !meals.contains { other in
                other.date > meal.date && other.date < meal.date.addingTimeInterval(isolation)
            }
        }
    }

    private static func glucoseAround(
        start: Date,
        end: Date,
        in readings: [TherapyGlucoseReading]
    ) -> Decimal? {
        let values = readings.compactMap { reading -> Decimal? in
            guard reading.date >= start, reading.date <= end else { return nil }
            return reading.glucose
        }
        return median(values)
    }

    private static func targetNear(_ date: Date, loops: [TherapyLoopSample]) -> Decimal? {
        loops.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })?
            .target
    }
}

private extension Date {
    func addingTimeInterval(hours: Decimal) -> Date {
        addingTimeInterval(TimeInterval(NSDecimalNumber(decimal: hours * 3600).doubleValue))
    }
}
