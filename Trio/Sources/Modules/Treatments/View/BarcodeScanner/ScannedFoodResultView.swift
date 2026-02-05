import SwiftUI

struct ScannedFoodResultView: View {
    let product: FoodProduct
    let useFPUconversion: Bool
    let onConfirm: (Decimal, Decimal, Decimal) -> Void // carbs, fat, protein
    let onSaveAsPreset: ((FoodProduct) -> Void)?
    let onCancel: () -> Void

    @State private var servingMultiplier: Decimal = 1
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) var appState

    private var adjustedCarbs: Decimal { product.carbohydrates * servingMultiplier }
    private var adjustedFat: Decimal { product.fat * servingMultiplier }
    private var adjustedProtein: Decimal { product.protein * servingMultiplier }

    var body: some View {
        NavigationStack {
            Form {
                productInfoSection
                servingSection
                nutritionSection
                actionsSection
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Scanned Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    @ViewBuilder  private var productInfoSection: some View {
        Section {
            HStack {
                if let imageUrl = product.imageUrl {
                    AsyncImage(url: imageUrl) { image in
                        image.resizable()
                            .aspectRatio(contentMode: .fit)
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(product.name)
                        .font(.headline)
                    if let brand = product.brand {
                        Text(brand)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let servingSize = product.servingSize {
                HStack {
                    Text("Serving Size")
                    Spacer()
                    Text(servingSize)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Product")
        }
        .listRowBackground(Color.chart)
    }

    @ViewBuilder  private var servingSection: some View {
        Section {
            Stepper(value: $servingMultiplier, in: 0.25 ... 10, step: 0.25) {
                HStack {
                    Text("Servings")
                    Spacer()
                    Text("\(servingMultiplier as NSNumber, formatter: servingFormatter)")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Amount")
        }
        .listRowBackground(Color.chart)
    }

    @ViewBuilder  private var nutritionSection: some View {
        Section {
            nutritionRow("Carbs", value: adjustedCarbs, color: .blue)
            if useFPUconversion {
                nutritionRow("Fat", value: adjustedFat, color: .orange)
                nutritionRow("Protein", value: adjustedProtein, color: .red)
            }
        } header: {
            Text("Nutrition")
        }
        .listRowBackground(Color.chart)
    }

    @ViewBuilder  private var actionsSection: some View {
        Section {
            Button {
                onConfirm(adjustedCarbs, adjustedFat, adjustedProtein)
            } label: {
                Text("Add to Treatments")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.blue)

            if let saveAsPreset = onSaveAsPreset {
                Button {
                    saveAsPreset(product)
                } label: {
                    Text("Save as Meal Preset")
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.chart)
            }
        }
    }

    @ViewBuilder  private func nutritionRow(_ label: String, value: Decimal, color: Color) -> some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
            Spacer()
            Text("\(roundToInt(value)) g")
                .fontWeight(.medium)
        }
    }

    private func roundToInt(_ value: Decimal) -> Int {
        NSDecimalNumber(decimal: value).intValue
    }

    private var servingFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter
    }
}
