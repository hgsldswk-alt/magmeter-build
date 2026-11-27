import Foundation

struct SpotReading: Codable, Equatable, Identifiable {
    let id: UUID
    let version: Int
    var label: String
    var customLabel: Bool
    let time: TimeInterval
    let vector: FieldVector
    let magnitude: Double
    let delta: Double
    let comparable: Bool
    let source: ReadingSource

    init(id: UUID = UUID(), label: String, customLabel: Bool = false, sample: FieldSample, baseline: Baseline) {
        self.id = id
        version = 1
        self.label = label
        self.customLabel = customLabel
        time = sample.time
        vector = sample.vector
        magnitude = sample.vector.magnitude
        delta = baseline.delta(sample.vector.magnitude)
        comparable = true
        source = sample.source
    }
}

struct FieldSession: Codable, Equatable, Identifiable {
    let id: UUID
    let baseline: Baseline
    let preset: Preset
    var spots: [SpotReading] = []
    var retakes: [SpotReading] = []
    var archived = false

    init(id: UUID = UUID(), baseline: Baseline, preset: Preset) {
        self.id = id
        self.baseline = baseline
        self.preset = preset
    }

    static func label(for index: Int) -> String {
        var remaining = index
        var label = ""
        repeat {
            label = String(UnicodeScalar(65 + remaining % 26)!) + label
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return label
    }

    mutating func replace(_ id: UUID, with sample: FieldSample, keepHistory: Bool) {
        guard let index = spots.firstIndex(where: { $0.id == id }) else { return }
        let old = spots[index]
        if keepHistory { retakes.append(old) }
        spots[index] = SpotReading(id: id, label: old.label, customLabel: old.customLabel, sample: sample, baseline: baseline)
    }

    func csv() -> Data {
        var lines = ["\u{FEFF}session_id,\(L.t("csv.header"))"]
        for (readings, state) in [(spots, L.t("csv.current")), (retakes, L.t("csv.previous"))] {
            for spot in readings {
                let origin = spot.source == .example ? L.t("csv.example") : L.t("csv.sensor")
                let status = spot.comparable ? L.t("pose.same") : L.t("pose.adjust")
                lines.append([
                    id.uuidString, csvLabel(spot.label), cell(state), String(spot.version), String(spot.time - baseline.time),
                    String(spot.vector.x), String(spot.vector.y), String(spot.vector.z),
                    String(spot.magnitude), String(spot.delta), String(baseline.magnitude),
                    String(preset.windowSec), cell(preset.pose.title), L.t("unit"), cell(origin), cell(status)
                ].joined(separator: ","))
            }
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private func cell(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func csvLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let formula = trimmed.first.map { "=+-@".contains($0) } ?? false
        return cell(formula ? "'" + label : label)
    }
}
