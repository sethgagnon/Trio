import CoreData
import SwiftUI

/// Sheet displayed after scanning a barcode to show food details and adjust serving
struct FoodDetailsSheet: View {
    @State var food: FoodProduct
    var onAddToMeal: (FoodProduct, Decimal) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var moc
    @State private var selectedPreset: ServingPreset = .one
    @State private var customMultiplier: Decimal = 1
    @State private var useCustom: Bool = false
    @State private var showSavePresetAlert: Bool = false
    @State private var presetName: String = ""
    @State private var showSavedConfirmation: Bool = false
    @State private var isLoadingAI: Bool = false
    @State private var aiError: String?

    private var currentMultiplier: Decimal {
        useCustom ? max(0.1, customMultiplier) : selectedPreset.value
    }

    private var nutrition: NutritionValues {
        food.nutrition(forServings: currentMultiplier)
    }

    private var canUseAI: Bool {
        ClaudeConfig.isConfigured && food.dataSource != .ai
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

            Button {
                presetName = food.name
                showSavePresetAlert = true
            } label: {
                HStack {
                    Spacer()
                    Label("Save as Preset", systemImage: "bookmark.fill")
                        .font(.headline)
                    Spacer()
                }
            }
            .buttonStyle(.bordered)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            // AI Lookup button - only show if Claude is configured and not already AI data
            if canUseAI {
                Button {
                    Task {
                        await lookupWithAI()
                    }
                } label: {
                    HStack {
                        Spacer()
                        if isLoadingAI {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .padding(.trailing, 8)
                            Text("Looking up...")
                                .font(.headline)
                        } else {
                            Label("Lookup with AI", systemImage: "sparkles")
                                .font(.headline)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .disabled(isLoadingAI)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            // Show data source indicator
            HStack {
                Spacer()
                Text("Data from: \(dataSourceLabel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .listRowBackground(Color.clear)
        }
        .alert("Save as Meal Preset", isPresented: $showSavePresetAlert) {
            TextField("Preset Name", text: $presetName)
            Button("Cancel", role: .cancel) {
                presetName = ""
            }
            Button("Save") {
                saveAsPreset()
            }
        } message: {
            Text("Enter a name for this preset")
        }
        .overlay {
            if showSavedConfirmation {
                savedConfirmationOverlay
            }
        }
    }

    private func saveAsPreset() {
        guard !presetName.isEmpty else { return }

        let preset = MealPresetStored(context: moc)
        preset.dish = presetName
        preset.carbs = nutrition.carbs as NSDecimalNumber
        preset.fat = nutrition.fat as NSDecimalNumber
        preset.protein = nutrition.protein as NSDecimalNumber

        do {
            if moc.hasChanges {
                try moc.save()
                showSavedConfirmation = true

                // Hide confirmation after 2 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    showSavedConfirmation = false
                }
            }
        } catch {
            print("Failed to save preset: \(error.localizedDescription)")
        }

        presetName = ""
    }

    private func lookupWithAI() async {
        isLoadingAI = true
        aiError = nil

        do {
            let aiProduct = try await ClaudeNutritionService.shared.fetchNutrition(
                productName: food.name,
                brand: food.brand,
                barcode: food.id
            )

            // Update the food with AI data
            await MainActor.run {
                food = aiProduct
                isLoadingAI = false
            }
        } catch {
            await MainActor.run {
                aiError = error.localizedDescription
                isLoadingAI = false
            }
            print("AI lookup failed: \(error.localizedDescription)")
        }
    }

    private var dataSourceLabel: String {
        switch food.dataSource {
        case .fatSecret:
            return "FatSecret"
        case .openFoodFacts:
            return "OpenFoodFacts"
        case .ai:
            return "Claude AI ✨"
        case .cache:
            return "Cache"
        case .manual:
            return "Manual"
        }
    }

    private var savedConfirmationOverlay: some View {
        VStack {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50))
                .foregroundColor(.green)
            Text("Preset Saved!")
                .font(.headline)
                .foregroundColor(.primary)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .transition(.scale.combined(with: .opacity))
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
