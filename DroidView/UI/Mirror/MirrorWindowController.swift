import AppKit
import SwiftUI

/// Painel de controles flutuante: janela-filha sem borda, transparente, que
/// acompanha a janela do espelhamento. Nunca vira janela-chave, então o teclado
/// continua indo para o aparelho.
final class ControlPanel: NSPanel {
    /// Margem transparente ao redor da cápsula (espaço para a sombra do vidro).
    static let shadowInset: CGFloat = 14
    /// Distância visual entre a janela e a cápsula.
    static let gap: CGFloat = 10

    init<Content: View>(rootView: Content) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.fullScreenNone, .managed]
        let hosting = FirstMouseHostingView(rootView: rootView)
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Largura visível da cápsula (sem a margem da sombra).
    var capsuleWidth: CGFloat { frame.width - 2 * Self.shadowInset }

    func fitContent() {
        guard let size = contentView?.fittingSize, size != frame.size else { return }
        setContentSize(size)
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Janela de espelhamento em AppKit puro: precisamos do delegate para manter a
/// proporção exata da tela do aparelho. Os controles ficam no `ControlPanel` ao lado.
@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    /// Espaço horizontal que o painel ocupa ao lado da janela (para caber na tela).
    static let panelReserve: CGFloat = 60 + ControlPanel.gap
    private var panelReserve: CGFloat { app?.settings.showControlBar == false ? 0 : Self.panelReserve }

    let session: MirrorSession
    var onClose: (() -> Void)?
    private weak var app: AppModel?
    private var lastVideoSize: CGSize = .zero
    private var panel: ControlPanel?
    private var isEnforcingAspect = false
    private var enforceWork: DispatchWorkItem?

    init(session: MirrorSession, app: AppModel) {
        self.session = session
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = session.title
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone, .managed]
        window.backgroundColor = .black
        window.minSize = NSSize(width: 200, height: 240)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: MirrorWindowView(session: session).environment(app))
        window.center()
        window.level = app.settings.alwaysOnTop ? .floating : .normal

        let panel = ControlPanel(rootView: ControlBar(session: session).environment(app))
        self.panel = panel
        if app.settings.showControlBar { window.addChildWindow(panel, ordered: .above) }
        positionPanel()
        observe()
    }

    /// Mostra ou esconde a barra flutuante (ajuste "Mostrar barra de controles").
    func setControlBarVisible(_ visible: Bool) {
        guard let window, let panel else { return }
        if visible {
            if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
            positionPanel()
            panel.orderFront(nil)
        } else {
            window.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    /// Cola o painel à direita da janela (ou à esquerda, se não couber), centralizado na vertical.
    func positionPanel() {
        guard let window, let panel else { return }
        panel.fitContent()
        panel.level = window.level
        let inset = ControlPanel.shadowInset
        let gap = ControlPanel.gap
        let w = window.frame
        var x = w.maxX + gap - inset
        if let visible = window.screen?.visibleFrame, x + panel.frame.width - inset > visible.maxX {
            x = w.minX - gap - panel.frame.width + inset
        }
        var y = w.midY - panel.frame.height / 2
        if panel.frame.height - 2 * inset > w.height {
            y = w.maxY - panel.frame.height + inset
        }
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    func windowDidResize(_ notification: Notification) {
        positionPanel()
        // Redimensionamentos feitos pelo sistema (tiling ao soltar na borda da tela,
        // "Preencher", Mission Control) ignoram o windowWillResize: corrige depois.
        guard let window, !window.inLiveResize, !isEnforcingAspect else { return }
        scheduleEnforceAspect()
    }

    /// O tiling anima a janela em vários passos; corrige só quando ela para de mudar.
    private func scheduleEnforceAspect() {
        enforceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.enforceAspect() }
        enforceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// O tiling do sistema é animado como "live resize": corrige quando termina.
    func windowDidEndLiveResize(_ notification: Notification) {
        scheduleEnforceAspect()
    }

    /// Mantém a proporção do aparelho dentro do espaço que o sistema deu à janela:
    /// ocupa a altura disponível e a largura proporcional, presa à borda onde foi solta.
    private func enforceAspect() {
        guard let window, !window.inLiveResize, session.videoSize.width > 0 else { return }
        let frame = window.frame
        let content = window.contentRect(forFrameRect: frame).size
        guard content.height > 0, abs(content.width / content.height - aspect) > 0.01 else { return }

        var size = content
        if content.width / content.height > aspect {
            size.width = (content.height * aspect).rounded()
        } else {
            size.height = (content.width / aspect).rounded()
        }
        var target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let visible = window.screen?.visibleFrame ?? frame
        let edge: CGFloat = 4
        if abs(frame.minX - visible.minX) < edge {
            target.origin.x = frame.minX                       // solta na borda esquerda
        } else if abs(frame.maxX - visible.maxX) < edge {
            target.origin.x = frame.maxX - target.width        // solta na borda direita
        } else {
            target.origin.x = frame.midX - target.width / 2
        }
        target.origin.y = frame.maxY - target.height           // mantém o topo

        isEnforcingAspect = true
        window.setFrame(target, display: true, animate: true)
        isEnforcingAspect = false
        positionPanel()
    }

    /// Botão verde / duplo clique no título: ocupa a altura da tela mantendo a proporção.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let available = window.contentRect(forFrameRect: newFrame).size
        var size = NSSize(width: available.height * aspect, height: available.height)
        let maxW = available.width - panelReserve
        if size.width > maxW { size = NSSize(width: maxW, height: maxW / aspect) }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = min(max(window.frame.midX - frame.width / 2, newFrame.minX), newFrame.maxX - frame.width - panelReserve)
        frame.origin.y = newFrame.maxY - frame.height
        return frame
    }
    func windowDidMove(_ notification: Notification) { positionPanel() }
    func windowDidChangeScreen(_ notification: Notification) { positionPanel() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Observa a sessão (Observation) para título, subtítulo e tamanho do vídeo.
    private func observe() {
        withObservationTracking {
            _ = session.videoSize
            _ = session.fps
            _ = session.title
            _ = session.codecInUse
            _ = session.isRecording
            _ = session.isWireless
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sessionChanged()
                self?.observe()
            }
        }
    }

    private func sessionChanged() {
        guard let window else { return }
        window.title = session.isRecording ? "● \(session.title)" : session.title
        if session.videoSize.width > 0 {
            let codec = session.codecInUse.map { $0 == .h265 ? "H.265" : "H.264" } ?? ""
            let link = session.isWireless ? "Wi‑Fi" : "USB"
            window.subtitle = "\(Int(session.videoSize.width))×\(Int(session.videoSize.height)) · \(session.fps) fps · \(codec) · \(link)"
        }
        if session.videoSize != lastVideoSize, session.videoSize.width > 0 {
            let rotatedOnly = lastVideoSize != .zero
            lastVideoSize = session.videoSize
            fitToScreen(keepCenter: rotatedOnly)
        }
    }

    private var aspect: CGFloat {
        let s = session.videoSize
        return s.width > 0 && s.height > 0 ? s.width / s.height : 9.0 / 19.5
    }

    /// Ajusta a janela para caber confortavelmente na tela mantendo a proporção.
    func fitToScreen(keepCenter: Bool = true) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let maxW = visible.width * 0.85 - panelReserve
        let maxH = visible.height * 0.88 - titleBarHeight
        var h = min(maxH, maxW / aspect)
        if aspect > 1 { h = min(h, 900 / aspect) }
        let w = h * aspect
        setContentSize(NSSize(width: w, height: h), keepCenter: keepCenter)
    }

    /// Pixel a pixel: 1 pixel do aparelho = 1 pixel físico da tela do Mac.
    func pixelPerfect() {
        guard let window, session.videoSize.width > 0 else { return }
        let scale = window.backingScaleFactor
        let w = session.videoSize.width / scale
        let h = session.videoSize.height / scale
        setContentSize(NSSize(width: w, height: h), keepCenter: true)
    }

    private var titleBarHeight: CGFloat {
        guard let window else { return 28 }
        return window.frame.height - window.contentRect(forFrameRect: window.frame).height
    }

    private func setContentSize(_ size: NSSize, keepCenter: Bool) {
        guard let window else { return }
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        if keepCenter {
            frame.origin = NSPoint(x: old.midX - frame.width / 2, y: old.midY - frame.height / 2)
        } else {
            frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        }
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width - panelReserve)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: keepCenter)
    }

    // MARK: NSWindowDelegate

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Só o arraste manual passa por aqui com proporção travada. Mudanças do
        // sistema (tiling, "Preencher") e as nossas próprias passam direto; o
        // enforceAspect() encaixa depois na altura disponível.
        guard sender.inLiveResize else { return frameSize }
        let current = sender.contentRect(forFrameRect: sender.frame).size
        let target = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        var content = target
        if abs(target.width - current.width) > abs(target.height - current.height) {
            content.height = max(1, target.width) / aspect
        } else {
            content.width = target.height * aspect
        }
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }

    func windowDidBecomeKey(_ notification: Notification) {
        app?.activeSession = session
    }

    func windowWillClose(_ notification: Notification) {
        if let panel {
            window?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        session.stop()
        onClose?()
    }
}
