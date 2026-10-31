import Presence
import SwiftUI

/// The main player surface's SHARED SESSION panel (contract section 8). The
/// strip swaps its local player content for this panel whenever the
/// engine-owned session view has a remote stint: the peer's track/position/
/// status with an "on <peer>" badge, transport that dispatches `command`
/// messages to the peer, and a one-tap "Take over here" handoff.
///
/// Connection is a different axis from the session: while the stint peer is
/// unreachable or gone the panel keeps showing the last-known state with a
/// connection-lost indicator and disables transport, but "Take over here"
/// stays legal (section 8's conflict machinery covers the overlap).
///
/// The displayed position is a PRESENTATION dead-reckoning estimate while the
/// peer reports playing; the authoritative (positionSec, updatedAtMs) pair
/// lives only in the engine-owned `SessionView` holder.
struct RemoteSessionPanel: View {
    let session: SessionViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// View-layer playback clock for dead-reckoned position display only.
    @State private var displayNow = Date()

    private var stint: SessionView.RemoteStint? {
        if case let .remote(stint) = self.session.session.source {
            return stint
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "iPhone.radiowaves.left.and.right")
                .scaledSystemFont(size: 22, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 40)
                .help(L10n.string("Another device owns the shared session."))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: L10n.string("on \(self.stint?.peerName ?? "")"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let conflict = self.session.session.conflict {
                        Text(localized: "Both playing")
                            .font(.caption2)
                            .foregroundStyle(Color.warningTint)
                            .help(L10n.string("Both devices are playing: \(conflict.deviceNames.joined(separator: " + "))"))
                    }
                }
                if let stint = self.stint {
                    Text(verbatim: Self.trackText(stint.lastKnown))
                        .font(.body)
                        .lineLimit(1)
                    Text(verbatim: Self.statusText(stint, now: self.displayNow))
                        .font(.caption)
                        .foregroundStyle(stint.reachability == .connected ? .secondary : Color.warningTint)
                } else if case let .takeoverInFlight(takeover) = self.session.session.source {
                    Text(localized: "Taking over from \(takeover.peerName)…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 160, maxWidth: 340, alignment: .leading)

            Spacer(minLength: 16)

            if let stint = self.stint {
                self.transport(stint)
            }

            Spacer(minLength: 16)

            Button(L10n.string("Take over here")) {
                Task { await self.session.takeOverHere() }
            }
            .help(L10n.string("Resumes this track on this Mac from your own copy, at the peer's position."))
        }
        .frame(height: Theme.nowPlayingStripHeight)
        .padding(.horizontal, 16)
        .adaptiveMaterial()
        .task {
            // View-layer playback clock: only drives the dead-reckoned
            // position display while the peer reports playing.
            while !Task.isCancelled {
                self.displayNow = Date()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - Pieces

    private static func trackText(_ lastKnown: SessionView.LastKnown) -> String {
        lastKnown.trackTitle.isEmpty ? L10n.string("Nothing") : lastKnown.trackTitle
    }

    private static func statusText(
        _ stint: SessionView.RemoteStint,
        now: Date
    ) -> String {
        let position = Self.deadReckoned(
            lastKnown: stint.lastKnown,
            now: now
        )
        let minutes = Int(position) / 60
        let seconds = Int(position) % 60
        let clock = String(format: "%d:%02d", minutes, seconds)
        switch stint.reachability {
        case .connected:
            return stint.lastKnown.status == .playing
                ? L10n.string("Playing on \(stint.peerName) — \(clock)")
                : L10n.string("Paused on \(stint.peerName) — \(clock)")

        case .unreachable:
            return L10n.string("Connection lost — last seen at \(clock)")

        case .gone:
            return L10n.string("Last seen on \(stint.peerName) — \(clock)")
        }
    }

    /// Presentation-only dead reckoning: advances the last-known position by
    /// the elapsed wall time while the stint reports playing. The holder
    /// (SessionView) stores only the authoritative last-known pair.
    static func deadReckoned(
        lastKnown: SessionView.LastKnown,
        now: Date
    ) -> Double {
        guard lastKnown.status == .playing else { return lastKnown.positionSec }
        let elapsed = max(0, now.timeIntervalSince1970 * 1000 - lastKnown.updatedAtMs) / 1000
        return lastKnown.positionSec + elapsed
    }

    @ViewBuilder
    private func transport(_ stint: SessionView.RemoteStint) -> some View {
        let connected = stint.reachability == .connected
        HStack(spacing: 14) {
            Button {
                Task { await self.session.dispatch(.previous) }
            } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.plain)
            .disabled(!connected)
            .help(L10n.string("Sends previous to \(stint.peerName)."))

            Button {
                Task { await self.session.dispatch(.toggle) }
            } label: {
                Image(systemName: stint.lastKnown.status == .playing ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .scaledSystemFont(size: 18, weight: .medium)
            .disabled(!connected)
            .help(L10n.string("Sends \(stint.lastKnown.status == .playing ? "pause" : "play") to \(stint.peerName)."))

            Button {
                Task { await self.session.dispatch(.next) }
            } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.plain)
            .disabled(!connected)
            .help(L10n.string("Sends next to \(stint.peerName)."))
        }
    }
}
