// swift-tools-version:3.1

import PackageDescription

var deps: [Package.Dependency] = [
	.Package(url: "https://github.com/pixelspark/sqlite.git", majorVersion: 3),
	.Package(url: "https://github.com/IBM-Swift/Kitura.git", majorVersion: 1, minor: 7),
	.Package(url: "https://github.com/jatoben/CommandLine",  "3.0.0-pre1"),
	.Package(url: "https://github.com/IBM-Swift/Kitura-Request.git", majorVersion: 0),
	.Package(url: "https://github.com/IBM-Swift/BlueCryptor.git", majorVersion: 0),
	.Package(url: "https://github.com/pixelspark/swift-parser-generator.git", majorVersion: 1),
	.Package(url: "https://github.com/IBM-Swift/HeliumLogger.git", majorVersion: 1),
	.Package(url: "https://github.com/IBM-Swift/Kitura-WebSocket", majorVersion: 0, minor: 8),
	.Package(url: "https://github.com/vzsg/ed25519.git", majorVersion: 0, minor: 1),
	.Package(url: "https://github.com/pixelspark/base58.git", majorVersion: 1),
	.Package(url: "https://github.com/Bouke/NetService.git", majorVersion: 0)
]

#if !os(Linux)
	// Starscream is used for outgoing WebSocket connections; unfortunately it is not available on Linux
	deps.append(.Package(url: "https://github.com/daltoniam/Starscream.git", majorVersion: 2))
#endif

let package = Package(
    name: "Catena",

    targets: [
		Target(
			name: "Catena",
			dependencies: ["CatenaCore", "CatenaSQL"]
		),
		Target(
			name: "CatenaSQL",
			dependencies: ["CatenaCore"]
		),
		Target(name: "CatenaCore")
	],

	dependencies: deps
)
