// swift-tools-version: 6.0
import PackageDescription

// Measures how badly each dictation engine mishears the sentence this product exists to carry. Kept out of the
// app's own package graph on purpose: it pulls MLX and CoreML in, and `swift test` for the UI package must stay
// runnable on a machine with no model cache.
let package = Package(
    name: "dictation-cer",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "dictation-cer", targets: ["dictation-cer"])],
    dependencies: [
        .package(
            url: "https://github.com/soniqo/speech-swift",
            revision: "7b2d17fe2a607738e9cca63cd909c5101964dfc8")
    ],
    targets: [
        .executableTarget(
            name: "dictation-cer",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "ParakeetASR", package: "speech-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
