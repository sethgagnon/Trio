import SwiftUI

/// Main view for building a meal from multiple scanned items
struct MealBuilderView: View {
    @Binding var isPresented: Bool
    var onMealComplete: (Decimal, Decimal, Decimal, String) -> Void // carbs, fat, protein, note

    @State private var mealBuilder = MealBuilder()
    @State private var showScanner = false
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

            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No items scanned yet")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Scan food barcodes to build your meal")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showScanner = true
            } label: {
                Label("Scan First Item", systemImage: "barcode.viewfinder")
                    .font(.headline)
                    .padding()
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding()
    }

    private var itemsList: some View {
        List {
            ForEach(mealBuilder.items) { item in
                ScannedItemRow(item: item) {
                    mealBuilder.remove(id: item.id)
                }
            }
            .onDelete { indexSet in
                indexSet.forEach { mealBuilder.remove(at: $0) }
            }

            // Add another item button
            Button {
                showScanner = true
            } label: {
                Label("Scan Another Item", systemImage: "plus.circle")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var bottomSection: some View {
        VStack(spacing: 16) {
            // Totals
            HStack(spacing: 20) {
                TotalPill(label: "Carbs", value: mealBuilder.totalCarbs, color: .green)
                TotalPill(label: "Fat", value: mealBuilder.totalFat, color: .orange)
                TotalPill(label: "Protein", value: mealBuilder.totalProtein, color: .red)
            }
            .padding(.horizontal)
            .padding(.top, 16)

            // Action buttons
            VStack(spacing: 12) {
                Button {
                    completeMeal()
                } label: {
                    HStack {
                        Spacer()
                        Label("Use This Meal", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                        Spacer()
                    }
                    .padding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(mealBuilder.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
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

/// Row for a single scanned item
struct ScannedItemRow: View {
    let item: ScannedMealItem
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.food.name)
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

#Preview {
    MealBuilderView(isPresented: .constant(true)) { carbs, fat, protein, note in
        print("Meal: \(carbs)C, \(fat)F, \(protein)P - \(note)")
    }
}
