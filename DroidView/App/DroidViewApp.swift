import SwiftUI

@main
struct DroidViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let app = AppModel.shared

    var body: some Scene {
        Window("DroidView", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 760, minHeight: 500)
        }
        .defaultSize(width: 980, height: 640)
        .commands { DeviceCommands(app: app) }

        Settings {
            SettingsView().environment(app)
        }

        MenuBarExtra("DroidView", systemImage: "iphone.gen3") {
            MenuBarContent().environment(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.startSession()
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info(.app, "DroidView encerrando")
        MainActor.assumeIsolated {
            for s in AppModel.shared.sessions { s.stop() }
        }
        LocalNetworkBridge.disconnectAll(using: .shared)
    }
}

struct DeviceCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Mostrar logs do DroidView") {
                Log.info(.ui, "Logs abertos no Finder")
                NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
            }
        }
        CommandMenu("Dispositivo") {
            let s = app.activeSession
            Button("Voltar") { s?.back() }.keyboardShortcut("b").disabled(s == nil)
            Button("Início") { s?.home() }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(s == nil)
            Button("Apps recentes") { s?.recents() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(s == nil)
            Button("Notificações") { s?.expandNotifications() }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(s == nil)
            Divider()
            Button("Volume +") { s?.volumeUp() }.keyboardShortcut(.upArrow).disabled(s == nil)
            Button("Volume −") { s?.volumeDown() }.keyboardShortcut(.downArrow).disabled(s == nil)
            Button("Power") { s?.power() }.keyboardShortcut("p").disabled(s == nil)
            Button("Girar") { s?.rotate() }.keyboardShortcut(.rightArrow).disabled(s == nil)
            Button(s?.isScreenOff == true ? "Religar tela do aparelho" : "Apagar tela do aparelho") {
                if let s { s.setScreenOff(!s.isScreenOff) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(s == nil)
            Divider()
            Button("Screenshot") { s?.takeScreenshot() }.keyboardShortcut("s").disabled(s == nil)
            Button(s?.isRecording == true ? "Parar gravação" : "Gravar tela") { s?.toggleRecording() }
                .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(s == nil)
            Divider()
            Button("Ajustar janela à tela") { if let s { app.controller(for: s)?.fitToScreen() } }
                .keyboardShortcut("0").disabled(s == nil)
            Button("Pixel a pixel (1:1)") { if let s { app.controller(for: s)?.pixelPerfect() } }
                .keyboardShortcut("1").disabled(s == nil)
            Button(app.settings.showControlBar ? "Ocultar barra de controles" : "Mostrar barra de controles") {
                app.settings.showControlBar.toggle()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Logcat") { if let s { app.openLogcat(serial: s.serial, title: s.title) } }
                .keyboardShortcut("l", modifiers: [.command, .shift]).disabled(s == nil)
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let online = app.devices.visibleDevices.filter(\.isOnline)
        if online.isEmpty {
            Text("Nenhum dispositivo conectado")
        }
        ForEach(online) { d in
            Button {
                app.openMirror(d)
            } label: {
                Label("\(d.displayName) — \(d.stateDescription)", systemImage: d.isWireless ? "wifi" : "cable.connector")
            }
        }
        Divider()
        Button("Abrir DroidView") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink { Text("Ajustes…") }
        Divider()
        Button("Encerrar DroidView") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
