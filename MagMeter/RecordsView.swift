import SwiftUI

struct CompareView: View {
    @EnvironmentObject private var model: AppModel
    @State private var retaking = false
    @State private var retakeSpotID: UUID?

    var body: some View {
        PageHeader(title: L.t("mode.compare"), subtitle: L.t("compare.subtitle")) { BackButton() }
        readingPanel

        if let session = model.currentSession, !session.spots.isEmpty {
            SpotResults(session: session)
            Button(L.t("retake.title")) {
                retaking.toggle()
                retakeSpotID = nil
            }.buttonStyle(ToolButtonStyle()).accessibilityIdentifier("compare.retake")
            if retaking { retakeOptions(in: session) }
            RecordActions(session: session, milestone: model.compareMilestone == session.id)
        }
        Button(L.t("history.title")) { model.go(.history) }
            .buttonStyle(ToolButtonStyle()).accessibilityIdentifier("compare.history")
    }

    private var readingPanel: some View {
        Panel(tone: .teal) {
            MeterHeader()
            ReadingValue(value: model.meter.last?.vector.magnitude)
            RelativeSummary(baseline: model.meter.baseline ?? model.currentSession?.baseline, delta: model.meter.delta)
            if model.meter.baseline == nil {
                BaselineButton()
                HelpText(L.f("baseline.hold", model.preset(for: .compare).pose.title))
            } else {
                Tag(title: L.t(model.meter.delta == nil ? "pose.adjust" : "pose.same"))
                    .accessibilityIdentifier("compare.pose")
                HelpText(L.f("compare.pose", model.preset(for: .compare).pose.title))
                Button(L.t("capture.title")) { model.captureSpot() }
                    .buttonStyle(ToolButtonStyle(primary: true)).accessibilityIdentifier("compare.capture")
                    .disabled(!model.canCapture)
                BaselineButton()
            }
            if model.meter.poseMissing { HelpText(L.t("pose.unavailable")) }
            else if model.meter.baseline != nil && model.meter.delta == nil { HelpText(L.t("pose.recover")) }
            SensorHelp()
        }
    }

    private func retakeOptions(in session: FieldSession) -> some View {
        Panel {
            Text(L.t("retake.title")).font(.headline)
            HelpText(L.t("retake.help"))
            ForEach(session.spots.indices, id: \.self) { index in
                let spot = session.spots[index]
                Button(spot.label) { retakeSpotID = spot.id }
                    .buttonStyle(InlineButtonStyle())
                    .accessibilityIdentifier("retake.option.\(index)")
                if retakeSpotID == spot.id {
                    Button(L.t("retake.replace")) { retake(spot, keepHistory: false) }
                        .buttonStyle(ToolButtonStyle())
                        .accessibilityIdentifier("retake.replace")
                        .disabled(!model.canCapture)
                    Button(L.t("retake.keep")) { retake(spot, keepHistory: true) }
                        .buttonStyle(ToolButtonStyle())
                        .accessibilityIdentifier("retake.keep")
                        .disabled(!model.canCapture)
                }
            }
        }
    }

    private func retake(_ spot: SpotReading, keepHistory: Bool) {
        guard model.captureSpot(replacing: spot.id, keepHistory: keepHistory) else { return }
        retakeSpotID = nil
        retaking = false
    }
}

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PageHeader(title: L.t("history.title"), subtitle: L.t("history.subtitle")) { BackButton() }
        if Launch.freePeriod {
            Button(L.t("compare.new")) { model.select(.compare) }
                .buttonStyle(ToolButtonStyle(primary: true)).accessibilityIdentifier("history.new")
        }

        if model.library.sessions.isEmpty {
            Panel { HelpText(L.t("history.empty")) }
        } else {
            Panel(inset: 0) {
                ForEach(model.library.sessions.indices, id: \.self) { index in
                    let session = model.library.sessions[index]
                    if index > 0 { Divider() }
                    RouteRow(
                        title: L.f("history.baseline", L.reading(session.baseline.magnitude)),
                        subtitle: L.f("compare.pose", session.preset.pose.title),
                        identifier: "history.record.\(index)"
                    ) { model.go(.record(session.id)) }
                }
            }
        }

        if let spot = model.library.markedSpot {
            Panel {
                Text(L.t("history.mark")).font(.headline)
                SpotRow(spot: spot)
            }
        }
    }
}

struct RecordView: View {
    let id: UUID
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PageHeader(title: L.t("record.title"), subtitle: L.t("history.subtitle")) { BackButton() }
        if let session = model.session(id: id) {
            Panel(tone: .teal) {
                Text(L.f("history.baseline", L.reading(session.baseline.magnitude))).font(.headline)
                HelpText(L.f("compare.pose", session.preset.pose.title))
            }
            SpotResults(session: session)
            RecordActions(session: session, milestone: false)
        }
    }
}

struct SpotResults: View {
    let session: FieldSession
    @EnvironmentObject private var model: AppModel
    @State private var editing: SpotReading?
    @State private var name = ""

    private var extent: Double {
        max(5, (session.spots + session.retakes).map { abs($0.delta) }.max() ?? 0)
    }

    var body: some View {
        Panel {
            HStack(alignment: .top) {
                Text(L.t("record.spots")).font(.headline)
                Spacer()
                if session.baseline.source == .example { Tag(title: L.t("status.example")) }
            }
            ForEach(session.spots.indices, id: \.self) { index in
                let spot = session.spots[index]
                if index > 0 { Divider() }
                Button {
                    name = spot.label
                    editing = spot
                } label: {
                    HStack(spacing: 9) {
                        SpotRow(spot: spot, extent: extent)
                        Image(systemName: "pencil").foregroundStyle(D.accent).accessibilityHidden(true)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityIdentifier("spot.rename.\(index)")
            }
        }
        .sheet(item: $editing, onDismiss: { model.setModal(.edit, shown: false) }) { spot in
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: L.t("rename.title")) {
                    Button(L.t("action.cancel")) { editing = nil }
                        .buttonStyle(InlineButtonStyle()).accessibilityIdentifier("rename.cancel")
                }
                TextField(L.t("rename.label"), text: $name).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("rename.input")
                Button(L.t("action.save")) {
                    model.rename(session: session.id, spot: spot.id, label: name)
                    editing = nil
                }.buttonStyle(ToolButtonStyle(primary: true)).accessibilityIdentifier("rename.save")
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }.padding(21).foregroundStyle(D.ink).background(D.paper.ignoresSafeArea())
                .onAppear { model.setModal(.edit, shown: true) }
        }

        if !session.retakes.isEmpty {
            Panel {
                DisclosureGroup(L.t("retake.history")) {
                    ForEach(session.retakes.indices.reversed(), id: \.self) { index in
                        Divider()
                        SpotRow(spot: session.retakes[index], extent: extent)
                    }
                }.accessibilityIdentifier("record.retakes")
            }
        }
    }
}

struct SpotRow: View {
    let spot: SpotReading
    var extent: Double? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(spot.label).font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                Spacer()
                if let extent { DeltaBar(value: spot.delta, maximum: extent).frame(minWidth: 24, maxWidth: 78) }
                measures
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(spot.label).font(.subheadline.weight(.semibold))
                measures
                if let extent { DeltaBar(value: spot.delta, maximum: extent).frame(maxWidth: 150) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spot.label)
        .accessibilityValue(L.f("record.spoken", L.reading(spot.magnitude), L.reading(spot.delta, signed: true)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var measures: some View {
        HStack(spacing: 9) {
            Text(L.f("reading.unitValue", L.reading(spot.magnitude))).foregroundStyle(D.muted)
            Text(L.f("record.deltaValue", L.reading(spot.delta, signed: true))).foregroundStyle(D.accent)
        }.font(.subheadline.weight(.semibold)).monospacedDigit().fixedSize()
    }
}

struct RecordActions: View {
    let session: FieldSession
    let milestone: Bool
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel {
            if milestone {
                Text(L.t("milestone.comparison")).font(.headline).accessibilityIdentifier("compare.milestone")
                HelpText(L.t("milestone.comparisonHelp"))
            }
            Button(L.t("share.title")) {
                model.presentCard(milestone ? .milestone : .comparison, session: session)
            }.buttonStyle(ToolButtonStyle(primary: milestone)).accessibilityIdentifier("record.card")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { exports }
                VStack(spacing: 8) { exports }
            }
            if model.shareSignal { ShareConfirmation() }
        }
    }

    @ViewBuilder private var exports: some View {
        Button(L.t("export.csv")) { Task { await model.export(session.csv(), suffix: "csv") } }
            .buttonStyle(ToolButtonStyle()).accessibilityIdentifier("record.csv")
        Button(L.t("export.chart")) {
            guard let png = ShareRenderer.chart(for: session) else { model.notify(L.t("share.failed")); return }
            Task { await model.export(png, suffix: "png") }
        }.buttonStyle(ToolButtonStyle()).accessibilityIdentifier("record.chart")
    }
}
