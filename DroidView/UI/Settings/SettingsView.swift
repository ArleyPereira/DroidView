import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            Tab("Imagem", systemImage: "photo.tv") { QualitySettings() }
            Tab("Comportamento", systemImage: "gearshape") { BehaviorSettings() }
            Tab("Arquivos", systemImage: "folder") { FileSettings() }
            Tab("ADB", systemImage: "terminal") { ADBSettings() }
        }
        .frame(width: 560, height: 470)
    }
}

private struct QualitySettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Presets") {
                Picker("Via USB", selection: $app.settings.usbPreset) {
                    ForEach(QualityPreset.allCases) { Text($0.title).tag($0) }
                }
                Picker("Via Wi‑Fi", selection: $app.settings.wifiPreset) {
                    ForEach(QualityPreset.allCases) { Text($0.title).tag($0) }
                }
                Picker("Codec de vídeo", selection: $app.settings.codec) {
                    ForEach(CodecPreference.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Personalizada") {
                Picker("Resolução máxima", selection: $app.settings.customMaxSize) {
                    Text("Nativa").tag(0)
                    ForEach([2560, 1920, 1600, 1280, 1024, 800], id: \.self) { Text("\($0) px").tag($0) }
                }
                VStack(alignment: .leading) {
                    Slider(value: Binding(get: { Double(app.settings.customBitrateMbps) }, set: { app.settings.customBitrateMbps = Int($0) }), in: 2...80, step: 1) {
                        Text("Bitrate")
                    }
                    Text("\(app.settings.customBitrateMbps) Mbps").font(.caption).foregroundStyle(.secondary)
                }
                Picker("FPS máximo", selection: $app.settings.customMaxFps) {
                    Text("Sem limite").tag(0)
                    ForEach([120, 90, 60, 30], id: \.self) { Text("\($0) fps").tag($0) }
                }
            }
            Section {
                Text("H.265 entrega a mesma qualidade com cerca de metade do bitrate e é decodificado por hardware no Mac. Se o aparelho não tiver encoder H.265, o modo automático cai para H.264.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct BehaviorSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Espelhamento") {
                Toggle("Manter o aparelho acordado", isOn: $app.settings.stayAwake)
                Toggle("Apagar a tela do aparelho ao iniciar", isOn: $app.settings.turnScreenOffOnStart)
                Toggle("Desligar a tela do aparelho ao fechar", isOn: $app.settings.powerOffOnClose)
                Toggle("Mostrar toques enquanto espelha", isOn: $app.settings.showTouchesWhileMirroring)
                Toggle("Sincronizar área de transferência", isOn: $app.settings.clipboardSync)
                Toggle("Mostrar barra de controles flutuante", isOn: $app.settings.showControlBar)
                Toggle("Janela sempre no topo", isOn: $app.settings.alwaysOnTop)
                    .onChange(of: app.settings.alwaysOnTop) { app.applyAlwaysOnTop() }
            }
            Section("Conexão") {
                Toggle("Reconectar automaticamente quando a conexão cair", isOn: $app.settings.autoReconnect)
                Toggle("Conectar sozinho a aparelhos Wi‑Fi conhecidos", isOn: $app.settings.autoConnectKnownWireless)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FileSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Screenshots") {
                folderRow("Pasta inicial ao salvar", path: $app.settings.screenshotFolder)
                Text("Ao capturar, uma prévia oferece Copiar, Salvar… e Cancelar. O painel de salvar lembra a última pasta usada.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Gravações") {
                folderRow("Pasta", path: $app.settings.recordingFolder)
                Text("As gravações usam o próprio stream H.265/H.264 (sem re-encode).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func folderRow(_ title: String, path: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                Text((path.wrappedValue as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Escolher…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
                }
            }
        }
    }
}

private struct ADBSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Servidor ADB") {
                LabeledContent("Executável") {
                    Text(app.devices.adbPath).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
                LabeledContent("Origem") {
                    Text(ADBLocator.isUsingBundled ? "Embutido no DroidView" : "Android SDK / sistema")
                }
                LabeledContent("Servidor scrcpy") { Text("v\(ScrcpyServer.version) (Apache 2.0)") }
                Button("Reiniciar servidor ADB") { app.devices.restartADBServer() }
                Text("O DroidView compartilha o servidor ADB com o Android Studio (porta 5037), então os dois funcionam ao mesmo tempo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Rede") {
                Button("Reiniciar descoberta Wi‑Fi (mDNS)") { app.devices.discovery.restart() }
                if let err = app.devices.discovery.browserError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}
