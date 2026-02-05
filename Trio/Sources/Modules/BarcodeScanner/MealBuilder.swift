import Foundation
import SwiftUI

/// A single scanned food item with serving adjustment
struct ScannedMealItem: Identifiable {
    let id = UUID()
    let food: FoodProduct
    var servingMultiplier: Decimal

    init(food: FoodProduct, servingMultiplier: Decimal = 1) {
        self.food = food
        self.servingMultiplier = servingMultiplier
    }

    /// Calculated nutrition for this item
    var nutrition: NutritionValues {
        food.nutrition(forServings: servingMultiplier)
    }

    /// Display label for serving amount
    var servingLabel: String {
        let multiplierDouble = NSDecimalNumber(decimal: servingMultiplier).doubleValue
        if let label = food.servingLabel {
            if servingMultiplier == 1 {
                return label
            } else {
                return String(format: "%.1fx %@", multiplierDouble, label)
            }
        } else {
            let grams = NSDecimalNumber(decimal: food.servingSizeG * servingMultiplier).intValue
            return "\(grams)g"
        }
    }
}

/// Manages multiple scanned food items for a meal
@Observable final class MealBuilder {
    var items: [ScannedMealItem] = []

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

    /// Add a food item to the meal
    func add(_ food: FoodProduct, servingMultiplier: Decimal = 1) {
        let item = ScannedMealItem(food: food, servingMultiplier: servingMultiplier)
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
        items.map(\.food.name).joined(separator: ", ")
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
