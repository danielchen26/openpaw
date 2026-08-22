import Foundation

/// Which recogniser turns a held thumb into words.
///
/// Apple's recogniser is not the only option because it is not good enough at the sentence this product is built
/// around. Measured by `tools/dictation-cer`, Apple's on-device recogniser gets 44% of the characters wrong in a
/// Chinese sentence with an English command name in it — "运行 npm install 安装依赖", which it hears as
/// "运行BPM in so安装" — and averages 22% across the benchmark corpus. Qwen3-ASR 0.6B gets that sentence exactly
/// right and averages 2%. That gap is the whole reason this enum exists: the choice is not a preference between
/// equivalent engines, it is a choice between one that can hear the user and one that cannot.
///
/// The cost of the better answer is a model download and a slower turnaround, so the choice stays the user's.
public enum DictationEngineChoice: String, Codable, Sendable, CaseIterable, Hashable {
    /// `SFSpeechRecognizer`. No download, streaming partial results, weak on mixed Chinese and English.
    case appleSpeech = "apple"
    /// Qwen3-ASR 0.6B, 4-bit MLX. Downloaded once, runs on the phone's GPU, strong on mixed Chinese and English.
    case qwen3Small = "qwen3-0.6b"
    /// Qwen3-ASR 1.7B, 8-bit MLX. The most accurate of the three and the largest; a phone with 8 GB can hold it,
    /// an older one cannot.
    case qwen3Large = "qwen3-1.7b"
    /// Parakeet TDT v3, CoreML on the Neural Engine. Fastest and smallest, English and European languages only.
    case parakeet = "parakeet-v3"

    public var displayName: String {
        switch self {
        case .appleSpeech: "Apple"
        case .qwen3Small: "Qwen3 0.6B"
        case .qwen3Large: "Qwen3 1.7B"
        case .parakeet: "Parakeet"
        }
    }

    /// True when the engine needs weights fetched before it can hear anything. Apple's is part of the OS.
    public var requiresDownload: Bool { self != .appleSpeech }

    /// The HuggingFace repository the weights come from, or nil for the system recogniser.
    ///
    /// Stated here rather than inside the app target so the settings screen can name the exact repository a
    /// download will contact before the user taps it.
    public var modelID: String? {
        switch self {
        case .appleSpeech: nil
        case .qwen3Small: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        case .qwen3Large: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        // The 5-second-window iOS export: one fixed CoreML shape, small enough to load on a phone. Longer audio is
        // window-chunked by the engine rather than truncated.
        case .parakeet: "aufklarer/Parakeet-TDT-v3-CoreML-INT8-iOS-5s"
        }
    }

    /// Roughly what the download costs, for a screen that has to tell the user before spending their data.
    public var approximateDownloadMegabytes: Int {
        switch self {
        case .appleSpeech: 0
        case .qwen3Small: 450
        case .qwen3Large: 1_900
        case .parakeet: 700
        }
    }

    /// Whether this engine can transcribe Chinese at all.
    ///
    /// Parakeet cannot: it covers 25 European languages, and given Chinese audio it emits a phonetic transliteration
    /// rather than failing, which is worse than an error because it looks like a transcript. The picker says so
    /// instead of letting a zh-CN user discover it by dictating.
    public var supportsChinese: Bool { self != .parakeet }

    /// Emits words while the user is still speaking. Only Apple's does; the local models transcribe the utterance
    /// once the finger comes up, so the ring shows no live text and the words arrive together.
    public var streamsPartialResults: Bool { self == .appleSpeech }

    /// One line under the picker: what picking this costs and what it buys.
    public var summary: String {
        switch self {
        case .appleSpeech:
            "Built into iOS. Words appear as you speak. Weakest on Chinese sentences containing English commands."
        case .qwen3Small:
            "450 MB download, runs on this device. Handles Chinese mixed with English commands well; the transcript "
                + "arrives when you let go rather than as you speak."
        case .qwen3Large:
            "1.9 GB download, runs on this device. The most accurate option, and needs a recent phone with memory "
                + "to spare."
        case .parakeet:
            "700 MB download, runs on the Neural Engine. Fast and accurate in English and European languages, and "
                + "cannot transcribe Chinese at all."
        }
    }

    /// Engines worth offering for a given dictation language.
    ///
    /// Filtered rather than merely annotated: an engine that transliterates Chinese into English syllables is not a
    /// degraded choice for a Chinese speaker, it is a wrong one, and a picker that offers it is inviting a bug
    /// report that reads "dictation writes gibberish".
    public static func choices(forLocale identifier: String) -> [DictationEngineChoice] {
        let isChinese = identifier.lowercased().hasPrefix("zh")
        return allCases.filter { !isChinese || $0.supportsChinese }
    }

    /// The engine to fall back to when the stored choice cannot serve the selected language.
    public static func resolve(_ choice: DictationEngineChoice, forLocale identifier: String)
        -> DictationEngineChoice
    {
        choices(forLocale: identifier).contains(choice) ? choice : .appleSpeech
    }
}

/// Where a downloadable engine's weights are in their journey onto the device.
///
/// Modelled as a state rather than a bool because the failure that matters — a download that stalled half way and
/// left an unusable directory — is invisible to "is it installed", and the user needs to be told to retry rather
/// than left holding a button that never hears anything.
public enum DictationModelState: Sendable, Equatable {
    /// Nothing fetched. The engine cannot run.
    case absent
    /// Fetching, with a fraction and what the fraction is doing.
    case downloading(progress: Double, detail: String)
    /// On disk and loadable.
    case installed
    /// The last attempt failed. Carries the reason so the screen can say it.
    case failed(String)
    /// This device cannot run the engine at all, whatever the user does. Carries the reason.
    ///
    /// Distinct from `failed` because the two want opposite buttons. A failure is worth retrying and the row offers
    /// Download again; this is not, and a Download button here would take 450 MB of somebody's bandwidth to arrive
    /// at the same wall. The concrete case is a simulator, where MLX cannot allocate a Metal heap.
    case unsupported(String)

    public var isInstalled: Bool { self == .installed }

    public var isBusy: Bool {
        if case .downloading = self { return true }
        return false
    }

    /// What a settings row says about this state, or nil when there is nothing worth saying.
    public var statusText: String? {
        switch self {
        case .absent: "Not downloaded"
        case .downloading(let progress, let detail): "\(detail) \(Int(progress * 100))%"
        case .installed: "Ready on this device"
        case .failed(let reason): "Download failed: \(reason)"
        case .unsupported(let reason): reason
        }
    }

    /// Whether the user can do anything about this state, which decides if a row offers a button at all.
    public var isActionable: Bool {
        if case .unsupported = self { return false }
        return true
    }
}
