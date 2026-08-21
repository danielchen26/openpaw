import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import Testing
@testable import OpenPawUI

@Suite("Signal presentation")
struct SignalPresentationTests {
    @Test("Flagship aliases keep the approved signal in the dark palette")
    func flagshipPaletteAliasesAreExact() {
        #expect(OpenPawTheme.flagshipHex.void == 0x080B10)
        #expect(OpenPawTheme.flagshipHex.graphite == 0x111722)
        #expect(OpenPawTheme.flagshipHex.ember == 0x1B1817)
        #expect(OpenPawTheme.flagshipHex.signal == 0x7C9CFF)
        #expect(OpenPawTheme.flagshipHex.pulse == 0x60D5B2)
        #expect(OpenPawTheme.flagshipHex.caution == 0xF4BE5B)
    }

    @Test("Every connection signal state has exact semantic presentation")
    func everySignalStateHasExactSemanticPresentation() {
        let expectations: [(state: ConnectionSignalState, label: String, glyph: String, tone: ConnectionSignalTone, rotatesWhenAllowed: Bool)] = [
            (.discovering, "Discovering", "dot.radiowaves.left.and.right", .quiet, true),
            (.connecting, "Connecting", "arrow.triangle.2.circlepath", .signal, true),
            (.online, "Online", "checkmark.circle.fill", .pulse, false),
            (.degraded, "Degraded", "exclamationmark.triangle.fill", .caution, true),
            (.offline, "Offline", "moon.zzz.fill", .quiet, false),
            (.failed, "Failed", "xmark.octagon.fill", .caution, false),
            (.blocked, "Blocked", "lock.trianglebadge.exclamationmark.fill", .blocked, false),
        ]

        #expect(expectations.map(\.state) == ConnectionSignalState.allCases)

        for expectation in expectations {
            let signal = ConnectionSignal(expectation.state)

            #expect(signal.label == expectation.label)
            #expect(signal.glyph == expectation.glyph)
            #expect(signal.tone == expectation.tone)
            #expect(signal.rotatesWhenAllowed == expectation.rotatesWhenAllowed)
        }
    }

    @Test("Signal states have distinct glyphs")
    func signalGlyphsAreDistinct() {
        let glyphs = ConnectionSignalState.allCases.map { ConnectionSignal($0).glyph }
        #expect(Set(glyphs).count == ConnectionSignalState.allCases.count)
    }

    @Test("Offline, failed, and blocked remain distinguishable without color")
    func offlineFailedAndBlockedAreNonColorDistinct() {
        let offline = ConnectionSignal(.offline)
        let failed = ConnectionSignal(.failed)
        let blocked = ConnectionSignal(.blocked)

        #expect(offline.label != blocked.label)
        #expect(offline.label != failed.label)
        #expect(failed.label != blocked.label)
        #expect(offline.glyph != blocked.glyph)
        #expect(offline.glyph != failed.glyph)
        #expect(failed.glyph != blocked.glyph)
        #expect(offline.accessibilityLabel != blocked.accessibilityLabel)
        #expect(offline.accessibilityLabel != failed.accessibilityLabel)
        #expect(failed.accessibilityLabel != blocked.accessibilityLabel)
    }

    @Test("Motion policy disables rotation for reduce motion or inactive app")
    func motionPolicyDisablesRotationWhenReducedOrInactive() {
        #expect(SignalOrb.motionPolicy(reduceMotion: false, appIsActive: true, signal: .connecting).rotates == true)
        #expect(SignalOrb.motionPolicy(reduceMotion: true, appIsActive: true, signal: .connecting).rotates == false)
        #expect(SignalOrb.motionPolicy(reduceMotion: false, appIsActive: false, signal: .connecting).rotates == false)
        #expect(SignalOrb.motionPolicy(reduceMotion: false, appIsActive: true, signal: .offline).rotates == false)
    }

    @Test("Availability maps to connection signal semantics")
    func availabilityMapsToConnectionSignal() {
        #expect(ConnectionSignal(availability: .unknown).state == .discovering)
        #expect(ConnectionSignal(availability: .connecting).state == .connecting)
        #expect(ConnectionSignal(availability: .online).state == .online)
        #expect(ConnectionSignal(availability: .offline).state == .offline)
        #expect(ConnectionSignal(availability: .failed).state == .failed)
    }
}

private func fixture(
    nickname: String = "studio",
    hostname: String = "studio.example.com",
    preferredTransport: TransportKind? = nil,
    lastSuccessfulTransport: TransportKind? = nil,
    multiplexerPreference: MultiplexerKind? = nil,
    tags: [String] = []
) -> HostRecord {
    HostRecord(
        nickname: nickname,
        hostname: hostname,
        username: "chet",
        auth: .agentForwarding,
        preferredTransport: preferredTransport,
        lastSuccessfulTransport: lastSuccessfulTransport,
        multiplexerPreference: multiplexerPreference,
        tags: tags
    )
}
