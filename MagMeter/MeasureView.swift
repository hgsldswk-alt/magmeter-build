import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    let openPresetFile: () -> Void

    var body: some View {
        PageHeader(title: L.t("home.title"), subtitle: L.t("home.subtitle")) {
            Button(L.t("settings.title")) { model.go(.settings) }
                .buttonStyle(InlineButtonStyle()).accessibilityIdentifier("home.settings")
        }

        Panel(tone: model.frozen ? .white : .teal) {
            MeterHeader()
            ReadingValue(value: model.meter.last?.vector.magnitude)
            axes
            TrendChart(points: model.meter.absolute, window: model.selectedWindow,
                       frozen: model.frozen || model.meter.status != .live)
            if model.frozen || model.meter.status == .live {
                Button(L.t(model.frozen ? "home.resume" : "home.freeze")) { model.toggleFreeze() }
                    .buttonStyle(ToolButtonStyle(primary: true))
                    .accessibilityIdentifier(model.frozen ? "home.resume" : "home.freeze")
            } else {
                SensorHelp()
            }
        }

        if model.frozen {
            Button(L.t("share.title")) { model.presentCard(.frozen) }
                .buttonStyle(ToolButtonStyle()).accessibilityIdentifier("home.card")
            HelpText(L.t("home.frozenHelp"))
        } else {
            Panel(inset: 0) {
                ForEach(MeasureMode.allCases) { mode in
                    if mode != .metal { Divider().overlay(D.line) }
                    RouteRow(title: mode.title, subtitle: mode.subtitle, identifier: "home.\(mode.rawValue)") {
                        model.select(mode)
                    }.disabled(mode == .compare && !model.ready)
                }
            }
            if model.introMilestone {
                Panel {
                    Text(L.t("milestone.first")).font(.headline)
                    Button(L.t("share.title")) { model.presentCard(.firstReading) }
                        .buttonStyle(ToolButtonStyle()).accessibilityIdentifier("home.milestone")
                }
            }
        }
        if let session = model.library.latestComparison {
            RouteRow(title: L.t("home.shareRecent"), identifier: "home.shareRecent") {
                model.presentCard(.comparison, session: session)
            }
        }
        Panel(inset: 0) {
            RouteRow(title: L.t("history.title"), identifier: "home.history") { model.go(.history) }
            Divider()
            RouteRow(title: L.t("preset.title"), identifier: "home.import") { model.openPreset() }
            Divider()
            RouteRow(title: L.t("preset.file"), identifier: "home.importFile", action: openPresetFile)
        }
    }

    private var axes: some View {
        let vector = model.meter.last?.vector
        let axes = [("axis.x", vector?.x), ("axis.y", vector?.y), ("axis.z", vector?.z)]
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { axisCells(axes) }
            VStack(spacing: 4) { axisCells(axes) }
        }
    }

    @ViewBuilder private func axisCells(_ axes: [(String, Double?)]) -> some View {
        ForEach(axes.indices, id: \.self) { index in
            let (key, value) = axes[index]
            HStack(spacing: 4) {
                Text(L.t(key)).font(.caption.weight(.bold)).foregroundStyle(D.muted)
                Text(L.reading(value)).font(.subheadline.weight(.semibold)).monospacedDigit()
            }.fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity).padding(5)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L.t(key))
                .accessibilityValue(value.map { L.f("reading.spoken", L.reading($0)) } ?? L.t("reading.wait"))
        }
    }
}

struct MeterHeader: View {
    @EnvironmentObject private var model: AppModel

    private var statusKey: String {
        if model.frozen && model.page == .home { return "status.frozen" }
        switch model.meter.status {
        case .waiting: return "status.waiting"
        case .live: return "status.live"
        case .paused: return "status.paused"
        case .unavailable: return "status.unavailable"
        case .invalid: return "status.invalid"
        case .saturated: return "status.saturated"
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(L.t("reading.strength")).font(.headline).fixedSize()
                Spacer()
                status
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("reading.strength")).font(.headline)
                status
            }
        }
    }

    private var status: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Tag(title: L.t(statusKey), live: statusKey == "status.live")
                .accessibilityIdentifier("reading.status")
            if model.storeShots && model.meter.last != nil { HelpText(L.t("status.example")) }
            if model.meter.last != nil && model.meter.status != .live && statusKey != "status.frozen" {
                HelpText(L.t("status.frozen"))
            }
        }
    }
}

struct SensorHelp: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.meter.status {
        case .unavailable:
            HelpText(L.t("sensor.unavailable"))
        case .saturated:
            HelpText(L.t("sensor.saturated"))
        case .paused, .invalid:
            Button(L.t("action.retry")) { model.retrySensor() }
                .buttonStyle(ToolButtonStyle()).accessibilityIdentifier("sensor.retry")
        default:
            EmptyView()
        }
    }
}

struct BaselineButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button(L.t(model.pendingBaseline ? "baseline.pending" : model.meter.baseline == nil ? "baseline.set" : "baseline.new")) {
            model.setBaseline()
        }
        .buttonStyle(ToolButtonStyle(primary: model.meter.baseline == nil))
        .disabled(model.pendingBaseline || model.meter.status != .live || model.meter.poseMissing)
        .accessibilityIdentifier("scan.baseline")
    }
}

struct RelativeSummary: View {
    let baseline: Baseline?
    let delta: Double?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { cells }
            VStack(spacing: 8) { cells }
        }
    }

    @ViewBuilder private var cells: some View {
        metric(L.t("baseline.label"), value: baseline?.magnitude, signed: false)
        metric(L.t("chart.change"), value: delta, signed: true)
    }

    private func metric(_ label: String, value: Double?, signed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HelpText(label)
            Text(value.map { L.f("reading.unitValue", L.reading($0, signed: signed)) } ?? L.t("reading.missing"))
                .font(.title3.weight(.bold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 11))
            .accessibilityElement(children: .combine)
    }
}

struct ScanView: View {
    let mode: MeasureMode
    @EnvironmentObject private var model: AppModel

    private var instruction: (title: String, detail: String, warning: Bool, id: String) {
        let meter = model.meter
        if meter.poseMissing {
            return ("pose.unavailableTitle", "pose.unavailable", true, "scan.pose")
        }
        if meter.baseline != nil {
            if meter.delta == nil { return ("pose.adjust", "pose.recover", true, "scan.pose") }
            if model.markedThisScan { return ("scan.marked", "scan.markedDetail", false, "scan.marked") }
            if meter.scan.repeatPeak != nil { return ("scan.similar", "scan.similarDetail", true, "scan.similar") }
            if meter.scan.firstPeak != nil { return ("scan.resweep", "scan.resweepDetail", true, "scan.resweep") }
            return ("scan.slow", mode == .wall ? "scan.wallSweep" : "scan.metalSweep", false, "scan.slow")
        }
        return (mode == .wall ? "scan.wallTip" : "scan.metalTip", mode == .wall ? "scan.wallSetup" : "scan.metalSetup", false, "scan.setup")
    }

    var body: some View {
        PageHeader(title: mode.title, subtitle: L.t(mode == .wall ? "scan.wallSubtitle" : "scan.metalSubtitle")) { BackButton() }
        Panel(tone: .teal) {
            MeterHeader()
            ReadingValue(value: model.meter.last?.vector.magnitude)
            RelativeSummary(baseline: model.meter.baseline, delta: model.meter.delta)
            if model.meter.baseline != nil {
                TrendChart(points: model.meter.relative, window: model.preset(for: mode).windowSec,
                           relative: true, endTime: model.meter.last?.time)
            } else {
                BaselineButton()
                HelpText(L.f("baseline.hold", model.preset(for: mode).pose.title))
            }
            SensorHelp()
        }
        Panel(tone: instruction.warning ? .warning : .white) {
            Text(L.t(instruction.title)).font(.headline)
                .foregroundStyle(instruction.warning ? D.amber : D.ink)
                .accessibilityIdentifier(instruction.id)
            HelpText(L.t(instruction.detail))
        }
        if model.meter.scan.repeatPeak != nil && !model.markedThisScan {
            Button(L.t("scan.mark")) { model.markSpot() }
                .buttonStyle(ToolButtonStyle(primary: true)).accessibilityIdentifier("scan.mark")
                .disabled(!model.canCapture)
        }
        if model.meter.baseline != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { scanActions }
                VStack(spacing: 8) { scanActions }
            }
        }
        HelpText(L.t(mode == .wall ? "scan.wallLimit" : "scan.metalLimit"))
    }

    @ViewBuilder private var scanActions: some View {
        BaselineButton()
        Button(L.t("scan.end")) { model.go(.home) }
            .buttonStyle(ToolButtonStyle()).accessibilityIdentifier("scan.end")
    }
}
