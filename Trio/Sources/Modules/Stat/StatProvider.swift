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
            let fallback = Decimal(string: "0.05") ?? 0.05
            let rates = (deviceManager.pumpManager?.supportedBasalRates ?? [])
                .filter { $0 > 0 }
                .sorted()
            guard rates.count >= 2 else { return fallback }
            // Smallest gap, not the first one: some pumps step finer at low rates than high ones,
            // and rounding to the coarse step there would move a suggestion off a rate the pump
            // actually accepts. `algorithmValue` avoids the binary-Double residue that plain
            // Decimal(Double) leaves behind (0.1 - 0.05 is not exactly 0.05).
            let gaps = zip(rates.dropFirst(), rates).map { Decimal(algorithmValue: $0 - $1) }
            guard let step = gaps.filter({ $0 > 0 }).min() else { return fallback }
            return step.rounded(scale: 4)
        }
    }
}
