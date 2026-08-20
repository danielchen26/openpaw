import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One read-only fact: its name in the micro-label register, its value in monospace.
///
/// The value is monospaced even when it is prose-shaped, because everything in this row came from the host and
/// column alignment across a stack of them is the information. The copy control reports success *in place* for a
/// moment and then goes back to being a copy control — a toast for a clipboard write is a notification about
/// something the person just did on purpose.
public struct MonoField: View {
    private let label: String
    private let value: String
    private let isCopyable: Bool

    @State private var didCopy = false

    public init(label: String, value: String, isCopyable: Bool = false) {
        self.label = label
        self.value = value
        self.isCopyable = isCopyable
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.medium) {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
                Text(label).microLabel()
                Text(value)
                    .font(OpenPawTheme.Machine.code)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isCopyable { copyControl }
        }
        .accessibilityElement(children: .combine)
    }

    private var copyControl: some View {
        Button {
            OpenPawClipboard.copy(value)
            didCopy = true
        } label: {
            Group {
                if didCopy {
                    Text("copied").microLabel(OpenPawTheme.ok)
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OpenPawTheme.textTertiary)
                }
            }
            // The floor, not a suggestion: an icon-only control gets a 44 pt square whatever it looks like.
            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(didCopy ? "\(label) copied" : "Copy \(label)")
        // Keyed on `didCopy` so a second copy restarts the window instead of inheriting the first one's deadline.
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .milliseconds(1_500))
            didCopy = false
        }
    }
}

// MARK: - Clipboard

/// The one place the app touches a pasteboard. Both platforms, because these screens are snapshot-rendered on
/// macOS and a `#if os(iOS)`-only clipboard would make the shared component fail to build there.
public enum OpenPawClipboard {
    public static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

#Preview("Fields") {
    VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
        MonoField(label: "session", value: PreviewBackend.claudeSessionID, isCopyable: true)
        MonoField(label: "branch", value: "feat/inbox-gate")
        MonoField(label: "cwd", value: "/Users/dana/src/openpaw", isCopyable: true)
        MonoField(label: "last seq", value: "18")
    }
    .padding(OpenPawTheme.Space.large)
    .panelStyle(label: "session")
    .padding(OpenPawTheme.Space.large)
    .background(OpenPawTheme.ink)
}
