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
/// Priority: FatSecret -> OpenFoodFacts -> Claude AI (if configured)
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
    /// Tries FatSecret first (if configured), then OpenFoodFacts, then Claude AI
    /// - Parameter barcode: The product barcode (UPC, EAN, etc.)
    /// - Returns: FoodProduct with nutrition information
    func fetchProduct(barcode: String) async throws -> FoodProduct {
        // Check memory cache first
        if let cached = cache[barcode] {
            return cached
        }

        var bestProduct: FoodProduct?
        var productName: String?
        var productBrand: String?

        // Try FatSecret first if configured
        if FatSecretConfig.isConfigured {
            do {
                let product = try await FatSecretAPIService.shared.fetchProduct(barcode: barcode)
                productName = product.name
                productBrand = product.brand
                bestProduct = product
                print("FatSecret found: \(product.name)")
            } catch {
                print("FatSecret lookup failed: \(error.localizedDescription)")
            }
        }

        // Try OpenFoodFacts
        do {
            let offProduct = try await fetchFromOpenFoodFacts(barcode: barcode)
            productName = productName ?? offProduct.name
            productBrand = productBrand ?? offProduct.brand
            print("OpenFoodFacts found: \(offProduct.name)")

            // Compare with FatSecret result if we have both
            if let existing = bestProduct {
                let existingNutrition = existing.nutrition(forServings: 1)
                let offNutrition = offProduct.nutrition(forServings: 1)
                let existingTotal = existingNutrition.carbs + existingNutrition.fat + existingNutrition.protein
                let offTotal = offNutrition.carbs + offNutrition.fat + offNutrition.protein

                // Use the source with higher macro totals (more likely to be accurate)
                if offTotal > existingTotal {
                    print("Using OpenFoodFacts (higher macros: \(offTotal)g vs \(existingTotal)g)")
                    bestProduct = offProduct
                }
            } else {
                bestProduct = offProduct
            }
        } catch {
            print("OpenFoodFacts lookup failed: \(error.localizedDescription)")
        }

        // If we have a product from barcode databases, validate and potentially use AI
        if let product = bestProduct {
            let nutrition = product.nutrition(forServings: 1)
            let totalMacros = nutrition.carbs + nutrition.fat + nutrition.protein

            // If data seems suspiciously low and Claude is configured, verify with AI
            if totalMacros < 15, ClaudeConfig.isConfigured {
                print("Barcode data seems low (total: \(totalMacros)g), checking with Claude AI...")
                if let aiProduct = try? await fetchFromClaude(
                    productName: product.name,
                    brand: product.brand,
                    barcode: barcode
                ) {
                    let aiNutrition = aiProduct.nutrition(forServings: 1)
                    let aiTotal = aiNutrition.carbs + aiNutrition.fat + aiNutrition.protein

                    // Use AI data if it's significantly higher (more accurate)
                    if aiTotal > totalMacros * 1.5 {
                        print("Using Claude AI data (total: \(aiTotal)g vs \(totalMacros)g)")
                        cache[barcode] = aiProduct
                        return aiProduct
                    }
                }
            }

            cache[barcode] = product
            return product
        }

        // Last resort: Try Claude AI if we have no data but know the product name
        if let name = productName, ClaudeConfig.isConfigured {
            print("No barcode data found, trying Claude AI for: \(name)")
            let aiProduct = try await fetchFromClaude(
                productName: name,
                brand: productBrand,
                barcode: barcode
            )
            cache[barcode] = aiProduct
            return aiProduct
        }

        throw NutritionError.productNotFound
    }

    /// Fetch nutrition data using Claude AI
    private func fetchFromClaude(productName: String, brand: String?, barcode: String) async throws -> FoodProduct {
        try await ClaudeNutritionService.shared.fetchNutrition(
            productName: productName,
            brand: brand,
            barcode: barcode
        )
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
