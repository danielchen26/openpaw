import CoreGraphics
import ImageIO
import XCTest

@testable import OpenPawApp

/// Proves the blur brush is destructive.
///
/// The failure this guards is the one every screenshot annotator ships first: draw a blurred rectangle on a layer
/// above the image and export the composite. It looks identical on screen and it leaks the secret to anyone who
/// reads the attachment with a tool that keeps layers, inspects the PDF, or simply gets the original file. The only
/// acceptable implementation destroys the pixels before encoding, so these tests assert on decoded bytes, not on a
/// view hierarchy.
final class RedactionTests: XCTestCase {

    // MARK: - Fixtures

    /// A bitmap whose "secret" region carries a high-frequency stripe pattern — the same thing that makes
    /// monospaced text legible — over a flat background.
    private func fixture(
        width: Int = 200,
        height: Int = 120,
        secret: CGRect
    ) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.35, green: 0.36, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // `secret` is given top-left; CGContext fills bottom-left, so flip once here.
        let flipped = CGRect(
            x: secret.minX,
            y: CGFloat(height) - secret.maxY,
            width: secret.width,
            height: secret.height
        )
        var x = flipped.minX
        while x < flipped.maxX {
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: x, y: flipped.minY, width: 1, height: flipped.height))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: x + 1, y: flipped.minY, width: 1, height: flipped.height))
            x += 2
        }
        return context.makeImage()!
    }

    /// Row-major RGBA8, top-left origin.
    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func luminance(x: Int, y: Int) -> Double {
            let offset = (y * width + x) * 4
            let r = Double(bytes[offset])
            let g = Double(bytes[offset + 1])
            let b = Double(bytes[offset + 2])
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        func rgba(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let offset = (y * width + x) * 4
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }
    }

    private func read(_ image: CGImage) -> Pixels {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            // A Core Graphics bitmap context stores its first row of bytes at the *top* of the image, and a
            // CGImage does the same, so drawing one into the other preserves row order. `Pixels` is therefore
            // already top-left origin and needs no flip — adding one here silently inverts every assertion.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Pixels(width: width, height: height, bytes: bytes)
    }

    private func standardDeviationOfLuminance(_ pixels: Pixels, in rect: CGRect) -> Double {
        var values: [Double] = []
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                values.append(pixels.luminance(x: x, y: y))
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }

    private func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Tests

    /// The core claim: after redaction the stripe pattern is gone from the bitmap, not covered up.
    func testBlurDestroysThePixelsItCovers() throws {
        let secret = CGRect(x: 20, y: 30, width: 160, height: 50)
        let original = fixture(secret: secret)
        let redacted = try XCTUnwrap(Redaction.redact(original, rects: [secret], origin: .topLeft))

        let before = read(original)
        let after = read(redacted)

        let sample = CGRect(x: 30, y: 38, width: 140, height: 34)
        let beforeSigma = standardDeviationOfLuminance(before, in: sample)
        let afterSigma = standardDeviationOfLuminance(after, in: sample)

        XCTAssertGreaterThan(beforeSigma, 90, "fixture must start with a high-contrast pattern")
        XCTAssertLessThan(
            afterSigma, beforeSigma / 6,
            "the redacted region still carries most of its original detail"
        )

        var identical = 0
        var total = 0
        for y in 38..<72 {
            for x in 30..<170 {
                total += 1
                if before.rgba(x: x, y: y) == after.rgba(x: x, y: y) { identical += 1 }
            }
        }
        // A blurred region has to pass through every intermediate value on its way between the black and white
        // stripes, so a small number of pixels coincide with the original by arithmetic accident. What must not
        // happen is a *region* surviving, which the deviation assertion above already rules out.
        XCTAssertLessThan(
            Double(identical) / Double(total), 0.10,
            "\(identical) of \(total) redacted pixels survived unchanged"
        )
    }

    /// Redaction is surgical: everything outside the rectangles must be byte-identical, because the attachment is
    /// also the evidence the user is sending to the agent.
    func testPixelsOutsideTheRectangleAreUntouched() throws {
        let secret = CGRect(x: 20, y: 30, width: 160, height: 50)
        let original = fixture(secret: secret)
        let redacted = try XCTUnwrap(Redaction.redact(original, rects: [secret], origin: .topLeft))

        let before = read(original)
        let after = read(redacted)

        for y in [0, 5, 20, 100, 119] {
            for x in [0, 7, 60, 150, 199] {
                let lhs = before.rgba(x: x, y: y)
                let rhs = after.rgba(x: x, y: y)
                XCTAssertLessThanOrEqual(abs(Int(lhs.0) - Int(rhs.0)), 2, "at \(x),\(y)")
                XCTAssertLessThanOrEqual(abs(Int(lhs.1) - Int(rhs.1)), 2, "at \(x),\(y)")
                XCTAssertLessThanOrEqual(abs(Int(lhs.2) - Int(rhs.2)), 2, "at \(x),\(y)")
            }
        }
    }

    /// Catches the coordinate-flip bug, which fails silently: the region above the secret gets blurred and the
    /// secret ships in the clear.
    func testRectanglesAreInterpretedTopLeft() throws {
        // Secret only in the top third; ask for exactly that band.
        let band = CGRect(x: 0, y: 0, width: 200, height: 40)
        let original = fixture(secret: band)
        let redacted = try XCTUnwrap(Redaction.redact(original, rects: [band], origin: .topLeft))

        let before = read(original)
        let after = read(redacted)

        let topSample = CGRect(x: 10, y: 6, width: 180, height: 28)
        XCTAssertGreaterThan(standardDeviationOfLuminance(before, in: topSample), 90)
        XCTAssertLessThan(standardDeviationOfLuminance(after, in: topSample), 30)

        // The flat bottom must be identical, which it would not be if the mask had been flipped.
        for y in [60, 90, 118] {
            for x in [3, 100, 196] {
                XCTAssertEqual(before.rgba(x: x, y: y).0, after.rgba(x: x, y: y).0, "at \(x),\(y)")
            }
        }
    }

    /// The bytes that actually leave the device are the ones that matter. This is the assertion the ticket asks
    /// for: the uploaded payload does not contain the original pixels under an overlay.
    func testUploadedBytesDoNotContainTheOriginalPixels() throws {
        let secret = CGRect(x: 20, y: 30, width: 160, height: 50)
        let original = fixture(secret: secret)
        let redacted = try XCTUnwrap(Redaction.redact(original, rects: [secret], origin: .topLeft))

        let encoded = try XCTUnwrap(Redaction.encode(redacted, format: .jpeg, budget: 512 * 1024))
        XCTAssertLessThanOrEqual(encoded.data.count, 512 * 1024)
        XCTAssertEqual(encoded.scale, 1.0, "a 200x120 image must not need downscaling to fit 512 KB")

        let roundTripped = try XCTUnwrap(decode(encoded.data))
        XCTAssertEqual(roundTripped.width, 200)
        XCTAssertEqual(roundTripped.height, 120)

        let sample = CGRect(x: 30, y: 38, width: 140, height: 34)
        let originalSigma = standardDeviationOfLuminance(read(original), in: sample)
        let uploadedSigma = standardDeviationOfLuminance(read(roundTripped), in: sample)
        XCTAssertLessThan(
            uploadedSigma, originalSigma / 6,
            "the encoded upload still carries the redacted detail"
        )

        // And the encoded original is measurably different from the encoded redaction, which rules out the
        // degenerate case where both went through a lossy path that flattened everything.
        let encodedOriginal = try XCTUnwrap(Redaction.encode(original, format: .jpeg, budget: 512 * 1024))
        let controlSigma = standardDeviationOfLuminance(read(try XCTUnwrap(decode(encodedOriginal.data))), in: sample)
        XCTAssertGreaterThan(controlSigma, 60, "JPEG alone must not be mistaken for redaction")
    }

    /// Several rectangles in one pass, because the editor lets the user paint more than one.
    func testMultipleRectanglesAreAllDestroyed() throws {
        let left = CGRect(x: 10, y: 20, width: 60, height: 40)
        let right = CGRect(x: 120, y: 60, width: 70, height: 40)
        let context = CGContext(
            data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        for rect in [left, right] {
            let flipped = CGRect(x: rect.minX, y: 120 - rect.maxY, width: rect.width, height: rect.height)
            var x = flipped.minX
            while x < flipped.maxX {
                context.setFillColor(gray: 0, alpha: 1)
                context.fill(CGRect(x: x, y: flipped.minY, width: 1, height: flipped.height))
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: x + 1, y: flipped.minY, width: 1, height: flipped.height))
                x += 2
            }
        }
        let original = context.makeImage()!
        let redacted = try XCTUnwrap(Redaction.redact(original, rects: [left, right], origin: .topLeft))
        let after = read(redacted)

        for sample in [
            CGRect(x: 18, y: 26, width: 44, height: 28),
            CGRect(x: 128, y: 66, width: 54, height: 28),
        ] {
            XCTAssertLessThan(standardDeviationOfLuminance(after, in: sample), 30, "\(sample)")
        }
    }

    func testEmptyRectangleListLeavesTheImageAlone() throws {
        let original = fixture(secret: CGRect(x: 20, y: 30, width: 40, height: 20))
        let result = try XCTUnwrap(Redaction.redact(original, rects: [], origin: .topLeft))
        XCTAssertEqual(result.width, original.width)
        XCTAssertEqual(result.height, original.height)
    }

    func testEncodeFallsBackToASmallerScaleWhenQualityCannotReachTheBudget() throws {
        let original = fixture(width: 1_400, height: 900, secret: CGRect(x: 0, y: 0, width: 1_400, height: 900))
        let encoded = try XCTUnwrap(Redaction.encode(original, format: .jpeg, budget: 20_000))
        XCTAssertLessThan(encoded.scale, 1.0, "a full-frame stripe pattern cannot reach 20 KB at full size")
    }

    func testCropIsTopLeftOriginAndClamped() throws {
        let original = fixture(secret: CGRect(x: 0, y: 0, width: 200, height: 20))
        let cropped = try XCTUnwrap(Redaction.crop(original, to: CGRect(x: 150, y: 0, width: 200, height: 20)))
        XCTAssertEqual(cropped.width, 50, "the crop must clamp to the image instead of failing")
        XCTAssertEqual(cropped.height, 20)
        XCTAssertGreaterThan(
            standardDeviationOfLuminance(read(cropped), in: CGRect(x: 0, y: 0, width: 50, height: 20)),
            90,
            "cropping the top band must return the striped band, not the flat area below it"
        )
    }
}
