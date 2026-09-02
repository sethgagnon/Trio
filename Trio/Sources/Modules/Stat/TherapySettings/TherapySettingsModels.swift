import Foundation

/// How far back the therapy-settings report looks.
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

/// Structured reason for a suggested profile tweak. Localized in the view.
enum TherapyRationale: Equatable {
    case basalExtraAfterTdd(medianResidual: Decimal, usedTddRatio: Bool)
    case basalCoveredByAdjustBasal(medianTddRatio: Decimal)
    case basalTooHigh(medianResidual: Decimal, usedTddRatio: Bool)
    case isfHighNearTarget(medianDelta: Decimal)
    case isfLowNearTarget(medianDelta: Decimal)
    case crHighAfterMeal(medianDelta: Decimal, extraSmb: Decimal, mealCount: Int)
    case crLowAfterMeal(medianDelta: Decimal, extraSmb: Decimal, mealCount: Int)
    case insufficientSamples
    case roundedToUnchanged
    case noConsistentSignal
}

struct TherapySettingRow: Identifiable, Equatable {
    var id: String { family.rawValue + "-" + startLabel }
    let family: TherapySettingFamily
    let startLabel: String
    let current: Decimal
    let suggested: Decimal
    /// Signed fraction, e.g. 0.05 = 5% higher. For ISF/CR, negative means a smaller (more aggressive) number.
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
    let mealCount: Int
    let earliestSample: Date?
    let latestSample: Date?
    let insufficientHistory: Bool
    /// Median basal TDD ratio parsed from determinations (`Basal ratio:` in the reason string).
    let medianTddRatio: Decimal?
    let basalRows: [TherapySettingRow]
    let isfRows: [TherapySettingRow]
    let crRows: [TherapySettingRow]
    /// Isolation order: basal, then ISF, then CR. Nil when no family has a high-confidence change.
    let highConfidenceFamilyToChange: TherapySettingFamily?
}

struct TherapyLoopSample: Equatable {
    let date: Date
    let glucose: Decimal?
    let target: Decimal?
    let cob: Decimal
    let enactedRate: Decimal?
    let sensitivityRatio: Decimal?
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

struct TherapyProfileSnapshot: Equatable {
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
}
