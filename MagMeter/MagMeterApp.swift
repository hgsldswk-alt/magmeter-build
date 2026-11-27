import StoreKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MagMeterApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(D.accent)
                .preferredColorScheme(.light)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @State private var importingPreset = false

    var body: some View {
        content
            .dynamicTypeSize(model.accessibilityFixture ? .accessibility2 : dynamicTypeSize)
            .task { await model.start() }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .background { model.enteredBackground() }
                model.setActive(phase == .active)
            }
            .reviewAfterCoreAction(when: model.coreReviewHome && !importingPreset) { requestReview() }
            .onChange(of: model.reviewSignal) { _, _ in
                if !importingPreset { model.requestSharedReview { requestReview() } }
            }
            .onChange(of: model.manualReviewSignal) { _, _ in requestReview() }
            .onOpenURL { url in
                guard url.isFileURL, url.pathExtension.lowercased() == "magmeterpreset" else { return }
                Task { await model.readPresetFile(url) }
            }
            .fileImporter(isPresented: $importingPreset, allowedContentTypes: [.magMeterPreset]) { result in
                model.setModal(.importer, shown: false)
                switch result {
                case .success(let url):
                    Task { await model.readPresetFile(url) }
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled { model.notify(L.t("preset.invalid")) }
                }
            }
            .onChange(of: importingPreset) { _, value in
                if !value { model.setModal(.importer, shown: false) }
            }
            .sheet(item: $model.card, onDismiss: { model.setModal(.card, shown: false) }) { card in
                ShareView(request: card).onAppear { model.setModal(.card, shown: true) }
            }
            .sheet(item: rootActivity) { request in
                ActivitySheet(request: request) { model.completeShare(request, completed: $0) }
                    .onAppear { model.setModal(.activity, shown: true) }
                    .onDisappear { model.setModal(.activity, shown: false) }
            }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var rootActivity: Binding<ActivityRequest?> {
        Binding(get: { model.card == nil ? model.activity : nil }, set: { model.activity = $0 })
    }

    private func choosePresetFile() {
        if model.testing, let text = ProcessInfo.processInfo.environment["UITEST_PRESET_FILE"] {
            Task {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".magmeterpreset")
                defer { try? FileManager.default.removeItem(at: url) }
                do {
                    try Data(text.utf8).write(to: url)
                    await model.readPresetFile(url)
                } catch { model.notify(L.t("preset.invalid")) }
            }
        } else {
            model.setModal(.importer, shown: true)
            importingPreset = true
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch model.page {
                case .home: HomeView(openPresetFile: choosePresetFile)
                case .scan(let mode): ScanView(mode: mode)
                case .compare: CompareView()
                case .history: HistoryView()
                case .record(let id): RecordView(id: id)
                case .settings: SettingsView()
                case .preset: ImportView(openFile: choosePresetFile)
                }
                if let problem = model.storageProblem { HelpText(problem) }
            }
            .frame(maxWidth: 530)
            .padding(.horizontal, 21).padding(.top, 6).padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .id(model.page)
        }
        .scrollDismissesKeyboard(.interactively)
        .foregroundStyle(D.ink)
        .background(D.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let toast = model.toast { Toast(text: toast) }
        }
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
            .padding(.vertical, 9).padding(.horizontal, 14)
            .foregroundStyle(D.ink).background(D.tint, in: RoundedRectangle(cornerRadius: 14))
            .padding(8).allowsHitTesting(false)
    }
}

struct ShareConfirmation: View {
    var body: some View {
        HelpText(L.t("share.generated")).accessibilityIdentifier("share.requested")
    }
}

struct BackButton: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Button(L.t("action.back")) { model.back() }
            .buttonStyle(InlineButtonStyle()).accessibilityIdentifier("nav.back")
    }
}
