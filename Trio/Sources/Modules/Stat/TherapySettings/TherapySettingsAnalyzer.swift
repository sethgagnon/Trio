import Foundation

enum TherapySettingsAnalyzer {
    static let maxCOBForBasalAndISF: Decimal = 10
    static let minMealCarbs: Decimal = 10
    static let minCorrectionInsulin: Decimal = Decimal(string: "0.3") ?? 0.3
    static let mealIsolationHours: Decimal = 4
    static let mealOutcomeStartHours: Decimal = 3
    static let mealOutcomeEndHours: Decimal = 4
    static let isfOutcomeStartHours: Decimal = 3
    static let isfOutcomeEndHours: Decimal = 4
    static let minHistoryDays: Int = 6
    static let minUsableLoops: Int = 200
    static let minObservedISF: Decimal = 9
    static let maxObservedISF: Decimal = 540
    static let minObservedCR: Decimal = 1
    static let maxObservedCR: Decimal = 150
    static let nearestLoopLimit: TimeInterval = 20 * 60

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
            glucose: glucose,
            carbs: carbs,
            boluses: boluses,
            profile: input.profile,
            calendar: input.calendar,
            excludedWindows: input.excludedWindows
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
        parseLabeledRatio("Basal ratio:", from: reason)
    }

    /// Parses `Autosens ratio: 1.15` from an oref determination reason string.
    static func parseAutosensRatio(from reason: String) -> Decimal? {
        parseLabeledRatio("Autosens ratio:", from: reason)
    }

    /// Recorded scale applied to the enacted basal, or `nil` when the loop cannot be used.
    ///
    /// - `Basal ratio:` present and numeric: Adjust Basal was on; divide it out.
    /// - `Basal ratio:` present but unreadable: skip (do not assume 1).
    /// - `Dynamic ISF: On` and no basal-ratio token: Adjust Basal was off; enacted is not TDD-scaled.
    /// - Otherwise use a recorded `Autosens ratio:` (non-dynamic loops scale basal by autosens).
    /// - No recorded scale at all: skip.
    static func basalScaleRatio(from reason: String) -> Decimal? {
        if let tddRatio = parseBasalTddRatio(from: reason) {
            return tddRatio
        }
        if reason.contains("Basal ratio:") {
            return nil
        }
        if reason.contains("Dynamic ISF: On") {
            return 1
        }
        return parseAutosensRatio(from: reason)
    }

    private static func parseLabeledRatio(_ label: String, from reason: String) -> Decimal? {
        guard let range = reason.range(of: label) else { return nil }
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
            var impliedRates: [Decimal] = []
            var ratios: [Decimal] = []
            for loop in loops {
                guard loop.cob <= maxCOBForBasalAndISF,
                      let enacted = loop.enactedRate, enacted > 0,
                      inSlot(loop.date, slot, calendar: calendar)
                else { continue }
                guard let ratio = basalScaleRatio(from: loop.reason) else { continue }
                impliedRates.append(enacted / ratio)
                if let tddRatio = parseBasalTddRatio(from: loop.reason), tddRatio != 1 {
                    ratios.append(tddRatio)
                }
            }
            let medianImplied = median(impliedRates)
            let slotTdd = median(ratios) ?? medianTddRatio
            return makeRow(
                family: .basal,
                startLabel: slot.label,
                current: slot.value,
                implied: medianImplied,
                increment: profile.basalIncrement,
                minValue: profile.basalIncrement,
                sampleCount: impliedRates.count,
                highThreshold: 48,
                mediumThreshold: 18,
                lowThreshold: 6,
                unit: String(localized: "U/hr", comment: "Basal unit")
            ) { implied in
                if let slotTdd, slotTdd != 1,
                   abs(implied - slot.value) < max(profile.basalIncrement / 2, Decimal(string: "0.025") ?? 0.025)
                {
                    return .basalMatchesTddAdjusted(medianTddRatio: slotTdd, sampleCount: impliedRates.count)
                }
                if abs(implied - slot.value) < max(profile.basalIncrement / 2, Decimal(string: "0.025") ?? 0.025) {
                    return .roundedToUnchanged(medianImplied: implied)
                }
                return .basalImplied(
                    medianRate: implied,
                    medianTddRatio: slotTdd,
                    sampleCount: impliedRates.count
                )
            }
        }
    }

    // MARK: - ISF

    private static func makeISFRows(
        loops: [TherapyLoopSample],
        glucose: [TherapyGlucoseReading],
        carbs: [TherapyCarbEntry],
        boluses: [TherapyBolus],
        profile: TherapyProfileSnapshot,
        calendar: Calendar,
        excludedWindows: [DateInterval]
    ) -> [TherapySettingRow] {
        let observations = observedISFEvents(
            loops: loops,
            glucose: glucose,
            carbs: carbs,
            boluses: boluses,
            excludedWindows: excludedWindows
        )
        let slots = isfSlots(profile.isf)
        return slots.map { slot in
            let inSlot = observations.filter { inSlot($0.date, slot, calendar: calendar) }
            let implied = inSlot.map(\.isf)
            let medianImplied = median(implied)
            let medianDelta = median(inSlot.map(\.delta))
            let medianInsulin = median(inSlot.map(\.insulin))
            return makeRow(
                family: .isf,
                startLabel: slot.label,
                current: slot.value,
                implied: medianImplied,
                increment: 1,
                minValue: minObservedISF,
                sampleCount: inSlot.count,
                highThreshold: 8,
                mediumThreshold: 4,
                lowThreshold: 2,
                unit: profile.units.rawValue + "/U"
            ) { value in
                .isfObserved(
                    medianISF: value,
                    medianDelta: medianDelta ?? 0,
                    medianInsulin: medianInsulin ?? 0,
                    sampleCount: inSlot.count
                )
            }
        }
    }

    private struct ISFObservation {
        let date: Date
        let isf: Decimal
        let delta: Decimal
        let insulin: Decimal
    }

    private static func observedISFEvents(
        loops: [TherapyLoopSample],
        glucose: [TherapyGlucoseReading],
        carbs: [TherapyCarbEntry],
        boluses: [TherapyBolus],
        excludedWindows: [DateInterval]
    ) -> [ISFObservation] {
        let insulinEvents = boluses
            .filter { !$0.isExternal && $0.amount > 0 && !isExcluded($0.date, windows: excludedWindows) }
            .sorted { $0.date < $1.date }

        var observations: [ISFObservation] = []
        var usedStarts: [Date] = []

        for event in insulinEvents {
            if usedStarts.contains(where: { abs($0.timeIntervalSince(event.date)) < 2 * 3600 }) {
                continue
            }
            guard let loop = nearestLoop(to: event.date, in: loops),
                  loop.cob <= maxCOBForBasalAndISF,
                  let ratio = loop.sensitivityRatio,
                  ratio >= 0.85, ratio <= 1.15
            else { continue }

            let windowEnd = event.date.addingTimeInterval(hours: isfOutcomeEndHours)
            let carbsInWindow = carbs.contains {
                !$0.isFPU && $0.carbs >= minMealCarbs
                    && $0.date >= event.date.addingTimeInterval(-30 * 60)
                    && $0.date <= windowEnd
            }
            guard !carbsInWindow else { continue }

            let insulin = insulinEvents
                .filter { $0.date >= event.date && $0.date <= event.date.addingTimeInterval(30 * 60) }
                .reduce(Decimal(0)) { $0 + $1.amount }
            guard insulin >= minCorrectionInsulin else { continue }

            guard let startGlucose = glucoseAround(
                start: event.date.addingTimeInterval(-10 * 60),
                end: event.date.addingTimeInterval(10 * 60),
                in: glucose
            ), let endGlucose = glucoseAround(
                start: event.date.addingTimeInterval(hours: isfOutcomeStartHours),
                end: windowEnd,
                in: glucose
            ) else { continue }

            let delta = startGlucose - endGlucose
            guard delta > 0 else { continue }
            let observed = delta / insulin
            guard observed >= minObservedISF, observed <= maxObservedISF else { continue }

            usedStarts.append(event.date)
            observations.append(ISFObservation(date: event.date, isf: observed, delta: delta, insulin: insulin))
        }
        return observations
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
            var implied: [Decimal] = []
            var carbAmounts: [Decimal] = []
            var insulinAmounts: [Decimal] = []
            var deltas: [Decimal] = []

            for meal in meals {
                guard inSlot(meal.date, slot, calendar: calendar) else { continue }
                guard let outcome = glucoseAround(
                    start: meal.date.addingTimeInterval(hours: mealOutcomeStartHours),
                    end: meal.date.addingTimeInterval(hours: mealOutcomeEndHours),
                    in: glucose
                ) else { continue }
                guard let startGlucose = glucoseAround(
                    start: meal.date.addingTimeInterval(-10 * 60),
                    end: meal.date.addingTimeInterval(10 * 60),
                    in: glucose
                ) else { continue }
                guard let loop = nearestLoop(to: meal.date, in: loops),
                      let target = loop.target, target > 0
                else { continue }

                let mealEnd = meal.date.addingTimeInterval(hours: mealOutcomeEndHours)
                let laterUserBolus = boluses.reduce(Decimal(0)) { sum, bolus in
                    guard !bolus.isSMB, !bolus.isExternal,
                          bolus.date > meal.date.addingTimeInterval(15 * 60),
                          bolus.date <= mealEnd
                    else { return sum }
                    return sum + bolus.amount
                }
                guard laterUserBolus == 0 else { continue }

                let insulinGiven = boluses.reduce(Decimal(0)) { sum, bolus in
                    guard !bolus.isExternal,
                          bolus.date >= meal.date.addingTimeInterval(-15 * 60),
                          bolus.date <= mealEnd
                    else { return sum }
                    return sum + bolus.amount
                }
                guard insulinGiven > 0 else { continue }

                let leftoverInsulin: Decimal
                let gap = outcome - target
                if gap == 0 {
                    leftoverInsulin = 0
                } else {
                    guard let isf = loop.insulinSensitivity, isf > 0 else { continue }
                    leftoverInsulin = gap / isf
                }

                let insulinNeeded = insulinGiven + leftoverInsulin
                guard insulinNeeded > 0 else { continue }
                let observedCR = meal.carbs / insulinNeeded
                guard observedCR >= minObservedCR, observedCR <= maxObservedCR else { continue }

                implied.append(observedCR)
                carbAmounts.append(meal.carbs)
                insulinAmounts.append(insulinNeeded)
                deltas.append(outcome - startGlucose)
            }

            let medianImplied = median(implied)
            return makeRow(
                family: .cr,
                startLabel: slot.label,
                current: slot.value,
                implied: medianImplied,
                increment: Decimal(string: "0.1") ?? 0.1,
                minValue: minObservedCR,
                sampleCount: implied.count,
                highThreshold: 8,
                mediumThreshold: 4,
                lowThreshold: 2,
                unit: String(localized: "g/U", comment: "Carb ratio unit")
            ) { value in
                .crObserved(
                    medianCR: value,
                    medianCarbs: median(carbAmounts) ?? 0,
                    medianInsulin: median(insulinAmounts) ?? 0,
                    medianGlucoseDelta: median(deltas) ?? 0,
                    sampleCount: implied.count
                )
            }
        }
    }

    // MARK: - Row construction

    private static func makeRow(
        family: TherapySettingFamily,
        startLabel: String,
        current: Decimal,
        implied: Decimal?,
        increment: Decimal,
        minValue: Decimal,
        sampleCount: Int,
        highThreshold: Int,
        mediumThreshold: Int,
        lowThreshold: Int,
        unit: String,
        rationaleForImplied: (Decimal) -> TherapyRationale
    ) -> TherapySettingRow {
        let confidence = confidence(for: sampleCount, high: highThreshold, medium: mediumThreshold, low: lowThreshold)
        let suggested: Decimal
        let rationale: TherapyRationale
        if let implied, confidence != .insufficient {
            let rounded = roundToIncrement(implied, increment: increment)
            if rounded < minValue {
                suggested = current
                rationale = .roundedToUnchanged(medianImplied: implied)
            } else {
                suggested = rounded
                rationale = rationaleForImplied(implied)
            }
        } else {
            suggested = current
            rationale = .insufficientEvidence
        }
        let percentChange: Decimal = {
            guard current != 0 else { return 0 }
            return ((suggested - current) / current).rounded(toPlaces: 4)
        }()
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

    private static func inSlot(_ date: Date, _ slot: Slot, calendar: Calendar) -> Bool {
        let minutes = minutesFromMidnight(date, calendar: calendar)
        return minutes >= slot.startMinutes && minutes < slot.endMinutes
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

    private static func nearestLoop(to date: Date, in loops: [TherapyLoopSample]) -> TherapyLoopSample? {
        guard let nearest = loops.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }) else { return nil }
        guard abs(nearest.date.timeIntervalSince(date)) <= nearestLoopLimit else { return nil }
        return nearest
    }
}

private extension Date {
    func addingTimeInterval(hours: Decimal) -> Date {
        addingTimeInterval(TimeInterval(NSDecimalNumber(decimal: hours * 3600).doubleValue))
    }
}
