import CoreGraphics
import OpenPawProtocol
import OpenPawUI
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Tools

/// The annotation tools, in the order they appear on the bar.
enum AnnotationTool: String, CaseIterable, Identifiable, Sendable {
    case draw
    case arrow
    case rectangle
    case redact
    case crop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .draw: "Draw"
        case .arrow: "Arrow"
        case .rectangle: "Box"
        case .redact: "Redact"
        case .crop: "Crop"
        }
    }

    var glyph: String {
        switch self {
        case .draw: "scribble"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .redact: "eye.slash"
        case .crop: "crop"
        }
    }
}

// MARK: - Marks

/// Every mark stores geometry normalised to the working image, so a mark keeps its meaning when the editor is laid out
/// at a different size, when the device rotates, and when the image is finally rendered at full pixel resolution.
struct FreehandStroke: Identifiable, Equatable, Sendable {
    let id = UUID()
    var points: [CGPoint]
    var width: CGFloat
}

struct ArrowMark: Identifiable, Equatable, Sendable {
    let id = UUID()
    var start: CGPoint
    var end: CGPoint
    var width: CGFloat
}

struct BoxMark: Identifiable, Equatable, Sendable {
    let id = UUID()
    var rect: CGRect
    var width: CGFloat
}

/// A region whose pixels are destroyed on export. Not a mark: it never draws anything, it removes something.
struct RedactionMark: Identifiable, Equatable, Sendable {
    let id = UUID()
    var rect: CGRect
}

// MARK: - Draft

/// The attachment being prepared. Owns the working bitmap and the marks on it.
@MainActor
@Observable
final class AttachmentDraft: Identifiable {

    /// Stable across edits so a `sheet(item:)` presenting the editor is not torn down every time a mark is added.
    let id = UUID()

    /// The bitmap every mark is measured against. A committed crop replaces it, which is why marks never need
    /// re-mapping: they are always normalised to whatever this currently is.
    private(set) var workingImage: CGImage
    private(set) var croppedFromOriginal = false

    var strokes: [FreehandStroke] = []
    var arrows: [ArrowMark] = []
    var boxes: [BoxMark] = []
    var redactions: [RedactionMark] = []

    var tool: AnnotationTool = .draw
    var strokeWidth: CGFloat = 4
    /// The crop the user is dragging out, normalised. Committed by `commitCrop`.
    var pendingCrop: CGRect?

    /// Upload budget. 900 KB keeps a screenshot legible while staying inside a single request the host will not
    /// reject and a phone on cellular can send in a second or two.
    var byteBudget = 900 * 1_024
    var format: Redaction.Format = .jpeg

    private(set) var isUploading = false
    private(set) var uploadError: String?
    private(set) var remotePath: String?

    init(image: CGImage) {
        workingImage = image
    }

    convenience init?(uiImage: UIImage) {
        guard let cgImage = uiImage.normalizedCGImage() else { return nil }
        self.init(image: cgImage)
    }

    var pixelSize: CGSize {
        CGSize(width: workingImage.width, height: workingImage.height)
    }

    var hasMarks: Bool {
        !strokes.isEmpty || !arrows.isEmpty || !boxes.isEmpty || !redactions.isEmpty || croppedFromOriginal
    }

    var redactionCount: Int { redactions.count }

    // MARK: Editing

    func undo() {
        // One undo stack ordered by what the user most likely just did: the last mark of the most recently used tool.
        switch tool {
        case .draw where !strokes.isEmpty: strokes.removeLast()
        case .arrow where !arrows.isEmpty: arrows.removeLast()
        case .rectangle where !boxes.isEmpty: boxes.removeLast()
        case .redact where !redactions.isEmpty: redactions.removeLast()
        case .crop: pendingCrop = nil
        default:
            if !redactions.isEmpty { redactions.removeLast() } else if !boxes.isEmpty {
                boxes.removeLast()
            } else if !arrows.isEmpty {
                arrows.removeLast()
            } else if !strokes.isEmpty {
                strokes.removeLast()
            }
        }
    }

    /// Applies the pending crop to the bitmap and rescales every existing mark into the new space, so cropping after
    /// annotating does not move the annotations.
    func commitCrop() {
        guard let crop = pendingCrop, crop.width > 0.02, crop.height > 0.02 else {
            pendingCrop = nil
            return
        }
        let pixels = CGRect(
            x: crop.minX * pixelSize.width,
            y: crop.minY * pixelSize.height,
            width: crop.width * pixelSize.width,
            height: crop.height * pixelSize.height
        )
        guard let cropped = Redaction.crop(workingImage, to: pixels, origin: .topLeft) else {
            pendingCrop = nil
            return
        }
        func remap(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: (point.x - crop.minX) / crop.width,
                y: (point.y - crop.minY) / crop.height
            )
        }
        func remap(_ rect: CGRect) -> CGRect {
            let origin = remap(CGPoint(x: rect.minX, y: rect.minY))
            return CGRect(
                x: origin.x,
                y: origin.y,
                width: rect.width / crop.width,
                height: rect.height / crop.height
            )
        }
        strokes = strokes.map { FreehandStroke(points: $0.points.map(remap), width: $0.width) }
        arrows = arrows.map { ArrowMark(start: remap($0.start), end: remap($0.end), width: $0.width) }
        boxes = boxes.map { BoxMark(rect: remap($0.rect), width: $0.width) }
        redactions = redactions.map { RedactionMark(rect: remap($0.rect)) }

        workingImage = cropped
        croppedFromOriginal = true
        pendingCrop = nil
    }

    // MARK: Export

    /// Renders the final bitmap.
    ///
    /// Order is the whole correctness of this function. Redaction runs on the pixel buffer **first**, so the marks
    /// drawn afterwards sit on top of pixels that no longer contain the secret. If it ran last, or if the redaction
    /// were drawn as an overlay, the exported file would still carry the original bytes underneath — which is the bug
    /// `RedactionTests` exists to catch.
    func render() -> CGImage? {
        let size = pixelSize
        let rects = redactions.map { mark in
            CGRect(
                x: mark.rect.minX * size.width,
                y: mark.rect.minY * size.height,
                width: mark.rect.width * size.width,
                height: mark.rect.height * size.height
            )
        }
        let base = rects.isEmpty
            ? workingImage
            : (Redaction.redact(workingImage, rects: rects, origin: .topLeft) ?? workingImage)

        guard !strokes.isEmpty || !arrows.isEmpty || !boxes.isEmpty else { return base }

        guard
            let context = CGContext(
                data: nil,
                width: base.width,
                height: base.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return base }

        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        context.draw(base, in: bounds)
        // Marks are authored in top-left space; flip once so every path below reads the way it was stored.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        AnnotationRenderer.draw(
            strokes: strokes,
            arrows: arrows,
            boxes: boxes,
            in: context,
            size: bounds.size
        )
        return context.makeImage() ?? base
    }

    func encodedPayload() -> (data: Data, filename: String)? {
        guard let image = render() else { return nil }
        guard let encoded = Redaction.encode(image, format: format, budget: byteBudget) else { return nil }
        let stamp = filenameTimestamp()
        return (encoded.data, "openpaw-\(stamp).\(encoded.format.fileExtension)")
    }

    /// Uploads and records the remote path the agent should be told about.
    func upload(using backend: any OpenPawBackend) async {
        guard let payload = encodedPayload() else {
            uploadError = "This image could not be encoded. Pick another one."
            return
        }
        isUploading = true
        uploadError = nil
        defer { isUploading = false }
        do {
            let result = try await backend.upload(data: payload.data, filename: payload.filename)
            remotePath = result.path
        } catch {
            uploadError = String(describing: error)
        }
    }
}

// MARK: - Annotation rendering

/// The one place mark geometry becomes drawing. Used by the export renderer; the live `Canvas` mirrors it with
/// SwiftUI paths built from the same normalised values.
enum AnnotationRenderer {

    static let markColor = OpenPawTheme.warn

    static func draw(
        strokes: [FreehandStroke],
        arrows: [ArrowMark],
        boxes: [BoxMark],
        in context: CGContext,
        size: CGSize
    ) {
        // Mark width is authored against a nominal 1000 pt canvas so a stroke that looked right on screen is the same
        // relative weight in a 3x screenshot.
        let scale = max(size.width, size.height) / 1_000
        context.setStrokeColor(UIColor(markColor).cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in strokes where stroke.points.count > 1 {
            context.setLineWidth(max(1, stroke.width * scale))
            context.beginPath()
            let points = stroke.points.map { denormalize($0, size) }
            context.move(to: points[0])
            for point in points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        }

        for arrow in arrows {
            context.setLineWidth(max(1, arrow.width * scale))
            let start = denormalize(arrow.start, size)
            let end = denormalize(arrow.end, size)
            context.beginPath()
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            for point in arrowHead(from: start, to: end, width: max(1, arrow.width * scale)) {
                context.beginPath()
                context.move(to: end)
                context.addLine(to: point)
                context.strokePath()
            }
        }

        for box in boxes {
            context.setLineWidth(max(1, box.width * scale))
            context.stroke(denormalize(box.rect, size))
        }
    }

    static func denormalize(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    static func denormalize(_ rect: CGRect, _ size: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * size.width,
            y: rect.minY * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )
    }

    /// The two barbs of an arrowhead, sized from the line weight so it stays proportional at any zoom.
    static func arrowHead(from start: CGPoint, to end: CGPoint, width: CGFloat) -> [CGPoint] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.001 else { return [] }
        let angle = atan2(dy, dx)
        let barb = max(width * 4, length * 0.16)
        let spread = CGFloat.pi / 7
        return [
            CGPoint(x: end.x - barb * cos(angle - spread), y: end.y - barb * sin(angle - spread)),
            CGPoint(x: end.x - barb * cos(angle + spread), y: end.y - barb * sin(angle + spread)),
        ]
    }
}

// MARK: - Source picker

/// Where an attachment comes from. All three sources produce a `UIImage`, which the draft normalises to a `CGImage`
/// with the orientation already baked in — a rotated camera frame that keeps its EXIF orientation would have its
/// redaction rectangles land on the wrong pixels.
struct AttachmentSourceBar: View {

    @Binding var draft: AttachmentDraft?
    @State private var photoItem: PhotosPickerItem?
    @State private var isShowingCamera = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            Text("Attach an image").microLabel()
            HStack(spacing: OpenPawTheme.Space.small) {
                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                    SourceLabel(title: "Photos", glyph: "photo.on.rectangle")
                }
                .accessibilityLabel("Choose a photo")

                Button { isShowingCamera = true } label: {
                    SourceLabel(title: "Camera", glyph: "camera")
                }
                .accessibilityLabel("Take a photo")

                Button(action: pasteFromClipboard) {
                    SourceLabel(title: "Paste", glyph: "doc.on.clipboard")
                }
                .disabled(!UIPasteboard.general.hasImages)
                .accessibilityLabel("Paste the image on the clipboard")
            }
            if let message {
                Text(message)
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.bad)
            }
        }
        .sheet(isPresented: $isShowingCamera) {
            CameraCapture { image in
                isShowingCamera = false
                adopt(image)
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                    let image = UIImage(data: data)
                else {
                    message = "That photo could not be read. Pick another one."
                    return
                }
                adopt(image)
            }
        }
    }

    private func pasteFromClipboard() {
        guard let image = UIPasteboard.general.image else {
            message = "There is no image on the clipboard."
            return
        }
        adopt(image)
    }

    private func adopt(_ image: UIImage) {
        guard let created = AttachmentDraft(uiImage: image) else {
            message = "That image could not be decoded. Pick another one."
            return
        }
        message = nil
        draft = created
    }
}

/// The label shared by the three source buttons.
///
/// Its own `View` rather than a method on `AttachmentSourceBar`, because `PhotosPicker`'s label builder is not
/// main-actor isolated and calling a method on the surrounding view from inside it is an isolation violation.
struct SourceLabel: View {
    let title: String
    let glyph: String

    var body: some View {
        HStack(spacing: OpenPawTheme.Space.tight) {
            Image(systemName: glyph)
            Text(title)
        }
        .font(OpenPawTheme.Machine.headline)
        .padding(.horizontal, OpenPawTheme.Space.medium)
        // A 44 pt floor is the smallest target a finger reliably hits, and these three sit side by side.
        .frame(minHeight: 44)
        .background(OpenPawTheme.panel, in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card))
    }
}

/// Camera capture. `UIImagePickerController` rather than an `AVCaptureSession`, because the system camera already
/// gives focus, flash, HDR and the review step, and reimplementing them would be a worse camera for no gain.
struct CameraCapture: UIViewControllerRepresentable {

    let onCapture: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (UIImage) -> Void

        init(onCapture: @escaping (UIImage) -> Void) {
            self.onCapture = onCapture
            super.init()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage {
                onCapture(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - Editor

/// Crop, draw, arrow, box and redact, then upload.
struct ImageAnnotationEditor: View {

    @Bindable var draft: AttachmentDraft
    let backend: any OpenPawBackend
    /// Called with the remote path once the upload succeeds, so the caller can put it in the prompt.
    let onAttached: (String) -> Void
    let onCancel: () -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            canvas
            controls
        }
        .background(OpenPawTheme.ink)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            let frame = fittedFrame(in: geometry.size)
            ZStack {
                Image(decorative: draft.workingImage, scale: 1, orientation: .up)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)

                Canvas { context, _ in
                    drawRedactionPreview(in: &context, frame: frame)
                    drawMarks(in: &context, frame: frame)
                    drawCropPreview(in: &context, frame: frame)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(gesture(in: frame))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OpenPawTheme.well)
        .accessibilityLabel("Image editor. \(draft.redactionCount) redacted regions.")
    }

    /// Aspect-fit, because a preview that letterboxes is a preview whose coordinates the export can reproduce
    /// exactly. Filling would crop the view and put marks outside the image.
    private func fittedFrame(in size: CGSize) -> CGRect {
        let pixels = draft.pixelSize
        guard pixels.width > 0, pixels.height > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / pixels.width, size.height / pixels.height)
        let fitted = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private func normalize(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max((point.x - frame.minX) / frame.width, 0), 1),
            y: min(max((point.y - frame.minY) / frame.height, 0), 1)
        )
    }

    private func gesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = normalize(value.location, in: frame)
                if dragStart == nil {
                    dragStart = normalize(value.startLocation, in: frame)
                    begin(at: dragStart ?? point)
                }
                dragCurrent = point
                extend(to: point)
            }
            .onEnded { _ in
                dragStart = nil
                dragCurrent = nil
            }
    }

    private func begin(at point: CGPoint) {
        switch draft.tool {
        case .draw:
            draft.strokes.append(FreehandStroke(points: [point], width: draft.strokeWidth))
        case .arrow:
            draft.arrows.append(ArrowMark(start: point, end: point, width: draft.strokeWidth))
        case .rectangle:
            draft.boxes.append(BoxMark(rect: CGRect(origin: point, size: .zero), width: draft.strokeWidth))
        case .redact:
            // The brush paints a run of squares along the drag, which is what makes it feel like a brush while
            // staying a set of rectangles that `Redaction` can mask exactly.
            draft.redactions.append(RedactionMark(rect: brushRect(at: point)))
        case .crop:
            draft.pendingCrop = CGRect(origin: point, size: .zero)
        }
    }

    private func extend(to point: CGPoint) {
        switch draft.tool {
        case .draw:
            guard !draft.strokes.isEmpty else { return }
            draft.strokes[draft.strokes.count - 1].points.append(point)
        case .arrow:
            guard !draft.arrows.isEmpty else { return }
            draft.arrows[draft.arrows.count - 1].end = point
        case .rectangle:
            guard !draft.boxes.isEmpty, let start = dragStart else { return }
            draft.boxes[draft.boxes.count - 1].rect = CGRect(from: start, to: point)
        case .redact:
            draft.redactions.append(RedactionMark(rect: brushRect(at: point)))
        case .crop:
            guard let start = dragStart else { return }
            draft.pendingCrop = CGRect(from: start, to: point)
        }
    }

    /// Brush footprint, normalised. Sized from the stroke width so the same slider controls both.
    private func brushRect(at point: CGPoint) -> CGRect {
        let pixels = draft.pixelSize
        let side = max(draft.strokeWidth * 6, 24)
        let width = side / max(pixels.width, 1)
        let height = side / max(pixels.height, 1)
        return CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
    }

    // MARK: Canvas drawing

    /// The preview draws a solid plate, not a blur.
    ///
    /// Showing a live Gaussian here would suggest the export is a blur *layer* — the exact misconception this feature
    /// must not create. A flat plate says "these pixels are gone", which is what the exported file will actually
    /// contain, and it costs nothing to draw while the user is dragging.
    private func drawRedactionPreview(in context: inout GraphicsContext, frame: CGRect) {
        for mark in draft.redactions {
            let rect = denormalize(mark.rect, in: frame)
            context.fill(Path(rect), with: .color(OpenPawTheme.ink))
            context.stroke(
                Path(rect),
                with: .color(OpenPawTheme.color(for: .credentialAccess)),
                lineWidth: 1
            )
        }
    }

    private func drawMarks(in context: inout GraphicsContext, frame: CGRect) {
        let scale = max(frame.width, frame.height) / 1_000
        let color = GraphicsContext.Shading.color(AnnotationRenderer.markColor)

        for stroke in draft.strokes where stroke.points.count > 1 {
            var path = Path()
            let points = stroke.points.map { denormalize($0, in: frame) }
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(
                path,
                with: color,
                style: StrokeStyle(lineWidth: max(1, stroke.width * scale), lineCap: .round, lineJoin: .round)
            )
        }

        for arrow in draft.arrows {
            let start = denormalize(arrow.start, in: frame)
            let end = denormalize(arrow.end, in: frame)
            let width = max(1, arrow.width * scale)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            for barb in AnnotationRenderer.arrowHead(from: start, to: end, width: width) {
                path.move(to: end)
                path.addLine(to: barb)
            }
            context.stroke(path, with: color, style: StrokeStyle(lineWidth: width, lineCap: .round))
        }

        for box in draft.boxes {
            context.stroke(
                Path(denormalize(box.rect, in: frame)),
                with: color,
                lineWidth: max(1, box.width * scale)
            )
        }
    }

    private func drawCropPreview(in context: inout GraphicsContext, frame: CGRect) {
        guard let crop = draft.pendingCrop else { return }
        let rect = denormalize(crop, in: frame)
        var outside = Path(frame)
        outside.addPath(Path(rect))
        context.fill(outside, with: .color(OpenPawTheme.ink.opacity(0.6)), style: FillStyle(eoFill: true))
        context.stroke(Path(rect), with: .color(OpenPawTheme.textPrimary), lineWidth: 1)
    }

    private func denormalize(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
    }

    private func denormalize(_ rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + rect.minX * frame.width,
            y: frame.minY + rect.minY * frame.height,
            width: rect.width * frame.width,
            height: rect.height * frame.height
        )
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
            HStack(spacing: OpenPawTheme.Space.tight) {
                ForEach(AnnotationTool.allCases) { tool in
                    Button {
                        draft.tool = tool
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: tool.glyph)
                            Text(tool.label).font(OpenPawTheme.Machine.codeSmall)
                        }
                        .frame(minWidth: 56, minHeight: 44)
                        .foregroundStyle(
                            draft.tool == tool ? OpenPawTheme.textPrimary : OpenPawTheme.textSecondary
                        )
                        .background(
                            draft.tool == tool ? OpenPawTheme.panel : Color.clear,
                            in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                        )
                    }
                    .accessibilityLabel(tool.label)
                    .accessibilityAddTraits(draft.tool == tool ? .isSelected : [])
                }
            }

            HStack(spacing: OpenPawTheme.Space.medium) {
                Text("Width").microLabel()
                Slider(value: $draft.strokeWidth, in: 1...16, step: 1)
                    .accessibilityLabel("Mark width")
                Text("\(Int(draft.strokeWidth))")
                    .font(OpenPawTheme.Machine.code)
                    .foregroundStyle(OpenPawTheme.textSecondary)
            }

            if draft.tool == .crop {
                Button("Apply crop") { draft.commitCrop() }
                    .font(OpenPawTheme.Machine.headline)
                    .disabled(draft.pendingCrop == nil)
                    .frame(minHeight: 44)
            }

            if draft.redactionCount > 0 {
                HStack(spacing: OpenPawTheme.Space.tight) {
                    Image(systemName: OpenPawTheme.glyph(for: .credentialAccess))
                    Text(
                        "\(draft.redactionCount) region\(draft.redactionCount == 1 ? "" : "s") will be destroyed "
                            + "before upload. The original pixels are not sent."
                    )
                    .font(OpenPawTheme.Human.caption)
                }
                .foregroundStyle(OpenPawTheme.color(for: .credentialAccess))
            }

            if let error = draft.uploadError {
                Text(error)
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.bad)
            }

            HStack(spacing: OpenPawTheme.Space.medium) {
                Button("Cancel", action: onCancel)
                    .frame(minHeight: 44)
                Button("Undo") { draft.undo() }
                    .disabled(!draft.hasMarks)
                    .frame(minHeight: 44)
                Spacer()
                Button {
                    Task {
                        await draft.upload(using: backend)
                        if let path = draft.remotePath { onAttached(path) }
                    }
                } label: {
                    Text(draft.isUploading ? "Uploading" : "Attach")
                        .font(OpenPawTheme.Machine.headline)
                        .padding(.horizontal, OpenPawTheme.Space.large)
                        .frame(minHeight: 44)
                }
                .disabled(draft.isUploading)
            }
            .font(OpenPawTheme.Machine.body)
        }
        .padding(OpenPawTheme.Space.large)
        .background(OpenPawTheme.panel)
    }
}

// MARK: - Helpers

extension CGRect {
    /// Rectangle between two dragged corners, in either direction.
    init(from start: CGPoint, to end: CGPoint) {
        self.init(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

extension UIImage {
    /// A `CGImage` with the EXIF orientation already applied.
    ///
    /// `UIImage.cgImage` returns the *unrotated* buffer, so a photo taken in portrait comes back sideways. Redacting
    /// that buffer would put the blur on the wrong side of the frame — a silent, total failure of the feature — so
    /// the orientation is baked in before any pixel work happens.
    func normalizedCGImage() -> CGImage? {
        if imageOrientation == .up, let cgImage { return cgImage }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let redrawn = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return redrawn.cgImage
    }
}

/// A timestamp that is safe in a filename on every filesystem the host might be running: no colons, no spaces, no
/// locale.
///
/// Built by hand rather than with a shared `ISO8601DateFormatter`, which is not `Sendable` and so cannot be a `static
/// let` under Swift 6 — and allocating one per attachment to avoid that would be a formatter per upload for a string
/// this simple.
func filenameTimestamp(_ date: Date = Date()) -> String {
    let parts = Calendar(identifier: .gregorian).dateComponents(
        [.year, .month, .day, .hour, .minute, .second], from: date
    )
    func pad(_ value: Int?, _ width: Int) -> String {
        String(format: "%0\(width)d", value ?? 0)
    }
    return pad(parts.year, 4) + pad(parts.month, 2) + pad(parts.day, 2)
        + "-" + pad(parts.hour, 2) + pad(parts.minute, 2) + pad(parts.second, 2)
}
