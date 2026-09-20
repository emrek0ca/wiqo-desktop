import SwiftUI
import UIKit

/// The place where code Wiqo wrote (or the user wrote) becomes something you can see.
///
/// Two surfaces, nothing else:
///   - Kod: the editable source and the libraries it needs
///   - Sonuç: whatever the code produced - a live interface (as a phone app or on a PC), or the
///     program's output
///
/// Running code switches to the result on its own. HTML, and JavaScript written for the browser,
/// open instantly on the device. Python, JavaScript and shell run in the isolated backend sandbox;
/// a Python program that writes `app.html` (or any HTML file) gets that page shown as the
/// interface. A program that opens a native desktop window cannot be drawn on a phone, and the
/// canvas says so instead of showing an empty result.
struct CanvasView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var language: String
    @State private var code: String
    @State private var surface: Surface
    @State private var manualPackages: [String] = []
    @State private var dismissedPackages: Set<String> = []
    @State private var packageDraft = ""
    @State private var phase: RunPhase = .idle
    @State private var hasRun = false
    @State private var activeTaskID: Int?
    @State private var runMessage: String?
    @State private var result: RovaBackendClient.CanvasRunResult?
    @State private var errorMessage: String?
    @State private var artifactErrorMessage: String?
    @State private var previewHTML: String?
    @State private var previewURL: URL?
    @State private var previewDevice: WiqoPreviewDevice = .phone
    @State private var reloadToken = 0
    @State private var copied = false

    private let autoRun: Bool

    private enum Surface: String, CaseIterable {
        case code = "Kod"
        case result = "Sonuç"
    }

    private enum RunPhase: Equatable {
        case idle
        case preparing
        case running
        case finishing
        case done
    }

    private let languages = [
        ("python", "Python"),
        ("javascript", "JavaScript"),
        ("shell", "Shell"),
        ("html", "HTML")
    ]

    init(language: String = "python", code: String = "", autoRun: Bool = false) {
        let canonical = language.lowercased() == "html" ? "html" : language
        _language = State(initialValue: canonical)
        _code = State(initialValue: code)
        let hasCode = !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        _surface = State(initialValue: autoRun && hasCode ? .result : .code)
        self.autoRun = autoRun
    }

    // MARK: - Derived state

    private var isHTML: Bool { language == "html" }
    private var isRunning: Bool { phase == .preparing || phase == .running || phase == .finishing }
    private var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Libraries found in the code plus the ones the user added, minus the ones they turned off.
    private var packages: [String] {
        guard language == "python" else { return [] }
        var list: [String] = []
        for name in CanvasPackageDetector.detect(in: code) + manualPackages {
            let key = name.lowercased()
            guard !dismissedPackages.contains(key),
                  !list.contains(where: { $0.lowercased() == key }) else { continue }
            list.append(name)
        }
        return Array(list.prefix(CanvasPackageDetector.limit))
    }

    private var displayLanguage: String {
        languages.first(where: { $0.0 == language })?.1 ?? language.capitalized
    }

    private var fileName: String {
        switch language {
        case "python": return "canvas.py"
        case "javascript": return "canvas.js"
        case "shell": return "canvas.sh"
        default: return "app.html"
        }
    }

    private var placeholder: String {
        switch language {
        case "python": return "# Python kodunu buraya yaz\nprint(\"merhaba\")"
        case "javascript": return "// JavaScript kodunu buraya yaz\nconsole.log(\"merhaba\")"
        case "html": return "<!doctype html>\n<html>\n  <body>\n    <h1>Merhaba</h1>\n  </body>\n</html>"
        default: return "# Shell komutlarını buraya yaz\necho merhaba"
        }
    }

    private var opensNativeWindow: Bool {
        language == "python" && CanvasPackageDetector.opensNativeWindow(code)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                surfacePicker
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch surface {
                        case .code: codeSurface
                        case .result: resultSurface
                        }
                    }
                    .padding(RovaDesign.screenPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(RovaDesign.canvas)
            .safeAreaInset(edge: .bottom) { runBar }
            .navigationTitle("Canvas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Kapat") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    languageMenu
                }
            }
            .quickLookPreview($previewURL)
        }
        .task {
            guard autoRun, !trimmedCode.isEmpty else { return }
            await run()
        }
        .wiqoAnimation(value: surface)
    }

    private var surfacePicker: some View {
        WiqoPillTabs<Surface>(
            options: Surface.allCases.map { WiqoPillTabs<Surface>.Option(value: $0, title: $0.rawValue) },
            selection: $surface
        )
        .padding(.horizontal, RovaDesign.screenPadding)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var languageMenu: some View {
        Menu {
            ForEach(languages, id: \.0) { value, label in
                Button {
                    language = value
                } label: {
                    if language == value {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            Label(displayLanguage, systemImage: "chevron.down")
                .font(.caption.weight(.medium))
        }
        .accessibilityLabel("Kod dili")
    }

    private var runBar: some View {
        Button {
            if isRunning {
                Task { await cancelRun() }
            } else {
                Task { await run() }
            }
        } label: {
            HStack(spacing: 8) {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                }
                Text(isRunning ? "Durdur" : "Çalıştır")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.wiqoPill(isRunning ? .secondary : .accent))
        .disabled(!isRunning && trimmedCode.isEmpty)
        .padding(.horizontal, RovaDesign.screenPadding)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Kod

    private var codeSurface: some View {
        VStack(alignment: .leading, spacing: 14) {
            editor
            if language == "python" {
                packagesSection
            }
            if opensNativeWindow {
                notice("Bu kod bilgisayarda pencere açıyor. Telefonda göstermek için arayüzün web olarak (HTML) yazılması gerekir.", systemImage: "macwindow")
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WiqoTheme.ink3)
                Text(fileName)
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Kopyalandı" : "Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? WiqoTheme.green : Color.secondary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 42)

            Rectangle().fill(WiqoTheme.line).frame(height: 0.5)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $code)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)

                if code.isEmpty {
                    Text(placeholder)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoCard(radius: 14)
    }

    private var packagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Kütüphaneler", systemImage: "shippingbox")
                .font(.subheadline.weight(.medium))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(packages, id: \.self) { name in
                        packageChip(name)
                    }
                    TextField("Ekle", text: $packageDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                        .submitLabel(.done)
                        .frame(width: 84)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(WiqoTheme.inset, in: Capsule())
                        .onSubmit(addDraftPackage)
                }
            }

            Text(packages.isEmpty
                 ? "Kodda kullanılan tanınmış kütüphaneleri otomatik hazırlarım. İstersen kendin de ekleyebilirsin."
                 : "Çalıştırırken hazırlanır. Kod çalışırken internet erişimi kapalıdır.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func packageChip(_ name: String) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(.footnote, design: .monospaced))
            Button {
                dismissedPackages.insert(name.lowercased())
                manualPackages.removeAll { $0.lowercased() == name.lowercased() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(name) kütüphanesini kaldır")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 30)
        .background(WiqoTheme.inset, in: Capsule())
        .overlay { Capsule().strokeBorder(WiqoTheme.line, lineWidth: 0.5) }
    }

    private func addDraftPackage() {
        let name = packageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        packageDraft = ""
        guard !name.isEmpty, name.count <= 60 else { return }
        dismissedPackages.remove(name.lowercased())
        if !manualPackages.contains(where: { $0.lowercased() == name.lowercased() }) {
            manualPackages.append(name)
        }
    }

    // MARK: - Sonuç

    @ViewBuilder
    private var resultSurface: some View {
        if !hasRun && result == nil && previewHTML == nil && errorMessage == nil {
            emptyResult
        } else {
            let rows = progressRows
            if !rows.isEmpty {
                WiqoToolChips(rows: rows)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .wiqoCard(radius: 14)
            }

            if let previewHTML {
                previewSection(previewHTML)
            }

            if let result {
                outputSection(result)
            }

            if opensNativeWindow, previewHTML == nil {
                notice("Bu kod bilgisayarda pencere açıyor; telefonda gösterilemez. Arayüzün web olarak (HTML) yazılmasını iste.", systemImage: "macwindow")
            }

            if let artifactErrorMessage {
                Text(artifactErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                errorView(errorMessage)
            }
        }
    }

    private var emptyResult: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.rectangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Sonuç burada görünür")
                .font(.subheadline.weight(.medium))
            Text("Kodu çalıştırdığında arayüz ya da çıktı otomatik olarak açılır.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(20)
        .wiqoCard(radius: 16)
    }

    private var progressRows: [WiqoToolRow] {
        guard hasRun else { return [] }
        var rows: [WiqoToolRow] = []
        let past = phase != .idle && phase != .preparing

        if !packages.isEmpty {
            rows.append(WiqoToolRow(
                id: "packages",
                icon: "shippingbox",
                label: "Kütüphaneleri hazırla",
                chip: packages.joined(separator: ", "),
                tone: phase == .preparing ? .active : (past ? .success : .neutral)
            ))
        }

        let runTone: WiqoToolChipTone
        var runStatus: String?
        if isRunning {
            runTone = phase == .preparing ? .neutral : .active
            runStatus = phase == .preparing ? nil : runMessage
        } else if let result {
            runTone = result.timedOut ? .attention : (result.exitCode == 0 ? .success : .failure)
            runStatus = result.timedOut
                ? "Beklenenden uzun sürdü, durdurdum."
                : (result.exitCode == 0 ? nil : "Kod çalışmadı; ayrıntı aşağıda.")
        } else if errorMessage != nil {
            runTone = .failure
            runStatus = "Çalıştırma durdu."
        } else {
            runTone = previewHTML == nil ? .neutral : .success
            runStatus = nil
        }
        rows.append(WiqoToolRow(
            id: "run",
            icon: language == "html" ? "safari" : "terminal",
            label: language == "html" ? "Sayfayı aç" : "Kodu çalıştır",
            chip: fileName,
            tone: runTone,
            status: runStatus
        ))

        if previewHTML != nil, !isRunning {
            rows.append(WiqoToolRow(id: "preview", icon: "rectangle.on.rectangle", label: "Arayüzü aç", tone: .success))
        }
        return rows
    }

    private func previewSection(_ html: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                devicePicker
                Spacer(minLength: 0)
                Button {
                    reloadToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(WiqoTheme.inset, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Önizlemeyi yenile")
            }

            let document = WiqoHTMLDocument.wrap(html, viewportWidth: previewDevice.viewportWidth, reduceMotion: reduceMotion)
            Group {
                switch previewDevice {
                case .phone:
                    WiqoDeviceFrame(device: .phone) {
                        WiqoHTMLWebView(html: document, reloadToken: reloadToken)
                            .frame(height: 560)
                            .background(Color.white)
                    }
                    .frame(maxWidth: 300)
                    .frame(maxWidth: .infinity)
                case .desktop:
                    WiqoDeviceFrame(device: .desktop, address: fileName) {
                        WiqoHTMLWebView(html: document, reloadToken: reloadToken)
                            .frame(height: 380)
                            .background(Color.white)
                    }
                }
            }
            .transition(reduceMotion ? .identity : .opacity)
        }
        .wiqoAnimation(WiqoMotion.slide(), value: previewDevice)
    }

    private var devicePicker: some View {
        WiqoPillTabs<WiqoPreviewDevice>(
            options: WiqoPreviewDevice.allCases.map {
                WiqoPillTabs<WiqoPreviewDevice>.Option(value: $0, title: $0.title, systemImage: $0.systemImage)
            },
            selection: $previewDevice
        )
        .frame(maxWidth: 240)
    }

    @ViewBuilder
    private func outputSection(_ result: RovaBackendClient.CanvasRunResult) -> some View {
        let hasOutput = !result.stdout.isEmpty || !result.stderr.isEmpty
        if hasOutput {
            if previewHTML != nil {
                DisclosureGroup("Konsol") { outputBlocks(result) }
                    .font(.subheadline.weight(.medium))
                    .tint(.secondary)
            } else {
                outputBlocks(result)
            }
        } else if previewHTML == nil, result.exitCode == 0, result.artifacts.isEmpty {
            notice("Kod çalıştı ama görüntülenecek bir çıktı üretmedi.", systemImage: "checkmark.circle")
        }

        ForEach(result.artifacts) { artifact in
            if isHTMLArtifact(artifact) {
                ArtifactFileRow(artifact: artifact, isBusy: false) {
                    Task { await openArtifact(artifact) }
                }
            } else if case .none = ArtifactInlineKind(mimeType: artifact.mimeType) {
                ArtifactFileRow(artifact: artifact, isBusy: false) {
                    Task { await openArtifact(artifact) }
                }
            } else {
                InlineArtifactPreview(artifact: artifact) {
                    Task { await openArtifact(artifact) }
                }
            }
        }
    }

    private func outputBlocks(_ result: RovaBackendClient.CanvasRunResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !result.stdout.isEmpty {
                WiqoCodeBlock(code: result.stdout, title: "Çıktı")
            }
            if !result.stderr.isEmpty {
                WiqoCodeBlock(code: result.stderr, title: "Ayrıntı")
            }
            if result.truncated {
                Text("Çıktının uzun bölümünü kısalttım.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        DisclosureGroup {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Çalıştırma tamamlanamadı", systemImage: "exclamationmark.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(WiqoTheme.red)
        }
        .tint(.secondary)
        .padding(12)
        .background(WiqoTheme.tint(WiqoTheme.red), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Running

    @MainActor
    private func run() async {
        guard !isRunning else { return }
        let source = trimmedCode
        guard !source.isEmpty else { return }

        // A page, or a script written for the browser, needs no server: it opens right here.
        if isHTML || (language == "javascript" && WiqoHTMLDocument.isBrowserScript(source)) {
            showLocalPreview(isHTML ? source : WiqoHTMLDocument.wrapBrowserScript(source))
            return
        }

        let requested = packages
        hasRun = true
        surface = .result
        phase = requested.isEmpty ? .running : .preparing
        activeTaskID = nil
        result = nil
        previewHTML = nil
        errorMessage = nil
        artifactErrorMessage = nil
        runMessage = requested.isEmpty ? "Kodu çalıştırıyorum…" : "Kütüphaneleri hazırlıyorum…"
        defer { if isRunning { phase = .done } }

        do {
            let runResult = try await RovaBackendClient.runCanvasCode(
                language: language,
                code: source,
                packages: requested,
                onTaskID: { taskID in activeTaskID = taskID },
                onProgress: { message in
                    let text = naturalProgress(message)
                    runMessage = text
                    phase = text.contains("Kütüphane") ? .preparing : (text.contains("Çıktı") ? .finishing : .running)
                }
            )
            result = runResult
            phase = .done
            if let htmlArtifact = runResult.artifacts.first(where: isHTMLArtifact) {
                await loadPreview(htmlArtifact)
            }
        } catch RovaBackendError.declined(let message) {
            errorMessage = message
            phase = .done
        } catch RovaBackendError.network(let message) {
            errorMessage = message
            phase = .done
        } catch is CancellationError {
            runMessage = "Çalıştırmayı durdurdum."
            phase = .done
        } catch {
            errorMessage = "Kod çalıştırılamadı."
            phase = .done
        }
        activeTaskID = nil
    }

    @MainActor
    private func showLocalPreview(_ html: String) {
        hasRun = true
        result = nil
        errorMessage = nil
        artifactErrorMessage = nil
        previewHTML = html
        reloadToken += 1
        phase = .done
        surface = .result
    }

    @MainActor
    private func cancelRun() async {
        guard let taskID = activeTaskID else {
            runMessage = "Çalıştırmayı durduruyorum…"
            return
        }
        do {
            try await RovaBackendClient.cancelCanvasRun(taskID: taskID)
            runMessage = "Çalıştırmayı durduruyorum…"
        } catch {
            errorMessage = "Çalıştırma durdurulamadı."
        }
    }

    @MainActor
    private func loadPreview(_ artifact: RovaBackendClient.ArtifactDescriptor) async {
        do {
            let url = try await RovaBackendClient.downloadArtifact(artifact)
            previewHTML = try String(contentsOf: url, encoding: .utf8)
            reloadToken += 1
        } catch {
            artifactErrorMessage = "Uygulama önizlemesi açılamadı."
        }
    }

    private func openArtifact(_ artifact: RovaBackendClient.ArtifactDescriptor) async {
        do {
            previewURL = try await RovaBackendClient.downloadArtifact(artifact)
        } catch {
            await MainActor.run { artifactErrorMessage = "Dosya açılamadı." }
        }
    }

    private func isHTMLArtifact(_ artifact: RovaBackendClient.ArtifactDescriptor) -> Bool {
        artifact.mimeType == "text/html" || artifact.filename.lowercased().hasSuffix(".html") || artifact.filename.lowercased().hasSuffix(".htm")
    }

    private func naturalProgress(_ message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("kütüphane") { return "Kütüphaneleri hazırlıyorum…" }
        if lowercased.contains("çıktı") || lowercased.contains("dosya") { return "Çıktıyı düzenliyorum…" }
        return "Kodu çalıştırıyorum…"
    }
}
