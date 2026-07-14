import Foundation
import Crypto
import X509
import Security
import Network

enum PeerTLSIdentityError: Error {
    case keyImportFailed(OSStatus)
    case secKeyCreationFailed(String)
    case certificateImportFailed(OSStatus)
    case identityLookupFailed(OSStatus)
}

// Generates an ephemeral, self-signed TLS identity for the TCP transport, and
// configures the accept-any verify block used on the connecting (browser)
// side. There is no CA in this peer-to-peer model: TLS here provides wire
// privacy only. Authorization is still enforced at the app level via
// PeerAdvertiserDelegate.allowConnectionRequest — the certificate is not a
// trust boundary, the same way MCSession's own encryption isn't one either.
enum PeerTLSIdentity {
    /// Builds a fresh P-256 self-signed identity, valid for 24 hours, and
    /// imports it into the keychain (required for `Network` to reference it
    /// by `sec_identity_t`). Not persisted beyond the keychain item's
    /// lifetime; callers should treat this as a per-process/per-instance identity.
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

        // Keychain label unique to this identity so repeated calls (e.g. one
        // per PeerAdvertiser instance, or across test runs) don't collide.
        let label = "com.peerconnect.tcp-identity.\(UUID().uuidString)"

        let keyAddAttributes: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: secKey,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(keyAddAttributes as CFDictionary)
        let keyAddStatus = SecItemAdd(keyAddAttributes as CFDictionary, nil)
        guard keyAddStatus == errSecSuccess else {
            throw PeerTLSIdentityError.keyImportFailed(keyAddStatus)
        }

        let certAddAttributes: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: secCertificate,
            kSecAttrLabel as String: label
        ]
        SecItemDelete(certAddAttributes as CFDictionary)
        let certAddStatus = SecItemAdd(certAddAttributes as CFDictionary, nil)
        guard certAddStatus == errSecSuccess else {
            throw PeerTLSIdentityError.certificateImportFailed(certAddStatus)
        }

        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchItemList as String: [secCertificate] as CFArray
        ]
        var identityRef: CFTypeRef?
        let identityStatus = SecItemCopyMatching(identityQuery as CFDictionary, &identityRef)
        guard identityStatus == errSecSuccess, let identityRef else {
            throw PeerTLSIdentityError.identityLookupFailed(identityStatus)
        }
        return identityRef as! SecIdentity
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
