import XCTest
import MultipeerConnectivity
import Combine
@testable import PeerConnect

final class PeerSessionTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    private func makeSession(localName: String = "Local", remoteName: String = "Remote") -> (PeerSession, MCSession, MCPeerID) {
        let localPeerID = MCPeerID(displayName: localName)
        let remotePeerID = MCPeerID(displayName: remoteName)
        let mcSession = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .none)
        let remotePeer = Peer(name: remoteName, peerID: UUID().uuidString)
        let transport = MCTransport(mcSession: mcSession, remoteMCPeerID: remotePeerID)
        let session = PeerSession(transport: transport, remotePeer: remotePeer)
        return (session, mcSession, remotePeerID)
    }

    func testRemotePeerIsCorrect() {
        let remotePeer = Peer(name: "ServerDevice", peerID: "fixed-uuid")
        let localPeerID = MCPeerID(displayName: "Client")
        let remotePeerID = MCPeerID(displayName: "ServerDevice")
        let mc = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .none)
        let transport = MCTransport(mcSession: mc, remoteMCPeerID: remotePeerID)
        let session = PeerSession(transport: transport, remotePeer: remotePeer)

        XCTAssertEqual(session.remotePeer.name, "ServerDevice")
        XCTAssertEqual(session.remotePeer.peerID, "fixed-uuid")
    }

    func testDelegateQueueDefaultsToMain() {
        let (session, _, _) = makeSession()
        XCTAssertTrue(session.delegateQueue === DispatchQueue.main)
    }

    func testCustomDelegateQueueIsPreserved() {
        let (session, _, _) = makeSession()
        let custom = DispatchQueue(label: "com.test.custom")
        session.delegateQueue = custom
        XCTAssertTrue(session.delegateQueue === custom)
    }

    func testDelegateAssignment() {
        let (session, _, _) = makeSession()
        let spy = SpySessionDelegate()
        session.delegate = spy
        XCTAssertTrue(session.delegate === spy)
    }

    func testWeakDelegate() {
        let (session, _, _) = makeSession()
        var spy: SpySessionDelegate? = SpySessionDelegate()
        session.delegate = spy
        spy = nil
        XCTAssertNil(session.delegate)
    }

    // Verifies that disconnect() flips disconnecting before calling mcSession.disconnect().
    // Real disconnection behaviour requires hardware; this checks the flag indirectly
    // by asserting no crash occurs and the delegate does not fire synchronously.
    func testDisconnectDoesNotFireDelegateSynchronously() {
        let (session, _, _) = makeSession()
        let spy = SpySessionDelegate()
        session.delegate = spy
        session.disconnect()
        XCTAssertFalse(spy.didDisconnect)
    }

    // MARK: - PeerTransport-backed behaviour (transport-agnostic, no real MCSession/socket needed)

    private func makeSpySession(remoteName: String = "Remote") -> (PeerSession, SpyTransport) {
        let transport = SpyTransport()
        let remotePeer = Peer(name: remoteName, peerID: UUID().uuidString)
        let session = PeerSession(transport: transport, remotePeer: remotePeer)
        return (session, transport)
    }

    func testSendTextEncodesAndForwardsToTransport() {
        let (session, transport) = makeSpySession()
        session.sendText("hello")

        XCTAssertEqual(transport.sentData.count, 1)
        let decoded = try? JSONDecoder().decode(PeerMessage.self, from: transport.sentData[0])
        guard case .text("hello") = decoded else {
            return XCTFail("Expected encoded .text(\"hello\"), got \(String(describing: decoded))")
        }
    }

    func testSendDataEncodesAndForwardsToTransport() {
        let (session, transport) = makeSpySession()
        let payload = Data([1, 2, 3])
        session.sendData(payload)

        XCTAssertEqual(transport.sentData.count, 1)
        let decoded = try? JSONDecoder().decode(PeerMessage.self, from: transport.sentData[0])
        guard case .data(let received) = decoded else {
            return XCTFail("Expected encoded .data, got \(String(describing: decoded))")
        }
        XCTAssertEqual(received, payload)
    }

    func testSendResourceForwardsToTransport() {
        let (session, transport) = makeSpySession()
        let url = URL(fileURLWithPath: "/tmp/example.txt")
        let expectation = expectation(description: "completion called")

        session.sendResourceAtURL(url, name: "example.txt", resourceID: "res-1") { sent in
            XCTAssertTrue(sent)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(transport.sendResourceCalls.count, 1)
        XCTAssertEqual(transport.sendResourceCalls[0].name, "example.txt")
        XCTAssertEqual(transport.sendResourceCalls[0].resourceID, "res-1")
    }

    func testDisconnectForwardsToTransport() {
        let (session, transport) = makeSpySession()
        session.disconnect()
        XCTAssertTrue(transport.didDisconnect)
    }

    func testTransportDidReceiveDispatchesTextToDelegate() throws {
        let (session, _) = makeSpySession()
        let spy = SpySessionDelegate()
        session.delegate = spy

        let delegateExpectation = expectation(description: "text received")
        spy.onTextReceived = { delegateExpectation.fulfill() }

        let publisherExpectation = expectation(description: "textReceivedPublisher fired")
        var publishedText: String?
        session.textReceivedPublisher.sink { text in
            publishedText = text
            publisherExpectation.fulfill()
        }.store(in: &cancellables)

        let encoded = try JSONEncoder().encode(PeerMessage.text("hi there"))
        (session as PeerTransportDelegate).transportDidReceive(encoded)

        wait(for: [delegateExpectation, publisherExpectation], timeout: 1)
        XCTAssertEqual(spy.lastText, "hi there")
        XCTAssertEqual(publishedText, "hi there")
    }

    func testTransportDidReceiveDispatchesDataToDelegate() throws {
        let (session, _) = makeSpySession()
        let spy = SpySessionDelegate()
        session.delegate = spy

        let delegateExpectation = expectation(description: "data received")
        spy.onDataReceived = { delegateExpectation.fulfill() }

        let publisherExpectation = expectation(description: "dataReceivedPublisher fired")
        var publishedData: Data?
        session.dataReceivedPublisher.sink { data in
            publishedData = data
            publisherExpectation.fulfill()
        }.store(in: &cancellables)

        let payload = Data([9, 9, 9])
        let encoded = try JSONEncoder().encode(PeerMessage.data(payload))
        (session as PeerTransportDelegate).transportDidReceive(encoded)

        wait(for: [delegateExpectation, publisherExpectation], timeout: 1)
        XCTAssertEqual(spy.lastData, payload)
        XCTAssertEqual(publishedData, payload)
    }

    func testTransportDidDisconnectForwardsByRequestToDelegate() {
        let (session, _) = makeSpySession()
        let spy = SpySessionDelegate()
        session.delegate = spy

        let delegateExpectation = expectation(description: "disconnected")
        spy.onDisconnected = { delegateExpectation.fulfill() }

        let publisherExpectation = expectation(description: "disconnectedPublisher fired")
        var publishedByRequest: Bool?
        session.disconnectedPublisher.sink { byRequest in
            publishedByRequest = byRequest
            publisherExpectation.fulfill()
        }.store(in: &cancellables)

        (session as PeerTransportDelegate).transportDidDisconnect(byRequest: true)

        wait(for: [delegateExpectation, publisherExpectation], timeout: 1)
        XCTAssertTrue(spy.didDisconnect)
        XCTAssertEqual(spy.lastByRequest, true)
        XCTAssertEqual(publishedByRequest, true)
    }

    func testResourceReceiveMovesFileIntoDocumentsAndNotifiesDelegate() throws {
        let (session, _) = makeSpySession()
        let spy = SpySessionDelegate()
        session.delegate = spy

        let fileName = "peerconnect-test-\(UUID().uuidString).txt"
        let resourceName = "res-2\u{001C}\(fileName)"
        let progress = Progress(totalUnitCount: 4)

        let startExpectation = expectation(description: "started receiving")
        spy.onStartedReceivingResource = { startExpectation.fulfill() }
        let startPublisherExpectation = expectation(description: "startedReceivingResourcePublisher fired")
        var startedEvent: PeerReceivingResourceEvent?
        session.startedReceivingResourcePublisher.sink { event in
            startedEvent = event
            startPublisherExpectation.fulfill()
        }.store(in: &cancellables)

        (session as PeerTransportDelegate).transport(didStartReceivingResourceNamed: resourceName, progress: progress)
        wait(for: [startExpectation, startPublisherExpectation], timeout: 1)

        guard let destination = spy.lastResourceURL else {
            return XCTFail("Expected startedReceivingResource to report a destination URL")
        }
        defer { try? FileManager.default.removeItem(at: destination) }

        XCTAssertEqual(startedEvent?.atURL, destination)
        XCTAssertEqual(startedEvent?.name, fileName)
        XCTAssertEqual(startedEvent?.resourceID, "res-2")

        let stagingURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("test".utf8).write(to: stagingURL)

        let finishExpectation = expectation(description: "finished receiving")
        spy.onResourceReceived = { finishExpectation.fulfill() }
        let finishPublisherExpectation = expectation(description: "resourceReceivedPublisher fired")
        var finishedEvent: PeerReceivedResourceEvent?
        session.resourceReceivedPublisher.sink { event in
            finishedEvent = event
            finishPublisherExpectation.fulfill()
        }.store(in: &cancellables)

        (session as PeerTransportDelegate).transport(didFinishReceivingResourceNamed: resourceName, at: stagingURL, error: nil)
        wait(for: [finishExpectation, finishPublisherExpectation], timeout: 1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "test")
        XCTAssertEqual(finishedEvent?.atURL, destination)
        XCTAssertEqual(finishedEvent?.name, fileName)
        XCTAssertEqual(finishedEvent?.resourceID, "res-2")
    }
}

// MARK: - Spies

private final class SpyTransport: PeerTransport {
    weak var transportDelegate: PeerTransportDelegate?
    var sentData: [Data] = []
    var didDisconnect = false
    var sendResourceCalls: [(url: URL, name: String, resourceID: String)] = []

    func send(_ data: Data) {
        sentData.append(data)
    }

    func sendResource(at url: URL, name: String, resourceID: String, onCompletion: @escaping SendCompletionHandler) -> Progress {
        sendResourceCalls.append((url, name, resourceID))
        onCompletion(true)
        return Progress(totalUnitCount: -1)
    }

    func disconnect() {
        didDisconnect = true
    }
}

private final class SpySessionDelegate: PeerSessionDelegate {
    var didDisconnect = false
    var lastByRequest: Bool?
    var lastText: String?
    var lastData: Data?
    var lastResourceURL: URL?

    var onDisconnected: (() -> Void)?
    var onTextReceived: (() -> Void)?
    var onDataReceived: (() -> Void)?
    var onStartedReceivingResource: (() -> Void)?
    var onResourceReceived: (() -> Void)?

    func disconnected(_ session: PeerSession, byRequest: Bool) {
        didDisconnect = true
        lastByRequest = byRequest
        onDisconnected?()
    }
    func textReceived(_ session: PeerSession, text: String) {
        lastText = text
        onTextReceived?()
    }
    func dataReceived(_ session: PeerSession, data: Data) {
        lastData = data
        onDataReceived?()
    }
    func startedReceivingResource(_ session: PeerSession, atURL: URL, name: String, resourceID: String, progress: Progress) {
        lastResourceURL = atURL
        onStartedReceivingResource?()
    }
    func resourceReceived(_ session: PeerSession, atURL: URL, name: String, resourceID: String) {
        lastResourceURL = atURL
        onResourceReceived?()
    }
}
