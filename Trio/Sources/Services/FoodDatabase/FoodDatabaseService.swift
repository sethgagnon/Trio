import Foundation

/// Protocol for fetching food product nutrition data from a barcode
protocol FoodDatabaseService {
    func fetchProduct(barcode: String) async throws -> FoodProduct
}

/// Errors that can occur when fetching food product data
enum FoodDatabaseError: LocalizedError {
    case productNotFound
    case networkError(Error)
    case invalidResponse
    case missingNutritionData

    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return String(localized: "Product not found in database")
        case .networkError(let error):
            return String(localized: "Network error: \(error.localizedDescription)")
        case .invalidResponse:
            return String(localized: "Invalid response from food database")
        case .missingNutritionData:
            return String(localized: "Nutrition data not available for this product")
        }
    }
}
