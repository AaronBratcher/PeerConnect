import Foundation

// Encodes all wire messages. `handshake` is internal to the connection setup
// protocol; `text` and `data` are user-facing payloads. The `resource*` cases
// are used only by TCPTransport, which (unlike MCSession) has no built-in
// file-transfer primitive and must chunk resources itself.
enum PeerMessage: Codable {
    case text(String)
    case data(Data)
    case handshake(accepted: Bool)
    case resourceStart(resourceID: String, name: String, totalBytes: Int64)
    case resourceChunk(resourceID: String, chunk: Data)
    case resourceEnd(resourceID: String)

    private enum CodingKeys: String, CodingKey {
        case type, payload, accepted, resourceID, name, totalBytes, chunk
    }

    private enum MessageType: String, Codable {
        case text, data, handshake, resourceStart, resourceChunk, resourceEnd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(MessageType.self, forKey: .type) {
        case .text:
            self = .text(try c.decode(String.self, forKey: .payload))
        case .data:
            self = .data(try c.decode(Data.self, forKey: .payload))
        case .handshake:
            self = .handshake(accepted: try c.decode(Bool.self, forKey: .accepted))
        case .resourceStart:
            self = .resourceStart(
                resourceID: try c.decode(String.self, forKey: .resourceID),
                name: try c.decode(String.self, forKey: .name),
                totalBytes: try c.decode(Int64.self, forKey: .totalBytes)
            )
        case .resourceChunk:
            self = .resourceChunk(
                resourceID: try c.decode(String.self, forKey: .resourceID),
                chunk: try c.decode(Data.self, forKey: .chunk)
            )
        case .resourceEnd:
            self = .resourceEnd(resourceID: try c.decode(String.self, forKey: .resourceID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode(MessageType.text, forKey: .type)
            try c.encode(s, forKey: .payload)
        case .data(let d):
            try c.encode(MessageType.data, forKey: .type)
            try c.encode(d, forKey: .payload)
        case .handshake(let accepted):
            try c.encode(MessageType.handshake, forKey: .type)
            try c.encode(accepted, forKey: .accepted)
        case .resourceStart(let resourceID, let name, let totalBytes):
            try c.encode(MessageType.resourceStart, forKey: .type)
            try c.encode(resourceID, forKey: .resourceID)
            try c.encode(name, forKey: .name)
            try c.encode(totalBytes, forKey: .totalBytes)
        case .resourceChunk(let resourceID, let chunk):
            try c.encode(MessageType.resourceChunk, forKey: .type)
            try c.encode(resourceID, forKey: .resourceID)
            try c.encode(chunk, forKey: .chunk)
        case .resourceEnd(let resourceID):
            try c.encode(MessageType.resourceEnd, forKey: .type)
            try c.encode(resourceID, forKey: .resourceID)
        }
    }
}
