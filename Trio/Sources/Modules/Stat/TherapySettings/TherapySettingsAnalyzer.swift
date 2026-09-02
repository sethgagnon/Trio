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
    /// A dose given this long before a meal still counts as that meal's insulin.
    static let preBolusWindowMinutes: Decimal = 30
    /// The lowest and highest recorded sensitivity ratio an ISF correction may carry.
    static let minISFSensitivityRatio: Decimal = Decimal(string: "0.85") ?? 0.85
    static let maxISFSensitivityRatio: Decimal = Decimal(string: "1.15") ?? 1.15

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
            calendar: input.calendar
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
            crSampleCount: crRows.reduce(0) { $0 + $1.sampleCount },
            earliestSample: earliest,
            latestSample: latest,
            insufficientHistory: insufficientHistory,
            overrideHistoryIncomplete: input.overrideHistoryStart.map { $0 > windowStart } ?? true,
            overrideHistoryStart: input.overrideHistoryStart,
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

    /// What one loop's recorded temp-basal decision says about the profile rate.
    enum BasalEvidence: Equatable {
        /// oref recorded that the rate it wanted equalled the profile rate for that time.
        case matchesProfile
        /// A rate oref asked for, on the scaled axis: divide the recorded scale back out.
        case requested(Decimal)
        /// A deliberate zero temp: oref wanted no basal at all.
        case zeroTemp
    }

    /// Reads the decision out of a determination, or `nil` when it recorded no usable one.
    ///
    /// Only reading `rate > 0` throws away every decision that means "the profile rate is fine or
    /// too high": with `skipNeutralTemps` on, agreement is written as `rate 0, duration 0` or as no
    /// rate at all, and a real zero temp is `rate 0, duration > 0`. What survives is the set of
    /// loops that wanted *more* basal, which is why this has to read all four shapes.
    static func basalEvidence(reason: String, rate: Decimal?, duration: Decimal?) -> BasalEvidence? {
        // `profile.currentBasal` is the unscaled schedule rate (`ProfileGenerator`), so when oref
        // records that its request matched it, the recorded fact is already about the profile
        // value and no scale may be divided out.
        if reason.contains("same as profile rate") || reason.contains("neutral temp basal of") {
            return .matchesProfile
        }
        // "no temp required" keeps the running temp and never writes `rate`; the rate it wanted
        // survives only in the reason text.
        if reason.contains("no temp required") {
            guard let requested = parseRequestedRate(from: reason) else { return nil }
            return .requested(requested)
        }
        guard let rate else { return nil }
        if rate > 0 { return .requested(rate) }
        // Zero with a duration is a deliberate zero temp. Zero without one is a bare cancel whose
        // intended rate was never recorded.
        if let duration, duration > 0 { return .zeroTemp }
        return nil
    }

    /// Parses the `req 1.25U/hr` token oref writes in its "no temp required" reason.
    static func parseRequestedRate(from reason: String) -> Decimal? {
        guard let range = reason.range(of: "req ") else { return nil }
        let token = reason[range.upperBound...].prefix(while: { $0.isNumber || $0 == "." })
        guard !token.isEmpty, let value = Decimal(string: String(token)), value >= 0 else { return nil }
        return value
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
        calendar: Calendar
    ) -> [TherapySettingRow] {
        let slots = basalSlots(profile.basal)
        return slots.map { slot in
            var impliedRates: [Decimal] = []
            var slotTddRatios: [Decimal] = []
            for loop in loops {
                guard loop.cob <= maxCOBForBasalAndISF,
                      inSlot(loop.date, slot, calendar: calendar),
                      let evidence = basalEvidence(
                          reason: loop.reason,
                          rate: loop.requestedRate,
                          duration: loop.duration
                      )
                else { continue }

                let implied: Decimal
                switch evidence {
                case .matchesProfile:
                    implied = slot.value
                case .zeroTemp:
                    implied = 0
                case let .requested(rate):
                    guard let ratio = basalScaleRatio(from: loop.reason) else { continue }
                    implied = rate / ratio
                }
                impliedRates.append(implied)
                if let tddRatio = parseBasalTddRatio(from: loop.reason) {
                    slotTddRatios.append(tddRatio)
                }
            }
            let medianImplied = median(impliedRates)
            // Only this slot's own ratios, and only when every counted loop recorded one:
            // a median over a subset would be credited to samples that never had a ratio.
            let slotTdd = slotTddRatios.count == impliedRates.count ? median(slotTddRatios) : nil
            return makeRow(
                family: .basal,
                startLabel: slot.label,
                startMinutes: slot.startMinutes,
                current: slot.value,
                implied: medianImplied,
                increment: profile.basalIncrement,
                minValue: profile.basalIncrement,
                sampleCount: impliedRates.count,
                highThreshold: 48,
                mediumThreshold: 18,
                lowThreshold: 6,
                unit: String(localized: "U/hr", comment: "Basal unit")
            ) { implied, roundsToCurrent in
                if roundsToCurrent {
                    if let slotTdd, slotTdd != 1 {
                        return .basalMatchesTddAdjusted(medianTddRatio: slotTdd, sampleCount: impliedRates.count)
                    }
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
            let slotObservations = observations.filter { inSlot($0.date, slot, calendar: calendar) }
            let implied = slotObservations.map(\.isf)
            let medianImplied = median(implied)
            let medianDelta = median(slotObservations.map(\.delta))
            let medianInsulin = median(slotObservations.map(\.insulin))
            return makeRow(
                family: .isf,
                startLabel: slot.label,
                startMinutes: slot.startMinutes,
                current: slot.value,
                implied: medianImplied,
                increment: 1,
                minValue: minObservedISF,
                sampleCount: slotObservations.count,
                highThreshold: 8,
                mediumThreshold: 4,
                lowThreshold: 2,
                unit: profile.units.rawValue + "/U"
            ) { value, _ in
                .isfObserved(
                    medianISF: value,
                    medianDelta: medianDelta ?? 0,
                    medianInsulin: medianInsulin ?? 0,
                    sampleCount: slotObservations.count
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
        // Every recorded dose, including external and override-window ones. The contamination
        // check has to see doses this report will not measure: filtering them out first would
        // make an externally injected unit invisible and credit its whole effect to this dose.
        let allInsulin = boluses.filter { $0.amount > 0 }.sorted { $0.date < $1.date }
        let insulinEvents = allInsulin
            .filter { !$0.isExternal && !isExcluded($0.date, windows: excludedWindows) }

        var observations: [ISFObservation] = []
        var usedStarts: [Date] = []

        for event in insulinEvents {
            if usedStarts.contains(where: { abs($0.timeIntervalSince(event.date)) < 2 * 3600 }) {
                continue
            }
            let windowEnd = event.date.addingTimeInterval(hours: isfOutcomeEndHours)
            let windowStart = event.date.addingTimeInterval(-30 * 60)
            // An override or temp target anywhere in the outcome window changes the insulin need
            // being measured, so the whole span has to be clear, not just the dosing instant.
            guard !isExcluded(from: windowStart, to: windowEnd, windows: excludedWindows) else { continue }

            guard let loop = nearestLoop(to: event.date, in: loops),
                  loop.cob <= maxCOBForBasalAndISF,
                  let ratio = loop.sensitivityRatio,
                  ratio >= minISFSensitivityRatio, ratio <= maxISFSensitivityRatio
            else { continue }

            // Carb-free means carb-free: a hypo treatment or an FPU entry raises glucose, shrinks the
            // measured drop, and would understate ISF — the direction that doses more insulin.
            let carbsInWindow = carbs.contains {
                $0.carbs > 0 && $0.date >= windowStart && $0.date <= windowEnd
            }
            guard !carbsInWindow else { continue }

            let dosingWindowEnd = event.date.addingTimeInterval(30 * 60)
            let insulin = insulinEvents
                .filter { $0.date >= event.date && $0.date <= dosingWindowEnd }
                .reduce(Decimal(0)) { $0 + $1.amount }
            guard insulin >= minCorrectionInsulin else { continue }

            // The rationale claims this drop came from this dose, so no other dose may be acting in
            // the window: earlier insulin is still active, and later insulin lands inside the drop
            // while staying out of the divisor. Either way the stated evidence would be untrue.
            let otherInsulin = allInsulin.contains {
                ($0.date > dosingWindowEnd && $0.date <= windowEnd)
                    || ($0.date >= event.date.addingTimeInterval(hours: -isfOutcomeEndHours) && $0.date < event.date)
            }
            guard !otherInsulin else { continue }

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
                guard let loop = nearestLoop(to: meal.date, in: loops) else { continue }

                // A pre-bolus is meal insulin, so the counting window opens before the entry.
                let mealStart = meal.date.addingTimeInterval(minutes: -preBolusWindowMinutes)
                let mealEnd = meal.date.addingTimeInterval(hours: mealOutcomeEndHours)
                guard !isExcluded(from: mealStart, to: mealEnd, windows: excludedWindows) else { continue }

                let bolusesInWindow = boluses.filter { $0.date >= mealStart && $0.date <= mealEnd }

                // Insulin older than the pre-bolus window is a correction, not meal insulin.
                // Counting it would credit the meal with insulin it did not need; leaving it out
                // while it is still lowering glucose inflates the ratio instead. Neither is
                // evidence, so the meal is dropped.
                let priorInsulin = boluses.contains {
                    $0.amount > 0
                        && $0.date >= meal.date.addingTimeInterval(hours: -mealIsolationHours)
                        && $0.date < mealStart
                }
                guard !priorInsulin else { continue }

                let laterUserBolus = bolusesInWindow.contains { bolus in
                    !bolus.isSMB && !bolus.isExternal
                        && bolus.date > meal.date.addingTimeInterval(15 * 60)
                }
                guard !laterUserBolus else { continue }

                // An external dose moved glucose but its amount is not trustworthy insulin
                // accounting, so the meal cannot be reduced to carbs per recorded unit.
                let externalInsulin = bolusesInWindow.contains { $0.isExternal && $0.amount > 0 }
                guard !externalInsulin else { continue }

                let insulinGiven = bolusesInWindow.reduce(Decimal(0)) { sum, bolus in
                    bolus.isExternal ? sum : sum + bolus.amount
                }
                guard insulinGiven > 0 else { continue }

                // What the meal needed is what was given, corrected by the *net* glucose change:
                //   Δglucose = (carbs / CR - insulin) × ISF  ⇒  carbs / CR = insulin + Δglucose / ISF
                // The starting glucose, not the target, is the reference. Measuring the residual
                // against target instead charges the meal for a pre-meal excess it did not cause,
                // which understates the carb ratio and asks for more insulin per gram.
                let leftoverInsulin: Decimal
                let gap = outcome - startGlucose
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
                startMinutes: slot.startMinutes,
                current: slot.value,
                implied: medianImplied,
                increment: Decimal(string: "0.1") ?? 0.1,
                minValue: minObservedCR,
                sampleCount: implied.count,
                highThreshold: 8,
                mediumThreshold: 4,
                lowThreshold: 2,
                unit: String(localized: "g/U", comment: "Carb ratio unit")
            ) { value, _ in
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
        startMinutes: Int,
        current: Decimal,
        implied: Decimal?,
        increment: Decimal,
        minValue: Decimal,
        sampleCount: Int,
        highThreshold: Int,
        mediumThreshold: Int,
        lowThreshold: Int,
        unit: String,
        rationaleForImplied: (Decimal, Bool) -> TherapyRationale
    ) -> TherapySettingRow {
        let confidence = confidence(for: sampleCount, high: highThreshold, medium: mediumThreshold, low: lowThreshold)
        let suggested: Decimal
        let rationale: TherapyRationale
        if let implied, confidence != .insufficient {
            let rounded = roundToIncrement(implied, increment: increment)
            if rounded < minValue {
                suggested = current
                rationale = .belowSafetyFloor(medianImplied: implied, floor: minValue)
            } else {
                suggested = rounded
                // The row's wording is decided by the rounded number it actually shows. Comparing
                // the raw median against a separate tolerance let a row read "rounds to your
                // current setting" while displaying a different one.
                rationale = rationaleForImplied(implied, rounded == current)
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
            startMinutes: startMinutes,
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

    /// Rejects loops whose reason marks them as not a real dosing decision. Per-field requirements
    /// belong to each family's own evidence gate: requiring an enacted rate here would also drop the
    /// loop as ISF and carb-ratio context, where only the recorded ratio, target, and ISF matter.
    private static func isUsableLoop(_ sample: TherapyLoopSample) -> Bool {
        let reason = sample.reason.lowercased()
        if reason.contains("calibrat") { return false }
        if reason.contains("???") { return false }
        return true
    }

    private static func isExcluded(_ date: Date, windows: [DateInterval]) -> Bool {
        windows.contains { $0.contains(date) }
    }

    /// True when an override or temp target overlaps any part of `start ... end`.
    ///
    /// A sample is only as clean as its whole outcome window: an override starting an hour into a
    /// 4-hour window changes the insulin need for the rest of it.
    private static func isExcluded(from start: Date, to end: Date, windows: [DateInterval]) -> Bool {
        guard end >= start else { return isExcluded(start, windows: windows) }
        let span = DateInterval(start: start, end: end)
        return windows.contains { $0.intersects(span) }
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
        let allCarbEntries = carbs.filter { $0.carbs > 0 }.sorted { $0.date < $1.date }
        let isolation = TimeInterval(NSDecimalNumber(decimal: mealIsolationHours * 3600).doubleValue)
        // Isolation has to look backwards too. A forward-only check keeps the last meal of a
        // cluster, whose window still carries the previous meal's carbs and insulin. Indices rather
        // than dates identify the meal, so a second entry at the same instant (an FPU split off the
        // same meal, which keeps absorbing past the 4h outcome) still counts as contamination.
        return allCarbEntries.enumerated().filter { index, meal in
            guard !meal.isFPU, meal.carbs >= minMealCarbs,
                  !isExcluded(meal.date, windows: excludedWindows)
            else { return false }
            return !allCarbEntries.enumerated().contains { otherIndex, other in
                otherIndex != index
                    && other.date > meal.date.addingTimeInterval(-isolation)
                    && other.date < meal.date.addingTimeInterval(isolation)
            }
        }.map { $0.element }
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

    func addingTimeInterval(minutes: Decimal) -> Date {
        addingTimeInterval(TimeInterval(NSDecimalNumber(decimal: minutes * 60).doubleValue))
    }
}
