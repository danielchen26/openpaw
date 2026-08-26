import Foundation
import Testing

@testable import OpenPawUI

/// Which recogniser a user ends up talking to, and what the screen tells them about it.
///
/// This is a settings surface, so the failures are not crashes: they are a picker that offers an engine which
/// cannot hear the selected language, a "Ready" label over weights that were never downloaded, and a privacy
/// sentence that describes the wrong engine. Each of those is a lie the user acts on.
@MainActor
@Suite("Dictation engine choice")
struct DictationEngineChoiceTests {

    @Test("an engine that cannot hear Chinese is not offered to someone dictating Chinese")
    func chineseExcludesParakeetAndApple() {
        // Parakeet does not fail on Chinese — it transliterates it into English syllables, which looks like a
        // transcript and is not one. Apple is legacy decoding only and must not be offered at all.
        let choices = DictationEngineChoice.choices(forLocale: "zh-CN")
        #expect(!choices.contains(.parakeet))
        #expect(!choices.contains(.appleSpeech))
        #expect(choices.contains(.qwen3Small))

        // Every spelling of Chinese a locale picker can produce, not just the canonical one.
        for identifier in ["zh-Hans-CN", "zh_CN", "zh-TW", "ZH-CN"] {
            #expect(
                !DictationEngineChoice.choices(forLocale: identifier).contains(.parakeet),
                "\(identifier) is Chinese and Parakeet cannot transcribe it")
            #expect(
                !DictationEngineChoice.choices(forLocale: identifier).contains(.appleSpeech),
                "\(identifier) must not expose Apple's legacy recogniser")
        }
    }

    @Test("Apple Speech is never offered for any visible locale")
    func appleSpeechIsNeverOffered() {
        for identifier in ["en-US", "zh-CN", "zh-Hans-CN", "ja-JP", "de-DE"] {
            #expect(
                !DictationEngineChoice.choices(forLocale: identifier).contains(.appleSpeech),
                "\(identifier) offered Apple's legacy recogniser")
        }
    }

    @Test("an English speaker is offered only local engines")
    func englishOffersLocalEngines() {
        let choices = DictationEngineChoice.choices(forLocale: "en-US")
        #expect(choices == [.qwen3Small, .qwen3Large, .parakeet])
    }

    @Test("a stored choice that cannot serve the language falls back to the default local model")
    func resolveFallsBack() {
        #expect(DictationEngineChoice.resolve(.appleSpeech, forLocale: "en-US") == .qwen3Small)
        #expect(DictationEngineChoice.resolve(.appleSpeech, forLocale: "zh-CN") == .qwen3Small)
        #expect(DictationEngineChoice.resolve(.parakeet, forLocale: "zh-CN") == .qwen3Small)
        #expect(DictationEngineChoice.resolve(.parakeet, forLocale: "en-US") == .parakeet)
        #expect(DictationEngineChoice.resolve(.qwen3Large, forLocale: "zh-CN") == .qwen3Large)
    }

    @Test("switching language does not overwrite the engine the user chose")
    func localeChangeKeepsStoredChoice() {
        // A user who picked Parakeet for English and dictates one Chinese sentence must find Parakeet still
        // selected when they switch back, not silently demoted to Apple forever.
        let settings = OpenPawSettings(defaults: Self.freshDefaults())
        settings.dictationEngine = .parakeet
        settings.dictationLocaleID = "zh-CN"

        #expect(settings.dictationEngine == .parakeet, "the stored preference survives")
        #expect(settings.effectiveDictationEngine == .qwen3Small, "but Chinese falls back to the default local model")

        settings.dictationLocaleID = "en-US"
        #expect(settings.effectiveDictationEngine == .parakeet)
    }

    @Test("the engine choice survives a relaunch")
    func choiceIsPersisted() {
        let defaults = Self.freshDefaults()
        let first = OpenPawSettings(defaults: defaults)
        first.dictationEngine = .qwen3Small

        let second = OpenPawSettings(defaults: defaults)
        #expect(second.dictationEngine == .qwen3Small, "paying for a 450 MB download once should be enough")
    }

    @Test("a fresh install defaults to Qwen3 0.6B")
    func defaultIsQwen3Small() {
        let settings = OpenPawSettings(defaults: Self.freshDefaults())
        #expect(settings.dictationEngine == .qwen3Small)
        #expect(settings.effectiveDictationEngine == .qwen3Small)
    }

    @Test("a stored legacy Apple choice migrates to Qwen3 0.6B")
    func storedAppleMigratesToQwen3Small() {
        let defaults = Self.freshDefaults()
        defaults.set("apple", forKey: "openpaw.settings.dictationEngine")

        let settings = OpenPawSettings(defaults: defaults)

        #expect(settings.dictationEngine == .qwen3Small)
        #expect(defaults.string(forKey: "openpaw.settings.dictationEngine") == DictationEngineChoice.qwen3Small.rawValue)
    }

    @Test("a settings file exported before engine choice existed still imports")
    func snapshotDecodesWithoutEngineField() throws {
        // Adding a required field to a `Codable` export silently breaks every backup taken before it, which the
        // user discovers as "import failed" with all their hosts and shortcuts still in the file.
        let legacy = """
            {
              "requires_biometric_gate": true,
              "dictation_locale": "en-US",
              "dictation_mode": "composer",
              "terminal_font_size": 13,
              "terminal_theme": "slate",
              "scrollback_lines": 10000,
              "application_cursor_keys": false,
              "preview_port": 3000,
              "event_budget_per_session": 2000,
              "shortcuts": {"version": 1, "shortcuts": []},
              "session_profiles": {}
            }
            """
        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: Data(legacy.utf8))
        #expect(snapshot.dictationEngine == .qwen3Small)
        #expect(snapshot.dictationLocaleID == "en-US")
    }
    @Test("legacy Apple snapshots import as Qwen3 0.6B")
    func snapshotDecodesLegacyAppleAsQwen3Small() throws {
        let legacy = """
            {
              "requires_biometric_gate": true,
              "dictation_locale": "en-US",
              "dictation_mode": "composer",
              "dictation_engine": "apple",
              "terminal_font_size": 13,
              "terminal_theme": "slate",
              "scrollback_lines": 10000,
              "application_cursor_keys": false,
              "preview_port": 3000,
              "event_budget_per_session": 2000,
              "shortcuts": {"version": 1, "shortcuts": []},
              "session_profiles": {}
            }
            """
        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: Data(legacy.utf8))
        #expect(snapshot.dictationEngine == .qwen3Small)
    }


    func snapshotRoundTripsEngine() throws {
        let settings = OpenPawSettings(defaults: Self.freshDefaults())
        settings.dictationEngine = .qwen3Large
        settings.eventBudgetPerSession = 2_000
        let data = try JSONEncoder().encode(settings.snapshot())

        let restored = OpenPawSettings(defaults: Self.freshDefaults())
        let proposal = try SettingsImportProposal.parse(data, current: restored)
        try restored.apply(proposal, confirmSecurityReductions: true)
        #expect(restored.dictationEngine == .qwen3Large)
    }

    @Test("every downloadable engine names the repository its weights come from")
    func downloadableEnginesHaveModelIDs() {
        for choice in DictationEngineChoice.allCases {
            if choice.requiresDownload {
                #expect(choice.modelID != nil, "\(choice) claims a download with nowhere to download from")
                #expect(choice.approximateDownloadMegabytes > 0)
            } else {
                #expect(choice.modelID == nil)
                #expect(choice.approximateDownloadMegabytes == 0)
            }
        }
    }
    @Test("Qwen3 names distinguish default high accuracy from maximum accuracy")
    func qwenAccuracyLabelsAreClear() {
        #expect(DictationEngineChoice.qwen3Small.summary.contains("Default high accuracy"))
        #expect(DictationEngineChoice.qwen3Large.summary.contains("Maximum accuracy"))
        #expect(DictationEngineChoice.qwen3Small.approximateDownloadMegabytes == 450)
        #expect(DictationEngineChoice.qwen3Large.approximateDownloadMegabytes == 1_900)
    }


    func stateTextIsActionable() {
        #expect(DictationModelState.absent.statusText == "Not downloaded")
        #expect(DictationModelState.installed.isInstalled)
        #expect(DictationModelState.downloading(progress: 0.5, detail: "Downloading weights").isBusy)
        #expect(DictationModelState.downloading(progress: 0.5, detail: "Downloading weights").statusText
            == "Downloading weights 50%")
        // The reason survives into the label, because "Download failed" alone leaves the user with no next move.
        #expect(DictationModelState.failed("no network").statusText == "Download failed: no network")
        #expect(DictationModelState.failed("no network").isInstalled == false)
    }

    @Test("the legacy Apple engine never claims to stream in current policy")
    func streamingIsDeclaredHonestly() {
        #expect(!DictationEngineChoice.appleSpeech.streamsPartialResults)
        for choice in DictationEngineChoice.allCases where choice.requiresDownload {
            #expect(
                !choice.streamsPartialResults,
                "\(choice) transcribes a whole recording, so promising live words would be a lie")
        }
    }

    @Test("the recogniser the screen shows is always one the picker actually offers")
    func resolvedEngineIsAlwaysOffered() {
        // A SwiftUI Picker whose selection matches none of its tags renders as an empty box. The recogniser field
        // is populated from the resolved engine and its options from the same locale filter, so this pairing is
        // what keeps a user who picked Parakeet and then switched to Chinese from seeing a blank control.
        for locale in ["en-US", "zh-CN", "zh-Hans-CN", "ja-JP", "de-DE"] {
            let offered = DictationEngineChoice.choices(forLocale: locale)
            for stored in DictationEngineChoice.allCases {
                let resolved = DictationEngineChoice.resolve(stored, forLocale: locale)
                #expect(
                    offered.contains(resolved),
                    "\(stored) in \(locale) resolves to \(resolved), which the picker does not list")
            }
        }
    }

    @Test("a state the user cannot act on says so, and every other one offers a way forward")
    func unsupportedIsNotOfferedAsRetryable() {
        // The row switches over the state exhaustively rather than reading this, so that a new state cannot be
        // silently absorbed. This asserts the two agree: `unsupported` is the one case that draws no button, and
        // the difference is a device that cannot run the model saying so once, versus offering a 450 MB download
        // that ends in the same place.
        #expect(!DictationModelState.unsupported("no GPU").isActionable)
        #expect(DictationModelState.absent.isActionable)
        #expect(DictationModelState.failed("network").isActionable)
        #expect(DictationModelState.installed.isActionable)
        #expect(DictationModelState.downloading(progress: 0.2, detail: "Fetching").isActionable)

        // And it is never mistaken for a usable model: `isInstalled` gates the engine factory, so an unsupported
        // state reading as installed is exactly the bug that crashes the app on a simulator.
        #expect(!DictationModelState.unsupported("no GPU").isInstalled)

        // The reason reaches the screen verbatim rather than being wrapped in "Download failed", which would be
        // a false description of a device that never attempted a download.
        #expect(DictationModelState.unsupported("Needs a real device").statusText == "Needs a real device")
    }

    @Test("finishing a model download invalidates the root push-to-talk configuration")
    func rootConfigurationTracksModelState() {
        let settings = OpenPawSettings(defaults: Self.freshDefaults())
        settings.dictationEngine = .qwen3Small
        let store = StubDictationModelStore(states: [.qwen3Small: .absent])
        let model = OpenPawModel(dictationModels: store, settings: settings)

        let before = RootPushToTalkConfiguration.make(model: model, settings: settings)
        store.states[.qwen3Small] = .installed
        let after = RootPushToTalkConfiguration.make(model: model, settings: settings)

        #expect(before != after)
        #expect(before.modelState == .absent)
        #expect(after.modelState == .installed)
    }

    private static func freshDefaults() -> UserDefaults {
        let suite = "openpaw.tests.dictation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
