import Foundation

/// Represents nutrition data for a scanned food product
struct FoodProduct: Codable, Identifiable, Equatable {
    let id: String // barcode
    let name: String
    let brand: String?
    let servingSize: String?
    let servingSizeGrams: Decimal?

    // Nutrition per serving (or per 100g if serving not available)
    let carbohydrates: Decimal
    let fat: Decimal
    let protein: Decimal

    // Per 100g values for reference
    let carbsPer100g: Decimal?
    let fatPer100g: Decimal?
    let proteinPer100g: Decimal?

    let imageUrl: URL?
}
