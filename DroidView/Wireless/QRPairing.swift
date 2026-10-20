import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Pareamento por QR Code, no mesmo formato do Android Studio:
/// `WIFI:T:ADB;S:<nome-do-serviço>;P:<senha>;;`
/// O celular lê o QR, sobe um servidor de pareamento anunciado via mDNS como
/// `<nome-do-serviço>._adb-tls-pairing._tcp`, e nós pareamos com a senha.
struct QRPairingCredentials: Equatable {
    let serviceName: String
    let password: String

    var payload: String { "WIFI:T:ADB;S:\(serviceName);P:\(password);;" }

    static func random() -> QRPairingCredentials {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        func token(_ n: Int) -> String { String((0..<n).map { _ in alphabet.randomElement()! }) }
        return QRPairingCredentials(serviceName: "droidview-\(token(8))", password: token(12))
    }
}

enum QRCodeRenderer {
    static func image(for text: String, size: CGFloat = 220, dark: Bool = false) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard var output = filter.outputImage else { return nil }

        let colors = CIFilter.falseColor()
        colors.inputImage = output
        colors.color0 = CIColor(color: dark ? .white : .black)!
        colors.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let colored = colors.outputImage { output = colored }

        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}
