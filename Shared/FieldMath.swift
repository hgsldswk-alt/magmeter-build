import Foundation

struct FieldVector: Codable, Equatable {
    let x: Double
    let y: Double
    let z: Double

    var magnitude: Double { hypot(hypot(x, y), z) }
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite && magnitude.isFinite }
    var isSaturated: Bool { max(abs(x), abs(y), abs(z)) >= 1_900 }
}

struct Orientation: Codable, Equatable {
    let x: Double
    let y: Double
    let z: Double
    let w: Double

    static let level = Self(x: 0, y: 0, z: 0, w: 1)
    var isValid: Bool {
        let norm = x*x + y*y + z*z + w*w
        return norm.isFinite && abs(norm - 1) < 0.01
    }

    func angle(to other: Self) -> Double {
        let dot = abs(x * other.x + y * other.y + z * other.z + w * other.w)
        return 2 * acos(min(dot, 1)) * 180 / .pi
    }
}

enum ReadingSource: String, Codable { case magnetometer, example }
enum SensorStatus: Equatable { case waiting, live, paused, unavailable, invalid, saturated }

struct FieldSample: Equatable {
    let time: TimeInterval
    let vector: FieldVector
    let orientation: Orientation?
    let source: ReadingSource
}

struct Baseline: Codable, Equatable {
    let time: TimeInterval
    let magnitude: Double
    let mad: Double
    let orientation: Orientation
    let source: ReadingSource

    var threshold: Double { max(5, 6 * mad) }
    func delta(_ current: Double) -> Double { current - magnitude }

    static func make(from samples: [FieldSample]) -> Self? {
        guard let last = samples.last, let orientation = last.orientation, orientation.isValid else { return nil }
        let window = samples.filter { $0.time >= last.time - 1.06 }
        guard let first = window.first, last.time - first.time >= 1,
              window.count >= 18,
              zip(window, window.dropFirst()).allSatisfy({ $0.1.time - $0.0.time <= 0.15 }),
              window.allSatisfy({ sample in
                  guard let pose = sample.orientation, pose.isValid else { return false }
                  return sample.vector.isFinite && !sample.vector.isSaturated && sample.source == last.source
                      && orientation.angle(to: pose) <= 5
              })
        else { return nil }

        let values = window.map { $0.vector.magnitude }
        let middle = median(values)
        let mad = median(values.map { abs($0 - middle) })
        guard mad <= 2, values.allSatisfy({ abs($0 - middle) <= 4 }) else { return nil }
        return Self(time: last.time, magnitude: middle, mad: mad, orientation: orientation, source: last.source)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

struct PeakDetector {
    private var above = 0
    private var below = 0
    private var extreme = 0.0

    mutating func feed(_ delta: Double, threshold: Double) -> Double? {
        if abs(delta) >= threshold {
            if above > 0 && (delta < 0) != (extreme < 0) {
                self = Self()
            }
            above += 1
            below = 0
            if abs(delta) >= abs(extreme) { extreme = delta }
        } else if above >= 3 {
            if abs(delta) <= threshold * 0.65 {
                below += 1
                if below >= 3 {
                    let peak = extreme
                    self = Self()
                    return peak
                }
            } else {
                below = 0
            }
        } else {
            self = Self()
        }
        return nil
    }
}

struct ScanProgress {
    private(set) var firstPeak: Double?
    private(set) var repeatPeak: Double?

    mutating func record(_ peak: Double) {
        guard let firstPeak else {
            self.firstPeak = peak
            return
        }
        let ratio = abs(peak / firstPeak)
        if (peak < 0) == (firstPeak < 0), (0.55...1.8).contains(ratio) {
            repeatPeak = peak
        }
    }
}

struct TrendPoint: Equatable {
    let time: TimeInterval
    let value: Double
    let segment: Int
}

struct MeterEngine {
    static let staleAfter: TimeInterval = 0.65
    private(set) var status: SensorStatus = .waiting
    private(set) var last: FieldSample?
    private(set) var absolute: [TrendPoint] = []
    private(set) var relative: [TrendPoint] = []
    private(set) var baseline: Baseline?
    private(set) var delta: Double?
    private(set) var scan = ScanProgress()
    private(set) var poseMissing = false
    private var recent: [FieldSample] = []
    private var peak = PeakDetector()
    private var stableSince: TimeInterval?
    private var absoluteSegment = 0
    private var relativeSegment = 0

    mutating func receive(_ sample: FieldSample, now: TimeInterval, window: Int) -> Double? {
        guard sample.time <= now + 0.1, now - sample.time <= Self.staleAfter,
              last.map({ sample.time > $0.time }) ?? true else { return nil }
        guard sample.vector.isFinite else { interrupt(.invalid); return nil }
        guard !sample.vector.isSaturated else { interrupt(.saturated); return nil }
        if let last, sample.time - last.time > 0.18 { interrupt(.paused) }

        let previous = recent.last
        status = .live
        last = sample
        poseMissing = !(sample.orientation?.isValid ?? false)
        recent.append(sample)
        recent.removeAll { $0.time < sample.time - 1.1 }
        absolute.append(.init(time: sample.time, value: sample.vector.magnitude, segment: absoluteSegment))
        absolute.removeAll { $0.time < sample.time - Double(window) }
        relative.removeAll { $0.time < sample.time - Double(window) }
        guard let baseline,
              let pose = sample.orientation, pose.isValid,
              pose.angle(to: baseline.orientation) <= 12,
              sample.source == baseline.source else {
            suspendRelative()
            return nil
        }
        if let oldPose = previous?.orientation, pose.angle(to: oldPose) > 5 { suspendRelative() }
        if stableSince == nil { stableSince = sample.time }
        guard let stableSince, sample.time - stableSince >= 0.24 else { return nil }

        let next = baseline.delta(sample.vector.magnitude)
        delta = next
        relative.append(.init(time: sample.time, value: next, segment: relativeSegment))
        guard let detected = peak.feed(next, threshold: baseline.threshold) else { return nil }
        scan.record(detected)
        return detected
    }

    mutating func checkFreshness(now: TimeInterval) {
        if status == .live, let last, now - last.time > Self.staleAfter { interrupt(.paused) }
    }

    mutating func interrupt(_ next: SensorStatus) {
        if status == .live { absoluteSegment += 1 }
        status = next
        clearRecentSamples()
        suspendRelative()
    }

    mutating func clearRecentSamples() {
        recent.removeAll(keepingCapacity: true)
    }

    private mutating func suspendRelative() {
        if delta != nil { relativeSegment += 1 }
        delta = nil
        stableSince = nil
        peak = PeakDetector()
    }

    @discardableResult mutating func setBaseline(now: TimeInterval) -> Baseline? {
        guard status == .live, let last, now - last.time <= Self.staleAfter,
              let candidate = Baseline.make(from: recent) else { return nil }
        clearBaseline()
        baseline = candidate
        stableSince = candidate.time
        return candidate
    }

    mutating func clearBaseline() {
        baseline = nil
        relative.removeAll(keepingCapacity: true)
        scan = ScanProgress()
        suspendRelative()
    }

    func capture(now: TimeInterval) -> FieldSample? {
        guard status == .live, delta != nil, let last, now - last.time <= Self.staleAfter, let baseline,
              let anchor = last.orientation else { return nil }
        let slice = recent.filter { $0.time >= last.time - 0.28 }
        guard let first = slice.first, last.time - first.time >= 0.22,
              slice.count >= 5, slice.allSatisfy({ sample in
                  guard let pose = sample.orientation, pose.isValid else { return false }
                  return pose.angle(to: anchor) <= 3 && pose.angle(to: baseline.orientation) <= 12
                      && abs(sample.vector.magnitude - last.vector.magnitude) <= 3
              }) else { return nil }
        return last
    }
}
