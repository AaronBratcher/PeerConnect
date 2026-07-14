import Foundation

// Prevents a device running both a PeerAdvertiser and a PeerBrowser from
// ending up with two parallel PeerSessions to the same remote peer — e.g.
// both sides invite each other at roughly the same time ("glare"). Share one
// instance between an app's PeerAdvertiser and PeerBrowser to get full
// resolution; each defaults to a private instance otherwise, which still
// refuses a redundant duplicate attempt to an already-connected peer.
//
// Tie-break: when both an inbound and outbound attempt are in flight for the
// same remote peerID at once, the pair's connection is decided by comparing
// peerIDs — the greater peerID is that pair's "initiator." Both peers compute
// this identically from the same two peerIDs, so they converge on keeping the
// same one of the two racing connections without any extra negotiation.
public final class PeerSessionCoordinator: @unchecked Sendable {
    public let localPeerID: String

    /// Identifies one specific attempt. A losing attempt's own teardown code
    /// still calls markEnded/markEstablished with its token; the coordinator
    /// uses the token to recognize the slot no longer belongs to it (a winner
    /// may have already been registered in its place) and no-ops instead of
    /// clobbering the winner's registration.
    struct AttemptToken: Equatable {
        fileprivate let id = UUID()
    }

    private enum Slot {
        case outbound(token: AttemptToken, cancel: () -> Void)
        case inbound(token: AttemptToken, cancel: () -> Void)
        case established(token: AttemptToken)

        var token: AttemptToken {
            switch self {
            case .outbound(let token, _), .inbound(let token, _), .established(let token):
                return token
            }
        }
    }

    private var slots: [String: Slot] = [:]
    private let lock = NSLock()

    public init(localPeerID: String) {
        self.localPeerID = localPeerID
    }

    /// Call before dialing/inviting a peer. Returns `nil` if this attempt
    /// should be abandoned (already connected, already dialing, or lost the
    /// tie-break against a simultaneous inbound attempt from the same peer);
    /// otherwise returns a token to pass to `markEstablished`/`markEnded`.
    func beginOutbound(to remotePeerID: String, cancel: @escaping () -> Void) -> AttemptToken? {
        begin(remotePeerID: remotePeerID, isInitiatorSide: true) { .outbound(token: $0, cancel: cancel) }
    }

    /// Call before acting on an inbound invitation/connection. Returns `nil` if
    /// this attempt should be abandoned (already connected, already being
    /// accepted, or lost the tie-break against a simultaneous outbound attempt
    /// to the same peer); otherwise returns a token to pass to
    /// `markEstablished`/`markEnded`.
    func beginInbound(from remotePeerID: String, cancel: @escaping () -> Void) -> AttemptToken? {
        begin(remotePeerID: remotePeerID, isInitiatorSide: false) { .inbound(token: $0, cancel: cancel) }
    }

    /// Call right before constructing the `PeerSession` for an attempt that
    /// proceeded. A no-op if `token` no longer owns this peer's slot (i.e. this
    /// attempt already lost a tie-break to another one).
    func markEstablished(_ remotePeerID: String, token: AttemptToken) {
        lock.lock()
        defer { lock.unlock() }
        guard slots[remotePeerID]?.token == token else { return }
        slots[remotePeerID] = .established(token: token)
    }

    /// Call when that attempt/session ends (denied, failed, or disconnected),
    /// so a future attempt at the same peer isn't permanently blocked. A no-op
    /// if `token` no longer owns this peer's slot.
    func markEnded(_ remotePeerID: String, token: AttemptToken) {
        lock.lock()
        defer { lock.unlock() }
        guard slots[remotePeerID]?.token == token else { return }
        slots.removeValue(forKey: remotePeerID)
    }

    // MARK: - Shared logic

    private func begin(remotePeerID: String, isInitiatorSide: Bool, makeSlot: (AttemptToken) -> Slot) -> AttemptToken? {
        lock.lock()

        let token = AttemptToken()
        let newSlot = makeSlot(token)

        switch slots[remotePeerID] {
        case .established:
            lock.unlock()
            return nil

        case .outbound(_, let existingCancel):
            guard !isInitiatorSide else {
                lock.unlock()
                return nil // duplicate outbound attempt
            }
            // Opposing directions in flight: glare. localPeerID > remotePeerID
            // makes the local peer this pair's initiator (outbound side wins).
            guard isInitiatorSide == (localPeerID > remotePeerID) else {
                lock.unlock()
                return nil
            }
            slots[remotePeerID] = newSlot
            lock.unlock()
            existingCancel()
            return token

        case .inbound(_, let existingCancel):
            guard isInitiatorSide else {
                lock.unlock()
                return nil // duplicate inbound attempt
            }
            guard isInitiatorSide == (localPeerID > remotePeerID) else {
                lock.unlock()
                return nil
            }
            slots[remotePeerID] = newSlot
            lock.unlock()
            existingCancel()
            return token

        case nil:
            slots[remotePeerID] = newSlot
            lock.unlock()
            return token
        }
    }
}
