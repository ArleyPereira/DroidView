import SwiftUI

struct MirrorWindowView: View {
    @Bindable var session: MirrorSession
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            VideoSurface(session: session)
            stateOverlay
            if session.isRecording { RecordingBadge(startedAt: session.recordingStartedAt) }
        }
        .overlay(alignment: .bottom) { ToastView(toast: $session.toast).padding(16) }
        .overlay {
            if let shot = session.pendingScreenshot {
                ScreenshotPreview(shot: shot, session: session).id(shot.id)
            }
        }
        .background(.black)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch session.state {
        case .running, .stopped:
            EmptyView()
        case .connecting(let message):
            StatusCard(icon: nil, title: session.title, message: message, showsProgress: true)
        case .reconnecting(let message):
            StatusCard(icon: "arrow.triangle.2.circlepath", title: "Reconectando", message: message, showsProgress: true) {
                Button("Tentar agora") { session.retry() }
            }
        case .failed(let message):
            StatusCard(icon: "exclamationmark.triangle.fill", title: "Não foi possível espelhar", message: message, showsProgress: false) {
                Button("Tentar novamente") { session.retry() }
                    .buttonStyle(.glassProminent)
            }
        }
    }
}

private struct StatusCard<Actions: View>: View {
    let icon: String?
    let title: String
    let message: String
    let showsProgress: Bool
    @ViewBuilder var actions: Actions

    init(icon: String?, title: String, message: String, showsProgress: Bool, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.message = message
        self.showsProgress = showsProgress
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 14) {
            if let icon {
                Image(systemName: icon).font(.system(size: 30, weight: .medium)).symbolRenderingMode(.hierarchical)
            }
            if showsProgress { ProgressView().controlSize(.regular) }
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(8)
                .textSelection(.enabled)
            actions
        }
        .padding(24)
        .frame(maxWidth: 300)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding()
        .environment(\.colorScheme, .dark)
    }
}

private struct RecordingBadge: View {
    let startedAt: Date?

    var body: some View {
        VStack {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                if let startedAt {
                    Text(startedAt, style: .timer).monospacedDigit()
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassEffect(.regular.tint(.red.opacity(0.35)), in: .capsule)
            .environment(\.colorScheme, .dark)
            Spacer()
        }
        .padding(.top, 10)
        .allowsHitTesting(false)
    }
}

struct ToastView: View {
    @Binding var toast: Toast?

    var body: some View {
        if let toast {
            HStack(spacing: 10) {
                Image(systemName: toast.icon)
                Text(toast.message).lineLimit(2)
                if let url = toast.fileURL {
                    Button("Mostrar") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
            .environment(\.colorScheme, .dark)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(toast.fileURL == nil ? 2.5 : 4))
                withAnimation(.smooth) { self.toast = nil }
            }
        }
    }
}
