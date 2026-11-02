import Presence
import SwiftUI

/// The compact shared-session chip the MAIN WINDOW shows above the play bar
/// (contract section 8; ADR-097 amendment). The main now-playing surface
/// itself carries the remote stint's content (display-source swap in
/// `NowPlayingViewModel`), so this is a single-line status chip: who owns the
/// stint and whether the connection is alive, plus the "Take over here"
/// affordance. Renders nothing while the source is `.local`.
///
/// Connection is a different axis from the session: an unreachable or gone
/// stint keeps its chip in warning styling and the main surface keeps
/// rendering the last-known state — it never silently flips back to local.
struct SessionSurfaceBanner: View {
    let session: SessionViewModel

    var body: some View {
        VStack(spacing: 4) {
            if let conflict = self.session.session.conflict {
                self.conflictChip(conflict)
            }
            switch self.session.session.source {
            case .local:
                EmptyView()

            case let .remote(stint):
                self.stintChip(stint)

            case let .takeoverInFlight(takeover):
                self.takeoverChip(takeover)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func stintChip(_ stint: SessionView.RemoteStint) -> some View {
        let connected = stint.reachability == .connected
        HStack(spacing: 6) {
            Image(systemName: "paperplane.fill")
                .scaledSystemFont(size: 10, weight: .medium)
                .foregroundStyle(connected ? Color.textSecondary : Color.warningTint)
                .accessibilityHidden(true)
            Text(verbatim: connected
                ? L10n.string("Playing on \(stint.peerName)")
                : L10n.string("Connection lost — showing last known state from \(stint.peerName)"))
                .font(Typography.caption)
                .foregroundStyle(connected ? Color.textSecondary : Color.warningTint)
                .lineLimit(1)
            // A takeover is legal even while the stint peer is unreachable
            // (section 8), so the affordance stays for both reachabilities.
            Text(L10n.string("Take over here"))
                .font(Typography.mini)
                .foregroundStyle(Color.textSecondary)
                .underline()
                .onTapGesture {
                    Task { await self.session.takeOverHere() }
                }
                .help(L10n.string("Resumes this track on this Mac from your own copy, at the peer's position."))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(.bar)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(connected ? Color.textTertiary : Color.warningTint, lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Shared session"))
    }

    @ViewBuilder
    private func takeoverChip(_ takeover: SessionView.RemoteTakeover) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(verbatim: L10n.string("Taking over from \(takeover.peerName)…"))
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(.bar)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.textTertiary, lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    private func conflictChip(_ conflict: SessionView.Conflict) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledSystemFont(size: 10)
                .foregroundStyle(Color.warningTint)
                .accessibilityHidden(true)
            Text(verbatim: L10n.string("Both devices are playing: \(conflict.deviceNames.joined(separator: " + "))"))
                .font(Typography.caption)
                .foregroundStyle(Color.warningTint)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(.bar)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.warningTint, lineWidth: 1)
                }
        }
        // Deliberately no dismissal affordance and no timer: the chip clears
        // only when the engine clears the conflict (section 8 never
        // auto-resolves).
    }
}
