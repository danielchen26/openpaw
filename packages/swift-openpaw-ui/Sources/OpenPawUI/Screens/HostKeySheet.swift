import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI

/// First-connection confirmation and the changed-key block.
///
/// The two states are deliberately not the same screen wearing different colours. An unknown key is a question:
/// here is a fingerprint, go and compare it. A changed key is a refusal: the key that answered is not the key
/// this device recorded, and no amount of tapping in this sheet will connect. That is why `.changed` has no
/// continue control at all rather than a disabled one — a disabled button still tells you that continuing is a
/// thing you might be allowed to do, and here it is not.
@MainActor
public struct HostKeySheet: View {
    private let prompt: HostKeyPrompt
    private let onTrust: () -> Void
    private let onCancel: () -> Void

    public init(prompt: HostKeyPrompt, onTrust: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.prompt = prompt
        self.onTrust = onTrust
        self.onCancel = onCancel
    }

    /// The command that answers "is this the right key?" from the host side. Shown, not run: verifying a key over
    /// the connection you are trying to verify proves nothing.
    private static let verificationCommand = "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
                header
                fingerprints
                guidance
                controls
            }
            .padding(OpenPawTheme.Space.large)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .background(OpenPawTheme.ink)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            HStack(spacing: OpenPawTheme.Space.small) {
                Image(systemName: glyph)
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text(eyebrow).microLabel(accent)
            }
            Text(title)
                .font(OpenPawTheme.Human.title)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(explanation)
                .font(OpenPawTheme.Human.prose)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        // VoiceOver hears the classification before the detail, same rule as a risk surface.
        .accessibilityLabel("\(eyebrow). \(title) \(explanation)")
    }

    // MARK: Fingerprints

    @ViewBuilder
    private var fingerprints: some View {
        Panel(label: "Fingerprint") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                if case .changed(let expected, let actual) = prompt.verdict {
                    MonoField(label: "Recorded", value: expected, isCopyable: true)
                    MonoField(label: "Received", value: actual, isCopyable: true)
                    Text("Two different keys. Only one of them belongs to the host you trusted.")
                        .font(OpenPawTheme.Human.caption)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if case .unknown(let fingerprint) = prompt.verdict {
                    MonoField(label: "Host", value: prompt.host, isCopyable: true)
                    MonoField(label: "SHA256", value: fingerprint, isCopyable: true)
                } else {
                    MonoField(label: "Host", value: prompt.host, isCopyable: true)
                    Text("This key already matches the one recorded for the host.")
                        .font(OpenPawTheme.Human.caption)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Guidance

    private var guidance: some View {
        HumanPanel {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                Text("How to check").microLabel()
                Text(guidanceProse)
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                MonoField(label: "Run on the host", value: Self.verificationCommand, isCopyable: true)
            }
        }
    }

    private var guidanceProse: String {
        if case .changed = prompt.verdict {
            return """
                Get to the host another way — a physical console, your provider's web console, an existing session \
                on a different machine — and print its key fingerprint. If it matches the received value, the host \
                was rebuilt or its key was rotated, and you can delete this host's stored key and pair again. If \
                it matches neither, stop using this network.
                """
        }
        return """
            Print the fingerprint on the host itself and compare it character by character with the value above. \
            Doing this once is what makes every later connection meaningful.
            """
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: OpenPawTheme.Space.small) {
            // `allowsTrust` is false for `.changed`, so this branch is the whole difference between a question
            // and a refusal. There is no `else` that quietly offers a way through.
            if prompt.allowsTrust {
                Button(action: onTrust) {
                    Text("Trust and continue")
                        .font(OpenPawTheme.Machine.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OpenPawTheme.ink)
                .background(OpenPawTheme.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card))
                .accessibilityLabel("Trust this host key and continue connecting")
            }

            Button(action: onCancel) {
                Text("Cancel")
                    .font(OpenPawTheme.Machine.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(OpenPawTheme.textPrimary)
            .overlay(
                RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                    .stroke(OpenPawTheme.lineStrong, lineWidth: OpenPawTheme.hairline))

            if !prompt.allowsTrust {
                Text("OpenPaw will not open this connection.")
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: Copy

    private var isChanged: Bool {
        if case .changed = prompt.verdict { return true }
        return false
    }

    private var isUnknown: Bool {
        if case .unknown = prompt.verdict { return true }
        return false
    }

    private var accent: Color {
        isChanged ? OpenPawTheme.bad : OpenPawTheme.warn
    }

    private var glyph: String {
        isChanged ? "exclamationmark.octagon.fill" : "questionmark.diamond.fill"
    }

    private var eyebrow: String {
        if isChanged { return "host key changed" }
        if isUnknown { return "first connection" }
        return "host key trusted"
    }

    private var title: String {
        if isChanged { return "This is not the host you trusted." }
        if isUnknown { return "Confirm the host key." }
        return "This host is already known."
    }

    private var explanation: String {
        if isChanged {
            return """
                The key offered by \(prompt.host) does not match the key this device recorded. Either the host was \
                rebuilt, or something between you and it is answering in its place.
                """
        }
        if isUnknown {
            return """
                This device has never connected to \(prompt.host). Compare the fingerprint below with the host \
                before you trust it.
                """
        }
        return "The key offered by \(prompt.host) matches the recorded one. Nothing to decide."
    }
}

#Preview("Unknown key") {
    HostKeySheet(
        prompt: HostKeyPrompt(
            host: "workshop.local:22",
            verdict: .unknown(fingerprint: "SHA256:9Xk2Lp7vQ0aB4tR8yN3mC6sJ1dW5hF7gK9zP2oT4uY8")),
        onTrust: {},
        onCancel: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Changed key") {
    HostKeySheet(
        prompt: HostKeyPrompt(
            host: "workshop.local:22",
            verdict: .changed(
                expected: "SHA256:9Xk2Lp7vQ0aB4tR8yN3mC6sJ1dW5hF7gK9zP2oT4uY8",
                actual: "SHA256:1Qw3Er5Ty7Ui9Op0As2Df4Gh6Jk8Lz0Xc2Vb4Nm6Qp8")),
        onTrust: {},
        onCancel: {}
    )
    .preferredColorScheme(.dark)
}
