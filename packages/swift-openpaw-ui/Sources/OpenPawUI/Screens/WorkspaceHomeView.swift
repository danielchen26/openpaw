import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI

public enum WorkspaceHomeCopy {
    public static let emptyPrimaryAction = "Add a Tailscale or SSH device"
    public static let headline = "Bring your own machine online"
    public static let message = "OpenPaw connects to your own Mac or server. Credentials remain local on this device, and you stay in control of what is trusted, saved, and opened."
    public static let localControl = "Nothing is dialed from Home until you add SSH details and choose to connect."
    public static let emptyAndOnboardingCopy = [emptyPrimaryAction, headline, message, localControl]
}

@MainActor
public struct WorkspaceHomeView: View {
    private let model: OpenPawModel
    private let settings: OpenPawSettings
    private let candidates: [AddDeviceCandidate]
    @State private var isAdding = false

    public init(model: OpenPawModel, settings: OpenPawSettings, candidates: [AddDeviceCandidate] = []) {
        self.model = model
        self.settings = settings
        self.candidates = candidates
    }

    public var body: some View {
        Group {
            if model.hostStore.hosts.isEmpty {
                emptyFirstRun
            } else {
                HostListView(model: model, settings: settings)
            }
        }
        .sheet(isPresented: $isAdding) {
            NavigationStack {
                AddDeviceFlow(model: model, settings: settings, candidates: candidates) { isAdding = false }
            }
        }
    }

    private var emptyFirstRun: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.xl) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: OpenPawTheme.Space.large) {
                        SignalOrb(.discovering, size: 88)
                            .accessibilityLabel("Waiting for a device you control")
                        homeHeroText
                    }
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                        SignalOrb(.discovering, size: 72)
                            .accessibilityLabel("Waiting for a device you control")
                        homeHeroText
                    }
                }

                Panel {
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                        Text(WorkspaceHomeCopy.message)
                            .font(OpenPawTheme.Human.prose)
                            .foregroundStyle(OpenPawTheme.textSecondary)
                        Text(WorkspaceHomeCopy.localControl)
                            .font(OpenPawTheme.Machine.body)
                            .foregroundStyle(OpenPawTheme.textPrimary)
                    }
                }

                addDeviceButton
            }
            .padding(OpenPawTheme.Space.xl)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(OpenPawTheme.void)
        .navigationTitle("Home")
    }

    private var homeHeroText: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            Text("home / first run")
                .font(OpenPawTheme.Machine.label)
                .foregroundStyle(OpenPawTheme.signal)
            Text(WorkspaceHomeCopy.headline)
                .font(OpenPawTheme.Human.display)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addDeviceButton: some View {
        Button { isAdding = true } label: {
            Label(WorkspaceHomeCopy.emptyPrimaryAction, systemImage: "plus.circle.fill")
                .font(OpenPawTheme.Machine.headline)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .padding(.horizontal, OpenPawTheme.Space.large)
                .frame(minHeight: 44)
                .background(OpenPawTheme.graphite)
                .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card).stroke(OpenPawTheme.lineStrong))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(WorkspaceHomeCopy.emptyPrimaryAction)
    }
}
