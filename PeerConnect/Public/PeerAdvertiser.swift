import Foundation
import MultipeerConnectivity
import Network
import Combine

public final class PeerAdvertiser: NSObject, @unchecked Sendable {
    public weak var delegate: PeerAdvertiserDelegate?

    private let errorSubject = PassthroughSubject<PeerConnectError, Never>()
    private let connectionRequestSubject = PassthroughSubject<PeerConnectionRequest, Never>()
    private let clientConnectedSubject = PassthroughSubject<PeerSession, Never>()

    public let errorPublisher: AnyPublisher<PeerConnectError, Never>
    public let connectionRequestPublisher: AnyPublisher<PeerConnectionRequest, Never>
    public let clientConnectedPublisher: AnyPublisher<PeerSession, Never>

    private let serviceType: String
    private let localPeer: Peer
    private let localMCPeerID: MCPeerID
    private var advertiser: MCNearbyServiceAdvertiser?

    private let tcpPort: UInt16
    private var tcpListener: NWListener?
    private var cachedTLSIdentity: SecIdentity?
    private let tcpQueue = DispatchQueue(label: "com.peerconnect.tcp-advertiser")

    // One entry per in-flight invitation: holds the per-connection MCSession,
    // the decoded remote Peer, and the MC invitation handler until the app
    // delegate decides whether to allow the connection.
    private struct PendingEntry {
        let session: MCSession
        let peer: Peer
        let invitationHandler: (Bool, MCSession?) -> Void
        let coordinatorToken: PeerSessionCoordinator.AttemptToken
    }
    private var pendingConnections: [MCPeerID: PendingEntry] = [:]

    // Same idea for inbound TCP connections, awaiting allowConnectionRequest.
    private struct PendingTCPEntry {
        let connection: NWConnection
        let peer: Peer
        let coordinatorToken: PeerSessionCoordinator.AttemptToken
    }
    private var pendingTCPConnections: [ObjectIdentifier: PendingTCPEntry] = [:]

    private let lock = NSLock()

    let sessionCoordinator: PeerSessionCoordinator

    /// - Parameters:
    ///   - serviceType: A short MultipeerConnectivity service identifier — ASCII letters, numbers, and hyphens only, max 15 chars. Example: `"myappname"`. Do NOT use Bonjour format (`_xxx._tcp`).
    ///   - tcpPort: The port the TCP/TLS listener binds to when `startPublishing(alsoAvailableViaTCP: true)` is called. Callers connecting via `Peer(name:peerID:host:port:)` must use this same port. Ignored if TCP is never enabled.
    ///   - sessionCoordinator: Share one instance with this device's `PeerBrowser` to prevent parallel sessions with a peer that's also advertising and browsing (see `PeerSessionCoordinator`). Defaults to a private instance, which still refuses a redundant duplicate attempt to an already-connected peer on its own.
    public init(serviceType: String, serverPeer: Peer, tcpPort: UInt16 = 8888, sessionCoordinator: PeerSessionCoordinator? = nil, delegate: PeerAdvertiserDelegate?) {
        self.serviceType = serviceType
        self.localPeer = serverPeer
        self.localMCPeerID = MCPeerID(displayName: serverPeer.name)
        self.tcpPort = tcpPort
        self.sessionCoordinator = sessionCoordinator ?? PeerSessionCoordinator(localPeerID: serverPeer.peerID)
        self.delegate = delegate
        self.errorPublisher = errorSubject.eraseToAnyPublisher()
        self.connectionRequestPublisher = connectionRequestSubject.eraseToAnyPublisher()
        self.clientConnectedPublisher = clientConnectedSubject.eraseToAnyPublisher()
    }

    // MARK: - Public API

    @discardableResult
    public func startPublishing(alsoAvailableViaTCP: Bool = false) -> Bool {
        let discoveryInfo = ["peerID": localPeer.peerID]
        let adv = MCNearbyServiceAdvertiser(peer: localMCPeerID, discoveryInfo: discoveryInfo, serviceType: serviceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv

        if alsoAvailableViaTCP {
            startTCPListener()
        }

        return true
    }

    public func stopPublishing() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        tcpListener?.cancel()
        tcpListener = nil
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension PeerAdvertiser: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        guard let context, let remotePeer = Peer(dataValue: context) else {
            invitationHandler(false, nil)
            return
        }

        guard let coordinatorToken = sessionCoordinator.beginInbound(from: remotePeer.peerID, cancel: { invitationHandler(false, nil) }) else {
            invitationHandler(false, nil)
            delegate?.duplicateConnectionRejected(remotePeer)
            return
        }

        // Create a dedicated session for this connection so that disconnect()
        // on one PeerSession does not affect any other active sessions.
        let session = MCSession(peer: localMCPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self

        let entry = PendingEntry(session: session, peer: remotePeer, invitationHandler: invitationHandler, coordinatorToken: coordinatorToken)
        lock.lock()
        pendingConnections[peerID] = entry
        lock.unlock()

        let responder = OneShotResponder { [weak self] allow in
            guard let self else { return }

            if allow {
                invitationHandler(true, session)
                // PeerSession is created in session(_:peer:didChangeState:) once
                // MC reports .connected, after which the handshake is sent.
            } else {
                invitationHandler(false, nil)
                self.sessionCoordinator.markEnded(remotePeer.peerID, token: coordinatorToken)
                self.lock.lock()
                self.pendingConnections.removeValue(forKey: peerID)
                self.lock.unlock()
            }
        }
        delegate?.allowConnectionRequest(remotePeer, requestResponse: responder.respond)
        connectionRequestSubject.send(PeerConnectionRequest(remotePeer: remotePeer, respond: responder.respond))
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        delegate?.advertiserError(["error": error.localizedDescription])
        errorSubject.send(PeerConnectError(message: error.localizedDescription))
    }
}

// MARK: - MCSessionDelegate (pending-phase only)

extension PeerAdvertiser: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        lock.lock()
        let entry = pendingConnections[peerID]
        lock.unlock()
        guard let entry, entry.session === session else { return }

        switch state {
        case .connected:
            // MC transport is up. Send the accepted handshake and hand off to PeerSession.
            if let data = try? JSONEncoder().encode(PeerMessage.handshake(accepted: true)) {
                try? session.send(data, toPeers: [peerID], with: .reliable)
            }
            lock.lock()
            pendingConnections.removeValue(forKey: peerID)
            lock.unlock()

            sessionCoordinator.markEstablished(entry.peer.peerID, token: entry.coordinatorToken)
            let transport = MCTransport(mcSession: session, remoteMCPeerID: peerID)
            let peerSession = PeerSession(transport: transport, remotePeer: entry.peer, onEnded: { [weak self] in
                self?.sessionCoordinator.markEnded(entry.peer.peerID, token: entry.coordinatorToken)
            })
            delegate?.clientDidConnect(peerSession)
            clientConnectedSubject.send(peerSession)

        case .notConnected:
            lock.lock()
            pendingConnections.removeValue(forKey: peerID)
            lock.unlock()
            sessionCoordinator.markEnded(entry.peer.peerID, token: entry.coordinatorToken)

        default:
            break
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - TCP/TLS listening

extension PeerAdvertiser {
    private func tlsIdentity() throws -> SecIdentity {
        if let cachedTLSIdentity { return cachedTLSIdentity }
        let identity = try PeerTLSIdentity.makeEphemeralIdentity(commonName: localPeer.name)
        cachedTLSIdentity = identity
        return identity
    }

    private func startTCPListener() {
        guard let port = NWEndpoint.Port(rawValue: tcpPort) else {
            let message = "Invalid tcpPort \(tcpPort)"
            delegate?.advertiserError(["error": message])
            errorSubject.send(PeerConnectError(message: message))
            return
        }

        do {
            let identity = try tlsIdentity()
            let parameters = PeerTLSIdentity.serverParameters(identity: identity)
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewTCPConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.delegate?.advertiserError(["error": error.localizedDescription])
                    self?.errorSubject.send(PeerConnectError(message: error.localizedDescription))
                }
            }
            listener.start(queue: tcpQueue)
            tcpListener = listener
        } catch {
            delegate?.advertiserError(["error": error.localizedDescription])
            errorSubject.send(PeerConnectError(message: error.localizedDescription))
        }
    }

    private func handleNewTCPConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state {
                self.removePendingTCPConnection(connection)
            }
        }
        connection.start(queue: tcpQueue)
        awaitTCPContext(on: connection)
    }

    private func removePendingTCPConnection(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        lock.lock()
        let entry = pendingTCPConnections.removeValue(forKey: key)
        lock.unlock()
        if let entry {
            sessionCoordinator.markEnded(entry.peer.peerID, token: entry.coordinatorToken)
        }
    }

    // Mirrors MC's invitation `context`: the first frame on a fresh TCP
    // connection is the connecting peer's raw Peer.dataValue() bytes, not a
    // PeerMessage. Once decoded, the flow rejoins the same
    // allowConnectionRequest/handshake shape used by the MC path.
    private func awaitTCPContext(on connection: NWConnection) {
        TCPFraming.receiveFrame(on: connection) { [weak self] data, error in
            guard let self else { return }
            guard let data, error == nil, let remotePeer = Peer(dataValue: data) else {
                connection.cancel()
                return
            }

            guard let coordinatorToken = self.sessionCoordinator.beginInbound(from: remotePeer.peerID, cancel: { connection.cancel() }) else {
                connection.cancel()
                self.delegate?.duplicateConnectionRejected(remotePeer)
                return
            }

            let key = ObjectIdentifier(connection)
            self.lock.lock()
            self.pendingTCPConnections[key] = PendingTCPEntry(connection: connection, peer: remotePeer, coordinatorToken: coordinatorToken)
            self.lock.unlock()

            let responder = OneShotResponder { [weak self] allow in
                guard let self else { return }

                self.lock.lock()
                let entry = self.pendingTCPConnections.removeValue(forKey: key)
                self.lock.unlock()
                guard let entry else { return }

                guard let handshakeData = try? JSONEncoder().encode(PeerMessage.handshake(accepted: allow)) else {
                    connection.cancel()
                    self.sessionCoordinator.markEnded(entry.peer.peerID, token: entry.coordinatorToken)
                    return
                }

                TCPFraming.sendFrame(handshakeData, on: connection) { sendError in
                    guard sendError == nil, allow else {
                        connection.cancel()
                        self.sessionCoordinator.markEnded(entry.peer.peerID, token: entry.coordinatorToken)
                        return
                    }
                    self.sessionCoordinator.markEstablished(entry.peer.peerID, token: entry.coordinatorToken)
                    let transport = TCPTransport(connection: connection, queue: self.tcpQueue)
                    let coordinator = self.sessionCoordinator
                    let peerSession = PeerSession(transport: transport, remotePeer: entry.peer, onEnded: { [weak coordinator] in
                        coordinator?.markEnded(entry.peer.peerID, token: entry.coordinatorToken)
                    })
                    self.delegate?.clientDidConnect(peerSession)
                    self.clientConnectedSubject.send(peerSession)
                }
            }
            self.delegate?.allowConnectionRequest(remotePeer, requestResponse: responder.respond)
            self.connectionRequestSubject.send(PeerConnectionRequest(remotePeer: remotePeer, respond: responder.respond))
        }
    }
}

private final class OneShotResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false
    private let handler: (Bool) -> Void

    init(handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    func respond(_ allow: Bool) {
        lock.lock()
        guard !answered else {
            lock.unlock()
            return
        }
        answered = true
        lock.unlock()
        handler(allow)
    }
}
