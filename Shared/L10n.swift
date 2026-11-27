import Foundation

final class LocalizationAnchor: NSObject {}

enum L {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: Bundle(for: LocalizationAnchor.self), comment: "")
    }

    static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: .current, arguments: arguments)
    }

    static func reading(_ value: Double?, signed: Bool = false) -> String {
        guard let value, value.isFinite else { return t("reading.missing") }
        let rounded = (value * 10).rounded() / 10
        let normalized = rounded == 0 ? 0 : rounded
        return String(format: signed ? "%+.1f" : "%.1f", locale: .current, normalized)
    }
}
