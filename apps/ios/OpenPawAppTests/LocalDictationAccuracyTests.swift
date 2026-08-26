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

    /// The scoring behind the on-device verdict must discriminate, and the tag test must not be redundant.
    ///
    /// `characterErrorRate` decides whether the accuracy test passes, and it has never run in this repository
    /// either. A scorer that returned 0 on anything would make that test pass vacuously on the first phone that
    /// plugs in, and it would be believed. So this pins it against the transcripts both recognisers actually
    /// produced: Apple scores 0.379 on the three sentences and Qwen 0.0, which puts the 0.15 threshold in the
    /// gap rather than close to either side.
    ///
    /// The second half is the part worth keeping. `testTranscriptsArriveWithoutModelTags` looks redundant beside
    /// an accuracy test, and the obvious cleanup is to merge them. It is not redundant: a leaked `<|zh|>` on a
    /// long sentence costs 0.146 character error, which is *under* the threshold, so a transcript that pastes
    /// `<|zh|>` into the user's terminal would pass the accuracy test outright. This asserts that, so the next
    /// person to reach for the merge sees why it stays.
    func testTheScoringDiscriminatesAndALeakedTagCanStillSlipPastIt() {
        let truth = Self.sentences
        let apple = ["运行BPM in so安装", "用jacket提交这个改动", "这个poo request需要rave一下"]
        let qwen = [
            "运行 NPM install 安装依赖。", "用 Git Commit 提交这个改动。",
            "这个 pull request 需要 review 一下。",
        ]

        // A scorer that cannot tell these apart cannot be the basis of a verdict.
        let appleMean = zip(apple, truth)
            .map { DictationAccuracyTests.characterErrorRate(heard: $0, spoken: $1) }
            .reduce(0, +) / Double(truth.count)
        let qwenMean = zip(qwen, truth)
            .map { DictationAccuracyTests.characterErrorRate(heard: $0, spoken: $1) }
            .reduce(0, +) / Double(truth.count)

        XCTAssertGreaterThan(
            appleMean, 0.15,
            "the scorer rates Apple's real transcripts at \(appleMean), below the threshold the on-device test "
                + "uses. Either the scoring is broken or the threshold no longer means anything.")
        XCTAssertLessThan(
            qwenMean, 0.15,
            "the scorer rates the model's real transcripts at \(qwenMean), so the on-device test would fail on "
                + "output that is actually correct.")

        // Identical strings must be free, or every threshold is measuring the scorer's own noise.
        XCTAssertEqual(DictationAccuracyTests.characterErrorRate(heard: truth[0], spoken: truth[0]), 0)
        // And an empty transcript must be a total loss, not a free pass.
        XCTAssertEqual(DictationAccuracyTests.characterErrorRate(heard: "", spoken: truth[0]), 1)

        // Why the tag test is separate: on a sentence of ordinary length, a leaked tag hides under the threshold.
        let long = "这个 pull request 需要 review 一下然后合并到主分支再通知团队里的所有人"
        let leaked = DictationAccuracyTests.characterErrorRate(heard: "<|zh|>" + long, spoken: long)
        XCTAssertLessThan(
            leaked, 0.15,
            "a leaked model tag now scores \(leaked), above the accuracy threshold. If that stays true the tag "
                + "test really is redundant, but until then, deleting it lets `<|zh|>` reach a terminal with the "
                + "accuracy test still green.")
    }

    /// The audio harness the on-device tests depend on must actually produce audio, checked where it can run.
    ///
    /// The two accuracy tests above skip on every machine in this repository, so nothing in them has ever
    /// executed — including `synthesise` and `readSamples`, which are the parts most likely to be quietly
    /// broken. A phone arrives, the tests finally run, and they fail on a nil buffer or a wrong sample rate,
    /// which reads as "the model is bad" rather than "the test harness never worked". That would waste the one
    /// scarce thing here, which is time with hardware plugged in.
    ///
    /// Speech synthesis and audio conversion need no GPU, so this runs anywhere and pins the contract the
    /// accuracy tests assume: real samples arrive, at the 16 kHz mono the model expects, long enough to be a
    /// sentence and not silence. It deliberately does not transcribe anything.
    func testTheAudioHarnessTheOnDeviceTestsRelyOnActuallyProducesSamples() throws {
        let sentence = Self.sentences[0]
        guard let samples = try Self.synthesise(sentence, language: "zh-CN") else {
            throw XCTSkip(
                "no Chinese voice is installed on this machine, so synthesis produced nothing. The on-device "
                    + "accuracy tests would skip here too rather than fail.")
        }

        // A sentence at rate 0.45, resampled to 16 kHz, cannot be shorter than about a second. Anything less
        // means the write callback ended early and the accuracy tests would be transcribing a fragment.
        XCTAssertGreaterThan(
            samples.count, 16_000,
            "synthesis produced \(samples.count) samples, under a second at 16 kHz, for: \(sentence)")

        // Silence would still satisfy a length check while making every transcript empty, and an empty
        // transcript scores 100% error, which looks exactly like a bad model.
        let peak = samples.map(abs).max() ?? 0
        XCTAssertGreaterThan(
            peak, 0.01, "the synthesised audio is silent (peak \(peak)); the model would hear nothing")

        // The wrapper hands these straight to the model, which assumes normalised float samples. Values outside
        // this range mean the conversion is wrong and inference would be garbage in a way no assertion names.
        XCTAssertLessThanOrEqual(peak, 1.0, "samples are not normalised floats (peak \(peak))")
        XCTAssertFalse(
            samples.contains { $0.isNaN || $0.isInfinite },
            "the converted audio contains NaN or infinite samples")
    }

    /// The sentence shown to a user on an unsupported device must stay the sentence the UI test looks for.
    ///
    /// `DictationEngineSettingsUITests` finds that row by searching the screen for "real device". That string
    /// lives here, in the app, and nothing connects the two but hope. Reword this reason and the only thing that
    /// notices is a four-minute UI test on a simulator, whose failure reads like a broken picker rather than like
    /// a renamed string. This is the cheap check that fails first and says which it was. It also pins the shape of
    /// the sentence: a reason a person can act on, not a Metal error, and never a promise that retrying helps.
    func testTheUnsupportedReasonStaysTheSentenceTheUITestSearchesFor() throws {
        let reason = LocalASRModelStore.simulatorReason
        XCTAssertTrue(
            reason.lowercased().contains("real device"),
            "DictationEngineSettingsUITests locates the unsupported row by searching for 'real device'. "
                + "This reason no longer contains it, so that test is now looking for a string nothing shows: "
                + reason
        )
        // Whatever it says, it must not sound like something a second attempt would fix, because nothing here
        // is retryable — the device has no GPU this model can use, and that will not change on a retry.
        for misleading in ["try again", "retry", "failed", "error"] {
            XCTAssertFalse(
                reason.lowercased().contains(misleading),
                "the reason reads like a transient failure ('\(misleading)'), inviting a retry that cannot work: "
                    + reason
            )
        }
        // And it has to fit a settings row rather than wrap into a paragraph.
        XCTAssertLessThanOrEqual(
            reason.count, 80,
            "this has to fit on one settings row; at \(reason.count) characters it will wrap or truncate: "
                + reason
        )
    }

    /// The legacy enum case stays decodable, but no runtime path may build or return Apple's recogniser.
    ///
    /// This is not just a settings rule. The factory is the last gate before a hold opens the microphone, so returning
    /// nil here is what prevents a stored `apple` value or a debug launch argument from silently selecting Apple.
    func testFactoryRefusesLegacyAppleSpeechChoice() async {
        let store = await MainActor.run { LocalASRModelStore() }
        let engine = await MainActor.run {
            LocalASREngineFactory(store: store).engine(for: .appleSpeech)
        }
        XCTAssertNil(engine, "the legacy Apple choice must not construct or return SpeechDictation")
    }

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

        // The legacy Apple case is decoding-only now. Returning nil makes a stored `apple` value flow into the same
        // unavailable guidance as any missing local model instead of silently running SFSpeechRecognizer.
        let apple = await MainActor.run {
            LocalASREngineFactory(store: store).engine(for: .appleSpeech)
        }
        XCTAssertNil(apple, "Apple's recogniser must never be returned, including on a simulator")
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
            // Angle brackets were the bug, but the rest of shell syntax deserves the same guarantee, because the
            // next person to reach for a regex here will be aiming at one of these.
            "ls | grep foo",
            "echo `date`",
            "a && b || c",
            "awk '{print $1}' file",
            "curl -H 'X-A: b' https://x/y?a=1&b=2",
            "sed 's/<old>/<new>/g' f.txt",
            "cat <<EOF > f.txt",
        ] {
            XCTAssertEqual(
                LoadedASRModel.clean(command), command,
                "the transcript cleaner rewrote a shell command the user dictated")
        }

        // The exact strings the model produced in the last benchmark run, which is what actually reaches a
        // terminal. Transcripts, not invented fixtures: if the cleaner damages one of these, the numbers in
        // tools/dictation-cer/README.md describe an experience nobody is having.
        for transcript in [
            "运行 NPM install 安装依赖。",
            "用 Git Commit 提交这个改动。",
            "把这个文件 rename 成 index.ts。",
            "先 C D 到项目根目录，再跑测试。",
            "这个 pull request 需要 review 一下。",
            "Run npm install to fetch the dependencies.",
        ] {
            XCTAssertEqual(
                LoadedASRModel.clean(transcript), transcript,
                "the cleaner altered a transcript the model actually produced in the benchmark")
        }

        // A tag in the middle is still a tag and still goes, so the fix did not simply stop stripping.
        XCTAssertEqual(LoadedASRModel.clean("test <|zh|> mid tag"), "test  mid tag")

        // A stray opening tag must not swallow the rest of the sentence.
        let stray = LoadedASRModel.clean("<|zh 运行 npm install 安装依赖")
        XCTAssertTrue(
            stray.contains("npm install"),
            "an unterminated model tag ate the command: \(stray)")
    }

    /// The benchmark's copy of the cleaner must match the app's.
    ///
    /// `tools/dictation-cer` reimplements `clean` because a macOS command line tool cannot link the app target,
    /// and its comment asks the next person to keep the two in step. A comment is not a mechanism: the two had in
    /// fact drifted apart the moment the app's copy was fixed, and the only thing that would have noticed is
    /// somebody rereading both files. Since the benchmark's entire claim is that it measures what ships, a
    /// divergence makes the numbers in its README quietly wrong.
    ///
    /// Compares source text rather than behaviour, because behaviour would need the tool linked in, which is the
    /// thing that cannot be done.
    ///
    /// It has already earned its place: it failed on the first run, on a real divergence introduced minutes
    /// earlier, before anybody had noticed.
    func testTheBenchmarkCleanerStillMatchesTheAppsCleaner() throws {
        // Walks up from this file to the repository root, so it works from any derived-data location.
        var root = URL(fileURLWithPath: #filePath)
        while root.pathComponents.count > 1, root.lastPathComponent != "openpaw" {
            root.deleteLastPathComponent()
        }
        let benchmark = root
            .appendingPathComponent("tools/dictation-cer/Sources/dictation-cer/main.swift")
        guard let text = try? String(contentsOf: benchmark, encoding: .utf8) else {
            throw XCTSkip("the benchmark source is not reachable from this checkout")
        }

        // The regex the app uses, as it appears in Swift source: inside a normal string literal each backslash is
        // written twice, so this looks doubled compared with the pattern the regex engine actually sees.
        let appPattern = #"<\\|[^|]{0,40}\\|>"#
        XCTAssertTrue(
            text.contains(appPattern),
            "tools/dictation-cer no longer strips tags the way the app does, so its numbers describe "
                + "something that does not ship")

        // And it must not have reacquired the one that ate shell redirection.
        XCTAssertFalse(
            text.contains(#"<[^>]{0,40}>"#),
            "tools/dictation-cer strips anything in angle brackets again, which deletes shell redirection")
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
