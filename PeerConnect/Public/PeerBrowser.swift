import Foundation
import MultipeerConnectivity
import Network
import Combine

public final class PeerBrowser: NSObject, ObservableObject, @unchecked Sendable {
    public weak var delegate: PeerBrowserDelegate?
    @Published public private(set) var nearbyServers: [Peer] = []

    private let errorSubject = PassthroughSubject<PeerConnectError, Never>()
    private let serverFoundSubject = PassthroughSubject<Peer, Never>()
    private let serverLostSubject = PassthroughSubject<Peer, Never>()
    private let unableToConnectSubject = PassthroughSubject<Peer, Never>()
    private let connectionDeniedSubject = PassthroughSubject<Peer, Never>()
    private let connectedSubject = PassthroughSubject<PeerSession, Never>()
    private let duplicateConnectionRejectedSubject = PassthroughSubject<Peer, Never>()

    public let errorPublisher: AnyPublisher<PeerConnectError, Never>
    public let serverFoundPublisher: AnyPublisher<Peer, Never>
    public let serverLostPublisher: AnyPublisher<Peer, Never>
    public let unableToConnectPublisher: AnyPublisher<Peer, Never>
    public let connectionDeniedPublisher: AnyPublisher<Peer, Never>
    public let connectedPublisher: AnyPublisher<PeerSession, Never>
    public let duplicateConnectionRejectedPublisher: AnyPublisher<Peer, Never>

    private let serviceType: String
    private let localPeer: Peer
    private let localMCPeerID: MCPeerID
    private var browser: MCNearbyServiceBrowser?

    private let tcpQueue = DispatchQueue(label: "com.peerconnect.tcp-browser")

    // Keyed by the remote MCPeerID; holds the session and the Peer model while
    // the MC connection is being established and the handshake is in flight.
    private struct PendingEntry {
        let session: MCSession
        let peer: Peer
        let coordinatorToken: PeerSessionCoordinator.AttemptToken
    }
    private var pendingConnections: [MCPeerID: PendingEntry] = [:]

    // Same idea for outbound TCP connections, keyed by the connection identity.
    private struct PendingTCPEntry {
        let peer: Peer
        let coordinatorToken: PeerSessionCoordinator.AttemptToken
    }
    private var pendingTCPConnections: [ObjectIdentifier: PendingTCPEntry] = [:]

    private let lock = NSLock()

    let sessionCoordinator: PeerSessionCoordinator

    /// - Parameters:
    ///   - serviceType: A short MultipeerConnectivity service identifier — ASCII letters, numbers, and hyphens only, max 15 chars. Example: `"myappname"`. Do NOT use Bonjour format (`_xxx._tcp`).
    ///   - sessionCoordinator: Share one instance with this device's `PeerAdvertiser` to prevent parallel sessions with a peer that's also advertising and browsing (see `PeerSessionCoordinator`). Defaults to a private instance, which still refuses a redundant duplicate attempt to an already-connected peer on its own.
    public init(serviceType: String, clientPeer: Peer, sessionCoordinator: PeerSessionCoordinator? = nil, delegate: PeerBrowserDelegate?) {
        self.serviceType = serviceType
        self.localPeer = clientPeer
        self.localMCPeerID = MCPeerID(displayName: clientPeer.name)
        self.sessionCoordinator = sessionCoordinator ?? PeerSessionCoordinator(localPeerID: clientPeer.peerID)
        self.delegate = delegate
        self.errorPublisher = errorSubject.eraseToAnyPublisher()
        self.serverFoundPublisher = serverFoundSubject.eraseToAnyPublisher()
        self.serverLostPublisher = serverLostSubject.eraseToAnyPublisher()
        self.unableToConnectPublisher = unableToConnectSubject.eraseToAnyPublisher()
        self.connectionDeniedPublisher = connectionDeniedSubject.eraseToAnyPublisher()
        self.connectedPublisher = connectedSubject.eraseToAnyPublisher()
        self.duplicateConnectionRejectedPublisher = duplicateConnectionRejectedSubject.eraseToAnyPublisher()
    }

    // MARK: - Public API

    public func startBrowsing() {
        let b = MCNearbyServiceBrowser(peer: localMCPeerID, serviceType: serviceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
    }

    public func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser = nil
    }

    /// Initiate a connection to a peer previously surfaced via `serverFound`,
    /// or one constructed directly via `Peer(name:peerID:host:port:)` to
    /// target a TCP/TLS connection instead.
    public func connectToServer(_ server: Peer) {
        if let remoteMCPeerID = server.mcPeerID, let browser {
            let session = MCSession(peer: localMCPeerID, securityIdentity: nil, encryptionPreference: .required)
            session.delegate = self

            guard let coordinatorToken = sessionCoordinator.beginOutbound(to: server.peerID, cancel: { session.disconnect() }) else {
                delegate?.duplicateConnectionRejected(server)
                duplicateConnectionRejectedSubject.send(server)
                return
            }

            lock.lock()
            pendingConnections[remoteMCPeerID] = PendingEntry(session: session, peer: server, coordinatorToken: coordinatorToken)
            lock.unlock()

            browser.invitePeer(remoteMCPeerID, to: session, withContext: localPeer.dataValue(), timeout: 30)
            return
        }

        if let tcpEndpoint = server.tcpEndpoint {
            connectViaTCP(server, host: tcpEndpoint.host, port: tcpEndpoint.port)
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension PeerBrowser: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let remotePeerID = info?["peerID"] else { return }

        lock.lock()
        let alreadyKnown = nearbyServers.contains(where: { $0.peerID == remotePeerID })
        lock.unlock()
        guard !alreadyKnown else { return }

        let peer = Peer(name: peerID.displayName, peerID: remotePeerID)
        peer.mcPeerID = peerID

        lock.lock()
        nearbyServers.append(peer)
        lock.unlock()

        delegate?.serverFound(peer)
        serverFoundSubject.send(peer)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        lock.lock()
        let lost = nearbyServers.first(where: { $0.mcPeerID == peerID })
        if lost != nil {
            nearbyServers.removeAll(where: { $0.mcPeerID == peerID })
        }
        lock.unlock()
        if let lost {
            delegate?.serverLost(lost)
            serverLostSubject.send(lost)
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        delegate?.browserError(["error": error.localizedDescription])
        errorSubject.send(PeerConnectError(message: error.localizedDescription))
    }
}

// MARK: - MCSessionDelegate (pending-phase only)

extension PeerBrowser: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard state == .notConnected else { return }
        lock.lock()
        let entry = pendingConnections.removeValue(forKey: peerID)
        lock.unlock()
        guard let entry else { return }
        sessionCoordinator.markEnded(entry.peer.peerID, token: entry.coordinatorToken)
        delegate?.unableToConnect(entry.peer)
        unableToConnectSubject.send(entry.peer)
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        lock.lock()
        let entry = pendingConnections[peerID]
        lock.unlock()
        guard let entry, entry.session === session else { return }

        guard let message = try? JSONDecoder().decode(PeerMessage.self, from: data),
              case .handshake(let accepted) = message
        else { return }

        lock.lock()
        pendingConnections.removeValue(forKey: peerID)
        lock.unlock()

        if accepted {
            sessionCoordinator.markEstablished(entry.peer.peerID, token: entry.coordinatorToken)
            let transport = MCTransport(mcSession: session, remoteMCPeerID: peerID)
            let peerSession = PeerSession(transport: transport, remotePeer: entry.peer, onEnded: { [weak self] in
                self?.sessionCoordinator.markEnded(entry.peer.peerID, token: entry.coordinatorToken)
            })
            delegate?.connected(peerSession)
            connectedSubject.send(peerSession)
        } else {
            session.disconnect()
            sessionCoordinator.markEnded(entry.peer.peerID, token: entry.coordinatorToken)
            delegate?.connectionDenied(entry.peer)
            connectionDeniedSubject.send(entry.peer)
        }
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - TCP/TLS connecting

extension PeerBrowser {
    private func connectViaTCP(_ server: Peer, host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            delegate?.unableToConnect(server)
            unableToConnectSubject.send(server)
            return
        }

        let parameters = PeerTLSIdentity.clientParameters()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)

        guard let coordinatorToken = sessionCoordinator.beginOutbound(to: server.peerID, cancel: { connection.cancel() }) else {
            delegate?.duplicateConnectionRejected(server)
            duplicateConnectionRejectedSubject.send(server)
            return
        }

        let key = ObjectIdentifier(connection)

        lock.lock()
        pendingTCPConnections[key] = PendingTCPEntry(peer: server, coordinatorToken: coordinatorToken)
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendTCPContext(on: connection, server: server, key: key)
            case .failed, .waiting:
                // .waiting covers cases like connection-refused, which Network
                // framework treats as potentially transient; PeerConnect doesn't
                // retry connection attempts anywhere else (MC's invite is also
                // one-shot), so treat it as a failed attempt here too.
                self.lock.lock()
                let entry = self.pendingTCPConnections.removeValue(forKey: key)
                self.lock.unlock()
                if let entry {
                    connection.cancel()
                    self.sessionCoordinator.markEnded(server.peerID, token: entry.coordinatorToken)
                    self.delegate?.unableToConnect(server)
                    self.unableToConnectSubject.send(server)
                }
            case .cancelled:
                self.lock.lock()
                let entry = self.pendingTCPConnections.removeValue(forKey: key)
                self.lock.unlock()
                if let entry {
                    self.sessionCoordinator.markEnded(server.peerID, token: entry.coordinatorToken)
                    self.delegate?.unableToConnect(server)
                    self.unableToConnectSubject.send(server)
                }
            default:
                break
            }
        }
        connection.start(queue: tcpQueue)
    }

    // Mirrors MC's invitePeer(_:to:withContext:): the first frame sent on a
    // fresh TCP connection is the local peer's raw Peer.dataValue() bytes.
    private func sendTCPContext(on connection: NWConnection, server: Peer, key: ObjectIdentifier) {
        TCPFraming.sendFrame(localPeer.dataValue(), on: connection) { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                connection.cancel()
                return
            }
            self.awaitTCPHandshake(on: connection, server: server, key: key)
        }
    }

    private func awaitTCPHandshake(on connection: NWConnection, server: Peer, key: ObjectIdentifier) {
        TCPFraming.receiveFrame(on: connection) { [weak self] data, error in
            guard let self else { return }

            self.lock.lock()
            let entry = self.pendingTCPConnections.removeValue(forKey: key)
            self.lock.unlock()
            guard let entry else { return }

            guard let data, error == nil,
                  let message = try? JSONDecoder().decode(PeerMessage.self, from: data),
                  case .handshake(let accepted) = message
            else {
                connection.cancel()
                self.sessionCoordinator.markEnded(server.peerID, token: entry.coordinatorToken)
                self.delegate?.unableToConnect(server)
                self.unableToConnectSubject.send(server)
                return
            }

            if accepted {
                self.sessionCoordinator.markEstablished(server.peerID, token: entry.coordinatorToken)
                let transport = TCPTransport(connection: connection, queue: self.tcpQueue)
                let peerSession = PeerSession(transport: transport, remotePeer: server, onEnded: { [weak self] in
                    self?.sessionCoordinator.markEnded(server.peerID, token: entry.coordinatorToken)
                })
                self.delegate?.connected(peerSession)
                self.connectedSubject.send(peerSession)
            } else {
                connection.cancel()
                self.sessionCoordinator.markEnded(server.peerID, token: entry.coordinatorToken)
                self.delegate?.connectionDenied(server)
                self.connectionDeniedSubject.send(server)
            }
        }
    }
}
