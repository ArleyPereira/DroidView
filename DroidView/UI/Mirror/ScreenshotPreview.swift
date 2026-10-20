import SwiftUI
import UniformTypeIdentifiers

/// Prévia do screenshot: Copiar (área de transferência), Salvar… (painel nativo) e Cancelar.
struct ScreenshotPreview: View {
    let shot: CapturedScreenshot
    let session: MirrorSession
    @State private var appeared = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(appeared ? 0.7 : 0))
                .ignoresSafeArea()
                .onTapGesture { close() }

            card
                .scaleEffect(appeared ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(duration: 0.35, bounce: 0.25)) { appeared = true } }
    }

    private var card: some View {
        GeometryReader { geo in
            let preview = previewSize(in: geo.size)
            VStack(spacing: 16) {
                header

                Image(nsImage: shot.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: preview.width, height: preview.height)
                    .id(shot.isLossless)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: shot.isLossless)
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                    .onDrag { dragProvider() }
                    .help("Arraste para o Finder ou outro app")

                actions
            }
            .padding(18)
            .frame(width: max(preview.width + 36, 300))
            .glassEffect(.regular.tint(.black.opacity(0.45)), in: .rect(cornerRadius: 26))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.colorScheme, .dark)
    }

    /// Prévia com a proporção exata da imagem, cabendo no espaço disponível.
    private func previewSize(in space: CGSize) -> CGSize {
        let px = shot.pixelSize
        guard px.width > 0, px.height > 0 else { return CGSize(width: 240, height: 240) }
        let maxW = min(space.width - 68, 420)
        let maxH = max(140, min(space.height - 190, space.height * 0.62))
        let scale = min(maxW / px.width, maxH / px.height)
        return CGSize(width: (px.width * scale).rounded(), height: (px.height * scale).rounded())
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(.tint.opacity(0.18), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text("Screenshot").font(.headline)
                status
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .animation(.smooth, value: shot.isUpgrading)
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Cancelar (Esc)")
        }
    }

    @ViewBuilder
    private var status: some View {
        let size = "\(Int(shot.pixelSize.width)) × \(Int(shot.pixelSize.height))"
        if shot.isUpgrading {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("\(size) · carregando sem perdas…").lineLimit(1)
            }
            .help("Já dá para copiar ou salvar o frame do vídeo; a versão sem perdas substitui assim que chegar")
        } else if let data = shot.data {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("\(size) · PNG sem perdas · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
            }
        } else {
            Text("\(size) · frame do vídeo")
        }
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button(role: .cancel, action: close) {
                    Text("Cancelar").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .help("Esc")

                Button { session.copyPendingScreenshot() } label: {
                    Label("Copiar", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .help("Copiar para a área de transferência (⌘C)")

                Button { session.savePendingScreenshot(in: NSApp.keyWindow) } label: {
                    Label("Salvar…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .help("Escolher onde salvar (↩)")
            }
            .controlSize(.large)
            .labelStyle(.titleAndIcon)
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.18)) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { session.dismissPendingScreenshot() }
    }

    private func dragProvider() -> NSItemProvider {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(shot.suggestedName)
        try? shot.pngData()?.write(to: url)
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
}
