import Presence
import SwiftUI

// MARK: - PeersWindowView

/// The Presence Peers window: every peer the engine knows about, connected and
/// discovered, with its live playback state as last announced.
public struct PeersWindowView: View {
    @State private var viewModel: PeersViewModel

    public init(viewModel: PeersViewModel) {
        self._viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Group {
            if self.viewModel.peers.isEmpty {
                ContentUnavailableView {
                    Text(localized: "No peers yet")
                } description: {
                    Text(localized: "Devices running Bòcan on your local network show up here once Presence is on and they are discovered.")
                }
            } else {
                self.peerTable
            }
        }
        .overlay(alignment: .bottom) {
            if let message = self.viewModel.handoffMessage {
                Text(message == .libraryUnsynced
                    ? L10n.string("Library not synced")
                    : L10n.string("Couldn't start that track here"))
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: self.viewModel.handoffMessage)
        .frame(minWidth: 640, minHeight: 320)
        .navigationTitle(L10n.string("Presence Peers"))
        .task {
            await self.viewModel.start()
        }
    }

    private var peerTable: some View {
        Table(self.viewModel.peers) {
            TableColumn(L10n.string("Device")) { peer in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: peer.name)
                        .font(.body)
                    Text(peer.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            TableColumn(L10n.string("Status")) { peer in
                Text(Self.connectionText(peer))
                    .foregroundStyle(peer.connection == .connected ? Color.primary : Color.secondary)
            }
            .width(min: 90, ideal: 110)
            TableColumn(L10n.string("Now Playing")) { peer in
                Text(Self.playbackText(peer))
                    .foregroundStyle(.secondary)
            }
            TableColumn(L10n.string("Position")) { peer in
                Text(Self.positionText(peer))
                    .foregroundStyle(.secondary)
            }
            TableColumn(L10n.string("RTT")) { peer in
                Text(Self.rttText(peer))
                    .foregroundStyle(.secondary)
            }
            TableColumn(L10n.string("Controls")) { peer in
                HStack(spacing: 8) {
                    Self.controlButtons(
                        send: { action in
                            Task { await self.viewModel.sendCommand(to: peer, action: action) }
                        },
                        connected: peer.connection == .connected
                    )
                    // Shared session (contract section 8): a session-capable
                    // peer (trackHash present) offers "Play here" - the
                    // takeover handoff from this Mac's own copy.
                    if peer.playback?.trackHash != nil {
                        Button(L10n.string("Play here")) {
                            Task { await self.viewModel.playHere(peer) }
                        }
                        .buttonStyle(.borderless)
                        .disabled(peer.connection != .connected)
                        .help(L10n.string("Resumes this track on this Mac from your own copy, at the peer's position."))
                    }
                }
            }
        }
    }

    /// Per-peer transport controls: play, pause and stop over the `command`
    /// message (contract section 6). Greyed out unless the peer is CONNECTED;
    /// commands are fire-and-forget, so the buttons only report sending.
    @ViewBuilder
    static func controlButtons(send: @escaping (PresenceCommandAction) -> Void, connected: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                send(.play)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!connected)
            .help(L10n.string("Sends play to this peer."))

            Button {
                send(.pause)
            } label: {
                Image(systemName: "pause.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!connected)
            .help(L10n.string("Sends pause to this peer."))

            Button {
                send(.stop)
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!connected)
            .help(L10n.string("Sends stop (pause and rewind) to this peer."))
        }
    }

    // MARK: Cell formatting

    static func connectionText(_ peer: PeerSnapshot) -> String {
        switch peer.connection {
        case .connected:
            L10n.string("Connected")

        case .connecting:
            L10n.string("Connecting…")

        case .unreachable:
            L10n.string("Unreachable")

        case .idle:
            switch peer.discovery {
            case .discovered, .inboundOnly:
                L10n.string("Discovered")

            case .gone:
                L10n.string("Gone")
            }
        }
    }

    static func playbackText(_ peer: PeerSnapshot) -> String {
        guard let playback = peer.playback, !playback.track.isEmpty else {
            return L10n.string("Nothing")
        }
        var text = playback.track
        if let artist = playback.artist, !artist.isEmpty {
            text += " · \(artist)"
        }
        return text
    }

    static func positionText(_ peer: PeerSnapshot) -> String {
        guard let playback = peer.playback else { return "-" }
        let minutes = Int(playback.positionSec) / 60
        let seconds = Int(playback.positionSec) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func rttText(_ peer: PeerSnapshot) -> String {
        guard let rtt = peer.rttMs else { return "-" }
        return L10n.string("\(Int(rtt)) ms")
    }
}
