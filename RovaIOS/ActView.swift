import SwiftUI
import UniformTypeIdentifiers

/// One progress card for creating and for changing: the steps in order, the current one marked,
/// the job's own message under it, and a way to stop.
private struct ActJobCard: View {
    let job: ActJobState
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ActStage.allCases, id: \.rawValue) { step in
                HStack(spacing: 10) {
                    Group {
                        if step.rawValue < job.stage.rawValue {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                        } else if step == job.stage {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(step.title)
                        .font(.subheadline.weight(step == job.stage ? .semibold : .regular))
                        .foregroundStyle(step.rawValue > job.stage.rawValue ? .secondary : .primary)
                }
            }
            if !job.message.isEmpty {
                Text(job.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button("Durdur", action: onCancel).font(.footnote.weight(.medium))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Said before the first request is sent to the writer, and before every one for a device-only project.
private struct WriterConsentAlert: ViewModifier {
    @Binding var isPresented: Bool
    let deviceOnly: Bool
    let onContinue: () -> Void

    func body(content: Content) -> some View {
        content.alert("Yazara gönderilecek", isPresented: $isPresented) {
            Button("Devam et") { onContinue() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text(deviceOnly
                 ? "Bu proje yalnız bu cihazda duruyor. İsteği yazmak için dosyaları bu istek boyunca yazar modele gönderilir; sunucuda saklanmaz."
                 : "İsteği yazmak için projenin dosyaları yazar modele gönderilir ve sunucuda saklanmaz. Projen cihazlar arasında şifreli senkronlanır; sunucu içeriği okuyamaz.")
        }
    }
}

private extension View {
    func writerConsent(isPresented: Binding<Bool>, deviceOnly: Bool, onContinue: @escaping () -> Void) -> some View {
        modifier(WriterConsentAlert(isPresented: isPresented, deviceOnly: deviceOnly, onContinue: onContinue))
    }
}

/// Pinned projects stay at the top of the list (a convenience of this phone, not synced).
private enum ActPins {
    private static let key = "act.pinned.projects"
    static func load() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func save(_ ids: Set<String>) { UserDefaults.standard.set(Array(ids), forKey: key) }
}

/// The "Act" tab: the project list on top, one input at the bottom. A description creates a project; opening one
/// keeps all further changes on that project.
struct ActView: View {
    @ObservedObject private var model = ActModel.shared
    @State private var draft = ""
    @State private var mode: ActPrivacyMode = .devices
    @State private var openedID: String?
    @State private var pendingDelete: ActLocalProject?
    @State private var showingPrivacy = false
    @State private var showingConsent = false
    @State private var showingImporter = false
    @State private var query = ""
    @State private var pinned = ActPins.load()
    @FocusState private var composerFocused: Bool

    private static let suggestions: [(title: String, prompt: String)] = [
        ("Sayaç", "Artır, azalt ve sıfırla butonları olan bir sayaç uygulaması yap"),
        ("Yapılacaklar", "Görev ekleme, silme ve tamamlandı işaretleme olan bir yapılacaklar listesi yap"),
        ("Hafıza oyunu", "4x4 kartlı basit bir hafıza kartı eşleştirme oyunu yap"),
        ("Kişisel site", "Kişisel tanıtım sayfası yap: adım, mesleğim ve iletişim bölümü olsun"),
        ("Python", "Python ile 1'den 100'e kadar asal sayıları yazdıran bir program yap")
    ]

    private static let importTypes = ["html", "htm", "css", "js", "json", "txt", "md", "py", "svg", "csv"].compactMap { UTType(filenameExtension: $0) }

    private var creating: Bool { model.job != nil && model.job?.projectID == nil }
    private var canCreate: Bool { model.job == nil && draft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 }

    /// Pinned first, then the most recently changed; narrowed by the search text.
    private var visibleProjects: [ActLocalProject] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let filtered = needle.isEmpty ? model.projects : model.projects.filter { $0.name.range(of: needle, options: .caseInsensitive) != nil }
        return filtered.filter { pinned.contains($0.id) } + filtered.filter { !pinned.contains($0.id) }
    }

    var body: some View {
        Group {
            if let openedID, model.project(openedID) != nil {
                CodeProjectWorkspaceView(projectID: openedID, embedded: true, onBack: { self.openedID = nil }, onOpen: { self.openedID = $0 })
            } else {
                projectList
            }
        }
        .task {
            model.reload()
            await model.syncAll()
            await model.watchChanges()
        }
    }

    private var projectList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let note = model.syncNote {
                    Label(note, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                if model.projects.isEmpty {
                    emptyState
                } else {
                    if model.projects.count >= 6 { searchField }
                    rows
                }
            }
            .padding(.horizontal, RovaDesign.screenPadding)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .background(Color(.systemBackground))
        .wiqoConfirmation(item: $pendingDelete, title: { _ in "Proje silinsin mi?" }) { project in
            Button("Sil", role: .destructive) { Task { await model.delete(project.id) } }
        } message: { project in
            Text("\"\(project.name)\": dosyalar ve geçmiş tüm cihazlardan silinir; geri alınamaz.")
        }
        .sheet(isPresented: $showingPrivacy) { ActPrivacySheet() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .writerConsent(isPresented: $showingConsent, deviceOnly: mode == .deviceOnly) { startCreate() }
        .refreshable { await model.syncAll() }
    }

    // MARK: - Üst

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Projeler").font(.title2.weight(.bold))
            Spacer()
            Menu {
                Button { showingImporter = true } label: { Label("Dosyalardan aç", systemImage: "square.and.arrow.down") }
                Button { showingPrivacy = true } label: { Label("Gizlilik ve anahtar", systemImage: "lock.shield") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 20)).foregroundStyle(WiqoTheme.ink)
            }
            .accessibilityLabel("Daha fazla")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Proje ara", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ne yapmak istersin?").font(.title3.weight(.semibold))
            Text("Aşağıya yaz, konuşarak anlat ya da birini seç.").font(.subheadline).foregroundStyle(.secondary)
                .padding(.bottom, 10)
            ForEach(Self.suggestions, id: \.title) { suggestion in
                Button {
                    draft = suggestion.prompt
                    composerFocused = true
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                            Text(suggestion.prompt).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.left").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .padding(.top, 18)
    }

    // MARK: - Liste

    private var rows: some View {
        let list = visibleProjects
        return VStack(spacing: 0) {
            ForEach(list) { project in
                Button { openedID = project.id } label: { ProjectRow(project: project, pinned: pinned.contains(project.id)) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { openedID = project.id } label: { Label("Aç", systemImage: "arrow.up.right.square") }
                        Button { togglePin(project.id) } label: { Label(pinned.contains(project.id) ? "Sabitlemeyi kaldır" : "Üste sabitle", systemImage: pinned.contains(project.id) ? "pin.slash" : "pin") }
                        Button { if let id = model.duplicate(project.id) { openedID = id } } label: { Label("Kopya oluştur", systemImage: "plus.square.on.square") }
                        Divider()
                        Button(role: .destructive) { pendingDelete = project } label: { Label("Sil", systemImage: "trash") }
                    }
                if project.id != list.last?.id { Divider().padding(.leading, 56) }
            }
            if list.isEmpty { Text("Sonuç yok.").font(.footnote).foregroundStyle(.secondary).padding(.top, 20).frame(maxWidth: .infinity) }
        }
    }

    private func togglePin(_ id: String) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        ActPins.save(pinned)
        WiqoHaptics.selection()
    }

    // MARK: - Alt: yeni proje

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let job = model.job, job.projectID == nil {
                ActJobCard(job: job) { Task { await model.cancel() } }
            }
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(WiqoTheme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            ActComposerBar(
                text: $draft,
                placeholder: "Ne yapalım?",
                busy: creating,
                canSend: canCreate,
                focus: $composerFocused,
                onSend: requestCreate
            ) {
                Menu {
                    Section("Bu proje nerede dursun?") {
                        ForEach([ActPrivacyMode.devices, .deviceOnly], id: \.self) { option in
                            Button { mode = option } label: { Label(option.title, systemImage: mode == option ? "checkmark" : option.systemImage) }
                        }
                    }
                } label: {
                    Image(systemName: mode.systemImage).font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary).frame(width: 34, height: 34)
                }
                .disabled(model.job != nil)
                .accessibilityLabel("Gizlilik: \(mode.title)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(Color(.systemBackground))
    }

    private func requestCreate() {
        composerFocused = false
        if model.needsConsent(for: nil) || mode == .deviceOnly { showingConsent = true } else { startCreate() }
    }

    private func startCreate() {
        model.recordConsent()
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if let id = await model.create(request: request, mode: mode) {
                draft = ""
                WiqoHaptics.selection()
                openedID = id
            }
        }
    }

    /// Text files from the Files app become a new project; anything the hub could not take is counted, not hidden.
    private func importFiles(_ urls: [URL]) {
        var files: [String: String] = [:]
        var skipped = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            guard files.count < ActSync.maxFiles, let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
                  ActSync.isSyncable(path: name, content: text) else { skipped += 1; continue }
            files[name] = text
        }
        let base = urls.first?.deletingPathExtension().lastPathComponent ?? "Proje"
        if let id = model.importProject(name: base, files: files, mode: mode) {
            openedID = id
            model.notice = skipped > 0 ? "\(skipped) dosya alınamadı (metin olmalı, en çok 100 KB)." : nil
        } else {
            model.notice = "Dosyalar alınamadı. Türler: html, css, js, json, txt, md, py, svg, csv; en çok 100 KB."
        }
    }
}

/// One project: a name and a quiet line under it. No cards, no chips; the list reads like a list.
private struct ProjectRow: View {
    let project: ActLocalProject
    let pinned: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: project.isWeb ? "safari" : "terminal")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(WiqoTheme.ink)
                .frame(width: 42, height: 42)
                .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if pinned { Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(.tertiary) }
            if project.mode == .deviceOnly { Image(systemName: "iphone").font(.system(size: 12)).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.unitsStyle = .short
        return formatter
    }()

    private var caption: String {
        [project.isWeb ? "Web" : "Python", Self.relativeFormatter.localizedString(for: project.updatedAt, relativeTo: Date())].joined(separator: " · ")
    }
}

/// What stays where, in three lines; the recovery code; entering another device's code.
private struct ActPrivacySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = ActModel.shared
    @State private var revealed = false
    @State private var code = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("lock.icloud", "Şifreli senkron", "Projelerin cihazların arasında şifreli gider; anahtar yalnız sende, sunucu içeriği okuyamaz.")
                    row("iphone", "Yalnız bu cihaz", "Seçtiğin projeler hiçbir yere gönderilmez.")
                    row("text.badge.checkmark", "Yazar model", "Bir istek yazılırken o isteğin dosyaları gider, saklanmaz.")
                }

                Section {
                    if revealed {
                        Text(model.recoveryCode).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Button("Kopyala") { UIPasteboard.general.string = model.recoveryCode; message = "Kopyalandı." }
                    } else {
                        Button("Kurtarma kodunu göster") { revealed = true }
                    }
                } header: { Text("Kurtarma kodu") } footer: {
                    Text("Yeni cihaza geçerken gerekir. Güvenli bir yere yaz; kaybedersen şifreli projeler açılamaz.")
                }

                Section {
                    DisclosureGroup("Başka cihazın anahtarını gir") {
                        TextField("Kod", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(.callout, design: .monospaced))
                        Button("Kullan") {
                            if model.useRecoveryCode(code) {
                                message = "Anahtar değişti; projeler yeniden eşitleniyor."
                                code = ""
                                Task { await model.syncAll() }
                            } else {
                                message = "Kod geçersiz; 55 karakteri kontrol et."
                            }
                        }
                        .disabled(code.count < 20)
                    }
                } footer: { Text("Mac'e anahtar, telefon ve Mac aynı ağdayken kendiliğinden gider.") }

                if let message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Gizlilik")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Bitti") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(WiqoTheme.ink).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Proje çalışma alanı

/// One project, full screen: the running page (or the program's output) on top, one input at the
/// bottom. Whatever is typed there changes this project and nothing else.
struct CodeProjectWorkspaceView: View {
    let projectID: String
    var embedded = false
    var onBack: (() -> Void)? = nil
    var onOpen: ((String) -> Void)? = nil

    @ObservedObject private var model = ActModel.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var runResult: ActHub.RunResult?
    @State private var running = false
    @State private var draft = ""
    @State private var reloadToken = 0
    @State private var showingDetails = false
    @State private var confirmingDelete = false
    @State private var showingConsent = false
    @State private var pcStatus: String?
    @State private var pcOutput: String?
    @State private var tab: WorkspaceTab = .preview
    @State private var codeFile: String?
    @State private var console: [ConsoleLine] = []
    @State private var showingConsole = false
    @State private var expandedEntry: UUID?
    @State private var editing = false
    @State private var editorText = ""
    @State private var searching = false
    @State private var searchText = ""
    @State private var previewDevice: WiqoPreviewDevice = .phone
    @State private var showingNewFile = false
    @State private var renamingFile: String?
    @State private var fileNameField = ""
    @State private var pendingFileDelete: String?
    @State private var showingFullScreen = false
    @FocusState private var focused: Bool

    private enum WorkspaceTab: Hashable { case preview, code, history }

    private struct ConsoleLine: Identifiable {
        let id = UUID()
        let level: String
        let text: String
    }

    private static let starters: [(title: String, icon: String, prompt: String)] = [
        ("Mobilde daha iyi göster", "iphone", "Sayfayı telefon ekranına göre düzenle: boşlukları, hizayı ve dokunma alanlarını iyileştir"),
        ("Daha sade yap", "minus.circle", "Tasarımı daha sade ve düzenli yap; gereksiz süsleri ve kalabalığı kaldır"),
        ("Hataları ara ve düzelt", "ladybug", "Kodu gözden geçir, çalışmayan veya hatalı yerleri bul ve düzelt"),
        ("Erişilebilirliği artır", "accessibility", "Kontrastı, yazı okunurluğunu ve buton boyutlarını erişilebilirlik için iyileştir"),
        ("Kısa açıklama ekle", "text.alignleft", "Sayfanın en üstüne ne işe yaradığını anlatan kısa bir açıklama ekle")
    ]

    private var project: ActLocalProject? { model.project(projectID) }
    private var working: Bool { model.job?.projectID == projectID }
    private var canSend: Bool { model.job == nil && draft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }
    private var isWeb: Bool { project?.isWeb ?? true }

    var body: some View {
        VStack(spacing: 0) {
            if embedded {
                HStack(spacing: 10) {
                    Button { onBack?() } label: { Label("Projeler", systemImage: "chevron.left") }
                        .buttonStyle(.plain)
                        .foregroundStyle(WiqoTheme.ink)
                    Text(project?.name ?? "Proje")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: project?.mode.systemImage ?? "lock.icloud").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    menu
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
            }
            tabBar
            content
            if !(tab == .code && editing) {
                Divider()
                footer
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(embedded ? "" : (project?.name ?? "Proje"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !embedded { ToolbarItem(placement: .topBarTrailing) { menu } } }
        .sheet(isPresented: $showingDetails) { NavigationStack { CodeProjectDetailView(projectID: projectID) } }
        .fullScreenCover(isPresented: $showingFullScreen) { fullScreenPreview }
        .wiqoConfirmation("Proje silinsin mi?", isPresented: $confirmingDelete) {
            Button("Sil", role: .destructive) { Task { await deleteProject() } }
        } message: {
            Text("Dosyalar ve geçmiş tüm cihazlardan silinir; geri alınamaz.")
        }
        .wiqoConfirmation(item: $pendingFileDelete, title: { "\($0) silinsin mi?" }) { path in
            Button("Dosyayı sil", role: .destructive) { model.saveFiles(projectID, remove: [path], summary: "\(path) silindi") }
        } message: { _ in Text("Silme geçmişe yazılır; Geçmiş sekmesinden geri alınabilir.") }
        .alert("Yeni dosya", isPresented: $showingNewFile) {
            TextField("ornek.css", text: $fileNameField).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Ekle") { addFile(fileNameField) }
            Button("Vazgeç", role: .cancel) {}
        } message: { Text("Klasör kullanabilirsin: js/app.js. Türler: html, css, js, json, txt, md, py, svg, csv.") }
        .alert("Yeniden adlandır", isPresented: Binding(get: { renamingFile != nil }, set: { if !$0 { renamingFile = nil } })) {
            TextField("dosya adı", text: $fileNameField).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Kaydet") { if let old = renamingFile { renameFile(old, to: fileNameField) } }
            Button("Vazgeç", role: .cancel) {}
        }
        .writerConsent(isPresented: $showingConsent, deviceOnly: project?.mode == .deviceOnly) { startSend() }
        .task {
            model.reload()
            await model.sync(projectID)
            reloadToken += 1
        }
        .onChange(of: reloadToken) { _, _ in console.removeAll() }
    }

    // MARK: Sekmeler

    private var tabBar: some View {
        WiqoPillTabs<WorkspaceTab>(
            options: [
                WiqoPillTabs<WorkspaceTab>.Option(value: .preview, title: isWeb ? "Önizleme" : "Çıktı", systemImage: isWeb ? "iphone" : "play.rectangle"),
                WiqoPillTabs<WorkspaceTab>.Option(value: .code, title: "Kod", systemImage: "chevron.left.forwardslash.chevron.right"),
                WiqoPillTabs<WorkspaceTab>.Option(value: .history, title: "Geçmiş", systemImage: "clock.arrow.circlepath")
            ],
            selection: $tab
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .preview:
            VStack(spacing: 0) {
                if isWeb { previewBar }
                stage
            }
        case .code: codeStage
        case .history: historyStage
        }
    }

    private var previewBar: some View {
        HStack(spacing: 10) {
            ForEach(WiqoPreviewDevice.allCases) { device in
                Button { withAnimation(.snappy(duration: 0.2)) { previewDevice = device } } label: {
                    Label(device.title, systemImage: device.systemImage)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(previewDevice == device ? WiqoTheme.inset : Color.clear, in: Capsule())
                        .foregroundStyle(previewDevice == device ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { showingFullScreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14, weight: .medium)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Tam ekran")
            Button { reloadToken += 1 } label: { Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .medium)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Sayfayı yenile")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
    }

    /// The page on the whole screen, as a person would use it.
    private var fullScreenPreview: some View {
        ZStack(alignment: .topTrailing) {
            Color.white.ignoresSafeArea()
            if let project, let page = project.bundle {
                WiqoHTMLWebView(
                    html: WiqoHTMLDocument.wrap(page, viewportWidth: previewDevice.viewportWidth, reduceMotion: reduceMotion),
                    projectDataKey: project.id,
                    reloadToken: reloadToken
                )
                .ignoresSafeArea(edges: .bottom)
            }
            Button { showingFullScreen = false } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.primary)
                    .frame(width: 36, height: 36).background(.regularMaterial, in: Circle())
            }
            .padding(12)
            .accessibilityLabel("Kapat")
        }
    }

    /// The files of the project, one chip per file, read like an editor (line numbers, syntax colours) and editable by hand.
    private var codeStage: some View {
        let files = (project?.sortedFiles ?? [])
        let selected = files.first { $0.path == codeFile } ?? files.first { $0.path == "index.html" || $0.path == "main.py" } ?? files.first
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(files, id: \.path) { file in
                            Button { codeFile = file.path; searching = false } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: Self.icon(for: file.path)).font(.system(size: 11))
                                    Text(file.path).font(.custom("JetBrainsMono-Regular", size: 12, relativeTo: .caption))
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(file.path == selected?.path ? WiqoTheme.ink : WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .foregroundStyle(file.path == selected?.path ? Color(.systemBackground) : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .disabled(editing)
                            .contextMenu {
                                Button { fileNameField = file.path; renamingFile = file.path } label: { Label("Yeniden adlandır", systemImage: "pencil") }
                                Button(role: .destructive) { pendingFileDelete = file.path } label: { Label("Sil", systemImage: "trash") }
                            }
                        }
                        Button { fileNameField = ""; showingNewFile = true } label: {
                            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 30)
                                .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .disabled(editing)
                        .accessibilityLabel("Yeni dosya")
                    }
                    .padding(.horizontal, 14)
                }
                Button { searching.toggle(); searchText = "" } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).frame(width: 34, height: 34)
                        .foregroundStyle(searching ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(editing)
                .accessibilityLabel("Projede ara")
                Button {
                    if editing { editing = false } else if let selected { editorText = selected.content; searching = false; editing = true }
                } label: {
                    Image(systemName: editing ? "xmark" : "pencil.line").font(.system(size: 14, weight: .medium)).frame(width: 34, height: 34)
                        .foregroundStyle(editing ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(selected == nil || model.job != nil)
                .accessibilityLabel(editing ? "Düzenlemeyi bırak" : "Düzenle")
                .padding(.trailing, 8)
            }
            .padding(.bottom, 8)
            if searching {
                searchPanel(files)
            } else if let selected {
                if editing {
                    ActCodeEditor(text: $editorText)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    HStack(spacing: 10) {
                        Text(selected.path).font(.custom("JetBrainsMono-Regular", size: 11, relativeTo: .caption2)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Vazgeç") { editing = false }.buttonStyle(.wiqoPill(.secondary))
                        Button("Kaydet") { saveEdit(selected.path) }.buttonStyle(.wiqoPill(.accent)).disabled(editorText == selected.content)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                } else {
                    ScrollView {
                        WiqoCodeBlock(code: selected.content, title: selected.path)
                            .id(selected.path)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 14)
                    }
                }
            } else {
                Spacer()
                Text("Projede dosya yok.").font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct SearchHit: Identifiable {
        let path: String
        let line: Int
        let text: String
        var id: String { "\(path):\(line)" }
    }

    private func hits(_ query: String, in files: [(path: String, content: String)]) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return [] }
        var found: [SearchHit] = []
        for file in files {
            for (index, line) in file.content.components(separatedBy: "\n").enumerated() where line.range(of: needle, options: .caseInsensitive) != nil {
                found.append(SearchHit(path: file.path, line: index + 1, text: line.trimmingCharacters(in: .whitespaces)))
                if found.count >= 80 { return found }
            }
        }
        return found
    }

    private func searchPanel(_ files: [(path: String, content: String)]) -> some View {
        let results = hits(searchText, in: files)
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Tüm dosyalarda ara", text: $searchText).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if results.isEmpty {
                        Text(searchText.trimmingCharacters(in: .whitespaces).count < 2 ? "En az 2 harf yaz." : "Sonuç yok.")
                            .font(.footnote).foregroundStyle(.secondary).padding(.top, 20).frame(maxWidth: .infinity)
                    }
                    ForEach(results) { hit in
                        Button { codeFile = hit.path; searching = false } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(hit.path):\(hit.line)").font(.custom("JetBrainsMono-Regular", size: 11, relativeTo: .caption2)).foregroundStyle(.secondary)
                                Text(hit.text).font(.custom("JetBrainsMono-Regular", size: 12, relativeTo: .caption)).foregroundStyle(.primary).lineLimit(2)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 14)
                    }
                }
            }
        }
    }

    private func saveEdit(_ path: String) {
        editing = false
        focused = false
        model.saveFiles(projectID, set: [path: editorText], summary: "\(path) elle düzenlendi")
        reloadToken += 1
        WiqoHaptics.selection()
    }

    /// A new file, empty; names are checked against what sync accepts.
    private func addFile(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validFileName(name) else { return }
        model.saveFiles(projectID, set: [name: ""], summary: "\(name) eklendi")
        codeFile = name
        editorText = ""
        editing = true
    }

    private func renameFile(_ old: String, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != old, validFileName(name), let content = project?.files[old] else { return }
        model.saveFiles(projectID, set: [name: content], remove: [old], summary: "\(old) → \(name)")
        codeFile = name
    }

    private func validFileName(_ name: String) -> Bool {
        let ok = !name.isEmpty && !name.hasPrefix("/") && !name.contains("..") && ActSync.isSyncable(path: name, content: "") && project?.files[name] == nil
        if !ok { model.notice = "Dosya adı geçersiz ya da zaten var (türler: html, css, js, json, txt, md, py, svg, csv)." }
        return ok
    }

    /// What changed, version by version; open an entry to see its diff.
    private var historyStage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array((project?.history ?? []).enumerated()), id: \.element.id) { index, entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { withAnimation(.snappy(duration: 0.2)) { expandedEntry = expandedEntry == entry.id ? nil : entry.id } } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: entry.verified ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(entry.verified ? Color.green : Color.orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.summary).font(.subheadline.weight(.medium)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                    Text("\(entry.source) · \(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(Self.counts(entry))")
                                        .font(.custom("JetBrainsMono-Regular", size: 11, relativeTo: .caption2))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: expandedEntry == entry.id ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        if expandedEntry == entry.id {
                            ForEach(entry.changes, id: \.path) { change in
                                WiqoCodeBlock(diff: Self.unifiedDiff(change), title: change.path)
                            }
                            if index > 0 {
                                Button { model.restore(projectID, to: entry.id); tab = .preview; reloadToken += 1 } label: {
                                    Label("Bu sürüme dön", systemImage: "arrow.uturn.backward")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(model.job != nil)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .wiqoCard()
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func icon(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "css": return "paintbrush"
        case "js", "json": return "curlybraces"
        case "py": return "terminal"
        case "md": return "doc.text"
        default: return "doc"
        }
    }

    private static func counts(_ entry: ActHistoryEntry) -> String {
        var added = 0
        var removed = 0
        for change in entry.changes {
            let diff = unifiedDiff(change).split(separator: "\n")
            added += diff.filter { $0.hasPrefix("+") }.count
            removed += diff.filter { $0.hasPrefix("-") }.count
        }
        return "\(entry.changes.count) dosya +\(added) −\(removed)"
    }

    /// A readable diff of one file change (removed and added lines in place; no surrounding context).
    private static func unifiedDiff(_ change: ActHistoryChange) -> String {
        let before = (change.before ?? "").components(separatedBy: "\n")
        let after = (change.after ?? "").components(separatedBy: "\n")
        let delta = after.difference(from: change.before == nil ? [] : before)
        var removals: [Int: String] = [:]
        var insertions: [Int: String] = [:]
        for step in delta {
            switch step {
            case .remove(let offset, let element, _): removals[offset] = element
            case .insert(let offset, let element, _): insertions[offset] = element
            }
        }
        var lines = ["@@ \(change.path) @@"]
        for offset in removals.keys.sorted() { lines.append("-\(removals[offset]!)") }
        for offset in insertions.keys.sorted() { lines.append("+\(insertions[offset]!)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Sahne

    @ViewBuilder private var stage: some View {
        ZStack {
            if let project {
                if isWeb {
                    if let page = project.bundle {
                        WiqoHTMLWebView(
                            html: WiqoHTMLDocument.wrap(page, viewportWidth: previewDevice.viewportWidth, reduceMotion: reduceMotion),
                            projectDataKey: project.id,
                            reloadToken: reloadToken,
                            onConsole: { level, text in
                                console.append(ConsoleLine(level: level, text: text))
                                if console.count > 80 { console.removeFirst(console.count - 80) }
                            }
                        )
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(WiqoTheme.lineStrong, lineWidth: 0.5) }
                        .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    } else {
                        Text("Bu projede açılacak bir sayfa (index.html) yok.").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    pythonStage
                }
            } else {
                ProgressView()
            }
            if let job = model.job, job.projectID == projectID {
                ActJobCard(job: job) { Task { await model.cancel() } }
                    .frame(maxWidth: 300)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pythonStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Button { Task { await run() } } label: { Label(runResult == nil ? "Çalıştır" : "Tekrar çalıştır", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.wiqoPill(.accent))
                    .disabled(running || model.job != nil)
                if let pcOutput, !pcOutput.isEmpty {
                    outputCard("Mac çıktısı", pcOutput, error: nil)
                }
                if let runResult {
                    outputCard("Çıktı", runResult.stdout.isEmpty ? (runResult.timedOut ? "Program zamanında bitmedi." : "Çıktı yok.") : runResult.stdout, error: runResult.stderr.isEmpty ? nil : runResult.stderr)
                } else {
                    Text("Programı çalıştırınca çıktısı burada görünür. Çalıştırma için dosyalar bu istek boyunca sunucudaki güvenli ortama gider ve saklanmaz.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(14)
        }
    }

    private func outputCard(_ title: String, _ text: String, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let error { Text(error).font(.system(.footnote, design: .monospaced)).foregroundStyle(WiqoTheme.red).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(14)
        .wiqoCard()
    }

    // MARK: Alt bölüm

    private var footer: some View {
        VStack(spacing: 10) {
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(WiqoTheme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let pcStatus {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                    Text(pcStatus).font(.footnote).lineLimit(3)
                    Spacer(minLength: 4)
                    Button { self.pcStatus = nil; pcOutput = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if isWeb && tab == .preview { consoleStrip }
            if let latest = project?.history.first { changeStrip(latest) }
            ActComposerBar(
                text: $draft,
                placeholder: "Ne değiştirelim?",
                busy: model.job != nil,
                canSend: canSend,
                focus: $focused,
                onSend: requestSend
            ) {
                Menu {
                    Section("Hazır istekler") {
                        ForEach(Self.starters, id: \.title) { starter in
                            Button { draft = starter.prompt; focused = true } label: { Label(starter.title, systemImage: starter.icon) }
                        }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(.primary).frame(width: 34, height: 34)
                }
                .disabled(model.job != nil)
                .accessibilityLabel("Daha fazla")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }

    /// The page's console: what it logged and every error it threw. Errors can be sent straight to the writer.
    @ViewBuilder private var consoleStrip: some View {
        let errors = console.filter { $0.level == "error" }
        if !console.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").font(.system(size: 12))
                    Text("Konsol").font(.footnote.weight(.semibold))
                    if !errors.isEmpty {
                        Text("\(errors.count) hata").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(WiqoTheme.red.opacity(0.15), in: Capsule()).foregroundStyle(WiqoTheme.red)
                    }
                    Text("\(console.count) satır").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if !errors.isEmpty {
                        Button { draft = "Sayfada şu hatalar var, düzelt: " + errors.prefix(3).map(\.text).joined(separator: "; "); focused = true } label: {
                            Label("Düzelt", systemImage: "wand.and.stars").font(.footnote.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(WiqoTheme.ink)
                        .disabled(model.job != nil)
                    }
                    Button { console.removeAll() } label: { Image(systemName: "trash").font(.system(size: 12)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Button { withAnimation(.snappy(duration: 0.2)) { showingConsole.toggle() } } label: { Image(systemName: showingConsole ? "chevron.down" : "chevron.up").font(.system(size: 12, weight: .semibold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                if showingConsole {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(console) { line in
                                Text(line.text)
                                    .font(.custom("JetBrainsMono-Regular", size: 11, relativeTo: .caption2))
                                    .foregroundStyle(line.level == "error" ? WiqoTheme.red : line.level == "warn" ? WiqoTheme.orange : Color.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 130)
                }
            }
            .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func changeStrip(_ entry: ActHistoryEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(entry.verified ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("v\(project?.versionNumber ?? 0) · \(entry.summary)")
                    .font(.footnote)
                    .lineLimit(1)
                Text("\(project?.files.count ?? 0) dosya · \(project?.mode.title ?? "")")
                    .font(.custom("JetBrainsMono-Regular", size: 10, relativeTo: .caption2))
                    .foregroundStyle(.secondary)
                if !entry.verified {
                    Text("Telefonda denenemedi; çalışmıyorsa geri al.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let notes = entry.notes, !notes.isEmpty {
                    Text("Tasarım notu: \(notes.joined(separator: "; "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if let notes = entry.notes, !notes.isEmpty, entry.verified {
                Button { draft = "Tasarım sorunlarını düzelt, başka bir şey değiştirme: " + notes.joined(separator: "; "); focused = true } label: { Label("Düzelt", systemImage: "wand.and.stars").font(.footnote.weight(.medium)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(WiqoTheme.ink)
                    .disabled(model.job != nil)
            }
            Button { undo() } label: { Label("Geri al", systemImage: "arrow.uturn.backward").font(.footnote.weight(.medium)) }
                .buttonStyle(.plain)
                .foregroundStyle(WiqoTheme.ink)
                .disabled(model.job != nil || !model.canUndo(projectID))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var menu: some View {
        Menu {
            Button { undo() } label: { Label("Son değişikliği geri al", systemImage: "arrow.uturn.backward") }
                .disabled(model.job != nil || !model.canUndo(projectID))
            if isWeb {
                Button { reloadToken += 1 } label: { Label("Sayfayı yenile", systemImage: "arrow.clockwise") }
            }
            Section("Mac'te") {
                if isWeb {
                    Button { Task { await handOff("open_preview", "Mac'te önizleme açılıyor…") } } label: { Label("Mac'te önizle", systemImage: "macwindow") }
                } else {
                    Button { Task { await handOff("run", "Mac'te çalıştırılıyor…") } } label: { Label("Mac'te çalıştır", systemImage: "play.rectangle") }
                }
                Button { Task { await handOff("open_editor", "Editörde açılıyor…") } } label: { Label("Mac'te editörde aç", systemImage: "chevron.left.forwardslash.chevron.right") }
                Button { Task { await handOff("open_folder", "Klasör açılıyor…") } } label: { Label("Klasörü Mac'te aç", systemImage: "folder") }
            }
            Section("Gizlilik") {
                ForEach([ActPrivacyMode.devices, .deviceOnly], id: \.self) { option in
                    Button { Task { await model.setMode(projectID, to: option) } } label: {
                        Label(option.title, systemImage: project?.mode == option ? "checkmark" : option.systemImage)
                    }
                }
            }
            Button { showingDetails = true } label: { Label("Paylaş ve ayrıntılar", systemImage: "square.and.arrow.up") }
            Button { if let id = model.duplicate(projectID) { onOpen?(id) } } label: { Label("Kopya oluştur", systemImage: "plus.square.on.square") }
            Divider()
            Button(role: .destructive) { confirmingDelete = true } label: { Label("Projeyi sil", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Proje menüsü")
    }

    // MARK: İşlemler

    private func requestSend() {
        focused = false
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Design-value requests are done on the phone, instantly, without the writer.
        if model.quickEdit(projectID, request: request) {
            draft = ""
            WiqoHaptics.selection()
            reloadToken += 1
            return
        }
        if model.needsConsent(for: project) { showingConsent = true } else { startSend() }
    }

    private func startSend() {
        model.recordConsent()
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await model.edit(projectID, request: request)
            if model.notice == nil || model.notice?.hasPrefix("Telefonda denenemedi") == true {
                draft = ""
                WiqoHaptics.selection()
            }
            runResult = nil
            reloadToken += 1
        }
    }

    private func undo() {
        model.undo(projectID)
        runResult = nil
        reloadToken += 1
    }

    private func run() async {
        running = true
        defer { running = false }
        do { runResult = try await model.runPython(projectID) }
        catch { model.notice = (error as? LocalizedError)?.errorDescription ?? "Program çalıştırılamadı." }
    }

    private func handOff(_ action: String, _ message: String) async {
        pcStatus = message
        pcOutput = nil
        let result = await model.handOff(projectID, action: action) { pcStatus = $0 }
        pcStatus = result.ok ? (action == "run" ? "Mac çalıştırdı." : result.text) : "Mac: \(result.text)"
        if action == "run" { pcOutput = result.text }
    }

    private func deleteProject() async {
        await model.delete(projectID)
        if model.project(projectID) == nil {
            if embedded { onBack?() } else { dismiss() }
        }
    }
}
