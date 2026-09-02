import Foundation

enum TherapyLookback: Int, CaseIterable, Identifiable {
    case seven = 7
    case fourteen = 14

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .seven:
            return String(localized: "7 D", comment: "7-day therapy report interval")
        case .fourteen:
            return String(localized: "14 D", comment: "14-day therapy report interval")
        }
    }
}

enum TherapySettingFamily: String, CaseIterable, Identifiable {
    case basal
    case isf
    case cr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .basal:
            return String(localized: "Basal", comment: "Therapy report family: basal rates")
        case .isf:
            return String(localized: "ISF", comment: "Therapy report family: insulin sensitivity")
        case .cr:
            return String(localized: "Carb Ratio", comment: "Therapy report family: carb ratio")
        }
    }
}

enum TherapyConfidence: String, Comparable {
    case insufficient
    case low
    case medium
    case high

    var displayName: String {
        switch self {
        case .insufficient:
            return String(localized: "Insufficient", comment: "Therapy report confidence")
        case .low:
            return String(localized: "Low", comment: "Therapy report confidence")
        case .medium:
            return String(localized: "Medium", comment: "Therapy report confidence")
        case .high:
            return String(localized: "High", comment: "Therapy report confidence")
        }
    }

    private var rank: Int {
        switch self {
        case .insufficient: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    static func < (lhs: TherapyConfidence, rhs: TherapyConfidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Why no basal row can be produced from the recorded evidence this report reads.
enum BasalEvidenceUnavailable: Equatable {
    /// The only per-slot basal signal in a determination is the temp basal it asked for, and that
    /// is a controller output rather than a measurement of basal need.
    ///
    /// Two recorded behaviours make it unusable. When oref microboluses it writes `rate` as the
    /// low or zero temp that offsets the bolus it just gave (`smbLowTempReq` in `DosingEngine`), so
    /// delivering *extra* insulin is recorded as asking for *less* basal. And outside SMB, the
    /// requested rate is the profile rate plus a correction for predicted deviation, so a run of
    /// boluses is followed by zero temps that state there is surplus insulin on board — not that
    /// the schedule is too high.
    ///
    /// Reading either as profile evidence understates basal exactly when the most insulin was
    /// given. Deriving basal honestly needs delivered insulin measured over carb-free, bolus-free
    /// windows, which this report does not yet compute.
    case requestedRateIsNotBasalNeed
}

/// Evidence behind a row. Every associated value is computed from recorded history.
enum TherapyRationale: Equatable {
    case isfObserved(medianISF: Decimal, medianDelta: Decimal, medianInsulin: Decimal, sampleCount: Int)
    case crObserved(
        medianCR: Decimal,
        medianCarbs: Decimal,
        medianInsulin: Decimal,
        medianGlucoseDelta: Decimal,
        sampleCount: Int
    )
    case insufficientEvidence
    case roundedToUnchanged(medianImplied: Decimal)
    /// The evidence pointed below the lowest value the setting may take, so the row keeps the
    /// current value. Distinct from `roundedToUnchanged`, which means the evidence agreed with it.
    case belowSafetyFloor(medianImplied: Decimal, floor: Decimal)
}

struct TherapySettingRow: Identifiable, Equatable {
    /// `startMinutes` rather than the label: two schedule entries with the same `HH:mm` would
    /// otherwise collide and give `ForEach` duplicate ids.
    var id: String { "\(family.rawValue)-\(startMinutes)" }
    let family: TherapySettingFamily
    let startLabel: String
    let startMinutes: Int
    let current: Decimal
    let suggested: Decimal
    let percentChange: Decimal
    let sampleCount: Int
    let confidence: TherapyConfidence
    let rationale: TherapyRationale
    let unit: String

    var hasChange: Bool { suggested != current }
}

struct TherapySettingsReport: Equatable {
    let lookbackDays: Int
    let loopCount: Int
    let usableLoopCount: Int
    let crSampleCount: Int
    let earliestSample: Date?
    let latestSample: Date?
    let insufficientHistory: Bool
    /// Why the basal family carries no rows, or nil when it does.
    let basalUnavailable: BasalEvidenceUnavailable?
    /// The lookback starts before override history was being kept, so some adjusted loops in this
    /// window cannot be identified and excluded.
    let overrideHistoryIncomplete: Bool
    /// The earliest instant whose override history can be trusted, or nil if that is unknown.
    let overrideHistoryStart: Date?
    let medianTddRatio: Decimal?
    let basalRows: [TherapySettingRow]
    let isfRows: [TherapySettingRow]
    let crRows: [TherapySettingRow]
    let highConfidenceFamilyToChange: TherapySettingFamily?
}

/// One recorded `OrefDetermination`, reduced to the fields the report treats as evidence.
struct TherapyLoopSample: Equatable {
    let date: Date
    let cob: Decimal
    let sensitivityRatio: Decimal?
    let insulinSensitivity: Decimal?
    let reason: String
}

struct TherapyGlucoseReading: Equatable {
    let date: Date
    let glucose: Decimal
}

struct TherapyCarbEntry: Equatable {
    let date: Date
    let carbs: Decimal
    let isFPU: Bool
}

struct TherapyBolus: Equatable {
    let date: Date
    let amount: Decimal
    let isSMB: Bool
    let isExternal: Bool
}

/// Not `Equatable`: `CarbRatios` and `InsulinSensitivityEntry` are `JSON`-only, so the
/// conformance cannot be synthesized, and nothing compares two snapshots.
struct TherapyProfileSnapshot {
    let basal: [BasalProfileEntry]
    let isf: [InsulinSensitivityEntry]
    let carbRatios: CarbRatios
    let units: GlucoseUnits
    let basalIncrement: Decimal
}

struct TherapySettingsInput {
    let lookbackDays: Int
    let now: Date
    let calendar: Calendar
    let profile: TherapyProfileSnapshot
    let loops: [TherapyLoopSample]
    let glucose: [TherapyGlucoseReading]
    let carbs: [TherapyCarbEntry]
    let boluses: [TherapyBolus]
    let excludedWindows: [DateInterval]
    /// The earliest instant for which override history is actually on disk, not the retention
    /// policy in days.
    ///
    /// The two differ for a long time after an upgrade. Trio kept override runs for three days
    /// before `OverrideRunStored.historyRetentionDays`, so a store can be governed by a 90-day
    /// policy while holding three days of records, and a policy-based check would call a
    /// fortnight of unverifiable loops fully verified. Nil means the caller cannot establish the
    /// boundary, which the report treats as no coverage rather than full coverage.
    let overrideHistoryStart: Date?
}
