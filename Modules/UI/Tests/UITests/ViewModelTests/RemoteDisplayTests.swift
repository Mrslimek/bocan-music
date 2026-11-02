import Foundation
import Presence
import Testing
@testable import UI

// MARK: - RemoteDisplay computation (contract section 8, main-window
// display-source swap)

@Suite("RemoteDisplay computation")
struct RemoteDisplayTests {
    private static func lastKnown(status: PresenceStatus = .playing) -> SessionView.LastKnown {
        SessionView.LastKnown(
            trackHash: String(repeating: "a", count: 64),
            trackTitle: "Peer Track",
            positionSec: 42,
            playbackId: "stint-1",
            status: status,
            updatedAtMs: 1_000
        )
    }

    private static func remoteSession(
        reachability: SessionView.Reachability = .connected,
        status: PresenceStatus = .playing
    ) -> SessionView {
        SessionView(source: .remote(.init(
            peerID: "peer-1",
            peerName: "Pixel 8",
            reachability: reachability,
            lastKnown: Self.lastKnown(status: status)
        )))
    }

    @Test("local source maps to no display override")
    func localIsNil() {
        #expect(NowPlayingViewModel.remoteDisplayValues(for: .local) == nil)
        #expect(!NowPlayingViewModel.isRemoteSource(.local))
    }

    @Test("remote connected stint maps to the last-known pair, playing")
    func remoteConnected() throws {
        #expect(NowPlayingViewModel.isRemoteSource(Self.remoteSession().source))
        let values = try #require(NowPlayingViewModel.remoteDisplayValues(for: Self.remoteSession().source))
        #expect(values.peerName == "Pixel 8")
        #expect(values.fallbackTitle == "Peer Track")
        #expect(values.isPlaying)
        #expect(values.positionBaseSec == 42)
        #expect(values.updatedAtMs == 1_000)
        #expect(values.trackHash == String(repeating: "a", count: 64))
    }

    @Test("unreachable stint freezes: not playing, same base")
    func remoteUnreachable() throws {
        let values = try #require(NowPlayingViewModel.remoteDisplayValues(
            for: Self.remoteSession(reachability: .unreachable).source
        ))
        #expect(!values.isPlaying)
        #expect(values.positionBaseSec == 42)
        #expect(values.reachability == .unreachable)
    }

    @Test("paused stint is not playing")
    func remotePaused() throws {
        let values = try #require(NowPlayingViewModel.remoteDisplayValues(
            for: Self.remoteSession(status: .paused).source
        ))
        #expect(!values.isPlaying)
    }

    @Test("takeover in flight maps to the takeover's position, imminent play")
    func takeoverInFlight() throws {
        let takeover = SessionView.RemoteTakeover(
            peerID: "peer-1",
            peerName: "Pixel 8",
            trackHash: String(repeating: "b", count: 64),
            positionSec: 12.5
        )
        #expect(NowPlayingViewModel.isRemoteSource(.takeoverInFlight(takeover)))
        let values = try #require(NowPlayingViewModel.remoteDisplayValues(for: .takeoverInFlight(takeover)))
        #expect(values.peerName == "Pixel 8")
        #expect(values.isPlaying)
        #expect(values.positionBaseSec == 12.5)
        #expect(values.trackHash == String(repeating: "b", count: 64))
    }

    @Test("stint key changes on playbackId, status and reachability")
    func stintKey() throws {
        let base = try #require(NowPlayingViewModel.remoteDisplayValues(for: Self.remoteSession().source))
        let paused = try #require(NowPlayingViewModel.remoteDisplayValues(
            for: Self.remoteSession(status: .paused).source
        ))
        let unreachable = try #require(NowPlayingViewModel.remoteDisplayValues(
            for: Self.remoteSession(reachability: .unreachable).source
        ))
        #expect(base.key != paused.key)
        #expect(base.key != unreachable.key)
    }
}
