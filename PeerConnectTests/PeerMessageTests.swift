import XCTest
@testable import PeerConnect

final class PeerMessageTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Text

    func testTextRoundTrip() throws {
        let original = PeerMessage.text("Hello, World!")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PeerMessage.self, from: data)
        guard case .text(let s) = decoded else { return XCTFail("wrong type") }
        XCTAssertEqual(s, "Hello, World!")
    }

    func testTextWithUnicode() throws {
        let original = PeerMessage.text("日本語 🎉")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PeerMessage.self, from: data)
        guard case .text(let s) = decoded else { return XCTFail("wrong type") }
        XCTAssertEqual(s, "日本語 🎉")
    }

    func testEmptyTextRoundTrip() throws {
        let original = PeerMessage.text("")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PeerMessage.self, from: data)
        guard case .text(let s) = decoded else { return XCTFail("wrong type") }
        XCTAssertEqual(s, "")
    }

    // MARK: - Data

    func testDataRoundTrip() throws {
        let payload = Data([0x00, 0xFF, 0x7F, 0x80])
        let original = PeerMessage.data(payload)
        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(PeerMessage.self, from: encoded)
        guard case .data(let d) = decoded else { return XCTFail("wrong type") }
        XCTAssertEqual(d, payload)
    }

    func testEmptyDataRoundTrip() throws {
        let original = PeerMessage.data(Data())
        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(PeerMessage.self, from: encoded)
        guard case .data(let d) = decoded else { return XCTFail("wrong type") }
        XCTAssertTrue(d.isEmpty)
    }

    // MARK: - Handshake

    func testHandshakeAcceptedRoundTrip() throws {
        let original = PeerMessage.handshake(accepted: true)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PeerMessage.self, from: data)
        guard case .handshake(let accepted) = decoded else { return XCTFail("wrong type") }
        XCTAssertTrue(accepted)
    }

    func testHandshakeDeniedRoundTrip() throws {
        let original = PeerMessage.handshake(accepted: false)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PeerMessage.self, from: data)
        guard case .handshake(let accepted) = decoded else { return XCTFail("wrong type") }
        XCTAssertFalse(accepted)
    }

    // MARK: - Resource transfer (TCPTransport-only wire cases)

    func testResourceStartRoundTrip() throws {
        let original = PeerMessage.resourceStart(resourceID: "res-1", name: "photo.jpg", totalBytes: 12345)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PeerMessage.self, from: data)
        guard case .resourceStart(let resourceID, let name, let totalBytes) = decoded else { return XCTFail("wrong type") }
        XCTAssertEqual(resourceID, "res-1")
        XCTAssertEqual(name, "photo.jpg")
        XCTAssertEqual(totalBytes, 12345)
    }

    func testResourceChunkRoundTrip() throws {
        let chunk = Data([0x10, 0x20, 0x30])
        let original = PeerMessage.resourceChunk(resourceID: "res-1", chunk: chunk)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PeerMessage.self, from: data)
        guard case .resourceChunk(let resourceID, let decodedChunk) = decoded else { return XCTFail("wrong type") }
        XCTAssertEqual(resourceID, "res-1")
        XCTAssertEqual(decodedChunk, chunk)
    }

    func testResourceEndRoundTrip() throws {
        let original = PeerMessage.resourceEnd(resourceID: "res-1")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PeerMessage.self, from: data)
        guard case .resourceEnd(let resourceID) = decoded else { return XCTFail("wrong type") }
        XCTAssertEqual(resourceID, "res-1")
    }

    // MARK: - Type isolation

    func testTextDoesNotDecodeAsData() throws {
        let original = PeerMessage.text("test")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PeerMessage.self, from: data)
        if case .data = decoded { XCTFail("text decoded as data") }
    }

    func testDataDoesNotDecodeAsText() throws {
        let original = PeerMessage.data(Data([1, 2, 3]))
        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(PeerMessage.self, from: encoded)
        if case .text = decoded { XCTFail("data decoded as text") }
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try decoder.decode(PeerMessage.self, from: Data()))
        XCTAssertThrowsError(try decoder.decode(PeerMessage.self, from: "{}".data(using: .utf8)!))
    }
}
