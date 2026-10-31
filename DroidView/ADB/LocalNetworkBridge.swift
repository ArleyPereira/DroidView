import Foundation

/// Ponte TCP local → aparelho na rede.
///
/// O macOS só deixa um processo acessar a rede local se o app "responsável" tiver
/// a permissão de Rede Local. Quando o servidor adb foi iniciado por outro app
/// (ex.: o Android Studio rodando `adb logcat`), ele recebe "No route to host"
/// ao conectar no celular. O DroidView tem a permissão: escutamos em 127.0.0.1 e
/// repassamos os bytes ao aparelho, e o adb conecta em `127.0.0.1:<porta>`, que
/// não depende de permissão nenhuma. TLS e pareamento passam intactos.
final class LocalNetworkBridge: @unchecked Sendable {
    let remoteHost: String
    let remotePort: UInt16
    private(set) var localPort: UInt16 = 0
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var closed = false

    var localAddress: String { "127.0.0.1:\(localPort)" }

    /// Pontes ativas por endereço remoto ("ip:porta"); reaproveitadas entre tentativas.
    private static var bridges: [String: LocalNetworkBridge] = [:]
    private static let registryLock = NSLock()

    /// Endereço local ("127.0.0.1:porta") que leva até `address` ("ip:porta" ou "[ipv6]:porta").
    static func localAddress(for address: String) throws -> String {
        registryLock.lock(); defer { registryLock.unlock() }
        if let existing = bridges[address], !existing.isClosed { return existing.localAddress }
        guard let sep = address.lastIndex(of: ":"), let port = UInt16(address[address.index(after: sep)...]) else {
            throw ADBError(message: "Endereço inválido: \(address)")
        }
        let host = String(address[..<sep]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let bridge = LocalNetworkBridge(remoteHost: host, remotePort: port)
        try bridge.start()
        bridges[address] = bridge
        Log.info(.connect, "Ponte local \(bridge.localAddress) → \(address) criada")
        return bridge.localAddress
    }

    static func isBridge(_ serial: String) -> Bool { serial.hasPrefix("127.0.0.1:") }

    /// Endereço remoto por trás de um serial de ponte (para logs/diagnóstico).
    static func remoteAddress(forLocal serial: String) -> String? {
        registryLock.lock(); defer { registryLock.unlock() }
        return bridges.first { $0.value.localAddress == serial }?.key
    }

    private init(remoteHost: String, remotePort: UInt16) {
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    private func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.posix("socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw SocketError.posix("bind/listen")
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        localPort = UInt16(bigEndian: addr.sin_port)
        listenFD = fd
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "droidview.bridge.\(localPort)"
        t.start()
    }

    private func acceptLoop() {
        while !isClosed {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                break
            }
            let local = TCPSocket(acceptedFD: client)
            do {
                let remote = try TCPSocket(host: remoteHost, port: remotePort, timeout: 5)
                pump(from: local, to: remote, name: "up")
                pump(from: remote, to: local, name: "down")
            } catch {
                Log.warning(.connect, "Ponte \(localAddress): falha ao alcançar \(remoteHost):\(remotePort): \(error.localizedDescription)")
                local.close()
            }
        }
        Log.info(.connect, "Ponte \(localAddress) encerrada")
    }

    /// Copia bytes num sentido; quando um lado fecha, fecha os dois.
    private func pump(from source: TCPSocket, to destination: TCPSocket, name: String) {
        let t = Thread {
            while let chunk = try? source.readSome(), !chunk.isEmpty {
                if (try? destination.write(chunk)) == nil { break }
            }
            source.close()
            destination.close()
        }
        t.name = "droidview.bridge.\(localPort).\(name)"
        t.qualityOfService = .userInitiated
        t.start()
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let fd = listenFD
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
