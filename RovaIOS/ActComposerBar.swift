import SwiftUI
import UIKit

/// The input of the Act tab, shaped like the chat's: one rounded bar, a menu on the left, the text, then the
/// microphone (dictation: the words land in the field, nothing is sent) or the send arrow.
struct ActComposerBar<Leading: View>: View {
    @Binding var text: String
    let placeholder: String
    let busy: Bool
    let canSend: Bool
    var focus: FocusState<Bool>.Binding
    let onSend: () -> Void
    @ViewBuilder let leading: () -> Leading

    @StateObject private var recorder = WiqoSpeechRecorder()
    @State private var starting = false
    @State private var spokenFrom = ""
    @State private var micMessage: String?
    @State private var micDenied = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            leading()
                .frame(width: 34, height: 34)
            TextField(recorder.isRecording ? "Dinliyorum…" : placeholder, text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused(focus)
                .disabled(busy || recorder.isRecording)
                .padding(.vertical, 8)
            trailing
                .frame(width: 34, height: 34)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(focus.wrappedValue ? RovaDesign.ink.opacity(0.45) : Color(.separator).opacity(0.4), lineWidth: focus.wrappedValue ? 1.2 : 0.75)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .animation(.easeOut(duration: 0.15), value: canSend)
        .onChange(of: recorder.transcript) { _, transcript in
            guard recorder.isRecording, !transcript.isEmpty else { return }
            text = spokenFrom.isEmpty ? transcript : spokenFrom + " " + transcript
        }
        .alert("Sesli giriş izni gerekli", isPresented: $micDenied) {
            Button("Ayarları Aç") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            Button("Vazgeç", role: .cancel) {}
        } message: { Text("Konuşarak yazmak için Ayarlar'dan mikrofon ve konuşma tanıma iznini aç.") }
        .alert("Ses", isPresented: Binding(get: { micMessage != nil }, set: { if !$0 { micMessage = nil } })) {
            Button("Tamam", role: .cancel) {}
        } message: { Text(micMessage ?? "") }
    }

    @ViewBuilder private var trailing: some View {
        if busy || starting {
            ProgressView().controlSize(.small)
        } else if canSend && !recorder.isRecording {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 30, height: 30)
                    .background(Color.primary, in: Circle())
            }
            .accessibilityLabel("Gönder")
        } else {
            Button(action: toggleMic) {
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(recorder.isRecording ? Color.white : Color.primary)
                    .frame(width: 30, height: 30)
                    .background(recorder.isRecording ? Color.red : Color(.tertiarySystemFill), in: Circle())
            }
            .accessibilityLabel(recorder.isRecording ? "Ses kaydını bitir" : "Konuşarak yaz")
        }
    }

    private func toggleMic() {
        guard !starting else { return }
        starting = true
        Task { @MainActor in
            defer { starting = false }
            if recorder.isRecording {
                let heard = await recorder.stop()
                if !heard.isEmpty { text = spokenFrom.isEmpty ? heard : spokenFrom + " " + heard }
                return
            }
            spokenFrom = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch await recorder.start() {
            case .started, .startedWithNetworkFallback: break
            case .permissionDenied: micDenied = true
            case .speechUnavailable: micMessage = "Konuşma tanıma şu an kullanılamıyor. Siri ve Dikte'nin açık olduğundan emin ol; bu arada yazabilirsin."
            case .setupFailed: micMessage = "Mikrofon başlatılamadı; başka bir uygulama kullanıyor olabilir."
            }
        }
    }
}
