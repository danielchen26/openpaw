import Foundation
import Sodium

public enum ETProtocolV6 {
    public static let version = 6
    public static let packetEncryptedFlagSize = 1
    public static let packetHeaderSize = 2
    public static let frameLengthSize = 4
    public static let maxBackupBytes = 64 * 1024 * 1024
    public static let disconnectBufferBytes = 64 * 1024 * 1024
    public static let defaultMaxProtoLength = 128 * 1024 * 1024
    public static let maxHandshakeProtoLength = 4 * 1024
}

public enum ETPacketType: UInt8 { case heartbeat = 254, initialPayload = 253, initialResponse = 252 }
public enum ETTerminalPacketType: UInt8 { case keepAlive = 0, terminalBuffer = 1, terminalInfo = 2, terminalUserInfo = 8, terminalInit = 9, jumphostInit = 10 }
public enum ETConnectStatus: Int32 { case newClient = 1, returningClient = 2, invalidKey = 3, mismatchedProtocol = 4 }

public enum ETTransportError: Error, Equatable {
    case malformedPacket, malformedProto(String), frameTooLarge(Int), invalidKeyLength, cryptoFailed
    case replayOutOfOrder(expected: Int64, received: Int64), replayDuplicate(Int64), replayLimitExceeded, clientAhead, tooFarBehind
}

public struct ETPacket: Equatable {
    public var encrypted: Bool
    public var header: UInt8
    public var payload: Data
    public init(encrypted: Bool = false, header: UInt8, payload: Data) { self.encrypted = encrypted; self.header = header; self.payload = payload }
    public init(serialized: Data) throws {
        guard serialized.count >= 2 else { throw ETTransportError.malformedPacket }
        encrypted = serialized[serialized.startIndex] != 0
        header = serialized[serialized.index(after: serialized.startIndex)]
        payload = serialized.dropFirst(2)
    }
    public func serialize() -> Data { Data([encrypted ? 1 : 0, header]) + payload }
    public var length: Int { 2 + payload.count }
}

public enum ETFraming {
    public static func lengthFrame(_ packet: ETPacket) -> Data {
        let body = packet.serialize(); let n = UInt32(body.count).bigEndian
        return withUnsafeBytes(of: n) { Data($0) } + body
    }
    public static func parseLengthFrame(_ data: Data, maxLength: Int = ETProtocolV6.defaultMaxProtoLength) throws -> ETPacket {
        guard data.count >= 4 else { throw ETTransportError.malformedPacket }
        let n = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard n <= maxLength else { throw ETTransportError.frameTooLarge(Int(n)) }
        guard data.count == 4 + Int(n) else { throw ETTransportError.malformedPacket }
        return try ETPacket(serialized: data.dropFirst(4))
    }
    public static func base64Encode(_ data: Data) -> Data { Data(data.base64EncodedString().utf8) }
    public static func base64Decode(_ data: Data, decodedLength: Int? = nil) throws -> Data {
        guard let out = Data(base64Encoded: data) else { throw ETTransportError.malformedPacket }
        if let decodedLength, out.count != decodedLength { throw ETTransportError.malformedPacket }
        return out
    }
}

public struct ETSecretBox {
    public static let keyBytes = 32, nonceBytes = 24, macBytes = 16
    private let sodium = Sodium(); private let key: Bytes; private let nonceMSB: UInt8; private var counter: UInt64 = 0
    public init(key: Data, nonceMSB: UInt8) throws { guard key.count == Self.keyBytes else { throw ETTransportError.invalidKeyLength }; self.key = Array(key); self.nonceMSB = nonceMSB }
    public mutating func cryptNonceForNextMessage() -> Data {
        counter += 1; var n = [UInt8](repeating: 0, count: Self.nonceBytes); var c = counter; var i = 0
        while c > 0 && i < Self.nonceBytes { n[i] = UInt8(c & 0xff); c >>= 8; i += 1 }
        n[Self.nonceBytes - 1] = nonceMSB &+ n[Self.nonceBytes - 1]
        return Data(n)
    }
    public mutating func encrypt(_ plaintext: Data) throws -> Data {
        let nonce = Array(cryptNonceForNextMessage())
        guard let c = sodium.secretBox.seal(message: Array(plaintext), secretKey: key, nonce: nonce) else { throw ETTransportError.cryptoFailed }
        return Data(c)
    }
    public mutating func decrypt(_ ciphertext: Data) throws -> Data {
        guard ciphertext.count >= Self.macBytes else { throw ETTransportError.cryptoFailed }
        let nonce = Array(cryptNonceForNextMessage())
        guard let p = sodium.secretBox.open(authenticatedCipherText: Array(ciphertext), secretKey: key, nonce: nonce) else { throw ETTransportError.cryptoFailed }
        return Data(p)
    }
}

public struct ETProto {
    static func key(_ field: Int, _ wire: UInt64) -> Data { varint(UInt64(field << 3) | wire) }
    static func varint(_ v: UInt64) -> Data { var x = v; var out = Data(); repeat { var b = UInt8(x & 0x7f); x >>= 7; if x != 0 { b |= 0x80 }; out.append(b) } while x != 0; return out }
    static func bytes(_ field: Int, _ d: Data) -> Data { key(field, 2) + varint(UInt64(d.count)) + d }
    static func string(_ field: Int, _ s: String) -> Data { bytes(field, Data(s.utf8)) }
    static func int32(_ field: Int, _ v: Int32) -> Data { key(field, 0) + varint(UInt64(UInt32(bitPattern: v))) }
    static func int64(_ field: Int, _ v: Int64) -> Data { key(field, 0) + varint(UInt64(bitPattern: v)) }
    public static func connectRequest(clientId: String, version: Int32 = Int32(ETProtocolV6.version)) -> Data { string(1, clientId) + int32(2, version) }
    public static func connectResponse(status: ETConnectStatus, error: String? = nil) -> Data { int32(1, status.rawValue) + (error.map { string(2, $0) } ?? Data()) }
    public static func sequenceHeader(_ n: Int32) -> Data { int32(1, n) }
    public static func catchupBuffer(_ buffers: [Data]) -> Data { buffers.reduce(Data()) { $0 + bytes(1, $1) } }
    public static func terminalBuffer(_ buffer: Data) -> Data { bytes(1, buffer) }
    public static func terminalInfo(id: String, row: Int32, column: Int32, width: Int32, height: Int32) -> Data { string(1,id)+int32(2,row)+int32(3,column)+int32(4,width)+int32(5,height) }
    public static func terminalUserInfo(id: String, passkey: String, uid: Int64, gid: Int64, fd: Int64) -> Data { string(1,id)+string(2,passkey)+int64(3,uid)+int64(4,gid)+int64(5,fd) }
    public static func terminalInit(environment: [(String, String)]) -> Data { environment.reduce(Data()) { $0 + string(1, $1.0) + string(2, $1.1) } }
    public static func initialPayload(jumphost: Bool = false, environment: [(String, String)] = []) -> Data {
        var out = jumphost ? (key(1,0)+varint(1)) : Data()
        for (k,v) in environment { out += bytes(3, string(1,k)+string(2,v)) }
        return out
    }
}

public struct ETReplayBuffer {
    public private(set) var sequenceNumber: Int64 = 0; public let maxBytes: Int; private var entries: [(Int64, Data)] = []; private var bytes = 0; private var accepted = Set<Int64>()
    public init(maxBytes: Int = ETProtocolV6.maxBackupBytes) { self.maxBytes = maxBytes }
    public mutating func appendExactCiphertext(_ data: Data) throws { guard data.count <= maxBytes, bytes + data.count <= maxBytes else { throw ETTransportError.replayLimitExceeded }; sequenceNumber += 1; entries.insert((sequenceNumber, data), at: 0); bytes += data.count }
    public mutating func accept(sequence: Int64, ciphertext: Data) throws { let expected = sequenceNumber + 1; if accepted.contains(sequence) { throw ETTransportError.replayDuplicate(sequence) }; guard sequence == expected else { throw ETTransportError.replayOutOfOrder(expected: expected, received: sequence) }; try appendExactCiphertext(ciphertext); accepted.insert(sequence) }
    public func recover(after lastValidSequenceNumber: Int64) throws -> [Data] { let n = sequenceNumber - lastValidSequenceNumber; if n < 0 { throw ETTransportError.clientAhead }; guard n <= entries.count else { throw ETTransportError.tooFarBehind }; return entries.prefix(Int(n)).reversed().map(\.1) }
}

public struct ETSSHBootstrapRequest: Equatable {
    public let executable = "ssh"; public let arguments: [String]; public let stdinPayload: Data
    public init(host: String, port: Int? = nil, stdinPayload: Data) { var a = ["-T"]; if let port { a += ["-p", String(port)] }; a.append(host); self.arguments = a; self.stdinPayload = stdinPayload }
}
