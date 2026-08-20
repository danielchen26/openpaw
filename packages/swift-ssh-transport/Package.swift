// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "swift-ssh-transport",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OpenPawSSH", targets: ["OpenPawSSH"])
    ],
    dependencies: [
        // swift-nio-ssh is pre-1.0, so pin to the next minor. 0.15.0 is the newest release.
        .package(url: "https://github.com/apple/swift-nio-ssh.git", .upToNextMinor(from: "0.15.0")),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.3"),
        // NIOSSH's key API is expressed in swift-crypto types (Curve25519, P256...), and the
        // bcrypt KDF needs SHA-512, so depend on it directly rather than transitively.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.1"),
        .package(name: "swift-terminal-core", path: "../swift-terminal-core"),
    ],
    targets: [
        .target(
            name: "OpenPawSSH",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                // AES-CTR / AES-CBC (for OpenSSH encrypted keys) and Curve25519 PKCS#8 PEM
                // support live in _CryptoExtras, not in the core Crypto module.
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "OpenPawTerminalCore", package: "swift-terminal-core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OpenPawSSHTests",
            dependencies: [
                "OpenPawSSH",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "OpenPawTerminalCore", package: "swift-terminal-core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
