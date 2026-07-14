import XCTest
@testable import PeerConnect

final class PeerTests: XCTestCase {

    func testEncodeDecodeRoundTrip() {
        let peer = Peer(name: "TestDevice", peerID: "550e8400-e29b-41d4-a716-446655440000")
        let data = peer.dataValue()
        let decoded = Peer(dataValue: data)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.name, "TestDevice")
        XCTAssertEqual(decoded?.peerID, "550e8400-e29b-41d4-a716-446655440000")
    }

    func testInvalidDataReturnsNil() {
        XCTAssertNil(Peer(dataValue: Data()))
        XCTAssertNil(Peer(dataValue: "not json".data(using: .utf8)!))
        // JSON but missing required keys
        let partial = try! JSONEncoder().encode(["name": "Only Name"])
        XCTAssertNil(Peer(dataValue: partial))
    }

    func testEqualityUsesPeerID() {
        let a = Peer(name: "Device A", peerID: "same-id")
        let b = Peer(name: "Device B", peerID: "same-id")   // same ID, different name
        let c = Peer(name: "Device A", peerID: "other-id")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testHashConsistentWithEquality() {
        let a = Peer(name: "Device A", peerID: "same-id")
        let b = Peer(name: "Device B", peerID: "same-id")
        XCTAssertEqual(a.hashValue, b.hashValue)

        var set = Set<Peer>()
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 1)
    }

    func testHostPortInitializerSetsTCPEndpoint() {
        let peer = Peer(name: "TCPServer", peerID: "tcp-uuid", host: "192.168.1.10", port: 8888)
        XCTAssertEqual(peer.name, "TCPServer")
        XCTAssertEqual(peer.peerID, "tcp-uuid")
        XCTAssertEqual(peer.tcpEndpoint?.host, "192.168.1.10")
        XCTAssertEqual(peer.tcpEndpoint?.port, 8888)
        XCTAssertNil(peer.mcPeerID)
    }

    func testDefaultInitializerHasNoTCPEndpoint() {
        let peer = Peer(name: "TestDevice", peerID: UUID().uuidString)
        XCTAssertNil(peer.tcpEndpoint)
    }

    func testDataValueContainsNameAndPeerID() throws {
        let peer = Peer(name: "MyDevice", peerID: "abc-123")
        let data = peer.dataValue()
        let dict = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(dict["name"], "MyDevice")
        XCTAssertEqual(dict["peerID"], "abc-123")
    }
}
