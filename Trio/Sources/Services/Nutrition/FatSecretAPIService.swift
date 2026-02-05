import Foundation

/// Service for fetching nutrition data from FatSecret API
/// Requires OAuth 2.0 client credentials - set via FatSecretConfig
actor FatSecretAPIService {
    static let shared = FatSecretAPIService()

    private let baseURL = "https://platform.fatsecret.com/rest"
    private let tokenURL = "https://oauth.fatsecret.com/connect/token"
    private let session: URLSession
    private let decoder: JSONDecoder

    // OAuth token management
    private var accessToken: String?
    private var tokenExpiration: Date?

    // In-memory cache
    private var cache: [String: FoodProduct] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
        decoder = JSONDecoder()
    }

    /// Fetch product by barcode using FatSecret API
    func fetchProduct(barcode: String) async throws -> FoodProduct {
        // Check cache first
        if let cached = cache[barcode] {
            return cached
        }

        // Ensure we have valid credentials
        guard FatSecretConfig.isConfigured else {
            throw FatSecretError.notConfigured
        }

        // Get OAuth token
        let token = try await getAccessToken()

        // Step 1: Find food_id from barcode
        let foodId = try await findFoodId(barcode: barcode, token: token)

        // Step 2: Get food details
        let product = try await getFoodDetails(foodId: foodId, token: token, barcode: barcode)

        // Cache the result
        cache[barcode] = product

        return product
    }

    // MARK: - Private Methods

    private func getAccessToken() async throws -> String {
        // Return cached token if still valid
        if let token = accessToken, let expiration = tokenExpiration, Date() < expiration {
            return token
        }

        // Request new token
        guard let url = URL(string: tokenURL) else {
            throw FatSecretError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let credentials = "\(FatSecretConfig.clientId):\(FatSecretConfig.clientSecret)"
        guard let credentialsData = credentials.data(using: .utf8) else {
            throw FatSecretError.authenticationFailed
        }
        let base64Credentials = credentialsData.base64EncodedString()
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")

        let body = "grant_type=client_credentials&scope=barcode"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw FatSecretError.authenticationFailed
        }

        let tokenResponse = try decoder.decode(FatSecretTokenResponse.self, from: data)
        accessToken = tokenResponse.accessToken
        tokenExpiration = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn - 60)) // Refresh 1 min early

        return tokenResponse.accessToken
    }

    private func findFoodId(barcode: String, token: String) async throws -> String {
        // Format barcode to GTIN-13 (pad with leading zeros if needed)
        let gtin13 = barcode.count < 13 ? String(repeating: "0", count: 13 - barcode.count) + barcode : barcode

        guard let url = URL(string: "\(baseURL)/food/barcode/find-by-id/v1?barcode=\(gtin13)&format=json") else {
            throw FatSecretError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FatSecretError.invalidResponse
        }

        if httpResponse.statusCode == 404 {
            throw FatSecretError.productNotFound
        }

        guard httpResponse.statusCode == 200 else {
            throw FatSecretError.invalidResponse
        }

        let barcodeResponse = try decoder.decode(FatSecretBarcodeResponse.self, from: data)

        guard let foodId = barcodeResponse.foodId?.value else {
            throw FatSecretError.productNotFound
        }

        return foodId
    }

    private func getFoodDetails(foodId: String, token: String, barcode: String) async throws -> FoodProduct {
        guard let url = URL(string: "\(baseURL)/food/v4?food_id=\(foodId)&format=json") else {
            throw FatSecretError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw FatSecretError.invalidResponse
        }

        let foodResponse = try decoder.decode(FatSecretFoodResponse.self, from: data)

        guard let food = foodResponse.food else {
            throw FatSecretError.productNotFound
        }

        // Find the best serving (prefer "1 bar", "1 serving", etc. over "100g")
        guard let servings = food.servings?.serving, !servings.isEmpty else {
            throw FatSecretError.incompleteNutritionData
        }

        // Debug: Print all servings to understand what FatSecret returns
        print("FatSecret servings for \(food.foodName ?? "unknown"):")
        for (index, s) in servings.enumerated() {
            print("  [\(index)] \(s.servingDescription ?? "no desc") - carbs: \(s.carbohydrate ?? "?"), fat: \(s.fat ?? "?"), protein: \(s.protein ?? "?")")
        }

        // Find the best serving - prioritize by description
        let serving = selectBestServing(from: servings)

        guard let carbsStr = serving.carbohydrate,
              let fatStr = serving.fat,
              let proteinStr = serving.protein,
              let carbs = Decimal(string: carbsStr),
              let fat = Decimal(string: fatStr),
              let protein = Decimal(string: proteinStr)
        else {
            throw FatSecretError.incompleteNutritionData
        }

        // Get serving size in grams
        let servingSizeG: Decimal
        if let metricAmount = serving.metricServingAmount,
           let amount = Decimal(string: metricAmount),
           serving.metricServingUnit?.lowercased() == "g"
        {
            servingSizeG = amount
        } else {
            // Estimate from serving description or default to 100g
            servingSizeG = 100
        }

        // Convert per-serving to per-100g for consistent calculations
        let carbsPer100g = servingSizeG > 0 ? carbs / servingSizeG * 100 : carbs
        let fatPer100g = servingSizeG > 0 ? fat / servingSizeG * 100 : fat
        let proteinPer100g = servingSizeG > 0 ? protein / servingSizeG * 100 : protein

        return FoodProduct(
            id: barcode,
            name: food.foodName ?? "Unknown",
            brand: food.brandName,
            imageURL: nil,
            carbsPer100g: carbsPer100g,
            fatPer100g: fatPer100g,
            proteinPer100g: proteinPer100g,
            servingSizeG: servingSizeG,
            servingLabel: serving.servingDescription,
            dataSource: .fatSecret
        )
    }

    /// Clear the cache
    func clearCache() {
        cache.removeAll()
        accessToken = nil
        tokenExpiration = nil
    }

    /// Select the best serving from available options
    /// Prioritizes: "bar", "serving", "piece", "package" over generic "g" or "oz" servings
    private func selectBestServing(from servings: [FatSecretServing]) -> FatSecretServing {
        let priorityKeywords = ["bar", "serving", "piece", "packet", "package", "container", "unit", "portion"]

        // First, try to find a serving that matches priority keywords
        for keyword in priorityKeywords {
            if let match = servings.first(where: {
                $0.servingDescription?.lowercased().contains(keyword) == true
            }) {
                print("Selected serving by keyword '\(keyword)': \(match.servingDescription ?? "unknown")")
                return match
            }
        }

        // If no keyword match, prefer servings that have "1 " at the start (like "1 bar", "1 piece")
        if let match = servings.first(where: {
            $0.servingDescription?.hasPrefix("1 ") == true
        }) {
            print("Selected serving starting with '1 ': \(match.servingDescription ?? "unknown")")
            return match
        }

        // Fall back to first serving
        print("Falling back to first serving: \(servings[0].servingDescription ?? "unknown")")
        return servings[0]
    }
}

// MARK: - Configuration

/// Configuration for FatSecret API credentials
/// Credentials are persisted in UserDefaults
enum FatSecretConfig {
    private static let clientIdKey = "FatSecretClientId"
    private static let clientSecretKey = "FatSecretClientSecret"

    static var clientId: String {
        get { UserDefaults.standard.string(forKey: clientIdKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: clientIdKey)
            // Clear cached token when credentials change
            Task { await FatSecretAPIService.shared.clearCache() }
        }
    }

    static var clientSecret: String {
        get { UserDefaults.standard.string(forKey: clientSecretKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: clientSecretKey)
            // Clear cached token when credentials change
            Task { await FatSecretAPIService.shared.clearCache() }
        }
    }

    static var isConfigured: Bool {
        !clientId.isEmpty && !clientSecret.isEmpty
    }

    /// Configure FatSecret API credentials
    static func configure(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
    }
}

// MARK: - Errors

enum FatSecretError: LocalizedError {
    case notConfigured
    case authenticationFailed
    case productNotFound
    case invalidURL
    case invalidResponse
    case incompleteNutritionData

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "FatSecret API not configured"
        case .authenticationFailed:
            return "FatSecret authentication failed"
        case .productNotFound:
            return "Product not found in FatSecret database"
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from FatSecret"
        case .incompleteNutritionData:
            return "Nutrition information incomplete"
        }
    }
}

// MARK: - Response Models

struct FatSecretTokenResponse: Codable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

struct FatSecretBarcodeResponse: Codable {
    let foodId: FatSecretFoodIdValue?

    enum CodingKeys: String, CodingKey {
        case foodId = "food_id"
    }
}

struct FatSecretFoodIdValue: Codable {
    let value: String?
}

struct FatSecretFoodResponse: Codable {
    let food: FatSecretFood?
}

struct FatSecretFood: Codable {
    let foodId: String?
    let foodName: String?
    let brandName: String?
    let foodType: String?
    let servings: FatSecretServings?

    enum CodingKeys: String, CodingKey {
        case foodId = "food_id"
        case foodName = "food_name"
        case brandName = "brand_name"
        case foodType = "food_type"
        case servings
    }
}

struct FatSecretServings: Codable {
    let serving: [FatSecretServing]?
}

struct FatSecretServing: Codable {
    let servingId: String?
    let servingDescription: String?
    let metricServingAmount: String?
    let metricServingUnit: String?
    let numberOfUnits: String?
    let measurementDescription: String?
    let calories: String?
    let carbohydrate: String?
    let protein: String?
    let fat: String?
    let saturatedFat: String?
    let polyunsaturatedFat: String?
    let monounsaturatedFat: String?
    let cholesterol: String?
    let sodium: String?
    let potassium: String?
    let fiber: String?
    let sugar: String?

    enum CodingKeys: String, CodingKey {
        case servingId = "serving_id"
        case servingDescription = "serving_description"
        case metricServingAmount = "metric_serving_amount"
        case metricServingUnit = "metric_serving_unit"
        case numberOfUnits = "number_of_units"
        case measurementDescription = "measurement_description"
        case calories
        case carbohydrate
        case protein
        case fat
        case saturatedFat = "saturated_fat"
        case polyunsaturatedFat = "polyunsaturated_fat"
        case monounsaturatedFat = "monounsaturated_fat"
        case cholesterol
        case sodium
        case potassium
        case fiber
        case sugar
    }
}
