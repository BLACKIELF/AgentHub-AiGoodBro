import Darwin
import Foundation
import Security

enum AFUnixWebSocketError: Error, CustomStringConvertible {
    case invalidSocketPath
    case socketFailed(Int32)
    case connectFailed(Int32)
    case handshakeFailed(String)
    case unexpectedHandshakeResponse(statusCode: Int?, headers: String)
    case readFailed(Int32)
    case writeFailed(Int32)
    case protocolViolation(String)
    case messageTooLarge
    case disconnected

    var description: String {
        switch self {
        case .invalidSocketPath:
            return "invalid Unix socket path"
        case .socketFailed(let code):
            return "socket() failed errno=\(code) (\(Self.errnoText(code)))"
        case .connectFailed(let code):
            return "connect() failed errno=\(code) (\(Self.errnoText(code)))"
        case .handshakeFailed(let reason):
            return "WebSocket handshake failed: \(reason)"
        case .unexpectedHandshakeResponse(let statusCode, let headers):
            let status = statusCode.map(String.init) ?? "unknown"
            return "WebSocket handshake response was not 101 status=\(status) headers=\(headers)"
        case .readFailed(let code):
            return "socket read failed errno=\(code) (\(Self.errnoText(code)))"
        case .writeFailed(let code):
            return "socket write failed errno=\(code) (\(Self.errnoText(code)))"
        case .protocolViolation(let reason):
            return "WebSocket protocol violation: \(reason)"
        case .messageTooLarge:
            return "WebSocket message exceeds configured limit"
        case .disconnected:
            return "peer closed the socket"
        }
    }

    private static func errnoText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

final class AFUnixWebSocket {
    typealias MessageHandler = (Data) -> Void
    typealias DisconnectHandler = () -> Void

    // An operation retains the socket until its final syscall has returned.
    // shutdown interrupts blocked IO; only the last owner closes the descriptor,
    // so another file can never reuse its integer while an operation still holds it.
    private final class Connection {
        let descriptor: Int32

        init(descriptor: Int32) { self.descriptor = descriptor }

        deinit { Darwin.close(descriptor) }

        func shutdown() { Darwin.shutdown(descriptor, SHUT_RDWR) }

        func withDescriptor<T>(_ operation: (Int32) throws -> T) rethrows -> T {
            try withExtendedLifetime(self) { try operation(descriptor) }
        }
    }

    private let socketPath: String
    private let maximumMessageBytes: Int
    private let callbackQueue: DispatchQueue
    private let readerQueue: DispatchQueue
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var connection: Connection?
    private var didStart = false
    private var didClose = false
    private var isReady = false
    private var didReportDisconnect = false

    init(socketPath: String, maximumMessageBytes: Int, callbackQueue: DispatchQueue) {
        self.socketPath = socketPath
        self.maximumMessageBytes = maximumMessageBytes
        self.callbackQueue = callbackQueue
        readerQueue = DispatchQueue(
            label: "com.blackielf.codex-account-manager-next.task-websocket.reader",
            qos: .utility
        )
    }

    func start(
        onReady: @escaping () -> Void,
        onMessage: @escaping MessageHandler,
        onDisconnect: @escaping DisconnectHandler
    ) {
        stateLock.lock()
        guard !didStart else {
            stateLock.unlock()
            return
        }
        didStart = true
        stateLock.unlock()
        readerQueue.async { [weak self] in
            guard let self else { return }
            do {
                let connection = try self.openSocket()
                try connection.withDescriptor { descriptor in
                    var buffer = try self.performHandshake(descriptor: descriptor)
                    guard self.markReady(connection) else { throw AFUnixWebSocketError.disconnected }
                    debugLog("AFUnixWebSocket: handshake completed status=101 residualBytes=\(buffer.count)")
                    self.callbackQueue.async { [weak self] in
                        guard self?.isCurrentReadyConnection(connection) == true else { return }
                        onReady()
                    }
                    try self.readFrames(
                        descriptor: descriptor,
                        buffer: &buffer,
                        onMessage: onMessage
                    )
                }
            } catch {
                debugLog("AFUnixWebSocket: connection ended")
            }
            self.close()
            debugLog("AFUnixWebSocket: scheduling onDisconnect callback")
            self.reportDisconnect(onDisconnect)
        }
    }

    func sendText(_ data: Data) -> Bool {
        sendFrame(opcode: 0x1, payload: data)
    }

    func close() {
        stateLock.lock()
        didClose = true
        isReady = false
        let connection = self.connection
        self.connection = nil
        stateLock.unlock()
        connection?.shutdown()
    }

    private func openSocket() throws -> Connection {
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw AFUnixWebSocketError.invalidSocketPath
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AFUnixWebSocketError.socketFailed(errno) }
        let connection = Connection(descriptor: descriptor)
        guard installConnection(connection) else { throw AFUnixWebSocketError.disconnected }
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 2
        let addressLength = pathOffset + pathBytes.count
        address.sun_len = UInt8(addressLength)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
                socketPath.withCString { source in
                    _ = Darwin.strlcpy(destination, source, pathBytes.count)
                }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(addressLength))
            }
        }
        guard result == 0 else {
            let code = errno
            throw AFUnixWebSocketError.connectFailed(code)
        }
        guard isCurrentConnection(connection) else { throw AFUnixWebSocketError.disconnected }
        debugLog("AFUnixWebSocket: Unix socket connected")
        return connection
    }

    private func performHandshake(descriptor: Int32) throws -> Data {
        var nonce = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess else {
            throw AFUnixWebSocketError.handshakeFailed("failed to generate Sec-WebSocket-Key")
        }
        let key = Data(nonce).base64EncodedString()
        let request =
            "GET / HTTP/1.1\r\n"
            + "Host: localhost\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\n"
            + "Sec-WebSocket-Version: 13\r\n\r\n"
        try writeAll(Data(request.utf8), descriptor: descriptor)

        var buffer = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        while buffer.range(of: delimiter) == nil {
            guard buffer.count < 32 * 1_024 else {
                throw AFUnixWebSocketError.handshakeFailed("response headers exceed 32768 bytes")
            }
            buffer.append(try readChunk(descriptor: descriptor))
        }
        guard let headerRange = buffer.range(of: delimiter) else {
            throw AFUnixWebSocketError.handshakeFailed("response header delimiter is missing")
        }
        let headerData = buffer[..<headerRange.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else {
            throw AFUnixWebSocketError.handshakeFailed("response headers are not UTF-8")
        }
        let lines = header.components(separatedBy: "\r\n")
        let statusCode = lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<separator]).lowercased()] = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
        }
        let diagnosticHeaders = Self.handshakeHeaderSummary(statusLine: lines.first, headers: headers)
        guard statusCode == 101 else {
            throw AFUnixWebSocketError.unexpectedHandshakeResponse(
                statusCode: statusCode,
                headers: diagnosticHeaders
            )
        }
        let expectedAccept = SHA1.hash(Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
            .base64EncodedString()
        guard headers["upgrade"]?.lowercased() == "websocket",
            headers["connection"]?.lowercased().split(separator: ",").map({
                $0.trimmingCharacters(in: .whitespaces)
            }).contains("upgrade") == true,
            headers["sec-websocket-accept"] == expectedAccept
        else {
            throw AFUnixWebSocketError.handshakeFailed(
                "invalid upgrade headers response=\(diagnosticHeaders)"
            )
        }
        return Data(buffer[headerRange.upperBound...])
    }

    private func readFrames(
        descriptor: Int32,
        buffer: inout Data,
        onMessage: @escaping MessageHandler
    ) throws {
        var fragmentedOpcode: UInt8?
        var fragmentedPayload = Data()
        while true {
            try fill(&buffer, count: 2, descriptor: descriptor)
            // buffer 经 removeFirst 后下标不从 0 开始，必须一律基于 startIndex 定位
            var base = buffer.startIndex
            let first = buffer[base]
            let second = buffer[base + 1]
            guard first & 0x70 == 0, second & 0x80 == 0 else {
                throw AFUnixWebSocketError.protocolViolation("RSV bit set or server frame is masked")
            }
            let isFinal = first & 0x80 != 0
            let opcode = first & 0x0f
            var headerBytes = 2
            var payloadLength = UInt64(second & 0x7f)
            if payloadLength == 126 {
                try fill(&buffer, count: 4, descriptor: descriptor)
                base = buffer.startIndex
                payloadLength = UInt64(buffer[base + 2]) << 8 | UInt64(buffer[base + 3])
                headerBytes = 4
            } else if payloadLength == 127 {
                try fill(&buffer, count: 10, descriptor: descriptor)
                base = buffer.startIndex
                guard buffer[base + 2] & 0x80 == 0 else {
                    throw AFUnixWebSocketError.protocolViolation("64-bit payload length has its high bit set")
                }
                payloadLength = (2..<10).reduce(UInt64(0)) { ($0 << 8) | UInt64(buffer[base + $1]) }
                headerBytes = 10
            }
            guard payloadLength <= UInt64(maximumMessageBytes),
                payloadLength <= UInt64(Int.max),
                headerBytes <= Int.max - Int(payloadLength)
            else {
                throw AFUnixWebSocketError.messageTooLarge
            }
            let frameBytes = headerBytes + Int(payloadLength)
            try fill(&buffer, count: frameBytes, descriptor: descriptor)
            base = buffer.startIndex
            let payload = Data(buffer[(base + headerBytes)..<(base + frameBytes)])
            buffer.removeFirst(frameBytes)

            if opcode & 0x08 != 0 {
                guard isFinal, payload.count <= 125 else {
                    throw AFUnixWebSocketError.protocolViolation("invalid control frame")
                }
                if opcode == 0x8 { return }
                if opcode == 0x9, !sendFrame(opcode: 0xA, payload: payload) { return }
                guard opcode == 0x9 || opcode == 0xA else {
                    throw AFUnixWebSocketError.protocolViolation("unknown control opcode \(opcode)")
                }
                continue
            }
            if opcode == 0x0 {
                guard fragmentedOpcode != nil else {
                    throw AFUnixWebSocketError.protocolViolation("continuation without an initial fragment")
                }
                guard fragmentedPayload.count <= maximumMessageBytes - payload.count else {
                    throw AFUnixWebSocketError.messageTooLarge
                }
                fragmentedPayload.append(payload)
                if isFinal {
                    let message = fragmentedPayload
                    let originalOpcode = fragmentedOpcode
                    fragmentedOpcode = nil
                    fragmentedPayload.removeAll(keepingCapacity: false)
                    if originalOpcode == 0x1 { callbackQueue.async { onMessage(message) } }
                }
            } else {
                guard opcode == 0x1 || opcode == 0x2, fragmentedOpcode == nil else {
                    throw AFUnixWebSocketError.protocolViolation("unexpected data opcode \(opcode)")
                }
                if isFinal {
                    if opcode == 0x1 { callbackQueue.async { onMessage(payload) } }
                } else {
                    fragmentedOpcode = opcode
                    fragmentedPayload = payload
                }
            }
        }
    }

    private func fill(_ buffer: inout Data, count: Int, descriptor: Int32) throws {
        while buffer.count < count { buffer.append(try readChunk(descriptor: descriptor)) }
    }

    private static func handshakeHeaderSummary(
        statusLine: String?,
        headers: [String: String]
    ) -> String {
        let upgrade = headers["upgrade"] ?? "missing"
        let connection = headers["connection"] ?? "missing"
        let accept = headers["sec-websocket-accept"] == nil ? "missing" : "present"
        let status = statusLine ?? "missing"
        return "statusLine=\(status) upgrade=\(upgrade) connection=\(connection) sec-websocket-accept=\(accept)"
    }

    private func readChunk(descriptor: Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { throw AFUnixWebSocketError.disconnected }
            if errno != EINTR { throw AFUnixWebSocketError.readFailed(errno) }
        }
    }

    private func sendFrame(opcode: UInt8, payload: Data) -> Bool {
        guard payload.count <= maximumMessageBytes else { return false }
        var mask = [UInt8](repeating: 0, count: 4)
        guard SecRandomCopyBytes(kSecRandomDefault, mask.count, &mask) == errSecSuccess else {
            return false
        }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(0x80 | payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(0x80 | 126)
            frame.append(UInt8((payload.count >> 8) & 0xff))
            frame.append(UInt8(payload.count & 0xff))
        } else {
            frame.append(0x80 | 127)
            let count = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((count >> UInt64(shift)) & 0xff))
            }
        }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let connection = isReady ? self.connection : nil
        stateLock.unlock()
        guard let connection else { return false }
        do {
            try connection.withDescriptor { try writeAll(frame, descriptor: $0) }
            return true
        } catch {
            debugLog("AFUnixWebSocket: send failed")
            return false
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count > 0 {
                    remaining -= count
                    pointer = pointer.advanced(by: count)
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw AFUnixWebSocketError.writeFailed(errno)
                }
            }
        }
    }

    private func installConnection(_ connection: Connection) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !didClose, self.connection == nil else { return false }
        self.connection = connection
        return true
    }

    private func isCurrentConnection(_ connection: Connection) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !didClose && self.connection === connection
    }

    private func markReady(_ connection: Connection) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !didClose, self.connection === connection else { return false }
        isReady = true
        return true
    }

    private func isCurrentReadyConnection(_ connection: Connection) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !didClose && isReady && self.connection === connection
    }

    private func reportDisconnect(_ handler: @escaping DisconnectHandler) {
        stateLock.lock()
        let shouldReport = !didReportDisconnect
        didReportDisconnect = true
        stateLock.unlock()
        if shouldReport { callbackQueue.async(execute: handler) }
    }
}

private enum SHA1 {
    static func hash(_ data: Data) -> Data {
        var message = Array(data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        var state: [UInt32] = [0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476, 0xc3d2_e1f0]
        for offset in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 80)
            for index in 0..<16 {
                let base = offset + index * 4
                words[index] =
                    UInt32(message[base]) << 24 | UInt32(message[base + 1]) << 16
                    | UInt32(message[base + 2]) << 8 | UInt32(message[base + 3])
            }
            for index in 16..<80 {
                words[index] = rotateLeft(
                    words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16],
                    by: 1
                )
            }
            var a = state[0]
            var b = state[1]
            var c = state[2]
            var d = state[3]
            var e = state[4]
            for index in 0..<80 {
                let (function, constant): (UInt32, UInt32)
                switch index {
                case 0..<20: (function, constant) = ((b & c) | ((~b) & d), 0x5a82_7999)
                case 20..<40: (function, constant) = (b ^ c ^ d, 0x6ed9_eba1)
                case 40..<60: (function, constant) = ((b & c) | (b & d) | (c & d), 0x8f1b_bcdc)
                default: (function, constant) = (b ^ c ^ d, 0xca62_c1d6)
                }
                let temporary = rotateLeft(a, by: 5) &+ function &+ e &+ constant &+ words[index]
                e = d
                d = c
                c = rotateLeft(b, by: 30)
                b = a
                a = temporary
            }
            state[0] &+= a
            state[1] &+= b
            state[2] &+= c
            state[3] &+= d
            state[4] &+= e
        }
        var digest = Data()
        for word in state {
            digest.append(UInt8((word >> 24) & 0xff))
            digest.append(UInt8((word >> 16) & 0xff))
            digest.append(UInt8((word >> 8) & 0xff))
            digest.append(UInt8(word & 0xff))
        }
        return digest
    }

    private static func rotateLeft(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }
}
