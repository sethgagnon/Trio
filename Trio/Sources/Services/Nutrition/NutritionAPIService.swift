import Foundation

/// Errors that can occur when fetching nutrition data
enum NutritionError: LocalizedError {
    case productNotFound
    case networkError(Error)
    case invalidResponse
    case incompleteNutritionData

    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return NSLocalizedString("Product not found", comment: "Barcode not in database")
        case let .networkError(error):
            return error.localizedDescription
        case .invalidResponse:
            return NSLocalizedString("Invalid response from server", comment: "API response error")
        case .incompleteNutritionData:
            return NSLocalizedString("Nutrition information incomplete", comment: "Missing nutrition data")
        }
    }
}

/// Unified service for fetching nutrition data
/// Uses FatSecret as primary source with OpenFoodFacts as fallback
actor NutritionAPIService {
    static let shared = NutritionAPIService()

    private let openFoodFactsBaseURL = "https://world.openfoodfacts.org/api/v2/product"
    private let session: URLSession
    private let decoder: JSONDecoder

    // In-memory cache for session
    private var cache: [String: FoodProduct] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
        decoder = JSONDecoder()
    }

    /// Fetch product by barcode
    /// Tries FatSecret first (if configured), then falls back to OpenFoodFacts
    /// - Parameter barcode: The product barcode (UPC, EAN, etc.)
    /// - Returns: FoodProduct with nutrition information
    func fetchProduct(barcode: String) async throws -> FoodProduct {
        // Check memory cache first
        if let cached = cache[barcode] {
            return cached
        }

        // Try FatSecret first if configured
        if FatSecretConfig.isConfigured {
            do {
                let product = try await FatSecretAPIService.shared.fetchProduct(barcode: barcode)

                // Validate FatSecret data - if it seems suspiciously low, try OpenFoodFacts
                let nutrition = product.nutrition(forServings: 1)
                let totalMacros = nutrition.carbs + nutrition.fat + nutrition.protein

                // If total macros for a serving is less than 5g, data might be incorrect
                // Try OpenFoodFacts to compare
                if totalMacros < 5 {
                    print("FatSecret data seems low (total: \(totalMacros)g), checking OpenFoodFacts...")
                    if let offProduct = try? await fetchFromOpenFoodFacts(barcode: barcode) {
                        let offNutrition = offProduct.nutrition(forServings: 1)
                        let offTotal = offNutrition.carbs + offNutrition.fat + offNutrition.protein

                        // Use OpenFoodFacts if it has significantly more data
                        if offTotal > totalMacros * 2 {
                            print("Using OpenFoodFacts data instead (total: \(offTotal)g)")
                            cache[barcode] = offProduct
                            return offProduct
                        }
                    }
                }

                cache[barcode] = product
                return product
            } catch {
                // Log the error but continue to fallback
                print("FatSecret lookup failed: \(error.localizedDescription), trying OpenFoodFacts...")
            }
        }

        // Fallback to OpenFoodFacts
        return try await fetchFromOpenFoodFacts(barcode: barcode)
    }

    /// Fetch from OpenFoodFacts API
    private func fetchFromOpenFoodFacts(barcode: String) async throws -> FoodProduct {
        guard let url = URL(string: "\(openFoodFactsBaseURL)/\(barcode).json") else {
            throw NutritionError.invalidResponse
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NutritionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 404 {
                throw NutritionError.productNotFound
            }
            throw NutritionError.invalidResponse
        }

        let apiResponse = try decoder.decode(OpenFoodFactsResponse.self, from: data)

        guard apiResponse.isFound, let product = apiResponse.product else {
            throw NutritionError.productNotFound
        }

        guard let foodProduct = product.toFoodProduct() else {
            throw NutritionError.incompleteNutritionData
        }

        // Validate nutrition data
        if foodProduct.carbsPer100g == 0, foodProduct.fatPer100g == 0, foodProduct.proteinPer100g == 0 {
            throw NutritionError.incompleteNutritionData
        }

        cache[barcode] = foodProduct

        return foodProduct
    }

    /// Check if a barcode is cached
    func isCached(barcode: String) -> Bool {
        cache[barcode] != nil
    }

    /// Clear the cache
    func clearCache() {
        cache.removeAll()
    }

    /// Add a product to cache manually (for testing or manual entry)
    func cacheProduct(_ product: FoodProduct) {
        cache[product.id] = product
    }
}
