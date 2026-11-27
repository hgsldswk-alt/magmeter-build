import Foundation
import CoreImage
import XCTest

final class CoreTests: XCTestCase {
    private func sample(_ time: TimeInterval, _ magnitude: Double = 48, pose: Orientation? = .level) -> FieldSample {
        FieldSample(time: time, vector: FieldVector(x: 0, y: 0, z: magnitude), orientation: pose, source: .example)
    }

    private func readyEngine() -> MeterEngine {
        var engine = MeterEngine()
        for index in 0...28 {
            let reading = sample(1 + Double(index) * 0.04)
            _ = engine.receive(reading, now: reading.time, window: 8)
        }
        XCTAssertNotNil(engine.setBaseline(now: 2.12))
        return engine
    }

    func testMagnitudeSignedDeltaAndBaselineLeavesAbsoluteReadingInPlace() {
        let vector = FieldVector(x: 3, y: -4, z: 12)
        XCTAssertEqual(vector.magnitude, 13, accuracy: 0.0001)
        var engine = readyEngine()
        XCTAssertEqual(engine.last?.vector.magnitude, 48)
        XCTAssertEqual(engine.baseline?.magnitude, 48)
        XCTAssertEqual(engine.baseline?.delta(53), 5)
        XCTAssertEqual(engine.baseline?.delta(40), -8)
        XCTAssertEqual(engine.absolute.last?.value, 48)
        XCTAssertNotNil(engine.setBaseline(now: 2.12))
        XCTAssertEqual(engine.last?.vector.magnitude, 48)
    }

    func testBaselineUsesMedianAndRequiresUninterruptedStableOrientation() throws {
        let values = (0...29).map { index in
            sample(Double(index) * 0.04, index == 19 ? 51 : 48)
        }
        let baseline = try XCTUnwrap(Baseline.make(from: values))
        XCTAssertEqual(baseline.magnitude, 48)
        XCTAssertEqual(baseline.mad, 0)
        XCTAssertEqual(baseline.threshold, 5)
        XCTAssertNil(Baseline.make(from: Array(values.suffix(14))))
        XCTAssertNil(Baseline.make(from: values.filter { !((10...14).contains(Int(($0.time / 0.04).rounded()))) }))
        var tilted = values
        tilted[22] = sample(tilted[22].time, pose: Orientation(x: 0.25, y: 0, z: 0, w: sqrt(0.9375)))
        XCTAssertNil(Baseline.make(from: tilted))
        tilted[22] = sample(tilted[22].time, pose: nil)
        XCTAssertNil(Baseline.make(from: tilted))
    }

    func testPeakRequiresConsecutiveSamplesAndFallAndAcceptsNegativeChange() {
        var detector = PeakDetector()
        let values: [Double] = [10, 1, -6, -9, -7, -4, -2, -1, 0]
        let peaks = values.compactMap { detector.feed($0, threshold: 5) }
        XCTAssertEqual(peaks, [-9])
        var progress = ScanProgress()
        progress.record(-9)
        XCTAssertNil(progress.repeatPeak)
        progress.record(9)
        progress.record(-20)
        XCTAssertNil(progress.repeatPeak)
        progress.record(-8)
        XCTAssertEqual(progress.repeatPeak, -8)
    }

    func testOrientationLossPausesRelativeReadingsAndRestoresAfterStableWindow() {
        var engine = readyEngine()
        let good = (1...9).map { sample(2.12 + Double($0) * 0.04, 55) }
        for reading in good { _ = engine.receive(reading, now: reading.time, window: 8) }
        XCTAssertEqual(engine.delta, 7)
        XCTAssertNotNil(engine.capture(now: 2.48))
        let pose = Orientation(x: 0.4, y: 0, z: 0, w: sqrt(0.84))
        let rotated = sample(2.52, 60, pose: pose)
        _ = engine.receive(rotated, now: 2.52, window: 8)
        XCTAssertNil(engine.delta)
        XCTAssertNil(engine.capture(now: 2.52))
        XCTAssertEqual(engine.last?.vector.magnitude, 60)

        for index in 1...9 {
            let time = 2.52 + Double(index) * 0.04
            _ = engine.receive(sample(time, 50), now: time, window: 8)
        }
        XCTAssertEqual(engine.delta, 2)
        XCTAssertNotNil(engine.capture(now: 2.88))
        XCTAssertGreaterThan(Set(engine.relative.map(\.segment)).count, 1)
        let noPose = sample(2.92, 50, pose: nil)
        _ = engine.receive(noPose, now: 2.92, window: 8)
        XCTAssertTrue(engine.poseMissing)
        XCTAssertEqual(engine.status, .live)
        XCTAssertNil(engine.delta)
    }

    func testMissingStaleBadOrSaturatedSamplesAndRecovery() {
        var engine = MeterEngine()
        XCTAssertNil(engine.last)
        XCTAssertNil(engine.capture(now: 5))
        _ = engine.receive(sample(4), now: 5, window: 8)
        XCTAssertNil(engine.last)
        engine.interrupt(.unavailable)
        XCTAssertEqual(engine.status, .unavailable)

        _ = engine.receive(sample(5), now: 5, window: 8)
        XCTAssertEqual(engine.status, .live)
        engine.checkFreshness(now: 6)
        XCTAssertEqual(engine.status, .paused)
        XCTAssertEqual(engine.last?.vector.magnitude, 48)
        _ = engine.receive(sample(6, .nan), now: 6, window: 8)
        XCTAssertEqual(engine.status, .invalid)
        _ = engine.receive(sample(6.1, 2_000), now: 6.1, window: 8)
        XCTAssertEqual(engine.status, .saturated)
        XCTAssertNil(engine.capture(now: 6.1))
        _ = engine.receive(sample(6.2, 49), now: 6.2, window: 8)
        XCTAssertEqual(engine.status, .live)
        XCTAssertEqual(engine.last?.vector.magnitude, 49)
    }

    func testPresetRoundTripAndRejectsVersionOversizeUnexpectedFieldsAndValues() {
        let code = "MAG1:eyJtb2RlIjoiY29tcGFyZSIsInBvc2UiOiJmbGF0Iiwid2luZG93U2VjIjo4fQ"
        let preset = Preset.standard(for: .compare)
        XCTAssertEqual(Preset.decode(code), preset)
        XCTAssertEqual(Preset.decode("\n" + preset.code + "\n"), preset)
        XCTAssertNil(Preset.decode("MAG2:" + code.dropFirst(5)))
        XCTAssertNil(Preset.decode(code + String(repeating: "a", count: 512)))
        XCTAssertNil(Preset.decode("MAG1:!!!!"))
        XCTAssertNil(Preset.decode(encoded("{\"mode\":\"wall\",\"pose\":\"flat\",\"windowSec\":999}")))
        XCTAssertNil(Preset.decode(encoded("{\"mode\":\"wall\",\"pose\":\"flat\",\"windowSec\":8,\"hasPro\":true}")))
        XCTAssertNil(Preset.decode(encoded("{\"mode\":\"radar\",\"pose\":\"flat\",\"windowSec\":8}")))
    }

    private func encoded(_ json: String) -> String {
        "MAG1:" + Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func testRetakeAndCSVKeepGroupBaselineAndProtectUserSuppliedCells() throws {
        let baseline = Baseline(time: 1, magnitude: 48, mad: 0, orientation: .level, source: .example)
        var session = FieldSession(baseline: baseline, preset: .standard(for: .compare))
        let spot = SpotReading(label: "=A,\"B\"", customLabel: true, sample: sample(2, 51), baseline: baseline)
        session.spots = [spot]
        session.replace(spot.id, with: sample(3, 45), keepHistory: true)
        XCTAssertEqual(session.spots.first?.delta, -3)
        XCTAssertEqual(session.retakes.first?.delta, 3)
        XCTAssertEqual(session.spots.first?.label, spot.label)
        session.replace(spot.id, with: sample(4, 59), keepHistory: false)
        XCTAssertEqual(session.retakes.count, 1)
        XCTAssertEqual(FieldSession.label(for: 0), "A")
        XCTAssertEqual(FieldSession.label(for: 26), "AA")
        let csv = try XCTUnwrap(String(data: session.csv(), encoding: .utf8))
        XCTAssertTrue(csv.contains("\"'=A,\"\"B\"\"\""))
        XCTAssertTrue(csv.contains("59.0,11.0,48.0"))
        XCTAssertEqual(csv.split(separator: "\r\n").count, 3)
    }

    func testReadsLocalPresetFileAndRejectsOversizeFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.magmeterpreset")
        let store = LocalStore(test: true, namespace: "preset")
        let code = Preset.standard(for: .wall).code
        try Data(code.utf8).write(to: url)
        let loaded = try await store.presetCode(at: url)
        XCTAssertEqual(loaded, code)
        try Data(repeating: 65, count: Preset.maxLength + 1).write(to: url)
        do {
            _ = try await store.presetCode(at: url)
            XCTFail("Oversize preset accepted")
        } catch LocalFailure.invalidPreset {
        }
    }

    func testCoreReviewRequiresThreeActionsOnTwoLocalDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23)))
        let nextDay = firstDay.addingTimeInterval(2 * 3600)
        let empty = try JSONDecoder().decode(CoreReviewProgress.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isEligible)
        var progress = CoreReviewProgress.recording(empty, at: firstDay, calendar: calendar)
        var twoDays = progress
        twoDays.record(at: nextDay, calendar: calendar)
        XCTAssertFalse(twoDays.isEligible)
        progress.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(progress.isEligible)

        var sameDay = progress
        sameDay.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(sameDay.isEligible)

        let data = try JSONEncoder().encode(progress)
        progress = try JSONDecoder().decode(CoreReviewProgress.self, from: data)
        progress.record(at: nextDay, calendar: calendar)
        XCTAssertTrue(progress.isEligible)
    }

    func testReviewRequiresTwoDatesACompletedShareAndSafeNextOpportunity() {
        let now = Date()
        var review = ReviewGate()
        review.completeMeasurement(on: now)
        review.completeMeasurement(on: now)
        review.completeShare()
        XCTAssertFalse(review.request(at: now, safe: true))
        review.completeMeasurement(on: now.addingTimeInterval(-2 * 86_400))
        XCTAssertFalse(review.request(at: now, safe: false))
        XCTAssertTrue(review.request(at: now, safe: true))
        XCTAssertFalse(review.request(at: now.addingTimeInterval(179 * 86_400), safe: true))
        XCTAssertTrue(review.request(at: now.addingTimeInterval(180 * 86_400), safe: true))
    }

    func testQRCodeDecodesWithCIDetectorAndBuildsRealLinkWhenIDIsPresent() throws {
        XCTAssertNil(DownloadCode.url(appID: nil))
        XCTAssertNil(DownloadCode.url(appID: ""))
        XCTAssertNil(DownloadCode.url(appID: " 123"))
        XCTAssertNil(DownloadCode.url(appID: "https://example.com/magmeter"))
        let url = try XCTUnwrap(DownloadCode.url(appID: "123456789"))
        XCTAssertEqual(url, "https://apps.apple.com/app/id123456789")
        let image = try XCTUnwrap(DownloadCode.image(for: url))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let symbols = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertTrue(symbols.contains(url))
    }

    func testLatestComparisonSkipsUnfinishedSessionsAfterReloading() throws {
        let baseline = try XCTUnwrap(readyEngine().baseline)
        let first = SpotReading(label: "A", sample: sample(3, 49), baseline: baseline)
        let second = SpotReading(label: "B", sample: sample(4, 53), baseline: baseline)
        let preset = Preset.standard(for: .compare)
        var complete = FieldSession(baseline: baseline, preset: preset)
        complete.spots = [first, second]
        complete.archived = true
        var partial = FieldSession(baseline: baseline, preset: preset)
        partial.spots = [first]
        var library = Library()
        XCTAssertNil(library.latestComparison)
        library.sessions = [partial, complete]
        let restored = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(restored.latestComparison?.id, complete.id)
    }

    func testStringsComeFromTheTargetBundle() {
        XCTAssertNotEqual(L.t("home.freeze"), "home.freeze")
        XCTAssertNotEqual(L.f("reading.spoken", "48.2"), "reading.spoken")
    }
}
