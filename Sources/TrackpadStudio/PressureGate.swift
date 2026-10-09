import Foundation

/// "Light touch aims, firmer press writes", from the trackpad's per-contact
/// pressure (MultitouchSupport; Force Touch pads). The scale differs between
/// machines and pens, so the thresholds come from a short calibration: a
/// stretch of light touching, then a stretch of writing pressure.
struct PressureGate: Codable, Equatable {
    /// Ink starts at or above this pressure…
    var press: Double
    /// …and stops below this one (hysteresis: a stroke must not break when
    /// the hand eases off a little mid-word).
    var release: Double

    enum Failure: Error, Equatable {
        /// Every sample read zero: this pad reports no pressure.
        case noPressureData
        /// The two pressures overlap too much to tell apart.
        case notSeparable
    }

    static func calibrate(light: [Double], firm: [Double]) -> Result<PressureGate, Failure> {
        guard (light + firm).contains(where: { $0 > 0 }) else { return .failure(.noPressureData) }
        let lightHigh = percentile(light, 0.9)
        let firmLow = percentile(firm, 0.25)
        guard firmLow > lightHigh * 1.3, firmLow - lightHigh > 1e-6 else { return .failure(.notSeparable) }
        let press = (lightHigh + firmLow) / 2
        return .success(PressureGate(press: press, release: lightHigh + (press - lightHigh) * 0.4))
    }

    func isInking(pressure: Double, wasInking: Bool) -> Bool {
        pressure >= (wasInking ? release : press)
    }

    /// Lighter or firmer: `[` / `]` nudge both thresholds by 10 %.
    func scaled(by factor: Double) -> PressureGate {
        PressureGate(press: press * factor, release: release * factor)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))]
    }

    // MARK: Persistence

    private static let key = "pressureGate"

    static func load() -> PressureGate? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(PressureGate.self, from: $0) }
    }

    static func save(_ gate: PressureGate?) {
        if let gate, let data = try? JSONEncoder().encode(gate) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
