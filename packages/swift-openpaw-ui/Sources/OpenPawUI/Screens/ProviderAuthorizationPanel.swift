import SwiftUI

public struct ProviderAuthorizationPanel: View {
    public let presentation: AuthorizationPresentation
    public var onCheck: () -> Void
    public var onCancel: () -> Void
    public init(presentation: AuthorizationPresentation, onCheck: @escaping () -> Void, onCancel: @escaping () -> Void) { self.presentation = presentation; self.onCheck = onCheck; self.onCancel = onCancel }
    public var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            Text(presentation.title).font(OpenPawTheme.Human.proseTight).foregroundStyle(OpenPawTheme.textPrimary)
            Text(presentation.detail).font(OpenPawTheme.Human.prose).foregroundStyle(OpenPawTheme.textSecondary)
            if let code = presentation.userCode { Text(code).font(OpenPawTheme.Machine.title).padding().accessibilityLabel(presentation.accessibilityLabel ?? code) }
            HStack { Button(presentation.primaryAction, action: onCheck).frame(minHeight: 44); if let cancel = presentation.cancelAction { Button(cancel, action: onCancel).frame(minHeight: 44) } }
        }.padding().background(OpenPawTheme.graphite, in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.sheet))
    }
}
