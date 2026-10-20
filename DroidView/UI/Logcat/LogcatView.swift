import SwiftUI

struct LogcatView: View {
    @Bindable var model: LogcatModel
    @State private var autoScroll = true

    var body: some View {
        let rows = model.filtered
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollViewReader { proxy in
                List(rows) { line in
                    LogRow(line: line).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 18)
                .font(.system(size: 11.5, design: .monospaced))
                .onChange(of: rows.last?.id) { _, last in
                    guard autoScroll, let last else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            Divider()
            HStack {
                Text("\(rows.count) de \(model.lines.count) linhas")
                Spacer()
                Circle().fill(model.isRunning ? .green : .secondary).frame(width: 7, height: 7)
                Text(model.isRunning ? (model.isPaused ? "Pausado" : "Ao vivo") : "Desconectado")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .frame(minWidth: 700, minHeight: 360)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Buscar tag ou mensagem", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 200)
            TextField("Pacote (ex.: com.meuapp)", text: $model.packageFilter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Picker("Nível", selection: $model.minLevel) {
                ForEach(LogLine.Level.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 140)
            Toggle(isOn: $autoScroll) { Image(systemName: "arrow.down.to.line") }
                .toggleStyle(.button).help("Rolagem automática")
            Toggle(isOn: $model.isPaused) { Image(systemName: "pause.fill") }
                .toggleStyle(.button).help("Pausar")
            Button { model.clear() } label: { Image(systemName: "trash") }.help("Limpar (logcat -c)")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.exportText(), forType: .string)
            } label: { Image(systemName: "doc.on.doc") }.help("Copiar linhas filtradas")
            Button { save() } label: { Image(systemName: "square.and.arrow.down") }.help("Salvar em arquivo")
        }
        .padding(10)
        .padding(.top, 22)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "logcat-\(model.title).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.exportText().write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct LogRow: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.time).foregroundStyle(.secondary)
            Text(line.pid).foregroundStyle(.tertiary).frame(width: 46, alignment: .trailing)
            Text(line.level.rawValue)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 16)
                .background(color.opacity(0.85), in: .rect(cornerRadius: 3))
            Text(line.tag).foregroundStyle(color).lineLimit(1).frame(width: 160, alignment: .leading)
            Text(line.message).foregroundStyle(line.level.rank >= LogLine.Level.warn.rank ? color : .primary)
                .textSelection(.enabled)
        }
    }

    private var color: Color {
        switch line.level {
        case .verbose: .gray
        case .debug: .blue
        case .info: .green
        case .warn: .orange
        case .error, .fatal: .red
        }
    }
}
