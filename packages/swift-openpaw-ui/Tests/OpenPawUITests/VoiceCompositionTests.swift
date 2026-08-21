import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import Testing
@testable import OpenPawUI

@Suite("Voice composition")
struct VoiceCompositionTests {
    @Test func finalTerminalRecognitionStagesDraftWithoutExecution() {
        var voice = VoiceComposition(destination: .terminal)
        voice.start()
        let action = voice.apply(DictationUpdate(text: "rm -rf important", isFinal: true))

        #expect(action == nil)
        #expect(voice.draft == "rm -rf important")
        #expect(voice.partialTranscript == "")
        #expect(voice.isActive)
    }

    @Test func terminalExecutesOnlyExplicitExecuteAction() {
        var voice = VoiceComposition(destination: .terminal)
        voice.start()
        #expect(voice.apply(DictationUpdate(text: "echo safe", isFinal: true)) == nil)

        let action = voice.commit()

        #expect(action == .executeTerminal("echo safe"))
        #expect(voice.draft == "echo safe")
        voice.clearAfterSuccessfulCommit()
        #expect(voice.draft == "")
    }

    @Test func terminalExecuteActionCarriesExpectedNewlineForBackendSend() {
        let action = VoiceCommitAction.executeTerminal("echo safe")
        #expect(action.terminalTextToSend == "echo safe\n")
        #expect(VoiceCommitAction.executeTerminal("echo safe\n").terminalTextToSend == "echo safe\n")
        #expect(VoiceCommitAction.sendAgent("echo safe").terminalTextToSend == nil)
    }

    @Test func terminalActionControllerClearsOnlyAfterSuccessfulNewlineSend() async {
        var sent: [String] = []
        var voice = VoiceComposition(destination: .terminal, draft: "echo safe")

        let succeeded = await VoiceTerminalActionController.execute(composition: &voice) { text in sent.append(text) }

        #expect(succeeded)
        #expect(sent == ["echo safe\n"])
        #expect(voice.draft == "")

        var failing = VoiceComposition(destination: .terminal, draft: "keep me")
        let failed = await VoiceTerminalActionController.execute(composition: &failing) { _ in throw FakeSendError() }
        #expect(!failed)
        #expect(failing.draft == "keep me")
    }

    @Test func agentSendsOnlyExplicitSendAction() {
        var voice = VoiceComposition(destination: .agent, draft: "please")
        voice.start()
        #expect(voice.apply(DictationUpdate(text: "review this", isFinal: true)) == nil)

        let action = voice.commit()

        #expect(action == .sendAgent("please review this"))
        #expect(voice.draft == "please review this")
        voice.clearAfterSuccessfulCommit()
        #expect(voice.draft == "")
    }

    @Test func stoppingKeepsDraftAndAcceptsOneLateFinalDeterministically() {
        var voice = VoiceComposition(destination: .agent, draft: "keep")
        voice.start()
        voice.apply(DictationUpdate(text: "partial", isFinal: false))
        voice.stop()
        #expect(voice.draft == "keep partial")
        #expect(voice.partialTranscript == "")

        #expect(voice.apply(DictationUpdate(text: "late final", isFinal: true)) == nil)
        #expect(voice.draft == "keep late final")
        #expect(voice.partialTranscript == "")
        #expect(!voice.isActive)
    }

    @Test func lateFinalDoesNotOverwriteUserEditedProvisionalDraft() {
        var voice = VoiceComposition(destination: .agent, draft: "keep")
        voice.start()
        voice.apply(DictationUpdate(text: "partial", isFinal: false))
        voice.stop()
        voice.draft = "keep partial plus my edit"

        #expect(voice.apply(DictationUpdate(text: "late final", isFinal: true)) == nil)

        #expect(voice.draft == "keep partial plus my edit")
        #expect(voice.partialTranscript == "")
        #expect(!voice.isActive)
    }

    @Test func oldDictationTurnCannotMutateNewTurn() {
        var voice = VoiceComposition(destination: .agent)
        let old = voice.start()
        voice.apply(DictationUpdate(text: "old partial", isFinal: false), turn: old)
        voice.stop()

        let current = voice.start()
        #expect(voice.apply(DictationUpdate(text: "late old", isFinal: true), turn: old) == nil)
        #expect(voice.draft == "old partial")

        voice.apply(DictationUpdate(text: "new words", isFinal: true), turn: current)
        #expect(voice.draft == "old partial new words")
    }

    @Test func lateFinalDoesNotOverwritePostStopUserEditWithoutProvisionalPartial() {
        var voice = VoiceComposition(destination: .agent, draft: "typed before")
        let turn = voice.start()
        voice.stop()
        voice.draft = "typed after stop"

        #expect(voice.apply(DictationUpdate(text: "late final", isFinal: true), turn: turn) == nil)

        #expect(voice.draft == "typed after stop")
        #expect(voice.partialTranscript == "")
        #expect(!voice.isActive)
    }

    @Test func cancelInvalidatesPendingLateFinalAfterNavigationTeardown() {
        var voice = VoiceComposition(destination: .agent, draft: "keep")
        let turn = voice.start()
        voice.apply(DictationUpdate(text: "partial", isFinal: false), turn: turn)
        voice.cancel()

        #expect(voice.apply(DictationUpdate(text: "late final", isFinal: true), turn: turn) == nil)

        #expect(voice.draft == "keep")
        #expect(voice.partialTranscript == "")
        #expect(!voice.isActive)
    }

    @Test func activeTerminalFinalUsesUserEditedDraftAsBase() {
        var voice = VoiceComposition(destination: .terminal, draft: "git")
        let turn = voice.start()
        voice.draft = "git status"

        #expect(voice.apply(DictationUpdate(text: "--short", isFinal: true), turn: turn) == nil)

        #expect(voice.draft == "git status --short")
        #expect(voice.partialTranscript == "")
        #expect(voice.isActive)
    }

    @Test func startingNewTurnInvalidatesOldLateFinalAfterRapidRestart() {
        var voice = VoiceComposition(destination: .agent)
        let old = voice.start()
        voice.stop()
        let new = voice.start()
        voice.apply(DictationUpdate(text: "new words", isFinal: false), turn: new)

        #expect(voice.apply(DictationUpdate(text: "old final", isFinal: true), turn: old) == nil)

        #expect(voice.displayText == "new words")
    }

    @Test func cancelDiscardsTransientPartialButKeepsPreexistingDraft() {
        var voice = VoiceComposition(destination: .agent, draft: "preexisting")
        voice.start()
        voice.apply(DictationUpdate(text: "transient words", isFinal: false))

        voice.cancel()

        #expect(voice.draft == "preexisting")
        #expect(voice.partialTranscript == "")
        #expect(!voice.isActive)
    }

    @Test func switchingDestinationsPreservesEditableDraft() {
        var voice = VoiceComposition(destination: .agent, draft: "typed")
        voice.switchDestination(to: .terminal)
        #expect(voice.destination == .terminal)
        #expect(voice.draft == "typed")
    }

    @Test func terminalLiveTranscriptShowsCommittedDraftAndPartial() {
        let split = DictationDraft.inProgress(draft: "staged command", partial: "more args", mode: .terminal)
        #expect(split.committed == "staged command ")
        #expect(split.live == "more args")
    }

    @Test func composerControlsNameAgentSendAndTerminalExecute() {
        let agent = ComposerControlPresentation.make(destination: .agent, hasAttachments: false, hasDraft: true, isSending: false)
        #expect(agent.commitTitle == "Send")
        #expect(agent.accessibilityLabel == "Send the agent prompt")
        #expect(agent.isCommitEnabled)

        let terminal = ComposerControlPresentation.make(destination: .terminal, hasAttachments: false, hasDraft: true, isSending: false)
        #expect(terminal.commitTitle == "Execute")
        #expect(terminal.accessibilityLabel == "Execute the terminal draft")
        #expect(terminal.isCommitEnabled)
    }

    @Test func terminalAttachmentsDoNotBecomeShellArguments() {
        let terminal = ComposerControlPresentation.make(destination: .terminal, hasAttachments: true, hasDraft: true, isSending: false)
        #expect(terminal.commitTitle == "Execute")
        #expect(!terminal.isCommitEnabled)
        #expect(terminal.disabledReason == "Remove attachments before executing a terminal draft.")
    }

    @Test func attachmentOnlyAgentCommitIsTypedAndTerminalStillRequiresText() {
        var agent = VoiceComposition(destination: .agent)
        #expect(agent.commit(hasAttachments: true) == .sendAgent(""))

        var terminal = VoiceComposition(destination: .terminal)
        #expect(terminal.commit(hasAttachments: true) == nil)
    }

    @Test func controlsLockDestinationLocaleAndCommitWhileDictating() {
        let active = ComposerControlPresentation.make(
            destination: .agent,
            hasAttachments: false,
            hasDraft: true,
            isSending: false,
            isDictating: true
        )
        #expect(!active.isCommitEnabled)
        #expect(!active.isDestinationSwitchEnabled)
        #expect(!active.isLocaleSwitchEnabled)

        let inactive = ComposerControlPresentation.make(
            destination: .agent,
            hasAttachments: false,
            hasDraft: true,
            isSending: false,
            isDictating: false
        )
        #expect(inactive.isCommitEnabled)
        #expect(inactive.isDestinationSwitchEnabled)
        #expect(inactive.isLocaleSwitchEnabled)
    }

    @Test func composerPreferencesNormalizePersistedLocaleAndDestination() {
        let restored = ComposerDictationPreferences.restored(localeID: "zh_CN", mode: .terminal)
        #expect(restored.localeID == "zh-CN")
        #expect(restored.destination == .terminal)
        #expect(ComposerDictationPreferences.persistedMode(for: .agent) == .composer)
        #expect(ComposerDictationPreferences.persistedMode(for: .terminal) == .terminal)
    }

    @Test func activeComposerEditorKeepsDraftEditableAndShowsPartialSeparately() {
        let presentation = ActiveDictationDraftPresentation.make(draft: "typed edit", partial: "live words")
        #expect(presentation.editableDraft == "typed edit")
        #expect(presentation.partialPreview == "live words")
        #expect(presentation.accessibilityValue == "Draft typed edit. Current recognition live words")
    }

    @Test func chatComposerDraftEditorLocksWhileDictating() {
        let active = ComposerControlPresentation.make(
            destination: .agent,
            hasAttachments: false,
            hasDraft: true,
            isSending: false,
            isDictating: true
        )
        #expect(!active.isDraftEditorEnabled)

        let inactive = ComposerControlPresentation.make(
            destination: .agent,
            hasAttachments: false,
            hasDraft: true,
            isSending: false,
            isDictating: false
        )
        #expect(inactive.isDraftEditorEnabled)
    }

    @Test func runtimeLifecycleAllowsOwningLateFinalButRejectsOldTerminationAfterRestart() {
        var lifecycle = DictationRuntimeLifecycle()
        let old = lifecycle.start()
        lifecycle.stop()

        #expect(lifecycle.accepts(updateFor: old, isFinal: true))

        let new = lifecycle.start()
        #expect(!lifecycle.accepts(updateFor: old, isFinal: true))
        #expect(!lifecycle.shouldStopEngine(forTerminationOf: old))
        #expect(lifecycle.shouldStopEngine(forTerminationOf: new))
    }

    @Test func runtimeLifecycleIgnoresStaleStopAfterRapidRestart() {
        var lifecycle = DictationRuntimeLifecycle()
        let old = lifecycle.start()
        let new = lifecycle.start()

        let stoppedOld = lifecycle.stop(turn: old)
        #expect(!stoppedOld)
        #expect(lifecycle.accepts(updateFor: new, isFinal: false))
        let stoppedNew = lifecycle.stop(turn: new)
        #expect(stoppedNew)
        #expect(lifecycle.accepts(updateFor: new, isFinal: true))
    }

    @Test func microphoneControlIsKeyboardAndVoiceOverActionable() {
        let stopped = ComposerControlPresentation.make(destination: .agent, hasAttachments: false, hasDraft: false, isSending: false)
        #expect(stopped.microphoneKeyboardShortcut == "⌘⇧M")
        #expect(stopped.microphoneAccessibilityLabel == "Start dictation")
    }

    @Test func terminalDraftControlsAreDisabledWhileDictating() {
        let active = TerminalDictationDraftPresentation.make(draft: "echo safe", isDictating: true)
        #expect(!active.isTextFieldEnabled)
        #expect(!active.isExecuteEnabled)

        let inactive = TerminalDictationDraftPresentation.make(draft: "echo safe", isDictating: false)
        #expect(inactive.isTextFieldEnabled)
        #expect(inactive.isExecuteEnabled)
    }

    @Test func microphoneAccessibilitySemanticsChangeWithDictationState() {
        let stopped = ComposerControlPresentation.make(destination: .agent, hasAttachments: false, hasDraft: false, isSending: false)
        #expect(stopped.microphoneAccessibilityLabel == "Start dictation")
        #expect(stopped.microphoneAccessibilityHint == "Double tap to start. Press and hold also works. Words land in the agent draft.")

        let active = ComposerControlPresentation.make(
            destination: .terminal,
            hasAttachments: false,
            hasDraft: false,
            isSending: false,
            isDictating: true
        )
        #expect(active.microphoneAccessibilityLabel == "Stop dictation")
        #expect(active.microphoneAccessibilityHint == "Double tap to stop. Words land in the terminal draft until you tap Execute.")
    }

    @Test func agentAttachmentsAreDisabledWhenUploadIsUnsupported() {
        let agent = ComposerControlPresentation.make(
            destination: .agent,
            hasAttachments: true,
            hasDraft: true,
            isSending: false,
            supportsAgentAttachments: false
        )
        #expect(!agent.isCommitEnabled)
        #expect(agent.disabledReason == "Connect to a host before sending attachments.")
    }

    @MainActor @Test func settingsAndComposerShareLocaleChoices() {
        #expect(DictationDraft.localeChoices(deviceLocale: "fr_FR") == VoiceLocaleChoices.choices(deviceLocale: "fr_FR"))
        #expect(OpenPawSettings.dictationLocaleChoices(deviceLocale: "en_US") == ["en-US", "zh-CN"])
    }

    @Test func settingsDictationModeMapsToComposerDestination() {
        #expect(VoiceDestination(dictationMode: .composer) == .agent)
        #expect(VoiceDestination(dictationMode: .terminal) == .terminal)
        #expect(VoiceDestination.agent.dictationMode == .composer)
        #expect(VoiceDestination.terminal.dictationMode == .terminal)
    }

    @Test func appleSpeechDisclosureMentionsFallbackHonestly() {
        #expect(VoicePrivacyDisclosure.appleSpeech.contains("on-device"))
        #expect(VoicePrivacyDisclosure.appleSpeech.contains("fallback recognition outside this app"))
    }

    @Test func fakeEngineLifecycleCapturesModeAndStop() async {
        let engine = FakeDictationEngine()
        _ = engine.transcribe(locale: Locale(identifier: "en-US"), mode: .terminal)
        for _ in 0..<5 where await engine.requestedModes.isEmpty {
            await Task.yield()
        }
        await engine.stop()

        #expect(await engine.requestedModes == [.terminal])
        #expect(await engine.stopCount == 1)
    }

    @MainActor @Test func chatComposerIntegrationKeepsCommitSemanticsTyped() async {
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(terminal: terminal)

        #expect(await model.sendAgentPrompt("review this"))
        #expect(await model.executeTerminalDraft("echo safe"))

        #expect(await terminal.sentTexts == ["review this\n", "echo safe\n"])
    }

    @MainActor @Test func commitReportsFailureWhenNoTerminalSoDraftCanStayStaged() async {
        let model = OpenPawModel()
        #expect(await model.commitVoice(.sendAgent("do not lose me")) == false)
    }

    @MainActor @Test func agentAttachmentsUploadAndAppendRemotePathsToPrompt() async {
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(backend: PreviewBackend(), terminal: terminal)
        let attachment = ComposerAttachment(data: Data("image".utf8), filename: "sketch.png", preview: nil)

        #expect(await model.commitVoice(.sendAgent("review this"), attachments: [attachment]))

        let sent = await terminal.sentTexts.joined()
        #expect(sent.contains("review this"))
        #expect(sent.contains("Attached files uploaded to:"))
        #expect(sent.contains("/.openpaw/uploads/sketch.png"))
    }

    @MainActor @Test func attachmentUploadFailureKeepsSpecificHostError() async {
        let terminal = RecordingTerminalBackend()
        let model = OpenPawModel(backend: FailingUploadBackend(), terminal: terminal)
        let attachment = ComposerAttachment(data: Data("image".utf8), filename: "sketch.png", preview: nil)

        #expect(await model.commitVoice(.sendAgent("review this"), attachments: [attachment]) == false)

        #expect(model.lastError?.title == "The host failed (507)")
        #expect(model.lastError?.detail == "disk full")
    }

    @MainActor @Test func attachmentCapabilityRequiresConnectedStructuredBackend() {
        let model = OpenPawModel(backend: FailingUploadBackend(), terminal: RecordingTerminalBackend())
        #expect(!model.canSendAgentAttachments())

        model.connection = .connected(.ssh)
        #expect(model.canSendAgentAttachments())
    }

    @MainActor @Test func chatComposerConfigurationUsesInjectedSettings() {
        let settings = OpenPawSettings.preview()
        settings.dictationLocaleID = "zh-CN"
        settings.dictationMode = .terminal

        let configuration = ChatComposerConfiguration.make(model: OpenPawModel(), settings: settings)

        #expect(configuration.settings === settings)
        #expect(configuration.initialLocaleID == "zh-CN")
        #expect(configuration.initialDestination == .terminal)
    }
}

private actor RecordingTerminalBackend: TerminalBackend {
    var sentTexts: [String] = []
    nonisolated var stateStream: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
    nonisolated var outputStream: AsyncStream<Data> { AsyncStream { $0.finish() } }
    func connect(host: HostRecord) async throws {}
    func disconnect() async {}
    func send(text: String) async throws { sentTexts.append(text) }
    func send(chord: KeyChord, applicationCursorKeys: Bool) async throws {}
    func resize(columns: Int, rows: Int) async throws {}
    func run(command: String) async throws -> String { "" }
}

private actor FakeDictationEngine: DictationEngine {
    nonisolated var isAvailable: Bool { true }
    private(set) var requestedModes: [DictationMode] = []
    private(set) var stopCount = 0

    nonisolated func transcribe(locale: Locale, mode: DictationMode) -> AsyncThrowingStream<DictationUpdate, any Error> {
        Task { await record(mode) }
        return AsyncThrowingStream { continuation in continuation.finish() }
    }

    func stop() async { stopCount += 1 }

    private func record(_ mode: DictationMode) { requestedModes.append(mode) }
}

private struct FakeSendError: Error {}

private struct FailingUploadBackend: OpenPawBackend {
    func health() async throws -> HealthInfo { throw FakeSendError() }
    func sessions() async throws -> [SessionSummary] { [] }
    func inbox(status: InboxStatus?) async throws -> [InboxItem] { [] }
    func resolve(item: InboxItem, action: ActionID, answer: String?, detailAcknowledged: Bool) async throws -> ResolveResult { throw FakeSendError() }
    func events(session: String?, afterSeq: UInt64?) -> AsyncThrowingStream<Event, any Error> { AsyncThrowingStream { $0.finish() } }
    func repos() async throws -> [RepoSummary] { [] }
    func repoStatus(_ repo: String) async throws -> RepoStatus { throw FakeSendError() }
    func diff(repo: String, mode: DiffMode, path: String?) async throws -> Diff { throw FakeSendError() }
    func tree(repo: String, ref: String, path: String) async throws -> [TreeEntry] { [] }
    func blob(repo: String, ref: String, path: String) async throws -> Blob { throw FakeSendError() }
    func search(repo: String, query: String, path: String?) async throws -> [ContentMatch] { [] }
    func upload(data: Data, filename: String) async throws -> UploadResult { throw HostClientError.server(status: 507, body: "disk full") }
    func previewURL(port: Int, path: String) throws -> URL { URL(string: "http://127.0.0.1")! }
    func tailscaleDevices() async throws -> TailscaleDevicesResponse { throw FakeSendError() }
    func audit(limit: Int) async throws -> [AuditEntry] { [] }
}
