import Foundation

/// The input-state machine that decides what a terminal actually sends while an input method is composing.
///
/// ## The bug this exists to prevent
///
/// A `UITextInput` conformance receives three different kinds of call while a CJK input method is running:
///
/// 1. `setMarkedText(_:selectedRange:)` — provisional text. For Pinyin this is the *romanisation* ("nih"), for
///    Japanese the kana being converted, for Korean the syllable under assembly. It is not what the user typed
///    and it is not what they mean.
/// 2. `insertText(_:)` — the committed result ("你好"). When this arrives while text is marked, it *replaces* the
///    marked text; UIKit does not send a separate deletion for the marked run.
/// 3. `unmarkText()` — the composition ends without a new commit, accepting whatever is currently marked.
///
/// The common bug is to forward every one of these to the PTY, because that is what the non-IME path does. The
/// result is that typing 你好 sends `n`, `i`, `h`, `a`, `o` to the shell — five stray keystrokes that a REPL or a
/// TUI interprets as commands — and then sends 你好 as well. The remote side sees garbage and, worse, an agent
/// prompt gets prefixed with the raw Pinyin.
///
/// So: **marked text is never written to the PTY.** It is composition state, owned locally, rendered inline by the
/// view, and it becomes bytes only at the moment the input method commits. Only rule 2 and rule 3 emit.
///
/// A second, subtler part of the same bug is backspace. While composing, `deleteBackward()` means "shorten the
/// composition", not "send 0x7F". Forwarding it erases a character the remote side never received, so the local
/// display and the remote line editor drift apart permanently. While `isComposing` is true, deletion is local.
struct MarkedTextComposer: Equatable, Sendable {

    /// What the caller must write to the transport as a result of the call. Returning it instead of calling out
    /// keeps this type pure and lets the tests assert the exact byte stream.
    enum Emission: Equatable, Sendable {
        case nothing
        case send(String)
    }

    /// The provisional text currently being composed. Empty means no composition is in flight.
    private(set) var markedText: String = ""

    var isComposing: Bool { !markedText.isEmpty }

    init() {}

    /// Provisional text from the input method. Never emits — this is the whole point of the type.
    mutating func setMarkedText(_ text: String) -> Emission {
        markedText = text
        return .nothing
    }

    /// The input method committed. `text` is the final string and, when a composition was in flight, it stands in
    /// for the marked run rather than following it, so the marked text is dropped rather than sent.
    mutating func insertText(_ text: String) -> Emission {
        markedText = ""
        return text.isEmpty ? .nothing : .send(text)
    }

    /// The composition ended with no new commit. Some input methods use this to accept the marked text verbatim
    /// (typing Pinyin and pressing space with no candidate selected), so whatever is marked becomes real here.
    mutating func unmarkText() -> Emission {
        guard !markedText.isEmpty else { return .nothing }
        let committed = markedText
        markedText = ""
        return .send(committed)
    }

    /// Backspace. Local while composing; a real DEL byte otherwise.
    mutating func deleteBackward() -> Emission {
        guard isComposing else { return .send("\u{7F}") }
        markedText.removeLast()
        return .nothing
    }

    /// Plain typed text with no input method involved. Identical to a commit, and kept as a separate name so call
    /// sites read honestly.
    mutating func typed(_ text: String) -> Emission {
        insertText(text)
    }

    /// The composition is abandoned without committing — the view lost first responder, the connection dropped, or
    /// the user switched sessions. Nothing is sent, because nothing was ever agreed.
    mutating func abandon() {
        markedText = ""
    }
}
