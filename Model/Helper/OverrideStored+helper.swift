import CoreData
import Foundation

extension NSPredicate {
    static var allOverridePresets: NSPredicate {
        NSPredicate(format: "isPreset == %@", true as NSNumber)
    }

    static var lastActiveOverride: NSPredicate {
        // For non-indefinite overrides, we still want to filter by date
        // For indefinite overrides, we want them regardless of date
        NSPredicate(
            format: "(date >= %@ OR indefinite == %@) AND enabled == %@",
            Date.oneDayAgo as NSDate,
            true as NSNumber,
            true as NSNumber
        )
    }
}

extension OverrideStored {
    static func fetch(_ predicate: NSPredicate, ascending: Bool, fetchLimit: Int? = nil) -> NSFetchRequest<OverrideStored> {
        let request = OverrideStored.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: ascending)]
        request.predicate = predicate
        if let fetchLimit = fetchLimit {
            request.fetchLimit = fetchLimit
        }
        return request
    }
}

extension OverrideStored {
    enum EventType: String, JSON {
        case nsExercise = "Exercise"
    }
}

extension OverrideRunStored {
    /// How long completed override runs survive `TrioApp.purgeOldNSManagedObjects`.
    ///
    /// Matches the other therapy-history entities, because anything reasoning over recorded loops
    /// needs to know which of them ran under an override, and history kept for less time than the
    /// loops themselves leaves adjusted loops indistinguishable from ordinary ones.
    ///
    /// Deliberately scoped to the run table. `OverrideStored` keeps its own shorter retention:
    /// `NSPredicate.lastActiveOverride` reads it on every loop cycle to decide the override
    /// currently being dosed under, so its retention is part of the dosing path and is left alone.
    /// Completed runs are read only by history and by Nightscout upload, never by dosing.
    ///
    /// The single source of truth for both the purge and any feature that discloses the limit.
    static let historyRetentionDays = 90
}
