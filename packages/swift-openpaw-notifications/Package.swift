// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-openpaw-notifications",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "OpenPawNotifications", targets: ["OpenPawNotifications"])
    ],
    targets: [
        .target(name: "OpenPawNotifications"),
        .testTarget(name: "OpenPawNotificationsTests", dependencies: ["OpenPawNotifications"])
    ]
)
