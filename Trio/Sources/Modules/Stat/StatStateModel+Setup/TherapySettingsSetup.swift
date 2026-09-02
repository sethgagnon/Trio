import CoreData
import Foundation

extension Stat.StateModel {
    func setupTherapySettingsReport() {
        // Toggling the lookback restarts the build; without cancelling the previous one a slower
        // earlier run could finish last and publish the wrong window.
        therapyReportTask?.cancel()
        therapyReportTask = Task {
            await loadTherapySettingsReport()
        }
    }

    func loadTherapySettingsReport() async {
        await MainActor.run { isTherapyReportLoading = true }
        do {
            let report = try await buildTherapySettingsReport()
            try Task.checkCancellation()
            await MainActor.run {
                therapyReport = report
                isTherapyReportLoading = false
            }
        } catch is CancellationError {
            return
        } catch {
            debug(.default, "\(DebuggingIdentifiers.failed) failed building therapy settings report: \(error)")
            await MainActor.run {
                therapyReport = nil
                isTherapyReportLoading = false
            }
        }
    }

    private func buildTherapySettingsReport() async throws -> TherapySettingsReport {
        let lookback = therapyLookback.rawValue
        let now = Date()
        let calendar = Calendar.current
        guard let windowStart = calendar.date(byAdding: .day, value: -lookback, to: now) else {
            throw CoreDataError.fetchError(function: #function, file: #file)
        }

        let context = CoreDataStack.shared.newTaskContext()
        context.name = "StatStateModel.therapySettingsReport"
        let start = windowStart as NSDate
        let end = now as NSDate

        let loopResults = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OrefDetermination.self,
            onContext: context,
            predicate: NSPredicate(format: "deliverAt >= %@ AND deliverAt <= %@", start, end),
            key: "deliverAt",
            ascending: true,
            batchSize: 200
        )
        let glucoseResults = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate(format: "date >= %@ AND date <= %@", start, end),
            key: "date",
            ascending: true,
            batchSize: 200
        )
        let carbResults = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: CarbEntryStored.self,
            onContext: context,
            predicate: NSPredicate(format: "date >= %@ AND date <= %@", start, end),
            key: "date",
            ascending: true,
            batchSize: 100
        )
        let pumpResults = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate(format: "timestamp >= %@ AND timestamp <= %@ AND bolus != nil", start, end),
            key: "timestamp",
            ascending: true,
            batchSize: 100,
            relationshipKeyPathsForPrefetching: ["bolus"]
        )
        let overrideRunResults = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OverrideRunStored.self,
            onContext: context,
            predicate: NSPredicate(format: "startDate >= %@ OR endDate >= %@", start, start),
            key: "startDate",
            ascending: true
        )
        let tempTargetRunResults = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: TempTargetRunStored.self,
            onContext: context,
            predicate: NSPredicate(format: "startDate >= %@ OR endDate >= %@", start, start),
            key: "startDate",
            ascending: true
        )
        // Enacting a preset enables the preset row itself, so `isPreset == NO` would miss most
        // running adjustments and let their loops count as ordinary evidence.
        let activeOverrideResults = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OverrideStored.self,
            onContext: context,
            predicate: NSPredicate(format: "enabled == YES"),
            key: "date",
            ascending: false
        )
        let activeTempTargetResults = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: TempTargetStored.self,
            onContext: context,
            predicate: NSPredicate(format: "enabled == YES"),
            key: "date",
            ascending: false
        )

        let snapshot: (
            loops: [TherapyLoopSample],
            glucose: [TherapyGlucoseReading],
            carbs: [TherapyCarbEntry],
            boluses: [TherapyBolus],
            windows: [DateInterval]
        ) = await context.perform {
            let loops = ((loopResults as? [OrefDetermination]) ?? []).compactMap { determination -> TherapyLoopSample? in
                guard let date = determination.deliverAt ?? determination.timestamp else { return nil }
                return TherapyLoopSample(
                    date: date,
                    cob: Decimal(determination.cob),
                    sensitivityRatio: determination.sensitivityRatio?.decimalValue,
                    insulinSensitivity: determination.insulinSensitivity?.decimalValue,
                    reason: determination.reason ?? ""
                )
            }
            let glucose = ((glucoseResults as? [GlucoseStored]) ?? []).compactMap { entry -> TherapyGlucoseReading? in
                guard let date = entry.date, entry.glucose > 0 else { return nil }
                return TherapyGlucoseReading(date: date, glucose: Decimal(entry.glucose))
            }
            let carbs = ((carbResults as? [CarbEntryStored]) ?? []).compactMap { entry -> TherapyCarbEntry? in
                guard let date = entry.date else { return nil }
                // `carbs` is a Core Data Double; Decimal(Double) carries binary residue into the
                // ratio, so use the repo's JSON-style conversion.
                return TherapyCarbEntry(
                    date: date,
                    carbs: Decimal(algorithmValue: entry.carbs),
                    isFPU: entry.isFPU
                )
            }
            let boluses = ((pumpResults as? [PumpEventStored]) ?? []).compactMap { event -> TherapyBolus? in
                guard let date = event.timestamp, let bolus = event.bolus else { return nil }
                return TherapyBolus(
                    date: date,
                    amount: bolus.amount?.decimalValue ?? 0,
                    isSMB: bolus.isSMB,
                    isExternal: bolus.isExternal
                )
            }

            var windows: [DateInterval] = []
            windows.append(contentsOf: ((overrideRunResults as? [OverrideRunStored]) ?? []).compactMap { run in
                Self.exclusionWindow(from: run.startDate, to: run.endDate ?? now)
            })
            windows.append(contentsOf: ((tempTargetRunResults as? [TempTargetRunStored]) ?? []).compactMap { run in
                Self.exclusionWindow(from: run.startDate, to: run.endDate ?? now)
            })
            for override in (activeOverrideResults as? [OverrideStored]) ?? [] {
                guard override.enabled, let startDate = override.date else { continue }
                let durationMinutes = override.indefinite ? Decimal(lookback * 24 * 60)
                    : (override.duration?.decimalValue ?? 0)
                let endDate = startDate.addingTimeInterval(
                    TimeInterval(NSDecimalNumber(decimal: durationMinutes * 60).doubleValue)
                )
                if let window = Self.exclusionWindow(from: startDate, to: max(endDate, now)) {
                    windows.append(window)
                }
            }
            for target in (activeTempTargetResults as? [TempTargetStored]) ?? [] {
                guard target.enabled, let startDate = target.date else { continue }
                let durationMinutes = target.duration?.decimalValue ?? 0
                let endDate = startDate.addingTimeInterval(
                    TimeInterval(NSDecimalNumber(decimal: durationMinutes * 60).doubleValue)
                )
                if let window = Self.exclusionWindow(from: startDate, to: max(endDate, now)) {
                    windows.append(window)
                }
            }
            return (loops, glucose, carbs, boluses, windows)
        }

        // Only `units` is main-actor state. The three profiles are synchronous disk reads, so
        // reading them inside `MainActor.run` would block the main thread on file I/O.
        let displayUnits = await MainActor.run { units }
        let profile = TherapyProfileSnapshot(
            basal: provider.basalProfile,
            isf: provider.isfProfile.sensitivities,
            carbRatios: provider.carbRatioProfile,
            units: displayUnits,
            basalIncrement: provider.basalIncrement
        )

        return TherapySettingsAnalyzer.generate(
            from: TherapySettingsInput(
                lookbackDays: lookback,
                now: now,
                calendar: calendar,
                profile: profile,
                loops: snapshot.loops,
                glucose: snapshot.glucose,
                carbs: snapshot.carbs,
                boluses: snapshot.boluses,
                excludedWindows: snapshot.windows,
                overrideHistoryStart: Self.overrideHistoryStart(now: now)
            )
        )
    }

    /// The earliest instant whose override history can be trusted.
    ///
    /// Bounded by both the purge policy and the upgrade that introduced it: records older than the
    /// retention window are gone, and records from before this build first ran were already dropped
    /// by the previous three-day purge. The later of the two is the honest boundary.
    private static func overrideHistoryStart(now: Date) -> Date? {
        guard let extendedAt = PropertyPersistentFlags.shared.overrideRunHistoryExtendedAt else {
            return nil
        }
        let retained = now.addingTimeInterval(-Double(OverrideRunStored.historyRetentionDays) * 86_400)
        return max(extendedAt, retained)
    }

    /// `DateInterval(start:end:)` traps on a reversed interval, so a stored run whose end
    /// precedes its start — corrupt data, or a device clock moved backwards — would crash the
    /// tab rather than lose one exclusion window.
    private static func exclusionWindow(from start: Date?, to end: Date) -> DateInterval? {
        guard let start, end >= start else { return nil }
        return DateInterval(start: start, end: end)
    }
}
