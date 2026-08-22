import XCTest

/// The translucent chrome, in the register of the Ghostty terminal this app is used beside.
///
/// These are pixel tests on purpose. Every question worth asking about glass is a question about what is on
/// screen — whether anything is actually behind it, whether the chrome covers what it claims to cover — and none
/// of it is visible to a query for buttons and frames.
final class GlassChromeUITests: XCTestCase {

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-openpaw-debug-seed-key", "/tmp/openpaw-sim-key",
            "-openpaw.settings.biometricGate", "<false/>",
        ]
        app.launch()
        return app
    }

    /// Nothing may show below the strip.
    ///
    /// Letting content pass behind translucent chrome is the point of it, but the strip is laid out inside the
    /// safe area while the content it floats over is not. That leaves the home-indicator band uncovered, so the
    /// content sliding under the strip reappears below it — a row of someone else's text sitting under the
    /// controls, which reads as a rendering fault rather than as depth.
    func testNothingShowsBelowTheStrip() throws {
        let app = launchedApp()
        XCTAssertTrue(app.buttons["Terminal"].waitForExistence(timeout: 15), "the app never came up")

        let shot = XCUIScreen.main.screenshot()
        let band = Self.brightestPixel(
            in: shot,
            // The home-indicator band, minus the middle where the system draws the indicator itself.
            bottomPoints: 30,
            excludingCentreFraction: 0.5
        )
        XCTAssertLessThan(
            band.luminance, 80,
            "something with luminance \(Int(band.luminance)) is drawn \(Int(band.pointsFromBottom)) points from "
                + "the bottom of the screen, below the strip: the chrome stops at the safe area while the content "
                + "behind it does not, so content passing under the strip comes back out beneath it"
        )
    }

    /// Content has to be visible through the chrome, or the blur is an expensive way to draw a flat colour.
    ///
    /// Measured as variation across the strip rather than as a specific colour. A translucent strip over a busy
    /// screen picks up whatever is behind it and stops being uniform; an opaque one is the same colour all the
    /// way across whatever it covers.
    func testTheStripIsTranslucentRatherThanASolidBar() throws {
        let app = launchedApp()
        XCTAssertTrue(app.buttons["Terminal"].waitForExistence(timeout: 15), "the app never came up")

        // The home screen has cards and a filled button near the bottom, so there is something to see through.
        let shot = XCUIScreen.main.screenshot()
        let spread = Self.verticalSpread(in: shot, bandFromBottomPoints: 30...86)
        XCTAssertGreaterThan(
            spread, 6,
            "the strip is the same colour all the way down (\(String(format: "%.1f", spread)) of variation), so "
                + "nothing behind it is showing through and the material is drawing over a flat fill"
        )
    }

    // MARK: Pixels

    private struct Brightest {
        let luminance: Double
        let pointsFromBottom: Double
    }

    private static func pixels(_ shot: XCUIScreenshot) -> (data: CFData, width: Int, height: Int, bpr: Int)? {
        guard let cg = shot.image.cgImage, let data = cg.dataProvider?.data else { return nil }
        return (data, cg.width, cg.height, cg.bytesPerRow)
    }

    /// The brightest pixel in a band across the bottom of the screen, ignoring the middle.
    private static func brightestPixel(
        in shot: XCUIScreenshot, bottomPoints: Double, excludingCentreFraction: Double
    ) -> Brightest {
        guard let (data, width, height, bpr) = pixels(shot),
            let base = CFDataGetBytePtr(data)
        else { return Brightest(luminance: 0, pointsFromBottom: 0) }

        let scale = Double(height) / (XCUIScreen.main.screenshot().image.size.height)
        let pixelScale = scale > 0 ? scale : 3
        let band = Int(bottomPoints * pixelScale)
        let margin = Int(Double(width) * (1 - excludingCentreFraction) / 2)

        var best = Brightest(luminance: 0, pointsFromBottom: 0)
        for y in max(0, height - band)..<height {
            for x in stride(from: 0, to: width, by: 2) {
                // Skip the middle, where the system draws the home indicator over everything.
                if x > margin && x < width - margin { continue }
                let p = base + y * bpr + x * 4
                let luminance = (Double(p[0]) + Double(p[1]) + Double(p[2])) / 3
                if luminance > best.luminance {
                    best = Brightest(
                        luminance: luminance, pointsFromBottom: Double(height - y) / pixelScale)
                }
            }
        }
        return best
    }

    /// How much the average row brightness varies down a band. Flat means opaque.
    private static func verticalSpread(in shot: XCUIScreenshot, bandFromBottomPoints: ClosedRange<Double>)
        -> Double
    {
        guard let (data, width, height, bpr) = pixels(shot), let base = CFDataGetBytePtr(data) else { return 0 }
        let pixelScale = 3.0
        var averages: [Double] = []
        for points in stride(from: bandFromBottomPoints.lowerBound, to: bandFromBottomPoints.upperBound, by: 2) {
            let y = height - Int(points * pixelScale)
            guard y >= 0, y < height else { continue }
            var total = 0.0
            var count = 0.0
            for x in stride(from: 0, to: width, by: 8) {
                let p = base + y * bpr + x * 4
                total += (Double(p[0]) + Double(p[1]) + Double(p[2])) / 3
                count += 1
            }
            if count > 0 { averages.append(total / count) }
        }
        guard let low = averages.min(), let high = averages.max() else { return 0 }
        return high - low
    }
}
