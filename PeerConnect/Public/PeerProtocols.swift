import Foundation

public typealias ConnectionRequestResponse = (_ allow: Bool) -> Void
public typealias SendCompletionHandler = @Sendable (_ sent: Bool) -> Void

public protocol PeerSessionDelegate: AnyObject {
    /// Called when the connection to the remote peer is broken.
    func disconnected(_ session: PeerSession, byRequest: Bool)

    /// Called when a text string is received from the remote peer.
    func textReceived(_ session: PeerSession, text: String)

    /// Called when arbitrary data is received from the remote peer.
    func dataReceived(_ session: PeerSession, data: Data)

    /// Called when a resource transfer has started. `progress` is updated by the framework.
    func startedReceivingResource(_ session: PeerSession, atURL: URL, name: String, resourceID: String, progress: Progress)

    /// Called when a resource transfer has completed and the file is available at `atURL`.
    func resourceReceived(_ session: PeerSession, atURL: URL, name: String, resourceID: String)
}

public protocol PeerBrowserDelegate: AnyObject {
    /// Called when the browser cannot start due to an error.
    func browserError(_ errorDict: [String: Any])

    /// Called when a new advertising peer is found.
    func serverFound(_ server: Peer)

    /// Called when a previously found peer is no longer visible.
    func serverLost(_ server: Peer)

    /// Called when a connection attempt failed (no response or transport error).
    func unableToConnect(_ server: Peer)

    /// Called when the remote peer explicitly denied the connection request.
    func connectionDenied(_ server: Peer)

    /// Called when a connection is fully established and the session is ready.
    func connected(_ session: PeerSession)
}

extension PeerBrowserDelegate {
    /// Called when `connectToServer(_:)` was refused by a shared `PeerSessionCoordinator`
    /// because the app already has (or is establishing) a session with this peer —
    /// either a plain duplicate, or the losing side of a simultaneous mutual-connect
    /// race with an advertiser also running on this device. Default no-op.
    public func duplicateConnectionRejected(_ server: Peer) {}
}

public protocol PeerAdvertiserDelegate: AnyObject {
    /// Called when the advertiser cannot publish due to an error.
    func advertiserError(_ errorDict: [String: Any])

    /// Called when a remote peer requests a connection. Call `requestResponse` with `true` to allow.
    func allowConnectionRequest(_ remotePeer: Peer, requestResponse: @escaping ConnectionRequestResponse)

    /// Called when a client has connected and the session is ready.
    func clientDidConnect(_ session: PeerSession)
}

extension PeerAdvertiserDelegate {
    /// Called when an inbound connection attempt was refused by a shared
    /// `PeerSessionCoordinator` because the app already has (or is establishing) a
    /// session with this peer — either a plain duplicate, or the losing side of a
    /// simultaneous mutual-connect race with a browser also running on this device.
    /// `allowConnectionRequest` is not called for a rejection like this. Default no-op.
    public func duplicateConnectionRejected(_ remotePeer: Peer) {}
}
