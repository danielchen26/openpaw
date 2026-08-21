import XCTest
@testable import OpenPawETTransport

private extension Data {
    init(hex: String) {
        self.init()
        var s = hex
        while s.count >= 2 {
            append(UInt8(s.prefix(2), radix: 16)!)
            s.removeFirst(2)
        }
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

final class OpenPawETTransportTests: XCTestCase {
    func testProtocolV6ConstantsMatchUpstream() {
        XCTAssertEqual(ETProtocolV6.version, 6)
        XCTAssertEqual(ETPacketType.heartbeat.rawValue, 254)
        XCTAssertEqual(ETPacketType.initialPayload.rawValue, 253)
        XCTAssertEqual(ETPacketType.initialResponse.rawValue, 252)
        XCTAssertEqual(ETTerminalPacketType.terminalBuffer.rawValue, 1)
        XCTAssertEqual(ETTerminalPacketType.terminalInfo.rawValue, 2)
        XCTAssertEqual(ETTerminalPacketType.terminalInit.rawValue, 9)
        XCTAssertEqual(ETProtocolV6.maxBackupBytes, 64 * 1024 * 1024)
        XCTAssertEqual(ETProtocolV6.maxHandshakeProtoLength, 4 * 1024)
    }
    func testUpstreamDerivedProtoGoldenVectors() {
        XCTAssertEqual(ETProto.connectRequest(clientId: "cid").hex, "0a036369641006")
        XCTAssertEqual(ETProto.connectResponse(status: .mismatchedProtocol, error: "bad").hex, "08041203626164")
        XCTAssertEqual(ETProto.sequenceHeader(300).hex, "08ac02")
        XCTAssertEqual(ETProto.catchupBuffer([Data([0, 0xfd, 0x68]), Data([1, 2])]).hex, "0a0300fd680a020102")
        XCTAssertEqual(ETProto.terminalBuffer(Data("hi".utf8)).hex, "0a026869")
        XCTAssertEqual(ETProto.terminalInfo(id: "t", row: 24, column: 80, width: 640, height: 480).hex, "0a01741018185020800528e003")
        XCTAssertEqual(ETProto.terminalUserInfo(id: "t", passkey: "p", uid: 501, gid: 20, fd: 7).hex, "0a017412017018f50320142807")
        XCTAssertEqual(ETProto.terminalInit(environment: [("TERM", "xterm")]).hex, "0a130a045445524d1205787465726d180020002800")
        XCTAssertEqual(ETProto.initialPayload(jumphost: true, environment: [("A", "B")]).hex, "08011a0e0a0c0a0141120142180020002800")
    }
    func testPacketAndFramingGoldenVectors() throws {
        let packet = ETPacket(header: ETTerminalPacketType.terminalBuffer.rawValue, payload: Data("hi".utf8))
        XCTAssertEqual(packet.serialize().hex, "00016869")
        let frame = ETFraming.lengthFrame(packet)
        XCTAssertEqual(frame.hex, "0000000400016869")
        XCTAssertEqual(try ETFraming.parseLengthFrame(frame), packet)
        XCTAssertEqual(String(data: ETFraming.base64Encode(Data([0, 1, 0xff])), encoding: .utf8), "AAH/")
        XCTAssertEqual(try ETFraming.base64Decode(Data("AAH/".utf8), decodedLength: 3), Data([0, 1, 0xff]))
    }
    func testLengthLimitsRejectOversizedFrames() {
        let oversized = Data([0,0,0,5,0,1])
        XCTAssertThrowsError(try ETFraming.parseLengthFrame(oversized, maxLength: 4))
    }
    func testSecretBoxNonceDirectionsAndRoundTrip() throws {
        let key = Data(repeating: 7, count: ETSecretBox.keyBytes)
        var c = try ETSecretBox(key: key, nonceMSB: 0)
        var s = try ETSecretBox(key: key, nonceMSB: 0)
        XCTAssertEqual(c.cryptNonceForNextMessage().hex, "010000000000000000000000000000000000000000000000")
        var enc = try ETSecretBox(key: key, nonceMSB: 0)
        let ct = try enc.encrypt(Data("hello".utf8))
        XCTAssertEqual(ct.count, 21)
        XCTAssertEqual(try s.decrypt(ct), Data("hello".utf8))
        var reverse = try ETSecretBox(key: key, nonceMSB: 1)
        XCTAssertEqual(reverse.cryptNonceForNextMessage().hex, "010000000000000000000000000000000000000000000001")
    }
    func testReplayBufferExactCiphertextRecoveryAndRejection() throws {
        var b = ETReplayBuffer(maxBytes: 10)
        try b.accept(sequence: 1, ciphertext: Data([1,2]))
        XCTAssertThrowsError(try b.accept(sequence: 1, ciphertext: Data([1,2])))
        XCTAssertThrowsError(try b.accept(sequence: 3, ciphertext: Data([3])))
        try b.accept(sequence: 2, ciphertext: Data([3,4]))
        XCTAssertEqual(try b.recover(after: 0), [Data([1,2]), Data([3,4])])
        XCTAssertEqual(try b.recover(after: 1), [Data([3,4])])
        try b.markDisconnected()
        XCTAssertThrowsError(try b.recordSent(Data(repeating: 9, count: 20), connected: false))
        XCTAssertThrowsError(try b.recover(after: 3))
    }
    func testBootstrapCarriesDynamicValuesInStdinNotShellInterpolation() {
        let payload = Data("user=$(rm -rf /)\nkey=abc".utf8)
        let req = ETSSHBootstrapRequest(host: "example.com", port: 2222, stdinPayload: payload)
        XCTAssertEqual(req.executable, "ssh")
        XCTAssertEqual(req.arguments, ["-T", "-p", "2222", "example.com", "etterminal", "--protocol", "6"])
        XCTAssertEqual(req.stdinPayload, payload)
        XCTAssertFalse(req.arguments.joined(separator: " ").contains("rm -rf"))
    }
}
