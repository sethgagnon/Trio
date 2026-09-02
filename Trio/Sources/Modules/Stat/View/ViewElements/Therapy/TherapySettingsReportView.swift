import SwiftUI
import UIKit

struct TherapySettingsReportView: View {
    let state: Stat.StateModel

    // Cached rather than computed: each row reads the percent and ISF formatters, so a computed
    // property rebuilds hundreds of `NumberFormatter`s per `body` evaluation.
    private static let basalFormatter = decimalFormatter(fractionDigits: 2)
    private static let crFormatter = decimalFormatter(fractionDigits: 1)
    private static let mgdLFormatter = decimalFormatter(fractionDigits: 0)
    private static let mmolLFormatter = decimalFormatter(fractionDigits: 1)

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.positivePrefix = "+"
        return formatter
    }()

    private static func decimalFormatter(fractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter
    }

    private var isfFormatter: NumberFormatter {
        state.units == .mmolL ? Self.mmolLFormatter : Self.mgdLFormatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Stat.RootView.Constants.spacing) {
            if state.isTherapyReportLoading, state.therapyReport == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let report = state.therapyReport {
                warningBanner(report)
                evidenceCard(report)
                tddRatioCard(report)
                familyCard(
                    title: String(localized: "Basal"),
                    rows: report.basalRows,
                    formatter: Self.basalFormatter,
                    highlighted: report.highConfidenceFamilyToChange == .basal
                )
                familyCard(
                    title: String(localized: "Insulin Sensitivity"),
                    rows: report.isfRows,
                    formatter: isfFormatter,
                    highlighted: report.highConfidenceFamilyToChange == .isf,
                    convertsISF: true
                )
                familyCard(
                    title: String(localized: "Carb Ratio"),
                    rows: report.crRows,
                    formatter: Self.crFormatter,
                    highlighted: report.highConfidenceFamilyToChange == .cr
                )
                copyButton(report)
            } else {
                ContentUnavailableView(
                    String(localized: "No Therapy Data"),
                    systemImage: "cross.vial",
                    description: Text("Therapy setting suggestions will appear here once loop history is available.")
                )
            }
        }
    }

    @ViewBuilder private func warningBanner(_ report: TherapySettingsReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Report only")
                .font(.headline)
            Text(
                "Each suggestion is the median of values computed from complete recorded events (glucose, insulin, carbs, and loop fields). Missing fields are skipped, not filled in. Trio will not change your profile or pump. Change only one setting family at a time."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            if report.insufficientHistory {
                Text(
                    "This window holds fewer than \(TherapySettingsAnalyzer.minHistoryDays) days of loop history or fewer than \(TherapySettingsAnalyzer.minUsableLoops) usable loops. Treat every row as informational until more closed-loop history accumulates."
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            } else if let family = report.highConfidenceFamilyToChange {
                Text(
                    "Change only the high-confidence family this round: \(family.displayName). Leave the others until you re-evaluate."
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            } else {
                Text("No family is high confidence yet. Use the rows as a signal, not as a change to make today.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Stat.RootView.Constants.cornerRadius)
                .fill(Color.orange.opacity(0.12))
        )
    }

    @ViewBuilder private func evidenceCard(_ report: TherapySettingsReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Evidence Used")
                .font(.headline)
            if let earliest = report.earliestSample, let latest = report.latestSample {
                Text(
                    "\(earliest.formatted(date: .abbreviated, time: .shortened)) to \(latest.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.subheadline)
            }
            Text(
                "\(report.usableLoopCount) usable loops of \(report.loopCount) in range, \(report.crSampleCount) meals behind the carb ratio rows."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            if report.overrideHistoryIncomplete {
                Text(
                    "Override history is kept for only \(TherapySettingsAnalyzer.overrideHistoryRetentionDays) days, so loops run under an override earlier in this window cannot be identified and are counted as ordinary evidence."
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Stat.RootView.Constants.cornerRadius)
                .fill(Color.secondary.opacity(Stat.RootView.Constants.backgroundOpacity))
        )
    }

    @ViewBuilder private func tddRatioCard(_ report: TherapySettingsReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Adjust Basal")
                .font(.headline)
            if let ratio = report.medianTddRatio {
                let percent = (ratio - 1) as NSNumber
                Text(
                    "Median TDD basal ratio: \(ratio.formatted(.number.precision(.fractionLength(2)))) (\(Self.percentFormatter.string(from: percent) ?? "0%"))"
                )
                Text(
                    "Recent TDD relative to your ~10-day average is already applied by Adjust Basal. Do not copy that global ratio into your basal profile. The basal rows below are the extra the loop still wanted after that ratio."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Text(
                    "No TDD basal ratio was parsed in this window. Each loop is included only when a recorded scale is present: a numeric Basal ratio, Dynamic ISF on with Adjust Basal off (enacted rate is unscaled), or a numeric Autosens ratio on non-dynamic loops. Missing or unreadable ratios are skipped."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Text(
                "Live Dynamic ISF is temporary and glucose-dependent. Do not paste Calculated Sensitivity into your ISF profile."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Stat.RootView.Constants.cornerRadius)
                .fill(Color.secondary.opacity(Stat.RootView.Constants.backgroundOpacity))
        )
    }

    @ViewBuilder private func familyCard(
        title: String,
        rows: [TherapySettingRow],
        formatter: NumberFormatter,
        highlighted: Bool,
        convertsISF: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                if highlighted {
                    Text("Change this family")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(Capsule())
                }
            }

            if rows.isEmpty {
                Text("No profile entries found.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.startLabel)
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .leading)
                            Text(formattedValue(row.current, formatter: formatter, convertsISF: convertsISF))
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(formattedValue(row.suggested, formatter: formatter, convertsISF: convertsISF))
                                .fontWeight(row.hasChange ? .semibold : .regular)
                                .foregroundStyle(row.hasChange ? Color.orange : Color.primary)
                            Text(row.unit)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Self.percentFormatter.string(from: row.percentChange as NSNumber) ?? "0%")
                                .foregroundStyle(row.hasChange ? Color.orange : Color.secondary)
                        }
                        .font(.subheadline)

                        HStack {
                            Text(row.confidence.displayName)
                            Text("n=\(row.sampleCount)")
                            Spacer()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text(rationaleText(row.rationale))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if index < rows.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Stat.RootView.Constants.cornerRadius)
                .fill(Color.secondary.opacity(Stat.RootView.Constants.backgroundOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Stat.RootView.Constants.cornerRadius)
                .stroke(highlighted ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
    }

    private func copyButton(_ report: TherapySettingsReport) -> some View {
        Button {
            UIPasteboard.general.string = summaryText(report)
        } label: {
            Label(
                String(localized: "Copy summary"),
                systemImage: "doc.on.doc"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func formattedValue(_ value: Decimal, formatter: NumberFormatter, convertsISF: Bool) -> String {
        let display = convertsISF && state.units == .mmolL ? value.asMmolL : value
        return formatter.string(from: display as NSNumber) ?? "\(display)"
    }

    private func rationaleText(_ rationale: TherapyRationale) -> String {
        switch rationale {
        case let .basalImplied(medianRate, medianTddRatio, sampleCount):
            if let medianTddRatio {
                return String(
                    localized: "Median requested temp basal ÷ recorded TDD basal ratio (\(medianTddRatio.formatted(.number.precision(.fractionLength(2))))) was \(medianRate.formatted(.number.precision(.fractionLength(2)))) U/hr across \(sampleCount) loops with COB ≤ 10 g.",
                    comment: "Basal rationale when every counted loop recorded a TDD ratio"
                )
            }
            return String(
                localized: "Median implied profile basal was \(medianRate.formatted(.number.precision(.fractionLength(2)))) U/hr across \(sampleCount) loops with COB ≤ 10 g. Loops that requested a rate are divided by the scale recorded on them; loops where the loop recorded that the profile rate was already right count as that rate, and zero temps count as zero.",
                comment: "Basal rationale when the counted loops did not all record a TDD ratio"
            )
        case let .basalMatchesTddAdjusted(medianTddRatio, sampleCount):
            return String(
                localized: "After dividing by the recorded TDD basal ratio (\(medianTddRatio.formatted(.number.precision(.fractionLength(2))))), \(sampleCount) loops round to the current profile rate. Adjust Basal is already covering that ratio; it is not copied into the basal schedule.",
                comment: "Basal rationale when the evidence agrees with the current setting"
            )
        case let .isfObserved(medianISF, medianDelta, medianInsulin, sampleCount):
            let displayISF = state.units == .mmolL ? medianISF.asMmolL : medianISF
            return String(
                localized: "Median observed ISF = (glucose drop) / insulin from \(sampleCount) corrections that recorded a sensitivity ratio between \(TherapySettingsAnalyzer.minISFSensitivityRatio.formatted(.number.precision(.fractionLength(2)))) and \(TherapySettingsAnalyzer.maxISFSensitivityRatio.formatted(.number.precision(.fractionLength(2)))), with no carbs and no other dose in the window: drop \(formattedGlucoseDelta(medianDelta)) after \(medianInsulin.formatted(.number.precision(.fractionLength(2)))) U → \(displayISF.formatted(.number.precision(.fractionLength(1)))) \(state.units.rawValue)/U. Corrections where glucose did not fall cannot yield a sensitivity and are left out, which leans this number high. Temp basal above or below your profile is not subtracted, so treat it as an estimate of bolus effect.",
                comment: "ISF rationale stating the recorded gate and the known bias"
            )
        case let .crObserved(medianCR, medianCarbs, medianInsulin, medianGlucoseDelta, sampleCount):
            return String(
                localized: "Median observed CR = carbs / (recorded meal insulin + the net 3–4h glucose change converted with the recorded ISF) from \(sampleCount) meals with no other carbs, external dose, earlier correction, or later manual bolus in the window: \(medianCarbs.formatted(.number.precision(.fractionLength(0)))) g, \(medianInsulin.formatted(.number.precision(.fractionLength(2)))) U, 3–4h change \(formattedGlucoseDelta(medianGlucoseDelta)) → \(medianCR.formatted(.number.precision(.fractionLength(1)))) g/U. Insulin from \(TherapySettingsAnalyzer.preBolusWindowMinutes.formatted(.number.precision(.fractionLength(0)))) minutes before the entry onward counts as meal insulin. The change is measured against the pre-meal glucose, so a high or low starting point is not charged to the meal. Temp basal above or below your profile is not subtracted.",
                comment: "Carb ratio rationale"
            )
        case .insufficientEvidence:
            return String(
                localized: "Not enough complete recorded events in this slot. No value was inferred.",
                comment: "Rationale when a slot has too few samples"
            )
        case let .roundedToUnchanged(medianImplied):
            return String(
                localized: "Median from recorded events is \(medianImplied.formatted(.number.precision(.fractionLength(2)))), which rounds to the current setting.",
                comment: "Rationale when the evidence agrees with the current setting"
            )
        case let .belowSafetyFloor(medianImplied, floor):
            return String(
                localized: "Median from recorded events is \(medianImplied.formatted(.number.precision(.fractionLength(2)))), below the lowest value this setting may take (\(floor.formatted(.number.precision(.fractionLength(2))))). The row keeps your current value: the evidence points lower than can be suggested, so review it rather than reading this as agreement.",
                comment: "Rationale when the evidence falls below the minimum allowed value"
            )
        }
    }

    private func formattedGlucoseDelta(_ delta: Decimal) -> String {
        let display = state.units == .mmolL ? delta.asMmolL : delta
        let formatted = isfFormatter.string(from: display as NSNumber) ?? "\(display)"
        return "\(formatted) \(state.units.rawValue)"
    }

    private func summaryText(_ report: TherapySettingsReport) -> String {
        var lines: [String] = [
            String(
                localized: "Trio therapy settings report (\(report.lookbackDays) days)",
                comment: "Header of the copyable therapy report"
            ),
            String(
                localized: "Each suggestion is the median of values computed from complete recorded events. Missing fields are skipped.",
                comment: "Method line of the copyable therapy report"
            )
        ]
        if let ratio = report.medianTddRatio {
            lines.append(
                String(
                    localized: "Median TDD basal ratio: \(ratio.formatted(.number.precision(.fractionLength(2)))). Adjust Basal already covers that global ratio.",
                    comment: "TDD ratio line of the copyable therapy report"
                )
            )
        }
        if let earliest = report.earliestSample, let latest = report.latestSample {
            lines.append(
                String(
                    localized: "Evidence window: \(earliest.formatted(date: .abbreviated, time: .shortened)) to \(latest.formatted(date: .abbreviated, time: .shortened)); \(report.usableLoopCount) of \(report.loopCount) loops usable, \(report.crSampleCount) carb ratio meals.",
                    comment: "Evidence window line of the copyable therapy report"
                )
            )
        }
        if report.overrideHistoryIncomplete {
            lines.append(
                String(
                    localized: "Override history is kept for only \(TherapySettingsAnalyzer.overrideHistoryRetentionDays) days, so earlier overridden loops are counted as ordinary evidence.",
                    comment: "Override retention caveat in the copyable therapy report"
                )
            )
        }
        if report.insufficientHistory {
            lines.append(
                String(
                    localized: "Insufficient history (under \(TherapySettingsAnalyzer.minHistoryDays) days or \(TherapySettingsAnalyzer.minUsableLoops) usable loops). Informational only.",
                    comment: "Insufficient history line of the copyable therapy report"
                )
            )
        } else if let family = report.highConfidenceFamilyToChange {
            lines.append(
                String(
                    localized: "Change only the high-confidence family: \(family.displayName).",
                    comment: "Guidance line of the copyable therapy report"
                )
            )
        } else {
            lines.append(
                String(
                    localized: "No high-confidence family this round.",
                    comment: "Guidance line of the copyable therapy report when nothing is high confidence"
                )
            )
        }
        lines.append("")
        lines.append(contentsOf: summarySection(
            TherapySettingFamily.basal.displayName,
            rows: report.basalRows,
            formatter: Self.basalFormatter,
            convertsISF: false
        ))
        lines.append(contentsOf: summarySection(
            TherapySettingFamily.isf.displayName,
            rows: report.isfRows,
            formatter: isfFormatter,
            convertsISF: true
        ))
        lines.append(contentsOf: summarySection(
            TherapySettingFamily.cr.displayName,
            rows: report.crRows,
            formatter: Self.crFormatter,
            convertsISF: false
        ))
        return lines.joined(separator: "\n")
    }

    private func summarySection(
        _ title: String,
        rows: [TherapySettingRow],
        formatter: NumberFormatter,
        convertsISF: Bool
    ) -> [String] {
        var lines = [title]
        for row in rows {
            let current = formattedValue(row.current, formatter: formatter, convertsISF: convertsISF)
            let suggested = formattedValue(row.suggested, formatter: formatter, convertsISF: convertsISF)
            let percent = Self.percentFormatter.string(from: row.percentChange as NSNumber) ?? "0%"
            lines.append(
                "\(row.startLabel)  \(current) → \(suggested) \(row.unit)  (\(percent), n=\(row.sampleCount), \(row.confidence.displayName))  \(rationaleText(row.rationale))"
            )
        }
        lines.append("")
        return lines
    }
}
