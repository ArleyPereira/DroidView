import Foundation
import Observation

struct AndroidDevice: Identifiable, Hashable {
    let serial: String
    var state: String
    var model: String
    var props: [String: String] = [:]

    var id: String { serial }
    var isOnline: Bool { state == "device" }
    var isWireless: Bool { serial.contains(":") || serial.contains("._adb-tls-connect.") }
    var hardwareSerial: String { props["ro.serialno"].flatMap { $0.isEmpty ? nil : $0 } ?? serial }
    var brand: String { props["ro.product.brand"]?.capitalized ?? "" }
    var displayName: String {
        let m = props["ro.product.model"] ?? model
        return m.isEmpty ? serial : m
    }
    var androidVersion: String { props["ro.build.version.release"] ?? "?" }
    var sdk: String { props["ro.build.version.sdk"] ?? "?" }
    var sdkLevel: Int { Int(sdk) ?? 0 }

    var stateDescription: String {
        switch state {
        case "device": isWireless ? "Wi‑Fi" : "USB"
        case "unauthorized": "Autorize a depuração no aparelho"
        case "offline": "Offline"
        case "authorizing": "Autorizando…"
        case "connecting": "Conectando…"
        default: state
        }
    }
}

@MainActor
@Observable
final class DeviceManager {
    private(set) var devices: [AndroidDevice] = []
    private(set) var adbError: String?
    private(set) var adbPath: String = ADBLocator.locate()?.path ?? "não encontrado"
    let discovery = WirelessDiscovery()

    @ObservationIgnored private var tracker: DeviceTracker?
    @ObservationIgnored private var propsCache: [String: [String: String]] = [:]
    @ObservationIgnored private var fetching: Set<String> = []
    @ObservationIgnored private var lastAutoConnect: [String: Date] = [:]
    @ObservationIgnored private var firstSeen: [String: Date] = [:]
    @ObservationIgnored private var reconnectTimer: Timer?
    @ObservationIgnored var settings: () -> MirrorSettings = { .load() }

    /// Aparelhos sem fio que já conectaram por aqui (`ro.serialno` → último endereço).
    private var knownWireless: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "KnownWirelessDevices") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "KnownWirelessDevices") }
    }

    var onlineDevices: [AndroidDevice] { devices.filter(\.isOnline) }

    /// Um item por aparelho físico: o adb pode ter o mesmo celular por USB, pelo
    /// nome mDNS e por IP:porta ao mesmo tempo. Preferência: USB > mDNS > IP.
    var visibleDevices: [AndroidDevice] {
        var seen: [String: Int] = [:]
        var result: [AndroidDevice] = []
        func rank(_ d: AndroidDevice) -> Int {
            if !d.isOnline { return 3 }
            if !d.isWireless { return 0 }
            return d.serial.contains("._adb-tls-connect.") ? 1 : 2
        }
        for d in devices {
            let key = d.props.isEmpty ? d.serial : d.hardwareSerial
            if let i = seen[key] {
                if rank(d) < rank(result[i]) { result[i] = d }
            } else {
                seen[key] = result.count
                result.append(d)
            }
        }
        return result
    }

    /// Serviços na rede que ainda não estão conectados.
    var discoverableServices: [MDNSService] {
        discovery.connectServices.filter { !isConnected($0) }
    }

    /// O aparelho anunciado por este serviço mDNS já tem uma conexão no adb?
    /// Considera o transport com o próprio nome do serviço (criado pelo mDNS do adb)
    /// e qualquer outro transport do mesmo `ro.serialno`.
    func isConnected(_ svc: MDNSService) -> Bool {
        onlineDevices.contains { d in
            d.serial.hasPrefix(svc.name) || (svc.deviceSerial != nil && d.hardwareSerial == svc.deviceSerial)
        }
    }

    /// Ainda há transport Wi‑Fi online sem propriedades lidas: não dá para saber
    /// de qual aparelho ele é, então qualquer reconexão agora pode duplicar.
    private var hasUnidentifiedWireless: Bool {
        onlineDevices.contains { $0.isWireless && $0.props.isEmpty }
    }

    func start() {
        guard tracker == nil else { return }
        let tracker = DeviceTracker(
            onUpdate: { [weak self] entries in Task { @MainActor in self?.apply(entries) } },
            onError: { [weak self] error in Task { @MainActor in self?.adbError = error } })
        self.tracker = tracker
        tracker.start()
        discovery.onConnectServicesChanged = { [weak self] services in self?.autoConnect(services) }
        discovery.start()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconnectLostWireless() }
        }
    }

    func device(serial: String) -> AndroidDevice? { devices.first { $0.serial == serial } }

    /// Serial atual de um aparelho (USB tem prioridade sobre Wi‑Fi).
    func currentSerial(forHardware hw: String) -> (serial: String, wireless: Bool)? {
        let candidates = onlineDevices.filter { $0.hardwareSerial == hw && !$0.props.isEmpty }
        if let usb = candidates.first(where: { !$0.isWireless }) { return (usb.serial, false) }
        if let wifi = candidates.first { return (wifi.serial, true) }
        return nil
    }

    private func apply(_ entries: [ADBDeviceEntry]) {
        devices = entries.map { e in
            AndroidDevice(serial: e.serial, state: e.state, model: e.model ?? "", props: propsCache[e.serial] ?? [:])
        }
        .sorted { ($0.isOnline ? 0 : 1, $0.displayName) < ($1.isOnline ? 0 : 1, $1.displayName) }

        for d in devices where d.isOnline && d.props.isEmpty && !fetching.contains(d.serial) {
            fetchProps(d.serial)
        }
        let serials = Set(entries.map(\.serial))
        propsCache = propsCache.filter { serials.contains($0.key) }
    }

    private func fetchProps(_ serial: String) {
        fetching.insert(serial)
        Task.detached {
            let props = (try? ADBClient.shared.getProperties(serial: serial)) ?? [:]
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.fetching.remove(serial)
                guard !props.isEmpty else { return }
                self.propsCache[serial] = props
                if let i = self.devices.firstIndex(where: { $0.serial == serial }) {
                    self.devices[i].props = props
                    let d = self.devices[i]
                    if d.isWireless, let hw = props["ro.serialno"], !hw.isEmpty {
                        var known = self.knownWireless
                        // Prefere o nome mDNS: ele sobrevive à troca de IP/porta e não duplica.
                        if !(known[hw]?.contains("._adb-tls-connect.") == true && !serial.contains("._adb-tls-connect.")) {
                            known[hw] = serial
                        }
                        self.knownWireless = known
                    }
                }
            }
        }
    }

    func refresh(_ serial: String) {
        propsCache[serial] = nil
        fetchProps(serial)
    }

    // MARK: Conexão sem fio

    func connect(address raw: String) async throws -> String {
        var address = raw.trimmingCharacters(in: .whitespaces)
        if !address.contains(":") || address.hasSuffix("]") { address += ":5555" }
        let result = try await Task.detached { try ADBClient.shared.connect(address) }.value
        return result
    }

    func pair(address: String, code: String) async throws -> String {
        let addr = address.trimmingCharacters(in: .whitespaces)
        let c = code.trimmingCharacters(in: .whitespaces)
        return try await Task.detached { try ADBClient.shared.pair(address: addr, code: c) }.value
    }

    /// Fluxo completo do QR Code: aguarda o anúncio mDNS do aparelho, pareia,
    /// aguarda o serviço de conexão e conecta.
    func pairWithQR(_ creds: QRPairingCredentials, progress: @escaping (String) -> Void) async throws -> String {
        progress("Aguardando a leitura do QR Code no aparelho…")
        let pairingService = try await waitFor(timeout: 180) { [weak self] in
            self?.discovery.pairingServices.first { $0.name == creds.serviceName }
        }
        progress("Aparelho encontrado. Pareando…")
        let address = try await discovery.resolve(pairingService)
        let result = try await pair(address: address, code: creds.password)

        // "Successfully paired to 192.168.0.10:37123 [guid=adb-XXXX-yyyy]"
        let guid = result.range(of: #"guid=([^\]\s]+)"#, options: .regularExpression)
            .map { String(result[$0].dropFirst(5)) }
        progress("Pareado! Conectando…")

        let pairedSerial = guid.flatMap { MDNSService(name: $0, type: "", domain: "").deviceSerial }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let guid, let online = onlineDevices.first(where: { $0.serial.hasPrefix(guid) || $0.hardwareSerial == pairedSerial }) {
                return online.displayName
            }
            // Dá alguns segundos para o adb conectar sozinho via mDNS antes de forçar.
            if deadline.timeIntervalSinceNow < 16,
               let svc = discovery.connectServices.first(where: { guid == nil || $0.name == guid }),
               !isConnected(svc), (try? await connect(service: svc)) != nil {
                return svc.deviceSerial ?? svc.name
            }
            try await Task.sleep(for: .seconds(1))
        }
        return "Pareado. Se não conectar sozinho, use \"Conectar\" na lista de dispositivos na rede."
    }

    /// Conecta pelo nome do serviço mDNS (`adb-SERIAL-xxx._adb-tls-connect._tcp`):
    /// o adb reaproveita o transport que ele mesmo cria via mDNS, então não surge
    /// uma segunda entrada "IP:porta" para o mesmo aparelho (o Android Studio
    /// mostraria dois dispositivos). IP:porta só como último recurso.
    func connect(service: MDNSService) async throws -> String {
        let type = service.type.hasSuffix(".") ? String(service.type.dropLast()) : service.type
        let name = "\(service.name).\(type)"
        if let result = try? await Task.detached(operation: { try ADBClient.shared.connect(name) }).value {
            return result
        }
        let addr = try await discovery.resolve(service)
        return try await connect(address: addr)
    }

    private func waitFor<T>(timeout: TimeInterval, _ probe: @escaping @MainActor () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let v = probe() { return v }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw ADBError(message: "Tempo esgotado aguardando o aparelho")
    }

    /// Ativa o modo `adb tcpip 5555` num aparelho USB e conecta pelo IP.
    func switchToWiFi(_ device: AndroidDevice) async throws -> String {
        let serial = device.serial
        let ip = try await Task.detached { () -> String in
            let out = try ADBClient.shared.shell(serial: serial, "ip -f inet addr show wlan0")
            guard let m = out.range(of: #"inet (\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression) else {
                throw ADBError(message: "O aparelho não parece estar conectado a uma rede Wi‑Fi")
            }
            return String(out[m].dropFirst(5))
        }.value
        _ = try await Task.detached { try ADBClient.shared.tcpip(serial: serial) }.value
        try await Task.sleep(for: .seconds(1.5))
        return try await connect(address: "\(ip):5555")
    }

    func disconnect(_ device: AndroidDevice) {
        var serials = [device.serial]
        if let hw = device.props["ro.serialno"] {
            var known = knownWireless
            known[hw] = nil
            knownWireless = known
            serials = devices.filter { $0.isWireless && $0.hardwareSerial == hw }.map(\.serial)
        }
        Task.detached { for s in serials { try? ADBClient.shared.disconnect(s) } }
    }

    func restartADBServer() {
        Task.detached {
            ADBClient.shared.killServer()
            try? await Task.sleep(for: .seconds(0.5))
            try? ADBClient.shared.startServer()
        }
        adbPath = ADBLocator.locate()?.path ?? "não encontrado"
    }

    // MARK: Reconexão automática

    private func autoConnect(_ services: [MDNSService]) {
        guard settings().autoConnectKnownWireless, !hasUnidentifiedWireless else { return }
        let known = knownWireless
        for svc in services {
            guard let hw = svc.deviceSerial, known[hw] != nil, !isConnected(svc) else { continue }
            // Dá tempo para o próprio adb conectar via mDNS antes de agirmos.
            let seen = firstSeen[svc.name] ?? .now
            firstSeen[svc.name] = seen
            guard Date().timeIntervalSince(seen) > 8 else { continue }
            if let last = lastAutoConnect[svc.name], Date().timeIntervalSince(last) < 10 { continue }
            lastAutoConnect[svc.name] = .now
            Task { _ = try? await connect(service: svc) }
        }
    }

    private func reconnectLostWireless() {
        guard settings().autoReconnect else { return }
        autoConnect(discovery.connectServices)
        // Endereços IP:porta clássicos (tcpip) que sumiram ou ficaram offline.
        guard !hasUnidentifiedWireless else { return }
        let onlineHW = Set(onlineDevices.map(\.hardwareSerial))
        for (hw, address) in knownWireless where !onlineHW.contains(hw) && address.contains(":") && !address.contains("._adb") {
            if let last = lastAutoConnect[address], Date().timeIntervalSince(last) < 15 { continue }
            lastAutoConnect[address] = .now
            Task.detached { _ = try? ADBClient.shared.connect(address) }
        }
    }
}
