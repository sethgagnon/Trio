import CoreData
import SwiftUI

struct FoodSearchBar: View {
    @Binding var searchText: String
    let onScanTapped: () -> Void
    let filteredPresets: [MealPresetStored]
    let onPresetSelected: (MealPresetStored) -> Void
    let useFPUconversion: Bool

    @State private var isSearching = false
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 12) {
                Button(action: onScanTapped) {
                    Image(systemName: "barcode.viewfinder")
                        .font(.system(size: 20))
                        .foregroundStyle(.primary)
                }

                TextField("Search presets...", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .onChange(of: isTextFieldFocused) { _, focused in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSearching = focused
                        }
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.chart)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Dropdown with filtered results
            if !searchText.isEmpty, !filteredPresets.isEmpty {
                VStack(spacing: 0) {
                    ForEach(filteredPresets, id: \.objectID) { preset in
                        Button {
                            onPresetSelected(preset)
                            searchText = ""
                            isTextFieldFocused = false
                        } label: {
                            presetRow(preset)
                        }
                        .buttonStyle(.plain)

                        if preset != filteredPresets.last {
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }
                .background(Color.chart)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                .padding(.top, 4)
            }

            // No results message
            if !searchText.isEmpty, filteredPresets.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text("No presets found")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color.chart)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.top, 4)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder  private func presetRow(_ preset: MealPresetStored) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.dish ?? "")
                    .font(.body)
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    nutritionLabel("C", value: preset.carbs)
                    if useFPUconversion {
                        nutritionLabel("F", value: preset.fat)
                        nutritionLabel("P", value: preset.protein)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.blue)
                .font(.title3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder  private func nutritionLabel(_ label: String, value: NSDecimalNumber?) -> some View {
        if let value = value {
            Text("\(label): \(value.intValue)g")
        }
    }
}
