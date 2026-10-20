import SwiftUI
import UniformTypeIdentifiers

/// Barra de controles flutuante (painel de vidro preso ao lado da janela do espelhamento).
struct ControlBar: View {
    let session: MirrorSession
    @Environment(AppModel.self) private var app
    @State private var toggles: [DevToggle: Bool] = [:]
    @AppStorage("LastDeepLink") private var lastDeepLink = ""

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(spacing: 6) {
                BarButton("power", "Ligar/desligar tela (power)") { session.power() }
                BarButton("speaker.plus", "Volume +") { session.volumeUp() }
                BarButton("speaker.minus", "Volume −") { session.volumeDown() }

                Divider().frame(width: 28).padding(.vertical, 4)

                BarButton("arrowtriangle.backward", "Voltar  (botão direito / Esc)") { session.back() }
                BarButton("circle", "Início  (⌘⇧H)") { session.home() }
                BarButton("square", "Apps recentes  (⌘⇧R)") { session.recents() }

                Divider().frame(width: 28).padding(.vertical, 4)

                BarButton("rotate.right", "Girar  (⌘→)") { session.rotate() }
                BarButton("camera.viewfinder", "Screenshot sem perdas  (⌘S)") { session.takeScreenshot() }
                BarButton(session.isRecording ? "stop.circle.fill" : "record.circle",
                          session.isRecording ? "Parar gravação  (⌘⇧G)" : "Gravar tela  (⌘⇧G)",
                          tint: session.isRecording ? .red : nil) { session.toggleRecording() }
                BarButton(session.isScreenOff ? "iphone.slash" : "iphone", session.isScreenOff ? "Religar tela do aparelho" : "Apagar tela do aparelho (continua espelhando)") {
                    session.setScreenOff(!session.isScreenOff)
                }

                Divider().frame(width: 28).padding(.vertical, 4)

                moreMenu
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 7)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(ControlPanel.shadowInset)
        .environment(\.colorScheme, .dark)
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button("Painel de notificações", systemImage: "bell") { session.expandNotifications() }
                Button("Configurações rápidas", systemImage: "switch.2") { session.expandQuickSettings() }
            }
            Section {
                Menu("Opções do desenvolvedor", systemImage: "hammer") {
                    ForEach(DevToggle.allCases) { t in
                        Toggle(isOn: Binding(get: { toggles[t] ?? false }, set: { on in
                            toggles[t] = on
                            let serial = session.serial
                            Task { await DevTools.set(t, on: on, serial: serial) }
                        })) { Label(t.title, systemImage: t.icon) }
                    }
                }
                Menu("Tamanho da fonte", systemImage: "textformat.size") {
                    ForEach([0.85, 1.0, 1.15, 1.3, 1.5], id: \.self) { s in
                        Button(s == 1 ? "Padrão (100%)" : "\(Int(s * 100))%") {
                            let serial = session.serial
                            Task { await DevTools.setFontScale(s, serial: serial) }
                        }
                    }
                }
                Menu("App em primeiro plano", systemImage: "app.badge") {
                    Button("Forçar parada", systemImage: "stop.circle") { foreground { run("am force-stop \($0)", done: "\($0) parado") } }
                    Button("Reiniciar app", systemImage: "arrow.clockwise") {
                        foreground { run("am force-stop \($0); monkey -p \($0) -c android.intent.category.LAUNCHER 1", done: "\($0) reiniciado") }
                    }
                    Button("Limpar dados…", systemImage: "trash") { foreground { confirmClearData($0) } }
                    Button("Copiar nome do pacote", systemImage: "doc.on.doc") {
                        foreground { pkg in
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pkg, forType: .string)
                            session.toast = Toast(icon: "doc.on.doc", message: pkg)
                        }
                    }
                }
                Button("Abrir deep link…", systemImage: "link") { askDeepLink() }
            }
            Section {
                Button("Instalar APK / enviar arquivo…", systemImage: "square.and.arrow.down") { pickFiles() }
                Button("Logcat", systemImage: "text.alignleft") { app.openLogcat(serial: session.serial, title: session.title) }
                Button("Colar texto do Mac", systemImage: "doc.on.clipboard") { session.pasteFromMac() }
            }
            Section {
                Button("Ajustar à tela", systemImage: "arrow.up.left.and.arrow.down.right") { app.controller(for: session)?.fitToScreen() }
                Button("Pixel a pixel (1:1)", systemImage: "1.square") { app.controller(for: session)?.pixelPerfect() }
                Toggle(isOn: Binding(get: { app.settings.alwaysOnTop }, set: { app.settings.alwaysOnTop = $0; app.applyAlwaysOnTop() })) {
                    Label("Sempre no topo", systemImage: "pin")
                }
            }
            Section {
                Menu("Reiniciar aparelho", systemImage: "restart") {
                    Button("Sistema") { confirmReboot("") }
                    Button("Recovery") { confirmReboot("recovery") }
                    Button("Bootloader") { confirmReboot("bootloader") }
                }
                Button("Copiar log do servidor", systemImage: "ladybug") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.serverLog.joined(separator: "\n"), forType: .string)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 36, height: 36)
        .contentShape(.circle)
        .background(HoverCircle())
        .help("Mais ferramentas")
        .task(id: session.serial) {
            toggles = await DevTools.readToggles(serial: session.serial)
        }
    }

    // MARK: Diálogos (alertas nativos presos à janela do espelhamento)

    private var mirrorWindow: NSWindow? { app.controller(for: session)?.window }

    private func present(_ alert: NSAlert, onConfirm: @escaping () -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { if $0 == .alertFirstButtonReturn { onConfirm() } }
        if let window = mirrorWindow { alert.beginSheetModal(for: window, completionHandler: handler) }
        else { handler(alert.runModal()) }
    }

    private func askDeepLink() {
        let alert = NSAlert()
        alert.messageText = "Abrir deep link"
        alert.informativeText = "A URL é aberta com android.intent.action.VIEW."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "myapp://rota/123 ou https://…"
        field.stringValue = lastDeepLink
        alert.accessoryView = field
        alert.addButton(withTitle: "Abrir")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        present(alert) {
            let url = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty else { return }
            lastDeepLink = url
            let serial = session.serial
            Task {
                let out = (try? await DevTools.openDeepLink(url, serial: serial)) ?? ""
                session.toast = out.contains("Error") ? Toast(icon: "xmark.octagon", message: "Nenhuma activity trata esse link")
                                                      : Toast(icon: "link", message: "Deep link aberto")
            }
        }
    }

    private func confirmClearData(_ pkg: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Limpar dados de \(pkg)?"
        alert.informativeText = "Isso apaga todos os dados locais do app no aparelho."
        alert.addButton(withTitle: "Limpar dados").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancelar")
        present(alert) { run("pm clear \(pkg)", done: "Dados de \(pkg) apagados") }
    }

    private func confirmReboot(_ target: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = target.isEmpty ? "Reiniciar o aparelho?" : "Reiniciar o aparelho em \(target)?"
        alert.addButton(withTitle: "Reiniciar").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancelar")
        let serial = session.serial
        present(alert) { Task.detached { try? ADBClient.shared.reboot(serial: serial, target: target) } }
    }

    private func foreground(_ action: @escaping @MainActor (String) -> Void) {
        let serial = session.serial
        Task {
            if let pkg = await DevTools.foregroundPackage(serial: serial) { action(pkg) }
            else { session.toast = Toast(icon: "questionmark.app", message: "Nenhum app em primeiro plano") }
        }
    }

    private func run(_ command: String, done: String) {
        let serial = session.serial
        Task {
            do {
                try await DevTools.run(command, serial: serial)
                session.toast = Toast(icon: "checkmark.circle", message: done)
            } catch {
                session.toast = Toast(icon: "xmark.octagon", message: error.localizedDescription)
            }
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Arquivos .apk serão instalados; os demais vão para Download/ no aparelho."
        guard panel.runModal() == .OK else { return }
        FileTransfer.send(panel.urls, to: session)
    }
}

private struct BarButton: View {
    let icon: String
    let help: String
    var tint: Color?
    let action: () -> Void

    init(_ icon: String, _ help: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.icon = icon
        self.help = help
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint ?? .primary)
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .buttonStyle(BarButtonStyle())
        .help(help)
        .accessibilityLabel(help.components(separatedBy: "  ").first ?? help)
    }
}

/// Botão circular "transparente" dentro da cápsula de vidro: realça no hover e no clique.
private struct BarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(HoverCircle(pressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

private struct HoverCircle: View {
    var pressed = false
    @State private var hovering = false

    var body: some View {
        Circle()
            .fill(.white.opacity(pressed ? 0.22 : hovering ? 0.12 : 0))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
