import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let magMeterPreset = UTType(exportedAs: "com.hgsldswk.magmeter.preset", conformingTo: .data)
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PageHeader(title: L.t("settings.title")) { BackButton() }

        Panel {
            Toggle(isOn: Binding(get: { model.library.haptics }, set: { model.toggleHaptics($0) })) {
                Text(L.t("settings.haptics")).font(.subheadline.weight(.semibold))
            }.frame(minHeight: 44).accessibilityIdentifier("settings.haptics")
            HelpText(L.t("settings.hapticsHelp"))
        }.disabled(!model.ready)

        Panel(inset: 0) {
            RouteRow(title: L.t("history.title"), identifier: "settings.history") { model.go(.history) }
            Divider()
            RouteRow(title: L.t("preset.title"), identifier: "settings.import") { model.openPreset() }
            if let preset = model.library.selectedPreset {
                Divider()
                RouteRow(title: preset.mode.title, subtitle: preset.pose.title, identifier: "settings.activePreset") {
                    model.select(preset.mode)
                }
            }
        }

        if !model.library.presets.isEmpty {
            Panel {
                Text(L.t("preset.saved")).font(.headline)
                ForEach(model.library.presets) { preset in
                    RouteRow(title: preset.mode.title,
                             subtitle: L.f("preset.summary", preset.pose.title, preset.windowSec),
                             identifier: "preset.saved.\(preset.mode.rawValue).\(preset.pose.rawValue).\(preset.windowSec)") {
                        model.usePreset(preset)
                    }
                }
            }
        }

        Button(L.t("settings.review")) { model.requestReviewManually() }
            .buttonStyle(ToolButtonStyle()).accessibilityIdentifier("settings.review")
        HelpText(L.t("settings.privacy"))
    }
}

struct ImportView: View {
    @EnvironmentObject private var model: AppModel
    let openFile: () -> Void

    var body: some View {
        PageHeader(title: L.t("preset.title"), subtitle: L.t("preset.subtitle")) { BackButton() }
        Panel {
            Text(L.t("preset.code")).font(.headline)
            TextField(L.t("preset.code"), text: $model.presetInput, axis: .vertical)
                .lineLimit(2...3).font(.footnote.monospaced())
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityIdentifier("preset.input")
                .onChange(of: model.presetInput) { _, value in model.previewPreset(value) }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { importOptions }
                VStack(spacing: 8) { importOptions }
            }
        }
        if let preset = model.presetPreview {
            Panel {
                Text(L.t("preset.preview")).font(.headline).accessibilityIdentifier("preset.preview")
                fact("preset.mode", preset.mode.title)
                fact("preset.pose", preset.pose.title)
                fact("preset.window", L.f("preset.seconds", preset.windowSec))
            }
            HelpText(L.t("preset.baseline"))
            Button(L.t("preset.use")) { model.usePreset(preset) }
                .buttonStyle(ToolButtonStyle(primary: true)).accessibilityIdentifier("preset.use")
                .disabled(!model.ready)
        } else if !model.presetInput.isEmpty {
            HelpText(L.t("preset.invalid")).accessibilityIdentifier("preset.error")
        }
    }

    @ViewBuilder private var importOptions: some View {
        PasteButton(payloadType: String.self) { strings in
            guard let code = strings.first else { return }
            model.presetInput = code
            model.previewPreset(code, showError: true)
        }.accessibilityIdentifier("preset.paste")
        Button(L.t("preset.file"), action: openFile)
            .buttonStyle(ToolButtonStyle()).accessibilityIdentifier("preset.file")
    }

    private func fact(_ key: String, _ value: String) -> some View {
        HStack {
            HelpText(L.t(key))
            Spacer()
            Text(value).font(.subheadline.weight(.semibold)).multilineTextAlignment(.trailing)
        }.accessibilityElement(children: .combine)
    }
}
