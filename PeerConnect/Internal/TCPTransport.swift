import Foundation
import Network

// Length-prefixed framing over a raw NWConnection stream: a 4-byte
// big-endian length prefix followed by that many bytes of payload. TCP has
// no built-in message boundaries (unlike MCSession), so both TCPTransport
// and the pre-session handshake dance in PeerAdvertiser/PeerBrowser share
// this helper.
enum TCPFraming {
    static func sendFrame(_ data: Data, on connection: NWConnection, completion: @escaping @Sendable (Error?) -> Void) {
        let length = UInt32(data.count)
        let header = Data([
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF)
        ])
        var framed = header
        framed.append(data)
        connection.send(content: framed, completion: .contentProcessed { error in
            completion(error)
        })
    }

    /// Calls `completion(nil, nil)` when the connection closed cleanly with no more frames.
    static func receiveFrame(on connection: NWConnection, completion: @escaping @Sendable (Data?, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { headerData, _, _, error in
            if let error {
                completion(nil, error)
                return
            }
            guard let headerData, headerData.count == 4 else {
                completion(nil, nil)
                return
            }
            let length = headerData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0 else {
                completion(nil, nil)
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { bodyData, _, _, error in
                if let error {
                    completion(nil, error)
                    return
                }
                guard let bodyData, bodyData.count == Int(length) else {
                    completion(nil, nil)
                    return
                }
                completion(bodyData, nil)
            }
        }
    }
}

// TCP/TLS-backed PeerTransport. Wraps an already-started, ready NWConnection
// (the handshake that established it happens in PeerAdvertiser/PeerBrowser
// before a TCPTransport is created — mirroring how PeerAdvertiser/PeerBrowser
// hand off MCSession delegate ownership to MCTransport/PeerSession).
//
// Unlike MCSession, raw TCP has no resource-transfer primitive, so file
// sends are chunked by hand using the PeerMessage.resource* wire cases.
final class TCPTransport: NSObject, PeerTransport, @unchecked Sendable {
    weak var transportDelegate: PeerTransportDelegate?

    private let connection: NWConnection
    private let queue: DispatchQueue

    private var disconnecting = false
    private let lock = NSLock()

    private struct IncomingResource {
        let name: String
        let fileHandle: FileHandle
        let tempURL: URL
        let progress: Progress
    }
    private var incomingResources: [String: IncomingResource] = [:]

    private static let chunkSize = 64 * 1024

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        super.init()
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleStateChange(state)
        }
        receiveNextFrame()
    }

    // MARK: - PeerTransport

    func send(_ data: Data) {
        TCPFraming.sendFrame(data, on: connection) { _ in }
    }

    @discardableResult
    func sendResource(at url: URL, name: String, resourceID: String, onCompletion: @escaping SendCompletionHandler) -> Progress {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let totalBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let progress = Progress(totalUnitCount: totalBytes)

        guard let fileHandle = try? FileHandle(forReadingFrom: url),
              let startFrame = try? JSONEncoder().encode(
                PeerMessage.resourceStart(resourceID: resourceID, name: name, totalBytes: totalBytes)
              )
        else {
            onCompletion(false)
            return progress
        }

        @Sendable func sendNextChunk() {
            let chunk = fileHandle.readData(ofLength: Self.chunkSize)
            if chunk.isEmpty {
                guard let endFrame = try? JSONEncoder().encode(PeerMessage.resourceEnd(resourceID: resourceID)) else {
                    try? fileHandle.close()
                    onCompletion(false)
                    return
                }
                TCPFraming.sendFrame(endFrame, on: connection) { error in
                    try? fileHandle.close()
                    onCompletion(error == nil)
                }
                return
            }

            guard let chunkFrame = try? JSONEncoder().encode(
                PeerMessage.resourceChunk(resourceID: resourceID, chunk: chunk)
            ) else {
                try? fileHandle.close()
                onCompletion(false)
                return
            }

            TCPFraming.sendFrame(chunkFrame, on: connection) { error in
                guard error == nil else {
                    try? fileHandle.close()
                    onCompletion(false)
                    return
                }
                progress.completedUnitCount += Int64(chunk.count)
                sendNextChunk()
            }
        }

        TCPFraming.sendFrame(startFrame, on: connection) { error in
            guard error == nil else {
                try? fileHandle.close()
                onCompletion(false)
                return
            }
            sendNextChunk()
        }

        return progress
    }

    func disconnect() {
        lock.lock()
        disconnecting = true
        lock.unlock()
        connection.cancel()
    }

    // MARK: - Receive loop

    private func receiveNextFrame() {
        TCPFraming.receiveFrame(on: connection) { [weak self] data, error in
            guard let self else { return }
            guard let data, error == nil else { return } // stateUpdateHandler reports the disconnect
            self.handleIncoming(frame: data)
            self.receiveNextFrame()
        }
    }

    private func handleIncoming(frame data: Data) {
        guard let message = try? JSONDecoder().decode(PeerMessage.self, from: data) else { return }

        switch message {
        case .resourceStart(let resourceID, let name, let totalBytes):
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: tempURL.path, contents: nil),
                  let fileHandle = try? FileHandle(forWritingTo: tempURL)
            else { return }
            let progress = Progress(totalUnitCount: totalBytes)
            lock.lock()
            incomingResources[resourceID] = IncomingResource(name: name, fileHandle: fileHandle, tempURL: tempURL, progress: progress)
            lock.unlock()
            transportDelegate?.transport(didStartReceivingResourceNamed: "\(resourceID)\u{001C}\(name)", progress: progress)

        case .resourceChunk(let resourceID, let chunk):
            lock.lock()
            let resource = incomingResources[resourceID]
            lock.unlock()
            guard let resource else { return }
            resource.fileHandle.write(chunk)
            resource.progress.completedUnitCount += Int64(chunk.count)

        case .resourceEnd(let resourceID):
            lock.lock()
            let resource = incomingResources.removeValue(forKey: resourceID)
            lock.unlock()
            guard let resource else { return }
            try? resource.fileHandle.close()
            transportDelegate?.transport(
                didFinishReceivingResourceNamed: "\(resourceID)\u{001C}\(resource.name)",
                at: resource.tempURL,
                error: nil
            )

        case .text, .data, .handshake:
            transportDelegate?.transportDidReceive(data)
        }
    }

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            lock.lock()
            let wasDisconnecting = disconnecting
            lock.unlock()
            transportDelegate?.transportDidDisconnect(byRequest: wasDisconnecting)
        default:
            break
        }
    }
}
