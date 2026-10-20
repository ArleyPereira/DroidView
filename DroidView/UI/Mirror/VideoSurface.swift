import AppKit
import AVFoundation
import SwiftUI

struct VideoSurface: NSViewRepresentable {
    let session: MirrorSession

    func makeNSView(context: Context) -> VideoInputView {
        let v = VideoInputView(session: session)
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ nsView: VideoInputView, context: Context) {}
}

/// NSView que hospeda o layer de vídeo e traduz mouse/trackpad/teclado
/// em eventos Android.
final class VideoInputView: NSView {
    let session: MirrorSession
    private var pinchCenter: CGPoint?
    private var pinchDistance: CGFloat = 0
    private var keycodesDown: Set<UInt16> = []
    private var mouseIsDown = false

    init(session: MirrorSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        let video = session.renderer.layer
        video.frame = bounds
        video.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(video)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        session.renderer.layer.frame = bounds
        CATransaction.commit()
    }

    // MARK: Coordenadas

    private var videoRect: CGRect {
        let size = session.videoSize
        guard size.width > 0 else { return bounds }
        return AVMakeRect(aspectRatio: size, insideRect: bounds)
    }

    /// Ponto da view → pixel do vídeo (o servidor converte para a tela real).
    private func devicePoint(_ event: NSEvent, clamp: Bool = true) -> CGPoint? {
        let p = convert(event.locationInWindow, from: nil)
        let r = videoRect
        guard r.width > 0, r.height > 0 else { return nil }
        if !clamp, !r.contains(p) { return nil }
        let x = min(max(p.x - r.minX, 0), r.width - 1) / r.width * session.videoSize.width
        let y = min(max(p.y - r.minY, 0), r.height - 1) / r.height * session.videoSize.height
        return CGPoint(x: x, y: y)
    }

    // MARK: Mouse → toque

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let p = devicePoint(event, clamp: false) else { return }
        mouseIsDown = true
        session.touch(.down, at: p)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseIsDown, let p = devicePoint(event) else { return }
        session.touch(.move, at: p)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseIsDown else { return }
        mouseIsDown = false
        if let p = devicePoint(event) { session.touch(.up, at: p) }
    }

    override func rightMouseDown(with event: NSEvent) { session.back() }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { session.home() }
        else if event.buttonNumber == 3 { session.back() }
        else if event.buttonNumber == 4 { session.recents() }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let p = devicePoint(event, clamp: false) else { return }
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            dx /= 24
            dy /= 24
        }
        if dx == 0 && dy == 0 { return }
        session.scroll(at: p, dx: -dx, dy: dy)
    }

    /// Pinça no trackpad → gesto de dois dedos (zoom) no Android.
    override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            guard let c = devicePoint(event, clamp: false) else { return }
            pinchCenter = c
            pinchDistance = min(session.videoSize.width, session.videoSize.height) * 0.12
            sendPinch(.down)
        case .changed:
            guard pinchCenter != nil else { return }
            let maxD = min(session.videoSize.width, session.videoSize.height) * 0.48
            pinchDistance = min(max(pinchDistance * (1 + event.magnification), 8), maxD)
            sendPinch(.move)
        case .ended, .cancelled:
            guard pinchCenter != nil else { return }
            sendPinch(.up)
            pinchCenter = nil
        default: break
        }
    }

    private func sendPinch(_ action: MotionAction) {
        guard let c = pinchCenter else { return }
        let a = CGPoint(x: c.x - pinchDistance, y: c.y)
        let b = CGPoint(x: c.x + pinchDistance, y: c.y)
        session.touch(action, at: a, pointerID: ControlMessage.pointerFinger)
        session.touch(action, at: b, pointerID: ControlMessage.pointerVirtualFinger)
    }

    // MARK: Teclado

    /// ⌘V/⌘C/⌘X/⌘A agem no aparelho quando o vídeo tem o foco.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command, let ch = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        if session.pendingScreenshot != nil {
            if ch == "c" { session.copyPendingScreenshot(); return true }
            if ch == "s" { session.savePendingScreenshot(in: window); return true }
            return super.performKeyEquivalent(with: event)
        }
        switch ch {
        case "v": session.pasteFromMac(); return true
        case "c": session.copyFromDevice(); return true
        case "x": session.copyFromDevice(cut: true); return true
        case "a": session.press(29, meta: AndroidKey.metaCtrl); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if session.pendingScreenshot != nil {
            switch event.keyCode {
            case 53: session.dismissPendingScreenshot()            // Esc
            case 36, 76: session.savePendingScreenshot(in: window)  // Return
            default: break
            }
            return
        }
        if event.keyCode == 53 { // Esc → voltar
            if !event.isARepeat { session.back() }
            return
        }
        let ctrl = mods.contains(.control)
        if !ctrl, let chars = event.characters, isPrintable(chars), !isNavigationKey(event.keyCode) {
            session.type(chars)
            return
        }
        guard let code = AndroidKey.fromMac(keyCode: event.keyCode) else { return }
        keycodesDown.insert(event.keyCode)
        session.key(.down, keycode: code, repeatCount: event.isARepeat ? 1 : 0, meta: metaState(mods))
    }

    override func keyUp(with event: NSEvent) {
        guard keycodesDown.remove(event.keyCode) != nil, let code = AndroidKey.fromMac(keyCode: event.keyCode) else { return }
        session.key(.up, keycode: code, meta: metaState(event.modifierFlags))
    }

    private func isNavigationKey(_ keyCode: UInt16) -> Bool {
        [36, 76, 48, 51, 117, 123, 124, 125, 126, 115, 119, 116, 121].contains(keyCode)
    }

    private func isPrintable(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { u in
            u.value >= 0x20 && u.value != 0x7F && !(0xF700...0xF8FF).contains(u.value)
        }
    }

    private func metaState(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.shift) { m |= AndroidKey.metaShift }
        if flags.contains(.control) { m |= AndroidKey.metaCtrl }
        if flags.contains(.option) { m |= AndroidKey.metaAlt }
        return m
    }

    // MARK: Arrastar e soltar (APK / arquivos)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        FileTransfer.send(urls, to: session)
        return true
    }
}

@MainActor
enum FileTransfer {
    /// `.apk` é instalado; qualquer outro arquivo vai para /sdcard/Download.
    static func send(_ urls: [URL], to session: MirrorSession) {
        let serial = session.serial
        for url in urls {
            let isAPK = url.pathExtension.lowercased() == "apk"
            session.toast = Toast(icon: isAPK ? "shippingbox" : "arrow.up.doc",
                                  message: isAPK ? "Instalando \(url.lastPathComponent)…" : "Enviando \(url.lastPathComponent)…")
            Task.detached {
                do {
                    if isAPK {
                        _ = try ADBClient.shared.install(serial: serial, apk: url)
                    } else {
                        let remote = "/sdcard/Download/\(url.lastPathComponent)"
                        try ADBClient.shared.push(serial: serial, file: url, to: remote)
                        _ = try? ADBClient.shared.shell(serial: serial, "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(DevTools.shellQuote("file://" + remote))")
                    }
                    await MainActor.run {
                        session.toast = Toast(icon: "checkmark.circle",
                                              message: isAPK ? "\(url.lastPathComponent) instalado" : "Enviado para Download/")
                    }
                } catch {
                    await MainActor.run {
                        session.toast = Toast(icon: "xmark.octagon", message: error.localizedDescription)
                    }
                }
            }
        }
    }
}
