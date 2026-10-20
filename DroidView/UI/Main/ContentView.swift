import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: String?
    @State private var showWireless = false
    @State private var wirelessTab: WirelessConnectView.Tab = .qr

    private var devices: DeviceManager { app.devices }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            if let serial = selection, let device = devices.device(serial: serial) {
                DeviceDetailView(device: device)
                    .id(device.serial)
            } else {
                WelcomeView(onQR: { open(.qr) }, onCode: { open(.code) }, onIP: { open(.ip) })
            }
        }
        .sheet(isPresented: $showWireless) {
            WirelessConnectView(tab: wirelessTab)
                .environment(app)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { open(.qr) } label: { Label("Conectar via Wi‑Fi", systemImage: "wifi") }
                    .help("Conectar via Wi‑Fi (QR Code, código ou IP)")
            }
        }
        .onChange(of: devices.devices) { _, _ in
            let list = devices.visibleDevices
            if selection == nil || !list.contains(where: { $0.serial == selection }) {
                selection = list.first(where: \.isOnline)?.serial ?? list.first?.serial
            }
        }
    }

    private func open(_ tab: WirelessConnectView.Tab) {
        wirelessTab = tab
        showWireless = true
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Dispositivos") {
                if devices.visibleDevices.isEmpty {
                    Text("Nenhum dispositivo conectado")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(devices.visibleDevices) { d in
                    DeviceRow(device: d, isMirroring: app.session(for: d) != nil)
                        .tag(d.serial)
                        .contextMenu {
                            Button("Espelhar tela") { app.openMirror(d) }.disabled(!d.isOnline)
                            Button("Logcat") { app.openLogcat(serial: d.serial, title: d.displayName) }.disabled(!d.isOnline)
                            if d.isWireless { Button("Desconectar") { devices.disconnect(d) } }
                        }
                }
            }
            if !devices.discoverableServices.isEmpty {
                Section("Na rede (depuração sem fio)") {
                    ForEach(devices.discoverableServices) { svc in
                        NetworkServiceRow(service: svc)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if let err = devices.adbError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
                Button { open(.qr) } label: {
                    Label("Conectar via Wi‑Fi…", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(12)
        }
    }
}

struct DeviceRow: View {
    let device: AndroidDevice
    let isMirroring: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isWireless ? "wifi" : "cable.connector")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(device.isOnline ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).fontWeight(.medium).lineLimit(1)
                Text(device.isOnline ? "Android \(device.androidVersion) · \(device.stateDescription)" : device.stateDescription)
                    .font(.caption)
                    .foregroundStyle(device.state == "unauthorized" ? .orange : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isMirroring {
                Image(systemName: "rectangle.on.rectangle")
                    .foregroundStyle(.green)
                    .help("Espelhando")
            }
        }
        .padding(.vertical, 3)
    }
}

private struct NetworkServiceRow: View {
    let service: MDNSService
    @Environment(AppModel.self) private var app
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        HStack {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.deviceSerial ?? service.name).lineLimit(1)
                Text(error ?? "Pareado anteriormente?").font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.orange).lineLimit(2)
            }
            Spacer()
            if connecting {
                ProgressView().controlSize(.small)
            } else {
                Button("Conectar") {
                    connecting = true
                    error = nil
                    Task {
                        do { _ = try await app.devices.connect(service: service) }
                        catch { self.error = "Pareie primeiro (QR ou código)" }
                        connecting = false
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
    }
}

struct WelcomeView: View {
    let onQR: () -> Void
    let onCode: () -> Void
    let onIP: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
            VStack(spacing: 6) {
                Text("Conecte um dispositivo Android").font(.title2.weight(.semibold))
                Text("Ligue o cabo USB com a **Depuração USB** ativada, ou conecte pela rede usando a **Depuração sem fio** (Android 11+).")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
            }
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: onQR) { Label("Parear com QR Code", systemImage: "qrcode") }
                        .buttonStyle(.glassProminent)
                    Button(action: onCode) { Label("Código de pareamento", systemImage: "number") }
                        .buttonStyle(.glass)
                    Button(action: onIP) { Label("Endereço IP", systemImage: "network") }
                        .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
