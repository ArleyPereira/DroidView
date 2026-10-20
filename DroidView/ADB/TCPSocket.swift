import Foundation
import Darwin

struct SocketError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static func posix(_ what: String) -> SocketError {
        SocketError(message: "\(what): \(String(cString: strerror(errno)))")
    }
}

/// Socket TCP bloqueante e minimalista. Cada stream (vídeo, áudio, controle, adb)
/// roda em sua própria thread, então leituras bloqueantes são a forma mais simples
/// e de menor latência de consumir os dados.
final class TCPSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private(set) var isClosed = false

    init(host: String = "127.0.0.1", port: UInt16, timeout: TimeInterval = 5) throws {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &result)
        guard rc == 0, let first = result else {
            throw SocketError(message: "Não foi possível resolver \(host)")
        }
        defer { freeaddrinfo(result) }

        var lastError: SocketError = SocketError(message: "Falha ao conectar em \(host):\(port)")
        var info: UnsafeMutablePointer<addrinfo>? = first
        var connected: Int32 = -1
        while let ai = info {
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s >= 0 {
                var on: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                if Darwin.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                    connected = s
                    break
                }
                lastError = .posix("connect \(host):\(port)")
                Darwin.close(s)
            }
            info = ai.pointee.ai_next
        }
        guard connected >= 0 else { throw lastError }
        fd = connected
        var nodelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
        // Leituras não têm timeout: streams de vídeo podem ficar parados (tela estática).
        var zero = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &zero, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close() }

    func setReadTimeout(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func setReceiveBuffer(_ bytes: Int32) {
        var size = bytes
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var ptr = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.send(fd, ptr, remaining, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.posix("send")
                }
                remaining -= n
                ptr = ptr.advanced(by: n)
            }
        }
    }

    func write(_ string: String) throws { try write(Data(string.utf8)) }

    /// Lê exatamente `count` bytes ou lança erro em EOF.
    func read(exactly count: Int) throws -> Data {
        var data = Data(count: count)
        if count == 0 { return data }
        try data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            try readFully(into: raw.baseAddress!, count: count)
        }
        return data
    }

    func readFully(into buffer: UnsafeMutableRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.recv(fd, buffer.advanced(by: offset), count - offset, 0)
            if n == 0 { throw SocketError(message: "Conexão encerrada") }
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError.posix("recv")
            }
            offset += n
        }
    }

    /// Lê até `max` bytes. Retorna `nil` em EOF.
    func readSome(max: Int = 64 * 1024) throws -> Data? {
        var data = Data(count: max)
        let n: Int = data.withUnsafeMutableBytes { raw in
            var r: Int
            repeat { r = Darwin.recv(fd, raw.baseAddress!, max, 0) } while r < 0 && errno == EINTR
            return r
        }
        if n == 0 { return nil }
        if n < 0 { throw SocketError.posix("recv") }
        data.count = n
        return data
    }

    func readToEnd() throws -> Data {
        var all = Data()
        while let chunk = try readSome() { all.append(chunk) }
        return all
    }

    func readUInt8() throws -> UInt8 { try read(exactly: 1)[0] }
    func readUInt32BE() throws -> UInt32 { try read(exactly: 4).uint32BE(at: 0) }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

extension Data {
    func uint16BE(at i: Int) -> UInt16 {
        let b = startIndex + i
        return UInt16(self[b]) << 8 | UInt16(self[b + 1])
    }
    func uint32BE(at i: Int) -> UInt32 {
        let b = startIndex + i
        return UInt32(self[b]) << 24 | UInt32(self[b + 1]) << 16 | UInt32(self[b + 2]) << 8 | UInt32(self[b + 3])
    }
    func uint64BE(at i: Int) -> UInt64 {
        UInt64(uint32BE(at: i)) << 32 | UInt64(uint32BE(at: i + 4))
    }
    func uint32LE(at i: Int) -> UInt32 {
        let b = startIndex + i
        return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24
    }

    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
