import Foundation

/// Presets de imagem. O padrão é sempre a melhor qualidade possível;
/// os outros existem para redes Wi‑Fi fracas.
enum QualityPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case maximum, high, balanced, saver, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maximum: "Máxima"
        case .high: "Alta"
        case .balanced: "Equilibrada"
        case .saver: "Economia"
        case .custom: "Personalizada"
        }
    }

    var subtitle: String {
        switch self {
        case .maximum: "Resolução nativa · 40 Mbps · fps máximo do aparelho"
        case .high: "Até 1920 px · 20 Mbps · 60 fps"
        case .balanced: "Até 1600 px · 10 Mbps · 60 fps"
        case .saver: "Até 1280 px · 4 Mbps · 30 fps"
        case .custom: "Valores definidos manualmente"
        }
    }

    /// (maxSize, bitrate em Mbps, maxFps) — 0 = sem limite.
    var values: (maxSize: Int, bitrateMbps: Int, maxFps: Int)? {
        switch self {
        case .maximum: (0, 40, 0)
        case .high: (1920, 20, 60)
        case .balanced: (1600, 10, 60)
        case .saver: (1280, 4, 30)
        case .custom: nil
        }
    }
}

enum CodecPreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic, h265, h264
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automático (H.265 → H.264)"
        case .h265: "H.265 (HEVC)"
        case .h264: "H.264 (AVC)"
        }
    }
}

struct MirrorSettings: Codable, Equatable, Sendable {
    var usbPreset: QualityPreset = .maximum
    var wifiPreset: QualityPreset = .maximum
    var codec: CodecPreference = .automatic
    var customMaxSize: Int = 0
    var customBitrateMbps: Int = 24
    var customMaxFps: Int = 0
    var stayAwake = true
    var turnScreenOffOnStart = false
    var powerOffOnClose = false
    var showTouchesWhileMirroring = false
    var clipboardSync = true
    var alwaysOnTop = false
    var autoReconnect = true
    var autoConnectKnownWireless = true
    var screenshotFolder: String = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.path
    var recordingFolder: String = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.path

    func resolved(preset: QualityPreset) -> (maxSize: Int, bitrate: Int, maxFps: Int) {
        if let v = preset.values { return (v.maxSize, v.bitrateMbps * 1_000_000, v.maxFps) }
        return (customMaxSize, customBitrateMbps * 1_000_000, customMaxFps)
    }

    // MARK: Persistência

    private static let key = "MirrorSettings.v1"

    /// Mescla o que foi salvo sobre os valores padrão: campos novos ganham o
    /// padrão em vez de descartar todos os ajustes do usuário.
    static func load() -> MirrorSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(MirrorSettings()),
              var merged = (try? JSONSerialization.jsonObject(with: defaultsData)) as? [String: Any] else {
            return MirrorSettings()
        }
        merged.merge(stored) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              var s = try? JSONDecoder().decode(MirrorSettings.self, from: mergedData) else { return MirrorSettings() }
        // Padrão antigo (~/Movies/DroidView) → Mesa, que é o padrão atual.
        let oldDefault = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!.appendingPathComponent("DroidView").path
        if s.recordingFolder == oldDefault { s.recordingFolder = MirrorSettings().recordingFolder }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
