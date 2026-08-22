import AVFoundation
import Foundation
import ParakeetASR
import Qwen3ASR
import Speech

// Answers, with numbers, the question the recogniser picker is built around: can this engine hear a Chinese
// sentence with an English command name in it?
//
// This exists because the claim in `DictationEngineChoice` — that Apple's recogniser gets 39% of the characters
// wrong on "运行 npm install 安装依赖" while a local model gets ~3% wrong — is the entire justification for
// shipping a 450 MB download, and a justification nobody can re-run is a rumour. Every engine is measured on
// byte-identical audio through the same call the app itself makes.

// MARK: - Corpus

/// One line the user might actually say, and the exact characters they said.
struct Phrase {
    let id: String
    let reference: String
    /// The dictation language the user would have selected, which is also the hint handed to the model. Guessing
    /// it instead would measure language identification rather than transcription.
    var locale: String { id.hasPrefix("zh") ? "zh-CN" : "en-US" }
}

// MARK: - Scoring

/// Character error rate: edit distance over characters, divided by the length of what was said.
///
/// Case and punctuation are stripped first. "npm Install." instead of "npm install" is not a mistake a user
/// would ever notice, and counting it would flatter no engine consistently — Apple emits no Chinese full stops,
/// the local models do.
func characterErrorRate(reference: String, hypothesis: String) -> Double {
    func normalise(_ text: String) -> [Character] {
        Array(text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
    }
    let expected = normalise(reference)
    let heard = normalise(hypothesis)
    guard !expected.isEmpty else { return heard.isEmpty ? 0 : 1 }
    var previous = Array(0...heard.count)
    var current = [Int](repeating: 0, count: heard.count + 1)
    for i in 1...expected.count {
        current[0] = i
        for j in 1...heard.count {
            current[j] = min(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + (expected[i - 1] == heard[j - 1] ? 0 : 1))
        }
        swap(&previous, &current)
    }
    return Double(previous[heard.count]) / Double(expected.count)
}

/// Strips the tags a model may emit around its own output, exactly as `LoadedASRModel` does in the app.
///
/// Duplicated rather than imported because the app target cannot be linked from a macOS command line tool. If
/// these two ever diverge, the benchmark stops describing what ships.
func clean(_ text: String) -> String {
    text
        .replacingOccurrences(of: "<[^>]{0,40}>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "<\\|[^|]{0,40}\\|>", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Audio

/// Reads a clip as the 16 kHz mono float the models want, which is the format `LocalASRSession` produces from the
/// microphone. Measuring anything else would measure a resampler the app does not use.
func readSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
        let converter = AVAudioConverter(from: file.processingFormat, to: target)
    else { throw BenchError.audio("cannot convert \(url.lastPathComponent) to 16 kHz mono") }

    let ratio = 16_000 / file.processingFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(file.length) * ratio) + 4_096
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
        throw BenchError.audio("cannot allocate output buffer")
    }

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
    if let conversionError { throw conversionError }
    guard let channel = output.floatChannelData?[0] else {
        throw BenchError.audio("converted buffer has no samples")
    }
    return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
}

enum BenchError: LocalizedError {
    case audio(String)
    case usage(String)
    var errorDescription: String? {
        switch self {
        case .audio(let detail): detail
        case .usage(let detail): detail
        }
    }
}

// MARK: - Engines

protocol Recogniser {
    var name: String { get }
    func transcribe(samples: [Float], url: URL, locale: String) async throws -> String
}

struct QwenRecogniser: Recogniser {
    let name: String
    let model: Qwen3ASRModel
    func transcribe(samples: [Float], url: URL, locale: String) async throws -> String {
        let language = Locale(identifier: locale).language.languageCode?.identifier
        return clean(
            model.transcribe(
                audio: samples, sampleRate: 16_000,
                options: Qwen3DecodingOptions(language: language)))
    }
}

struct ParakeetRecogniser: Recogniser {
    let name = "parakeet"
    let model: ParakeetASRModel
    func transcribe(samples: [Float], url: URL, locale: String) async throws -> String {
        let language = Locale(identifier: locale).language.languageCode?.identifier
        return clean(try model.transcribeAudio(samples, sampleRate: 16_000, language: language))
    }
}

/// `SFSpeechRecognizer`, pinned on device.
///
/// `requiresOnDeviceRecognition` is set because the alternative measures Apple's servers, and the settings screen
/// promises the user that on-device recognition is what happens. An engine that returns nothing is scored as
/// having heard nothing, which is the correct treatment: silence is a total loss to a user holding the button.
struct AppleRecogniser: Recogniser {
    let name = "apple"
    func transcribe(samples: [Float], url: URL, locale: String) async -> String {
        guard let recogniser = SFSpeechRecognizer(locale: Locale(identifier: locale)),
            recogniser.isAvailable
        else { return "" }
        recogniser.supportsOnDeviceRecognition = true
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { continuation in
            var resumed = false
            recogniser.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    resumed = true
                    continuation.resume(returning: "")
                }
            }
        }
    }
}

// MARK: - Run

let arguments = CommandLine.arguments
let corpusDirectory = URL(
    fileURLWithPath: arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath)
let engineNames =
    arguments.count > 2
    ? Array(arguments.dropFirst(2))
    : ["apple", "qwen3-0.6b"]

let manifest = try String(
    contentsOf: corpusDirectory.appendingPathComponent("phrases.tsv"), encoding: .utf8)
let phrases = manifest.split(separator: "\n").compactMap { line -> Phrase? in
    let columns = line.split(separator: "\t", maxSplits: 1)
    guard columns.count == 2 else { return nil }
    return Phrase(id: String(columns[0]), reference: String(columns[1]))
}
guard !phrases.isEmpty else {
    throw BenchError.usage("no phrases in \(corpusDirectory.path)/phrases.tsv")
}

var note = ""
var lastDecade = -1
let progress: (Double, String) -> Void = { fraction, detail in
    let percent = Int(fraction * 100)
    guard percent / 10 != lastDecade else { return }
    lastDecade = percent / 10
    FileHandle.standardError.write("  \(percent)% \(detail)\n".data(using: .utf8)!)
}

for engineName in engineNames {
    let recogniser: any Recogniser
    switch engineName {
    case "apple":
        let status = await withCheckedContinuation {
            (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            print("apple: speech recognition not authorised, skipping")
            continue
        }
        recogniser = AppleRecogniser()
    case "qwen3-0.6b", "qwen3-1.7b":
        let modelID =
            engineName == "qwen3-0.6b"
            ? "aufklarer/Qwen3-ASR-0.6B-MLX-4bit" : "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        FileHandle.standardError.write("loading \(modelID)…\n".data(using: .utf8)!)
        lastDecade = -1
        recogniser = QwenRecogniser(
            name: engineName,
            model: try await Qwen3ASRModel.fromPretrained(modelId: modelID, progressHandler: progress))
    case "parakeet":
        let modelID = "aufklarer/Parakeet-TDT-v3-CoreML-INT8-iOS-5s"
        FileHandle.standardError.write("loading \(modelID)…\n".data(using: .utf8)!)
        lastDecade = -1
        recogniser = ParakeetRecogniser(
            model: try await ParakeetASRModel.fromPretrained(
                modelId: modelID, progressHandler: progress))
    default:
        throw BenchError.usage("unknown engine \(engineName)")
    }

    var totalRate = 0.0
    print("\n=== \(recogniser.name) ===")
    for phrase in phrases {
        let url = corpusDirectory.appendingPathComponent("\(phrase.id).wav")
        let samples = try readSamples(url)
        let started = Date()
        let heard = try await recogniser.transcribe(
            samples: samples, url: url, locale: phrase.locale)
        let rate = characterErrorRate(reference: phrase.reference, hypothesis: heard)
        totalRate += rate
        print(
            String(
                format: "%@ %6.1f%%  %5.2fs  %@", phrase.id.padding(toLength: 4, withPad: " ", startingAt: 0),
                rate * 100, Date().timeIntervalSince(started), heard.isEmpty ? "(nothing)" : heard))
    }
    note += String(
        format: "%@: mean CER %.1f%% over %d clips\n", recogniser.name,
        totalRate / Double(phrases.count) * 100, phrases.count)
}

print("\n" + note, terminator: "")
