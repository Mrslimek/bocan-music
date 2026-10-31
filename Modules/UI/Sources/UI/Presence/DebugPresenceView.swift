import SwiftUI

// MARK: - DebugPresenceView

/// DEBUG-only window: a live, human-readable log of inter-device Presence
/// communication (directions, peer names, message types with key fields), over
/// the `.presence` log category. Compiled out of Release with its scene.
public struct DebugPresenceView: View {
    @State private var viewModel = DebugPresenceViewModel()

    public init() {}

    public var body: some View {
        ScrollViewReader { proxy in
            List(self.viewModel.lines) { line in
                Text(verbatim: line.text)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    .id(line.id)
            }
            .listStyle(.plain)
            .onChange(of: self.viewModel.lines.count) { _, _ in
                guard self.viewModel.isTailing, let last = self.viewModel.lines.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .overlay {
            if self.viewModel.lines.isEmpty {
                Text(localized: "No Presence traffic yet. Turn Presence on and wait for a peer.")
                    .foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: self.$viewModel.isTailing) {
                    Text(localized: "Follow")
                }
                .toggleStyle(.checkbox)
                .help(L10n.string("Keeps the newest line in view as traffic arrives."))
            }
        }
        .navigationTitle(L10n.string("Debug Presence"))
        .task {
            self.viewModel.start()
        }
        .onDisappear {
            self.viewModel.stop()
        }
    }
}
