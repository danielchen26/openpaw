import XCTest
@testable import OpenPawETTransport

private extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }

final class ETCorrectionTests: XCTestCase {
    func testProtoFramesUseEightByteHostEndianLengthAndDecodeStreaming() throws {
        let body = ETProto.connectRequest(clientId: "cid", version: 6)
        let frame = try ETProtoFraming.frame(body)
        XCTAssertEqual(frame.prefix(8).hex, "0700000000000000")
        var decoder = ETProtoFrameDecoder(maxLength: ETProtocolV6.maxHandshakeProtoLength)
        XCTAssertEqual(try decoder.feed(frame.prefix(3)), [])
        let messages = try decoder.feed(frame.dropFirst(3))
        XCTAssertEqual(messages, [body])
        XCTAssertEqual(try ETProto.decodeConnectRequest(messages[0]), ETConnectRequest(clientId: "cid", version: 6))
    }

    func testActualProtoDecodersAndCanonicalNegativeInt32() throws {
        XCTAssertEqual(ETProto.int32FieldForTesting(1, -1).hex, "08ffffffffffffffffff01")
        XCTAssertEqual(try ETProto.decodeConnectResponse(ETProto.connectResponse(status: .invalidKey, error: "no")), ETConnectResponse(status: .invalidKey, error: "no"))
        XCTAssertEqual(try ETProto.decodeSequenceHeader(ETProto.sequenceHeader(-1)), ETSequenceHeader(sequenceNumber: -1))
        let catchup = try ETProto.decodeCatchupBuffer(ETProto.catchupBuffer([Data([1]), Data([2,3])]))
        XCTAssertEqual(catchup.buffers, [Data([1]), Data([2,3])])
        XCTAssertEqual(try ETProto.decodeTerminalBuffer(ETProto.terminalBuffer(Data("x".utf8))).buffer, Data("x".utf8))
        XCTAssertEqual(try ETProto.decodeTerminalInfo(ETProto.terminalInfo(id: "t", row: 1, column: 2, width: 3, height: 4)), ETTerminalInfo(id: "t", row: 1, column: 2, width: 3, height: 4))
    }

    func testPacketConstantsAndFramingAreSeparate() throws {
        XCTAssertEqual(ETTerminalPacketType.portForwardDestinationRequest.rawValue, 5)
        XCTAssertEqual(ETTerminalPacketType.portForwardDestinationResponse.rawValue, 6)
        XCTAssertEqual(ETTerminalPacketType.portForwardData.rawValue, 7)
        let packet = ETPacket(encrypted: true, header: 9, payload: Data([1,2]))
        XCTAssertEqual(ETPacketFraming.frame(packet).hex, "0000000401090102")
        XCTAssertEqual(try ETPacketFraming.parse(ETPacketFraming.frame(packet)), packet)
    }

    func testNonceFullCarryDirectionAndOverflow() throws {
        let key = Data(repeating: 1, count: ETSecretBox.keyBytes)
        let box = try ETSecretBox(key: key, direction: .clientToServer, initialNonce: Data([0xff] + Array(repeating: 0, count: 23)))
        XCTAssertEqual(try box.nextNonceForTesting().hex, "000100000000000000000000000000000000000000000000")
        let server = try ETSecretBox(key: key, direction: .serverToClient)
        XCTAssertEqual(try server.nextNonceForTesting().last, ETNonceDirection.serverToClient.msb)
        XCTAssertThrowsError(try ETSecretBox(key: key, direction: .clientToServer, initialNonce: Data(repeating: 0xff, count: 24)))
    }

    func testReplayConnectedEvictionDisconnectedCapAndRevive() throws {
        var replay = ETReplayBuffer(maxBackupBytes: 6, disconnectBufferBytes: 5)
        try replay.recordSent(ETPacket(encrypted: true, header: 1, payload: Data([1,2])).serialize(), connected: true)
        try replay.recordSent(ETPacket(encrypted: true, header: 1, payload: Data([3,4])).serialize(), connected: true)
        XCTAssertThrowsError(try replay.recover(after: 0))
        XCTAssertEqual(try replay.recover(after: 1).map(\.hex), ["01010304"])
        try replay.markDisconnected()
        try replay.recordSent(Data([9,9,9]), connected: false)
        XCTAssertEqual(replay.disconnectedBytes, 3)
        XCTAssertThrowsError(try replay.recordSent(Data([8,8,8]), connected: false))
        try replay.revive()
        XCTAssertEqual(replay.disconnectedBytes, 0)
    }

    func testBootstrapUsesFixedRemoteEtterminalCommandAndNoCallerShellText() throws {
        let req = try ETSSHBootstrapRequest(host: "h", port: 22, terminalId: "tid", passkey: "pk")
        XCTAssertEqual(req.executable, "ssh")
        XCTAssertEqual(req.arguments, ["-T", "-p", "22", "h", "etterminal", "--protocol", "6"])
        XCTAssertEqual(String(data: req.stdinPayload, encoding: .utf8), "tid/pk_xterm-256color\n")
        XCTAssertFalse(req.arguments.joined(separator: " ").contains("pk"))
    }

    func testLifecycleStateMachine() throws {
        var lifecycle = ETConnectionLifecycle()
        try lifecycle.apply(.connectResponse(.newClient))
        XCTAssertEqual(lifecycle.state, .handshaking(.newClient))
        try lifecycle.apply(.handshakeComplete)
        XCTAssertEqual(lifecycle.state, .live)
        try lifecycle.apply(.disconnect(bufferedBytes: 4))
        XCTAssertEqual(lifecycle.state, .disconnected(bufferedBytes: 4))
        try lifecycle.apply(.revive)
        XCTAssertEqual(lifecycle.state, .live)
        try lifecycle.apply(.fail(.cryptoFailed))
        XCTAssertEqual(lifecycle.state, .failed(.cryptoFailed))
    }
}
