import Foundation
import os

/// Registro de diagnóstico do DroidView.
///
/// Cada evento vai para o unified logging (Console.app, subsystem
/// `com.arley.DroidView`) e para `~/Library/Logs/DroidView/droidview.log`,
/// com rotação em 5 MB (mantém `.1` e `.2`). O arquivo é a fonte para
/// investigar bugs relatados: conexões, adb, mDNS, espelhamento.
enum Log {
    enum Category: String {
        case app, adb, tracker, mdns, connect, mirror, server, ui
    }

    enum Level: String { case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR" }

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DroidView", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("droidview.log")

    /// Log do servidor adb (escrito pelo próprio adb), útil junto com o nosso.
    static var adbServerLogURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("adb.\(getuid()).log")
    }

    private static let maxSize = 5 * 1024 * 1024
    private static let queue = DispatchQueue(label: "droidview.log", qos: .utility)
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var loggers: [Category: Logger] = [:]
    private static let loggersLock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func debug(_ category: Category, _ message: @autoclosure () -> String) { write(.debug, category, message()) }
    static func info(_ category: Category, _ message: @autoclosure () -> String) { write(.info, category, message()) }
    static func warning(_ category: Category, _ message: @autoclosure () -> String) { write(.warning, category, message()) }
    static func error(_ category: Category, _ message: @autoclosure () -> String) { write(.error, category, message()) }

    /// Primeira linha de cada execução: versões e caminhos relevantes.
    static func startSession() {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        write(.info, .app, "===== DroidView \(version) iniciado · macOS \(os) · adb: \(ADBLocator.locate()?.path ?? "não encontrado") =====")
    }

    private static func write(_ level: Level, _ category: Category, _ message: String) {
        let logger = logger(for: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        let date = Date()
        let thread = Thread.isMainThread ? "main" : "bg"
        queue.async {
            let line = "\(formatter.string(from: date)) [\(level.rawValue)] [\(category.rawValue)] [\(thread)] \(message)\n"
            append(Data(line.utf8))
        }
    }

    private static func logger(for category: Category) -> Logger {
        loggersLock.lock(); defer { loggersLock.unlock() }
        if let l = loggers[category] { return l }
        let l = Logger(subsystem: "com.arley.DroidView", category: category.rawValue)
        loggers[category] = l
        return l
    }

    private static func append(_ data: Data) {
        if handle == nil { openFile() }
        guard let handle else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        if handle.offsetInFile > maxSize { rotate() }
    }

    private static func openFile() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let one = fileURL.appendingPathExtension("1"), two = fileURL.appendingPathExtension("2")
        try? fm.removeItem(at: two)
        try? fm.moveItem(at: one, to: two)
        try? fm.moveItem(at: fileURL, to: one)
        openFile()
    }
}
