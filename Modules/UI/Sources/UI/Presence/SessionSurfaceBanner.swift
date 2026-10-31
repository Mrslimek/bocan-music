import Presence
import SwiftUI

/// The compact shared-session line the MAIN WINDOW shows above the play bar
/// (contract section 8). Renders nothing while the source is `.local`.
///
/// Connection is a different axis from the session: an unreachable or gone
/// stint keeps its last-known state visible here with warning styling; it
/// never silently flips the strip back to local. Position display dead-reckons
/// in the view only (`SessionView.LastKnown` stays authoritative); nothing
/// here writes back.
struct SessionSurfaceBanner: View {
    let session: SessionViewModel

    /// View-layer clock for the dead-reckoned position display only.
    @State private var displayNow = Date()

    private var stint: SessionView.RemoteStint? {
        if case let .remote(stint) = self.session.session.source {
            return stint
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conflict = self.session.session.conflict {
                self.conflictBanner(conflict)
            }
            if let stint = self.stint {
                self.remoteRow(stint)
            } else if case let .takeoverInFlight(takeover) = self.session.session.source {
                self.takeoverRow(takeover)
            }
        }
        .task {
            // Only drives the dead-reckoned position display while the
            // session shows a remote stint; presentation, never stored.
            while !Task.isCancelled {
                if self.stint?.lastKnown.status == .playing {
                    self.displayNow = Date()
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func remoteRow(_ stint: SessionView.RemoteStint) -> some View {
        let connected = stint.reachability == .connected
        HStack(spacing: 8) {
            Image(systemName: "paperplane.fill")
                .scaledSystemFont(size: 11, weight: .medium)
                .foregroundStyle(connected ? Color.textSecondary : Color.warningTint)
                .accessibilityHidden(true)
            Text(verbatim: Self.trackText(stint.lastKnown))
                .font(Typography.subheadline)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
            Text(verbatim: Self.positionText(stint, now: self.displayNow))
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .monospacedDigit()
            if connected {
                Text(L10n.string("Playing on \(stint.peerName)"))
                    .font(Typography.mini)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.textTertiary, lineWidth: 1)
                    }
            } else {
                Text(L10n.string("Connection lost — showing last known state from \(stint.peerName)"))
                    .font(Typography.caption)
                    .foregroundStyle(Color.warningTint)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button(L10n.string("Take over here")) {
                Task { await self.session.takeOverHere() }
            }
            .help(L10n.string("Resumes this track on this Mac from your own copy, at the peer's position."))
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Shared session"))
    }

    @ViewBuilder
    private func takeoverRow(_ takeover: SessionView.RemoteTakeover) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(L10n.string("Taking over from \(takeover.peerName)…"))
                .font(Typography.subheadline)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(.bar)
    }

    @ViewBuilder
    private func conflictBanner(_ conflict: SessionView.Conflict) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.warningTint)
                .accessibilityHidden(true)
            Text(L10n.string("Both devices are playing: \(conflict.deviceNames.joined(separator: " + "))"))
                .font(Typography.caption)
                .foregroundStyle(Color.warningTint)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        // Deliberately no dismissal affordance and no timer: the banner
        // clears only when the engine clears the conflict (section 8 never
        // auto-resolves).
    }

    // MARK: - Formatting

    private static func trackText(_ lastKnown: SessionView.LastKnown) -> String {
        lastKnown.trackTitle.isEmpty ? L10n.string("Nothing") : lastKnown.trackTitle
    }

    /// Dead-reckoned clock, computed on render from the authoritative
    /// (positionSec, updatedAtMs) pair. The estimate never leaves the view.
    private static func positionText(_ stint: SessionView.RemoteStint, now: Date) -> String {
        let position = RemoteSessionPanel.deadReckoned(lastKnown: stint.lastKnown, now: now)
        let minutes = Int(position) / 60
        let seconds = Int(position) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
