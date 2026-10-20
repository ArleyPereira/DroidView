import Foundation

struct ScrcpyLaunchOptions: Sendable {
    var codec: VideoCodec
    var maxSize: Int
    var bitrate: Int
    var maxFps: Int
    var stayAwake: Bool
    var powerOffOnClose: Bool
    var clipboardAutosync: Bool
}

/// Sockets abertos com o servidor que roda no Android.
struct ScrcpyStreams: @unchecked Sendable {
    let video: TCPSocket
    let control: TCPSocket
    let deviceName: String
}

/// Envia o scrcpy-server (Apache 2.0) e o executa via `app_process`, a mesma
/// técnica que o Vysor usa com o APK dele: nada é instalado no aparelho.
final class ScrcpyServer: @unchecked Sendable {
    static let version = "5.0.1"
    static let remotePath = "/data/local/tmp/droidview-server.jar"

    let serial: String
    let scid: UInt32 = UInt32.random(in: 1...0x7FFF_FFFF)
    private let adb = ADBClient.shared
    private var shell: TCPSocket?
    private let lock = NSLock()
    private var output: [String] = []
    private var exited = false

    var onLog: ((String) -> Void)?

    init(serial: String) { self.serial = serial }

    private var socketName: String { String(format: "scrcpy_%08x", scid) }

    var recentOutput: String {
        lock.lock(); defer { lock.unlock() }
        return output.suffix(12).joined(separator: "\n")
    }

    private var hasExited: Bool { lock.lock(); defer { lock.unlock() }; return exited }

    /// Bloqueante. Chamar fora da main thread.
    func start(_ options: ScrcpyLaunchOptions) throws -> ScrcpyStreams {
        try pushServerIfNeeded()

        var args = [
            "CLASSPATH=\(Self.remotePath)", "app_process", "/", "com.genymobile.scrcpy.Server", Self.version,
            String(format: "scid=%08x", scid),
            "log_level=info",
            "tunnel_forward=true",
            "video_codec=\(options.codec.rawValue)",
            "video_bit_rate=\(options.bitrate)",
            "audio=false", // o som continua tocando no próprio aparelho
            "clipboard_autosync=\(options.clipboardAutosync)",
        ]
        if options.maxSize > 0 { args.append("max_size=\(options.maxSize)") }
        if options.maxFps > 0 { args.append("max_fps=\(options.maxFps)") }
        if options.stayAwake { args.append("stay_awake=true") }
        if options.powerOffOnClose { args.append("power_off_on_close=true") }

        let shellSocket = try adb.openService(serial: serial, "shell:" + args.joined(separator: " "))
        lock.lock(); shell = shellSocket; output = []; exited = false; lock.unlock()
        startOutputReader(shellSocket)

        let video = try connectWithRetry()
        do {
            _ = try video.readUInt8() // dummy byte enviado no primeiro socket
            let control = try adb.openService(serial: serial, "localabstract:\(socketName)")
            let nameData = try video.read(exactly: 64)
            let name = String(decoding: nameData.prefix { $0 != 0 }, as: UTF8.self)
            video.setReceiveBuffer(4 * 1024 * 1024)
            return ScrcpyStreams(video: video, control: control, deviceName: name)
        } catch {
            video.close()
            throw error
        }
    }

    func stop() {
        lock.lock()
        let s = shell
        shell = nil
        lock.unlock()
        s?.close()
    }

    private func pushServerIfNeeded() throws {
        guard let url = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) else {
            throw ADBError(message: "scrcpy-server não encontrado no bundle do app")
        }
        let local = try Data(contentsOf: url)
        let remoteSize = try? adb.shell(serial: serial, "stat -c %s \(Self.remotePath) 2>/dev/null")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if remoteSize == String(local.count) { return }
        try adb.push(serial: serial, data: local, to: Self.remotePath)
    }

    private func connectWithRetry() throws -> TCPSocket {
        var lastError: Error = ADBError(message: "Servidor não respondeu")
        for _ in 0..<100 {
            if hasExited {
                throw ADBError(message: "O servidor no dispositivo encerrou:\n\(recentOutput)")
            }
            do {
                return try adb.openService(serial: serial, "localabstract:\(socketName)")
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw lastError
    }

    private func startOutputReader(_ socket: TCPSocket) {
        let t = Thread { [weak self] in
            var pending = ""
            while let chunk = try? socket.readSome() {
                pending += String(decoding: chunk, as: UTF8.self)
                while let nl = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
                    pending = String(pending[pending.index(after: nl)...])
                    guard !line.isEmpty, let self else { continue }
                    self.lock.lock(); self.output.append(line); if self.output.count > 200 { self.output.removeFirst(50) }; self.lock.unlock()
                    self.onLog?(line)
                }
            }
            guard let self else { return }
            self.lock.lock(); self.exited = true; self.lock.unlock()
        }
        t.name = "droidview.server.output"
        t.start()
    }
}
