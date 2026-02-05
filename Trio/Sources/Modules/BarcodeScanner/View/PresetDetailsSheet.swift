import CoreData
import SwiftUI

/// View displayed after selecting a meal preset to adjust serving size
struct PresetDetailsView: View {
    let preset: MealPresetStored
    var onConfirm: (Decimal, Decimal, Decimal, String) -> Void // carbs, fat, protein, name

    @State private var selectedPreset: ServingPreset = .one
    @State private var customMultiplier: Decimal = 1
    @State private var useCustom: Bool = false

    private var currentMultiplier: Decimal {
        useCustom ? max(0.1, customMultiplier) : selectedPreset.value
    }

    // Base values from preset
    private var baseCarbs: Decimal { preset.carbs?.decimalValue ?? 0 }
    private var baseFat: Decimal { preset.fat?.decimalValue ?? 0 }
    private var baseProtein: Decimal { preset.protein?.decimalValue ?? 0 }

    // Calculated values based on multiplier
    private var adjustedCarbs: Decimal { (baseCarbs * currentMultiplier).rounded(0) }
    private var adjustedFat: Decimal { (baseFat * currentMultiplier).rounded(0) }
    private var adjustedProtein: Decimal { (baseProtein * currentMultiplier).rounded(0) }

    var body: some View {
        Form {
            // Preset Info
            presetInfoSection

            // Serving Size
            servingSizeSection

            // Nutrition Facts
            nutritionSection

            // Actions
            actionsSection
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Adjust Serving")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var presetInfoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(preset.dish ?? "Unnamed Preset")
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 16) {
                    Text("Base:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    MacroTag(label: "C", value: baseCarbs, color: .green)
                    MacroTag(label: "F", value: baseFat, color: .orange)
                    MacroTag(label: "P", value: baseProtein, color: .red)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Saved Food")
        }
    }

    private var servingSizeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("How many servings?")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // Serving preset picker
                HStack(spacing: 8) {
                    ForEach(ServingPreset.allCases, id: \.self) { preset in
                        Button {
                            useCustom = false
                            selectedPreset = preset
                        } label: {
                            Text(preset.label)
                                .font(.system(.body, design: .rounded, weight: .medium))
                                .frame(minWidth: 40)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 4)
                                .background(
                                    !useCustom && selectedPreset == preset
                                        ? Color.blue
                                        : Color(.systemGray5)
                                )
                                .foregroundColor(
                                    !useCustom && selectedPreset == preset
                                        ? .white
                                        : .primary
                                )
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Custom input
                HStack {
                    Toggle("Custom", isOn: $useCustom)
                        .toggleStyle(.button)
                        .tint(useCustom ? .blue : .gray)

                    if useCustom {
                        HStack {
                            TextField("1.0", value: $customMultiplier, format: .number)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)

                            Text("servings")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Serving Size")
        }
    }

    private var nutritionSection: some View {
        Section {
            HStack {
                NutritionPill(label: "Carbs", value: adjustedCarbs, color: .green)
                NutritionPill(label: "Fat", value: adjustedFat, color: .orange)
                NutritionPill(label: "Protein", value: adjustedProtein, color: .red)
            }
            .padding(.vertical, 8)
        } header: {
            let multiplierStr = NSDecimalNumber(decimal: currentMultiplier).stringValue
            Text("Adjusted Nutrition (×\(multiplierStr))")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                onConfirm(adjustedCarbs, adjustedFat, adjustedProtein, preset.dish ?? "")
            } label: {
                Label("Use These Values", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }
}

// MARK: - Sheet Wrapper

/// Sheet wrapper for PresetDetailsView (for modal presentation)
struct PresetDetailsSheet: View {
    let preset: MealPresetStored
    var onConfirm: (Decimal, Decimal, Decimal, String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PresetDetailsView(preset: preset, onConfirm: { carbs, fat, protein, name in
                onConfirm(carbs, fat, protein, name)
            })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

// Note: Decimal.rounded(_:) extension is defined in FoodProduct.swift

#Preview {
    // Preview requires a mock MealPresetStored which needs CoreData context
    Text("Preview requires CoreData context")
}
