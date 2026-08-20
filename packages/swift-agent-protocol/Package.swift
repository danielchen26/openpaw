// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "swift-agent-protocol",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OpenPawProtocol", targets: ["OpenPawProtocol"])
    ],
    targets: [
        .target(
            name: "OpenPawProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OpenPawProtocolTests",
            dependencies: ["OpenPawProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
