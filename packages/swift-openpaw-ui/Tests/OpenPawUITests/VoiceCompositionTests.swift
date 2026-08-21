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
