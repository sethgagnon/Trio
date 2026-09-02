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
                "These numbers are suggestions from your local history. Trio will not change your profile or pump. Change only one setting family at a time."
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
                    "No basal TDD ratio was found on determinations in this window. Basal rows treat the ratio as 1.0 (Adjust Basal off, or older history without a stored ratio)."
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
        case let .basalExtraAfterTdd(medianResidual, usedTddRatio):
            let residual = medianResidual.formatted(.number.precision(.fractionLength(2)))
            if usedTddRatio {
                return String(
                    localized: "Median enacted basal was \(residual)× scheduled × TDD ratio. The loop still wanted more after Adjust Basal."
                )
            }
            return String(
                localized: "Median enacted basal was \(residual)× scheduled. TDD ratio was not on these determinations."
            )
        case let .basalCoveredByAdjustBasal(medianTddRatio):
            let percent = ((medianTddRatio - 1) as NSNumber)
            return String(
                localized: "Adjust Basal is already covering a TDD ratio of \(medianTddRatio.formatted(.number.precision(.fractionLength(2)))) (\(percentFormatter.string(from: percent) ?? "0%")). Do not copy that into the profile."
            )
        case let .basalTooHigh(medianResidual, _):
            return String(
                localized: "Median enacted basal was \(medianResidual.formatted(.number.precision(.fractionLength(2))))× scheduled after Adjust Basal. The loop wanted less in this window."
            )
        case let .isfHighNearTarget(medianDelta):
            return String(
                localized: "Near-target loops (sigmoid ratio ≈ 1) sat a median \(formattedGlucoseDelta(medianDelta)) above target. Profile ISF at target looks too weak. High-BG ISF is Adjustment Factor / Autosens Max — do not paste Calculated Sensitivity."
            )
        case let .isfLowNearTarget(medianDelta):
            return String(
                localized: "Near-target loops (sigmoid ratio ≈ 1) sat a median \(formattedGlucoseDelta(abs(medianDelta))) below target. Profile ISF at target looks too strong."
            )
        case let .crHighAfterMeal(medianDelta, extraSmb, mealCount):
            return String(
                localized: "After \(mealCount) isolated meals, glucose was a median \(formattedGlucoseDelta(medianDelta)) higher at 3–4h, with \(extraSmb.formatted(.number.precision(.fractionLength(1)))) U extra SMBs. A smaller g/U (more aggressive CR) is suggested."
            )
        case let .crLowAfterMeal(medianDelta, extraSmb, mealCount):
            return String(
                localized: "After \(mealCount) isolated meals, glucose was a median \(formattedGlucoseDelta(abs(medianDelta))) lower at 3–4h, with \(extraSmb.formatted(.number.precision(.fractionLength(1)))) U extra SMBs. A larger g/U (weaker CR) is suggested."
            )
        case .insufficientSamples:
            return String(localized: "Not enough isolated samples in this slot to recommend a change.")
        case .roundedToUnchanged:
            return String(localized: "The indicated move rounded back to the current pump/profile step.")
        case .noConsistentSignal:
            return String(localized: "No consistent residual in this slot.")
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
            "Report only — Trio will not change your profile or pump.",
            "Do not paste live Dynamic ISF / Calculated Sensitivity into profile ISF."
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
