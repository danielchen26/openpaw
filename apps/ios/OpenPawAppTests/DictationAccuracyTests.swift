import AVFoundation
import Foundation
import OpenPawUI
import Speech
import XCTest

@testable import OpenPawApp

/// What the speech engine actually does with the sentences this app exists to hear.
///
/// The roadmap calls mixed Chinese/English input a first-class requirement rather than a later fix. That claim was
/// never measured. These tests measure it, against the real Speech framework, on synthesised speech so the numbers
/// do not depend on anyone being in the room.
///
/// Synthesised speech is cleaner than a person in a café, so every error rate here is a floor rather than an
/// estimate: the real thing can only be worse. That is the useful direction for a regression test — a number that
/// cannot be reached under ideal conditions will not be reached under real ones.
final class DictationAccuracyTests: XCTestCase {

    /// A sentence, and the language its speaker is speaking.
    private struct Utterance {
        let text: String
        let locale: String
    }

    /// Prose in one language. This is the case both engines already handle.
    private static let monolingual = [
        Utterance(text: "列出这个目录下的所有文件", locale: "zh-CN"),
        Utterance(text: "提交代码然后推送到远程分支", locale: "zh-CN"),
        Utterance(text: "install the dependencies with npm", locale: "en-US"),
    ]

    /// A Chinese sentence with an English command name in it, which is how a bilingual developer actually talks to
    /// a terminal. Nobody says "使用版本控制系统提交" — they say "git commit".
    private static let mixed = [
        Utterance(text: "git status 看一下当前状态", locale: "zh-CN"),
        Utterance(text: "运行 npm install 安装依赖", locale: "zh-CN"),
        Utterance(text: "用 grep 搜索这个文件", locale: "zh-CN"),
        Utterance(text: "git commit 提交一下", locale: "zh-CN"),
    ]

    /// Single-language dictation works, and is worth pinning so a change to the engine cannot quietly break it.
    func testProseInOneLanguageIsTranscribedAccurately() throws {
        try requireAuthorization()
        var rates: [Double] = []
        for utterance in Self.monolingual {
            guard let heard = try transcribe(utterance) else { continue }
            let rate = Self.characterErrorRate(heard: heard, spoken: utterance.text)
            print("DICTATION mono spoke=\"\(utterance.text)\" heard=\"\(heard)\" cer=\(rate)")
            rates.append(rate)
        }
        try XCTSkipIf(rates.isEmpty, "no locale on this machine could transcribe anything")
        let mean = rates.reduce(0, +) / Double(rates.count)
        XCTAssertLessThan(
            mean, 0.15,
            "single-language dictation is \(Int(mean * 100))% wrong per character on clean synthesised speech, so "
                + "it will be far worse on a real voice in a real room"
        )
    }

    /// The case the roadmap calls first class, measured.
    ///
    /// This is deliberately a recorded measurement rather than a pass/fail line drawn where the engine happens to
    /// sit today. The threshold is loose enough to state the truth — mixed input is substantially worse than
    /// single-language input — without pretending the current number is acceptable.
    func testMixedChineseAndEnglishIsMeasured() throws {
        try requireAuthorization()
        var rates: [Double] = []
        for utterance in Self.mixed {
            guard let heard = try transcribe(utterance) else { continue }
            let rate = Self.characterErrorRate(heard: heard, spoken: utterance.text)
            print("DICTATION mixed spoke=\"\(utterance.text)\" heard=\"\(heard)\" cer=\(rate)")
            rates.append(rate)
        }
        try XCTSkipIf(rates.isEmpty, "no locale on this machine could transcribe anything")
        let mean = rates.reduce(0, +) / Double(rates.count)
        print("DICTATION mixed meanCER=\(mean)")

        // The engine mangles English command names inside a Chinese sentence: "git status" comes back as
        // "getting to", "git commit" as "Gecko meet". Recorded rather than asserted away, so that improving the
        // engine shows up here as a number moving rather than as a test that was always green.
        XCTAssertLessThan(
            mean, 0.60,
            "mixed Chinese/English dictation is \(Int(mean * 100))% wrong per character, which is past the point "
                + "where the transcript is worth editing rather than retyping"
        )
    }

    /// `contextualStrings` is the only lever the current engine offers for this, and it is worth knowing whether it
    /// pulls anything. Measured rather than assumed: the terminal mode sets it, so if it does nothing at all, that
    /// is a thing to know before building more on top of it.
    func testContextualStringsAreMeasuredAgainstCommandNames() throws {
        try requireAuthorization()
        let utterance = Utterance(text: "git status 看一下当前状态", locale: "zh-CN")
        guard let without = try transcribe(utterance, contextual: []),
            let with = try transcribe(utterance, contextual: ["git", "git status", "npm", "grep", "sudo"])
        else {
            throw XCTSkip("this machine could not transcribe the probe sentence")
        }
        let plain = Self.characterErrorRate(heard: without, spoken: utterance.text)
        let hinted = Self.characterErrorRate(heard: with, spoken: utterance.text)
        print("DICTATION contextual without=\"\(without)\" cer=\(plain)")
        print("DICTATION contextual with=\"\(with)\" cer=\(hinted)")
        XCTAssertLessThanOrEqual(
            hinted, plain + 0.001,
            "supplying the command names as contextual strings made recognition worse, so terminal mode is paying "
                + "accuracy for a hint that costs it"
        )
    }

    // MARK: Machinery

    private func requireAuthorization() throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return }
        let waited = XCTestExpectation(description: "speech authorization")
        SFSpeechRecognizer.requestAuthorization { _ in waited.fulfill() }
        _ = XCTWaiter().wait(for: [waited], timeout: 20)
        try XCTSkipUnless(
            SFSpeechRecognizer.authorizationStatus() == .authorized,
            "speech recognition is not authorised on this machine"
        )
    }

    /// Runs one utterance through the same recogniser configuration the app uses in terminal mode.
    private func transcribe(_ utterance: Utterance, contextual: [String]? = nil) throws -> String? {
        let locale = Locale(identifier: utterance.locale)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { return nil }
        guard let audio = Self.synthesise(utterance.text, voice: utterance.locale) else { return nil }
        defer { try? FileManager.default.removeItem(at: audio) }

        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        // Terminal mode's settings: no punctuation, and the command names the app supplies as context.
        request.addsPunctuation = false
        request.contextualStrings =
            contextual ?? ["git", "npm", "pnpm", "cargo", "kubectl", "grep", "sudo", "OpenPaw"]

        let finished = XCTestExpectation(description: "transcription")
        let transcript = NSMutableString()
        var failed = false
        recognizer.recognitionTask(with: request) { result, error in
            if error != nil {
                failed = true
                finished.fulfill()
                return
            }
            if let result, result.isFinal {
                transcript.setString(result.bestTranscription.formattedString)
                finished.fulfill()
            }
        }
        _ = XCTWaiter().wait(for: [finished], timeout: 45)
        if failed { return nil }
        let heard = transcript as String
        return heard.isEmpty ? nil : heard
    }

    /// Levenshtein distance over characters, divided by the length of what was said.
    ///
    /// Characters rather than words, because a word error rate is close to meaningless for Chinese: the sentence
    /// has no spaces in it, so word segmentation would be the thing being measured rather than recognition.
    /// Whitespace and punctuation are normalised away — the app's terminal mode strips punctuation anyway, and a
    /// missing space is not the failure anyone is complaining about.
    static func characterErrorRate(heard: String, spoken: String) -> Double {
        let a = Array(normalise(heard))
        let b = Array(normalise(spoken))
        guard !b.isEmpty else { return a.isEmpty ? 0 : 1 }
        guard !a.isEmpty else { return 1 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return Double(previous[b.count]) / Double(b.count)
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
    }

    /// A sentence rendered to audio the recogniser can read.
    private static func synthesise(_ text: String, voice: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openpaw-accuracy-\(UUID().uuidString).caf")
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: voice)
        // Slower than default: the point is to measure the recogniser, not the synthesiser's diction.
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
                        forWriting: url,
                        settings: pcm.format.settings,
                        commonFormat: pcm.format.commonFormat,
                        interleaved: pcm.format.isInterleaved
                    )
                }
                try file?.write(from: pcm)
            } catch {
                done.fulfill()
            }
        }
        _ = XCTWaiter().wait(for: [done], timeout: 30)
        file = nil
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
