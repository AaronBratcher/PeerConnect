# PeerConnect

A Swift package that provides a simple, role-based API. It handles the session lifecycle, handshakes, delegate ownership transfers, and thread safety for you — you just work with `Peer`, `PeerSession`, and three small delegate protocols.

A second transport is also available: a direct TCP connection wrapped in TLS, for connecting to a known IP address instead of discovering peers over Bonjour. Both transports share the same API — see [Connecting over TCP/TLS instead](#connecting-over-tcptls-instead-of-mc-discovery) below.

**Supported platforms:** iOS 26+, macOS 26+, tvOS 26+, watchOS 26+, visionOS 26+

For a deep dive into internals (connection lifecycle, wire format, thread-safety model), see [ARCHITECTURE.md](Sources/PeerConnect/ARCHITECTURE.md).

---

## Installation

Add PeerConnect as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(path: "../PeerConnect") // or a git URL if hosted remotely
]
```

Then add `"PeerConnect"` to your target's dependencies:

```swift
.target(
    name: "MyApp",
    dependencies: ["PeerConnect"]
)
```

Or in Xcode: **File → Add Package Dependencies…** and point it at this package.

PeerConnect depends on [`apple/swift-certificates`](https://github.com/apple/swift-certificates) (and transitively `swift-crypto`/`swift-asn1`) to generate the ephemeral TLS identity used by the TCP transport; SPM resolves these automatically.

---

## Required Info.plist entries (iOS)

MultipeerConnectivity requires local network access and Bonjour service declarations, or your app will silently fail to advertise/browse. Add these to your app's `Info.plist` (not this package's — the *consuming* app's):

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app uses the local network to discover and connect to nearby devices.</string>

<key>NSBonjourServices</key>
<array>
    <string>_myapp._tcp</string>
    <string>_myapp._udp</string>
</array>
```

Replace `myapp` with the same `serviceType` string you pass to `PeerAdvertiser`/`PeerBrowser`, prefixed with `_` and suffixed with `._tcp`/`._udp`. The first time your app browses or advertises, iOS will prompt the user for local network permission.

---

## Core concepts

Every participant is either an **advertiser** (server) or a **browser** (client). A single process can run both roles at once if needed — share a `PeerSessionCoordinator` between them to avoid ending up with two parallel sessions to the same peer (see [Running both roles at once](#running-both-roles-at-once) below).

- `PeerAdvertiser` — publishes your presence on the network and accepts/rejects incoming connection requests.
- `PeerBrowser` — discovers nearby advertisers and initiates connections.
- `PeerSession` — the active, bidirectional connection created once both sides agree to connect. This is what you use to send/receive text, data, and files.
- `Peer` — a simple identity model (`name` + `peerID`) representing a network participant.

You never construct a `PeerSession` yourself — it's handed to you via delegate callbacks once a connection succeeds.

---

## Quick start

### Server (advertiser) side

```swift
import PeerConnect

let serverPeer = Peer(name: "My Server", peerID: UUID().uuidString)
let advertiser = PeerAdvertiser(serviceType: "myapp", serverPeer: serverPeer, delegate: self)
advertiser.startPublishing()
```

```swift
extension MyServerController: PeerAdvertiserDelegate {
    func allowConnectionRequest(_ remotePeer: Peer, requestResponse: @escaping ConnectionRequestResponse) {
        requestResponse(true) // or false to reject; can be called asynchronously
    }

    func clientDidConnect(_ session: PeerSession) {
        session.delegate = self
        session.sendText("Hello from server")
    }

    func advertiserError(_ errorDict: [String: Any]) {
        print("Advertiser failed:", errorDict["error"] ?? "unknown error")
    }
}
```

### Client (browser) side

```swift
import PeerConnect

let clientPeer = Peer(name: "My Client", peerID: UUID().uuidString)
let browser = PeerBrowser(serviceType: "myapp", clientPeer: clientPeer, delegate: self)
browser.startBrowsing()
```

```swift
extension MyClientController: PeerBrowserDelegate {
    func serverFound(_ server: Peer) {
        browser.connectToServer(server) // connect as soon as found, or show in UI first
    }

    func serverLost(_ server: Peer) {
        // Remove from UI list, if you're tracking one
    }

    func connected(_ session: PeerSession) {
        session.delegate = self
    }

    func unableToConnect(_ server: Peer) {
        print("Could not reach \(server.name)")
    }

    func connectionDenied(_ server: Peer) {
        print("\(server.name) rejected the connection")
    }

    func browserError(_ errorDict: [String: Any]) {
        print("Browser failed:", errorDict["error"] ?? "unknown error")
    }
}
```

### Shared: sending and receiving on a `PeerSession`

```swift
extension MyController: PeerSessionDelegate {
    func textReceived(_ session: PeerSession, text: String) {
        print("Received text:", text)
    }

    func dataReceived(_ session: PeerSession, data: Data) {
        print("Received \(data.count) bytes")
    }

    func startedReceivingResource(_ session: PeerSession, atURL: URL, name: String, resourceID: String, progress: Progress) {
        // Observe `progress` (e.g. bind to a progress bar) if you want live updates
    }

    func resourceReceived(_ session: PeerSession, atURL: URL, name: String, resourceID: String) {
        print("File \(name) saved to \(atURL)")
    }

    func disconnected(_ session: PeerSession, byRequest: Bool) {
        print("Disconnected, byRequest:", byRequest)
    }
}

// Sending:
session.sendText("hi there")
session.sendData(myData)
session.sendResourceAtURL(fileURL, name: "photo.jpg", resourceID: UUID().uuidString) { sent in
    print(sent ? "Sent successfully" : "Send failed")
}

// Tearing down:
session.disconnect()
```

---

## Connecting over TCP/TLS instead of MC discovery

If you'd rather connect to a specific IP address than discover peers over Bonjour, enable the TCP/TLS transport. Everything else — `PeerSession`, its delegate, `sendText`/`sendData`/`sendResourceAtURL`/`disconnect` — works exactly the same either way.

```swift
// --- Server ---
let advertiser = PeerAdvertiser(serviceType: "myapp", serverPeer: serverPeer, tcpPort: 8888, delegate: self)
advertiser.startPublishing(alsoAvailableViaTCP: true)
```

```swift
// --- Client, given a known IP address (and the same port the advertiser used) ---
let target = Peer(name: "My Server", peerID: knownServerPeerID, host: "192.168.1.42", port: 8888)
browser.connectToServer(target)
```

`PeerBrowserDelegate`/`PeerAdvertiserDelegate`/`PeerSessionDelegate` callbacks fire the same way as the MC path — `serverFound(_:)` just never fires for a manually-constructed `Peer` since there's no discovery step to skip.

**Security note:** the TCP listener presents a fresh, ephemeral, self-signed TLS identity — there's no certificate authority in this peer-to-peer model, so the connecting side accepts that certificate unconditionally rather than validating a trust chain. TLS here encrypts the wire; it does not authenticate the remote peer's identity. Your `allowConnectionRequest(_:requestResponse:)` implementation remains the real place to decide whether to trust an incoming connection (e.g. checking `remotePeer.peerID` against an allowlist) — for both transports.

---

## Running both roles at once

If your app runs a `PeerAdvertiser` and a `PeerBrowser` at the same time (a "symmetric peer" setup), you can race with another device doing the same thing: your browser invites them while their browser invites you, at nearly the same moment. Left alone, both invitations can be accepted, leaving each device with two separate `PeerSession`s to the same peer.

Share one `PeerSessionCoordinator` between your `PeerAdvertiser` and `PeerBrowser` to prevent this:

```swift
let coordinator = PeerSessionCoordinator(localPeerID: myPeer.peerID)
let advertiser = PeerAdvertiser(serviceType: "myapp", serverPeer: myPeer, sessionCoordinator: coordinator, delegate: self)
let browser = PeerBrowser(serviceType: "myapp", clientPeer: myPeer, sessionCoordinator: coordinator, delegate: self)
```

With a shared coordinator, a redundant or race-losing connection attempt is refused automatically — `allowConnectionRequest`/dialing never happens for it — and your delegate optionally learns why via `duplicateConnectionRejected(_:)` (default no-op if you don't implement it). If you don't share a coordinator, each of `PeerAdvertiser`/`PeerBrowser` still gets its own private one, which refuses a plain duplicate attempt at an already-connected peer on its own, just without resolving a race against your other role. See [ARCHITECTURE.md](Sources/PeerConnect/ARCHITECTURE.md#preventing-parallelduplicate-sessions) for how the tie-break works.

---

## Notes and gotchas

- **`serviceType`** must be ASCII letters, digits, and hyphens only, max 15 characters (e.g. `"myapp"`). Do **not** use Bonjour's `_xxx._tcp` format here — that belongs only in `Info.plist`. The advertiser and browser must use the exact same `serviceType` to find each other.
- **Delegate callbacks may arrive on a background thread.** `PeerSession` dispatches its delegate calls on `delegateQueue` (defaults to `DispatchQueue.main`), but `PeerAdvertiserDelegate` and `PeerBrowserDelegate` callbacks can arrive on arbitrary threads — dispatch to `.main` yourself in those callbacks if you're touching UI.
- **`connectToServer(_:)`** only works with a `Peer` your delegate received via `serverFound(_:)`, or one constructed via `Peer(name:peerID:host:port:)` to connect over TCP/TLS — either way it needs internal state attached that a bare `Peer(name:peerID:)` doesn't carry.
- **TCP/TLS `tcpPort`** must match between `PeerAdvertiser`'s `tcpPort` init parameter and the `port` passed to `Peer(name:peerID:host:port:)` on the browser side — the same way `serviceType` must match for MC.
- **Received files** land in your app's Documents directory automatically; if a name collision occurs, a numeric suffix (`-1`, `-2`, …) is appended.
- **Delegates are weakly held** (`weak var delegate`) — keep a strong reference to your `PeerAdvertiser`/`PeerBrowser`/`PeerSession` delegate elsewhere (e.g. a view controller or observable object) or callbacks will silently stop firing.
- **Running an advertiser and browser together?** Share a `PeerSessionCoordinator` between them (see [Running both roles at once](#running-both-roles-at-once)) or you may end up with two parallel sessions to the same peer.

---

## Running tests

```sh
swift test
```
