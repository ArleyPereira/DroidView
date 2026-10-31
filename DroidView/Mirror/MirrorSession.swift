import AppKit
import UniformTypeIdentifiers
import CoreMedia
import Observation

/// Screenshot em prévia. Nasce com o frame do vídeo (instantâneo) e é trocado
/// pelo PNG sem perdas do `screencap` quando ele chega, mantendo o mesmo `id`.
struct CapturedScreenshot: Identifiable, Equatable {
    let id: UUID
    let image: NSImage
    let suggestedName: String
    /// PNG pronto (sem perdas). `nil` enquanto só temos o frame do stream.
    let data: Data?
    var isLossless: Bool { data != nil }
    /// O `screencap` ainda está a caminho.
    var isUpgrading: Bool

    var pixelSize: CGSize {
        guard let rep = image.representations.first else { return image.size }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// PNG para copiar/salvar: o sem perdas se já chegou, senão o frame codificado.
    func pngData() -> Data? {
        if let data { return data }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.isLossless == b.isLossless && a.isUpgrading == b.isUpgrading
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let icon: String
    let message: String
    var fileURL: URL?
}

/// Uma sessão de espelhamento: servidor no Android + streams de vídeo/áudio/controle.
/// Sobrevive a quedas de conexão: quando o aparelho volta (USB ou Wi‑Fi, mesmo
/// com outro IP/porta), a sessão se reconecta sozinha na mesma janela.
@MainActor
@Observable
final class MirrorSession: Identifiable {
    enum State: Equatable {
        case connecting(String)
        case running
        case reconnecting(String)
        case failed(String)
        case stopped

        var isActive: Bool { self == .running }
    }

    let id = UUID()
    /// `ro.serialno`: identidade estável do aparelho, independente do transporte.
    let hardwareSerial: String
    private(set) var serial: String
    private(set) var title: String
    private(set) var isWireless: Bool

    private(set) var state: State = .connecting("Preparando…")
    private(set) var videoSize: CGSize = .zero
    private(set) var fps: Int = 0
    private(set) var codecInUse: VideoCodec?
    private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?
    private(set) var isScreenOff = false
    var toast: Toast?
    var pendingScreenshot: CapturedScreenshot?
    private(set) var serverLog: [String] = []

    @ObservationIgnored let renderer = VideoRenderer()
    @ObservationIgnored var resolveSerial: ((String) -> (serial: String, wireless: Bool)?)?
    @ObservationIgnored var settings: () -> MirrorSettings = { .load() }

    @ObservationIgnored private var server: ScrcpyServer?
    @ObservationIgnored private var streams: ScrcpyStreams?
    @ObservationIgnored private var control: ControlChannel?
    @ObservationIgnored private var decoder: VideoDecoder?
    @ObservationIgnored private var recorder: ScreenRecorder?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var userStopped = false
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var fpsTimer: Timer?
    @ObservationIgnored private let frameCounter = FrameCounter()
    @ObservationIgnored private var codecOverride: VideoCodec?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var clipboardSequence: UInt64 = 1
    @ObservationIgnored private var lastClipboardFromDevice: String?
    @ObservationIgnored private var recordingPart = 1

    init(serial: String, hardwareSerial: String, title: String, isWireless: Bool) {
        self.serial = serial
        self.hardwareSerial = hardwareSerial
        self.title = title
        self.isWireless = isWireless
    }

    // MARK: Ciclo de vida

    func start() {
        userStopped = false
        reconnectTask?.cancel()
        reconnectTask = nil
        generation += 1
        let gen = generation
        let settings = settings()
        let preset = isWireless ? settings.wifiPreset : settings.usbPreset
        let q = settings.resolved(preset: preset)
        let codec: VideoCodec = codecOverride ?? (settings.codec == .h264 ? .h264 : .h265)
        let options = ScrcpyLaunchOptions(
            codec: codec, maxSize: q.maxSize, bitrate: q.bitrate, maxFps: q.maxFps,
            stayAwake: settings.stayAwake,
            powerOffOnClose: settings.powerOffOnClose,
            clipboardAutosync: settings.clipboardSync)
        let server = ScrcpyServer(serial: serial)
        server.onLog = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        self.server = server
        state = .connecting("Iniciando servidor no dispositivo…")

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let streams = try server.start(options)
                await self?.attach(streams, server: server, codecRequested: codec, generation: gen)
            } catch {
                await self?.startFailed(error, codecRequested: codec, generation: gen)
            }
        }
    }

    func stop() {
        userStopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        generation += 1
        if isRecording { toggleRecording() }
        teardown()
        restoreShowTouches()
        state = .stopped
    }

    // MARK: Mostrar toques

    /// Valor de `show_touches` do aparelho antes do espelhamento (restaurado ao fechar).
    @ObservationIgnored private var originalShowTouches: String?

    /// Aplica "mostrar toques" na hora, sem reiniciar o espelhamento. Controlado pelo
    /// app (e não pelo scrcpy-server, que só lê a opção ao iniciar).
    func applyShowTouches(_ on: Bool) {
        let serial = self.serial
        let needsOriginal = originalShowTouches == nil
        Task.detached { [weak self] in
            let adb = ADBClient.shared
            if needsOriginal {
                let original = (try? adb.shell(serial: serial, "settings get system show_touches"))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
                await MainActor.run { if self?.originalShowTouches == nil { self?.originalShowTouches = original } }
            }
            _ = try? adb.shell(serial: serial, "settings put system show_touches \(on ? 1 : 0)")
        }
    }

    /// Devolve o valor original ao fechar (síncrono: precisa terminar antes do app sair).
    private func restoreShowTouches() {
        guard let original = originalShowTouches else { return }
        originalShowTouches = nil
        _ = try? ADBClient.shared.shell(serial: serial, "settings put system show_touches \(original == "1" ? 1 : 0)")
    }

    func retry() {
        failures = 0
        if let resolved = resolveSerial?(hardwareSerial) {
            serial = resolved.serial
            isWireless = resolved.wireless
        }
        start()
    }

    private func attach(_ streams: ScrcpyStreams, server: ScrcpyServer, codecRequested: VideoCodec, generation gen: Int) {
        guard gen == generation else {
            streams.video.close(); streams.control.close(); server.stop()
            return
        }
        self.streams = streams
        if !streams.deviceName.isEmpty { title = streams.deviceName }
        state = .connecting("Recebendo vídeo…")

        let control = ControlChannel(socket: streams.control)
        control.onClipboard = { [weak self] text in
            Task { @MainActor in self?.deviceClipboardChanged(text) }
        }
        control.start()
        self.control = control

        startVideoThread(socket: streams.video, codecRequested: codecRequested, generation: gen)
        startFPSTimer()
        if settings().turnScreenOffOnStart { setScreenOff(true) }
        // Reaplica a cada (re)conexão; só mexe no aparelho se a opção estiver ligada
        // ou se já tivermos mudado o valor nesta sessão.
        if settings().showTouchesWhileMirroring || originalShowTouches != nil {
            applyShowTouches(settings().showTouchesWhileMirroring)
        }
    }

    private func startFailed(_ error: Error, codecRequested: VideoCodec, generation gen: Int) {
        guard gen == generation else { return }
        let message = error.localizedDescription
        appendLog("Erro: \(message)")
        teardown()
        if settings().codec == .automatic, codecRequested == .h265, codecOverride == nil {
            appendLog("H.265 indisponível, tentando H.264…")
            codecOverride = .h264
            start()
            return
        }
        scheduleReconnect(reason: message)
    }

    private func streamEnded(generation gen: Int, receivedFrames: Bool) {
        guard gen == generation, !userStopped else { return }
        if !receivedFrames, settings().codec == .automatic, codecInUse != .h264, codecOverride == nil {
            appendLog("Nenhum frame com H.265, tentando H.264…")
            codecOverride = .h264
            teardown()
            start()
            return
        }
        if isRecording { toggleRecording() }
        teardown()
        scheduleReconnect(reason: "Conexão com o dispositivo perdida")
    }

    private func scheduleReconnect(reason: String) {
        guard !userStopped else { return }
        failures += 1
        guard settings().autoReconnect, failures <= 30 else {
            state = .failed(reason)
            return
        }
        state = .reconnecting(reason)
        let myGeneration = generation
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            let delay = min(1.0 * Double(self?.failures ?? 1), 5.0)
            try? await Task.sleep(for: .seconds(delay))
            while !Task.isCancelled {
                guard let self, self.generation == myGeneration, !self.userStopped else { return }
                if let resolved = self.resolveSerial?(self.hardwareSerial) {
                    self.serial = resolved.serial
                    self.isWireless = resolved.wireless
                    self.start()
                    return
                }
                self.state = .reconnecting("Aguardando o dispositivo voltar…")
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func teardown() {
        fpsTimer?.invalidate()
        fpsTimer = nil
        control?.close()
        control = nil
        streams?.video.close()
        streams?.control.close()
        streams = nil
        server?.stop()
        server = nil
        decoder?.onFrame = nil
        decoder?.onEncodedFrame = nil
        decoder = nil
        fps = 0
    }

    private func appendLog(_ line: String) {
        serverLog.append(line)
        if serverLog.count > 300 { serverLog.removeFirst(100) }
    }

    // MARK: Streams

    private func startVideoThread(socket: TCPSocket, codecRequested: VideoCodec, generation gen: Int) {
        let renderer = self.renderer
        let counter = frameCounter
        let thread = Thread { [weak self] in
            var receivedFrames = false
            defer {
                let got = receivedFrames
                Task { @MainActor in self?.streamEnded(generation: gen, receivedFrames: got) }
            }
            do {
                let codecID = try socket.readUInt32BE()
                guard let codec = VideoCodec(scrcpyCodecID: codecID) else {
                    throw ADBError(message: codecID == 0 ? "Vídeo desativado pelo dispositivo" : "Erro de configuração do vídeo (\(codecID))")
                }
                let decoder = VideoDecoder(codec: codec)
                decoder.onFrame = { pixelBuffer, _ in
                    renderer.display(pixelBuffer)
                    counter.tick()
                    if !receivedFrames {
                        receivedFrames = true
                        Task { @MainActor in self?.firstFrameArrived() }
                    }
                }
                decoder.onEncodedFrame = { frame in
                    self?.recorderBox.recorder?.append(video: frame)
                }
                decoder.onFormatChange = { format in
                    Task { @MainActor in self?.videoFormatChanged(format) }
                }
                Task { @MainActor in
                    guard let self, gen == self.generation else { return }
                    self.decoder = decoder
                    self.codecInUse = codec
                }

                var header = Data(count: 12)
                while true {
                    try header.withUnsafeMutableBytes { try socket.readFully(into: $0.baseAddress!, count: 12) }
                    if header[0] & 0x80 != 0 {
                        let w = Int(header.uint32BE(at: 4)), h = Int(header.uint32BE(at: 8))
                        Task { @MainActor in
                            guard let self, gen == self.generation else { return }
                            self.videoSize = CGSize(width: w, height: h)
                        }
                        continue
                    }
                    let ptsFlags = header.uint64BE(at: 0)
                    let length = Int(header.uint32BE(at: 8))
                    guard length > 0 else { throw ADBError(message: "Pacote inválido") }
                    let packet = try socket.read(exactly: length)
                    let isConfig = ptsFlags & (1 << 62) != 0
                    let isKey = ptsFlags & (1 << 61) != 0
                    let pts = Int64(ptsFlags & ((1 << 61) - 1))
                    decoder.handle(packet: packet, isConfig: isConfig, isKeyFrame: isKey, pts: pts)
                }
            } catch {
                // fim do stream
            }
        }
        thread.name = "droidview.video"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Acesso ao gravador a partir das threads de stream.
    @ObservationIgnored nonisolated let recorderBox = RecorderBox()

    private func firstFrameArrived() {
        state = .running
        failures = 0
        if videoSize == .zero { videoSize = renderer.frameSize }
    }

    private func videoFormatChanged(_ format: CMVideoFormatDescription) {
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        if dims.width > 0 { videoSize = CGSize(width: Int(dims.width), height: Int(dims.height)) }
        // Rotação durante a gravação: fecha o arquivo atual e abre uma nova parte.
        if isRecording, let current = recorderBox.recorder {
            recorderBox.recorder = nil
            Task {
                _ = await current.finish()
                await MainActor.run {
                    self.recordingPart += 1
                    self.beginRecorder(format: format)
                }
            }
        }
    }

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.fps = self.frameCounter.takeCount()
            }
        }
    }

    // MARK: Entrada

    func touch(_ action: MotionAction, at point: CGPoint, pointerID: UInt64 = ControlMessage.pointerFinger, pressure: Float? = nil) {
        guard let control, videoSize.width > 0 else { return }
        control.send(.injectTouch(
            action: action, pointerID: pointerID,
            x: Int32(point.x.rounded()), y: Int32(point.y.rounded()),
            width: UInt16(videoSize.width), height: UInt16(videoSize.height),
            pressure: pressure ?? (action == .up ? 0 : 1)))
    }

    func scroll(at point: CGPoint, dx: CGFloat, dy: CGFloat) {
        guard let control, videoSize.width > 0 else { return }
        control.send(.injectScroll(
            x: Int32(point.x), y: Int32(point.y),
            width: UInt16(videoSize.width), height: UInt16(videoSize.height),
            hScroll: Float(dx), vScroll: Float(dy)))
    }

    func key(_ action: KeyAction, keycode: UInt32, repeatCount: UInt32 = 0, meta: UInt32 = 0) {
        control?.send(.injectKeycode(action: action, keycode: keycode, repeatCount: repeatCount, metaState: meta))
    }

    func press(_ keycode: UInt32, meta: UInt32 = 0) {
        key(.down, keycode: keycode, meta: meta)
        key(.up, keycode: keycode, meta: meta)
    }

    func type(_ text: String) {
        guard !text.isEmpty else { return }
        control?.send(.injectText(text))
    }

    func back() {
        control?.send(.backOrScreenOn(.down))
        control?.send(.backOrScreenOn(.up))
    }

    func home() { press(AndroidKey.home) }
    func recents() { press(AndroidKey.appSwitch) }
    func power() { press(AndroidKey.power) }
    func volumeUp() { press(AndroidKey.volumeUp) }
    func volumeDown() { press(AndroidKey.volumeDown) }
    func rotate() { control?.send(.rotateDevice) }
    func expandNotifications() { control?.send(.expandNotificationPanel) }
    func collapsePanels() { control?.send(.collapsePanels) }

    func setScreenOff(_ off: Bool) {
        control?.send(.setDisplayPower(!off))
        isScreenOff = off
    }

    /// Cola no Android o conteúdo do clipboard do Mac.
    func pasteFromMac() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        clipboardSequence += 1
        lastClipboardFromDevice = text
        control?.send(.setClipboard(sequence: clipboardSequence, text: text, paste: true))
    }

    /// Copia (Cmd+C) no Android: o dispositivo devolve o texto pelo canal de clipboard.
    func copyFromDevice(cut: Bool = false) {
        control?.send(.getClipboard(copyKey: cut ? 2 : 1))
    }

    private func deviceClipboardChanged(_ text: String) {
        guard settings().clipboardSync, text != lastClipboardFromDevice else { return }
        lastClipboardFromDevice = text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Screenshot

    func takeScreenshot() {
        let serial = self.serial
        let name = "\(fileBaseName()).png"
        let id = UUID()

        // 1) Prévia instantânea com o frame atual do vídeo.
        if let cg = renderer.snapshot() {
            NSSound(named: "Grab")?.play()
            pendingScreenshot = CapturedScreenshot(id: id, image: NSImage(cgImage: cg, size: .zero),
                                                   suggestedName: name, data: nil, isUpgrading: true)
        }

        // 2) PNG sem perdas na resolução nativa via screencap.
        Task.detached(priority: .userInitiated) {
            var png: Data? = try? ADBClient.shared.exec(serial: serial, "screencap -p")
            if let d = png, !d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { png = nil }
            let image = png.flatMap { NSImage(data: $0) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let png, let image {
                    if self.pendingScreenshot == nil {
                        NSSound(named: "Grab")?.play()
                    } else if self.pendingScreenshot?.id != id {
                        return // fechado e outro screenshot já foi aberto
                    }
                    self.pendingScreenshot = CapturedScreenshot(id: id, image: image, suggestedName: name,
                                                                data: png, isUpgrading: false)
                } else if let current = self.pendingScreenshot, current.id == id {
                    // Sem screencap: segue com o frame do vídeo.
                    self.pendingScreenshot = CapturedScreenshot(id: id, image: current.image, suggestedName: name,
                                                                data: nil, isUpgrading: false)
                } else if self.pendingScreenshot == nil {
                    self.toast = Toast(icon: "exclamationmark.triangle", message: "Não foi possível capturar a tela")
                }
            }
        }
    }

    // MARK: Prévia do screenshot (copiar / salvar / cancelar)

    func copyPendingScreenshot() {
        guard let shot = pendingScreenshot else { return }
        NSPasteboard.general.clearContents()
        if let png = shot.data {
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            NSPasteboard.general.writeObjects([item, shot.image])
        } else {
            NSPasteboard.general.writeObjects([shot.image])
        }
        pendingScreenshot = nil
        toast = Toast(icon: "doc.on.doc", message: "Screenshot copiado")
    }

    /// Abre o painel nativo de salvar. Não usa sheet: a janela do espelhamento é
    /// estreita (retrato) e o painel expandido ficaria cortado.
    func savePendingScreenshot(in window: NSWindow?) {
        guard let shot = pendingScreenshot else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = shot.suggestedName
        panel.canCreateDirectories = true
        let lastFolder = UserDefaults.standard.string(forKey: "LastScreenshotFolder") ?? settings().screenshotFolder
        panel.directoryURL = URL(fileURLWithPath: lastFolder, isDirectory: true)

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            // Se o PNG sem perdas chegou enquanto o painel estava aberto, salva ele.
            let latest = self.pendingScreenshot?.id == shot.id ? self.pendingScreenshot! : shot
            guard let png = latest.pngData() else { return }
            do {
                try png.write(to: url)
                UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "LastScreenshotFolder")
                self.pendingScreenshot = nil
                self.toast = Toast(icon: "checkmark.circle", message: "Screenshot salvo", fileURL: url)
            } catch {
                self.toast = Toast(icon: "xmark.octagon", message: error.localizedDescription)
            }
        }
        if let window, let screen = window.screen {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                         y: screen.visibleFrame.midY - panel.frame.height / 2))
        }
        panel.level = .modalPanel
        panel.begin(completionHandler: finish)
    }

    func dismissPendingScreenshot() {
        pendingScreenshot = nil
    }

    // MARK: Gravação

    func toggleRecording() {
        if isRecording {
            isRecording = false
            recordingStartedAt = nil
            guard let recorder = recorderBox.recorder else { return }
            recorderBox.recorder = nil
            Task {
                let url = await recorder.finish()
                await MainActor.run {
                    self.toast = url.map { Toast(icon: "record.circle", message: "Gravação salva", fileURL: $0) }
                        ?? Toast(icon: "exclamationmark.triangle", message: "A gravação não pôde ser salva")
                }
            }
        } else {
            guard let format = decoder?.formatDescription else {
                toast = Toast(icon: "exclamationmark.triangle", message: "Aguarde o vídeo iniciar para gravar")
                return
            }
            recordingPart = 1
            isRecording = true
            recordingStartedAt = .now
            beginRecorder(format: format)
        }
    }

    private func beginRecorder(format: CMVideoFormatDescription) {
        guard isRecording else { return }
        let settings = settings()
        let folder = URL(fileURLWithPath: settings.recordingFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suffix = recordingPart > 1 ? " (parte \(recordingPart))" : ""
        let url = folder.appendingPathComponent("\(fileBaseName())\(suffix).mp4")
        do {
            recorderBox.recorder = try ScreenRecorder(url: url, format: format)
            control?.send(.resetVideo) // força um keyframe imediato
        } catch {
            isRecording = false
            recordingStartedAt = nil
            toast = Toast(icon: "exclamationmark.triangle", message: "Falha ao iniciar gravação: \(error.localizedDescription)")
        }
    }

    private func fileBaseName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
        return "\(safeTitle) \(f.string(from: .now))"
    }
}

final class RecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _recorder: ScreenRecorder?
    var recorder: ScreenRecorder? {
        get { lock.lock(); defer { lock.unlock() }; return _recorder }
        set { lock.lock(); _recorder = newValue; lock.unlock() }
    }
}

final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func tick() { lock.lock(); count += 1; lock.unlock() }
    func takeCount() -> Int { lock.lock(); defer { count = 0; lock.unlock() }; return count }
}
