import XCTest
@testable import PeerConnect

// End-to-end loopback (127.0.0.1) tests of the full TCP/TLS path: PeerAdvertiser
// listening, PeerBrowser dialing a Peer(host:port:), the handshake, and
// PeerSession's public sendText/sendData/sendResourceAtURL/disconnect API —
// exercised over the new transport exactly as a consuming app would use it.
final class PeerAdvertiserBrowserTCPTests: XCTestCase {

    private func waitForListenerToBind() {
        let ready = expectation(description: "listener bound")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { ready.fulfill() }
        wait(for: [ready], timeout: 2)
    }

    func testFullConnectSendAndDisconnectOverTCP() throws {
        try TLSTestAvailability.requireKeychainAccess()

        let tcpPort: UInt16 = 18900
        let serverPeer = Peer(name: "Server", peerID: UUID().uuidString)
        let advertiserDelegate = RecordingAdvertiserDelegate()
        let advertiser = PeerAdvertiser(serviceType: "pctesttcp", serverPeer: serverPeer, tcpPort: tcpPort, delegate: advertiserDelegate)
        advertiser.startPublishing(alsoAvailableViaTCP: true)
        defer { advertiser.stopPublishing() }
        waitForListenerToBind()

        let clientPeer = Peer(name: "Client", peerID: UUID().uuidString)
        let browserDelegate = RecordingBrowserDelegate()
        let browser = PeerBrowser(serviceType: "pctesttcp", clientPeer: clientPeer, delegate: browserDelegate)
        let targetPeer = Peer(name: "Server", peerID: serverPeer.peerID, host: "127.0.0.1", port: tcpPort)

        let connected = expectation(description: "client connected")
        browserDelegate.onConnected = { connected.fulfill() }
        let clientDidConnect = expectation(description: "server accepted client")
        advertiserDelegate.onClientDidConnect = { clientDidConnect.fulfill() }

        browser.connectToServer(targetPeer)
        wait(for: [connected, clientDidConnect], timeout: 5)

        guard let clientSession = browserDelegate.session, let serverSession = advertiserDelegate.session else {
            return XCTFail("Expected sessions on both sides")
        }
        XCTAssertEqual(serverSession.remotePeer.peerID, clientPeer.peerID)
        XCTAssertEqual(clientSession.remotePeer.peerID, serverPeer.peerID)

        let serverSessionDelegate = RecordingSessionDelegate()
        serverSession.delegate = serverSessionDelegate
        let clientSessionDelegate = RecordingSessionDelegate()
        clientSession.delegate = clientSessionDelegate

        // Text: client -> server
        let serverGotText = expectation(description: "server got text")
        serverSessionDelegate.onText = { serverGotText.fulfill() }
        clientSession.sendText("hello server")
        wait(for: [serverGotText], timeout: 5)
        XCTAssertEqual(serverSessionDelegate.lastText, "hello server")

        // Data: server -> client
        let clientGotData = expectation(description: "client got data")
        clientSessionDelegate.onData = { clientGotData.fulfill() }
        let payload = Data([1, 2, 3, 4])
        serverSession.sendData(payload)
        wait(for: [clientGotData], timeout: 5)
        XCTAssertEqual(clientSessionDelegate.lastData, payload)

        // Resource: client -> server
        let sourceContent = "integration test resource content"
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try sourceContent.write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let serverGotResource = expectation(description: "server got resource")
        serverSessionDelegate.onResourceReceived = { serverGotResource.fulfill() }
        let sendCompleted = expectation(description: "resource send completed")
        clientSession.sendResourceAtURL(sourceURL, name: "note.txt", resourceID: "int-res-1") { sent in
            XCTAssertTrue(sent)
            sendCompleted.fulfill()
        }
        wait(for: [serverGotResource, sendCompleted], timeout: 5)
        guard let resourceURL = serverSessionDelegate.lastResourceURL else {
            return XCTFail("Expected a resource URL")
        }
        defer { try? FileManager.default.removeItem(at: resourceURL) }
        XCTAssertEqual(try String(contentsOf: resourceURL, encoding: .utf8), sourceContent)

        // Disconnect
        let clientDisconnected = expectation(description: "client disconnected")
        clientSessionDelegate.onDisconnected = { clientDisconnected.fulfill() }
        clientSession.disconnect()
        wait(for: [clientDisconnected], timeout: 5)
    }

    func testConnectionDeniedOverTCP() throws {
        try TLSTestAvailability.requireKeychainAccess()

        let tcpPort: UInt16 = 18901
        let serverPeer = Peer(name: "Server", peerID: UUID().uuidString)
        let advertiserDelegate = RecordingAdvertiserDelegate()
        advertiserDelegate.allow = false
        let advertiser = PeerAdvertiser(serviceType: "pctesttcp2", serverPeer: serverPeer, tcpPort: tcpPort, delegate: advertiserDelegate)
        advertiser.startPublishing(alsoAvailableViaTCP: true)
        defer { advertiser.stopPublishing() }
        waitForListenerToBind()

        let clientPeer = Peer(name: "Client", peerID: UUID().uuidString)
        let browserDelegate = RecordingBrowserDelegate()
        let browser = PeerBrowser(serviceType: "pctesttcp2", clientPeer: clientPeer, delegate: browserDelegate)
        let targetPeer = Peer(name: "Server", peerID: serverPeer.peerID, host: "127.0.0.1", port: tcpPort)

        let denied = expectation(description: "connection denied")
        browserDelegate.onDenied = { denied.fulfill() }
        browser.connectToServer(targetPeer)
        wait(for: [denied], timeout: 5)
    }

    func testUnableToConnectToClosedPort() {
        let clientPeer = Peer(name: "Client", peerID: UUID().uuidString)
        let browserDelegate = RecordingBrowserDelegate()
        let browser = PeerBrowser(serviceType: "pctesttcp3", clientPeer: clientPeer, delegate: browserDelegate)
        let targetPeer = Peer(name: "Nobody", peerID: UUID().uuidString, host: "127.0.0.1", port: 1)

        let unableToConnect = expectation(description: "unable to connect")
        browserDelegate.onUnableToConnect = { unableToConnect.fulfill() }
        browser.connectToServer(targetPeer)
        wait(for: [unableToConnect], timeout: 5)
    }

    func testSecondConnectToServerIsRejectedOnceAlreadyEstablished() throws {
        try TLSTestAvailability.requireKeychainAccess()

        let tcpPort: UInt16 = 18902
        let serverPeer = Peer(name: "Server", peerID: UUID().uuidString)
        let advertiserDelegate = RecordingAdvertiserDelegate()
        let advertiser = PeerAdvertiser(serviceType: "pctesttcp4", serverPeer: serverPeer, tcpPort: tcpPort, delegate: advertiserDelegate)
        advertiser.startPublishing(alsoAvailableViaTCP: true)
        defer { advertiser.stopPublishing() }
        waitForListenerToBind()

        let clientPeer = Peer(name: "Client", peerID: UUID().uuidString)
        let browserDelegate = RecordingBrowserDelegate()
        let browser = PeerBrowser(serviceType: "pctesttcp4", clientPeer: clientPeer, delegate: browserDelegate)
        let targetPeer = Peer(name: "Server", peerID: serverPeer.peerID, host: "127.0.0.1", port: tcpPort)

        let connected = expectation(description: "client connected")
        browserDelegate.onConnected = { connected.fulfill() }
        browser.connectToServer(targetPeer)
        wait(for: [connected], timeout: 5)

        // Same PeerBrowser instance, same coordinator: a second attempt at an
        // already-established peer should be refused rather than opening a
        // redundant parallel session.
        let duplicateRejected = expectation(description: "duplicate rejected")
        browserDelegate.onDuplicateRejected = { duplicateRejected.fulfill() }
        browser.connectToServer(targetPeer)
        wait(for: [duplicateRejected], timeout: 5)
    }
}

// MARK: - Recording delegates

private final class RecordingAdvertiserDelegate: PeerAdvertiserDelegate {
    var allow = true
    var session: PeerSession?
    var onClientDidConnect: (() -> Void)?

    func advertiserError(_ errorDict: [String: Any]) {}
    func allowConnectionRequest(_ remotePeer: Peer, requestResponse: @escaping ConnectionRequestResponse) {
        requestResponse(allow)
    }
    func clientDidConnect(_ session: PeerSession) {
        self.session = session
        onClientDidConnect?()
    }
}

private final class RecordingBrowserDelegate: PeerBrowserDelegate {
    var session: PeerSession?
    var onConnected: (() -> Void)?
    var onDenied: (() -> Void)?
    var onUnableToConnect: (() -> Void)?
    var onDuplicateRejected: (() -> Void)?

    func browserError(_ errorDict: [String: Any]) {}
    func serverFound(_ server: Peer) {}
    func serverLost(_ server: Peer) {}
    func unableToConnect(_ server: Peer) { onUnableToConnect?() }
    func connectionDenied(_ server: Peer) { onDenied?() }
    func connected(_ session: PeerSession) {
        self.session = session
        onConnected?()
    }
    func duplicateConnectionRejected(_ server: Peer) { onDuplicateRejected?() }
}

private final class RecordingSessionDelegate: PeerSessionDelegate {
    var lastText: String?
    var lastData: Data?
    var lastResourceURL: URL?

    var onText: (() -> Void)?
    var onData: (() -> Void)?
    var onResourceReceived: (() -> Void)?
    var onDisconnected: (() -> Void)?

    func disconnected(_ session: PeerSession, byRequest: Bool) { onDisconnected?() }
    func textReceived(_ session: PeerSession, text: String) {
        lastText = text
        onText?()
    }
    func dataReceived(_ session: PeerSession, data: Data) {
        lastData = data
        onData?()
    }
    func startedReceivingResource(_ session: PeerSession, atURL: URL, name: String, resourceID: String, progress: Progress) {}
    func resourceReceived(_ session: PeerSession, atURL: URL, name: String, resourceID: String) {
        lastResourceURL = atURL
        onResourceReceived?()
    }
}
