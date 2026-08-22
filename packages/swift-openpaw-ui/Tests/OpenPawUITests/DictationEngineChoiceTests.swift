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
    func chineseExcludesParakeet() {
        // Parakeet does not fail on Chinese — it transliterates it into English syllables, which looks like a
        // transcript and is not one. Offering it is worse than offering nothing.
        let choices = DictationEngineChoice.choices(forLocale: "zh-CN")
        #expect(!choices.contains(.parakeet))
        #expect(choices.contains(.qwen3Small))
        #expect(choices.contains(.appleSpeech))

        // Every spelling of Chinese a locale picker can produce, not just the canonical one.
        for identifier in ["zh-Hans-CN", "zh_CN", "zh-TW", "ZH-CN"] {
            #expect(
                !DictationEngineChoice.choices(forLocale: identifier).contains(.parakeet),
                "\(identifier) is Chinese and Parakeet cannot transcribe it")
        }
    }

    @Test("an English speaker is offered every engine")
    func englishOffersEverything() {
        let choices = DictationEngineChoice.choices(forLocale: "en-US")
        #expect(choices.count == DictationEngineChoice.allCases.count)
    }

    @Test("a stored choice that cannot serve the language falls back rather than transliterating")
    func resolveFallsBack() {
        #expect(DictationEngineChoice.resolve(.parakeet, forLocale: "zh-CN") == .appleSpeech)
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
        #expect(settings.effectiveDictationEngine == .appleSpeech, "but it is not what runs on Chinese")

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

    @Test("a fresh install dictates with the engine that needs no download")
    func defaultIsAppleSpeech() {
        let settings = OpenPawSettings(defaults: Self.freshDefaults())
        #expect(settings.dictationEngine == .appleSpeech)
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
        #expect(snapshot.dictationEngine == .appleSpeech)
        #expect(snapshot.dictationLocaleID == "en-US")
    }

    @Test("an exported snapshot carries the engine and restores it")
    func snapshotRoundTripsEngine() throws {
        let settings = OpenPawSettings(defaults: Self.freshDefaults())
        settings.dictationEngine = .qwen3Large
        let data = try JSONEncoder().encode(settings.snapshot(eventBudget: 2_000))

        let restored = OpenPawSettings(defaults: Self.freshDefaults())
        restored.apply(try JSONDecoder().decode(SettingsSnapshot.self, from: data))
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

    @Test("download state says something specific enough to act on")
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

    @Test("only the streaming engine claims to stream")
    func streamingIsDeclaredHonestly() {
        #expect(DictationEngineChoice.appleSpeech.streamsPartialResults)
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

    private static func freshDefaults() -> UserDefaults {
        let suite = "openpaw.tests.dictation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
