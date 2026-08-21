// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "swift-et-transport",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "OpenPawETTransport", targets: ["OpenPawETTransport"])],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.11.0")
    ],
    targets: [
        .target(name: "OpenPawETTransport", dependencies: [.product(name: "Sodium", package: "swift-sodium")]),
        .testTarget(name: "OpenPawETTransportTests", dependencies: ["OpenPawETTransport"])
    ]
)
