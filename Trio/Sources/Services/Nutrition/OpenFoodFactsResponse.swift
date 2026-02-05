import Foundation

/// Response from OpenFoodFacts API
struct OpenFoodFactsResponse: Codable {
    let status: Int // 1 = found, 0 = not found
    let product: OpenFoodFactsProduct?

    var isFound: Bool { status == 1 && product != nil }
}

struct OpenFoodFactsProduct: Codable {
    let code: String?
    let productName: String?
    let brands: String?
    let imageURL: String?
    let servingSize: String?
    let servingQuantity: Double?
    let nutriments: OpenFoodFactsNutriments?

    enum CodingKeys: String, CodingKey {
        case code
        case productName = "product_name"
        case brands
        case imageURL = "image_url"
        case servingSize = "serving_size"
        case servingQuantity = "serving_quantity"
        case nutriments
    }

    /// Convert to our FoodProduct model
    func toFoodProduct() -> FoodProduct? {
        guard let name = productName, !name.isEmpty else { return nil }

        // Parse serving size - default to 100g if not provided
        let servingG: Decimal
        if let qty = servingQuantity, qty > 0 {
            servingG = Decimal(qty)
        } else if let sizeStr = servingSize {
            servingG = parseServingSize(sizeStr)
        } else {
            servingG = 100
        }

        // Get nutrition values - prefer per-serving when available as they're often more accurate
        let carbs: Decimal
        let fat: Decimal
        let protein: Decimal

        // Check if we have valid per-serving values
        let hasServingValues = nutriments?.carbohydratesServing != nil &&
            nutriments?.fatServing != nil &&
            nutriments?.proteinsServing != nil

        if hasServingValues, servingG > 0 {
            // Use per-serving values, convert to per-100g for consistent calculations
            let carbsServing = Decimal(nutriments?.carbohydratesServing ?? 0)
            let fatServing = Decimal(nutriments?.fatServing ?? 0)
            let proteinServing = Decimal(nutriments?.proteinsServing ?? 0)

            carbs = carbsServing / servingG * 100
            fat = fatServing / servingG * 100
            protein = proteinServing / servingG * 100
        } else {
            // Fall back to per-100g values
            carbs = Decimal(nutriments?.carbohydrates100g ?? 0)
            fat = Decimal(nutriments?.fat100g ?? 0)
            protein = Decimal(nutriments?.proteins100g ?? 0)
        }

        return FoodProduct(
            id: code ?? UUID().uuidString,
            name: name,
            brand: brands,
            imageURL: imageURL.flatMap { URL(string: $0) },
            carbsPer100g: carbs,
            fatPer100g: fat,
            proteinPer100g: protein,
            servingSizeG: servingG,
            servingLabel: servingSize,
            dataSource: .openFoodFacts
        )
    }

    /// Parse serving size string to grams
    private func parseServingSize(_ str: String) -> Decimal {
        // Try to extract number from strings like "68g", "1 bar (68g)", "100 ml"
        let pattern = #"(\d+(?:\.\d+)?)\s*(?:g|ml|grams?|milliliters?)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
           let range = Range(match.range(at: 1), in: str),
           let value = Double(str[range])
        {
            return Decimal(value)
        }
        return 100 // Default to 100g
    }
}

struct OpenFoodFactsNutriments: Codable {
    let carbohydrates100g: Double?
    let fat100g: Double?
    let proteins100g: Double?
    let carbohydratesServing: Double?
    let fatServing: Double?
    let proteinsServing: Double?
    let energyKcal100g: Double?
    let sugars100g: Double?
    let fiber100g: Double?
    let sodium100g: Double?

    enum CodingKeys: String, CodingKey {
        case carbohydrates100g = "carbohydrates_100g"
        case fat100g = "fat_100g"
        case proteins100g = "proteins_100g"
        case carbohydratesServing = "carbohydrates_serving"
        case fatServing = "fat_serving"
        case proteinsServing = "proteins_serving"
        case energyKcal100g = "energy-kcal_100g"
        case sugars100g = "sugars_100g"
        case fiber100g = "fiber_100g"
        case sodium100g = "sodium_100g"
    }
}
