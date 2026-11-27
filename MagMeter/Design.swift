import Charts
import SwiftUI

enum D {
    static let paper = Color(red: 241/255, green: 245/255, blue: 248/255)
    static let ink = Color(red: 16/255, green: 38/255, blue: 53/255)
    static let muted = Color(red: 71/255, green: 96/255, blue: 109/255)
    static let line = Color(red: 216/255, green: 229/255, blue: 233/255)
    static let accent = Color(red: 0, green: 104/255, blue: 117/255)
    static let tint = Color(red: 225/255, green: 241/255, blue: 240/255)
    static let amber = Color(red: 116/255, green: 65/255, blue: 0)
    static let warning = Color(red: 1, green: 242/255, blue: 218/255)
}

enum PanelTone { case white, teal, warning
    var color: Color {
        switch self {
        case .white: .white
        case .teal: D.tint
        case .warning: D.warning
        }
    }
}

struct Panel<Content: View>: View {
    var tone: PanelTone = .white
    var inset: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(inset)
            .background(tone.color, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(D.line).allowsHitTesting(false) }
    }
}

struct ToolButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: primary ? 50 : 44)
            .padding(.horizontal, 9).padding(.vertical, 2)
            .foregroundStyle(primary ? .white : D.ink)
            .background(primary ? D.accent : Color.white, in: RoundedRectangle(cornerRadius: 13))
            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(primary ? D.accent : D.line).allowsHitTesting(false) }
            .opacity(!enabled ? 0.48 : configuration.isPressed ? 0.76 : 1)
    }
}

struct InlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold))
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(D.accent)
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.bold)).tracking(-0.9)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle { HelpText(subtitle) }
            }
            Spacer(minLength: 0)
            trailing
        }.frame(minHeight: 58)
    }
}

struct HelpText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.footnote).foregroundStyle(D.muted).fixedSize(horizontal: false, vertical: true) }
}

struct Tag: View {
    let title: String
    var live = false
    var body: some View {
        HStack(spacing: 5) {
            if live { Circle().fill(D.accent).frame(width: 6, height: 6).accessibilityHidden(true) }
            Text(title).font(.caption.weight(.semibold))
        }.padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(D.accent).background(D.tint, in: RoundedRectangle(cornerRadius: 15))
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
    }
}

struct RouteRow: View {
    let title: String
    var subtitle: String? = nil
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let subtitle { HelpText(subtitle) }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(D.accent).accessibilityHidden(true)
            }.frame(minHeight: 47).padding(.horizontal, 13).padding(.vertical, 4)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
    }
}

struct DeltaBar: View {
    let value: Double
    let maximum: Double

    var body: some View {
        GeometryReader { geometry in
            let center = geometry.size.width / 2
            let width = center * min(1, CGFloat(abs(value) / max(1, maximum)))
            ZStack(alignment: .leading) {
                Capsule().fill(D.tint)
                Rectangle().fill(D.muted).frame(width: 1).offset(x: center)
                Capsule().fill(D.accent).frame(width: width)
                    .offset(x: value < 0 ? center - width : center)
            }
        }.frame(height: 8).accessibilityHidden(true)
    }
}

struct ReadingValue: View {
    let value: Double?
    @ScaledMetric(relativeTo: .largeTitle) private var size = 66.0

    var body: some View {
        ViewThatFits(in: .horizontal) {
            valueText(size)
            valueText(size * 0.60)
            valueText(size * 0.40)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(L.t("reading.strength"))
            .accessibilityValue(value.map { L.f("reading.spoken", L.reading($0)) } ?? L.t("reading.wait"))
            .accessibilityIdentifier("reading.value")
    }

    private func valueText(_ scale: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(L.reading(value)).font(.system(size: scale, weight: .bold))
                .monospacedDigit().tracking(-scale * 0.045)
            Text(L.t("unit")).font(.title3.weight(.semibold)).foregroundStyle(D.muted)
        }.fixedSize(horizontal: true, vertical: false)
    }
}

struct TrendChart: View {
    let points: [TrendPoint]
    let window: Int
    var relative = false
    var frozen = false
    var endTime: TimeInterval? = nil

    private var timeScale: ClosedRange<Double> {
        let end = endTime ?? points.last?.time ?? 0
        return (end - Double(window))...end
    }

    private var valueScale: ClosedRange<Double> {
        let values = points.map(\.value)
        if relative {
            let extent = ceil(max(5, values.map { abs($0) }.max() ?? 0) / 5) * 5
            return -extent...extent
        }
        let bottom = max(0, floor(((values.min() ?? 40) - 2) / 5) * 5)
        let top = max(bottom + 10, ceil(((values.max() ?? 55) + 2) / 5) * 5)
        return bottom...top
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HelpText(L.t(relative ? "chart.delta" : frozen ? "chart.frozen" : "chart.field"))
            Chart {
                if relative {
                    RuleMark(y: .value(L.t("chart.baseline"), 0))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(D.muted)
                }
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value(L.t("chart.time"), point.time), y: .value(L.t("unit"), point.value),
                             series: .value(L.t("chart.series"), point.segment))
                        .foregroundStyle(D.accent).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            .chartXScale(domain: timeScale).chartYScale(domain: valueScale)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [valueScale.lowerBound, (valueScale.lowerBound + valueScale.upperBound) / 2, valueScale.upperBound]) { value in
                    AxisGridLine().foregroundStyle(D.line)
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(L.reading(number)).font(.caption2).monospacedDigit().foregroundStyle(D.muted)
                        }
                    }
                }
            }
            .frame(height: 72)
            .accessibilityHidden(true)

            HStack {
                HelpText(L.f("chart.ago", window))
                Spacer()
                HelpText(L.t(frozen ? "status.frozen" : "chart.now"))
            }.padding(.leading, 25).accessibilityHidden(true)
        }.accessibilityElement(children: .combine)
            .accessibilityValue(points.isEmpty ? L.t("reading.wait")
                                : L.f("chart.spoken", window, L.reading(points.last?.value, signed: relative)))
    }
}
