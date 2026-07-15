// swift-tools-version: 6.2
import PackageDescription

let package = Package(
	name: "PeerConnect",
	// Minimums are set by the platform-gated APIs PeerConnect actually calls, not by whatever
	// SDK happened to be current when this was written:
	//   - MultipeerConnectivity (MCSession et al.): iOS 7.0, macOS 10.10, tvOS 10.0, visionOS 1.0 -
	//     and it does not exist on watchOS at all, at any version, so watchOS can't be listed here.
	//   - Network (NWListener/NWConnection, used for the TCP/TLS transport): iOS 12.0, macOS 10.14, tvOS 12.0
	//   - Security's SecIdentityCreate (ephemeral TLS identity, see PeerTLSIdentity.swift): iOS 11.2, macOS 10.12, tvOS 11.2
	//   - Combine (PassthroughSubject/AnyPublisher on the public event publishers): iOS 13.0, macOS 10.15, tvOS 13.0
	// Combine's iOS/macOS/tvOS floor dominates all the others.
	platforms: [
		.iOS(.v13),
		.macOS(.v10_15),
		.tvOS(.v13),
		.visionOS(.v1)
	],
	products: [
		.library(name: "PeerConnect", targets: ["PeerConnect"])
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
		.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
	],
	targets: [
		.target(
			name: "PeerConnect",
			dependencies: [
				.product(name: "X509", package: "swift-certificates"),
				.product(name: "Crypto", package: "swift-crypto")
			],
			path: "PeerConnect/"
		),
		.testTarget(
			name: "PeerConnectTests",
			dependencies: ["PeerConnect"],
			path: "PeerConnectTests/"
		)
	]
)
