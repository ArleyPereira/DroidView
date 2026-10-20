import SwiftUI

struct DeviceDetailView: View {
    let device: AndroidDevice
    @Environment(AppModel.self) private var app
    @State private var battery: String?
    @State private var screen: String?
    @State private var density: String?
    @State private var working: String?
    @State private var message: String?

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if device.state == "unauthorized" {
                    unauthorizedHint
                } else if device.isOnline {
                    actions
                    qualityCard(settings: $app.settings)
                    infoGrid
                } else {
                    Label("O dispositivo está \(device.stateDescription.lowercased()). Reconecte o cabo ou verifique a rede.", systemImage: "bolt.horizontal.circle")
                        .foregroundStyle(.secondary)
                }
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(device.displayName)
        .navigationSubtitle(device.isOnline ? "Android \(device.androidVersion) · API \(device.sdk)" : device.stateDescription)
        .task(id: device.isOnline) { await loadDetails() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.tint.opacity(0.15))
                Image(systemName: "smartphone").font(.system(size: 34, weight: .light)).foregroundStyle(.tint)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName).font(.largeTitle.weight(.semibold))
                HStack(spacing: 8) {
                    Label(device.stateDescription, systemImage: device.isWireless ? "wifi" : "cable.connector")
                    if !device.brand.isEmpty { Text("·"); Text(device.brand) }
                    if let battery { Text("·"); Label(battery, systemImage: "battery.75percent") }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button { app.openMirror(device) } label: {
                    Label(app.session(for: device) == nil ? "Espelhar tela" : "Mostrar espelhamento", systemImage: "rectangle.on.rectangle")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)

                Button { app.openLogcat(serial: device.serial, title: device.displayName) } label: {
                    Label("Logcat", systemImage: "text.alignleft")
                }
                .buttonStyle(.glass)

                if !device.isWireless {
                    Button { switchToWiFi() } label: {
                        Label("Usar via Wi‑Fi", systemImage: "wifi")
                    }
                    .buttonStyle(.glass)
                    .help("Ativa adb tcpip 5555 e conecta pelo IP; depois o cabo pode ser removido")
                } else {
                    Button { app.devices.disconnect(device) } label: {
                        Label("Desconectar", systemImage: "wifi.slash")
                    }
                    .buttonStyle(.glass)
                }
                if let working {
                    ProgressView().controlSize(.small)
                    Text(working).font(.callout).foregroundStyle(.secondary)
                }
            }
            .controlSize(.large)
        }
    }

    private func qualityCard(settings: Binding<MirrorSettings>) -> some View {
        let binding = device.isWireless ? settings.wifiPreset : settings.usbPreset
        return VStack(alignment: .leading, spacing: 12) {
            Text("Qualidade de imagem (\(device.isWireless ? "Wi‑Fi" : "USB"))").font(.headline)
            Picker("Preset", selection: binding) {
                ForEach(QualityPreset.allCases) { p in
                    Text(p.title).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(binding.wrappedValue.subtitle).font(.callout).foregroundStyle(.secondary)
            Text("A mudança vale a partir do próximo espelhamento. Ajustes finos em Ajustes (⌘,).")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var infoGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            info("Modelo", device.props["ro.product.model"])
            info("Fabricante", device.props["ro.product.manufacturer"])
            info("Android", "\(device.androidVersion) (API \(device.sdk))")
            info("Patch de segurança", device.props["ro.build.version.security_patch"])
            info("Build", device.props["ro.build.display.id"])
            info("ABI", device.props["ro.product.cpu.abi"])
            info("Tela", screen)
            info("Densidade", density)
            info("Serial", device.hardwareSerial)
            info("Conexão adb", device.serial)
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func info(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value)
            }
        }
    }

    private var unauthorizedHint: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Autorização pendente").font(.headline)
                Text("Desbloqueie o aparelho e toque em **Permitir** no diálogo \"Permitir depuração USB?\". Marque \"Sempre permitir neste computador\" para não ser perguntado de novo.")
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "lock.shield").foregroundStyle(.orange).font(.title2)
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func loadDetails() async {
        guard device.isOnline else { return }
        let serial = device.serial
        let (b, s, d) = await Task.detached { () -> (String?, String?, String?) in
            let adb = ADBClient.shared
            // Fabricantes (ex.: Samsung) imprimem várias linhas com "level"; vale a "  level: N".
            let battery = (try? adb.shell(serial: serial, "dumpsys battery"))
                .flatMap { out in
                    out.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .first { $0.hasPrefix("level:") }
                }
                .map { "\($0.dropFirst(6).trimmingCharacters(in: .whitespaces))%" }
            let size = (try? adb.shell(serial: serial, "wm size"))?
                .split(separator: "\n").last?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
            let dens = (try? adb.shell(serial: serial, "wm density"))?
                .split(separator: "\n").last?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
            return (battery, size, dens.map { "\($0) dpi" })
        }.value
        battery = b
        screen = s
        density = d
    }

    private func switchToWiFi() {
        working = "Ativando Wi‑Fi…"
        message = nil
        Task {
            do {
                let result = try await app.devices.switchToWiFi(device)
                message = "\(result). Você já pode desconectar o cabo."
            } catch {
                message = error.localizedDescription
            }
            working = nil
        }
    }
}
