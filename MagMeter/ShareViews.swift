import SwiftUI
import UIKit

struct ActivitySheet: UIViewControllerRepresentable {
    let request: ActivityRequest
    let completion: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: request.items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            let succeeded = completed && error == nil
            Task { @MainActor in completion(succeeded) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct CardSpot: Identifiable {
    let id: UUID
    let name: String
    let magnitude: Double
    let delta: Double
}

private struct CardContent {
    let request: CardRequest
    let included: Set<UUID>
    let showNames: Bool
    let showFrozen: Bool

    var heading: String {
        switch request.kind {
        case .comparison: L.t("share.resultsTitle")
        case .milestone: L.t("share.comparisonTitle")
        case .firstReading, .frozen: L.t("share.firstTitle")
        }
    }

    var baseline: String? {
        guard !spots.isEmpty, let session = request.session else { return nil }
        return L.f("history.baseline", L.reading(session.baseline.magnitude))
    }

    var spots: [CardSpot] {
        guard let session = request.session else { return [] }
        return session.spots.enumerated().filter { included.contains($0.element.id) }.map { index, spot in
            CardSpot(id: spot.id, name: showNames ? spot.label : FieldSession.label(for: index),
                     magnitude: spot.magnitude, delta: spot.delta)
        }
    }
}

struct ShareView: View {
    let request: CardRequest
    @State private var included: Set<UUID>
    @State private var showNames = false
    @State private var showFrozen = false
    @State private var captionTopics = true
    @State private var qr: CGImage?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let url = DownloadCode.url(appID: Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String)
    private let maxCardSpots = 5

    init(request: CardRequest) {
        self.request = request
        _included = State(initialValue: Set(request.session?.spots.filter(\.comparable).prefix(2).map(\.id) ?? []))
    }

    private var content: CardContent {
        CardContent(request: request, included: included, showNames: showNames, showFrozen: showFrozen)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: L.t("share.title"), subtitle: L.t("share.preview")) {
                    Button(L.t("action.close")) { dismiss() }
                        .buttonStyle(InlineButtonStyle()).accessibilityIdentifier("share.close")
                }
                FieldCard(content: content, qr: qr, previewCode: url == nil)
                Button(L.t("share.image")) {
                    guard let image = ShareRenderer.card(content, qr: qr, preview: url == nil) else {
                        model.notify(L.t("share.failed"))
                        return
                    }
                    let caption = L.t("share.caption") + (captionTopics ? " " + L.t("share.topics") : "")
                    model.share([image, caption])
                }
                .buttonStyle(ToolButtonStyle(primary: true)).accessibilityIdentifier("share.image")
                .disabled(url != nil && qr == nil)
                if model.shareSignal { ShareConfirmation() }
                if let toast = model.toast { HelpText(toast) }
                HelpText(L.t("share.private"))
                options
                Button(L.t("preset.copy")) { model.copyPreset(request.preset) }
                    .buttonStyle(ToolButtonStyle()).accessibilityIdentifier("share.copy")
                Button(L.t("preset.export")) {
                    Task { await model.export(Data(request.preset.code.utf8), suffix: "magmeterpreset") }
                }.buttonStyle(ToolButtonStyle()).accessibilityIdentifier("share.presetFile")
            }.padding(21).foregroundStyle(D.ink).frame(maxWidth: 530)
                .frame(maxWidth: .infinity)
        }
        .background(D.paper.ignoresSafeArea())
        .task {
            guard let target = url else { return }
            qr = await Task.detached(priority: .userInitiated) { DownloadCode.image(for: target) }.value
            if qr == nil { model.notify(L.t("share.failed")) }
        }
        .sheet(item: $model.activity) { activity in
            ActivitySheet(request: activity) { model.completeShare(activity, completed: $0) }
                .onAppear { model.setModal(.activity, shown: true) }
                .onDisappear { model.setModal(.activity, shown: false) }
        }
    }

    private var options: some View {
        Panel {
            if let session = request.session {
                Text(L.t("share.select")).font(.headline)
                if session.spots.count > maxCardSpots { HelpText(L.f("share.limit", maxCardSpots)) }
                ForEach(session.spots.indices, id: \.self) { index in
                    let spot = session.spots[index]
                    Toggle(isOn: selection(spot.id)) {
                        Text(spot.label)
                    }.frame(minHeight: 44).accessibilityIdentifier("share.spot.\(index)")
                        .disabled(included.count >= maxCardSpots && !included.contains(spot.id))
                }
                Toggle(L.t("share.names"), isOn: $showNames)
                    .frame(minHeight: 44).accessibilityIdentifier("share.names")
            }
            if request.sample != nil {
                Toggle(L.t("share.includeReading"), isOn: $showFrozen)
                    .frame(minHeight: 44).accessibilityIdentifier("share.reading")
            }
            Toggle(L.t("share.includeTopics"), isOn: $captionTopics)
                .frame(minHeight: 44).accessibilityIdentifier("share.topics")
        }
    }

    private func selection(_ id: UUID) -> Binding<Bool> {
        Binding(get: { included.contains(id) }, set: { value in
            if value && included.count < maxCardSpots { included.insert(id) }
            if !value { included.remove(id) }
        })
    }
}

private struct FieldCard: View {
    let content: CardContent
    let qr: CGImage?
    let previewCode: Bool
    var output = false

    var body: some View {
        VStack(alignment: .leading, spacing: output ? 15 : 11) {
            Text(L.t("home.title")).font(.caption.weight(.bold)).tracking(1.4)
                .foregroundStyle(D.accent)
            Text(content.heading).font(.largeTitle.bold()).tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true)
            if let baseline = content.baseline {
                Text(baseline).font(.subheadline.weight(.semibold))
            }
            HelpText(L.f("compare.pose", content.request.preset.pose.title))
            if content.spots.isEmpty {
                if content.showFrozen, let sample = content.request.sample {
                    Text(L.f("reading.unitValue", L.reading(sample.vector.magnitude)))
                        .font(.title.weight(.bold)).monospacedDigit()
                }
                HelpText(L.t("share.steps"))
            } else {
                ComparisonBars(spots: content.spots, compact: output)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("share.card.results")
            }
            if output { Spacer(minLength: 0) }
            Divider().overlay(D.line)
            footer
        }
        .padding(output ? 26 : 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(D.ink)
        .background(.white, in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(D.line).allowsHitTesting(false) }
    }

    @ViewBuilder private var footer: some View {
        if output {
            horizontalFooter
        } else {
            ViewThatFits(in: .horizontal) {
                horizontalFooter
                VStack(alignment: .leading, spacing: 8) {
                    footerWords
                    qrImage
                }
            }
        }
    }

    private var horizontalFooter: some View {
        HStack(alignment: .bottom, spacing: 8) {
            footerWords
            Spacer(minLength: 0)
            qrImage
        }
    }

    private var footerWords: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.t("share.topics")).font(.caption2.weight(.semibold)).foregroundStyle(D.accent)
                .accessibilityIdentifier("share.card.topics")
            HelpText(L.t(previewCode ? "share.previewQR" : "share.download"))
        }
    }

    @ViewBuilder private var qrImage: some View {
        if let qr {
            Image(decorative: qr, scale: 1, orientation: .up)
                .interpolation(.none).resizable().scaledToFit().frame(width: output ? 78 : 91)
                .accessibilityLabel(L.t(previewCode ? "share.previewQR" : "share.download"))
        } else if previewCode {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(D.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .background(D.paper, in: RoundedRectangle(cornerRadius: 8))
                .frame(width: output ? 78 : 91, height: output ? 78 : 91)
                .accessibilityHidden(true)
        }
    }
}

private struct ComparisonBars: View {
    let spots: [CardSpot]
    var compact = false
    private var maxDelta: Double { max(1, spots.map { abs($0.delta) }.max() ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 9) {
            HelpText(L.t("chart.delta"))
            ForEach(spots) { spot in
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) {
                        Text(spot.name).lineLimit(1).frame(width: compact ? 72 : 84, alignment: .leading)
                        measures(spot)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(spot.name)
                        measures(spot)
                    }
                }
                .font(.caption.weight(.semibold)).monospacedDigit()
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func measures(_ spot: CardSpot) -> some View {
        HStack(spacing: 7) {
            Text(L.f("reading.unitValue", L.reading(spot.magnitude))).fixedSize()
            DeltaBar(value: spot.delta, maximum: maxDelta).frame(minWidth: 28)
            Text(L.f("reading.unitValue", L.reading(spot.delta, signed: true)))
                .foregroundStyle(D.accent).fixedSize()
        }
    }
}

@MainActor
enum ShareRenderer {
    fileprivate static func card(_ content: CardContent, qr: CGImage?, preview: Bool) -> UIImage? {
        let design = FieldCard(content: content, qr: qr, previewCode: preview, output: true)
            .frame(width: 328, height: 418, alignment: .topLeading)
            .padding(16)
            .frame(width: 360, height: 450)
            .background(D.paper)
            .environment(\.dynamicTypeSize, .medium)
        let renderer = ImageRenderer(content: design)
        renderer.scale = 3
        return renderer.uiImage
    }

    static func chart(for session: FieldSession) -> Data? {
        let data = session.spots.map { CardSpot(id: $0.id, name: $0.label, magnitude: $0.magnitude, delta: $0.delta) }
        let design = VStack(alignment: .leading, spacing: 16) {
            Text(L.t("mode.compare")).font(.title.bold())
            Text(L.f("history.baseline", L.reading(session.baseline.magnitude))).font(.headline)
            HelpText(L.f("compare.pose", session.preset.pose.title))
            ComparisonBars(spots: data)
        }.padding(24).frame(width: 420, alignment: .leading)
            .foregroundStyle(D.ink).background(.white)
            .environment(\.dynamicTypeSize, .medium)
        let renderer = ImageRenderer(content: design)
        renderer.scale = 2
        return renderer.uiImage?.pngData()
    }
}
