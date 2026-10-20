import Foundation

struct ADBDeviceEntry: Hashable, Sendable {
    let serial: String
    let state: String
    let attributes: [String: String]

    var isOnline: Bool { state == "device" }
    var model: String? { attributes["model"]?.replacingOccurrences(of: "_", with: " ") }
}

/// Mantém um socket `host:track-devices-l` aberto: o servidor adb empurra a lista
/// completa a cada mudança. Reabre sozinho se o servidor adb reiniciar.
final class DeviceTracker: @unchecked Sendable {
    private let client: ADBClient
    private let onUpdate: @Sendable ([ADBDeviceEntry]) -> Void
    private let onError: @Sendable (String?) -> Void
    private var thread: Thread?
    private var socket: TCPSocket?
    private let lock = NSLock()
    private var running = false

    init(client: ADBClient = .shared,
         onUpdate: @escaping @Sendable ([ADBDeviceEntry]) -> Void,
         onError: @escaping @Sendable (String?) -> Void) {
        self.client = client
        self.onUpdate = onUpdate
        self.onError = onError
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "adb.track-devices"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    func stop() {
        lock.lock()
        running = false
        let s = socket
        lock.unlock()
        s?.close()
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func loop() {
        while isRunning {
            do {
                let s = try client.connectToServer()
                lock.lock(); socket = s; lock.unlock()
                try client.send("host:track-devices-l", on: s)
                onError(nil)
                while isRunning {
                    let payload = try client.readLengthPrefixed(s)
                    onUpdate(Self.parse(payload))
                }
            } catch {
                guard isRunning else { break }
                onError(error.localizedDescription)
                onUpdate([])
                Thread.sleep(forTimeInterval: 1.5)
            }
        }
    }

    static func parse(_ payload: String) -> [ADBDeviceEntry] {
        payload.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { return nil }
            var attrs: [String: String] = [:]
            for f in fields.dropFirst(2) {
                if let idx = f.firstIndex(of: ":") {
                    attrs[String(f[..<idx])] = String(f[f.index(after: idx)...])
                }
            }
            return ADBDeviceEntry(serial: fields[0], state: fields[1], attributes: attrs)
        }
    }
}
