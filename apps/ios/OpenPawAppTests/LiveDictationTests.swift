import AVFoundation
import Foundation
import OpenPawUI
import Speech
import XCTest

@testable import OpenPawApp

/// Keeps legacy `SpeechDictation` error classification covered without exercising it as an OpenPaw engine.
///
/// Apple Speech is no longer a runtime dictation path. The only active audio acceptance path is the local Qwen test in
/// `LocalDictationAccuracyTests` on a physical phone.
///
/// Skipped rather than failed when the environment cannot answer: no speech authorisation, or no on-device model
/// installed for the locale. Both are properties of the machine, not defects in the app, and a red test for them
/// would train us to ignore the suite.
final class LiveDictationTests: XCTestCase {

    func testDictationFailuresKeepDistinctActionablePresentations() throws {
        let failures: [(DictationError, String, String)] = [
            (.microphoneDenied, "microphone", "Settings"),
            (.speechRecognitionDenied, "speech recognition", "Settings"),
            (.recognizerUnavailable("en-US"), "unavailable", "Try again"),
            (.noSpeech, "No speech", "speak"),
            (.audioSessionFailed("busy"), "audio session", "call or recording"),
            (.audioEngineFailed("no input"), "microphone", "Try again"),
        ]

        for (failure, diagnosis, recovery) in failures {
            let message = try XCTUnwrap(failure.errorDescription)
            XCTAssertEqual(failure.localizedDescription, message, "the UI reads localizedDescription")
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains(diagnosis),
                "\(failure) does not diagnose the failure: \(message)"
            )
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains(recovery),
                "\(failure) does not tell the user what to do: \(message)"
            )
        }
    }

    func testSpeechFrameworkNoSpeechErrorIsClassifiedWithoutLosingOtherFailures() {
        let noSpeech = NSError(domain: "kAFAssistantErrorDomain", code: 1_110)
        XCTAssertEqual(
            SpeechDictation.classifyRecognitionError(noSpeech, locale: Locale(identifier: "en-US")),
            .noSpeech
        )

        let unavailable = NSError(domain: "kAFAssistantErrorDomain", code: 1_101)
        XCTAssertEqual(
            SpeechDictation.classifyRecognitionError(unavailable, locale: Locale(identifier: "zh-CN")),
            .recognizerUnavailable("zh-CN")
        )

        let existing = DictationError.audioEngineFailed("input route vanished")
        XCTAssertEqual(
            SpeechDictation.classifyRecognitionError(existing, locale: Locale(identifier: "en-US")),
            existing
        )
    }

    private struct RequiredDeviceCapabilityMissing: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Simulator infrastructure gaps are skips. The same gap on a physical device is failed acceptance evidence.
    private func unavailable(_ message: String) throws -> Never {
        #if targetEnvironment(simulator)
            throw XCTSkip(message)
        #else
            throw RequiredDeviceCapabilityMissing(message: message)
        #endif
    }

    private func requireAuthorization() throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return }
        let waited = XCTestExpectation(description: "speech authorization")
        SFSpeechRecognizer.requestAuthorization { _ in waited.fulfill() }
        _ = XCTWaiter().wait(for: [waited], timeout: 20)
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            try unavailable("speech recognition is not authorised on this test device")
        }
    }

    /// The microphone the app would record from has to actually deliver samples, or dictation is dead before the
    /// recogniser is ever involved.
    func testTheMicrophoneDeliversAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true)
        defer { try? session.setActive(false) }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { try unavailable("this test device exposes no usable audio input") }

        let counted = NSLock()
        var frames = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            counted.lock()
            frames += Int(buffer.frameLength)
            counted.unlock()
        }
        try engine.start()
        Thread.sleep(forTimeInterval: 2)
        engine.stop()
        input.removeTap(onBus: 0)

        counted.lock()
        let captured = frames
        counted.unlock()
        XCTAssertGreaterThan(captured, 0, "the audio tap produced no frames, so dictation has nothing to transcribe")
    }

    /// Apple Speech transcription is intentionally not exercised. Keeping this explicit skip prevents an old helper
    /// from being mistaken for current acceptance coverage.
    func testSpeechFrameworkTranscriptionIsNotAnOpenPawRuntimePath() throws {
        throw XCTSkip("OpenPaw no longer runs Apple Speech. Run LocalDictationAccuracyTests on a phone for Qwen coverage.")
    }

    /// Settings offers Simplified Chinese as a first-class choice, so whether this machine can actually serve it is
    /// worth stating plainly rather than discovering while dictating a prompt.
    func testTheOfferedLocalesReportTheirOnDeviceSupport() throws {
        let offered = SpeechDictation.offeredLocales.prefix(2).map(\.identifier)
        XCTAssertEqual(offered, ["en-US", "zh-CN"], "the first-class locales are not the ones Settings promises")
        for identifier in offered {
            let locale = Locale(identifier: identifier)
            let onDevice = SpeechDictation.supportsOnDeviceRecognition(locale: locale)
            print("DICTATION locale=\(identifier) onDevice=\(onDevice)")
        }
    }

    /// A short utterance rendered to a file the recogniser can read.
    private static func synthesise(_ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let aiff = directory.appendingPathComponent("openpaw-dictation-\(UUID().uuidString).aiff")
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

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
                        forWriting: aiff,
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

        guard FileManager.default.fileExists(atPath: aiff.path) else {
            throw XCTSkip("speech synthesis produced no audio on this machine")
        }
        return aiff
    }
}
