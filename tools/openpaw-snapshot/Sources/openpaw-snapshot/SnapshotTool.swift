import AppKit
import Foundation
import OpenPawUI
import SwiftUI

/// Renders every OpenPaw screen headlessly to PNG.
///
/// This exists because the repository has no iOS simulator runtime, so the only way a UI change can be *seen* before
/// it ships is to render the same SwiftUI views on macOS through `ImageRenderer`. That is also why every screen in
/// `OpenPawUI` is required to compile for macOS: the constraint is not portability for its own sake, it is what makes
/// visual review possible at all here.
///
/// The tool fails the build when a render comes back empty or as one flat colour. That check is the point: a screen
/// whose data source went missing, whose `GeometryReader` collapsed to zero, or which `ImageRenderer` could not host
/// still *builds*, and without this it would still pass review.
@main
@MainActor
struct SnapshotTool {

    static func main() async {
        // The renderer puts each view in a real `NSHostingView` inside an `NSWindow`, so the shared application has to
        // exist before the first render — font resolution, text measurement and appearance all read from it.
        // See the note at the top of SnapshotRenderer.swift for why this is not `ImageRenderer`.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        do {
            let outputDirectory = try parseOutputDirectory()
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

            let renderer = SnapshotRenderer(outputDirectory: outputDirectory)
            var written: [Rendered] = []
            var skipped: [Skipped] = []
            var failures: [String] = []

            for scenario in PreviewBackend.Scenario.allCases {
                for screen in ScreenCatalog.all {
                    for device in DeviceProfile.all {
                        let name = "\(screen.name).\(scenario.snapshotName)"
                        // A fresh model per render. Screens hold `@State`, and `ApprovalSheet-acknowledged` mutates
                        // the model on purpose, so sharing one model would let an earlier render change a later one.
                        let model = PreviewBackend.model(scenario)
                        guard let view = screen.build(model, scenario) else {
                            if device.name == DeviceProfile.all[0].name {
                                skipped.append(Skipped(name: name, reason: screen.unavailableReason))
                            }
                            continue
                        }
                        do {
                            written.append(try await renderer.render(view, name: name, device: device))
                        } catch {
                            failures.append("\(name)@\(device.name): \(error)")
                        }
                    }
                }
            }

            report(written: written, skipped: skipped, failures: failures, directory: outputDirectory)

            let blank = written.filter(\.isBlank)
            guard failures.isEmpty, blank.isEmpty else {
                exit(1)
            }
        } catch {
            FileHandle.standardError.write(Data("openpaw-snapshot: \(error)\n".utf8))
            exit(2)
        }
    }

    // MARK: Arguments

    private static func parseOutputDirectory() throws -> URL {
        var arguments = Array(CommandLine.arguments.dropFirst())
        while let first = arguments.first {
            arguments.removeFirst()
            guard first == "--output" || first == "-o" else { continue }
            guard let path = arguments.first else { throw SnapshotError.missingOutputDirectory }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        throw SnapshotError.missingOutputDirectory
    }

    // MARK: Manifest

    /// Prints the manifest: one line per file with its pixel dimensions and byte size, then the blank-render verdict.
    ///
    /// Dimensions and byte sizes are in the output because they are the two numbers a reviewer can check without
    /// opening anything: a file that is 1/20th the size of its neighbours is a screen that drew almost nothing, and a
    /// frame whose pixel size does not match its profile is a scale bug.
    private static func report(
        written: [Rendered],
        skipped: [Skipped],
        failures: [String],
        directory: URL
    ) {
        print("openpaw-snapshot → \(directory.path)")
        print("")

        let nameWidth = written.map { $0.url.lastPathComponent.count }.max() ?? 0
        for item in written.sorted(by: { $0.url.lastPathComponent < $1.url.lastPathComponent }) {
            let name = item.url.lastPathComponent.padding(
                toLength: max(nameWidth, 1), withPad: " ", startingAt: 0
            )
            let dimensions = "\(item.pixelWidth)x\(item.pixelHeight)"
            let bytes = ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file)
            let flag = item.isBlank ? "  BLANK" : ""
            let coverage = String(format: "%6.2f%% ink", item.inkCoverage * 100)
            print(
                "  \(name)  \(dimensions.padding(toLength: 11, withPad: " ", startingAt: 0))  "
                    + "\(bytes.padding(toLength: 10, withPad: " ", startingAt: 0))  "
                    + "\(coverage)  \(item.distinctSampledColours) colours\(flag)"
            )
        }

        if !skipped.isEmpty {
            print("")
            print("skipped:")
            for item in skipped.sorted(by: { $0.name < $1.name }) {
                print("  \(item.name) — \(item.reason)")
            }
        }

        if !failures.isEmpty {
            print("")
            print("failed to render:")
            for failure in failures.sorted() { print("  \(failure)") }
        }

        let blank = written.filter(\.isBlank)
        print("")
        print("\(written.count) written, \(skipped.count) skipped, \(failures.count) failed, \(blank.count) blank")
        if !blank.isEmpty {
            print("")
            print("blank renders are a failure: these screens produced a single flat colour or no bytes at all.")
            for item in blank.sorted(by: { $0.url.lastPathComponent < $1.url.lastPathComponent }) {
                print("  \(item.url.lastPathComponent) — \(item.blankReason ?? "blank")")
            }
        }
    }
}

extension PreviewBackend.Scenario {
    /// Filename-safe scenario name.
    var snapshotName: String {
        switch self {
        case .populated: "populated"
        case .empty: "empty"
        case .disconnected: "disconnected"
        case .reviewingDestructiveCommand: "destructive"
        case .repoProviders: "repo-providers"
        }
    }
}
