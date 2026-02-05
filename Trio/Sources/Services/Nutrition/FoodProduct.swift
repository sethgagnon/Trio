import Foundation

/// Represents a food product with nutrition information
struct FoodProduct: Codable, Identifiable {
    let id: String // barcode
    let name: String
    let brand: String?
    let imageURL: URL?

    // Nutrition per 100g (base unit for calculations)
    let carbsPer100g: Decimal
    let fatPer100g: Decimal
    let proteinPer100g: Decimal

    // Serving information
    let servingSizeG: Decimal
    let servingLabel: String? // "1 bar", "1 cup", etc.

    // Data source tracking
    let dataSource: DataSource

    enum DataSource: String, Codable {
        case fatSecret
        case openFoodFacts
        case ai
        case cache
        case manual
    }

    /// Calculate nutrition for a given serving multiplier
    func nutrition(forServings multiplier: Decimal) -> NutritionValues {
        let servingFactor = (servingSizeG / 100) * multiplier
        return NutritionValues(
            carbs: (carbsPer100g * servingFactor).rounded(0),
            fat: (fatPer100g * servingFactor).rounded(0),
            protein: (proteinPer100g * servingFactor).rounded(0)
        )
    }

    /// Nutrition values for one standard serving
    var nutritionPerServing: NutritionValues {
        nutrition(forServings: 1)
    }
}

/// Nutrition values container
struct NutritionValues {
    let carbs: Decimal
    let fat: Decimal
    let protein: Decimal

    static let zero = NutritionValues(carbs: 0, fat: 0, protein: 0)

    static func + (lhs: NutritionValues, rhs: NutritionValues) -> NutritionValues {
        NutritionValues(
            carbs: lhs.carbs + rhs.carbs,
            fat: lhs.fat + rhs.fat,
            protein: lhs.protein + rhs.protein
        )
    }
}

/// Extension to round Decimal values
extension Decimal {
    func rounded(_ scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}
