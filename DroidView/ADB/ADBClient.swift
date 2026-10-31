import Foundation

struct ADBError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Localiza o executável adb. Preferência: Android SDK do usuário (o mesmo do
/// Android Studio, evitando dois servidores adb brigando pela porta 5037), depois
/// Homebrew e por último o adb embutido no app.
enum ADBLocator {
    static func locate() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let h = env["ANDROID_HOME"] { candidates.append("\(h)/platform-tools/adb") }
        if let h = env["ANDROID_SDK_ROOT"] { candidates.append("\(h)/platform-tools/adb") }
        candidates += [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("platform-tools/adb").path {
            candidates.append(bundled)
        }
        return candidates.lazy
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
            .first
    }

    static var isUsingBundled: Bool {
        guard let url = locate(), let res = Bundle.main.resourceURL else { return false }
        return url.path.hasPrefix(res.path)
    }
}

/// Cliente nativo do protocolo "smart socket" do servidor ADB (porta 5037).
/// Em vez de executar `adb` e parsear texto, conversamos direto com o servidor,
/// exatamente como o próprio adb client, o Android Studio e o Vysor fazem.
final class ADBClient: @unchecked Sendable {
    static let shared = ADBClient()

    let port: UInt16 = 5037
    private let startLock = NSLock()

    // MARK: Conexão com o servidor

    func connectToServer() throws -> TCPSocket {
        if let s = try? TCPSocket(port: port, timeout: 2) { return s }
        try startServer()
        return try TCPSocket(port: port, timeout: 5)
    }

    func startServer() throws {
        startLock.lock(); defer { startLock.unlock() }
        if (try? TCPSocket(port: port, timeout: 1)) != nil { return }
        guard let adb = ADBLocator.locate() else {
            throw ADBError(message: "adb não encontrado. Instale o Android SDK Platform-Tools.")
        }
        let p = Process()
        p.executableURL = adb
        p.arguments = ["start-server"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
    }

    func killServer() {
        try? hostRequest("host:kill")
    }

    // MARK: Primitivas do protocolo

    private func encode(_ request: String) -> Data {
        let payload = Data(request.utf8)
        var data = Data(String(format: "%04x", payload.count).utf8)
        data.append(payload)
        return data
    }

    /// Envia uma requisição e consome OKAY/FAIL.
    func send(_ request: String, on socket: TCPSocket) throws {
        try socket.write(encode(request))
        try readStatus(socket, context: request)
    }

    func readStatus(_ socket: TCPSocket, context: String) throws {
        let status = String(decoding: try socket.read(exactly: 4), as: UTF8.self)
        switch status {
        case "OKAY": return
        case "FAIL": throw ADBError(message: (try? readLengthPrefixed(socket)) ?? "Falha em \(context)")
        default: throw ADBError(message: "Resposta inesperada do adb (\(status)) para \(context)")
        }
    }

    func readLengthPrefixed(_ socket: TCPSocket) throws -> String {
        let lenHex = String(decoding: try socket.read(exactly: 4), as: UTF8.self)
        // Alguns serviços (ex.: host:pair no adb 37) respondem OKAY e depois FAIL + motivo.
        if lenHex == "FAIL" { throw ADBError(message: try readLengthPrefixed(socket)) }
        guard let len = Int(lenHex, radix: 16) else { throw ADBError(message: "Tamanho inválido: \(lenHex)") }
        return String(decoding: try socket.read(exactly: len), as: UTF8.self)
    }

    /// `host:` request sem payload de resposta.
    func hostRequest(_ request: String) throws {
        let s = try connectToServer()
        defer { s.close() }
        try send(request, on: s)
    }

    /// `host:` request que responde com uma string com prefixo de tamanho.
    /// `timeout`: limite para a resposta (connect/pair podem ficar presos em
    /// "Operation timed out" do adb por mais de um minuto).
    func hostQuery(_ request: String, timeout: TimeInterval? = nil) throws -> String {
        let s = try connectToServer()
        defer { s.close() }
        if let timeout { s.setReadTimeout(timeout) }
        do {
            try send(request, on: s)
            return try readLengthPrefixed(s)
        } catch let error as SocketError where timeout != nil && error.message.contains("temporarily unavailable") {
            throw ADBError(message: "Tempo esgotado aguardando o adb (\(Int(timeout!)) s)")
        }
    }

    /// Abre um serviço no dispositivo (shell:, exec:, sync:, localabstract:...).
    func openService(serial: String, _ service: String) throws -> TCPSocket {
        let s = try connectToServer()
        do {
            try send("host:transport:\(serial)", on: s)
            try send(service, on: s)
            return s
        } catch {
            s.close()
            throw error
        }
    }

    // MARK: Comandos de alto nível

    func version() throws -> Int {
        Int(try hostQuery("host:version"), radix: 16) ?? 0
    }

    @discardableResult
    func shell(serial: String, _ command: String) throws -> String {
        let s = try openService(serial: serial, "shell:\(command)")
        defer { s.close() }
        return String(decoding: try s.readToEnd(), as: UTF8.self)
    }

    /// `exec:` não passa por PTY: saída binária intacta (ex.: screencap -p).
    func exec(serial: String, _ command: String) throws -> Data {
        let s = try openService(serial: serial, "exec:\(command)")
        defer { s.close() }
        return try s.readToEnd()
    }

    func getProperties(serial: String) throws -> [String: String] {
        let out = try shell(serial: serial, "getprop")
        var props: [String: String] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            // [ro.product.model]: [Pixel 8]
            let parts = line.components(separatedBy: "]: [")
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "[ "))
            let value = String(parts[1].dropLast())
            props[key] = value
        }
        return props
    }

    func connect(_ address: String) throws -> String {
        try withLocalNetworkRecovery {
            let result = try hostQuery("host:connect:\(address)", timeout: 15)
            if result.contains("failed") || result.contains("cannot") || result.contains("unable") {
                throw ADBError(message: result)
            }
            return result
        }
    }

    /// O macOS (privacidade de "Rede local") bloqueia o servidor adb quando ele foi
    /// iniciado por um processo sem essa permissão: o erro é "No route to host".
    /// Reiniciamos o servidor a partir do DroidView, que tem a permissão, e repetimos.
    private func withLocalNetworkRecovery<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            guard error.localizedDescription.localizedCaseInsensitiveContains("no route to host") else { throw error }
            restartServer()
            return try body()
        }
    }

    func restartServer() {
        killServer()
        for _ in 0..<20 where (try? TCPSocket(port: port, timeout: 0.3)) != nil {
            Thread.sleep(forTimeInterval: 0.1)
        }
        try? startServer()
    }

    @discardableResult
    func disconnect(_ address: String) throws -> String {
        try hostQuery("host:disconnect:\(address)")
    }

    /// Pareamento da depuração sem fio (Android 11+). Feito pelo próprio servidor adb
    /// (SPAKE2 + TLS), igual ao `adb pair`.
    func pair(address: String, code: String) throws -> String {
        try withLocalNetworkRecovery {
            let result: String
            do {
                result = try hostQuery("host:pair:\(code):\(address)", timeout: 30)
            } catch {
                throw Self.explainUnreachable(error, address: address)
            }
            guard result.lowercased().contains("success") else {
                if result.contains("Unable to start pairing client") {
                    // Detalhe real ("No route to host") só aparece no log do adb.
                    throw ADBError(message: "\(result) (no route to host?)")
                }
                throw ADBError(message: result)
            }
            return result
        }
    }

    /// "Host is down" / "Unable to start pairing client": o Mac não alcança o IP
    /// anunciado pelo aparelho (IP antigo em cache no mDNS ou rede isolada).
    static func explainUnreachable(_ error: Error, address: String) -> Error {
        let text = error.localizedDescription
        let unreachable = ["host is down", "unable to start pairing", "timed out", "tempo esgotado", "connection refused"]
        guard unreachable.contains(where: text.localizedCaseInsensitiveContains) else { return error }
        return ADBError(message: "O Mac não conseguiu alcançar o celular em \(address) (\(text)). "
            + "Confira em Depuração sem fio se o IP do aparelho é esse; se for diferente, use a aba Código de pareamento "
            + "com o IP mostrado no celular. Redes com isolamento de clientes (comum em Wi‑Fi de convidados) também bloqueiam a conexão.")
    }

    func tcpip(serial: String, port: Int = 5555) throws -> String {
        let s = try openService(serial: serial, "tcpip:\(port)")
        defer { s.close() }
        return String(decoding: try s.readToEnd(), as: UTF8.self)
    }

    func reboot(serial: String, target: String = "") throws {
        let s = try openService(serial: serial, "reboot:\(target)")
        s.close()
    }

    // MARK: Sync (push)

    func push(serial: String, data: Data, to remotePath: String, mode: Int32 = 0o644) throws {
        let s = try openService(serial: serial, "sync:")
        defer { s.close() }

        var header = Data("SEND".utf8)
        let spec = Data("\(remotePath),\(mode)".utf8)
        header.appendLE(UInt32(spec.count))
        header.append(spec)
        try s.write(header)

        let chunkSize = 64 * 1024
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            var chunk = Data("DATA".utf8)
            chunk.appendLE(UInt32(end - offset))
            chunk.append(data[offset..<end])
            try s.write(chunk)
            offset = end
        }
        var done = Data("DONE".utf8)
        done.appendLE(UInt32(Date().timeIntervalSince1970))
        try s.write(done)

        let response = try s.read(exactly: 8)
        let id = String(decoding: response.prefix(4), as: UTF8.self)
        if id == "FAIL" {
            let len = Int(response.uint32LE(at: 4))
            let msg = String(decoding: try s.read(exactly: len), as: UTF8.self)
            throw ADBError(message: "Falha ao enviar arquivo: \(msg)")
        }
        var quit = Data("QUIT".utf8)
        quit.appendLE(UInt32(0))
        try? s.write(quit)
    }

    func push(serial: String, file: URL, to remotePath: String) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        try push(serial: serial, data: data, to: remotePath)
    }

    func install(serial: String, apk: URL) throws -> String {
        let remote = "/data/local/tmp/droidview-install-\(UUID().uuidString.prefix(8)).apk"
        try push(serial: serial, file: apk, to: remote)
        let out = try shell(serial: serial, "pm install -r -t -d '\(remote)'; rm -f '\(remote)'")
        guard out.contains("Success") else { throw ADBError(message: out.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return out
    }
}
