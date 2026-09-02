import CoreData
import Foundation

extension Stat.StateModel {
    func setupTherapySettingsReport() {
        Task {
            await loadTherapySettingsReport()
        }
    }

    func loadTherapySettingsReport() async {
        await MainActor.run { isTherapyReportLoading = true }
        do {
            let report = try await buildTherapySettingsReport()
            await MainActor.run {
                therapyReport = report
                isTherapyReportLoading = false
            }
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
        let activeOverrideResults = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OverrideStored.self,
            onContext: context,
            predicate: NSPredicate(format: "enabled == YES AND isPreset == NO"),
            key: "date",
            ascending: false
        )
        let activeTempTargetResults = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: TempTargetStored.self,
            onContext: context,
            predicate: NSPredicate(format: "enabled == YES AND isPreset == NO"),
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
                    glucose: determination.glucose?.decimalValue,
                    target: determination.currentTarget?.decimalValue,
                    cob: Decimal(determination.cob),
                    enactedRate: determination.rate?.decimalValue,
                    sensitivityRatio: determination.sensitivityRatio?.decimalValue,
                    insulinSensitivity: determination.insulinSensitivity?.decimalValue,
                    carbRatio: determination.carbRatio?.decimalValue,
                    reason: determination.reason ?? ""
                )
            }
            let glucose = ((glucoseResults as? [GlucoseStored]) ?? []).compactMap { entry -> TherapyGlucoseReading? in
                guard let date = entry.date, entry.glucose > 0 else { return nil }
                return TherapyGlucoseReading(date: date, glucose: Decimal(entry.glucose))
            }
            let carbs = ((carbResults as? [CarbEntryStored]) ?? []).compactMap { entry -> TherapyCarbEntry? in
                guard let date = entry.date else { return nil }
                return TherapyCarbEntry(date: date, carbs: Decimal(entry.carbs), isFPU: entry.isFPU)
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
                guard let startDate = run.startDate else { return nil }
                return DateInterval(start: startDate, end: run.endDate ?? now)
            })
            windows.append(contentsOf: ((tempTargetRunResults as? [TempTargetRunStored]) ?? []).compactMap { run in
                guard let startDate = run.startDate else { return nil }
                return DateInterval(start: startDate, end: run.endDate ?? now)
            })
            for override in (activeOverrideResults as? [OverrideStored]) ?? [] {
                guard override.enabled, let startDate = override.date else { continue }
                let durationMinutes = override.indefinite ? Decimal(lookback * 24 * 60)
                    : (override.duration?.decimalValue ?? 0)
                let endDate = startDate.addingTimeInterval(
                    TimeInterval(NSDecimalNumber(decimal: durationMinutes * 60).doubleValue)
                )
                windows.append(DateInterval(start: startDate, end: max(endDate, now)))
            }
            for target in (activeTempTargetResults as? [TempTargetStored]) ?? [] {
                guard target.enabled, let startDate = target.date else { continue }
                let durationMinutes = target.duration?.decimalValue ?? 0
                let endDate = startDate.addingTimeInterval(
                    TimeInterval(NSDecimalNumber(decimal: durationMinutes * 60).doubleValue)
                )
                windows.append(DateInterval(start: startDate, end: max(endDate, now)))
            }
            return (loops, glucose, carbs, boluses, windows)
        }

        let profile = await MainActor.run {
            TherapyProfileSnapshot(
                basal: provider.basalProfile,
                isf: provider.isfProfile.sensitivities,
                carbRatios: provider.carbRatioProfile,
                units: units,
                basalIncrement: provider.basalIncrement
            )
        }

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
                excludedWindows: snapshot.windows
            )
        )
    }
}
