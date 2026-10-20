import SwiftUI

struct WirelessConnectView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case qr, code, ip
        var id: String { rawValue }
        var title: String {
            switch self {
            case .qr: "QR Code"
            case .code: "Código de pareamento"
            case .ip: "Endereço IP"
            }
        }
    }

    @State var tab: Tab
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Group {
                switch tab {
                case .qr: QRPairingPane()
                case .code: CodePairingPane()
                case .ip: IPConnectPane()
                }
            }
            .frame(width: 560, height: 380)

            Divider()
            HStack {
                Text("Requer o celular e o Mac na mesma rede Wi‑Fi.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
    }
}

// MARK: - QR Code

private struct QRPairingPane: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var creds = QRPairingCredentials.random()
    @State private var status = "Aguardando a leitura do QR Code no aparelho…"
    @State private var phase: Phase = .waiting
    @State private var attempt = 0

    enum Phase { case waiting, working, done, failed }

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(.white)
                if let img = QRCodeRenderer.image(for: creds.payload, size: 200) {
                    Image(nsImage: img).interpolation(.none)
                }
                if phase == .done {
                    RoundedRectangle(cornerRadius: 20).fill(.background.opacity(0.9))
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                }
            }
            .frame(width: 228, height: 228)

            VStack(alignment: .leading, spacing: 12) {
                Text("No aparelho Android:").font(.headline)
                step(1, "Abra **Configurações › Opções do desenvolvedor**")
                step(2, "Entre em **Depuração sem fio** e ative")
                step(3, "Toque em **Parear o dispositivo com um QR code**")
                step(4, "Aponte a câmera para este código")
                Spacer().frame(height: 4)
                HStack(spacing: 8) {
                    switch phase {
                    case .waiting, .working: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if phase == .failed || phase == .done {
                    Button(phase == .done ? "Parear outro aparelho" : "Gerar novo QR Code") {
                        creds = .random()
                        attempt += 1
                    }
                    .buttonStyle(.glass)
                }
                if let err = app.devices.discovery.browserError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .task(id: attempt) { await run() }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).frame(width: 18, height: 18).background(.tint.opacity(0.2), in: .circle)
            Text(text).font(.callout)
        }
    }

    private func run() async {
        phase = .waiting
        status = "Aguardando a leitura do QR Code no aparelho…"
        do {
            let result = try await app.devices.pairWithQR(creds) { msg in
                status = msg
                if !msg.hasPrefix("Aguardando") { phase = .working }
            }
            phase = .done
            status = "Conectado: \(result)"
        } catch is CancellationError {
        } catch {
            phase = .failed
            status = error.localizedDescription
        }
    }
}

// MARK: - Código de pareamento

private struct CodePairingPane: View {
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @State private var code = ""
    @State private var connectAddress = ""
    @State private var status: String?
    @State private var busy = false
    @State private var ok = false

    var body: some View {
        Form {
            Section {
                Text("No aparelho: **Depuração sem fio › Parear o dispositivo com um código de pareamento**. Digite o código de 6 dígitos e o IP:porta mostrados.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !app.devices.discovery.pairingServices.isEmpty {
                Section("Encontrados aguardando pareamento") {
                    ForEach(app.devices.discovery.pairingServices) { svc in
                        Button {
                            Task {
                                if let addr = try? await app.devices.discovery.resolve(svc) { address = addr }
                            }
                        } label: {
                            Label(svc.deviceSerial ?? svc.name, systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            Section {
                TextField("IP e porta de pareamento", text: $address, prompt: Text("192.168.0.10:37123"))
                TextField("Código de pareamento", text: $code, prompt: Text("123456"))
                    .font(.body.monospacedDigit())
                TextField("IP e porta de conexão (opcional)", text: $connectAddress, prompt: Text("Detectado automaticamente"))
            }
            Section {
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    if let status {
                        Label(status, systemImage: ok ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(ok ? .green : .secondary)
                            .font(.callout)
                    }
                    Spacer()
                    Button("Parear e conectar", action: pair)
                        .buttonStyle(.glassProminent)
                        .disabled(busy || address.isEmpty || code.count < 6)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pair() {
        busy = true
        ok = false
        status = "Pareando…"
        Task {
            defer { busy = false }
            do {
                let result = try await app.devices.pair(address: address, code: code)
                status = "Pareado. Conectando…"
                if !connectAddress.isEmpty {
                    _ = try await app.devices.connect(address: connectAddress)
                } else {
                    // A porta de conexão é diferente da de pareamento: descobre via mDNS.
                    let guid = result.range(of: #"guid=([^\]\s]+)"#, options: .regularExpression).map { String(result[$0].dropFirst(5)) }
                    let host = address.split(separator: ":").first.map(String.init) ?? ""
                    for _ in 0..<15 {
                        if let svc = app.devices.discovery.connectServices.first(where: { $0.name == guid }),
                           (try? await app.devices.connect(service: svc)) != nil { break }
                        if app.devices.onlineDevices.contains(where: { d in
                            d.serial.hasPrefix(host) || (guid.map { d.serial.hasPrefix($0) } ?? false)
                        }) { break }
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                ok = true
                status = "Pareado e conectado"
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

// MARK: - IP

private struct IPConnectPane: View {
    @Environment(AppModel.self) private var app
    @AppStorage("LastIPAddress") private var address = ""
    @State private var status: String?
    @State private var busy = false
    @State private var ok = false

    var body: some View {
        Form {
            Section {
                Text("Use o **IP:porta** exibido em *Depuração sem fio* (Android 11+, depois de pareado) ou um aparelho em modo `adb tcpip 5555`. Se a porta for omitida, usamos 5555.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                TextField("Endereço", text: $address, prompt: Text("192.168.0.10:5555"))
                    .onSubmit(connect)
            }
            Section {
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    if let status {
                        Label(status, systemImage: ok ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(ok ? .green : .secondary)
                            .font(.callout)
                    }
                    Spacer()
                    Button("Conectar", action: connect)
                        .buttonStyle(.glassProminent)
                        .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            Section("Dica") {
                Text("Conectado por USB? Selecione o aparelho e use **Usar via Wi‑Fi**, que configura tudo automaticamente.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func connect() {
        busy = true
        ok = false
        status = "Conectando…"
        Task {
            defer { busy = false }
            do {
                status = try await app.devices.connect(address: address)
                ok = true
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
