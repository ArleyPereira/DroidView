import Foundation

/// Opções de desenvolvedor do Android alternáveis com um clique.
enum DevToggle: String, CaseIterable, Identifiable {
    case showTouches, pointerLocation, layoutBounds, gpuOverdraw, profileGPU, darkMode, animationsOff, stayAwakeCharging

    var id: String { rawValue }

    var title: String {
        switch self {
        case .showTouches: "Mostrar toques"
        case .pointerLocation: "Local do ponteiro"
        case .layoutBounds: "Limites de layout"
        case .gpuOverdraw: "Overdraw da GPU"
        case .profileGPU: "Barras de renderização (HWUI)"
        case .darkMode: "Tema escuro"
        case .animationsOff: "Desativar animações"
        case .stayAwakeCharging: "Tela sempre ligada ao carregar"
        }
    }

    var icon: String {
        switch self {
        case .showTouches: "hand.tap"
        case .pointerLocation: "scope"
        case .layoutBounds: "square.dashed"
        case .gpuOverdraw: "square.3.layers.3d"
        case .profileGPU: "chart.bar.xaxis"
        case .darkMode: "moon"
        case .animationsOff: "figure.walk.motion.trianglebadge.exclamationmark"
        case .stayAwakeCharging: "bolt.badge.clock"
        }
    }

    /// Força o recarregamento das system properties nos apps em execução.
    private static let pokeSysProps = "service call activity 1599295570 > /dev/null 2>&1"

    var readCommand: String {
        switch self {
        case .showTouches: "settings get system show_touches"
        case .pointerLocation: "settings get system pointer_location"
        case .layoutBounds: "getprop debug.layout"
        case .gpuOverdraw: "getprop debug.hwui.overdraw"
        case .profileGPU: "getprop debug.hwui.profile"
        case .darkMode: "cmd uimode night"
        case .animationsOff: "settings get global animator_duration_scale"
        case .stayAwakeCharging: "settings get global stay_on_while_plugged_in"
        }
    }

    func isOn(_ output: String) -> Bool {
        let v = output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .showTouches, .pointerLocation: return v == "1"
        case .layoutBounds: return v == "true"
        case .gpuOverdraw: return v == "show"
        case .profileGPU: return v == "visual_bars"
        case .darkMode: return v.contains("yes")
        case .animationsOff: return v == "0" || v == "0.0"
        case .stayAwakeCharging: return v != "0" && !v.isEmpty && v != "null"
        }
    }

    func writeCommand(on: Bool) -> String {
        switch self {
        case .showTouches: return "settings put system show_touches \(on ? 1 : 0)"
        case .pointerLocation: return "settings put system pointer_location \(on ? 1 : 0)"
        case .layoutBounds: return "setprop debug.layout \(on ? "true" : "false"); \(Self.pokeSysProps)"
        case .gpuOverdraw: return "setprop debug.hwui.overdraw \(on ? "show" : "false"); \(Self.pokeSysProps)"
        case .profileGPU: return "setprop debug.hwui.profile \(on ? "visual_bars" : "false"); \(Self.pokeSysProps)"
        case .darkMode: return "cmd uimode night \(on ? "yes" : "no")"
        case .animationsOff:
            let s = on ? "0" : "1"
            return "settings put global window_animation_scale \(s); settings put global transition_animation_scale \(s); settings put global animator_duration_scale \(s)"
        case .stayAwakeCharging: return "settings put global stay_on_while_plugged_in \(on ? 7 : 0)"
        }
    }
}

enum DevTools {
    static func readToggles(serial: String) async -> [DevToggle: Bool] {
        await Task.detached {
            var result: [DevToggle: Bool] = [:]
            for t in DevToggle.allCases {
                if let out = try? ADBClient.shared.shell(serial: serial, t.readCommand) {
                    result[t] = t.isOn(out)
                }
            }
            return result
        }.value
    }

    static func set(_ toggle: DevToggle, on: Bool, serial: String) async {
        _ = await Task.detached { try? ADBClient.shared.shell(serial: serial, toggle.writeCommand(on: on)) }.value
    }

    @discardableResult
    static func run(_ command: String, serial: String) async throws -> String {
        try await Task.detached { try ADBClient.shared.shell(serial: serial, command) }.value
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func openDeepLink(_ url: String, serial: String) async throws -> String {
        try await run("am start -a android.intent.action.VIEW -d \(shellQuote(url))", serial: serial)
    }

    /// Pacote do app em primeiro plano.
    static func foregroundPackage(serial: String) async -> String? {
        guard let out = try? await run("dumpsys activity activities | grep -E 'topResumedActivity|mResumedActivity' | head -n 1", serial: serial) else { return nil }
        // ... ActivityRecord{abc u0 com.example.app/.MainActivity t12}
        guard let r = out.range(of: #"[a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+"#, options: .regularExpression) else { return nil }
        return String(out[r].split(separator: "/").first ?? "")
    }

    static func setFontScale(_ scale: Double, serial: String) async {
        _ = try? await run("settings put system font_scale \(scale)", serial: serial)
    }

    static func setDensity(_ dpi: Int?, serial: String) async {
        _ = try? await run(dpi.map { "wm density \($0)" } ?? "wm density reset", serial: serial)
    }
}
