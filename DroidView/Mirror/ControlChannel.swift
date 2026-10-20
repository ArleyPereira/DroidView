import Foundation

enum AndroidKey {
    static let home: UInt32 = 3, back: UInt32 = 4, call: UInt32 = 5
    static let dpadUp: UInt32 = 19, dpadDown: UInt32 = 20, dpadLeft: UInt32 = 21, dpadRight: UInt32 = 22
    static let volumeUp: UInt32 = 24, volumeDown: UInt32 = 25, power: UInt32 = 26, camera: UInt32 = 27
    static let tab: UInt32 = 61, space: UInt32 = 62, enter: UInt32 = 66, del: UInt32 = 67
    static let menu: UInt32 = 82, notification: UInt32 = 83, search: UInt32 = 84
    static let pageUp: UInt32 = 92, pageDown: UInt32 = 93, escape: UInt32 = 111, forwardDel: UInt32 = 112
    static let moveHome: UInt32 = 122, moveEnd: UInt32 = 123, volumeMute: UInt32 = 164
    static let appSwitch: UInt32 = 187, brightnessDown: UInt32 = 220, brightnessUp: UInt32 = 221
    static let sleep: UInt32 = 223, wakeup: UInt32 = 224, cut: UInt32 = 277, copy: UInt32 = 278, paste: UInt32 = 279
    static let screenshot: UInt32 = 120

    static let metaShift: UInt32 = 0x1 | 0x40
    static let metaAlt: UInt32 = 0x2 | 0x10
    static let metaCtrl: UInt32 = 0x1000 | 0x2000
    static let metaMeta: UInt32 = 0x10000 | 0x20000

    /// Mapeia `NSEvent.keyCode` (layout ANSI) para keycodes Android.
    static func fromMac(keyCode: UInt16) -> UInt32? {
        switch keyCode {
        case 0: return 29   // A
        case 11: return 30  // B
        case 8: return 31   // C
        case 2: return 32   // D
        case 14: return 33  // E
        case 3: return 34   // F
        case 5: return 35   // G
        case 4: return 36   // H
        case 34: return 37  // I
        case 38: return 38  // J
        case 40: return 39  // K
        case 37: return 40  // L
        case 46: return 41  // M
        case 45: return 42  // N
        case 31: return 43  // O
        case 35: return 44  // P
        case 12: return 45  // Q
        case 15: return 46  // R
        case 1: return 47   // S
        case 17: return 48  // T
        case 32: return 49  // U
        case 9: return 50   // V
        case 13: return 51  // W
        case 7: return 52   // X
        case 16: return 53  // Y
        case 6: return 54   // Z
        case 29: return 7   // 0
        case 18: return 8
        case 19: return 9
        case 20: return 10
        case 21: return 11
        case 23: return 12
        case 22: return 13
        case 26: return 14
        case 28: return 15
        case 25: return 16  // 9
        case 36, 76: return enter
        case 48: return tab
        case 49: return space
        case 51: return del
        case 117: return forwardDel
        case 53: return escape
        case 123: return dpadLeft
        case 124: return dpadRight
        case 125: return dpadDown
        case 126: return dpadUp
        case 115: return moveHome
        case 119: return moveEnd
        case 116: return pageUp
        case 121: return pageDown
        case 122: return 131 // F1
        case 120: return 132
        case 99: return 133
        case 118: return 134
        case 96: return 135
        case 97: return 136
        case 98: return 137
        case 100: return 138
        case 101: return 139
        case 109: return 140
        case 103: return 141
        case 111: return 142 // F12
        default: return nil
        }
    }
}

enum MotionAction: UInt8 { case down = 0, up = 1, move = 2 }
enum KeyAction: UInt8 { case down = 0, up = 1 }

/// Mensagens de controle do scrcpy (app/src/control_msg.c, versão 5.0.1).
enum ControlMessage {
    case injectKeycode(action: KeyAction, keycode: UInt32, repeatCount: UInt32 = 0, metaState: UInt32 = 0)
    case injectText(String)
    case injectTouch(action: MotionAction, pointerID: UInt64, x: Int32, y: Int32, width: UInt16, height: UInt16, pressure: Float, actionButton: UInt32 = 0, buttons: UInt32 = 0)
    case injectScroll(x: Int32, y: Int32, width: UInt16, height: UInt16, hScroll: Float, vScroll: Float, buttons: UInt32 = 0)
    case backOrScreenOn(KeyAction)
    case expandNotificationPanel
    case expandSettingsPanel
    case collapsePanels
    case getClipboard(copyKey: UInt8)
    case setClipboard(sequence: UInt64, text: String, paste: Bool)
    case setDisplayPower(Bool)
    case rotateDevice
    case openHardKeyboardSettings
    case startApp(String)
    case resetVideo

    static let pointerMouse: UInt64 = UInt64.max          // -1
    static let pointerFinger: UInt64 = UInt64.max - 1     // -2
    static let pointerVirtualFinger: UInt64 = UInt64.max - 2 // -3

    var data: Data {
        var d = Data()
        switch self {
        case let .injectKeycode(action, keycode, repeatCount, metaState):
            d.append(0); d.append(action.rawValue)
            d.appendBE(keycode); d.appendBE(repeatCount); d.appendBE(metaState)
        case let .injectText(text):
            d.append(1); Self.appendString(&d, text, maxBytes: 300)
        case let .injectTouch(action, pointerID, x, y, w, h, pressure, actionButton, buttons):
            d.append(2); d.append(action.rawValue); d.appendBE(pointerID)
            d.appendBE(x); d.appendBE(y); d.appendBE(w); d.appendBE(h)
            d.appendBE(Self.u16FixedPoint(pressure))
            d.appendBE(actionButton); d.appendBE(buttons)
        case let .injectScroll(x, y, w, h, hScroll, vScroll, buttons):
            d.append(3)
            d.appendBE(x); d.appendBE(y); d.appendBE(w); d.appendBE(h)
            d.appendBE(Self.i16FixedPoint(max(-1, min(1, hScroll / 16))))
            d.appendBE(Self.i16FixedPoint(max(-1, min(1, vScroll / 16))))
            d.appendBE(buttons)
        case let .backOrScreenOn(action):
            d.append(4); d.append(action.rawValue)
        case .expandNotificationPanel: d.append(5)
        case .expandSettingsPanel: d.append(6)
        case .collapsePanels: d.append(7)
        case let .getClipboard(copyKey):
            d.append(8); d.append(copyKey)
        case let .setClipboard(sequence, text, paste):
            d.append(9); d.appendBE(sequence); d.append(paste ? 1 : 0)
            Self.appendString(&d, text, maxBytes: (1 << 18) - 14)
        case let .setDisplayPower(on):
            d.append(10); d.append(on ? 1 : 0)
        case .rotateDevice: d.append(11)
        case .openHardKeyboardSettings: d.append(15)
        case let .startApp(name):
            d.append(16)
            let bytes = Array(name.utf8.prefix(255))
            d.append(UInt8(bytes.count)); d.append(contentsOf: bytes)
        case .resetVideo: d.append(17)
        }
        return d
    }

    private static func appendString(_ d: inout Data, _ text: String, maxBytes: Int) {
        var bytes = Array(text.utf8)
        if bytes.count > maxBytes {
            bytes = Array(bytes.prefix(maxBytes))
            // não corta no meio de um caractere UTF-8
            while let last = bytes.last, last & 0xC0 == 0x80 { bytes.removeLast() }
            if let last = bytes.last, last & 0xC0 == 0xC0 { bytes.removeLast() }
        }
        d.appendBE(UInt32(bytes.count))
        d.append(contentsOf: bytes)
    }

    private static func u16FixedPoint(_ f: Float) -> UInt16 {
        let v = UInt32(max(0, min(1, f)) * 65536)
        return v >= 0xFFFF ? 0xFFFF : UInt16(v)
    }

    private static func i16FixedPoint(_ f: Float) -> UInt16 {
        var v = Int32(f * 32768)
        if v >= 0x7FFF { v = 0x7FFF }
        if v < -0x8000 { v = -0x8000 }
        return UInt16(bitPattern: Int16(v))
    }
}

/// Socket de controle: escrita serializada numa fila, leitura das mensagens
/// do dispositivo (clipboard) numa thread dedicada.
final class ControlChannel: @unchecked Sendable {
    private let socket: TCPSocket
    private let queue = DispatchQueue(label: "droidview.control", qos: .userInteractive)
    var onClipboard: ((String) -> Void)?
    var onClosed: (() -> Void)?

    init(socket: TCPSocket) {
        self.socket = socket
    }

    func start() {
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "droidview.control.reader"
        t.start()
    }

    func send(_ message: ControlMessage) {
        let data = message.data
        queue.async { [socket] in try? socket.write(data) }
    }

    func close() { socket.close() }

    private func readLoop() {
        do {
            while true {
                let type = try socket.readUInt8()
                switch type {
                case 0: // CLIPBOARD
                    let len = Int(try socket.readUInt32BE())
                    let text = String(decoding: try socket.read(exactly: len), as: UTF8.self)
                    onClipboard?(text)
                case 1: // ACK_CLIPBOARD
                    _ = try socket.read(exactly: 8)
                case 2: // UHID_OUTPUT
                    _ = try socket.read(exactly: 2)
                    let size = Int(try socket.read(exactly: 2).uint16BE(at: 0))
                    _ = try socket.read(exactly: size)
                default:
                    throw SocketError(message: "Mensagem de dispositivo desconhecida: \(type)")
                }
            }
        } catch {
            onClosed?()
        }
    }
}
