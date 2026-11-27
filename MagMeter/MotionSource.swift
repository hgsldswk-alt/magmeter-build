import CoreMotion
import Foundation

enum MotionEvent {
    case samples([FieldSample])
    case failure(SensorStatus)
    case orientationReset
}

protocol MotionSource: AnyObject {
    func start(deliver: @escaping (MotionEvent) -> Void)
    func stop()
    func beginScan(_ mode: MeasureMode)
}

final class DeviceMotionSource: MotionSource {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MagMeter.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var pose: (time: TimeInterval, orientation: Orientation)?
    private var pending: [FieldSample] = []
    private var lastDelivery: TimeInterval = 0
    private var generation = 0

    func start(deliver: @escaping (MotionEvent) -> Void) {
        queue.addOperation { [weak self] in
            guard let self else { return }
            generation += 1
            let token = generation
            pose = nil
            pending.removeAll()
            lastDelivery = 0
            guard manager.isMagnetometerAvailable else {
                deliver(.failure(.unavailable))
                return
            }
            if manager.isDeviceMotionAvailable,
               CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryZVertical) {
                manager.deviceMotionUpdateInterval = 0.04
                manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, error in
                    guard let self, token == self.generation else { return }
                    if let motion, error == nil {
                        if let pose = self.pose, motion.timestamp - pose.time > 0.20 {
                            self.pending.removeAll()
                            deliver(.orientationReset)
                        }
                        let q = motion.attitude.quaternion
                        self.pose = (motion.timestamp, Orientation(x: q.x, y: q.y, z: q.z, w: q.w))
                    } else if self.pose != nil {
                        self.pose = nil
                        self.pending.removeAll()
                        deliver(.orientationReset)
                    }
                }
            }
            manager.magnetometerUpdateInterval = 0.04
            manager.startMagnetometerUpdates(to: queue) { [weak self] data, error in
                guard let self, token == self.generation else { return }
                guard let data, error == nil else {
                    self.pending.removeAll()
                    deliver(.failure(.paused))
                    return
                }
                let field = data.magneticField
                let orientation = self.pose.flatMap {
                    abs(data.timestamp - $0.time) <= 0.15 ? $0.orientation : nil
                }
                self.pending.append(FieldSample(time: data.timestamp,
                                                vector: FieldVector(x: field.x, y: field.y, z: field.z),
                                                orientation: orientation, source: .magnetometer))
                if data.timestamp - self.lastDelivery >= 0.09 {
                    self.lastDelivery = data.timestamp
                    let batch = self.pending
                    self.pending.removeAll(keepingCapacity: true)
                    deliver(.samples(batch))
                }
            }
        }
    }

    func stop() {
        queue.addOperation { [weak self] in
            guard let self else { return }
            generation += 1
            manager.stopMagnetometerUpdates()
            manager.stopDeviceMotionUpdates()
            pose = nil
            pending.removeAll()
        }
    }

    func beginScan(_ mode: MeasureMode) {}
}

final class ExampleMotionSource: MotionSource {
    private static let sampleInterval: TimeInterval = 0.04
    private static let batchInterval = 3 * sampleInterval
    private let scenario: String?
    private var retried = false
    private var timer: Timer?
    private(set) var firstSampleTime: TimeInterval = 0
    private var nextSampleTime: TimeInterval = 0
    private var scan: (mode: MeasureMode, startedAt: TimeInterval)?
    private var measurement = 0
    private var frame = 0

    init(scenario: String?) { self.scenario = scenario }

    func start(deliver: @escaping (MotionEvent) -> Void) {
        stop()
        if scenario == "unavailable" {
            deliver(.failure(.unavailable))
            return
        }
        if scenario == "silent" && !retried {
            retried = true
            return
        }
        if scenario == "retry" && !retried {
            retried = true
            deliver(.failure(.paused))
            return
        }
        let timer = Timer(timeInterval: Self.batchInterval, repeats: true) { [weak self] _ in
            self?.deliverSamples(to: deliver)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func deliverSamples(to deliver: (MotionEvent) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        let oldest = now - MeterEngine.staleAfter + Self.batchInterval
        if nextSampleTime < oldest {
            let skipped = ceil((oldest - nextSampleTime) / Self.sampleInterval)
            nextSampleTime += skipped * Self.sampleInterval
        }
        var samples: [FieldSample] = []
        while nextSampleTime <= now {
            samples.append(sample(at: nextSampleTime))
            nextSampleTime += Self.sampleInterval
        }
        if !samples.isEmpty { deliver(.samples(samples)) }
    }

    private func sample(at time: TimeInterval) -> FieldSample {
        var magnitude = 47.8 + 0.32 * sin(Double(frame) / 7) + Double(measurement) * 6.7
        var pose = Orientation.level
        if let scan {
            let elapsed = time - scan.startedAt
            if scenario == "tilt" {
                if (1.1...3.2).contains(elapsed) {
                    pose = Orientation(x: 0.3, y: 0, z: 0, w: sqrt(0.91))
                }
            } else if scan.mode == .wall || scenario == "single-peak" {
                let firstPass = (0.65...1.25).contains(elapsed)
                let secondPass = scenario != "single-peak" && (2.2...2.8).contains(elapsed)
                if firstPass || secondPass { magnitude += 10.6 }
            }
        }
        let z = sqrt(magnitude * magnitude - 24.1 * 24.1 - 7.3 * 7.3)
        frame += 1
        return FieldSample(time: time, vector: FieldVector(x: 24.1, y: -7.3, z: z),
                           orientation: pose, source: .example)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        resetScenario()
    }

    func resetScenario() {
        scan = nil
        measurement = 0
        startSampleWindow()
    }

    func beginScan(_ mode: MeasureMode) {
        scan = (mode, ProcessInfo.processInfo.systemUptime)
    }
    func advanceSpot() {
        measurement += 1
        startSampleWindow()
    }

    private func startSampleWindow() {
        firstSampleTime = ProcessInfo.processInfo.systemUptime
        nextSampleTime = firstSampleTime
    }
}
