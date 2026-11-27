import Foundation

struct Milestones: Codable {
    var firstFreeze = false
    var firstComparison = false
}

struct ReviewGate: Codable {
    private(set) var completedDays: Set<String> = []
    private(set) var completedShare = false
    private(set) var lastRequest: Date?

    var isQualified: Bool { completedShare && completedDays.count >= 2 }

    mutating func completeMeasurement(on date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        completedDays.insert(String(day.timeIntervalSinceReferenceDate))
    }

    mutating func completeShare() { completedShare = true }

    mutating func request(at date: Date, safe: Bool) -> Bool {
        guard safe, isQualified,
              lastRequest.map({ date.timeIntervalSince($0) >= 180 * 86_400 }) ?? true else { return false }
        lastRequest = date
        return true
    }
}
