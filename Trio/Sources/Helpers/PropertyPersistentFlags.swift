//
//  PropertyPersistentFlags.swift
//  Trio
//
//  Created by Cengiz Deniz on 06.05.25.
//
import Foundation

/// Centralized store for app-wide persistent flags backed by property list (.plist) files.
///
/// This class uses the `@PersistedProperty` wrapper to store simple state flags such as
/// onboarding completion, diagnostics sharing preference, and the last cleanup timestamp.
///
/// All values are persisted independently in the app’s documents directory as `.plist` files,
/// and survive app restarts and reinstallations (unless the sandbox is cleared).
///
/// Accessed as a singleton via `PropertyPersistentFlags.shared`.
final class PropertyPersistentFlags {
    static let shared = PropertyPersistentFlags()

    @PersistedProperty(key: "onboardingCompleted") var onboardingCompleted: Bool?

    @PersistedProperty(key: "lastCleanupDate") var lastCleanupDate: Date?

    /// First launch of a build that keeps override runs for `OverrideRunStored.historyRetentionDays`.
    ///
    /// Earlier builds purged them after three days, so this is the boundary before which nobody can
    /// say which loops ran under an override. Anything reasoning over recorded loops has to treat
    /// the window before it as unverifiable instead of assuming the current policy always applied.
    @PersistedProperty(key: "overrideRunHistoryExtendedAt") var overrideRunHistoryExtendedAt: Date?

    // TODO: This flag can be deleted in March 2027. Check the commit for other places to cleanup.
    @PersistedProperty(key: "hasSeenFatProteinOrderChange") var hasSeenFatProteinOrderChange: Bool?

    // MARK: - Telemetry

    //
    // See Trio/Sources/Services/Telemetry/TelemetryClient.swift.
    // `telemetrySharingEnabled` gates the anonymous-usage POST;
    // `crashlyticsSharingEnabled` is the Crashlytics gate. Both streams are on
    // by default: `nil` means enabled; only an explicit `false` opts out.
    @PersistedProperty(key: "crashlyticsSharingEnabled") var crashlyticsSharingEnabled: Bool?
    @PersistedProperty(key: "telemetrySharingEnabled") var telemetrySharingEnabled: Bool?
    @PersistedProperty(key: "telemetryLastSentAt") var telemetryLastSentAt: Date?
    @PersistedProperty(key: "telemetryLastSentSha") var telemetryLastSentSha: String?
    // Sliding 7-day window of cold-launch timestamps; count is sent as `coldLaunches7d`.
    @PersistedProperty(key: "telemetryColdLaunchTimes") var telemetryColdLaunchTimes: [Date]?
    // Stable per-install UUID. IDFV resets when the user removes all Trio-team apps;
    // this survives independently and is wiped only by deleting Trio itself.
    @PersistedProperty(key: "telemetryInstallId") var telemetryInstallId: String?

    // App Attest "give up" signal — set on a 403 from /api/attest/register, meaning
    // the server has rejected this app_id and there's no point retrying.
    @PersistedProperty(key: "telemetryAttestForbidden") var telemetryAttestForbidden: Bool?

    // Debug override for the telemetry server base URL. Empty/unset → use the
    // production constant in TelemetryClient. Surfaced as a hidden field in
    // App Diagnostics for local testing against a dev server.
    @PersistedProperty(key: "telemetryDebugServerURL") var telemetryDebugServerURL: String?
}
