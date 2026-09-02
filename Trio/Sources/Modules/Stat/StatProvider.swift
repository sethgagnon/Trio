import Foundation
import LoopKit

protocol StatProvider: Provider {
    var basalProfile: [BasalProfileEntry] { get }
    var isfProfile: InsulinSensitivities { get }
    var carbRatioProfile: CarbRatios { get }
    var basalIncrement: Decimal { get }
}

extension Stat {
    final class Provider: BaseProvider, StatProvider {
        var basalProfile: [BasalProfileEntry] {
            storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self)
                ?? [BasalProfileEntry](from: OpenAPS.defaults(for: OpenAPS.Settings.basalProfile))
                ?? []
        }

        var isfProfile: InsulinSensitivities {
            storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
                ?? InsulinSensitivities(from: OpenAPS.defaults(for: OpenAPS.Settings.insulinSensitivities))
                ?? InsulinSensitivities(units: .mgdL, userPreferredUnits: .mgdL, sensitivities: [])
        }

        var carbRatioProfile: CarbRatios {
            storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self)
                ?? CarbRatios(from: OpenAPS.defaults(for: OpenAPS.Settings.carbRatios))
                ?? CarbRatios(units: .grams, schedule: [])
        }

        var basalIncrement: Decimal {
            let rates = deviceManager.pumpManager?.supportedBasalRates.filter { $0 > 0 } ?? []
            guard rates.count >= 2 else {
                return Decimal(string: "0.05") ?? 0.05
            }
            let step = Decimal(rates[1] - rates[0])
            return step > 0 ? step : (Decimal(string: "0.05") ?? 0.05)
        }
    }
}
