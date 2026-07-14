import Foundation
import MultipeerConnectivity

// Wraps an already-connected MCSession as a PeerTransport. This is a pure
// extraction of what PeerSession used to do directly as an MCSessionDelegate
// — behavior is unchanged, only the ownership moved so PeerSession can also
// be backed by TCPTransport.
final class MCTransport: NSObject, PeerTransport, @unchecked Sendable {
    weak var transportDelegate: PeerTransportDelegate?

    private let mcSession: MCSession
    private let remoteMCPeerID: MCPeerID

    private var disconnecting = false
    private let lock = NSLock()

    init(mcSession: MCSession, remoteMCPeerID: MCPeerID) {
        self.mcSession = mcSession
        self.remoteMCPeerID = remoteMCPeerID
        super.init()
        mcSession.delegate = self
    }

    func send(_ data: Data) {
        try? mcSession.send(data, toPeers: [remoteMCPeerID], with: .reliable)
    }

    @discardableResult
    func sendResource(at url: URL, name: String, resourceID: String, onCompletion: @escaping SendCompletionHandler) -> Progress {
        let resourceName = "\(resourceID)\u{001C}\(name)"
        let progress = mcSession.sendResource(at: url, withName: resourceName, toPeer: remoteMCPeerID) { error in
            onCompletion(error == nil)
        }
        return progress ?? Progress(totalUnitCount: -1)
    }

    func disconnect() {
        lock.lock()
        disconnecting = true
        lock.unlock()
        mcSession.disconnect()
    }
}

// MARK: - MCSessionDelegate

extension MCTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard peerID == remoteMCPeerID, state == .notConnected else { return }
        lock.lock()
        let wasDisconnecting = disconnecting
        lock.unlock()
        transportDelegate?.transportDidDisconnect(byRequest: wasDisconnecting)
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard peerID == remoteMCPeerID else { return }
        transportDelegate?.transportDidReceive(data)
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        guard peerID == remoteMCPeerID else { return }
        transportDelegate?.transport(didStartReceivingResourceNamed: resourceName, progress: progress)
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        guard peerID == remoteMCPeerID else { return }
        transportDelegate?.transport(didFinishReceivingResourceNamed: resourceName, at: localURL, error: error)
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Streams not used.
    }
}
