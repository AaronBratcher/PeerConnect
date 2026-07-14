import Foundation

/// Error payload for `PeerAdvertiser`/`PeerBrowser`'s `errorPublisher`s. The existing
/// delegate methods keep their `[String: Any]` shape; this is a cleaner value type
/// for the new reactive surface only.
public struct PeerConnectError: Error, Equatable {
    public let message: String
}

/// An inbound connection request, published by `PeerAdvertiser.connectionRequestPublisher`.
/// Exactly one of `accept()`/`reject()` has effect — whichever is called first (across
/// this and the paired `allowConnectionRequest` delegate callback, if both are in use).
public struct PeerConnectionRequest {
    public let remotePeer: Peer
    private let respond: (Bool) -> Void

    init(remotePeer: Peer, respond: @escaping (Bool) -> Void) {
        self.remotePeer = remotePeer
        self.respond = respond
    }

    public func accept() { respond(true) }
    public func reject() { respond(false) }
}

/// Published by `PeerSession.startedReceivingResourcePublisher` when a resource
/// transfer begins. `progress` is updated continuously by the framework.
public struct PeerReceivingResourceEvent {
    public let atURL: URL
    public let name: String
    public let resourceID: String
    public let progress: Progress
}

/// Published by `PeerSession.resourceReceivedPublisher` once a resource transfer
/// has completed and the file is available at `atURL`.
public struct PeerReceivedResourceEvent {
    public let atURL: URL
    public let name: String
    public let resourceID: String
}
