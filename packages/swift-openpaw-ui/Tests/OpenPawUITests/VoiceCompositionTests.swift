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
        #expect(voice.draft == "")
    }

    @Test func agentSendsOnlyExplicitSendAction() {
        var voice = VoiceComposition(destination: .agent, draft: "please")
        voice.start()
        #expect(voice.apply(DictationUpdate(text: "review this", isFinal: true)) == nil)

        let action = voice.commit()

        #expect(action == .sendAgent("please review this"))
        #expect(voice.draft == "")
    }

    @Test func stoppingKeepsDraftAndAcceptsOneLateFinalDeterministically() {
        var voice = VoiceComposition(destination: .agent, draft: "keep")
        voice.start()
        voice.apply(DictationUpdate(text: "partial", isFinal: false))
        voice.stop()
        #expect(voice.draft == "keep")
        #expect(voice.partialTranscript == "partial")

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
}
