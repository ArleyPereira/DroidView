import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let devices = DeviceManager()
    var settings = MirrorSettings.load() {
        didSet {
            settings.save()
            if oldValue.showControlBar != settings.showControlBar { applyControlBarVisibility() }
            if oldValue.showTouchesWhileMirroring != settings.showTouchesWhileMirroring {
                for s in sessions where s.state == .running { s.applyShowTouches(settings.showTouchesWhileMirroring) }
            }
        }
    }
    /// Sessão da janela de espelhamento em foco (alvo dos comandos de menu).
    var activeSession: MirrorSession?

    @ObservationIgnored private var mirrorWindows: [String: MirrorWindowController] = [:]
    @ObservationIgnored private var logcatWindows: [String: NSWindowController] = [:]

    private init() {
        devices.settings = { [unowned self] in self.settings }
        devices.isSerialInUse = { [unowned self] serial in
            self.sessions.contains { $0.serial == serial && $0.state != .stopped }
        }
    }

    func start() {
        devices.start()
    }

    func session(for device: AndroidDevice) -> MirrorSession? {
        mirrorWindows[device.hardwareSerial]?.session
    }

    var sessions: [MirrorSession] { mirrorWindows.values.map(\.session) }

    func openMirror(_ device: AndroidDevice) {
        let key = device.hardwareSerial
        if let existing = mirrorWindows[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            if case .failed = existing.session.state { existing.session.retry() }
            if existing.session.state == .stopped { existing.session.retry() }
            return
        }
        let session = MirrorSession(serial: device.serial, hardwareSerial: key, title: device.displayName, isWireless: device.isWireless)
        session.settings = { [unowned self] in self.settings }
        session.resolveSerial = { [weak self] hw in self?.devices.currentSerial(forHardware: hw) }
        let controller = MirrorWindowController(session: session, app: self)
        controller.onClose = { [weak self] in
            self?.mirrorWindows[key] = nil
            if self?.activeSession === session { self?.activeSession = nil }
        }
        mirrorWindows[key] = controller
        controller.showWindow(nil)
        session.start()
    }

    func openLogcat(serial: String, title: String) {
        if let existing = logcatWindows[serial] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let model = LogcatModel(serial: serial, title: title)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Logcat — \(title)"
        window.contentViewController = NSHostingController(rootView: LogcatView(model: model))
        window.setContentSize(NSSize(width: 1100, height: 680))
        window.center()
        window.setFrameAutosaveName("Logcat")
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        logcatWindows[serial] = controller
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                model.stop()
                self?.logcatWindows[serial] = nil
            }
        }
        controller.showWindow(nil)
        model.start()
    }

    func applyAlwaysOnTop() {
        for c in mirrorWindows.values {
            c.window?.level = settings.alwaysOnTop ? .floating : .normal
            c.positionPanel()
        }
    }

    func applyControlBarVisibility() {
        for c in mirrorWindows.values { c.setControlBarVisible(settings.showControlBar) }
    }

    func controller(for session: MirrorSession) -> MirrorWindowController? {
        mirrorWindows[session.hardwareSerial]
    }
}
