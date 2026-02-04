import Foundation

/// API client for Open Food Facts database
final class OpenFoodFactsAPI: FoodDatabaseService {
    private let baseURL = "https://world.openfoodfacts.org/api/v2/product"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchProduct(barcode: String) async throws -> FoodProduct {
        // Build URL with fields parameter to limit response size
        var components = URLComponents(string: "\(baseURL)/\(barcode).json")

        components?.queryItems = [
            URLQueryItem(
                name: "fields",
                value: "code,product_name,brands,serving_size,serving_quantity,nutriments,image_url"
            )
        ]

        guard let url = components?.url else {
            throw FoodDatabaseError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("Trio-iOS-App", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FoodDatabaseError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw FoodDatabaseError.networkError(URLError(.badServerResponse))
        }

        let decoded: OpenFoodFactsResponse
        do {
            decoded = try JSONDecoder().decode(OpenFoodFactsResponse.self, from: data)
        } catch {
            throw FoodDatabaseError.invalidResponse
        }

        guard decoded.status == 1, let product = decoded.product else {
            throw FoodDatabaseError.productNotFound
        }

        return try mapToFoodProduct(product, barcode: barcode)
    }

    private func mapToFoodProduct(_ off: OFFProduct, barcode: String) throws -> FoodProduct {
        let nutriments = off.nutriments

        // Ensure we have at least carbohydrate data
        guard let carbsPer100g = nutriments.carbohydrates100g else {
            throw FoodDatabaseError.missingNutritionData
        }

        // Calculate per-serving values if serving size is available
        let servingGrams = off.servingQuantity ?? 100
        let multiplier = servingGrams / 100

        return FoodProduct(
            id: barcode,
            name: off.productName ?? String(localized: "Unknown Product"),
            brand: off.brands,
            servingSize: off.servingSize,
            servingSizeGrams: servingGrams,
            carbohydrates: carbsPer100g * multiplier,
            fat: (nutriments.fat100g ?? 0) * multiplier,
            protein: (nutriments.proteins100g ?? 0) * multiplier,
            carbsPer100g: carbsPer100g,
            fatPer100g: nutriments.fat100g,
            proteinPer100g: nutriments.proteins100g,
            imageUrl: off.imageUrl.flatMap { URL(string: $0) }
        )
    }
}

// MARK: - Open Food Facts Response Models

private struct OpenFoodFactsResponse: Codable {
    let status: Int
    let product: OFFProduct?
}

private struct OFFProduct: Codable {
    let productName: String?
    let brands: String?
    let servingSize: String?
    let servingQuantity: Decimal?
    let nutriments: OFFNutriments
    let imageUrl: String?

    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case brands
        case servingSize = "serving_size"
        case servingQuantity = "serving_quantity"
        case nutriments
        case imageUrl = "image_url"
    }
}

private struct OFFNutriments: Codable {
    let carbohydrates100g: Decimal?
    let fat100g: Decimal?
    let proteins100g: Decimal?

    enum CodingKeys: String, CodingKey {
        case carbohydrates100g = "carbohydrates_100g"
        case fat100g = "fat_100g"
        case proteins100g = "proteins_100g"
    }
}
