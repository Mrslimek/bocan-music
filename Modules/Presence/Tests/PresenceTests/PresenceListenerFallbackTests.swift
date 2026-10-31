import Foundation
import Testing

@testable import Presence

// MARK: - Listener stack selection

@Suite
struct PresenceListenerFallbackTests {
    /// Under `.automatic` the listener runs the NW probe and falls back to the
    /// BSD stack exactly when the NW listen path fails, so the engine ends up
    /// bound either way. The expected outcome is derived from the same probe
    /// the production decision uses, which keeps the assertion true on both
    /// healthy and broken macOS builds.
    @Test
    func automaticResolvesToAWorkingStack() async throws {
        let nwWorks = await LoopbackIntegrationTests.listenerBindable()
        let listener = PresenceListener(configuredStack: .automatic)
        let port = try await listener.start(
            advertise: false,
            serviceName: "PresenceFallbackTest",
            txt: PresenceListener.txtRecord(id: "fallback-test", name: "FallbackTest", version: 1)
        )
        #expect(port > 0)
        let effective = await listener.effectiveStack
        #expect(effective == (nwWorks ? .networkFramework : .bsdSocket))
        await listener.stop()
    }

    /// The forced BSD stack binds an ephemeral port and reports itself.
    @Test
    func forcedBSDStackBindsAndReports() async throws {
        let listener = PresenceListener(configuredStack: .bsdSocket)
        let port = try await listener.start(
            advertise: false,
            serviceName: "PresenceBSDTest",
            txt: PresenceListener.txtRecord(id: "bsd-test", name: "BSDTest", version: 1)
        )
        #expect(port > 0)
        #expect(await listener.effectiveStack == .bsdSocket)
        await listener.stop()
    }
}
