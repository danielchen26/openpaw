import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
@_spi(SnapshotTesting) import OpenPawUI
import SwiftUI

/// One thing to render: a screen, in a scenario, as a view.
struct Screen: Sendable {
    let name: String
    /// `nil` when the scenario cannot produce this screen — an approval sheet needs an item to approve. The reason is
    /// reported so a missing screen is never mistaken for a passing one.
    let build: @MainActor (OpenPawModel, PreviewBackend.Scenario) -> AnyView?
    let unavailableReason: String
}

/// Every screen the repository is expected to be able to render, and how to build it from a `PreviewBackend` model.
///
/// This catalogue is the only reason a repository with no iOS simulator runtime can still review its own UI. It is
/// deliberately exhaustive rather than illustrative: a screen that is not here is a screen whose regressions are
/// invisible.
@MainActor
enum ScreenCatalog {

    /// A scrollback with real terminal output, injected as the terminal surface. The PTY is not available headlessly,
    /// and a blank rectangle where the terminal should be would defeat the blankness check on the shell screens.
    static func terminalSurface() -> AnyView {
        AnyView(
            ScrollbackTextView(
                snapshot: ScrollbackSnapshot(
                    firstLineNumber: 1,
                    lines: [
                        "~/src/openpaw $ cargo build --workspace",
                        "   Compiling openpaw-protocol v0.1.0 (/Users/you/src/openpaw/host/crates/openpaw-protocol)",
                        "   Compiling openpaw-agents v0.1.0 (/Users/you/src/openpaw/host/crates/openpaw-agents)",
                        "   Compiling openpaw-git v0.1.0 (/Users/you/src/openpaw/host/crates/openpaw-git)",
                        "warning: unused variable: `seq`",
                        "  --> crates/openpaw-agents/src/claude_code.rs:214:13",
                        "    Finished `dev` profile [unoptimized + debuginfo] target(s) in 18.42s",
                        "~/src/openpaw $ openpaw-host --port 8787",
                        "listening on 127.0.0.1:8787",
                        "adapters: claude-code, codex, opencode",
                        "~/src/openpaw $ git status --short",
                        " M host/crates/openpaw-git/src/status.rs",
                        "?? tools/openpaw-snapshot/",
                        "~/src/openpaw $ ",
                    ],
                    partialLine: ""
                )
            )
        )
    }

    static func repoName(_ model: OpenPawModel) -> String? {
        model.selectedRepo ?? model.repos.first?.name
    }

    static func sessionID(_ model: OpenPawModel) -> String? {
        model.selectedSessionID ?? model.sessions.first?.sessionID
    }

    /// The item the safety gate is about: the highest-risk pending request that demands the full command be read.
    static func gatedItem(_ model: OpenPawModel) -> InboxItem? {
        model.pendingInbox.first { $0.risk?.requiresDetailExpansion == true } ?? model.pendingInbox.first
    }

    static let all: [Screen] = [
        Screen(
            name: "RootView",
            build: { model, _ in
                AnyView(RootView(model: model, terminalSurface: { terminalSurface() }))
            },
            unavailableReason: ""
        ),
        Screen(
            name: "WorkspaceHomeView",
            build: { model, _ in
                AnyView(WorkspaceHomeView(model: model, settings: OpenPawSettings()))
            },
            unavailableReason: ""
        ),
        Screen(
            name: "InboxView",
            build: { model, _ in AnyView(InboxView(model: model)) },
            unavailableReason: ""
        ),
        Screen(
            name: "ApprovalSheet-sealed",
            build: { model, _ in
                guard let item = gatedItem(model) else { return nil }
                // Sealed: no approve control may exist on screen, because the user has not opened the command.
                return AnyView(ApprovalSheet(model: model, item: item))
            },
            unavailableReason: "the scenario has no pending inbox item to approve"
        ),
        Screen(
            name: "ApprovalSheet-acknowledged",
            build: { model, _ in
                guard let item = gatedItem(model) else { return nil }
                // Acknowledged: the seal has consolidated and the approve controls have appeared. Rendering both
                // states side by side is the only way the gate's two halves get reviewed together.
                model.acknowledgeDetail(item)
                return AnyView(ApprovalSheet(model: model, item: item))
            },
            unavailableReason: "the scenario has no pending inbox item to approve"
        ),
        Screen(
            name: "InboxItemDetailView",
            build: { model, _ in
                guard let item = gatedItem(model) else { return nil }
                return AnyView(InboxItemDetailView(model: model, item: item))
            },
            unavailableReason: "the scenario has no pending inbox item"
        ),
        Screen(
            name: "ChatView",
            build: { model, _ in
                guard let session = sessionID(model) else { return nil }
                return AnyView(
                    ChatView(model: model, sessionID: session, onOpenFile: { _ in }, onApprove: { _ in })
                )
            },
            unavailableReason: "the scenario has no agent session"
        ),
        Screen(
            name: "ChatView-working",
            build: { model, scenario in
                // The working session exists only where the fixtures put a tool call in flight. This snapshot is how
                // the motion budget gets verified: the scanline indicator and the Stop control both appear here, and
                // nowhere else in the set.
                guard scenario == .populated || scenario == .reviewingDestructiveCommand else { return nil }
                return AnyView(
                    ChatView(
                        model: model,
                        sessionID: PreviewBackend.workingSessionID,
                        onOpenFile: { _ in },
                        onApprove: { _ in }
                    )
                )
            },
            unavailableReason: "the working-session fixture exists only in the populated scenarios"
        ),
        Screen(
            name: "SessionListView",
            build: { model, _ in AnyView(SessionListView(model: model)) },
            unavailableReason: ""
        ),
        Screen(
            name: "SessionListView-session-space",
            build: { model, _ in
                AnyView(
                    SessionListView(
                        model: model,
                        remoteSessions: [
                            RemoteSession(id: "hd_01", name: "api", kind: .herdr, isAttached: false, isAlive: true, windowCount: 2, workingDirectory: "/srv/api"),
                            RemoteSession(id: "$0", name: "openpaw", kind: .tmux, isAttached: true, isAlive: true, windowCount: 3, workingDirectory: "/Users/dev/openpaw"),
                        ],
                        restoration: SessionRestorationPlan(
                            hostID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                            multiplexer: .herdr,
                            multiplexerTarget: "hd_01",
                            workingDirectory: "/srv/api",
                            agentSessionID: PreviewBackend.workingSessionID,
                            capturedAt: Date(timeIntervalSinceNow: -1800)
                        ),
                        transport: SessionTransportPresentation(
                            preferredMultiplexer: .herdr,
                            attemptedMultiplexers: [.tmux, .zellij, .screen, .herdr]
                        )
                    )
                )
            },
            unavailableReason: ""
        ),
        Screen(
            name: "EventLogView",
            build: { model, _ in
                guard let session = sessionID(model) else { return nil }
                return AnyView(EventLogView(model: model, sessionID: session))
            },
            unavailableReason: "the scenario has no agent session"
        ),
        Screen(
            name: "DiffViewerView-unified",
            build: { model, _ in
                guard let repo = repoName(model) else { return nil }
                return AnyView(
                    DiffViewerView(model: model, repo: repo, mode: .workingTree, openInFileBrowser: { _ in })
                )
            },
            unavailableReason: "the scenario has no repository"
        ),
        Screen(
            name: "DiffViewerView-split",
            build: { model, _ in
                guard let repo = repoName(model) else { return nil }
                // Split is requested explicitly rather than hoped for. Both device profiles are rendered, so the
                // iPhone frame of this entry is the honest answer to "what does split look like when it cannot fit".
                return AnyView(
                    DiffViewerView(
                        model: model,
                        repo: repo,
                        mode: .staged,
                        layout: .split,
                        openInFileBrowser: { _ in }
                    )
                )
            },
            unavailableReason: "the scenario has no repository"
        ),
        Screen(
            name: "FileBrowserView",
            build: { model, _ in
                guard let repo = repoName(model) else { return nil }
                return AnyView(
                    FileBrowserView(model: model, repo: repo, sendPathToAgent: { _ in })
                )
            },
            unavailableReason: "the scenario has no repository"
        ),
        Screen(
            name: "BlobView",
            build: { model, _ in
                guard let repo = repoName(model) else { return nil }
                return AnyView(
                    BlobView(
                        model: model,
                        repo: repo,
                        ref: "HEAD",
                        path: "src/main.rs",
                        sendPathToAgent: { _ in }
                    )
                )
            },
            unavailableReason: "the scenario has no repository"
        ),
        Screen(
            name: "RepoStatusView",
            build: { model, _ in
                guard let repo = repoName(model) else { return nil }
                return AnyView(RepoStatusView(model: model, repo: repo, openDiff: { _, _ in }))
            },
            unavailableReason: "the scenario has no repository"
        ),
        Screen(
            name: "PreviewWebView",
            build: { model, _ in AnyView(PreviewWebView(model: model)) },
            unavailableReason: ""
        ),
        Screen(
            name: "TerminalScreenView",
            build: { model, _ in
                return AnyView(
                    TerminalScreenView(
                        model: model,
                        settings: OpenPawSettings.preview(),
                        scrollback: ScrollbackStore(),
                        surface: { terminalSurface() },
                        onFontSizeChange: { _ in }
                    )
                )
            },
            unavailableReason: ""
        ),
        Screen(
            name: "HostListView",
            build: { model, _ in
                AnyView(HostListView(model: model, settings: OpenPawSettings.preview()))
            },
            unavailableReason: ""
        ),
        Screen(
            name: "WorkspaceHomeView-empty",
            build: { _, _ in
                return AnyView(
                    NavigationStack {
                        WorkspaceHomeView(model: OpenPawModel(hostStore: HostStore()), settings: OpenPawSettings.preview())
                    }
                )
            },
            unavailableReason: ""
        ),
        Screen(
            name: "AddDeviceFlow-welcome",
            build: { _, _ in
                return AnyView(
                    NavigationStack {
                        AddDeviceFlow(
                            model: OpenPawModel(hostStore: HostStore()),
                            settings: OpenPawSettings.preview(),
                            onDismiss: {}
                        )
                    }
                )
            },
            unavailableReason: ""
        ),
        Screen(
            name: "AddDeviceFlow-candidate-confirmation",
            build: { _, _ in
                let candidate = AddDeviceCandidate(
                    id: "node-studio",
                    nickname: "Studio",
                    hostname: "studio.tail123.ts.net"
                )
                var state = AddDeviceFlowState(hosts: [], discovered: [candidate])
                state.startTailscaleDiscovery()
                state.selectCandidate(id: candidate.id)
                return AnyView(
                    NavigationStack {
                        AddDeviceFlow(
                            model: OpenPawModel(hostStore: HostStore()),
                            settings: OpenPawSettings.preview(),
                            state: state,
                            onDismiss: {}
                        )
                    }
                )
            },
            unavailableReason: ""
        ),
        Screen(
            name: "AddDeviceFlow-tailscale-no-candidates",
            build: { _, _ in
                var state = AddDeviceFlowState(hosts: [])
                state.startTailscaleDiscovery()
                return AnyView(
                    NavigationStack {
                        AddDeviceFlow(
                            model: OpenPawModel(hostStore: HostStore()),
                            settings: OpenPawSettings.preview(),
                            state: state,
                            onDismiss: {}
                        )
                    }
                )
            },
            unavailableReason: ""
        ),
        Screen(
            name: "AddDeviceFlow-edit-details",
            build: { _, _ in
                let candidate = AddDeviceCandidate(
                    id: "node-studio",
                    nickname: "Studio",
                    hostname: "studio.tail123.ts.net"
                )
                var state = AddDeviceFlowState(hosts: [], discovered: [candidate])
                state.startTailscaleDiscovery()
                state.selectCandidate(id: candidate.id)
                let draft = state.confirmSelectedCandidate()
                return AnyView(
                    NavigationStack {
                        AddDeviceFlow(
                            model: OpenPawModel(hostStore: HostStore()),
                            settings: OpenPawSettings.preview(),
                            state: state,
                            draft: draft,
                            onDismiss: {}
                        )
                    }
                )
            },
            unavailableReason: ""
        ),
        Screen(
            name: "HostEditorView",
            build: { model, _ in
                AnyView(
                    HostEditorView(
                        model: model,
                        settings: OpenPawSettings.preview(),
                        record: model.selectedHost,
                        onDismiss: {}
                    )
                )
            },
            unavailableReason: ""
        ),
        Screen(
            name: "SettingsView",
            build: { model, _ in AnyView(SettingsView(model: model, settings: OpenPawSettings.preview())) },
            unavailableReason: ""
        ),
        Screen(
            name: "DiagnosticsView",
            build: { model, _ in AnyView(DiagnosticsView(model: model, forwardedPort: 53_871)) },
            unavailableReason: ""
        ),
        Screen(
            name: "AuditView",
            build: { model, _ in AnyView(AuditView(model: model)) },
            unavailableReason: ""
        ),
        Screen(
            name: "HostKeySheet-unknown",
            build: { _, _ in
                AnyView(
                    HostKeySheet(
                        prompt: HostKeyPrompt(
                            host: "workstation",
                            verdict: .unknown(
                                fingerprint: "SHA256:uNiQ3fingerPrint0fAn0therwiseUnkn0wnH0stKey"
                            )
                        ),
                        onTrust: {},
                        onCancel: {}
                    )
                )
            },
            unavailableReason: ""
        ),
        Screen(
            name: "HostKeySheet-changed",
            build: { _, _ in
                // A changed key must have no continue path anywhere in this frame. That is the assertion a reviewer
                // makes against this PNG.
                AnyView(
                    HostKeySheet(
                        prompt: HostKeyPrompt(
                            host: "workstation",
                            verdict: .changed(
                                expected: "SHA256:0rigina1PinnedFingerprintF0rThisH0stKeyAAA",
                                actual: "SHA256:c0mp1ete1yDifferentFingerprintArrivedT0dayB"
                            )
                        ),
                        onTrust: {},
                        onCancel: {}
                    )
                )
            },
            unavailableReason: ""
        ),
    ]
}
