import Foundation

// Abstraction underneath PeerSession so it can be backed by either MCSession
// (MCTransport) or a raw TCP/TLS socket (TCPTransport) without changing its
// public API. PeerSession owns PeerMessage encode/decode, resource-name
// parsing, and the Documents-directory move; a transport only shuttles raw
// encoded frames and resource-transfer events.
protocol PeerTransport: AnyObject {
    var transportDelegate: PeerTransportDelegate? { get set }

    /// Send one already-encoded PeerMessage frame.
    func send(_ data: Data)

    /// Transfer a file. `name`/`resourceID` are combined into the same
    /// "<resourceID>\u{001C}<name>" encoding PeerSession already parses.
    @discardableResult
    func sendResource(
        at url: URL,
        name: String,
        resourceID: String,
        onCompletion: @escaping SendCompletionHandler
    ) -> Progress

    func disconnect()
}

protocol PeerTransportDelegate: AnyObject {
    /// One decoded PeerMessage frame's raw bytes arrived.
    func transportDidReceive(_ data: Data)

    func transportDidDisconnect(byRequest: Bool)

    /// A resource transfer has begun. `resourceName` is the combined
    /// "<resourceID>\u{001C}<name>" string.
    func transport(didStartReceivingResourceNamed resourceName: String, progress: Progress)

    /// A resource transfer has finished (successfully or not). `localURL` is
    /// where the transport staged the file; PeerSession moves it into
    /// Documents on success.
    func transport(didFinishReceivingResourceNamed resourceName: String, at localURL: URL?, error: Error?)
}
