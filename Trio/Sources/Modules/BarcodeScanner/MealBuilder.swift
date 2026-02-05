import CoreData
import Foundation
import SwiftUI

/// Source of a meal item - either scanned barcode or saved preset
enum MealItemSource {
    case scanned(FoodProduct)
    case preset(name: String, baseCarbs: Decimal, baseFat: Decimal, baseProtein: Decimal)

    var name: String {
        switch self {
        case let .scanned(food): return food.name
        case let .preset(name, _, _, _): return name
        }
    }

    var baseCarbs: Decimal {
        switch self {
        case let .scanned(food): return food.carbsPer100g * food.servingSizeG / 100
        case let .preset(_, carbs, _, _): return carbs
        }
    }

    var baseFat: Decimal {
        switch self {
        case let .scanned(food): return food.fatPer100g * food.servingSizeG / 100
        case let .preset(_, _, fat, _): return fat
        }
    }

    var baseProtein: Decimal {
        switch self {
        case let .scanned(food): return food.proteinPer100g * food.servingSizeG / 100
        case let .preset(_, _, _, protein): return protein
        }
    }

    var servingLabel: String? {
        switch self {
        case let .scanned(food): return food.servingLabel
        case .preset: return "1 serving"
        }
    }
}

/// A single meal item with serving adjustment
struct MealItem: Identifiable {
    let id = UUID()
    let source: MealItemSource
    var servingMultiplier: Decimal

    init(source: MealItemSource, servingMultiplier: Decimal = 1) {
        self.source = source
        self.servingMultiplier = servingMultiplier
    }

    /// Calculated nutrition for this item
    var nutrition: NutritionValues {
        NutritionValues(
            carbs: (source.baseCarbs * servingMultiplier).rounded(0),
            fat: (source.baseFat * servingMultiplier).rounded(0),
            protein: (source.baseProtein * servingMultiplier).rounded(0)
        )
    }

    /// Display label for serving amount
    var servingLabel: String {
        let multiplierDouble = NSDecimalNumber(decimal: servingMultiplier).doubleValue
        if let label = source.servingLabel {
            if servingMultiplier == 1 {
                return label
            } else {
                return String(format: "%.1fx %@", multiplierDouble, label)
            }
        } else {
            return String(format: "%.1fx serving", multiplierDouble)
        }
    }

    var name: String { source.name }
}

/// Manages multiple food items for a meal (supports both scanned and presets)
@Observable final class MealBuilder {
    var items: [MealItem] = []

    /// Total nutrition across all items
    var totalNutrition: NutritionValues {
        items.reduce(NutritionValues.zero) { $0 + $1.nutrition }
    }

    /// Total carbs
    var totalCarbs: Decimal { totalNutrition.carbs }

    /// Total fat
    var totalFat: Decimal { totalNutrition.fat }

    /// Total protein
    var totalProtein: Decimal { totalNutrition.protein }

    /// Whether the meal has any items
    var isEmpty: Bool { items.isEmpty }

    /// Number of items
    var count: Int { items.count }

    /// Add a scanned food item to the meal
    func add(_ food: FoodProduct, servingMultiplier: Decimal = 1) {
        let item = MealItem(source: .scanned(food), servingMultiplier: servingMultiplier)
        items.append(item)
    }

    /// Add a preset to the meal
    func addPreset(_ preset: MealPresetStored, servingMultiplier: Decimal = 1) {
        let source = MealItemSource.preset(
            name: preset.dish ?? "Unnamed",
            baseCarbs: preset.carbs?.decimalValue ?? 0,
            baseFat: preset.fat?.decimalValue ?? 0,
            baseProtein: preset.protein?.decimalValue ?? 0
        )
        let item = MealItem(source: source, servingMultiplier: servingMultiplier)
        items.append(item)
    }

    /// Remove an item at index
    func remove(at index: Int) {
        guard index >= 0, index < items.count else { return }
        items.remove(at: index)
    }

    /// Remove an item by ID
    func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Update serving multiplier for an item
    func updateServing(id: UUID, multiplier: Decimal) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].servingMultiplier = multiplier
        }
    }

    /// Clear all items
    func clear() {
        items.removeAll()
    }

    /// Generate a combined name for the meal
    var combinedName: String {
        items.map(\.name).joined(separator: ", ")
    }
}

/// Common serving presets
enum ServingPreset: CaseIterable {
    case quarter
    case half
    case threeQuarter
    case one
    case oneAndHalf
    case two

    var value: Decimal {
        switch self {
        case .quarter: return 0.25
        case .half: return 0.5
        case .threeQuarter: return 0.75
        case .one: return 1.0
        case .oneAndHalf: return 1.5
        case .two: return 2.0
        }
    }

    var label: String {
        switch self {
        case .quarter: return "¼"
        case .half: return "½"
        case .threeQuarter: return "¾"
        case .one: return "1"
        case .oneAndHalf: return "1½"
        case .two: return "2"
        }
    }
}
