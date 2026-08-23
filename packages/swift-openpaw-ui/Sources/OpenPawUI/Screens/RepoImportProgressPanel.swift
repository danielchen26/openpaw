import SwiftUI

public struct RepoImportProgressPanel: View {
    public let presentation: ImportProgressPresentation
    public var onCancel: () -> Void
    public init(presentation: ImportProgressPresentation, onCancel: @escaping () -> Void) { self.presentation = presentation; self.onCancel = onCancel }
    public var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            Text(presentation.title).font(OpenPawTheme.Human.proseTight).foregroundStyle(OpenPawTheme.textPrimary)
            Text(presentation.detail).font(OpenPawTheme.Human.prose).foregroundStyle(OpenPawTheme.textSecondary)
            if let action = presentation.action { Button(action, action: onCancel).frame(minHeight: 44) }
        }.padding().background(OpenPawTheme.graphite, in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.sheet)).accessibilityValue(presentation.accessibilityValue)
    }
}
