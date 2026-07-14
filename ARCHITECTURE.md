# PeerConnect Architecture

PeerConnect is a Swift package that wraps Apple's `MultipeerConnectivity` (MC) framework behind a simpler, role-based API. It handles the MC ceremony — session lifecycle, handshakes, delegate ownership transfers, thread safety — so callers work only with `Peer`, `PeerSession`, and three focused delegate protocols. Every event is also available as a discrete Combine publisher, alongside (not instead of) the delegate methods — see [Combine](#combine) below.

A second transport is also available: a direct TCP connection wrapped in TLS, for connecting to a specific IP address instead of discovering peers via MC/Bonjour. Both transports share the same `Peer`/`PeerAdvertiser`/`PeerBrowser`/`PeerSession` API — see [Transports](#transports) below.

**Supported platforms:** iOS 26+, macOS 26+, tvOS 26+, watchOS 26+, visionOS 26+

---

## Role model

Every participant is either an **advertiser** (server) or a **browser** (client). A single process can run both roles simultaneously — share a `PeerSessionCoordinator` between them to avoid ending up with two parallel sessions to the same peer (see [Preventing parallel/duplicate sessions](#preventing-parallelduplicate-sessions) below).

```
┌─────────────────────────────────┐      ┌─────────────────────────────────┐
│         Advertiser (server)     │      │          Browser (client)       │
│                                 │      │                                 │
│  PeerAdvertiser                 │      │  PeerBrowser                   │
│    startPublishing()            │◄────►│    startBrowsing()             │
│    stopPublishing()             │      │    stopBrowsing()              │
│                                 │      │    connectToServer(_:)         │
│  PeerAdvertiserDelegate         │      │  PeerBrowserDelegate           │
│    allowConnectionRequest(...)  │      │    serverFound(_:)             │
│    clientDidConnect(_:)         │      │    connected(_:)               │
└─────────────────────────────────┘      └─────────────────────────────────┘
                      │                              │
                      └──────────┐  ┌───────────────┘
                                 ▼  ▼
                            PeerSession
                          sendText(_:)
                          sendData(_:)
                          sendResourceAtURL(_:name:resourceID:onCompletion:)
                          disconnect()

                         PeerSessionDelegate
                          textReceived(_:text:)
                          dataReceived(_:data:)
                          startedReceivingResource(...)
                          resourceReceived(...)
                          disconnected(_:byRequest:)
```

---

## Source files

| File | Visibility | Purpose |
|---|---|---|
| `Peer.swift` | public | Identity model for a network participant |
| `PeerAdvertiser.swift` | public | Advertises presence; accepts/rejects incoming connections |
| `PeerBrowser.swift` | public | Discovers nearby advertisers; initiates connections |
| `PeerSession.swift` | public | Active bidirectional connection between two peers |
| `PeerProtocols.swift` | public | Delegate protocols and typealiases |
| `PeerMessage.swift` | internal | Wire message format (not part of the public API) |
| `PeerTransport.swift` | internal | Abstraction underneath `PeerSession`; lets it be backed by either transport |
| `MCTransport.swift` | internal | `PeerTransport` implementation wrapping `MCSession` |
| `TCPTransport.swift` | internal | `PeerTransport` implementation wrapping a TLS-wrapped `NWConnection`; also owns the length-prefixed framing (`TCPFraming`) shared with the pre-session handshake |
| `PeerTLSIdentity.swift` | internal | Generates the ephemeral self-signed TLS identity and TLS parameters for both sides of the TCP transport |
| `PeerSessionCoordinator.swift` | public | Optional, shareable between a device's `PeerAdvertiser` and `PeerBrowser`; prevents parallel/duplicate sessions with the same peer |
| `PeerConnectEvents.swift` | public | Value types for the Combine surface: `PeerConnectError`, `PeerConnectionRequest`, `PeerReceivingResourceEvent`, `PeerReceivedResourceEvent` |

---

## Transports

`PeerSession` doesn't know or care which transport backs it — `sendText`, `sendData`, `sendResourceAtURL`, and `disconnect` behave identically either way. The transport is chosen per-connection based on how the `Peer` was obtained:

- **MultipeerConnectivity (default):** a `Peer` discovered via `PeerBrowserDelegate.serverFound(_:)` carries an internal `mcPeerID`. `connectToServer(_:)` uses it to invite over MC, exactly as before.
- **TCP/TLS (direct IP):** a `Peer` constructed via `Peer(name:peerID:host:port:)` carries an internal `tcpEndpoint` instead. `connectToServer(_:)` dials that address directly over a TLS-wrapped `NWConnection`, bypassing Bonjour discovery entirely. The advertiser must have been started with `startPublishing(alsoAvailableViaTCP: true)`, listening on the `tcpPort` given to `PeerAdvertiser.init` (default `8888`) — the browser must be told this port out-of-band, the same way `serviceType` must match on both sides today.

A `Peer` can carry either identifier but not both in practice — whichever path created it determines which one gets set.

### Security model

The TCP/TLS listener presents a fresh, ephemeral, **self-signed** identity (P-256, generated via `apple/swift-certificates`, regenerated per `PeerAdvertiser` instance — not persisted). There is no certificate authority in this peer-to-peer model, so the connecting side's TLS verify block accepts the peer's certificate unconditionally rather than validating a trust chain.

This means TCP/TLS encrypts the wire but does **not** authenticate the remote peer's identity via PKI. That's an intentional match to MultipeerConnectivity's own security model: MC's built-in encryption doesn't tie into app-level identity verification either. In both transports, the actual authorization boundary is `PeerAdvertiserDelegate.allowConnectionRequest(_:requestResponse:)` — that's where an app should make its real trust decision (e.g. comparing `remotePeer.peerID` against a known allowlist), not the certificate.

---

## Preventing parallel/duplicate sessions

A device running both a `PeerAdvertiser` and a `PeerBrowser` can race with a peer doing the same thing: A's browser invites B while B's browser invites A at nearly the same time ("glare"). Without coordination, both invitations can be accepted, leaving each device with two independent `PeerSession`s to the same logical peer instead of one.

`PeerSessionCoordinator` prevents this. Construct one per local peer identity and share it between that device's `PeerAdvertiser` and `PeerBrowser`:

```swift
let coordinator = PeerSessionCoordinator(localPeerID: myPeer.peerID)
let advertiser = PeerAdvertiser(serviceType: "myapp", serverPeer: myPeer, sessionCoordinator: coordinator, delegate: self)
let browser = PeerBrowser(serviceType: "myapp", clientPeer: myPeer, sessionCoordinator: coordinator, delegate: self)
```

If omitted, each of `PeerAdvertiser`/`PeerBrowser` creates its own private coordinator — which still refuses a redundant second attempt at a peer it's already connected to, just without resolving a race against the *other* role on the same device.

**How it decides:** per remote `peerID`, the coordinator tracks nothing, an in-flight outbound attempt, an in-flight inbound attempt, or an established session.

- A new attempt while already `established` is refused outright — no negotiation needed.
- A new attempt in the *same* direction as one already in flight (e.g. `connectToServer` called twice before either resolves) is refused as a plain duplicate.
- A new attempt in the *opposite* direction from one already in flight (real glare) is resolved by comparing `peerID`s: whichever peer's `peerID` is lexicographically greater is that pair's "initiator" — its outbound attempt wins. Both peers compute this from the same two `peerID`s, so they converge on keeping the *same* one of the two racing connections without exchanging any extra messages. (A naive "whoever finishes first, locally" rule doesn't work here: since the two racing attempts are two independent connections spanning both devices, each side resolving independently by local timing could each keep the *opposite* connection, tearing down both.)

When an attempt is refused this way, `allowConnectionRequest`/dialing never happens for it — the app's delegate instead gets `duplicateConnectionRejected(_:)` (default no-op; implement it if you want visibility, e.g. for logging).

---

## Combine

Every delegate method also has a matching, discrete Combine publisher — pick whichever style suits a given call site, or mix both (a publisher fires at exactly the same point, on exactly the same thread, as its delegate counterpart, since the `send(...)` call sits right next to the `delegate?.method(...)` call at each event site). None of this changes the delegate protocols or their existing behavior.

**`PeerAdvertiser`:**
```swift
public let errorPublisher: AnyPublisher<PeerConnectError, Never>
public let connectionRequestPublisher: AnyPublisher<PeerConnectionRequest, Never>
public let clientConnectedPublisher: AnyPublisher<PeerSession, Never>
```

**`PeerBrowser`** (also conforms to `ObservableObject`):
```swift
@Published public private(set) var nearbyServers: [Peer]

public let errorPublisher: AnyPublisher<PeerConnectError, Never>
public let serverFoundPublisher: AnyPublisher<Peer, Never>
public let serverLostPublisher: AnyPublisher<Peer, Never>
public let unableToConnectPublisher: AnyPublisher<Peer, Never>
public let connectionDeniedPublisher: AnyPublisher<Peer, Never>
public let connectedPublisher: AnyPublisher<PeerSession, Never>
public let duplicateConnectionRejectedPublisher: AnyPublisher<Peer, Never>
```

**`PeerSession`:**
```swift
public let disconnectedPublisher: AnyPublisher<Bool, Never>              // byRequest
public let textReceivedPublisher: AnyPublisher<String, Never>
public let dataReceivedPublisher: AnyPublisher<Data, Never>
public let startedReceivingResourcePublisher: AnyPublisher<PeerReceivingResourceEvent, Never>
public let resourceReceivedPublisher: AnyPublisher<PeerReceivedResourceEvent, Never>
```
`disconnectedPublisher`'s payload is just `byRequest` — unlike `PeerSessionDelegate.disconnected(_:byRequest:)`, there's no redundant `session` parameter, since a subscriber already holds the `PeerSession` instance it subscribed on.

### `allowConnectionRequest` as a value: `PeerConnectionRequest`

`PeerAdvertiserDelegate.allowConnectionRequest(_:requestResponse:)` takes a completion-handler closure, which doesn't translate directly into a "fire and forget" publisher — accepting or rejecting is exactly the kind of side effect Combine publishers shouldn't perform inline. Instead, `connectionRequestPublisher` emits a `PeerConnectionRequest`:

```swift
public struct PeerConnectionRequest {
    public let remotePeer: Peer
    public func accept()
    public func reject()
}
```

Both the delegate callback and the published `PeerConnectionRequest` for a given inbound attempt are backed by the same underlying answer, guarded so only the first call — whichever path gets there first — actually takes effect (see `OneShotResponder` in `PeerAdvertiser.swift`). This means an app can implement `allowConnectionRequest` *or* subscribe to `connectionRequestPublisher` *or* both, without risk of double-answering a request.

### Errors: `PeerConnectError`

`advertiserError`/`browserError` keep their existing `[String: Any]` shape for delegate consumers. `errorPublisher` on both classes instead emits a small `PeerConnectError: Error, Equatable { public let message: String }` — a cleaner value type for the reactive-only surface, built from the same underlying error message at each call site.

---

## Public API reference

### `Peer`

Represents a participant. Equality and hashing are based solely on `peerID`, so a peer can be tracked across name changes.

```swift
public final class Peer: Equatable, Hashable, @unchecked Sendable {
    public let name: String      // Display name
    public let peerID: String    // Stable app-assigned identifier (e.g. a UUID string)

    public init(name: String, peerID: String)

    /// Targets a direct TCP/TLS connection at host:port instead of MC discovery.
    public init(name: String, peerID: String, host: String, port: UInt16)

    // Serialize/deserialize for transmission as MC discovery info/invitation context,
    // or as the first frame on a fresh TCP connection.
    public init?(dataValue: Data)
    public func dataValue() -> Data
}
```

`dataValue()` encodes the peer as `{"name": "…", "peerID": "…"}` JSON. `init?(dataValue:)` is the corresponding decoder; it returns `nil` if the data is malformed.

`mcPeerID` (internal `MCPeerID?`) is set by `PeerBrowser` when a remote peer is found during discovery. `tcpEndpoint` (internal `(host: String, port: UInt16)?`) is set directly by `init(name:peerID:host:port:)`. One or the other must be present before `connectToServer(_:)` will act on the peer.

---

### `PeerAdvertiser`

Manages the server side of a connection. One instance covers one service type. Multiple concurrent client connections are supported — each gets its own `PeerSession`.

```swift
public final class PeerAdvertiser: NSObject, @unchecked Sendable {
    public weak var delegate: PeerAdvertiserDelegate?

    // Combine equivalents of the delegate methods below — see "Combine" section above.
    public let errorPublisher: AnyPublisher<PeerConnectError, Never>
    public let connectionRequestPublisher: AnyPublisher<PeerConnectionRequest, Never>
    public let clientConnectedPublisher: AnyPublisher<PeerSession, Never>

    /// serviceType: ASCII letters, digits, and hyphens only; max 15 chars. Example: "myapp"
    /// Do NOT use Bonjour format (_xxx._tcp).
    /// tcpPort: port the TCP/TLS listener binds to if TCP is ever enabled (default 8888).
    /// Browsers connecting via Peer(name:peerID:host:port:) must use this same port.
    /// sessionCoordinator: share one with this device's PeerBrowser to prevent parallel
    /// sessions with a peer that's also advertising and browsing. Defaults to a private instance.
    public init(serviceType: String, serverPeer: Peer, tcpPort: UInt16 = 8888, sessionCoordinator: PeerSessionCoordinator? = nil, delegate: PeerAdvertiserDelegate?)

    /// alsoAvailableViaTCP: when true, also starts a TLS-wrapped TCP listener on tcpPort.
    @discardableResult
    public func startPublishing(alsoAvailableViaTCP: Bool = false) -> Bool
    public func stopPublishing()
}
```

#### `PeerAdvertiserDelegate`

```swift
public protocol PeerAdvertiserDelegate: AnyObject {
    /// The advertiser failed to start. Inspect errorDict["error"] for the description.
    func advertiserError(_ errorDict: [String: Any])

    /// A remote peer is requesting a connection. Call requestResponse(true) to allow,
    /// requestResponse(false) to reject. The callback may be called on any thread.
    func allowConnectionRequest(_ remotePeer: Peer, requestResponse: @escaping ConnectionRequestResponse)

    /// The connection is fully established. The session is ready for use.
    func clientDidConnect(_ session: PeerSession)
}

extension PeerAdvertiserDelegate {
    /// An inbound attempt was refused by a shared PeerSessionCoordinator — either a
    /// plain duplicate, or the losing side of a simultaneous mutual-connect race.
    /// allowConnectionRequest is not called for a rejection like this. Default no-op.
    func duplicateConnectionRejected(_ remotePeer: Peer) {}
}
```

---

### `PeerBrowser`

Manages the client side of discovery and connection.

```swift
public final class PeerBrowser: NSObject, ObservableObject, @unchecked Sendable {
    public weak var delegate: PeerBrowserDelegate?
    @Published public private(set) var nearbyServers: [Peer]   // Currently visible advertising peers

    // Combine equivalents of the delegate methods below — see "Combine" section above.
    public let errorPublisher: AnyPublisher<PeerConnectError, Never>
    public let serverFoundPublisher: AnyPublisher<Peer, Never>
    public let serverLostPublisher: AnyPublisher<Peer, Never>
    public let unableToConnectPublisher: AnyPublisher<Peer, Never>
    public let connectionDeniedPublisher: AnyPublisher<Peer, Never>
    public let connectedPublisher: AnyPublisher<PeerSession, Never>
    public let duplicateConnectionRejectedPublisher: AnyPublisher<Peer, Never>

    /// serviceType must match the advertiser's serviceType exactly.
    /// sessionCoordinator: share one with this device's PeerAdvertiser to prevent parallel
    /// sessions with a peer that's also advertising and browsing. Defaults to a private instance.
    public init(serviceType: String, clientPeer: Peer, sessionCoordinator: PeerSessionCoordinator? = nil, delegate: PeerBrowserDelegate?)

    public func startBrowsing()
    public func stopBrowsing()

    /// server must be a Peer previously delivered via serverFound(_:), or one
    /// constructed via Peer(name:peerID:host:port:) to connect over TCP/TLS instead.
    public func connectToServer(_ server: Peer)
}
```

#### `PeerBrowserDelegate`

```swift
public protocol PeerBrowserDelegate: AnyObject {
    /// The browser failed to start. Inspect errorDict["error"] for the description.
    func browserError(_ errorDict: [String: Any])

    /// A new advertising peer appeared. Add it to your UI; call connectToServer(_:) to connect.
    func serverFound(_ server: Peer)

    /// A previously found peer is no longer visible.
    func serverLost(_ server: Peer)

    /// A connection attempt failed at the transport level (timeout, no response, etc.).
    func unableToConnect(_ server: Peer)

    /// The advertiser explicitly denied the connection request.
    func connectionDenied(_ server: Peer)

    /// The connection is fully established. The session is ready for use.
    func connected(_ session: PeerSession)
}

extension PeerBrowserDelegate {
    /// connectToServer(_:) was refused by a shared PeerSessionCoordinator — either a
    /// plain duplicate, or the losing side of a simultaneous mutual-connect race.
    /// Default no-op.
    func duplicateConnectionRejected(_ server: Peer) {}
}
```

---

### `PeerSession`

Represents one active, bidirectional connection. Created internally by `PeerAdvertiser` and `PeerBrowser`; never instantiated directly by callers.

```swift
public final class PeerSession: NSObject, @unchecked Sendable {
    public weak var delegate: PeerSessionDelegate?
    public var delegateQueue: DispatchQueue   // Default: DispatchQueue.main
    public let remotePeer: Peer              // The peer on the other end

    // Combine equivalents of PeerSessionDelegate — see "Combine" section above.
    // disconnectedPublisher's payload is just byRequest (no redundant session param).
    public let disconnectedPublisher: AnyPublisher<Bool, Never>
    public let textReceivedPublisher: AnyPublisher<String, Never>
    public let dataReceivedPublisher: AnyPublisher<Data, Never>
    public let startedReceivingResourcePublisher: AnyPublisher<PeerReceivingResourceEvent, Never>
    public let resourceReceivedPublisher: AnyPublisher<PeerReceivedResourceEvent, Never>

    public func sendText(_ text: String)
    public func sendData(_ data: Data)

    /// Transfer a file. Returns a Progress for tracking. The discardable return value
    /// is a sentinel Progress(totalUnitCount: -1) when MC cannot start the transfer.
    @discardableResult
    public func sendResourceAtURL(
        _ url: URL,
        name: String,
        resourceID: String,
        onCompletion: @escaping SendCompletionHandler
    ) -> Progress

    public func disconnect()
}
```

#### `PeerSessionDelegate`

```swift
public protocol PeerSessionDelegate: AnyObject {
    /// The connection dropped. byRequest is true when disconnect() was called locally.
    func disconnected(_ session: PeerSession, byRequest: Bool)

    func textReceived(_ session: PeerSession, text: String)
    func dataReceived(_ session: PeerSession, data: Data)

    /// Called when a file transfer begins. atURL is where the file will land when complete.
    /// progress is updated continuously by the framework.
    func startedReceivingResource(
        _ session: PeerSession, atURL: URL, name: String,
        resourceID: String, progress: Progress)

    /// Called when the file has been moved to atURL in the Documents directory.
    func resourceReceived(
        _ session: PeerSession, atURL: URL, name: String, resourceID: String)
}
```

#### Typealiases

```swift
public typealias ConnectionRequestResponse = (_ allow: Bool) -> Void
public typealias SendCompletionHandler     = (_ sent: Bool) -> Void
```

---

## Connection lifecycle

### Advertiser side

```
startPublishing()
    └─ MCNearbyServiceAdvertiser starts broadcasting on the local network

Incoming invitation from browser
    └─ advertiser(_:didReceiveInvitationFromPeer:withContext:invitationHandler:)
         ├─ Decode Peer from context data
         ├─ Create MCSession (per-connection, encryption required)
         ├─ Store PendingEntry { session, peer, invitationHandler }
         └─ Call allowConnectionRequest on delegate
              ├─ allow == false → invitationHandler(false, nil); remove pending entry
              └─ allow == true  → invitationHandler(true, session)
                   └─ MCSession negotiates…
                        └─ session(_:peer:didChangeState:) → .connected
                             ├─ Send PeerMessage.handshake(accepted: true) over the wire
                             ├─ Remove pending entry
                             ├─ Create PeerSession; transfer MCSession delegate ownership
                             └─ Call clientDidConnect(_:) on delegate
```

### Browser side

```
startBrowsing()
    └─ MCNearbyServiceBrowser scans for peers advertising the same serviceType

Peer found
    └─ browser(_:foundPeer:withDiscoveryInfo:)
         ├─ Decode peerID from discoveryInfo
         ├─ Create Peer; attach mcPeerID
         ├─ Append to nearbyServers
         └─ Call serverFound(_:) on delegate

connectToServer(_:)
    ├─ Create MCSession (encryption required)
    ├─ Store PendingEntry { session, peer }
    └─ browser.invitePeer(_:to:withContext:timeout:30)
         └─ Context = localPeer.dataValue() (JSON-encoded)

Waiting for handshake
    ├─ session(_:peer:didChangeState:) → .notConnected (before handshake)
    │    └─ Remove pending entry; call unableToConnect(_:)
    └─ session(_:didReceive:fromPeer:)
         └─ Decode PeerMessage.handshake
              ├─ accepted == false → disconnect(); call connectionDenied(_:)
              └─ accepted == true
                   ├─ Remove pending entry
                   ├─ Create PeerSession; transfer MCSession delegate ownership
                   └─ Call connected(_:) on delegate
```

---

### TCP/TLS lifecycle

Mirrors the MC lifecycle above, with the initial `Peer.dataValue()` "context" and the `PeerMessage.handshake(accepted:)` reply sent as explicit framed messages (raw TCP has no invitation-context/session-delegate concept to piggyback on):

```
Advertiser side                              Browser side
────────────────                             ────────────
startPublishing(alsoAvailableViaTCP: true)
  └─ NWListener starts on tcpPort,
     presenting the ephemeral self-signed
     identity via TLS

                                              connectToServer(_:) on a Peer with tcpEndpoint
                                                └─ NWConnection dials host:port
                                                   with TLS (accepts the peer's
                                                   self-signed cert unconditionally)

Inbound connection accepted
  └─ First frame received, decoded as
     Peer.dataValue() (not a PeerMessage)
       ├─ malformed → cancel connection
       └─ ok → store pending entry,
              call allowConnectionRequest
                                              On .ready: sends Peer.dataValue()
                                              as the first frame, then awaits
                                              the handshake frame

allowConnectionRequest resolves
  ├─ deny → send handshake(accepted:false),
  │         cancel connection
  └─ allow → send handshake(accepted:true),
             wrap connection in TCPTransport,
             create PeerSession,
             call clientDidConnect(_:)
                                              Receives handshake frame
                                                ├─ accepted:false → cancel,
                                                │   call connectionDenied(_:)
                                                └─ accepted:true → wrap connection
                                                    in TCPTransport, create
                                                    PeerSession, call connected(_:)
```

A connection that fails or is refused before the handshake resolves (`.failed`/`.waiting`, e.g. connection-refused) is reported via `unableToConnect(_:)` on the browser side — PeerConnect doesn't retry automatically on either transport.

---

## Internal wire format — `PeerMessage`

`PeerMessage` is **internal** (not `public`). Callers never interact with it directly.

```
{ "type": "text",          "payload": "<string>" }
{ "type": "data",          "payload": "<base64>" }
{ "type": "handshake",     "accepted": true|false }
{ "type": "resourceStart", "resourceID": "<string>", "name": "<string>", "totalBytes": <int> }
{ "type": "resourceChunk", "resourceID": "<string>", "chunk": "<base64>" }
{ "type": "resourceEnd",   "resourceID": "<string>" }
```

The `handshake` case is consumed during connection setup by `PeerAdvertiser` (sender) and `PeerBrowser` (receiver) on both transports. By the time a `PeerSession` is handed to the delegate, the handshake has already been processed and `PeerSession` will silently drop any duplicate handshake messages it receives.

The `resource*` cases exist only because `TCPTransport` has no MC-style built-in resource-transfer primitive and must chunk files by hand (see [Resource transfer encoding](#resource-transfer-encoding) below). `MCTransport` never produces or expects them — MC's own `sendResource`/`didStartReceivingResourceWithName`/`didFinishReceivingResourceWithName` handle that transfer natively.

---

## Resource transfer encoding

`MCSession` identifies resources by a plain `String` name. PeerConnect encodes both a caller-supplied `resourceID` and the filename into that string using ASCII Unit Separator (U+001C) as a delimiter:

```
"<resourceID>\u{001C}<filename>"
```

U+001C cannot appear in UUIDs or typical filenames, making it a safe unambiguous separator. The receiver splits on the first occurrence to recover both values independently. This encoding is transport-agnostic: `TCPTransport` constructs the same `"<resourceID>\u{001C}<name>"` string when reporting `resourceStart`/`resourceEnd` events, so `PeerSession`'s parsing/Documents-move logic (below) is identical regardless of which transport delivered the resource.

Received files are moved from the transport's temporary staging location to a unique path inside the app's Documents directory. If a file with the same name already exists, a numeric suffix (`-1`, `-2`, …) is appended before the extension.

For MC, the temporary staging location is managed by `MCSession` itself. For TCP, `TCPTransport` has no such primitive: sending chunks a file by hand into fixed-size (64KB) `resourceChunk` frames after a `resourceStart` header and before a `resourceEnd` trailer, using a `Progress` object it updates as each chunk's send completes; on receive, it stages incoming bytes into a temp file under `FileManager.default.temporaryDirectory` and hands that URL to `PeerSession` on `resourceEnd`, exactly as MC hands over its own staging URL.

---

## Thread safety

`PeerAdvertiser`, `PeerBrowser`, and `PeerSession` all use `NSLock` to protect their mutable state (`pendingConnections`, `nearbyServers`, `resourceDestinations`, `disconnecting`). `TCPTransport` follows the same convention for its own state (`incomingResources`, `disconnecting`), and `PeerAdvertiser`/`PeerBrowser` extend their existing lock to also guard their TCP pending-connection dictionaries.

`PeerSession` dispatches all delegate calls onto `delegateQueue` (default `DispatchQueue.main`). Callers can set `delegateQueue` to a background queue before the first callback fires if main-thread delivery is not appropriate.

MC framework callbacks for `PeerAdvertiser` and `PeerBrowser` arrive on arbitrary threads; all shared-state accesses within those callbacks are lock-guarded. `NWListener`/`NWConnection` callbacks for the TCP path run on a dedicated serial `DispatchQueue` per `PeerAdvertiser`/`PeerBrowser` instance, with the same lock-guarding discipline.

---

## Usage example

```swift
// --- Server ---
let serverPeer = Peer(name: "My Server", peerID: UUID().uuidString)
let advertiser = PeerAdvertiser(serviceType: "myapp", serverPeer: serverPeer, delegate: self)
advertiser.startPublishing()

// PeerAdvertiserDelegate
func allowConnectionRequest(_ remotePeer: Peer, requestResponse: @escaping ConnectionRequestResponse) {
    requestResponse(true) // always accept for this example
}
func clientDidConnect(_ session: PeerSession) {
    session.delegate = self
    session.sendText("Hello from server")
}

// --- Client ---
let clientPeer = Peer(name: "My Client", peerID: UUID().uuidString)
let browser = PeerBrowser(serviceType: "myapp", clientPeer: clientPeer, delegate: self)
browser.startBrowsing()

// PeerBrowserDelegate
func serverFound(_ server: Peer) {
    browser.connectToServer(server)
}
func connected(_ session: PeerSession) {
    session.delegate = self
}

// PeerSessionDelegate (shared by both sides)
func textReceived(_ session: PeerSession, text: String) {
    print("Received:", text)
}
func disconnected(_ session: PeerSession, byRequest: Bool) {
    print("Disconnected, byRequest:", byRequest)
}
```

### Connecting over TCP/TLS instead of MC discovery

```swift
// --- Server ---
let advertiser = PeerAdvertiser(serviceType: "myapp", serverPeer: serverPeer, tcpPort: 8888, delegate: self)
advertiser.startPublishing(alsoAvailableViaTCP: true)

// --- Client, given a known IP address ---
let target = Peer(name: "My Server", peerID: knownServerPeerID, host: "192.168.1.42", port: 8888)
browser.connectToServer(target) // same PeerBrowserDelegate/PeerSessionDelegate callbacks as the MC path
```

### Combine, instead of (or alongside) the delegates

```swift
var cancellables = Set<AnyCancellable>()

// --- Server ---
advertiser.connectionRequestPublisher
    .sink { request in request.accept() } // or request.reject()
    .store(in: &cancellables)

advertiser.clientConnectedPublisher
    .sink { session in
        session.sendText("Hello from server")
    }
    .store(in: &cancellables)

// --- Client ---
browser.$nearbyServers
    .sink { servers in /* update SwiftUI list, etc. */ }
    .store(in: &cancellables)

browser.connectedPublisher
    .sink { session in
        session.textReceivedPublisher
            .sink { text in print("Received:", text) }
            .store(in: &cancellables)
    }
    .store(in: &cancellables)
```
