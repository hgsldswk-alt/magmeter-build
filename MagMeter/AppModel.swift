import Foundation
import SwiftUI
import UIKit

enum Page: Hashable {
    case home, scan(MeasureMode), compare, history, record(UUID), settings, preset

    var takesSamples: Bool {
        switch self {
        case .home, .scan, .compare: true
        default: false
        }
    }

    var allowsReview: Bool {
        switch self {
        case .settings, .history, .record: true
        default: false
        }
    }
}

enum CardKind { case frozen, firstReading, comparison, milestone }
enum ModalKind { case card, activity, edit, importer }

struct CardRequest: Identifiable {
    let id = UUID()
    let kind: CardKind
    let sample: FieldSample?
    let session: FieldSession?
    let preset: Preset
}

struct ActivityRequest: Identifiable {
    let id = UUID()
    let items: [Any]
    let temporaryFile: URL?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var page: Page = .home
    @Published private(set) var library = Library()
    @Published private(set) var ready = false
    @Published private(set) var meter = MeterEngine()
    @Published private(set) var frozen = false
    @Published private(set) var pendingBaseline = false
    @Published private(set) var currentSession: FieldSession?
    @Published private(set) var toast: String?
    @Published private(set) var storageProblem: String?
    @Published private(set) var shareSignal = false
    @Published private(set) var compareMilestone: UUID?
    @Published private(set) var introMilestone = false
    @Published private(set) var markedThisScan = false
    @Published private(set) var presetPreview: Preset?
    @Published var presetInput = ""
    @Published var card: CardRequest?
    @Published var activity: ActivityRequest?
    @Published var reviewSignal = 0
    @Published private(set) var manualReviewSignal = 0

    let testing: Bool
    let storeShots: Bool
    let accessibilityFixture: Bool
    let store: LocalStore
    private let source: MotionSource
    private let reset: Bool
    private var generation = 0
    private var revision = 0
    private var motionRunning = false
    private var motionStartedAt: TimeInterval = 0
    private var active = false
    private var reviewOnThisEntry = true
    private var sawScanCompletion = false
    private var pendingSince: TimeInterval?
    private var qualifyingFreeze = false
    private var pendingFreezeDate: Date?
    private var modals: Set<ModalKind> = []
    private var pageBeforeHistory: Page = .home
    private var pageBeforePreset: Page = .home
    private var presetFileRequest: UUID?
    private var lastSave: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var loaded = false
    private var storageReadable = false

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let testing = arguments.contains("-ui-testing")
        self.testing = testing
        storeShots = testing && arguments.contains("-store-shots")
        accessibilityFixture = testing && arguments.contains("-large-type")
        reset = testing && arguments.contains("-reset")
        let namespace = Launch.value("-data-id", in: arguments) ?? "default"
        let safeNamespace = namespace.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        store = LocalStore(test: testing, namespace: String(safeNamespace.prefix(80)))
        source = testing ? ExampleMotionSource(scenario: Launch.value("-scenario", in: arguments)) : DeviceMotionSource()
    }

    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var selectedWindow: Int { library.selectedPreset?.windowSec ?? 8 }
    var canCapture: Bool {
        ready && storageReadable && !pendingBaseline && meter.capture(now: uptime) != nil
    }

    func preset(for mode: MeasureMode) -> Preset {
        library.selectedPreset.flatMap { $0.mode == mode ? $0 : nil } ?? Preset.standard(for: mode)
    }

    func start() async {
        guard !loaded else { return }
        loaded = true
        if testing, let text = ProcessInfo.processInfo.environment["UITEST_PRESET_TEXT"] {
            UIPasteboard.general.string = text
        }
        updateMotion()
        do {
            library = try await store.load(reset: reset)
            storageReadable = true
            if let date = pendingFreezeDate { completeFreeze(on: date) }
        } catch {
            storageProblem = L.t("library.readError")
        }
        pendingFreezeDate = nil
        ready = true
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if value {
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.tick()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        } else {
            tickTask?.cancel()
            tickTask = nil
        }
        updateMotion()
    }

    func enteredBackground() { reviewOnThisEntry = true }

    private func tick() {
        guard active else { return }
        updateMotion()
        if motionRunning {
            var updated = meter
            let now = uptime
            if updated.status == .waiting && now - motionStartedAt > 1.5 {
                updated.interrupt(.paused)
            } else {
                updated.checkFreshness(now: now)
            }
            if updated.status != meter.status { meter = updated }
            finishBaselineIfPossible()
        }
        if reviewOnThisEntry && page.allowsReview && coreReviewHome {
            reviewOnThisEntry = false
            if !testing { reviewSignal += 1 }
        }
    }

    var coreReviewHome: Bool {
        active && ready && storageReadable && storageProblem == nil && toast == nil
            && (page.allowsReview || frozenForPage) && !motionRunning && card == nil && activity == nil
            && modals.isEmpty && !introMilestone
    }

    func requestSharedReview(_ request: () -> Void) {
        var progress = library.review
        guard page.allowsReview, coreReviewHome, CoreReview.shared.attempt(ifEligible: { progress.request(at: Date(), safe: true) }, request) else { return }
        library.review = progress
        saveLibrary()
    }

    func requestReviewManually() {
        guard page == .settings, modals.isEmpty, !testing else { return }
        reviewOnThisEntry = false
        manualReviewSignal += 1
    }

    func setModal(_ modal: ModalKind, shown: Bool) {
        if shown { modals.insert(modal) } else { modals.remove(modal) }
        updateMotion()
    }

    func go(_ destination: Page) {
        if frozen && destination.takesSamples && destination != .home {
            frozen = false
            qualifyingFreeze = false
        }
        if destination == .history && page != .history {
            switch page {
            case .record: break
            case .settings: pageBeforeHistory = .settings
            default: pageBeforeHistory = .home
            }
        }
        if page == .compare && destination != .compare {
            archiveCurrent()
            compareMilestone = nil
        }
        if page != destination {
            if let example = source as? ExampleMotionSource {
                example.resetScenario()
                meter.clearRecentSamples()
            }
            meter.clearBaseline()
            pendingSince = nil
            pendingBaseline = false
            markedThisScan = false
            sawScanCompletion = false
            shareSignal = false
        }
        page = destination
        updateMotion()
    }

    func back() {
        switch page {
        case .preset: go(pageBeforePreset)
        case .history: go(pageBeforeHistory)
        case .record: go(.history)
        default: go(.home)
        }
    }

    func select(_ mode: MeasureMode) {
        guard mode == .compare else { go(.scan(mode)); return }
        go(Launch.freePeriod ? .compare : .history)
    }

    private func updateMotion() {
        let desired = active && page.takesSamples && !frozenForPage
        guard desired != motionRunning else { return }
        generation += 1
        motionRunning = desired
        if desired {
            let token = generation
            motionStartedAt = uptime
            meter.interrupt(.waiting)
            source.start { [weak self] event in
                Task { @MainActor in self?.receive(event, generation: token) }
            }
        } else {
            source.stop()
            meter.interrupt(.paused)
            if page == .compare || scanMode != nil {
                meter.clearBaseline()
                pendingSince = nil
                pendingBaseline = false
            }
        }
    }

    private var scanMode: MeasureMode? {
        if case .scan(let mode) = page { return mode }
        return nil
    }
    private var frozenForPage: Bool { page == .home && frozen }

    private func receive(_ event: MotionEvent, generation token: Int) {
        guard token == generation, motionRunning else { return }
        switch event {
        case .failure(let status):
            meter.interrupt(status)
        case .orientationReset:
            meter.clearBaseline()
            meter.interrupt(.paused)
        case .samples(let samples):
            let window = scanMode.map { preset(for: $0).windowSec }
                ?? (page == .compare ? preset(for: .compare).windowSec : selectedWindow)
            var updated = meter
            let firstSampleTime = (source as? ExampleMotionSource)?.firstSampleTime ?? -Double.infinity
            for sample in samples where sample.time >= firstSampleTime {
                let event = updated.receive(sample, now: uptime, window: window)
                if event != nil && scanMode != nil && library.haptics && modals.isEmpty {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            meter = updated
            if scanMode != nil && updated.scan.repeatPeak != nil && !sawScanCompletion {
                sawScanCompletion = true
                recordMeasurement()
            }
        }
        finishBaselineIfPossible()
    }

    func retrySensor() {
        guard page.takesSamples else { return }
        generation += 1
        source.stop()
        motionRunning = false
        meter.clearBaseline()
        updateMotion()
    }

    func toggleFreeze() {
        if frozen {
            frozen = false
            if qualifyingFreeze {
                let date = Date()
                if storageReadable { completeFreeze(on: date) }
                else if storageProblem == nil { pendingFreezeDate = pendingFreezeDate ?? date }
            }
            qualifyingFreeze = false
        } else {
            guard meter.status == .live, let last = meter.last, uptime - last.time <= MeterEngine.staleAfter else { return }
            frozen = true
            qualifyingFreeze = true
            if storageReadable && !testing {
                library.coreReviewProgress = .recording(library.coreReviewProgress)
                saveLibrary(coreAction: true)
            }
        }
        updateMotion()
    }

    private func completeFreeze(on date: Date) {
        if !library.milestones.firstFreeze {
            library.milestones.firstFreeze = true
            introMilestone = true
        }
        recordMeasurement(on: date, countsForCore: false)
    }

    func setBaseline() {
        guard motionRunning, !pendingBaseline else { return }
        if page == .compare && (!ready || !storageReadable) {
            notify(L.t("history.readOnly"))
            return
        }
        pendingSince = uptime
        pendingBaseline = true
        finishBaselineIfPossible()
    }

    private func finishBaselineIfPossible() {
        guard let since = pendingSince else { return }
        guard uptime - since < 4 else {
            pendingSince = nil
            pendingBaseline = false
            notify(meter.poseMissing ? L.t("pose.unavailable") : L.t("baseline.failed"))
            return
        }
        guard let baseline = meter.setBaseline(now: uptime) else { return }
        pendingSince = nil
        pendingBaseline = false
        sawScanCompletion = false
        markedThisScan = false
        if page == .compare {
            archiveCurrent()
            currentSession = FieldSession(baseline: baseline, preset: preset(for: .compare))
        } else if let scanMode {
            source.beginScan(scanMode)
        }
    }

    @discardableResult func captureSpot(replacing id: UUID? = nil, keepHistory: Bool = false) -> Bool {
        guard canCapture, var session = currentSession,
              !session.archived, meter.baseline == session.baseline,
              let sample = meter.capture(now: uptime) else {
            notify(L.t("capture.wait"))
            return false
        }
        if let id {
            guard session.spots.contains(where: { $0.id == id }) else { return false }
            session.replace(id, with: sample, keepHistory: keepHistory)
        } else {
            let label = FieldSession.label(for: session.spots.count)
            session.spots.append(SpotReading(label: label, sample: sample, baseline: session.baseline))
        }
        currentSession = session
        upsert(session)
        if session.spots.count == 2 && id == nil {
            if !library.milestones.firstComparison {
                library.milestones.firstComparison = true
                compareMilestone = session.id
            }
            recordMeasurement()
        } else {
            saveLibrary()
        }
        if let example = source as? ExampleMotionSource {
            example.advanceSpot()
            meter.clearRecentSamples()
        }
        notify(L.t(id == nil ? "capture.saved" : "retake.saved"))
        return true
    }

    func markSpot() {
        guard canCapture, !markedThisScan, meter.scan.repeatPeak != nil,
              let baseline = meter.baseline, let sample = meter.capture(now: uptime) else {
            notify(L.t("capture.wait"))
            return
        }
        library.markedSpot = SpotReading(label: FieldSession.label(for: 0), sample: sample, baseline: baseline)
        markedThisScan = true
        saveLibrary()
    }

    func archiveCurrent() {
        guard var session = currentSession else { return }
        currentSession = nil
        guard !session.spots.isEmpty, !session.archived else { return }
        session.archived = true
        upsert(session)
        saveLibrary()
    }

    func rename(session id: UUID, spot spotID: UUID, label: String) {
        let cleaned = String(label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(40))
        guard !cleaned.isEmpty, var session = session(id: id),
              let index = session.spots.firstIndex(where: { $0.id == spotID }) else { return }
        session.spots[index].label = cleaned
        session.spots[index].customLabel = true
        if currentSession?.id == id { currentSession = session }
        upsert(session)
        saveLibrary()
    }

    func session(id: UUID) -> FieldSession? {
        if let currentSession, currentSession.id == id { return currentSession }
        return library.sessions.first { $0.id == id }
    }

    private func upsert(_ session: FieldSession) {
        if let index = library.sessions.firstIndex(where: { $0.id == session.id }) {
            library.sessions[index] = session
        } else {
            library.sessions.insert(session, at: 0)
        }
    }

    func toggleHaptics(_ on: Bool) {
        library.haptics = on
        saveLibrary()
    }

    func openPreset() {
        pageBeforePreset = page == .settings ? .settings : .home
        presetFileRequest = nil
        presetInput = ""
        presetPreview = nil
        go(.preset)
    }

    func previewPreset(_ input: String, showError: Bool = false) {
        presetPreview = Preset.decode(input)
        if presetPreview == nil && showError { notify(L.t("preset.invalid")) }
    }

    func readPresetFile(_ url: URL) async {
        if page != .preset { openPreset() }
        let request = UUID()
        presetFileRequest = request
        presetInput = ""
        presetPreview = nil
        do {
            let code = try await store.presetCode(at: url)
            guard page == .preset, presetFileRequest == request, presetInput.isEmpty else { return }
            presetInput = code
            previewPreset(presetInput, showError: true)
        } catch {
            if page == .preset && presetFileRequest == request && presetInput.isEmpty {
                notify(L.t("preset.invalid"))
            }
        }
    }

    func usePreset(_ preset: Preset) {
        guard ready, storageReadable else { return }
        if page == .preset && Preset.decode(presetInput) != preset { return }
        library.selectedPreset = preset
        if Launch.freePeriod && !library.presets.contains(preset) {
            library.presets.insert(preset, at: 0)
        }
        saveLibrary()
        notify(L.t("preset.applied"))
        select(preset.mode)
    }

    func presentCard(_ kind: CardKind, session: FieldSession? = nil) {
        shareSignal = false
        card = CardRequest(kind: kind, sample: kind == .frozen ? meter.last : nil,
                           session: session, preset: session?.preset ?? library.selectedPreset ?? .standard(for: .metal))
    }

    func share(_ items: [Any], temporaryFile: URL? = nil) {
        if testing {
            shareSignal = true
            if let temporaryFile { Task { await store.removeExport(temporaryFile) } }
            return
        }
        activity = ActivityRequest(items: items, temporaryFile: temporaryFile)
    }

    func completeShare(_ request: ActivityRequest, completed: Bool) {
        activity = nil
        reviewOnThisEntry = false
        if completed {
            library.review.completeShare()
            saveLibrary()
        }
        if let url = request.temporaryFile { Task { await store.removeExport(url) } }
    }

    func export(_ data: Data, suffix: String) async {
        shareSignal = false
        do {
            let file = try await store.export(data, extension: suffix)
            share([file], temporaryFile: file)
        } catch {
            notify(L.t("share.failed"))
        }
    }

    func copyPreset(_ preset: Preset) {
        UIPasteboard.general.string = preset.code
        notify(L.t("preset.copied"))
    }

    func notify(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    private func recordMeasurement(on date: Date = Date(), countsForCore: Bool = true) {
        guard storageReadable else { return }
        if !library.review.isQualified { reviewOnThisEntry = false }
        library.review.completeMeasurement(on: date)
        if countsForCore && !testing { library.coreReviewProgress = .recording(library.coreReviewProgress, at: date) }
        saveLibrary(coreAction: countsForCore)
    }

    private func saveLibrary(coreAction: Bool = false) {
        guard storageReadable else { return }
        revision += 1
        let number = revision
        let snapshot = library
        let prior = lastSave
        lastSave = Task { [weak self] in
            await prior?.value
            guard let self else { return }
            do {
                try await store.save(snapshot, revision: number)
                storageProblem = nil
                if coreAction { CoreReview.shared.record(snapshot.coreReviewProgress) }
            } catch {
                storageProblem = L.t("library.writeError")
            }
        }
    }

}
