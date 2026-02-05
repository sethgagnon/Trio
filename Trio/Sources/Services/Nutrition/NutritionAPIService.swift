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

/// Service for fetching nutrition data from OpenFoodFacts API
actor NutritionAPIService {
    static let shared = NutritionAPIService()

    private let baseURL = "https://world.openfoodfacts.org/api/v2/product"
    private let session: URLSession
    private let decoder: JSONDecoder

    // In-memory cache for session
    private var cache: [String: FoodProduct] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
    }

    /// Fetch product by barcode
    /// - Parameter barcode: The product barcode (UPC, EAN, etc.)
    /// - Returns: FoodProduct with nutrition information
    func fetchProduct(barcode: String) async throws -> FoodProduct {
        // Check memory cache first
        if let cached = cache[barcode] {
            return cached
        }

        // Build URL
        guard let url = URL(string: "\(baseURL)/\(barcode).json") else {
            throw NutritionError.invalidResponse
        }

        // Make request
        let (data, response) = try await session.data(from: url)

        // Check HTTP status
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NutritionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 404 {
                throw NutritionError.productNotFound
            }
            throw NutritionError.invalidResponse
        }

        // Decode response
        let apiResponse = try decoder.decode(OpenFoodFactsResponse.self, from: data)

        // Check if product was found
        guard apiResponse.isFound, let product = apiResponse.product else {
            throw NutritionError.productNotFound
        }

        // Convert to our model
        guard let foodProduct = product.toFoodProduct() else {
            throw NutritionError.incompleteNutritionData
        }

        // Validate nutrition data
        if foodProduct.carbsPer100g == 0, foodProduct.fatPer100g == 0, foodProduct.proteinPer100g == 0 {
            throw NutritionError.incompleteNutritionData
        }

        // Cache for future use
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
