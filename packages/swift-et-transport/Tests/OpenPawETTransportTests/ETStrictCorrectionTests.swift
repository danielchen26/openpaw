import XCTest
@testable import OpenPawETTransport

private extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }

final class ETStrictCorrectionTests: XCTestCase {
    func testSSHBootstrapArgvLaunchesEtterminalWithoutRemoteShellOrOptionInjection() throws {
        let bootstrap = try ETSSHBootstrapRequest(host: "example.com", port: 2022, terminalId: "tid", passkey: "pk")
        XCTAssertEqual(bootstrap.executable, "ssh")
        XCTAssertEqual(bootstrap.arguments, ["-T", "-p", "2022", "example.com", "etterminal", "--protocol", "6"])
        XCTAssertEqual(String(data: bootstrap.stdinPayload, encoding: .utf8), "tid/pk_TERM\n")
        XCTAssertFalse(bootstrap.arguments.contains("--"), "OpenSSH treats arguments after host as the remote command. Do not inject a post-host -- argument into the remote command.")
        XCTAssertThrowsError(try ETSSHBootstrapRequest(host: "-oProxyCommand=sh", port: 22, terminalId: "tid", passkey: "pk"))
        XCTAssertThrowsError(try ETSSHBootstrapRequest(host: "good host", port: 22, terminalId: "tid", passkey: "pk"))
        XCTAssertThrowsError(try ETSSHBootstrapRequest(host: "example.com", port: 0, terminalId: "tid", passkey: "pk"))
        XCTAssertThrowsError(try ETSSHBootstrapRequest(host: "example.com", port: 65536, terminalId: "tid", passkey: "pk"))
        XCTAssertThrowsError(try ETSSHBootstrapRequest(host: "example.com", port: 22, terminalId: "ti/d", passkey: "pk"))
        XCTAssertThrowsError(try ETSSHBootstrapRequest(host: "example.com", port: 22, terminalId: "tid", passkey: "p\nk"))
    }

    func testRawBootstrapInitializerSharesHostAndPortValidation() throws {
        let raw = try ETSSHBootstrapRequest(host: "safe.example", port: 22, stdinPayload: Data("tid/pk_TERM\n".utf8))
        XCTAssertEqual(raw.arguments, ["-T", "-p", "22", "safe.example", "etterminal", "--protocol", "6"])
        XCTAssertThrowsError(try ETSSHBootstrapRequest(host: "-oProxyCommand=sh", port: 22, stdinPayload: Data()))
        XCTAssertThrowsError(try ETSSHBootstrapRequest(host: "", port: 22, stdinPayload: Data()))
        XCTAssertThrowsError(try ETSSHBootstrapRequest(host: "bad host", port: 22, stdinPayload: Data()))
        XCTAssertThrowsError(try ETSSHBootstrapRequest(host: "example.com", port: 0, stdinPayload: Data()))
        XCTAssertThrowsError(try ETSSHBootstrapRequest(host: "example.com", port: 65536, stdinPayload: Data()))
    }

    func testProtoFrameDecoderRejectsExtremaBeforeIntConversionAndEncoderCaps() throws {
        XCTAssertThrowsError(try ETProtoFraming.frame(Data(repeating: 0, count: ETProtocolV6.defaultMaxProtoLength + 1)))
        let maxSignedNative = Data([0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x7f])
        let minSignedNative = Data([0,0,0,0,0,0,0,0x80])
        let allOnes = Data(repeating: 0xff, count: 8)
        for prefix in [maxSignedNative, minSignedNative, allOnes] {
            var decoder = ETProtoFrameDecoder(maxLength: ETProtocolV6.defaultMaxProtoLength)
            XCTAssertThrowsError(try decoder.feed(prefix))
        }
    }

    func testDisconnectedLimitCannotBeResetAndRejectedPreflightDoesNotAdvanceNonce() throws {
        var replay = ETReplayBuffer(maxBackupBytes: 100, disconnectBufferBytes: 5)
        try replay.markDisconnected()
        XCTAssertTrue(replay.canBufferDisconnectedPacket(byteCount: 3))
        try replay.recordSent(Data([1,2,3]), connected: false)
        try replay.markDisconnected()
        XCTAssertFalse(replay.canBufferDisconnectedPacket(byteCount: 3))
        XCTAssertThrowsError(try replay.recordSent(Data([4,5,6]), connected: false))
        XCTAssertEqual(replay.sequenceNumber, 1)
        XCTAssertEqual(replay.disconnectedBytes, 3)

        let key = Data(repeating: 7, count: ETSecretBox.keyBytes)
        let nonce = Data([0xfe] + Array(repeating: 0, count: 23))
        let box = try ETSecretBox(key: key, direction: .clientToServer, initialNonce: nonce)
        XCTAssertFalse(box.canEncrypt(plaintextByteCount: ETProtocolV6.defaultMaxProtoLength + 1))
        var afterRejected = box
        XCTAssertThrowsError(try afterRejected.encrypt(Data(repeating: 0, count: ETProtocolV6.defaultMaxProtoLength + 1)))
        XCTAssertEqual(try afterRejected.nextNonceForTesting().hex, "ff0000000000000000000000000000000000000000000000")
    }

    func testTerminalInitRepeatedFieldOrderAndMissingDecoders() throws {
        let user1 = ETTerminalUserInfo(id: "A", passkey: "P", uid: 1, gid: 2, fd: 3)
        let user2 = ETTerminalUserInfo(id: "B", passkey: "Q", uid: 4, gid: 5, fd: 6)
        let initMessage = ETTerminalInit(users: [user1, user2])
        let encoded = ETProto.terminalInit(initMessage)
        XCTAssertEqual(encoded.hex, "0a0c0a01411201501801200228030a0c0a0142120151180420052806")
        XCTAssertEqual(try ETProto.decodeTerminalUserInfo(ETProto.terminalUserInfo(user1)), user1)
        XCTAssertEqual(try ETProto.decodeTerminalInit(encoded), initMessage)

        let payload = ETInitialPayload(jumphost: true, terminalInit: initMessage)
        XCTAssertEqual(try ETProto.decodeInitialPayload(ETProto.initialPayload(payload)), payload)
        let response = ETInitialResponse(connectResponse: ETConnectResponse(status: .returningClient), sequenceHeader: ETSequenceHeader(sequenceNumber: 42))
        XCTAssertEqual(try ETProto.decodeInitialResponse(ETProto.initialResponse(response)), response)
    }
}
