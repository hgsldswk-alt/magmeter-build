import Foundation

enum MeasureMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case metal, wall, compare
    var id: Self { self }
    var title: String {
        switch self {
        case .metal: L.t("mode.metal")
        case .wall: L.t("mode.wall")
        case .compare: L.t("mode.compare")
        }
    }
    var subtitle: String {
        switch self {
        case .metal: L.t("mode.metal.subtitle")
        case .wall: L.t("mode.wall.subtitle")
        case .compare: L.t("mode.compare.subtitle")
        }
    }
}

enum PositionHint: String, Codable {
    case flat, upright
    var title: String { self == .flat ? L.t("pose.flat") : L.t("pose.upright") }
}

struct Preset: Codable, Equatable, Identifiable {
    let mode: MeasureMode
    let pose: PositionHint
    let windowSec: Int

    var id: String { code }
    static let maxLength = 512
    static let prefix = "MAG1:"
    private static let keys: Set<String> = ["mode", "pose", "windowSec"]

    static func standard(for mode: MeasureMode) -> Self {
        Self(mode: mode, pose: mode == .wall ? .upright : .flat, windowSec: 8)
    }

    var code: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let base = (try? encoder.encode(self))?.base64EncodedString() ?? ""
        return Self.prefix + base.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ input: String) -> Self? {
        guard input.utf8.count <= maxLength else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let token = String(trimmed.dropFirst(prefix.count))
        guard !token.isEmpty, token.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        var base = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        guard let data = Data(base64Encoded: base),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys,
              let preset = try? JSONDecoder().decode(Self.self, from: data),
              [4, 8, 12].contains(preset.windowSec)
        else { return nil }
        return preset
    }
}
