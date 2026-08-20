import AppKit
import CoreGraphics
import Foundation
import ImageIO
import OpenPawUI
import SwiftUI

// MARK: - Why NSHostingView, not ImageRenderer
//
// `ImageRenderer` does not draw the contents of a `ScrollView`. The scroll view's own background, frame and overlays
// render; every child inside it comes out empty. This was isolated with four variants rendered into one image:
//
//   (a) `CodeBlock(...)`                          → blank well
//   (b) the identical `Text(AttributedString)`, no ScrollView → renders fully
//   (c) `CodeBlock(isCopyable: false)`            → blank
//   (d) a bare `ScrollView(.horizontal) { Text("…") }` → blank
//
// So it is the `ScrollView`, not the components, not the syntax highlighter, and not `AttributedString`.
//
// That makes `ImageRenderer` unusable for this tool in the worst possible way. `CodeBlock` and `ScrollbackTextView`
// both scroll internally, and nearly every screen in OpenPaw is inside a `ScrollView`, so an `ImageRenderer` snapshot
// set would come out uniformly blank while looking perfectly stable from run to run — a verification tool that reports
// success while showing nothing.
//
// Rendering through a real `NSHostingView` and `cacheDisplay(in:to:)` goes down AppKit's ordinary display path, which
// draws scroll view contents. The same `CodeBlock` then renders completely: text, line-number gutter, highlighted-line
// bar and syntax colours. On iOS the equivalent host is `UIHostingView`.
//
// Credit: isolated by the UIFoundation slice during this build. Do not "simplify" this back to `ImageRenderer`.
//
// MARK: - What this tool cannot verify
//
// Dynamic Type. A macOS render has no `UIContentSizeCategory`, so these PNGs are always at the default text size and
// a frozen type scale is invisible in every one of them. That is not hypothetical: the theme's twelve type tokens were
// originally `Font.system(size:)`, which is not text-style anchored and therefore cannot track the content size
// category at all, and no snapshot in this set would ever have shown it. They are now
// `Font.system(_:design:weight:)`, which is anchored.
//
// The real check is to launch an iOS build with
//
//     -UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL
//
// and diff the result against the default run: rows must grow, nothing may clip, and no text may truncate. Until that
// runs on a device or simulator, Dynamic Type in this app is correct by construction and unverified in fact.

/// One rendered device class. Point size plus scale, because a screen that is correct at 1x and broken at 3x is
/// broken — the machine register is monospaced type on hairlines, and hairlines are where scale bugs show up.
struct DeviceProfile: Sendable {
    let name: String
    let size: CGSize
    let scale: CGFloat

    /// iPhone 15/16 logical size. The narrowest layout the product supports, so it is where the two-register
    /// typography either fits or does not.
    static let iPhone = DeviceProfile(name: "iphone", size: CGSize(width: 393, height: 852), scale: 3)
    /// iPad Pro 12.9 portrait, the widest layout, where the regular-width multi-pane shell appears.
    static let iPad = DeviceProfile(name: "ipad", size: CGSize(width: 1_024, height: 1_366), scale: 2)

    static let all: [DeviceProfile] = [.iPhone, .iPad]
}

/// One written file, plus the measurement that decides whether it is worth anything.
struct Rendered: Sendable {
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    /// Fraction of sampled pixels that differ from the most common sampled colour.
    let inkCoverage: Double
    let distinctSampledColours: Int

    /// Minimum fraction of sampled pixels that must differ from the modal colour, and minimum number of distinct
    /// sampled colours.
    ///
    /// Both are calibrated against measurements from this repo rather than guessed:
    ///
    ///   - a flat frame (the `ImageRenderer` failure mode) samples one or two colours and ~0% coverage;
    ///   - a screen caught mid-load, drawing only its header and a progress line, measured 0.165–0.171%;
    ///   - a legitimately sparse empty state — a serif headline and two lines of direction on a 1024x1366 iPad
    ///     canvas — measured 0.470%.
    ///
    /// So the floor sits at 0.2%, which separates "only chrome drew" from "a real empty state drew", and the colour
    /// count catches a flat fill outright. A single fraction cannot do both jobs, because coverage is diluted by canvas
    /// area: the same empty state that is obviously fine on an iPhone looks near-blank on an iPad.
    static let minimumInkCoverage = 0.002
    static let minimumDistinctColours = 4

    var isBlank: Bool {
        byteCount == 0
            || distinctSampledColours < Self.minimumDistinctColours
            || inkCoverage < Self.minimumInkCoverage
    }

    var blankReason: String? {
        if byteCount == 0 { return "zero bytes" }
        if distinctSampledColours < Self.minimumDistinctColours {
            return "only \(distinctSampledColours) distinct sampled colour(s) — the frame is a flat fill"
        }
        if inkCoverage < Self.minimumInkCoverage {
            return String(
                format: "only %.3f%% of sampled pixels differ from the background",
                inkCoverage * 100
            )
        }
        return nil
    }
}

/// A render that could not be attempted, with the reason. Distinct from a blank render, which is a failure.
struct Skipped: Sendable {
    let name: String
    let reason: String
}

enum SnapshotError: Error, CustomStringConvertible {
    case missingOutputDirectory
    case renderFailed(String)
    case encodeFailed(String)

    var description: String {
        switch self {
        case .missingOutputDirectory:
            "usage: openpaw-snapshot --output <directory>"
        case .renderFailed(let name):
            "AppKit produced no bitmap for \(name)"
        case .encodeFailed(let name):
            "could not encode a PNG for \(name)"
        }
    }
}

// MARK: - Renderer

@MainActor
struct SnapshotRenderer {

    let outputDirectory: URL

    /// Renders one view through a real host view and writes it.
    ///
    /// Dark appearance is applied twice on purpose: through the SwiftUI environment, which is what the views read, and
    /// through the hosting window's `NSAppearance`, which is what AppKit-backed material and control rendering reads.
    /// `preferredColorScheme` is deliberately not used — it is a request to the presenting scene, and there is none
    /// here, so it would be a silent no-op and produce a light-mode snapshot set nobody notices until review.
    ///
    /// Asynchronous on purpose. Screens load through `.task { … }`, so capturing straight after the first layout pass
    /// photographs the loading state — `AuditView` came out as nothing but its "Reading the audit log" line until this
    /// settled first. The loop below drains the main run loop and yields to the main actor until the frame stops being
    /// mostly background, which turns "wait long enough" into an observed condition instead of a guessed sleep.
    func render(
        _ content: some View,
        name: String,
        device: DeviceProfile
    ) async throws -> Rendered {
        let bounds = CGRect(origin: .zero, size: device.size)
        let host = NSHostingView(
            rootView: content
                .environment(\.colorScheme, .dark)
                .frame(width: device.size.width, height: device.size.height)
                .background(OpenPawTheme.ink)
        )
        host.frame = bounds

        // A window makes layout and appearance deterministic: without one, `NSAppearance.currentDrawing` falls back to
        // the process default and dynamic system colours resolve for light mode.
        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        // The rep's pixel dimensions and its `size` in points are what give the render its scale factor, so this is how
        // @2x and @3x are obtained without a Retina screen attached.
        func capture() throws -> (data: Data, image: CGImage, measurement: (coverage: Double, distinct: Int)) {
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(device.size.width * device.scale),
                    pixelsHigh: Int(device.size.height * device.scale),
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                )
            else { throw SnapshotError.renderFailed("\(name)@\(device.name)") }
            rep.size = device.size
            host.cacheDisplay(in: bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]), let image = rep.cgImage else {
                throw SnapshotError.encodeFailed("\(name)@\(device.name).png")
            }
            return (data, image, measure(image))
        }

        // Settle until the frame stops changing, not until something merely draws.
        //
        // Using ink coverage as the stop condition was wrong and produced a whole set of loading-state photographs:
        // `DiffViewerView` crossed the coverage floor while still showing "Reading the diff", so the loop exited and
        // captured the spinner. Frame stability is the right signal — a screen that has finished its `.task` work
        // renders byte-identically twice in a row, while one still loading does not.
        var shot = try capture()
        var previous = Data()
        var stableRepeats = 0
        var passes = 0
        // 60 passes at 25 ms is 1.5 s of settling, bounded so a screen with a live animation cannot hang the run; it
        // just stops at the cap with whatever frame it had, and the blank check still judges it.
        while passes < 60 {
            pumpRunLoop(for: 0.02)
            try? await Task.sleep(for: .milliseconds(5))
            host.layoutSubtreeIfNeeded()
            previous = shot.data
            shot = try capture()
            passes += 1
            stableRepeats = shot.data == previous ? stableRepeats + 1 : 0
            // Three identical frames and something actually on screen: nothing further is coming.
            if stableRepeats >= 3, shot.measurement.coverage >= Rendered.minimumInkCoverage { break }
        }

        let url = outputDirectory.appendingPathComponent("\(name)@\(device.name).png")
        try shot.data.write(to: url, options: .atomic)

        return Rendered(
            url: url,
            pixelWidth: shot.image.width,
            pixelHeight: shot.image.height,
            byteCount: shot.data.count,
            inkCoverage: shot.measurement.coverage,
            distinctSampledColours: shot.measurement.distinct
        )
    }

    /// Drains AppKit's run-loop sources for one bounded slice.
    ///
    /// Deliberately a synchronous function: both `RunLoop.run(until:)` and `CFRunLoopRunInMode` are annotated
    /// unavailable from asynchronous contexts, because blocking a cooperative thread is normally a mistake. Here it is
    /// exactly what is wanted — the caller has nothing else to do but let AppKit lay out and draw — so the pump lives
    /// behind a sync boundary and the caller yields the main actor separately.
    private func pumpRunLoop(for seconds: TimeInterval) {
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, seconds, false)
    }

    /// Samples the rendered bitmap on a fixed grid and reports how much of it is not background.
    ///
    /// Sampling rather than reading every pixel: a 3072x2556 frame is 7.8 million pixels, and the question being asked
    /// is answered just as well by a 128x128 grid spread over the whole frame — spread, not clustered, so a screen that
    /// drew only a navigation bar still measures as almost entirely background.
    private func measure(_ image: CGImage) -> (coverage: Double, distinct: Int) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return (0, 0) }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard
                let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        let samplesPerAxis = 128
        var counts: [UInt32: Int] = [:]
        counts.reserveCapacity(samplesPerAxis * samplesPerAxis)
        for row in 0..<samplesPerAxis {
            let y = min(height - 1, row * height / samplesPerAxis)
            for column in 0..<samplesPerAxis {
                let x = min(width - 1, column * width / samplesPerAxis)
                let offset = (y * width + x) * 4
                let packed =
                    UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8
                    | UInt32(bytes[offset + 2])
                counts[packed, default: 0] += 1
            }
        }
        let total = samplesPerAxis * samplesPerAxis
        let modal = counts.values.max() ?? total
        return (Double(total - modal) / Double(total), counts.count)
    }
}
