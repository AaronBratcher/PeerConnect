import Foundation
import Combine

// Resource name encoding: "<resourceID>\u{001C}<filename>"
// Unit separator (U+001C) cannot appear in UUIDs or typical filenames.
private let resourceNameSeparator = "\u{001C}"

public final class PeerSession: NSObject, @unchecked Sendable {
    public weak var delegate: PeerSessionDelegate?
    public var delegateQueue = DispatchQueue.main
    public let remotePeer: Peer

    private let transport: PeerTransport
    private let onEnded: (() -> Void)?

    private let lock = NSLock()

    // Tracks planned destination URLs for in-progress inbound resource transfers.
    private var resourceDestinations: [String: URL] = [:]

    private let disconnectedSubject = PassthroughSubject<Bool, Never>()
    private let textReceivedSubject = PassthroughSubject<String, Never>()
    private let dataReceivedSubject = PassthroughSubject<Data, Never>()
    private let startedReceivingResourceSubject = PassthroughSubject<PeerReceivingResourceEvent, Never>()
    private let resourceReceivedSubject = PassthroughSubject<PeerReceivedResourceEvent, Never>()

    /// Fires with `byRequest` when the connection ends. Unlike `PeerSessionDelegate`,
    /// there's no redundant `session` parameter — a subscriber already holds this instance.
    public let disconnectedPublisher: AnyPublisher<Bool, Never>
    public let textReceivedPublisher: AnyPublisher<String, Never>
    public let dataReceivedPublisher: AnyPublisher<Data, Never>
    public let startedReceivingResourcePublisher: AnyPublisher<PeerReceivingResourceEvent, Never>
    public let resourceReceivedPublisher: AnyPublisher<PeerReceivedResourceEvent, Never>

    /// - Parameter onEnded: Invoked once when the transport reports a disconnect,
    ///   before the app delegate is notified. Used internally by PeerAdvertiser/PeerBrowser
    ///   to release this peer's slot in a `PeerSessionCoordinator`.
    init(transport: PeerTransport, remotePeer: Peer, onEnded: (() -> Void)? = nil) {
        self.transport = transport
        self.remotePeer = remotePeer
        self.onEnded = onEnded
        self.disconnectedPublisher = disconnectedSubject.eraseToAnyPublisher()
        self.textReceivedPublisher = textReceivedSubject.eraseToAnyPublisher()
        self.dataReceivedPublisher = dataReceivedSubject.eraseToAnyPublisher()
        self.startedReceivingResourcePublisher = startedReceivingResourceSubject.eraseToAnyPublisher()
        self.resourceReceivedPublisher = resourceReceivedSubject.eraseToAnyPublisher()
        super.init()
        transport.transportDelegate = self
    }

    // MARK: - Public API

    public func sendText(_ text: String) {
        guard let encoded = try? JSONEncoder().encode(PeerMessage.text(text)) else { return }
        transport.send(encoded)
    }

    public func sendData(_ data: Data) {
        guard let encoded = try? JSONEncoder().encode(PeerMessage.data(data)) else { return }
        transport.send(encoded)
    }

    @discardableResult
    public func sendResourceAtURL(_ url: URL, name: String, resourceID: String, onCompletion: @escaping SendCompletionHandler) -> Progress {
        transport.sendResource(at: url, name: name, resourceID: resourceID, onCompletion: onCompletion)
    }

    public func disconnect() {
        transport.disconnect()
    }
}

// MARK: - PeerTransportDelegate

extension PeerSession: PeerTransportDelegate {
    func transportDidReceive(_ data: Data) {
        guard let message = try? JSONDecoder().decode(PeerMessage.self, from: data) else { return }

        switch message {
        case .text(let text):
            delegateQueue.async { [weak self] in
                guard let self else { return }
                self.delegate?.textReceived(self, text: text)
                self.textReceivedSubject.send(text)
            }
        case .data(let payload):
            delegateQueue.async { [weak self] in
                guard let self else { return }
                self.delegate?.dataReceived(self, data: payload)
                self.dataReceivedSubject.send(payload)
            }
        case .handshake, .resourceStart, .resourceChunk, .resourceEnd:
            // Handshake is consumed before PeerSession is installed as delegate;
            // resource frames are consumed internally by TCPTransport.
            // Arriving here means a duplicate or out-of-order message — ignore.
            break
        }
    }

    func transportDidDisconnect(byRequest: Bool) {
        onEnded?()
        delegateQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.disconnected(self, byRequest: byRequest)
            self.disconnectedSubject.send(byRequest)
        }
    }

    func transport(didStartReceivingResourceNamed resourceName: String, progress: Progress) {
        guard let (resourceID, name) = parseResourceName(resourceName) else { return }

        let destination = uniqueDocumentsURL(for: name)
        lock.lock()
        resourceDestinations[resourceName] = destination
        lock.unlock()

        delegateQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.startedReceivingResource(self, atURL: destination, name: name, resourceID: resourceID, progress: progress)
            self.startedReceivingResourceSubject.send(
                PeerReceivingResourceEvent(atURL: destination, name: name, resourceID: resourceID, progress: progress)
            )
        }
    }

    func transport(didFinishReceivingResourceNamed resourceName: String, at localURL: URL?, error: Error?) {
        guard let (resourceID, name) = parseResourceName(resourceName) else { return }

        lock.lock()
        let destination = resourceDestinations.removeValue(forKey: resourceName)
        lock.unlock()

        guard error == nil, let localURL, let destination else { return }
        try? FileManager.default.moveItem(at: localURL, to: destination)

        delegateQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.resourceReceived(self, atURL: destination, name: name, resourceID: resourceID)
            self.resourceReceivedSubject.send(
                PeerReceivedResourceEvent(atURL: destination, name: name, resourceID: resourceID)
            )
        }
    }
}

// MARK: - Helpers

private func parseResourceName(_ resourceName: String) -> (resourceID: String, name: String)? {
    guard let separatorRange = resourceName.range(of: resourceNameSeparator) else { return nil }
    let resourceID = String(resourceName[resourceName.startIndex..<separatorRange.lowerBound])
    let name = String(resourceName[separatorRange.upperBound...])
    return (resourceID, name)
}

private func uniqueDocumentsURL(for name: String) -> URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var url = docs.appendingPathComponent(name)
    var index = 1
    let ext = url.pathExtension
    let base = url.deletingPathExtension().lastPathComponent
    while FileManager.default.fileExists(atPath: url.path) {
        let newName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
        url = docs.appendingPathComponent(newName)
        index += 1
    }
    return url
}
