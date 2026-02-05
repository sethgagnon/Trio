import Foundation

/// Service for fetching nutrition data using Claude AI
/// Falls back to web search when barcode databases have incorrect data
actor ClaudeNutritionService {
    static let shared = ClaudeNutritionService()

    private let apiURL = "https://api.anthropic.com/v1/messages"
    private let session: URLSession
    private let decoder: JSONDecoder

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
        decoder = JSONDecoder()
    }

    /// Fetch nutrition data using Claude AI
    /// - Parameters:
    ///   - productName: The name of the product to look up
    ///   - brand: Optional brand name for more accurate results
    ///   - barcode: Optional barcode for reference
    /// - Returns: FoodProduct with nutrition information
    func fetchNutrition(productName: String, brand: String?, barcode: String?) async throws -> FoodProduct {
        guard ClaudeConfig.isConfigured else {
            throw ClaudeNutritionError.notConfigured
        }

        let prompt = buildPrompt(productName: productName, brand: brand)
        let response = try await callClaudeAPI(prompt: prompt)
        let product = try parseNutritionResponse(response, productName: productName, brand: brand, barcode: barcode)

        return product
    }

    private func buildPrompt(productName: String, brand: String?) -> String {
        let brandText = brand.map { " by \($0)" } ?? ""
        return """
        What are the nutrition facts for "\(productName)"\(brandText)?

        Please provide the information in this exact JSON format:
        {
            "name": "product name",
            "brand": "brand name or null",
            "serving_size_g": serving size in grams as a number,
            "serving_label": "serving description (e.g., '1 bar (40g)')",
            "carbs_per_serving": total carbohydrates in grams as a number,
            "fat_per_serving": total fat in grams as a number,
            "protein_per_serving": protein in grams as a number
        }

        Important:
        - Use TOTAL carbohydrates, not net carbs
        - Use the standard serving size from the nutrition label
        - Only return the JSON, no other text
        - If you're not confident about the data, set all nutrition values to 0
        """
    }

    private func callClaudeAPI(prompt: String) async throws -> String {
        guard let url = URL(string: apiURL) else {
            throw ClaudeNutritionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ClaudeConfig.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let requestBody: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 500,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeNutritionError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw ClaudeNutritionError.invalidAPIKey
        }

        guard httpResponse.statusCode == 200 else {
            print("Claude API error: \(httpResponse.statusCode)")
            if let errorText = String(data: data, encoding: .utf8) {
                print("Error body: \(errorText)")
            }
            throw ClaudeNutritionError.apiError(statusCode: httpResponse.statusCode)
        }

        // Parse Claude's response
        let claudeResponse = try decoder.decode(ClaudeAPIResponse.self, from: data)

        guard let content = claudeResponse.content.first,
              case .text(let text) = content
        else {
            throw ClaudeNutritionError.invalidResponse
        }

        return text
    }

    private func parseNutritionResponse(_ response: String, productName: String, brand: String?, barcode: String?) throws -> FoodProduct {
        // Extract JSON from response (Claude might include extra text)
        let jsonString = extractJSON(from: response)

        guard let jsonData = jsonString.data(using: .utf8) else {
            throw ClaudeNutritionError.parsingError
        }

        let nutritionData = try decoder.decode(ClaudeNutritionResponse.self, from: jsonData)

        // Validate the data
        guard nutritionData.carbsPerServing > 0 ||
              nutritionData.fatPerServing > 0 ||
              nutritionData.proteinPerServing > 0
        else {
            throw ClaudeNutritionError.noDataFound
        }

        let servingSizeG = Decimal(nutritionData.servingSizeG)
        let carbs = Decimal(nutritionData.carbsPerServing)
        let fat = Decimal(nutritionData.fatPerServing)
        let protein = Decimal(nutritionData.proteinPerServing)

        // Convert to per-100g for consistent calculations
        let carbsPer100g = servingSizeG > 0 ? carbs / servingSizeG * 100 : carbs
        let fatPer100g = servingSizeG > 0 ? fat / servingSizeG * 100 : fat
        let proteinPer100g = servingSizeG > 0 ? protein / servingSizeG * 100 : protein

        return FoodProduct(
            id: barcode ?? UUID().uuidString,
            name: nutritionData.name ?? productName,
            brand: nutritionData.brand ?? brand,
            imageURL: nil,
            carbsPer100g: carbsPer100g,
            fatPer100g: fatPer100g,
            proteinPer100g: proteinPer100g,
            servingSizeG: servingSizeG,
            servingLabel: nutritionData.servingLabel,
            dataSource: .ai
        )
    }

    private func extractJSON(from text: String) -> String {
        // Try to find JSON object in the response
        if let startIndex = text.firstIndex(of: "{"),
           let endIndex = text.lastIndex(of: "}") {
            return String(text[startIndex...endIndex])
        }
        return text
    }
}

// MARK: - Configuration

/// Configuration for Claude API
enum ClaudeConfig {
    private static let apiKeyKey = "ClaudeAPIKey"

    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyKey) }
    }

    static var isConfigured: Bool {
        !apiKey.isEmpty
    }
}

// MARK: - Errors

enum ClaudeNutritionError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidAPIKey
    case apiError(statusCode: Int)
    case invalidResponse
    case parsingError
    case noDataFound

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Claude API key not configured"
        case .invalidURL:
            return "Invalid API URL"
        case .invalidAPIKey:
            return "Invalid Claude API key"
        case .apiError(let statusCode):
            return "API error (status: \(statusCode))"
        case .invalidResponse:
            return "Invalid response from Claude"
        case .parsingError:
            return "Failed to parse nutrition data"
        case .noDataFound:
            return "No nutrition data found"
        }
    }
}

// MARK: - Response Models

private struct ClaudeAPIResponse: Codable {
    let content: [ContentBlock]

    enum ContentBlock: Codable {
        case text(String)
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)

            if type == "text" {
                let text = try container.decode(String.self, forKey: .text)
                self = .text(text)
            } else {
                self = .other
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .other:
                try container.encode("other", forKey: .type)
            }
        }

        enum CodingKeys: String, CodingKey {
            case type, text
        }
    }
}

private struct ClaudeNutritionResponse: Codable {
    let name: String?
    let brand: String?
    let servingSizeG: Double
    let servingLabel: String?
    let carbsPerServing: Double
    let fatPerServing: Double
    let proteinPerServing: Double

    enum CodingKeys: String, CodingKey {
        case name
        case brand
        case servingSizeG = "serving_size_g"
        case servingLabel = "serving_label"
        case carbsPerServing = "carbs_per_serving"
        case fatPerServing = "fat_per_serving"
        case proteinPerServing = "protein_per_serving"
    }
}
