import Foundation
import Observation

struct LogLine: Identifiable, Hashable {
    enum Level: String, CaseIterable, Identifiable {
        case verbose = "V", debug = "D", info = "I", warn = "W", error = "E", fatal = "F"
        var id: String { rawValue }
        var rank: Int { Level.allCases.firstIndex(of: self)! }
        var title: String {
            switch self {
            case .verbose: "Verbose"
            case .debug: "Debug"
            case .info: "Info"
            case .warn: "Warn"
            case .error: "Error"
            case .fatal: "Assert"
            }
        }
    }

    let id: Int
    let time: String
    let pid: String
    let tid: String
    let level: Level
    let tag: String
    let message: String

    /// Formato `-v threadtime`: "10-19 20:21:00.123  1234  5678 I Tag: mensagem"
    static func parse(_ raw: Substring, id: Int) -> LogLine? {
        let parts = raw.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard parts.count == 6, let level = Level(rawValue: String(parts[4])) else { return nil }
        let rest = parts[5]
        let tag: Substring
        let msg: Substring
        if let colon = rest.range(of: ": ") {
            tag = rest[..<colon.lowerBound]
            msg = rest[colon.upperBound...]
        } else {
            tag = rest.hasSuffix(":") ? rest.dropLast() : rest
            msg = ""
        }
        return LogLine(id: id, time: "\(parts[0]) \(parts[1])", pid: String(parts[2]), tid: String(parts[3]),
                       level: level, tag: tag.trimmingCharacters(in: .whitespaces), message: String(msg))
    }
}

@MainActor
@Observable
final class LogcatModel {
    let serial: String
    let title: String
    private(set) var lines: [LogLine] = []
    private(set) var isRunning = false
    var isPaused = false
    var minLevel: LogLine.Level = .verbose
    var search = ""
    var packageFilter = ""
    private(set) var packagePIDs: Set<String> = []

    @ObservationIgnored private var socket: TCPSocket?
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var pending: [LogLine] = []
    @ObservationIgnored private var flushTimer: Timer?
    @ObservationIgnored private var pidTimer: Timer?
    private let maxLines = 50_000

    init(serial: String, title: String) {
        self.serial = serial
        self.title = title
    }

    var filtered: [LogLine] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filterPkg = !packageFilter.trimmingCharacters(in: .whitespaces).isEmpty
        return lines.filter { l in
            guard l.level.rank >= minLevel.rank else { return false }
            if filterPkg, !packagePIDs.contains(l.pid) { return false }
            if q.isEmpty { return true }
            return l.tag.lowercased().contains(q) || l.message.lowercased().contains(q)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let serial = self.serial
        Task.detached { [weak self] in
            do {
                let s = try ADBClient.shared.openService(serial: serial, "shell:logcat -v threadtime -T 2000")
                await MainActor.run { self?.socket = s }
                var buffer = Data()
                while let chunk = try s.readSome() {
                    buffer.append(chunk)
                    guard let lastNL = buffer.lastIndex(of: 0x0A) else { continue }
                    let complete = buffer[buffer.startIndex...lastNL]
                    buffer = Data(buffer[buffer.index(after: lastNL)...])
                    let text = String(decoding: complete, as: UTF8.self)
                    await self?.ingest(text)
                }
            } catch {}
            await MainActor.run { self?.isRunning = false }
        }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        pidTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPIDs() }
        }
    }

    func stop() {
        socket?.close()
        socket = nil
        flushTimer?.invalidate()
        pidTimer?.invalidate()
        isRunning = false
    }

    func clear() {
        lines.removeAll()
        pending.removeAll()
        let serial = self.serial
        Task.detached { _ = try? ADBClient.shared.shell(serial: serial, "logcat -c") }
    }

    private func ingest(_ text: String) {
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let line = LogLine.parse(raw, id: nextID) else { continue }
            nextID += 1
            pending.append(line)
        }
    }

    private func flush() {
        guard !isPaused, !pending.isEmpty else { return }
        lines.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    private func refreshPIDs() {
        let pkg = packageFilter.trimmingCharacters(in: .whitespaces)
        guard !pkg.isEmpty else { packagePIDs = []; return }
        let serial = self.serial
        Task.detached { [weak self] in
            let out = (try? ADBClient.shared.shell(serial: serial, "pidof \(DevTools.shellQuote(pkg))")) ?? ""
            let pids = Set(out.split(whereSeparator: \.isWhitespace).map(String.init))
            await MainActor.run { self?.packagePIDs = pids }
        }
    }

    func exportText() -> String {
        filtered.map { "\($0.time) \($0.pid) \($0.tid) \($0.level.rawValue) \($0.tag): \($0.message)" }.joined(separator: "\n")
    }
}
