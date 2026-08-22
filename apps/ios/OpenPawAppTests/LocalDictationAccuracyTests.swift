import AVFoundation
import Foundation
import OpenPawUI
import XCTest

@testable import OpenPawApp

/// Proves the fix works where it has to work: on the device, through the app's own code.
///
/// `tools/dictation-cer` already measures the models, but it is a macOS command line tool linking the packages
/// directly. That leaves the interesting question open — whether the *app's* wrapper around them, running under
/// iOS, produces the same transcripts. The wrapper is not a thin one: it strips model tags, derives a language
/// code from the user's locale setting, and serialises calls through an actor. A benchmark that bypasses all of
/// that is measuring a library, not a feature.
///
/// **These will not run on a simulator, and that is not a configuration mistake.** MLX needs Metal features the
/// simulator's software renderer does not implement, and it fails in two stages. First `MTLSimDevice` returns a
/// null `architecture()->name()`, which MLX copies straight into a `std::string` and aborts on. Setting
/// `MLX_METAL_GPU_ARCH` gets past that and into the real wall: `newHeapWithDescriptor:` asserts
/// `MTLStorageModePrivate is required for heaps`, and MLX allocates shared-storage heaps because unified memory
/// is the entire premise of running a language model on a phone. There is no flag for that one.
///
/// So this file is the on-device half of the acceptance evidence, and it needs a cable. It is written, registered
/// in the test target, and skips cleanly everywhere else, so plugging in a phone is all that stands between the
/// repository and a measured answer.
///
/// Skipped unless the weights are already on disk. Downloading 450 MB inside a test would make the suite depend
/// on somebody's network, and the download path is exercised by the settings screen instead.
final class LocalDictationAccuracyTests: XCTestCase {

    /// True when this build is running against a simulator, where MLX cannot allocate a Metal heap at all.
    ///
    /// Checked before the weights are, so the skip reason names the real obstacle. A developer who sees "weights
    /// are not on this device" on a simulator would go and download 450 MB into a container where they can never
    /// be used.
    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            return false
        #endif
    }

    /// The sentence this whole feature exists for, and the two Apple destroys most reliably.
    ///
    /// Apple hears "运行 npm install 安装依赖" as "运行BPM in so安装" and "用 git commit 提交这个改动" as
    /// "用jacket提交这个改动" — in both cases the Chinese survives and the command name, the only part that must be
    /// exact, does not.
    private static let sentences = [
        "运行 npm install 安装依赖",
        "用 git commit 提交这个改动",
        "这个 pull request 需要 review 一下",
    ]

    /// The local model transcribes what Apple cannot, through the app's own wrapper and on this device.
    ///
    /// The threshold is 15% rather than 0% because synthesis and quantisation both add noise, and a test that
    /// demands perfection is a test that will be deleted the first time it flakes. Apple averages well over 40% on
    /// these three, so 15% is nowhere near close enough to pass by accident.
    func testTheLocalModelHearsCommandNamesApplesRecogniserDestroys() async throws {
        try XCTSkipIf(isSimulator, "MLX cannot allocate a Metal heap on a simulator; run this on a phone")
        let store = await MainActor.run { LocalASRModelStore() }
        let choice = DictationEngineChoice.qwen3Small
        let installed = await MainActor.run { store.state(of: choice).isInstalled }
        try XCTSkipUnless(
            installed,
            "\(choice.displayName) weights are not on this device; download them in Settings to run this"
        )

        let model = try await store.loadedModel(for: choice)
        var rates: [Double] = []
        for sentence in Self.sentences {
            guard let samples = try Self.synthesise(sentence, language: "zh-CN") else {
                XCTFail("could not synthesise \(sentence)")
                continue
            }
            let heard = try await model.transcribe(
                samples: samples, locale: Locale(identifier: "zh-CN"), mode: .terminal)
            let rate = DictationAccuracyTests.characterErrorRate(heard: heard, spoken: sentence)
            print("LOCAL ASR spoke=\"\(sentence)\" heard=\"\(heard)\" cer=\(rate)")
            rates.append(rate)
        }

        let mean = rates.reduce(0, +) / Double(rates.count)
        XCTAssertLessThan(
            mean, 0.15,
            "the local model is \(Int(mean * 100))% wrong per character on the sentences it was shipped to fix, "
                + "which means the 450 MB download is buying the user nothing"
        )
    }

    /// A transcript still carrying `<|zh|>` is a debug string, and it would be pasted straight into a terminal.
    ///
    /// Asserted separately from accuracy because a leaked tag can score well on character error rate while being
    /// completely unusable — the edit distance barely notices four characters on the front of a sentence, and the
    /// user notices immediately.
    func testTranscriptsArriveWithoutModelTags() async throws {
        try XCTSkipIf(isSimulator, "MLX cannot allocate a Metal heap on a simulator; run this on a phone")
        let store = await MainActor.run { LocalASRModelStore() }
        let choice = DictationEngineChoice.qwen3Small
        let installed = await MainActor.run { store.state(of: choice).isInstalled }
        try XCTSkipUnless(installed, "\(choice.displayName) weights are not on this device")

        let model = try await store.loadedModel(for: choice)
        guard let samples = try Self.synthesise("运行 npm install 安装依赖", language: "zh-CN") else {
            throw XCTSkip("could not synthesise the probe sentence")
        }
        let heard = try await model.transcribe(
            samples: samples, locale: Locale(identifier: "zh-CN"), mode: .terminal)
        XCTAssertFalse(heard.contains("<|"), "a model tag reached the transcript: \(heard)")
        XCTAssertFalse(heard.contains("<"), "a stray angle bracket reached the transcript: \(heard)")
        XCTAssertEqual(
            heard, heard.trimmingCharacters(in: .whitespacesAndNewlines),
            "the transcript has leading or trailing whitespace, which lands in the composer")
    }

    /// The guard that keeps a simulator from taking the app down, asserted where the danger actually is.
    ///
    /// Inverted on purpose: this is the one test in the file that runs on a simulator and skips on a phone. The
    /// other two need hardware, so without this the whole file would be green-by-absence in CI, which is the state
    /// a test file drifts into and rots in. Here the failure of the guard *is* the crash — if `state(of:)` ever
    /// reports installed again on a simulator, the factory hands back an engine, the user holds the button, and
    /// Metal aborts the process. So this asserts the three separate doors are all shut.
    func testLocalEnginesAreRefusedOnASimulatorRatherThanCrashing() async throws {
        try XCTSkipUnless(isSimulator, "this asserts the simulator guard, and there is no guard on a phone")
        let store = await MainActor.run { LocalASRModelStore() }

        for choice in DictationEngineChoice.allCases where choice.requiresDownload {
            let state = await MainActor.run { store.state(of: choice) }
            guard case .unsupported = state else {
                return XCTFail("\(choice.displayName) reports \(state) on a simulator, which crashes on load")
            }
            XCTAssertFalse(state.isInstalled, "\(choice.displayName) must never look loadable here")
            XCTAssertFalse(state.isActionable, "\(choice.displayName) must not offer a download that cannot work")

            // The factory is what the push-to-talk hold asks, and nil is what makes it say "unavailable" rather
            // than arming a ring over an engine that will kill the process.
            let engine = await MainActor.run {
                LocalASREngineFactory(store: store).engine(for: choice)
            }
            XCTAssertNil(engine, "\(choice.displayName) handed back an engine that aborts on first use")

            // And the loader itself, reachable directly, throws instead of reaching MLX.
            do {
                _ = try await store.loadedModel(for: choice)
                XCTFail("\(choice.displayName) loaded on a simulator, which should be impossible")
            } catch LocalASRError.simulatorUnsupported {
                // Correct: a Swift error, which a caller can show, rather than a C++ abort nobody can catch.
            } catch {
                XCTFail("\(choice.displayName) threw \(error) rather than naming the simulator")
            }
        }

        // Apple's recogniser is untouched by all of this. If the guard ever widened to catch it, dictation would
        // be gone entirely on a simulator and the settings screen would be inert for no reason.
        let apple = await MainActor.run {
            LocalASREngineFactory(store: store).engine(for: .appleSpeech)
        }
        XCTAssertNotNil(apple, "Apple's recogniser still has to work on a simulator")
    }

    /// What the model says must reach the terminal unchanged, apart from the model's own tags.
    ///
    /// Runs everywhere, GPU or not, because it is pure string work — and it had to be pulled out of the actor to
    /// be reachable at all, which is the point: this function decides what gets typed into somebody's shell and
    /// until now nothing could test it.
    ///
    /// It caught a real one. The stripper also removed anything matching `<[^>]*>`, so
    /// `cat < input.txt > output.txt` arrived as `cat  output.txt`: a different command, still valid, silently
    /// substituted for the one the user spoke. In a chat box that is a cosmetic bug. In a terminal draft the user
    /// is about to execute, it is the worst thing this app could do.
    func testShellRedirectionSurvivesTagStripping() {
        // The tags this exists for.
        XCTAssertEqual(LoadedASRModel.clean("<|zh|>运行 npm install"), "运行 npm install")
        XCTAssertEqual(LoadedASRModel.clean("<|en|><|transcribe|>git status"), "git status")
        XCTAssertEqual(LoadedASRModel.clean("  git commit  \n"), "git commit")

        // Shell syntax, which must not be touched. Every one of these was mangled before.
        for command in [
            "cat < input.txt > output.txt",
            "sort < a.txt > b.txt",
            "diff <(ls) <(ls -a)",
            "grep foo < log",
            "echo hi > /dev/null 2>&1",
            "python3 -c 'print(1 < 2)'",
            "if [ $a -lt $b ]; then echo '<yes>'; fi",
        ] {
            XCTAssertEqual(
                LoadedASRModel.clean(command), command,
                "the transcript cleaner rewrote a shell command the user dictated")
        }

        // A stray opening tag must not swallow the rest of the sentence.
        let stray = LoadedASRModel.clean("<|zh 运行 npm install 安装依赖")
        XCTAssertTrue(
            stray.contains("npm install"),
            "an unterminated model tag ate the command: \(stray)")
    }

    // MARK: Machinery

    /// A sentence as 16 kHz mono float, which is exactly what `LocalASRSession` hands the model from the
    /// microphone. Producing anything else would test a resampler the app does not use.
    private static func synthesise(_ text: String, language: String) throws -> [Float]? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openpaw-local-asr-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = 0.45

        var file: AVAudioFile?
        let done = XCTestExpectation(description: "synthesis")
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                done.fulfill()
                return
            }
            do {
                if file == nil {
                    file = try AVAudioFile(
                        forWriting: url, settings: pcm.format.settings,
                        commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                }
                try file?.write(from: pcm)
            } catch {
                done.fulfill()
            }
        }
        _ = XCTWaiter().wait(for: [done], timeout: 30)
        file = nil
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try readSamples(url)
    }

    private static func readSamples(_ url: URL) throws -> [Float]? {
        let file = try AVAudioFile(forReading: url)
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { return nil }

        let ratio = 16_000 / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(file.length) * ratio) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            guard
                let input = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                (try? file.read(into: input)) != nil
            else {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if conversionError != nil { return nil }
        guard let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
