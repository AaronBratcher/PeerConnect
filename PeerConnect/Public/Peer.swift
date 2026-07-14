import Foundation
import MultipeerConnectivity

public final class Peer: @unchecked Sendable {
    public let name: String
    public let peerID: String

    // Set internally by PeerBrowser when a remote peer is found via discovery.
    var mcPeerID: MCPeerID?

    // Set directly by the caller via init(name:peerID:host:port:) to target
    // a TCP/TLS connection instead of one discovered over MultipeerConnectivity.
    var tcpEndpoint: (host: String, port: UInt16)?

    public init(name: String, peerID: String) {
        self.name = name
        self.peerID = peerID
    }

    /// Constructs a `Peer` that targets a direct TCP/TLS connection at `host:port`,
    /// bypassing MultipeerConnectivity discovery entirely. Pass the result to
    /// `PeerBrowser.connectToServer(_:)` the same way you would a peer delivered
    /// via `serverFound(_:)`. `port` must match the advertiser's `tcpPort`, and the
    /// advertiser must have been started with `startPublishing(alsoAvailableViaTCP: true)`.
    public init(name: String, peerID: String, host: String, port: UInt16) {
        self.name = name
        self.peerID = peerID
        self.tcpEndpoint = (host: host, port: port)
    }

    public init?(dataValue: Data) {
        guard
            let dict = try? JSONDecoder().decode([String: String].self, from: dataValue),
            let name = dict["name"],
            let peerID = dict["peerID"]
        else { return nil }
        self.name = name
        self.peerID = peerID
    }

    public func dataValue() -> Data {
        let dict = ["name": name, "peerID": peerID]
        return (try? JSONEncoder().encode(dict)) ?? Data()
    }
}

extension Peer: Equatable {
    public static func == (lhs: Peer, rhs: Peer) -> Bool {
        lhs.peerID == rhs.peerID
    }
}

extension Peer: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(peerID)
    }
}
