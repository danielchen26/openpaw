import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// Destructive image redaction and size-budgeted encoding.
///
/// Redaction here rewrites pixels. A translucent black bar drawn over a screenshot is not redaction — it is a
/// layer, and every consumer that reads the layer stack or the original attachment gets the secret back. The only
/// safe implementation destroys the information in the bitmap before it is ever encoded, which is why this operates
/// on `CGImage` and why the encoder in this file only ever sees the already-redacted image.
///
/// Lives in its own file, free of UIKit, so the same code the app ships is the code the tests exercise on macOS.
enum Redaction {

    /// Coordinate space of the rectangles handed in.
    ///
    /// Callers work in view space, which is top-left origin; Core Graphics and Core Image are bottom-left origin.
    /// Making the flip explicit and doing it in one place is the difference between redacting the secret and
    /// redacting the whitespace above it.
    enum Origin: Sendable {
        case topLeft
        case bottomLeft
    }

    /// Replaces the contents of `rects` with an irreversibly destroyed version of those pixels.
    ///
    /// The destruction is two-stage on purpose. A Gaussian blur alone is a low-pass filter: at the radii that look
    /// convincing on screen, high-contrast monospaced text is frequently still legible after sharpening, and the
    /// operation is partially invertible because the kernel is known. Mosaicking first collapses each cell to a
    /// single average — that is a genuine loss of information, not an attenuation — and the blur that follows
    /// removes the cell edges that would otherwise reveal the mosaic grid and the glyph rhythm through it.
    ///
    /// - Parameters:
    ///   - image: the source bitmap.
    ///   - rects: regions to destroy, in pixel units of `image`.
    ///   - origin: which corner `rects` are measured from.
    /// - Returns: a new bitmap, or `nil` if Core Image could not render (out of memory, or a zero-sized image).
    static func redact(
        _ image: CGImage,
        rects: [CGRect],
        origin: Origin = .topLeft
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let normalized = rects
            .map { normalize($0, in: bounds, origin: origin) }
            .filter { $0.width >= 1 && $0.height >= 1 }
        guard !normalized.isEmpty else { return image }

        let source = CIImage(cgImage: image)

        // Scale the destruction to the region, not to the screen: a 20 pt cell destroys a caption and leaves a
        // full-width token readable, and a fixed radius that suits a token turns a caption into a grey bar. The
        // smallest redacted region decides, so every region is at least as destroyed as it needs to be.
        let shortestSide = normalized.map { min($0.width, $0.height) }.min() ?? CGFloat(min(width, height))
        let cell = max(8, (shortestSide / 4).rounded(.down))
        let sigma = max(6, cell / 1.5)

        let mosaic = CIFilter.pixellate()
        mosaic.inputImage = source.clampedToExtent()
        mosaic.center = CGPoint(x: 0, y: 0)
        mosaic.scale = Float(cell)
        guard let mosaicked = mosaic.outputImage else { return nil }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = mosaicked.clampedToExtent()
        blur.radius = Float(sigma)
        guard let blurred = blur.outputImage?.cropped(to: source.extent) else { return nil }

        guard let mask = maskImage(rects: normalized, width: width, height: height) else { return nil }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = blurred
        blend.backgroundImage = source
        blend.maskImage = CIImage(cgImage: mask)
        guard let output = blend.outputImage else { return nil }

        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        return context.createCGImage(
            output,
            from: source.extent,
            format: .RGBA8,
            colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        )
    }

    /// Clamps to the image and, for top-left input, flips into Core Image's bottom-left space.
    private static func normalize(_ rect: CGRect, in bounds: CGRect, origin: Origin) -> CGRect {
        let standardized = rect.standardized
        let flipped: CGRect
        switch origin {
        case .bottomLeft:
            flipped = standardized
        case .topLeft:
            flipped = CGRect(
                x: standardized.minX,
                y: bounds.height - standardized.maxY,
                width: standardized.width,
                height: standardized.height
            )
        }
        return flipped.intersection(bounds).integral
    }

    /// An 8-bit grey mask: white where pixels must be destroyed, black where the original must survive.
    private static func maskImage(rects: [CGRect], width: Int, height: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(rects)
        return context.makeImage()
    }

    // MARK: - Encoding

    enum Format: Sendable {
        case jpeg
        case heic

        var identifier: CFString {
            switch self {
            case .jpeg: "public.jpeg" as CFString
            case .heic: "public.heic" as CFString
            }
        }

        var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .heic: "heic"
            }
        }
    }

    /// Encodes `image` at the highest quality that fits `budget` bytes.
    ///
    /// Quality is stepped down before the image is downscaled, because a screenshot of code loses more to a 50%
    /// resize than to a 50% quality drop: the agent has to read the text in it. Only when quality alone cannot
    /// reach the budget does the pixel count come down, and the last attempt is returned even if it overshoots so
    /// that the caller always has something to upload and can say by how much it missed.
    static func encode(
        _ image: CGImage,
        format: Format,
        budget: Int,
        qualities: [Double] = [0.85, 0.7, 0.55, 0.4, 0.25],
        scales: [Double] = [1.0, 0.75, 0.5, 0.35]
    ) -> (data: Data, format: Format, quality: Double, scale: Double)? {
        // HEIC encoding is not available on every configuration. Resolving that once, before the search, keeps the
        // loop a straight line instead of a fallback branch inside a `guard else`.
        var effective = format
        if encodeOnce(image, format: format, quality: 0.5) == nil, format != .jpeg {
            effective = .jpeg
        }

        var last: (Data, Format, Double, Double)?
        for scale in scales {
            guard let scaled = resized(image, scale: scale) else { continue }
            for quality in qualities {
                guard let data = encodeOnce(scaled, format: effective, quality: quality) else { continue }
                if data.count <= budget { return (data, effective, quality, scale) }
                last = (data, effective, quality, scale)
            }
        }
        return last
    }

    static func encodeOnce(_ image: CGImage, format: Format, quality: Double) -> Data? {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, format.identifier, 1, nil
            )
        else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality as String: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func resized(_ image: CGImage, scale: Double) -> CGImage? {
        guard scale < 0.999 else { return image }
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - Cropping

    /// Crops in pixel units, clamped to the image.
    ///
    /// `CGImage.cropping(to:)` is already top-left origin, so `.topLeft` input needs no flip and `.bottomLeft`
    /// input does — the opposite of `redact`, which hands its rectangles to Core Image.
    static func crop(_ image: CGImage, to rect: CGRect, origin: Origin = .topLeft) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let standardized = rect.standardized
        let topLeft: CGRect
        switch origin {
        case .topLeft:
            topLeft = standardized
        case .bottomLeft:
            topLeft = CGRect(
                x: standardized.minX,
                y: bounds.height - standardized.maxY,
                width: standardized.width,
                height: standardized.height
            )
        }
        let clamped = topLeft.intersection(bounds).integral
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        return image.cropping(to: clamped)
    }
}
