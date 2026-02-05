import SwiftUI

/// Sheet displayed after scanning a barcode to show food details and adjust serving
struct FoodDetailsSheet: View {
    let food: FoodProduct
    var onAddToMeal: (FoodProduct, Decimal) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPreset: ServingPreset = .one
    @State private var customMultiplier: Decimal = 1
    @State private var useCustom: Bool = false

    private var currentMultiplier: Decimal {
        useCustom ? max(0.1, customMultiplier) : selectedPreset.value
    }

    private var nutrition: NutritionValues {
        food.nutrition(forServings: currentMultiplier)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Product Info
                productInfoSection

                // Serving Size
                servingSizeSection

                // Nutrition Facts
                nutritionSection

                // Actions
                actionsSection
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Food Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var productInfoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(food.name)
                    .font(.headline)
                    .lineLimit(2)

                if let brand = food.brand {
                    Text(brand)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if let servingLabel = food.servingLabel {
                    HStack {
                        Image(systemName: "scalemass")
                            .foregroundColor(.secondary)
                        Text("Serving: \(servingLabel)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Product")
        }
    }

    private var servingSizeSection: some View {
        Section {
            // Preset buttons
            VStack(alignment: .leading, spacing: 12) {
                Text("How much are you eating?")
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
                NutritionPill(label: "Carbs", value: nutrition.carbs, color: .green)
                NutritionPill(label: "Fat", value: nutrition.fat, color: .orange)
                NutritionPill(label: "Protein", value: nutrition.protein, color: .red)
            }
            .padding(.vertical, 8)
        } header: {
            let multiplierStr = NSDecimalNumber(decimal: currentMultiplier).stringValue
            Text("Nutrition (×\(multiplierStr) serving)")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                onAddToMeal(food, currentMultiplier)
            } label: {
                HStack {
                    Spacer()
                    Label("Add to Meal", systemImage: "plus.circle.fill")
                        .font(.headline)
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }
}

/// Pill-shaped nutrition display
struct NutritionPill: View {
    let label: String
    let value: Decimal
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(NSDecimalNumber(decimal: value).intValue)g")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundColor(color)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.1))
        .cornerRadius(12)
    }
}

#Preview {
    FoodDetailsSheet(
        food: FoodProduct(
            id: "123456789",
            name: "Clif Bar - Chocolate Chip",
            brand: "Clif",
            imageURL: nil,
            carbsPer100g: 54.4,
            fatPer100g: 16.2,
            proteinPer100g: 14.7,
            servingSizeG: 68,
            servingLabel: "1 bar (68g)",
            dataSource: .openFoodFacts
        ),
        onAddToMeal: { _, _ in }
    )
}
