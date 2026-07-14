import XCTest
import Combine
@testable import PeerConnect

final class PeerBrowserTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    func testInitialNearbyServersIsEmpty() {
        let localPeer = Peer(name: "Client", peerID: UUID().uuidString)
        let browser = PeerBrowser(serviceType: "pctest", clientPeer: localPeer, delegate: nil)
        XCTAssertTrue(browser.nearbyServers.isEmpty)
    }

    // MARK: - Combine

    func testNearbyServersPublishesInitialEmptyValue() {
        // foundPeer/lostPeer are MC-framework-driven and aren't unit-tested elsewhere
        // in this suite either; this confirms $nearbyServers is wired up and usable
        // as a Combine publisher (e.g. for SwiftUI binding), not the discovery flow itself.
        let localPeer = Peer(name: "Client", peerID: UUID().uuidString)
        let browser = PeerBrowser(serviceType: "pctest", clientPeer: localPeer, delegate: nil)

        let expectation = expectation(description: "initial value published")
        var received: [Peer]?
        browser.$nearbyServers.sink { servers in
            received = servers
            expectation.fulfill()
        }.store(in: &cancellables)

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(received, [])
    }

    func testConnectToServerWithTCPEndpointFiresUnableToConnectPublisherOnClosedPort() {
        let localPeer = Peer(name: "Client", peerID: UUID().uuidString)
        let browser = PeerBrowser(serviceType: "pctest", clientPeer: localPeer, delegate: SpyBrowserDelegate())
        let server = Peer(name: "Server", peerID: UUID().uuidString, host: "127.0.0.1", port: 1)

        let expectation = expectation(description: "unableToConnectPublisher fired")
        var publishedPeer: Peer?
        browser.unableToConnectPublisher.sink { peer in
            publishedPeer = peer
            expectation.fulfill()
        }.store(in: &cancellables)

        browser.connectToServer(server)

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(publishedPeer?.peerID, server.peerID)
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
