import XCTest
@testable import PeerConnect

final class PeerAdvertiserTests: XCTestCase {

    func testDelegateCanBeAssignedAndIsWeak() {
        let localPeer = Peer(name: "Server", peerID: UUID().uuidString)
        let advertiser = PeerAdvertiser(serviceType: "pctest", serverPeer: localPeer, delegate: nil)
        var spy: SpyAdvertiserDelegate? = SpyAdvertiserDelegate()
        advertiser.delegate = spy
        XCTAssertNotNil(advertiser.delegate)
        spy = nil
        XCTAssertNil(advertiser.delegate)
    }

    func testStartPublishingReturnsTrue() {
        let localPeer = Peer(name: "Server", peerID: UUID().uuidString)
        let advertiser = PeerAdvertiser(serviceType: "pctest", serverPeer: localPeer, delegate: nil)
        let result = advertiser.startPublishing()
        XCTAssertTrue(result)
        advertiser.stopPublishing()
    }

    func testStopPublishingWithoutStartDoesNotCrash() {
        let localPeer = Peer(name: "Server", peerID: UUID().uuidString)
        let advertiser = PeerAdvertiser(serviceType: "pctest", serverPeer: localPeer, delegate: nil)
        advertiser.stopPublishing()
    }

    func testStartAndStopCycleDoesNotCrash() {
        let localPeer = Peer(name: "Server", peerID: UUID().uuidString)
        let advertiser = PeerAdvertiser(serviceType: "pctest", serverPeer: localPeer, delegate: nil)
        advertiser.startPublishing()
        advertiser.stopPublishing()
        advertiser.startPublishing()
        advertiser.stopPublishing()
    }

    // MARK: - TCP/TLS listener

    func testStartPublishingWithTCPReturnsTrue() {
        let localPeer = Peer(name: "Server", peerID: UUID().uuidString)
        let advertiser = PeerAdvertiser(serviceType: "pctest", serverPeer: localPeer, tcpPort: 18881, delegate: nil)
        let result = advertiser.startPublishing(alsoAvailableViaTCP: true)
        XCTAssertTrue(result)
        advertiser.stopPublishing()
    }

    func testStartAndStopTCPCycleDoesNotCrash() {
        let localPeer = Peer(name: "Server", peerID: UUID().uuidString)
        let advertiser = PeerAdvertiser(serviceType: "pctest", serverPeer: localPeer, tcpPort: 18882, delegate: nil)
        advertiser.startPublishing(alsoAvailableViaTCP: true)
        advertiser.stopPublishing()
        advertiser.startPublishing(alsoAvailableViaTCP: true)
        advertiser.stopPublishing()
    }
}

// MARK: - Spy

private final class SpyAdvertiserDelegate: PeerAdvertiserDelegate {
    var errors: [[String: Any]] = []
    var connectionRequests: [Peer] = []
    var connectedSessions: [PeerSession] = []

    func advertiserError(_ errorDict: [String: Any]) { errors.append(errorDict) }
    func allowConnectionRequest(_ remotePeer: Peer, requestResponse: @escaping ConnectionRequestResponse) {
        connectionRequests.append(remotePeer)
        requestResponse(true)
    }
    func clientDidConnect(_ session: PeerSession) { connectedSessions.append(session) }
}
