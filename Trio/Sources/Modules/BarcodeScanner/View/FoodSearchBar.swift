import CoreData
import SwiftUI

/// Combined search bar for meal presets with camera button for barcode scanning
struct FoodSearchBar: View {
    @Binding var searchText: String
    var onScanTapped: () -> Void
    var onPresetSelected: (MealPresetStored) -> Void

    @FetchRequest(
        entity: MealPresetStored.entity(),
        sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
    ) var presets: FetchedResults<MealPresetStored>

    @State private var isExpanded = false
    @FocusState private var isSearchFocused: Bool

    private var filteredPresets: [MealPresetStored] {
        if searchText.isEmpty {
            return Array(presets)
        }
        return presets.filter { preset in
            preset.dish?.localizedCaseInsensitiveContains(searchText) ?? false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar with camera button
            HStack(spacing: 12) {
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)

                    TextField("Search saved foods...", text: $searchText)
                        .focused($isSearchFocused)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .onChange(of: searchText) { _, newValue in
                            isExpanded = !newValue.isEmpty || isSearchFocused
                        }
                        .onChange(of: isSearchFocused) { _, focused in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded = focused || !searchText.isEmpty
                            }
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.systemGray6))
                .cornerRadius(10)

                // Camera button for barcode scanning
                Button {
                    isSearchFocused = false
                    onScanTapped()
                } label: {
                    Image(systemName: "barcode.viewfinder")
                        .font(.system(size: 22))
                        .foregroundColor(.blue)
                        .frame(width: 44, height: 44)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                }
            }

            // Filtered results dropdown
            if isExpanded && !filteredPresets.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredPresets) { preset in
                            PresetResultRow(preset: preset) {
                                // Don't collapse immediately - let parent handle it
                                // This prevents UI state conflicts when parent presents sheet
                                isSearchFocused = false
                                onPresetSelected(preset)
                            }

                            if preset != filteredPresets.last {
                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
                .background(Color(.systemBackground))
                .cornerRadius(10)
                .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                .padding(.top, 4)
            }

            // "No results" state
            if isExpanded && filteredPresets.isEmpty && !searchText.isEmpty {
                HStack {
                    Text("No saved foods match '\(searchText)'")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.systemBackground))
                .cornerRadius(10)
                .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                .padding(.top, 4)
            }
        }
    }
}

/// Row for a single preset in search results
struct PresetResultRow: View {
    let preset: MealPresetStored
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.dish ?? "Unnamed")
                        .font(.body)
                        .foregroundColor(.primary)

                    HStack(spacing: 12) {
                        MacroTag(label: "C", value: preset.carbs?.decimalValue ?? 0, color: .green)
                        MacroTag(label: "F", value: preset.fat?.decimalValue ?? 0, color: .orange)
                        MacroTag(label: "P", value: preset.protein?.decimalValue ?? 0, color: .red)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Small macro tag for search results
struct MacroTag: View {
    let label: String
    let value: Decimal
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
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

#Preview {
    VStack {
        FoodSearchBar(
            searchText: .constant(""),
            onScanTapped: { print("Scan tapped") },
            onPresetSelected: { preset in print("Selected: \(preset.dish ?? "")") }
        )
        .padding()

        Spacer()
    }
}
