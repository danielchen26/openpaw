import SwiftUI
import UIKit
import XCTest

@testable import OpenPawUI

@MainActor
final class DestinationSwipeCatcherTests: XCTestCase {
    func testUIKitModifierMappingPreservesModifiersThatInvalidateTheExactChord() {
        XCTAssertEqual(
            DestinationSwipeCatcher.keyboardModifiers(from: [.command, .alternate]),
            [.command, .option]
        )
        XCTAssertEqual(
            DestinationSwipeCatcher.keyboardModifiers(from: [.command, .alternate, .shift]),
            [.command, .option, .shift]
        )
        XCTAssertEqual(
            DestinationSwipeCatcher.keyboardModifiers(from: [.command, .alternate, .control]),
            [.command, .option, .control]
        )
    }

    func testVoiceOverAdjustableSurfaceCallsTheSameBoundedPagingIntent() throws {
        var decisions: [DestinationPageDecision] = []
        let catcher = DestinationSwipeCatcher(
            destination: .terminal,
            isBackNavigationAvailable: false,
            isModalPresented: false,
            onIntent: { decisions.append($0) }
        )
        let controller = UIHostingController(rootView: catcher.frame(width: 1, height: 1))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()

        let host = try XCTUnwrap(findWindowHost(in: controller.view))
        XCTAssertEqual(host.accessibilityIdentifier, "root.destination.pager")
        XCTAssertEqual(host.accessibilityLabel, "Root tabs")
        XCTAssertEqual(host.accessibilityValue, "Terminal")
        XCTAssertTrue(host.accessibilityTraits.contains(.adjustable))
        XCTAssertEqual(host.accessibilityCustomActions?.map(\.name), ["Previous Tab", "Next Tab"])

        host.accessibilityIncrement()
        host.accessibilityDecrement()

        XCTAssertEqual(decisions, [.next, .previous])
        window.isHidden = true
    }

    private func findWindowHost(in view: UIView) -> DestinationSwipeCatcher.WindowHost? {
        if let host = view as? DestinationSwipeCatcher.WindowHost { return host }
        for child in view.subviews {
            if let host = findWindowHost(in: child) { return host }
        }
        return nil
    }
}
