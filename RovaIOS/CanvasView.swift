import SwiftUI

/// The composer's "Kod çalıştır" sheet: write Python/JavaScript/shell, run it directly on Wiqo's
/// server (the same stateless sandbox run_python uses - see RovaBackendClient.runCanvasCode /
/// backend routes/canvas.ts) and see stdout, stderr, and any produced charts/files inline,
/// without going through a model turn first. A deliberately small, self-contained view: no shared
/// state with the chat transcript, so closing it leaves nothing behind to clean up.
struct CanvasView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var language = "python"
    @State private var code = ""
    @State private var isRunning = false
    @State private var result: RovaBackendClient.CanvasRunResult?
    @State private var errorMessage: String?
    @State private var previewURL: URL?

    private let languages = [("python", "Python"), ("javascript", "JavaScript"), ("shell", "Shell")]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Dil", selection: $language) {
                        ForEach(languages, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)

                    codeEditor

                    Button {
                        Task { await run() }
                    } label: {
                        HStack {
                            if isRunning {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(isRunning ? "Çalışıyor..." : "Çalıştır")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RovaDesign.ink)
                    .disabled(isRunning || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if let result {
                        resultView(result)
                    }
                }
                .padding(RovaDesign.screenPadding)
            }
            .background(RovaDesign.canvas)
            .navigationTitle("Canvas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") { dismiss() }
                }
            }
            .quickLookPreview($previewURL)
        }
    }

    private var codeEditor: some View {
        TextEditor(text: $code)
            .font(.system(.footnote, design: .monospaced))
            .frame(minHeight: 200)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(RovaDesign.cardSurface, in: RoundedRectangle(cornerRadius: RovaDesign.cardRadius, style: .continuous))
            .overlay(alignment: .topLeading) {
                if code.isEmpty {
                    Text(placeholder)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
    }

    private var placeholder: String {
        switch language {
        case "python": return "# Python kodunu buraya yaz\nprint(\"merhaba\")"
        case "javascript": return "// JavaScript kodunu buraya yaz\nconsole.log(\"merhaba\")"
        default: return "# Shell komutlarını buraya yaz\necho merhaba"
        }
    }

    @ViewBuilder
    private func resultView(_ result: RovaBackendClient.CanvasRunResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                statusBadge(result)
                Text("\(result.durationMs) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !result.stdout.isEmpty {
                outputBlock(title: "Çıktı", text: result.stdout)
            }
            if !result.stderr.isEmpty {
                outputBlock(title: "Hata çıktısı", text: result.stderr, isError: true)
            }
            if result.truncated {
                Text("Çıktı çok uzun olduğu için kısaltıldı.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(result.artifacts) { artifact in
                if case .none = ArtifactInlineKind(mimeType: artifact.mimeType) {
                    ArtifactFileRow(artifact: artifact, isBusy: false) {
                        Task { previewURL = try? await RovaBackendClient.downloadArtifact(artifact) }
                    }
                } else {
                    InlineArtifactPreview(artifact: artifact) {
                        Task { previewURL = try? await RovaBackendClient.downloadArtifact(artifact) }
                    }
                }
            }
        }
    }

    private func statusBadge(_ result: RovaBackendClient.CanvasRunResult) -> some View {
        let (label, color): (String, Color) = {
            if result.timedOut { return ("Zaman aşımı", .orange) }
            if result.exitCode != 0 { return ("Hata (kod \(result.exitCode))", .red) }
            return ("Başarılı", RovaDesign.signal)
        }()
        return Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func outputBlock(title: String, text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(isError ? AttributedString(text) : SyntaxHighlighter.highlight(text))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RovaDesign.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func run() async {
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            result = try await RovaBackendClient.runCanvasCode(language: language, code: code)
        } catch RovaBackendError.declined(let message) {
            errorMessage = message
        } catch RovaBackendError.network(let message) {
            errorMessage = message
        } catch {
            errorMessage = "Kod çalıştırılamadı."
        }
    }
}
