import Foundation
import Network
import Observation

struct MDNSService: Hashable, Identifiable, Sendable {
    let name: String
    let type: String
    let domain: String
    var id: String { "\(type)/\(name)" }

    /// Serviços da depuração sem fio se chamam `adb-<ro.serialno>-<sufixo>`.
    var deviceSerial: String? {
        guard name.hasPrefix("adb-") else { return nil }
        let body = name.dropFirst(4)
        guard let dash = body.lastIndex(of: "-") else { return String(body) }
        return String(body[..<dash])
    }
}

/// Descoberta nativa via Network.framework (Bonjour). Mais confiável que o mDNS
/// interno do adb e é o que permite parear via QR Code sem digitar nada.
@MainActor
@Observable
final class WirelessDiscovery {
    static let pairingType = "_adb-tls-pairing._tcp"
    static let connectType = "_adb-tls-connect._tcp"

    private(set) var pairingServices: [MDNSService] = []
    private(set) var connectServices: [MDNSService] = []
    private(set) var browserError: String?

    @ObservationIgnored private var browsers: [NWBrowser] = []
    @ObservationIgnored private var resolvers: [UUID: ServiceResolver] = [:]
    @ObservationIgnored var onConnectServicesChanged: (([MDNSService]) -> Void)?

    func start() {
        guard browsers.isEmpty else { return }
        browsers = [makeBrowser(type: Self.pairingType), makeBrowser(type: Self.connectType)]
    }

    func restart() {
        browsers.forEach { $0.cancel() }
        browsers = []
        pairingServices = []
        connectServices = []
        start()
    }

    private func makeBrowser(type: String) -> NWBrowser {
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let services: [MDNSService] = results.compactMap { result in
                if case let .service(name, type, domain, _) = result.endpoint {
                    return MDNSService(name: name, type: type, domain: domain)
                }
                return nil
            }
            Task { @MainActor in self?.update(type: type, services: services) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed(let error):
                    self?.browserError = error.localizedDescription
                case .waiting(let error):
                    self?.browserError = "Aguardando permissão de rede local: \(error.localizedDescription)"
                case .ready:
                    self?.browserError = nil
                default: break
                }
            }
        }
        browser.start(queue: .main)
        return browser
    }

    private func update(type: String, services: [MDNSService]) {
        let unique = Array(Set(services)).sorted { $0.name < $1.name }
        if type == Self.pairingType {
            pairingServices = unique
        } else {
            connectServices = unique
            onConnectServicesChanged?(unique)
        }
    }

    /// Resolve um serviço Bonjour para IP:porta sem abrir conexão
    /// (abrir uma conexão TCP no servidor de pareamento faria o Android abortar).
    func resolve(_ service: MDNSService, timeout: TimeInterval = 8) async throws -> String {
        let id = UUID()
        let resolver = ServiceResolver(service: service)
        resolvers[id] = resolver
        defer { resolvers[id] = nil }
        return try await resolver.resolve(timeout: timeout)
    }
}

/// Wrapper assíncrono do NetService (resolução Bonjour → endereços).
@MainActor
private final class ServiceResolver: NSObject, NetServiceDelegate {
    private let netService: NetService
    private var continuation: CheckedContinuation<String, Error>?

    init(service: MDNSService) {
        let type = service.type.hasSuffix(".") ? service.type : service.type + "."
        netService = NetService(domain: service.domain, type: type, name: service.name)
        super.init()
        netService.delegate = self
    }

    func resolve(timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            netService.schedule(in: .main, forMode: .common)
            netService.resolve(withTimeout: timeout)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let port = sender.port
        let addresses = sender.addresses ?? []
        MainActor.assumeIsolated {
            guard let host = Self.preferredHost(from: addresses), port > 0 else { return }
            finish(.success("\(host):\(port)"))
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        MainActor.assumeIsolated {
            finish(.failure(ADBError(message: "Não foi possível resolver o dispositivo na rede (\(errorDict))")))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        netService.stop()
        c.resume(with: result)
    }

    /// Prefere IPv4; IPv6 link-local exige escopo, o que o adb nem sempre aceita.
    nonisolated static func preferredHost(from addresses: [Data]) -> String? {
        var ipv6: String?
        for data in addresses {
            let host: String? = data.withUnsafeBytes { raw in
                guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return nil }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(data.count), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: buffer)
            }
            guard let host else { continue }
            if host.contains(":") {
                if ipv6 == nil { ipv6 = "[\(host)]" }
            } else {
                return host
            }
        }
        return ipv6
    }
}
