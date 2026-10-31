import Foundation
import Testing
@testable import Presence

// MARK: - Backoff ladder

struct BackoffScheduleTests {
    @Test
    func ladderStepsWithoutJitter() {
        let schedule = BackoffSchedule()
        #expect(schedule.delay(attempt: 0, jitter: 0) == 1.5)
        #expect(schedule.delay(attempt: 1, jitter: 0) == 3)
        #expect(schedule.delay(attempt: 2, jitter: 0) == 6)
        #expect(schedule.delay(attempt: 3, jitter: 0) == 12)
        #expect(schedule.delay(attempt: 4, jitter: 0) == 24)
    }

    @Test
    func capAfterLadderExhausted() {
        let schedule = BackoffSchedule()
        for attempt in 5 ... 12 {
            #expect(schedule.delay(attempt: attempt, jitter: 0) == 30)
        }
    }

    @Test
    func jitterStaysWithinPlusMinus20Percent() {
        let schedule = BackoffSchedule()
        for attempt in 0 ... 6 {
            let base = schedule.baseDelay(attempt: attempt)
            let early = schedule.delay(attempt: attempt, jitter: -1)
            let late = schedule.delay(attempt: attempt, jitter: 1)
            #expect(early == base * 0.8)
            #expect(late == base * 1.2)
            // Random draws stay inside the band.
            for _ in 0 ..< 50 {
                let drawn = schedule.randomDelay(attempt: attempt)
                #expect(drawn >= base * 0.8 && drawn <= base * 1.2)
            }
        }
    }
}

// MARK: - Tie-break rule

struct TieBreakTests {
    @Test
    func smallerIDDials() {
        #expect(PresenceEngine.shouldDial(selfID: "aaa", peerID: "zzz"))
        #expect(!PresenceEngine.shouldDial(selfID: "zzz", peerID: "aaa"))
        #expect(!PresenceEngine.shouldDial(selfID: "same", peerID: "same"))
    }

    @Test
    func discoveryAppliesTieBreakOnlyToTheSmallerSide() async throws {
        let engine = Harness.makeEngine(selfID: "mmm", name: "Middle")
        // A peer with a LARGER id: we dial ("mmm" < "zzz"). A peer with a
        // smaller id ("aaa" < "mmm"): they dial us.
        try await engine.handleFound(PresenceAnnouncement(
            peerID: "aaa",
            name: "Small",
            endpoint: .url(#require(URL(string: "ws://127.0.0.1:1")))
        ))
        try await engine.handleFound(PresenceAnnouncement(
            peerID: "zzz",
            name: "Large",
            endpoint: .url(#require(URL(string: "ws://127.0.0.1:2")))
        ))
        let snapshot = await engine.currentPeersForTesting()
        let small = snapshot.first { $0.id == "aaa" }
        let large = snapshot.first { $0.id == "zzz" }
        // The tie-break winner gets a dial deadline; the loser waits. The
        // observable difference: the winner's dial fires through the tick loop.
        #expect(small != nil && large != nil)
        let largeDials = await engine.nextDialAtForTesting(peerID: "zzz")
        let smallDials = await engine.nextDialAtForTesting(peerID: "aaa")
        #expect(largeDials != nil)
        #expect(smallDials == nil)
    }

    @Test
    func reappearedPeerResumesScheduleFromScratch() async throws {
        let engine = Harness.makeEngine(selfID: "mmm", name: "Middle")
        try await engine.handleFound(PresenceAnnouncement(
            peerID: "aaa",
            name: "Small",
            endpoint: .url(#require(URL(string: "ws://127.0.0.1:1")))
        ))
        // Gone (mDNS removal applied), then found again.
        // (aaa < mmm, so the peer would dial us; the assertion is on revival.)
        await engine.handleRemovalHint(peerID: "aaa")
        await engine.applyExpiredRemovalsForTesting(now: Date().addingTimeInterval(10))
        try await engine.handleFound(PresenceAnnouncement(
            peerID: "aaa",
            name: "Small",
            endpoint: .url(#require(URL(string: "ws://127.0.0.1:1")))
        ))
        let snapshot = await engine.currentPeersForTesting()
        #expect(snapshot.first?.discovery == .discovered)
        #expect(await engine.nextDialAtForTesting(peerID: "aaa") != nil)
    }
}
