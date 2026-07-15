import Foundation
import Crypto
import X509
import Security
import Network

enum PeerTLSIdentityError: Error {
    case secKeyCreationFailed(String)
    case identityCreationFailed
}

// Generates an ephemeral, self-signed TLS identity for the TCP transport, and
// configures the accept-any verify block used on the connecting (browser)
// side. There is no CA in this peer-to-peer model: TLS here provides wire
// privacy only. Authorization is still enforced at the app level via
// PeerAdvertiserDelegate.allowConnectionRequest — the certificate is not a
// trust boundary, the same way MCSession's own encryption isn't one either.
enum PeerTLSIdentity {
    /// Builds a fresh P-256 self-signed identity, valid for 24 hours. Assembled entirely
    /// in-memory via `SecIdentityCreate` - no keychain storage or lookup involved, so this
    /// doesn't need keychain access (which a bare `swift test` process running outside
    /// Xcode/CI signing doesn't reliably have). Per-process/per-instance; never persisted.
    static func makeEphemeralIdentity(commonName: String) throws -> SecIdentity {
        let privateKey = P256.Signing.PrivateKey()

        let subjectName = try DistinguishedName {
            CommonName(commonName)
        }

        let now = Date()
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            KeyUsage(digitalSignature: true, keyEncipherment: true)
            try ExtendedKeyUsage([.serverAuth, .clientAuth])
        }

        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(privateKey.publicKey),
            notValidBefore: now.addingTimeInterval(-300),
            notValidAfter: now.addingTimeInterval(60 * 60 * 24),
            issuer: subjectName,
            subject: subjectName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(privateKey)
        )

        let secCertificate = try SecCertificate.makeWithCertificate(certificate)

        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        var keyCreationError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(
            privateKey.x963Representation as CFData,
            keyAttributes as CFDictionary,
            &keyCreationError
        ) else {
            let message = keyCreationError.map { String(describing: $0.takeUnretainedValue()) } ?? "unknown error"
            throw PeerTLSIdentityError.secKeyCreationFailed(message)
        }

        guard let identity = SecIdentityCreate(nil, secCertificate, secKey) else {
            throw PeerTLSIdentityError.identityCreationFailed
        }
        return identity
    }

    /// TLS options for the advertiser (server) side: presents `identity` during the handshake.
    static func serverParameters(identity: SecIdentity) -> NWParameters {
        let secIdentity = sec_identity_create(identity)!
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        return NWParameters(tls: options, tcp: NWProtocolTCP.Options())
    }

    /// TLS options for the browser (client) side: accepts the peer's
    /// self-signed certificate unconditionally — see the type-level doc
    /// comment for why that's an acceptable tradeoff here.
    static func clientParameters() -> NWParameters {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, _, verifyComplete in verifyComplete(true) },
            DispatchQueue(label: "com.peerconnect.tls-verify")
        )
        return NWParameters(tls: options, tcp: NWProtocolTCP.Options())
    }
}
