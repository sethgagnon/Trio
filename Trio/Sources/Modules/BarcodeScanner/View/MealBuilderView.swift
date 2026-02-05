import CoreData
import SwiftUI

/// Main view for building a meal from multiple scanned items and/or presets
struct MealBuilderView: View {
    @Binding var isPresented: Bool
    var onMealComplete: (Decimal, Decimal, Decimal, String) -> Void // carbs, fat, protein, note

    @State private var mealBuilder = MealBuilder()
    @State private var showScanner = false
    @State private var showPresetPicker = false
    @State private var showFoodDetails = false
    @State private var scannedFood: FoodProduct?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Scanned items list
                if mealBuilder.isEmpty {
                    emptyStateView
                } else {
                    itemsList
                }

                Divider()

                // Totals and actions
                bottomSection
            }
            .navigationTitle("Meal Builder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                BarcodeScannerView(isPresented: $showScanner) { barcode in
                    Task {
                        await handleScannedBarcode(barcode)
                    }
                }
            }
            .sheet(isPresented: $showFoodDetails) {
                if let food = scannedFood {
                    FoodDetailsSheet(
                        food: food,
                        isPresented: $showFoodDetails,
                        onAddToMeal: { food, multiplier in
                            mealBuilder.add(food, servingMultiplier: multiplier)
                        }
                    )
                }
            }
            .sheet(isPresented: $showPresetPicker) {
                PresetPickerSheet(
                    isPresented: $showPresetPicker,
                    onPresetSelected: { carbs, fat, protein, name in
                        // Add to meal builder with adjusted values
                        let source = MealItemSource.preset(
                            name: name,
                            baseCarbs: carbs,
                            baseFat: fat,
                            baseProtein: protein
                        )
                        mealBuilder.items.append(MealItem(source: source, servingMultiplier: 1))
                    }
                )
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "An error occurred")
            }
            .overlay {
                if isLoading {
                    loadingOverlay
                }
            }
        }
    }

    // MARK: - Views

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "fork.knife.circle")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("Build Your Meal")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Add saved foods or scan barcodes")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Button {
                    showPresetPicker = true
                } label: {
                    Label("Saved Foods", systemImage: "star.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .cornerRadius(12)

                Button {
                    showScanner = true
                } label: {
                    Label("Scan", systemImage: "barcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .cornerRadius(12)
            }
            .padding(.horizontal, 16)

            Spacer()
        }
        .padding()
    }

    private var itemsList: some View {
        List {
            ForEach(mealBuilder.items) { item in
                MealItemRow(item: item) {
                    mealBuilder.remove(id: item.id)
                }
            }
            .onDelete { indexSet in
                indexSet.forEach { mealBuilder.remove(at: $0) }
            }

            // Add more items buttons
            Section {
                Button {
                    showPresetPicker = true
                } label: {
                    Label("Add Saved Food", systemImage: "star")
                }

                Button {
                    showScanner = true
                } label: {
                    Label("Scan Barcode", systemImage: "barcode.viewfinder")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var bottomSection: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                // Section header
                Text("MEAL SUMMARY")
                    .font(.system(size: 13))
                    .foregroundColor(Color(.systemGray))
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                // Totals
                HStack(spacing: 12) {
                    TotalPill(label: "Carbs", value: mealBuilder.totalCarbs, color: .green)
                    TotalPill(label: "Fat", value: mealBuilder.totalFat, color: .orange)
                    TotalPill(label: "Protein", value: mealBuilder.totalProtein, color: .red)
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 20)

            // Action button
            Button {
                completeMeal()
            } label: {
                HStack {
                    Spacer()
                    Label("Use This Meal", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                    Spacer()
                }
                .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .disabled(mealBuilder.isEmpty)
            .cornerRadius(12)
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Looking up product...")
                    .font(.headline)
            }
            .padding(30)
            .background(.regularMaterial)
            .cornerRadius(16)
        }
    }

    // MARK: - Actions

    private func handleScannedBarcode(_ barcode: String) async {
        isLoading = true

        do {
            let food = try await NutritionAPIService.shared.fetchProduct(barcode: barcode)
            await MainActor.run {
                isLoading = false
                scannedFood = food
                showFoodDetails = true
            }
        } catch {
            await MainActor.run {
                isLoading = false
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func completeMeal() {
        onMealComplete(
            mealBuilder.totalCarbs,
            mealBuilder.totalFat,
            mealBuilder.totalProtein,
            mealBuilder.combinedName
        )
        isPresented = false
    }
}

/// Row for a single meal item
struct MealItemRow: View {
    let item: MealItem
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)

                    Text(item.servingLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 16) {
                MacroLabel(label: "C", value: item.nutrition.carbs, color: .green)
                MacroLabel(label: "F", value: item.nutrition.fat, color: .orange)
                MacroLabel(label: "P", value: item.nutrition.protein, color: .red)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Small macro label
struct MacroLabel: View {
    let label: String
    let value: Decimal
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text("\(NSDecimalNumber(decimal: value).intValue)g")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// Total pill for bottom section
struct TotalPill: View {
    let label: String
    let value: Decimal
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(NSDecimalNumber(decimal: value).intValue)g")
                .font(.system(.title, design: .rounded, weight: .bold))
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

/// Sheet to pick from saved presets
struct PresetPickerSheet: View {
    @Binding var isPresented: Bool
    var onPresetSelected: (Decimal, Decimal, Decimal, String) -> Void

    @FetchRequest(
        entity: MealPresetStored.entity(),
        sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
    ) var presets: FetchedResults<MealPresetStored>

    @State private var searchText = ""

    private var filteredPresets: [MealPresetStored] {
        if searchText.isEmpty {
            return Array(presets)
        }
        return presets.filter { preset in
            preset.dish?.localizedCaseInsensitiveContains(searchText) ?? false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredPresets.isEmpty {
                    ContentUnavailableView(
                        "No Saved Foods",
                        systemImage: "star.slash",
                        description: Text(
                            searchText
                                .isEmpty ? "Add foods from the Presets menu" : "No matches for '\(searchText)'"
                        )
                    )
                } else {
                    ForEach(filteredPresets) { preset in
                        NavigationLink {
                            PresetDetailsView(
                                preset: preset,
                                onConfirm: { carbs, fat, protein, name in
                                    onPresetSelected(carbs, fat, protein, name)
                                    isPresented = false
                                }
                            )
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.dish ?? "Unnamed")
                                        .font(.body)
                                        .foregroundColor(.primary)

                                    HStack(spacing: 12) {
                                        MacroLabel(label: "C", value: preset.carbs?.decimalValue ?? 0, color: .green)
                                        MacroLabel(label: "F", value: preset.fat?.decimalValue ?? 0, color: .orange)
                                        MacroLabel(label: "P", value: preset.protein?.decimalValue ?? 0, color: .red)
                                    }
                                }

                                Spacer()
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search saved foods")
            .navigationTitle("Add Saved Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

#Preview {
    MealBuilderView(isPresented: .constant(true)) { carbs, fat, protein, note in
        print("Meal: \(carbs)C, \(fat)F, \(protein)P - \(note)")
    }
}
