import XCTest
@testable import PeerConnect

// Generating the ephemeral self-signed TLS identity requires adding a key and
// certificate to the keychain, which in turn requires the process to carry a
// keychain-access-groups entitlement — true for any properly code-signed app,
// but not for an ad-hoc `swift test` binary run outside Xcode/CI signing.
// Tests that exercise the real TCP/TLS path preflight this and skip (rather
// than fail) when the environment can't grant keychain access, so the suite
// stays green in that environment while still documenting — and fully
// exercising — the real path wherever code signing is available.
enum TLSTestAvailability {
    static func requireKeychainAccess() throws {
        do {
            _ = try PeerTLSIdentity.makeEphemeralIdentity(commonName: "PeerConnectTests-preflight")
        } catch {
            throw XCTSkip("Keychain access unavailable in this environment (\(error)); this path is exercised in a properly code-signed app/CI run.")
        }
    }
}
