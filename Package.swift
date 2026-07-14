// swift-tools-version: 6.2
import PackageDescription

let package = Package(
	name: "PeerConnect",
	platforms: [
		.iOS(.v26),
		.macOS(.v26),
		.tvOS(.v26),
		.watchOS(.v26),
		.visionOS(.v26)
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
