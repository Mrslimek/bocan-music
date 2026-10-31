import Presence
import SwiftUI

// MARK: - PresenceSettingsView

/// Settings -> Presence: the enable toggle and this Mac's presence status
/// (device name, id tail, port, live peer counts). Modeled on the Phone Sync
/// pane; a protocol-free view model over the engine.
public struct PresenceSettingsView: View {
    @State private var viewModel: PresenceViewModel

    public init(viewModel: PresenceViewModel) {
        self._viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Form {
            self.enableSection
            self.controlSection
            self.statusSection
        }
        .formStyle(.grouped)
        .task {
            await self.viewModel.load()
        }
    }

    private var enableSection: some View {
        Section {
            Toggle(isOn: self.enabledBinding) {
                Text(localized: "Presence")
            }
            .help(L10n.string("Shares what is playing with other Bòcan devices on your Wi-Fi, and shows what they play here."))
            if self.viewModel.enabled {
                Text(localized: "On. Discoverable on your local network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(localized: "Presence shares what is playing with other Bòcan devices on your Wi-Fi. Only your own network takes part.")
        }
    }

    private var controlSection: some View {
        Section {
            Toggle(isOn: self.controlBinding) {
                Text(localized: "Allow peers to control playback")
            }
            .help(L10n.string("Peers on your network can play, pause, skip and seek in your library when this is on."))
        } footer: {
            Text(localized: "Applies to inbound commands only; controlling other peers is always available.")
        }
    }

    private var statusSection: some View {
        Section(L10n.string("Status")) {
            LabeledContent {
                Text(self.viewModel.deviceName)
                    .foregroundStyle(.secondary)
            } label: {
                Text(localized: "This device")
            }
            LabeledContent {
                Text(self.viewModel.deviceIDTail)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            } label: {
                Text(localized: "Device ID")
            }
            if let port = self.viewModel.port {
                LabeledContent {
                    Text(String(port))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                } label: {
                    Text(localized: "Port")
                }
            }
            LabeledContent {
                Text(self.viewModel.enabled
                    ? L10n.string("\(self.viewModel.connectedCount) connected, \(self.viewModel.discoveredCount) discovered")
                    : L10n.string("Off"))
                    .foregroundStyle(.secondary)
            } label: {
                Text(localized: "Peers")
            }
        }
    }

    private var controlBinding: Binding<Bool> {
        Binding(
            get: { self.viewModel.controlEnabled },
            set: { newValue in
                self.viewModel.setControlEnabled(newValue)
            }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.viewModel.enabled },
            set: { newValue in
                Task { await self.viewModel.setEnabled(newValue) }
            }
        )
    }
}
