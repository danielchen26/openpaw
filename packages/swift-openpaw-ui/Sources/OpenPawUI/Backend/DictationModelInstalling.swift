import Foundation
import Observation

/// Fetches and holds the weights a downloadable dictation engine needs.
///
/// Declared here and implemented in the app target because the weights come from MLX and CoreML packages that this
/// UI package must not depend on: a snapshot run and `swift test` build this module on a Mac with no GPU budget and
/// no model cache, and pulling a 2 GB inference stack into them to render a settings row would be absurd.
public protocol DictationModelInstalling: Sendable {
    /// Where the weights for this engine currently are. Cheap enough to call while drawing a row.
    @MainActor func state(of choice: DictationEngineChoice) -> DictationModelState
    /// Starts or resumes a download. Progress arrives through `state(of:)` as the store observes itself.
    @MainActor func install(_ choice: DictationEngineChoice)
    /// Abandons an in-flight download, leaving whatever is already on disk.
    @MainActor func cancelInstall(of choice: DictationEngineChoice)
    /// Deletes downloaded weights, so a user who tried the 1.9 GB model can get the space back.
    @MainActor func remove(_ choice: DictationEngineChoice)
}

/// Builds the engine behind a given choice.
///
/// A closure held by the model rather than a `switch` inside the UI package, because two of the three engines are
/// MLX and CoreML models that only the app target can construct.
@MainActor
public protocol DictationEngineMaking: Sendable {
    /// The engine for this choice, or nil when it cannot run on this device right now — weights missing, or a
    /// simulator with no Neural Engine. Nil is what makes the hold say "unavailable" instead of drawing a ring
    /// over a recogniser that will never answer.
    func engine(for choice: DictationEngineChoice) -> (any DictationEngine)?
}

/// A store that reports every engine as absent and refuses to download anything.
///
/// Used by previews, tests and the headless snapshot runner, all of which draw the settings screen and none of
/// which should be able to start a multi-gigabyte transfer as a side effect of rendering.
@MainActor
@Observable
public final class UnavailableDictationModelStore: DictationModelInstalling {
    public init() {}
    public func state(of choice: DictationEngineChoice) -> DictationModelState {
        choice.requiresDownload ? .absent : .installed
    }
    public func install(_ choice: DictationEngineChoice) {}
    public func cancelInstall(of choice: DictationEngineChoice) {}
    public func remove(_ choice: DictationEngineChoice) {}
}

/// A store frozen in one state, so a screen can be drawn mid-download without a download.
///
/// The states worth looking at — a stalled 1.9 GB fetch, a failure the user has to be told to retry — are the ones
/// that never occur while a snapshot runner is rendering, which is precisely why they are the ones that rot. This
/// makes them addressable by name.
@MainActor
@Observable
public final class StubDictationModelStore: DictationModelInstalling {
    public var states: [DictationEngineChoice: DictationModelState]
    private let fallback: DictationModelState

    public init(
        states: [DictationEngineChoice: DictationModelState] = [:],
        fallback: DictationModelState = .absent
    ) {
        self.states = states
        self.fallback = fallback
    }

    public func state(of choice: DictationEngineChoice) -> DictationModelState {
        if let state = states[choice] { return state }
        return choice.requiresDownload ? fallback : .installed
    }

    public func install(_ choice: DictationEngineChoice) {
        states[choice] = .downloading(progress: 0, detail: "Fetching")
    }
    public func cancelInstall(of choice: DictationEngineChoice) { states[choice] = .absent }
    public func remove(_ choice: DictationEngineChoice) { states[choice] = .absent }
}
