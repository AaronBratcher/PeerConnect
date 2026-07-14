import XCTest
@testable import PeerConnect

final class PeerBrowserTests: XCTestCase {

    func testInitialNearbyServersIsEmpty() {
        let localPeer = Peer(name: "Client", peerID: UUID().uuidString)
        let browser = PeerBrowser(serviceType: "pctest", clientPeer: localPeer, delegate: nil)
        XCTAssertTrue(browser.nearbyServers.isEmpty)
    }

    func testDelegateCanBeAssignedAndIsWeak() {
        let localPeer = Peer(name: "Client", peerID: UUID().uuidString)
        let browser = PeerBrowser(serviceType: "pctest", clientPeer: localPeer, delegate: nil)
        var spy: SpyBrowserDelegate? = SpyBrowserDelegate()
        browser.delegate = spy
        XCTAssertNotNil(browser.delegate)
        spy = nil
        XCTAssertNil(browser.delegate)
    }

    func testStartAndStopBrowsingDoNotCrash() {
        let localPeer = Peer(name: "Client", peerID: UUID().uuidString)
        let browser = PeerBrowser(serviceType: "pctest", clientPeer: localPeer, delegate: nil)
        browser.startBrowsing()
        browser.stopBrowsing()
    }

    func testStopBrowsingWithoutStartDoesNotCrash() {
        let localPeer = Peer(name: "Client", peerID: UUID().uuidString)
        let browser = PeerBrowser(serviceType: "pctest", clientPeer: localPeer, delegate: nil)
        browser.stopBrowsing()
    }

    func testConnectToServerWithoutMCPeerIDDoesNotCrash() {
        // Peer has no mcPeerID set (not discovered via browser) — should be a no-op.
        let localPeer = Peer(name: "Client", peerID: UUID().uuidString)
        let browser = PeerBrowser(serviceType: "pctest", clientPeer: localPeer, delegate: nil)
        browser.startBrowsing()
        let server = Peer(name: "Server", peerID: UUID().uuidString)  // no mcPeerID
        browser.connectToServer(server)
        browser.stopBrowsing()
    }

    func testConnectToServerWithTCPEndpointAttemptsConnection() {
        // Points at a closed local port — should fail asynchronously via
        // unableToConnect rather than crash or hang synchronously.
        let localPeer = Peer(name: "Client", peerID: UUID().uuidString)
        let browser = PeerBrowser(serviceType: "pctest", clientPeer: localPeer, delegate: SpyBrowserDelegate())
        let server = Peer(name: "Server", peerID: UUID().uuidString, host: "127.0.0.1", port: 1)
        browser.connectToServer(server)
    }
}

// MARK: - Spy

private final class SpyBrowserDelegate: PeerBrowserDelegate {
    var foundPeers: [Peer] = []
    var lostPeers: [Peer] = []
    var errors: [[String: Any]] = []

    func browserError(_ errorDict: [String: Any]) { errors.append(errorDict) }
    func serverFound(_ server: Peer) { foundPeers.append(server) }
    func serverLost(_ server: Peer) { lostPeers.append(server) }
    func unableToConnect(_ server: Peer) {}
    func connectionDenied(_ server: Peer) {}
    func connected(_ session: PeerSession) {}
}
