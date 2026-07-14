import XCTest
@testable import PeerConnect

// Pure unit tests of the glare/duplicate-resolution state machine — no
// networking involved, so these run reliably in any environment and are
// where the tie-break logic is actually proven correct.
final class PeerSessionCoordinatorTests: XCTestCase {

    func testLoneOutboundThenEstablishedThenEndedFreesSlot() {
        let coordinator = PeerSessionCoordinator(localPeerID: "A")
        var cancelled = false

        let token = coordinator.beginOutbound(to: "B", cancel: { cancelled = true })
        XCTAssertNotNil(token)
        XCTAssertFalse(cancelled)

        coordinator.markEstablished("B", token: token!)

        // A second outbound attempt while established should be rejected.
        let second = coordinator.beginOutbound(to: "B", cancel: {})
        XCTAssertNil(second)

        coordinator.markEnded("B", token: token!)

        // Freed up — a new attempt should now succeed.
        let third = coordinator.beginOutbound(to: "B", cancel: {})
        XCTAssertNotNil(third)
    }

    func testLoneInboundThenEstablished() {
        let coordinator = PeerSessionCoordinator(localPeerID: "A")
        let token = coordinator.beginInbound(from: "B", cancel: {})
        XCTAssertNotNil(token)
        coordinator.markEstablished("B", token: token!)

        let second = coordinator.beginInbound(from: "B", cancel: {})
        XCTAssertNil(second)
    }

    func testDuplicateOutboundWhileOutboundPendingIsRejected() {
        let coordinator = PeerSessionCoordinator(localPeerID: "A")
        let first = coordinator.beginOutbound(to: "B", cancel: {})
        XCTAssertNotNil(first)

        var secondCancelled = false
        let second = coordinator.beginOutbound(to: "B", cancel: { secondCancelled = true })
        XCTAssertNil(second)
        XCTAssertFalse(secondCancelled)
    }

    func testDuplicateInboundWhileInboundPendingIsRejected() {
        let coordinator = PeerSessionCoordinator(localPeerID: "A")
        let first = coordinator.beginInbound(from: "B", cancel: {})
        XCTAssertNotNil(first)

        let second = coordinator.beginInbound(from: "B", cancel: {})
        XCTAssertNil(second)
    }

    // MARK: - Glare (opposing directions in flight simultaneously)

    func testGlareLocalInitiatorWinsOutboundOverExistingInbound() {
        // "A" > "B" lexicographically, so local ("A") is this pair's initiator:
        // outbound should win over an already-pending inbound from "B".
        let coordinator = PeerSessionCoordinator(localPeerID: "b-local")
        var inboundCancelled = false
        let inboundToken = coordinator.beginInbound(from: "a-remote", cancel: { inboundCancelled = true })
        XCTAssertNotNil(inboundToken)

        let outboundToken = coordinator.beginOutbound(to: "a-remote", cancel: {})
        XCTAssertNotNil(outboundToken, "local peerID > remote peerID: local is initiator, outbound should win")
        XCTAssertTrue(inboundCancelled, "the superseded inbound attempt's cancel should fire")

        // The old inbound token no longer owns the slot — its release must be a no-op,
        // not clobber the winning outbound's registration.
        coordinator.markEnded("a-remote", token: inboundToken!)
        // The outbound attempt should still be able to establish.
        coordinator.markEstablished("a-remote", token: outboundToken!)
        let duplicateAttempt = coordinator.beginOutbound(to: "a-remote", cancel: {})
        XCTAssertNil(duplicateAttempt, "should still read as established after the stale inbound token's markEnded no-op")
    }

    func testGlareLocalAcceptorLosesOutboundToExistingInbound() {
        // "a-local" < "b-remote", so local is the acceptor for this pair:
        // an existing outbound attempt should lose to an incoming inbound attempt.
        let coordinator = PeerSessionCoordinator(localPeerID: "a-local")
        var outboundCancelled = false
        let outboundToken = coordinator.beginOutbound(to: "b-remote", cancel: { outboundCancelled = true })
        XCTAssertNotNil(outboundToken)

        let inboundToken = coordinator.beginInbound(from: "b-remote", cancel: {})
        XCTAssertNotNil(inboundToken, "local peerID < remote peerID: local is acceptor, inbound should win")
        XCTAssertTrue(outboundCancelled, "the superseded outbound attempt's cancel should fire")

        coordinator.markEnded("b-remote", token: outboundToken!)
        coordinator.markEstablished("b-remote", token: inboundToken!)
        let duplicateAttempt = coordinator.beginInbound(from: "b-remote", cancel: {})
        XCTAssertNil(duplicateAttempt)
    }

    func testGlareLosingSideAttemptIsRejectedAndWinnerUntouched() {
        // Local is the acceptor ("a-local" < "b-remote"); a *new* outbound attempt
        // arriving after inbound already won should simply be rejected outright,
        // without disturbing the already-established/pending inbound.
        let coordinator = PeerSessionCoordinator(localPeerID: "a-local")
        let inboundToken = coordinator.beginInbound(from: "b-remote", cancel: {})
        XCTAssertNotNil(inboundToken)

        var outboundCancelled = false
        let outboundToken = coordinator.beginOutbound(to: "b-remote", cancel: { outboundCancelled = true })
        XCTAssertNil(outboundToken, "local is acceptor: a fresh outbound loses to the pending inbound")
        XCTAssertFalse(outboundCancelled, "a rejected new attempt's own cancel should never be invoked")

        // Inbound is untouched and can still proceed normally.
        coordinator.markEstablished("b-remote", token: inboundToken!)
    }

    // MARK: - Symmetry: both sides of a pair independently agree on the same winner

    func testBothSidesOfAPairAgreeOnTheSameWinningDirection() {
        // Device A's coordinator and device B's coordinator are independent
        // instances, but each computes the tie-break from the same two peerIDs,
        // so they must agree: whichever side has the greater peerID keeps its
        // outbound; the other keeps its inbound. This proves neither side can
        // end up rejecting the connection the other side kept (which would
        // otherwise leave both connections torn down).
        let aCoordinator = PeerSessionCoordinator(localPeerID: "peer-A")
        let bCoordinator = PeerSessionCoordinator(localPeerID: "peer-B")

        // Both sides start an outbound to each other, and each also sees an
        // inbound arrive from the other, in some interleaving.
        let aOutboundToken = aCoordinator.beginOutbound(to: "peer-B", cancel: {})
        let bOutboundToken = bCoordinator.beginOutbound(to: "peer-A", cancel: {})
        XCTAssertNotNil(aOutboundToken)
        XCTAssertNotNil(bOutboundToken)

        let aInboundResult = aCoordinator.beginInbound(from: "peer-B", cancel: {})
        let bInboundResult = bCoordinator.beginInbound(from: "peer-A", cancel: {})

        // "peer-B" > "peer-A", so B is the initiator for this pair: B's outbound
        // should win on B's side, and A's inbound (from B) should win on A's side.
        // That means A's outbound should have lost, and B's inbound should have lost.
        XCTAssertNotNil(aInboundResult, "A should accept B's inbound (B is the initiator)")
        XCTAssertNil(bInboundResult, "B should not also accept an inbound — it already won as the initiator via its outbound")
    }
}
