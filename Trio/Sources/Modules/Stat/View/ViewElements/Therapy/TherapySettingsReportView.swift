import SwiftUI
import UIKit

struct TherapySettingsReportView: View {
    let state: Stat.StateModel

    private var basalFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }

    private var crFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }

    private var isfFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = state.units == .mmolL ? 1 : 0
        formatter.maximumFractionDigits = state.units == .mmolL ? 1 : 0
        return formatter
    }

    private var percentFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.positivePrefix = "+"
        return formatter
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
                    formatter: basalFormatter,
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
                    formatter: crFormatter,
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
                    "Fewer than 7 days of usable loops. Treat every row as informational until more closed-loop history accumulates."
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
                    "Median TDD basal ratio: \(ratio.formatted(.number.precision(.fractionLength(2)))) (\(percentFormatter.string(from: percent) ?? "0%"))"
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
                ForEach(rows) { row in
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
                            Text(percentFormatter.string(from: row.percentChange as NSNumber) ?? "0%")
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
                    if row.id != rows.last?.id {
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
                    localized: "Median enacted temp basal ÷ recorded TDD basal ratio (\(medianTddRatio.formatted(.number.precision(.fractionLength(2))))) was \(medianRate.formatted(.number.precision(.fractionLength(2)))) U/hr across \(sampleCount) loops with COB ≤ 10 g."
                )
            }
            return String(
                localized: "Median implied profile basal (enacted temp basal ÷ the scale recorded on those determinations) was \(medianRate.formatted(.number.precision(.fractionLength(2)))) U/hr across \(sampleCount) loops with COB ≤ 10 g."
            )
        case let .basalMatchesTddAdjusted(medianTddRatio, sampleCount):
            return String(
                localized: "After dividing by the recorded TDD basal ratio (\(medianTddRatio.formatted(.number.precision(.fractionLength(2))))), \(sampleCount) loops match the current profile. Adjust Basal is already covering that ratio; it is not copied into the basal schedule."
            )
        case let .isfObserved(medianISF, medianDelta, medianInsulin, sampleCount):
            let displayISF = state.units == .mmolL ? medianISF.asMmolL : medianISF
            return String(
                localized: "Median observed ISF = (glucose drop) / insulin from \(sampleCount) corrections with no carbs and no other bolus in the window, near target (sigmoid ratio ≈ 1): drop \(formattedGlucoseDelta(medianDelta)) after \(medianInsulin.formatted(.number.precision(.fractionLength(2)))) U → \(displayISF.formatted(.number.precision(.fractionLength(1)))) \(state.units.rawValue)/U. High-BG Dynamic ISF values are not used. Temp basal above or below your profile is not subtracted, so treat this as an estimate of bolus effect."
            )
        case let .crObserved(medianCR, medianCarbs, medianInsulin, medianGlucoseDelta, sampleCount):
            return String(
                localized: "Median observed CR = carbs / (recorded meal insulin + the net 3–4h glucose change converted with the recorded ISF) from \(sampleCount) meals with no other carbs, external dose, or later manual bolus in the window: \(medianCarbs.formatted(.number.precision(.fractionLength(0)))) g, \(medianInsulin.formatted(.number.precision(.fractionLength(2)))) U, 3–4h change \(formattedGlucoseDelta(medianGlucoseDelta)) → \(medianCR.formatted(.number.precision(.fractionLength(1)))) g/U. The change is measured against the pre-meal glucose, so a high or low starting point is not charged to the meal. Temp basal above or below your profile is not subtracted."
            )
        case .insufficientEvidence:
            return String(
                localized: "Not enough complete recorded events in this slot. No value was inferred."
            )
        case let .roundedToUnchanged(medianImplied):
            return String(
                localized: "Median from recorded events is \(medianImplied.formatted(.number.precision(.fractionLength(2)))), which rounds to the current setting."
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
            "Trio therapy settings report (\(report.lookbackDays) days)",
            "Each suggestion is the median of values computed from complete recorded events. Missing fields are skipped."
        ]
        if let ratio = report.medianTddRatio {
            lines.append(
                "Median TDD basal ratio: \(ratio.formatted(.number.precision(.fractionLength(2)))). Adjust Basal already covers that global ratio."
            )
        }
        if report.insufficientHistory {
            lines.append("Insufficient history (<7 days of usable loops). Informational only.")
        } else if let family = report.highConfidenceFamilyToChange {
            lines.append("Change only the high-confidence family: \(family.displayName).")
        } else {
            lines.append("No high-confidence family this round.")
        }
        lines.append("")
        lines.append(contentsOf: summarySection("Basal", rows: report.basalRows, formatter: basalFormatter, convertsISF: false))
        lines.append(contentsOf: summarySection(
            "ISF",
            rows: report.isfRows,
            formatter: isfFormatter,
            convertsISF: true
        ))
        lines.append(contentsOf: summarySection(
            "Carb ratio",
            rows: report.crRows,
            formatter: crFormatter,
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
            let percent = percentFormatter.string(from: row.percentChange as NSNumber) ?? "0%"
            lines.append(
                "\(row.startLabel)  \(current) → \(suggested) \(row.unit)  (\(percent), n=\(row.sampleCount), \(row.confidence.displayName))  \(rationaleText(row.rationale))"
            )
        }
        lines.append("")
        return lines
    }
}
