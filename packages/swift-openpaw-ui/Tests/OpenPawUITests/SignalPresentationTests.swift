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

    @Test("Every connection signal state has nonempty label glyph and tone", arguments: ConnectionSignalState.allCases)
    func everySignalStateHasSemanticCopy(state: ConnectionSignalState) {
        let signal = ConnectionSignal(state)

        #expect(signal.label.isEmpty == false)
        #expect(signal.glyph.isEmpty == false)
        #expect(ConnectionSignalTone.allCases.contains(signal.tone))
    }

    @Test("Signal states have distinct glyphs")
    func signalGlyphsAreDistinct() {
        let glyphs = ConnectionSignalState.allCases.map { ConnectionSignal($0).glyph }
        #expect(Set(glyphs).count == ConnectionSignalState.allCases.count)
    }

    @Test("Offline and blocked remain distinguishable without color")
    func offlineAndBlockedAreNonColorDistinct() {
        let offline = ConnectionSignal(.offline)
        let blocked = ConnectionSignal(.blocked)

        #expect(offline.label != blocked.label)
        #expect(offline.glyph != blocked.glyph)
        #expect(offline.accessibilityLabel != blocked.accessibilityLabel)
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
        #expect(ConnectionSignal(availability: .failed).state == .blocked)
    }

    @Test("Workspace card consumes deterministic presentation metric order")
    func workspaceCardUsesStableMetricOrder() {
        let host = fixture(preferredTransport: .mosh, multiplexerPreference: .zellij)
        let presentation = WorkspaceDevicePresentation(
            host: host,
            selectedHostID: host.id,
            activeSessionCount: 3,
            pendingApprovalCount: 2
        )
        let card = WorkspaceCard(presentation: presentation) {}

        #expect(card.orderedMetrics.map(\.id) == ["active-sessions", "pending-approvals", "transport", "multiplexer"])
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
