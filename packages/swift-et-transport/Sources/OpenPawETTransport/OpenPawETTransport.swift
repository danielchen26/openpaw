import Foundation
import Sodium

public enum ETProtocolV6 {
    public static let version = 6
    public static let packetEncryptedFlagSize = 1
    public static let packetHeaderSize = 2
    public static let frameLengthSize = 4
    public static let protoFrameLengthSize = 8
    public static let maxBackupBytes = 64 * 1024 * 1024
    public static let disconnectBufferBytes = 64 * 1024 * 1024
    public static let defaultMaxProtoLength = 128 * 1024 * 1024
    public static let maxHandshakeProtoLength = 4 * 1024
}

public enum ETPacketType: UInt8 { case heartbeat = 254, initialPayload = 253, initialResponse = 252 }
public enum ETTerminalPacketType: UInt8 {
    case keepAlive = 0, terminalBuffer = 1, terminalInfo = 2
    case portForwardDestinationRequest = 5, portForwardDestinationResponse = 6, portForwardData = 7
    case terminalUserInfo = 8, terminalInit = 9, jumphostInit = 10
}
public enum ETConnectStatus: Int32 { case newClient = 1, returningClient = 2, invalidKey = 3, mismatchedProtocol = 4 }
public enum ETNonceDirection: Equatable { case clientToServer, serverToClient; public var msb: UInt8 { self == .clientToServer ? 0 : 1 } }

public enum ETTransportError: Error, Equatable {
    case malformedPacket, malformedProto(String), frameTooLarge(Int), invalidKeyLength, cryptoFailed, nonceOverflow
    case replayOutOfOrder(expected: Int64, received: Int64), replayDuplicate(Int64), replayLimitExceeded, clientAhead, tooFarBehind
    case invalidLifecycleTransition(String)
}

public struct ETPacket: Equatable {
    public var encrypted: Bool; public var header: UInt8; public var payload: Data
    public init(encrypted: Bool = false, header: UInt8, payload: Data) { self.encrypted = encrypted; self.header = header; self.payload = payload }
    public init(serialized: Data) throws { guard serialized.count >= 2 else { throw ETTransportError.malformedPacket }; encrypted = serialized[serialized.startIndex] != 0; header = serialized[serialized.index(after: serialized.startIndex)]; payload = serialized.dropFirst(2) }
    public func serialize() -> Data { Data([encrypted ? 1 : 0, header]) + payload }
    public var length: Int { 2 + payload.count }
}

public enum ETPacketFraming {
    public static func frame(_ packet: ETPacket) -> Data { let body = packet.serialize(); let n = UInt32(body.count).bigEndian; return withUnsafeBytes(of: n) { Data($0) } + body }
    public static func parse(_ data: Data, maxLength: Int = ETProtocolV6.defaultMaxProtoLength) throws -> ETPacket { guard data.count >= 4 else { throw ETTransportError.malformedPacket }; let n = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }; guard n <= maxLength else { throw ETTransportError.frameTooLarge(Int(n)) }; guard data.count == 4 + Int(n) else { throw ETTransportError.malformedPacket }; return try ETPacket(serialized: data.dropFirst(4)) }
}

public enum ETFraming { // compatibility alias plus b64 helpers
    public static func lengthFrame(_ packet: ETPacket) -> Data { ETPacketFraming.frame(packet) }
    public static func parseLengthFrame(_ data: Data, maxLength: Int = ETProtocolV6.defaultMaxProtoLength) throws -> ETPacket { try ETPacketFraming.parse(data, maxLength: maxLength) }
    public static func base64Encode(_ data: Data) -> Data { Data(data.base64EncodedString().utf8) }
    public static func base64Decode(_ data: Data, decodedLength: Int? = nil) throws -> Data { guard let out = Data(base64Encoded: data) else { throw ETTransportError.malformedPacket }; if let decodedLength, out.count != decodedLength { throw ETTransportError.malformedPacket }; return out }
}

public enum ETProtoFraming {
    public static func frame(_ proto: Data) -> Data { var len = UInt64(proto.count).littleEndian; return withUnsafeBytes(of: &len) { Data($0) } + proto }
}

public struct ETProtoFrameDecoder {
    private var buffer = Data(); public let maxLength: Int
    public init(maxLength: Int = ETProtocolV6.defaultMaxProtoLength) { self.maxLength = maxLength }
    public mutating func feed<C: Collection>(_ data: C) throws -> [Data] where C.Element == UInt8 {
        buffer.append(contentsOf: data); var out: [Data] = []
        while buffer.count >= 8 {
            let len = Int(buffer.prefix(8).enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << UInt64(8 * $1.offset)) })
            guard len <= maxLength else { throw ETTransportError.frameTooLarge(len) }
            guard buffer.count >= 8 + len else { break }
            out.append(buffer.dropFirst(8).prefix(len)); buffer.removeFirst(8 + len)
        }
        return out
    }
}

public struct ETSecretBox {
    public static let keyBytes = 32, nonceBytes = 24, macBytes = 16
    private let sodium = Sodium(); private let key: Bytes; private var nonce: [UInt8]
    public init(key: Data, nonceMSB: UInt8) throws { try self.init(key: key, direction: nonceMSB == 0 ? .clientToServer : .serverToClient) }
    public init(key: Data, direction: ETNonceDirection, initialNonce: Data? = nil) throws { guard key.count == Self.keyBytes else { throw ETTransportError.invalidKeyLength }; self.key = Array(key); self.nonce = initialNonce.map(Array.init) ?? [UInt8](repeating: 0, count: Self.nonceBytes); guard nonce.count == Self.nonceBytes else { throw ETTransportError.malformedPacket }; if initialNonce == nil { nonce[Self.nonceBytes - 1] = direction.msb } }
    public mutating func nextNonceForTesting() throws -> Data { try incrementNonce(); return Data(nonce) }
    public mutating func cryptNonceForNextMessage() -> Data { (try? nextNonceForTesting()) ?? Data() }
    private mutating func incrementNonce() throws { for i in 0..<Self.nonceBytes { nonce[i] &+= 1; if nonce[i] != 0 { return } }; throw ETTransportError.nonceOverflow }
    public mutating func encrypt(_ plaintext: Data) throws -> Data { try incrementNonce(); guard let c = sodium.secretBox.seal(message: Array(plaintext), secretKey: key, nonce: nonce) else { throw ETTransportError.cryptoFailed }; return Data(c) }
    public mutating func decrypt(_ ciphertext: Data) throws -> Data { guard ciphertext.count >= Self.macBytes else { throw ETTransportError.cryptoFailed }; try incrementNonce(); guard let p = sodium.secretBox.open(authenticatedCipherText: Array(ciphertext), secretKey: key, nonce: nonce) else { throw ETTransportError.cryptoFailed }; return Data(p) }
}

public struct ETConnectRequest: Equatable { public let clientId: String; public let version: Int32; public init(clientId: String, version: Int32) { self.clientId = clientId; self.version = version } }
public struct ETConnectResponse: Equatable { public let status: ETConnectStatus; public let error: String?; public init(status: ETConnectStatus, error: String? = nil) { self.status = status; self.error = error } }
public struct ETSequenceHeader: Equatable { public let sequenceNumber: Int32; public init(sequenceNumber: Int32) { self.sequenceNumber = sequenceNumber } }
public struct ETCatchupBuffer: Equatable { public let buffers: [Data]; public init(buffers: [Data]) { self.buffers = buffers } }
public struct ETTerminalBuffer: Equatable { public let buffer: Data }
public struct ETTerminalInfo: Equatable { public let id: String; public let row, column, width, height: Int32; public init(id: String, row: Int32, column: Int32, width: Int32, height: Int32) { self.id = id; self.row = row; self.column = column; self.width = width; self.height = height } }

public struct ETProto {
    static func key(_ field: Int, _ wire: UInt64) -> Data { varint(UInt64(field << 3) | wire) }
    static func varint(_ v: UInt64) -> Data { var x = v; var out = Data(); repeat { var b = UInt8(x & 0x7f); x >>= 7; if x != 0 { b |= 0x80 }; out.append(b) } while x != 0; return out }
    static func readVarint(_ data: Data, _ i: inout Int) throws -> UInt64 { var shift: UInt64 = 0, result: UInt64 = 0; while i < data.count && shift < 70 { let b = data[data.index(data.startIndex, offsetBy: i)]; i += 1; result |= UInt64(b & 0x7f) << shift; if b & 0x80 == 0 { return result }; shift += 7 }; throw ETTransportError.malformedProto("bad varint") }
    static func bytes(_ field: Int, _ d: Data) -> Data { key(field, 2) + varint(UInt64(d.count)) + d }
    static func string(_ field: Int, _ s: String) -> Data { bytes(field, Data(s.utf8)) }
    static func int32(_ field: Int, _ v: Int32) -> Data { key(field, 0) + varint(UInt64(bitPattern: Int64(v))) }
    static func int64(_ field: Int, _ v: Int64) -> Data { key(field, 0) + varint(UInt64(bitPattern: v)) }
    public static func int32FieldForTesting(_ field: Int, _ v: Int32) -> Data { int32(field, v) }
    public static func connectRequest(clientId: String, version: Int32 = Int32(ETProtocolV6.version)) -> Data { string(1, clientId) + int32(2, version) }
    public static func connectResponse(status: ETConnectStatus, error: String? = nil) -> Data { int32(1, status.rawValue) + (error.map { string(2, $0) } ?? Data()) }
    public static func sequenceHeader(_ n: Int32) -> Data { int32(1, n) }
    public static func catchupBuffer(_ buffers: [Data]) -> Data { buffers.reduce(Data()) { $0 + bytes(1, $1) } }
    public static func terminalBuffer(_ buffer: Data) -> Data { bytes(1, buffer) }
    public static func terminalInfo(id: String, row: Int32, column: Int32, width: Int32, height: Int32) -> Data { string(1,id)+int32(2,row)+int32(3,column)+int32(4,width)+int32(5,height) }
    public static func terminalUserInfo(id: String, passkey: String, uid: Int64, gid: Int64, fd: Int64) -> Data { string(1,id)+string(2,passkey)+int64(3,uid)+int64(4,gid)+int64(5,fd) }
    public static func terminalInit(environment: [(String, String)]) -> Data { environment.reduce(Data()) { $0 + string(1, $1.0) + string(2, $1.1) } }
    public static func initialPayload(jumphost: Bool = false, environment: [(String, String)] = []) -> Data { var out = jumphost ? (key(1,0)+varint(1)) : Data(); for (k,v) in environment { out += bytes(3, string(1,k)+string(2,v)) }; return out }
    static func fields(_ data: Data) throws -> [(Int, UInt64, Data?, UInt64?)] { var i = 0, r: [(Int, UInt64, Data?, UInt64?)] = []; while i < data.count { let k = try readVarint(data, &i); let f = Int(k >> 3), w = k & 7; if w == 0 { r.append((f,w,nil,try readVarint(data,&i))) } else if w == 2 { let l = Int(try readVarint(data,&i)); guard i + l <= data.count else { throw ETTransportError.malformedProto("truncated") }; r.append((f,w,data.dropFirst(i).prefix(l),nil)); i += l } else { throw ETTransportError.malformedProto("wire") } }; return r }
    static func i32(_ v: UInt64?) -> Int32 { Int32(truncatingIfNeeded: v ?? 0) }
    public static func decodeConnectRequest(_ d: Data) throws -> ETConnectRequest { var id = ""; var ver: Int32 = 0; for f in try fields(d) { if f.0 == 1, let b = f.2 { id = String(data:b, encoding:.utf8) ?? "" }; if f.0 == 2 { ver = i32(f.3) } }; return ETConnectRequest(clientId: id, version: ver) }
    public static func decodeConnectResponse(_ d: Data) throws -> ETConnectResponse { var st: ETConnectStatus = .newClient; var err: String?; for f in try fields(d) { if f.0 == 1 { st = ETConnectStatus(rawValue: i32(f.3)) ?? .mismatchedProtocol }; if f.0 == 2, let b = f.2 { err = String(data:b, encoding:.utf8) } }; return ETConnectResponse(status: st, error: err) }
    public static func decodeSequenceHeader(_ d: Data) throws -> ETSequenceHeader { ETSequenceHeader(sequenceNumber: i32(try fields(d).first { $0.0 == 1 }?.3)) }
    public static func decodeCatchupBuffer(_ d: Data) throws -> ETCatchupBuffer { ETCatchupBuffer(buffers: try fields(d).compactMap { $0.0 == 1 ? $0.2 : nil }) }
    public static func decodeTerminalBuffer(_ d: Data) throws -> ETTerminalBuffer { ETTerminalBuffer(buffer: try fields(d).first { $0.0 == 1 }?.2 ?? Data()) }
    public static func decodeTerminalInfo(_ d: Data) throws -> ETTerminalInfo { var id=""; var vals=[Int:Int32](); for f in try fields(d) { if f.0 == 1, let b = f.2 { id = String(data:b, encoding:.utf8) ?? "" }; if (2...5).contains(f.0) { vals[f.0] = i32(f.3) } }; return ETTerminalInfo(id: id, row: vals[2] ?? 0, column: vals[3] ?? 0, width: vals[4] ?? 0, height: vals[5] ?? 0) }
}

public struct ETReplayBuffer {
    public private(set) var sequenceNumber: Int64 = 0; public let maxBackupBytes: Int; public let disconnectBufferBytes: Int; private var entries: [(Int64, Data)] = []; private var bytes = 0; public private(set) var disconnectedBytes = 0; private var disconnected = false
    public init(maxBytes: Int = ETProtocolV6.maxBackupBytes) { self.init(maxBackupBytes: maxBytes, disconnectBufferBytes: maxBytes) }
    public init(maxBackupBytes: Int = ETProtocolV6.maxBackupBytes, disconnectBufferBytes: Int = ETProtocolV6.disconnectBufferBytes) { self.maxBackupBytes = maxBackupBytes; self.disconnectBufferBytes = disconnectBufferBytes }
    public mutating func markDisconnected() throws { disconnected = true; disconnectedBytes = 0 }
    public mutating func revive() { disconnected = false; disconnectedBytes = 0 }
    public mutating func recordSent(_ encryptedPacketSerialization: Data, connected: Bool) throws { if !connected || disconnected { guard disconnectedBytes + encryptedPacketSerialization.count <= disconnectBufferBytes else { throw ETTransportError.replayLimitExceeded }; disconnectedBytes += encryptedPacketSerialization.count }; sequenceNumber += 1; entries.insert((sequenceNumber, encryptedPacketSerialization), at: 0); bytes += encryptedPacketSerialization.count; while connected && !disconnected && bytes > maxBackupBytes, let last = entries.last { bytes -= last.1.count; entries.removeLast() } }
    public mutating func appendExactCiphertext(_ data: Data) throws { try recordSent(data, connected: true) }
    public mutating func accept(sequence: Int64, ciphertext: Data) throws { let expected = sequenceNumber + 1; guard sequence == expected else { if sequence <= sequenceNumber { throw ETTransportError.replayDuplicate(sequence) }; throw ETTransportError.replayOutOfOrder(expected: expected, received: sequence) }; try recordSent(ciphertext, connected: true) }
    public func recover(after lastValidSequenceNumber: Int64) throws -> [Data] { let n = sequenceNumber - lastValidSequenceNumber; if n < 0 { throw ETTransportError.clientAhead }; guard n <= entries.count else { throw ETTransportError.tooFarBehind }; return entries.prefix(Int(n)).reversed().map(\.1) }
}

public struct ETSSHBootstrapRequest: Equatable {
    public let executable = "ssh"; public let arguments: [String]; public let stdinPayload: Data
    public init(host: String, port: Int? = nil, stdinPayload: Data) { var a = ["-T"]; if let port { a += ["-p", String(port)] }; a += [host, "--", "etterminal", "--protocol", String(ETProtocolV6.version)]; self.arguments = a; self.stdinPayload = stdinPayload }
}

public enum ETConnectionState: Equatable { case idle, handshaking(ETConnectStatus), live, disconnected(bufferedBytes: Int), failed(ETTransportError) }
public enum ETConnectionEvent { case connectResponse(ETConnectStatus), handshakeComplete, disconnect(bufferedBytes: Int), revive, fail(ETTransportError) }
public struct ETConnectionLifecycle { public private(set) var state: ETConnectionState = .idle; public init() {} ; public mutating func apply(_ e: ETConnectionEvent) throws { switch (state,e) { case (.idle,.connectResponse(let s)) where s == .newClient || s == .returningClient: state = .handshaking(s); case (_,.connectResponse(let s)): state = .failed(s == .invalidKey ? .cryptoFailed : .malformedProto("protocol")); case (.handshaking,.handshakeComplete): state = .live; case (.live,.disconnect(let b)): state = .disconnected(bufferedBytes: b); case (.disconnected,.revive): state = .live; case (_,.fail(let err)): state = .failed(err); default: throw ETTransportError.invalidLifecycleTransition("\(state)") } } }
