import XCTest
import Network
@testable import PeerConnect

// Real loopback (127.0.0.1) TLS tests between two TCPTransport instances,
// bypassing PeerAdvertiser/PeerBrowser's handshake dance so these focus
// purely on TCPTransport's framing, TLS, and resource-chunking behaviour.
final class TCPTransportTests: XCTestCase {

    private final class Harness: @unchecked Sendable {
        let listener: NWListener
        var serverConnection: NWConnection?
        var serverTransport: TCPTransport?
        let queue = DispatchQueue(label: "com.peerconnect.tests.tcp-transport")

        init(readyExpectation: XCTestExpectation, connectionExpectation: XCTestExpectation) throws {
            let identity = try PeerTLSIdentity.makeEphemeralIdentity(commonName: "TCPTransportTests")
            let parameters = PeerTLSIdentity.serverParameters(identity: identity)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.serverConnection = connection
                self.serverTransport = TCPTransport(connection: connection, queue: self.queue)
                connectionExpectation.fulfill()
            }
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    readyExpectation.fulfill()
                }
            }
            listener.start(queue: queue)
        }

        var port: NWEndpoint.Port {
            listener.port!
        }
    }

    private func makeClientConnection(port: NWEndpoint.Port, queue: DispatchQueue, readyExpectation: XCTestExpectation) -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: PeerTLSIdentity.clientParameters())
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                readyExpectation.fulfill()
            }
        }
        connection.start(queue: queue)
        return connection
    }

    func testTextRoundTripsOverTLS() throws {
        try TLSTestAvailability.requireKeychainAccess()

        let listenerReady = expectation(description: "listener ready")
        let serverAccepted = expectation(description: "server accepted connection")
        let harness = try Harness(readyExpectation: listenerReady, connectionExpectation: serverAccepted)
        wait(for: [listenerReady], timeout: 5)

        let clientReady = expectation(description: "client ready")
        let clientConnection = makeClientConnection(port: harness.port, queue: harness.queue, readyExpectation: clientReady)
        wait(for: [clientReady, serverAccepted], timeout: 5)

        let clientTransport = TCPTransport(connection: clientConnection, queue: harness.queue)

        let received = expectation(description: "server received text")
        let delegate = RecordingTransportDelegate()
        delegate.onReceive = { received.fulfill() }
        harness.serverTransport?.transportDelegate = delegate

        let encoded = try JSONEncoder().encode(PeerMessage.text("hello over tls"))
        clientTransport.send(encoded)

        wait(for: [received], timeout: 5)
        let decoded = try JSONDecoder().decode(PeerMessage.self, from: delegate.receivedData[0])
        guard case .text(let s) = decoded else { return XCTFail("wrong type") }
        XCTAssertEqual(s, "hello over tls")
    }

    func testResourceRoundTripsOverTLS() throws {
        try TLSTestAvailability.requireKeychainAccess()

        let listenerReady = expectation(description: "listener ready")
        let serverAccepted = expectation(description: "server accepted connection")
        let harness = try Harness(readyExpectation: listenerReady, connectionExpectation: serverAccepted)
        wait(for: [listenerReady], timeout: 5)

        let clientReady = expectation(description: "client ready")
        let clientConnection = makeClientConnection(port: harness.port, queue: harness.queue, readyExpectation: clientReady)
        wait(for: [clientReady, serverAccepted], timeout: 5)

        let clientTransport = TCPTransport(connection: clientConnection, queue: harness.queue)

        let started = expectation(description: "started receiving")
        let finished = expectation(description: "finished receiving")
        let delegate = RecordingTransportDelegate()
        delegate.onStart = { started.fulfill() }
        delegate.onFinish = { finished.fulfill() }
        harness.serverTransport?.transportDelegate = delegate

        let sourceContent = String(repeating: "peerconnect-tls-resource-test ", count: 5000) // > one chunk
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try sourceContent.write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let sendCompleted = expectation(description: "send completed")
        clientTransport.sendResource(at: sourceURL, name: "big.txt", resourceID: "res-tls-1") { sent in
            XCTAssertTrue(sent)
            sendCompleted.fulfill()
        }

        wait(for: [started, finished, sendCompleted], timeout: 10)

        XCTAssertEqual(delegate.startedResourceNames, ["res-tls-1\u{001C}big.txt"])
        guard let finishedURL = delegate.finishedResourceURL else {
            return XCTFail("Expected a finished resource URL")
        }
        defer { try? FileManager.default.removeItem(at: finishedURL) }

        let receivedContent = try String(contentsOf: finishedURL, encoding: .utf8)
        XCTAssertEqual(receivedContent, sourceContent)
    }
}

private final class RecordingTransportDelegate: PeerTransportDelegate {
    var receivedData: [Data] = []
    var startedResourceNames: [String] = []
    var finishedResourceURL: URL?

    var onReceive: (() -> Void)?
    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?

    func transportDidReceive(_ data: Data) {
        receivedData.append(data)
        onReceive?()
    }

    func transportDidDisconnect(byRequest: Bool) {}

    func transport(didStartReceivingResourceNamed resourceName: String, progress: Progress) {
        startedResourceNames.append(resourceName)
        onStart?()
    }

    func transport(didFinishReceivingResourceNamed resourceName: String, at localURL: URL?, error: Error?) {
        finishedResourceURL = localURL
        onFinish?()
    }
}
