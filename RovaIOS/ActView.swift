import SwiftUI
import UniformTypeIdentifiers

/// Progress of a job in one quiet line: what is happening now, which of the three steps, and a way to stop. Tapping it opens the writer's own message.
private struct ActJobStrip: View {
    let job: ActJobState
    let onCancel: () -> Void
    @State private var expanded = false

    private var stepNumber: Int { job.stage.rawValue + 1 }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(job.stage.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(stepNumber)/\(ActStage.allCases.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(action: onCancel) {
                    Text("Durdur")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            // Three short segments: done, current, to come.
            HStack(spacing: 4) {
                ForEach(ActStage.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(Color.primary.opacity(step.rawValue < job.stage.rawValue ? 0.55 : step == job.stage ? 0.35 : 0.10))
                        .frame(height: 3)
                }
            }
            if expanded, !job.message.isEmpty {
                Text(job.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if !job.message.isEmpty { withAnimation(WiqoMotion.ease(0.25)) { expanded.toggle() } } }
        .animation(WiqoMotion.ease(0.25), value: job.stage)
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
                 ? String(localized: "Bu proje yalnız bu cihazda duruyor. İsteği yazmak için dosyaları bu istek boyunca yazar modele gönderilir; sunucuda saklanmaz.")
                 : String(localized: "İsteği yazmak için projenin dosyaları yazar modele gönderilir ve sunucuda saklanmaz. Projen cihazlar arasında şifreli senkronlanır; sunucu içeriği okuyamaz."))
        }
    }
}

private extension View {
    func writerConsent(isPresented: Binding<Bool>, deviceOnly: Bool, onContinue: @escaping () -> Void) -> some View {
        modifier(WriterConsentAlert(isPresented: isPresented, deviceOnly: deviceOnly, onContinue: onContinue))
    }
}

/// One button of the side dock.
private struct ActDockItem: Identifiable {
    let id: String
    let systemImage: String
    let label: String
    var selected = false
    var disabled = false
    let action: () -> Void
}

/// The slim dock on the right edge of Act: icon buttons in groups (a hairline between groups), and an optional menu at the bottom.
/// Everything that used to sit in bars above and below the content lives here, so the content gets the whole width.
private struct ActDock<Extra: View>: View {
    let groups: [[ActDockItem]]
    @ViewBuilder var extra: Extra
    @State private var flash: String?

    /// Room a screen reserves beside its content so the dock never covers it.
    static var reservedWidth: CGFloat { 58 }

    private var column: some View {
        VStack(spacing: 2) {
            ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                if groupIndex > 0 {
                    Rectangle().fill(WiqoTheme.line).frame(width: 20, height: 0.5).padding(.vertical, 4)
                }
                ForEach(group) { item in
                    Button {
                        WiqoHaptics.selection()
                        item.action()
                        showLabel(item.label)
                    } label: {
                        ZStack {
                            Circle().fill(item.selected ? Color.primary.opacity(0.10) : Color.clear)
                            Image(systemName: item.systemImage)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color(uiColor: item.selected ? .label : .secondaryLabel))
                        }
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(item.disabled)
                    .opacity(item.disabled ? 0.35 : 1)
                    .accessibilityLabel(item.label)
                    .accessibilityAddTraits(item.selected ? .isSelected : [])
                }
            }
            extra
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .frame(width: 40, height: 40)
        }
        .padding(.vertical, 6)
        .frame(width: 44)
    }

    var body: some View {
        // Whole when there is room; scrolls on a short (sideways) screen.
        ViewThatFits(in: .vertical) {
            column
            ScrollView(.vertical, showsIndicators: false) { column }
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(WiqoTheme.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        // The name of what was just chosen, beside the dock for a moment.
        .overlay(alignment: .topLeading) {
            if let flash {
                Text(flash)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    .overlay(Capsule().strokeBorder(WiqoTheme.line, lineWidth: 0.5))
                    .fixedSize()
                    .alignmentGuide(.leading) { $0[.trailing] + 8 }
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func showLabel(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { flash = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            if flash == text { withAnimation(.easeOut(duration: 0.2)) { flash = nil } }
        }
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
    @State private var showsSearch = false
    @State private var pinned = ActPins.load()
    @FocusState private var composerFocused: Bool

    private static let suggestions: [(title: String, prompt: String)] = [
        (String(localized: "Sayaç"), String(localized: "Artır, azalt ve sıfırla butonları olan bir sayaç uygulaması yap")),
        (String(localized: "Yapılacaklar"), String(localized: "Görev ekleme, silme ve tamamlandı işaretleme olan bir yapılacaklar listesi yap")),
        (String(localized: "Hafıza oyunu"), String(localized: "4x4 kartlı basit bir hafıza kartı eşleştirme oyunu yap")),
        (String(localized: "Kişisel site"), String(localized: "Kişisel tanıtım sayfası yap: adım, mesleğim ve iletişim bölümü olsun")),
        ("Python", String(localized: "Python ile 1'den 100'e kadar asal sayıları yazdıran bir program yap"))
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
        // A chat card sent a request: a new project starts from it (the same consent and privacy steps as typing it here),
        // a change to an open project is applied to that project.
        .onReceive(NotificationCenter.default.publisher(for: .wiqoActHome)) { _ in
            withAnimation(WiqoMotion.ease(0.25)) { openedID = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiqoOpenInAct)) { note in
            guard let open = note.object as? ActOpenRequest else { return }
            handle(open)
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiqoOpenProjectInAct)) { note in
            if let id = note.object as? String, model.project(id) != nil { openedID = id }
        }
    }

    private func handle(_ open: ActOpenRequest) {
        if let id = open.projectID, let project = model.project(id) {
            openedID = id
            if open.operation == "edit" {
                if model.needsConsent(for: project) {
                    model.notice = String(localized: "Değişikliği başlatmak için projeye bir kez izin ver, sonra isteği buraya yaz.")
                } else {
                    Task { await model.edit(id, request: open.request) }
                }
            }
            return
        }
        guard model.job == nil else { model.notice = String(localized: "Act'te bir iş sürüyor; bitince yeniden dene."); return }
        openedID = nil
        draft = open.request
        requestCreate()
    }

    /// Wide room (a phone held sideways, a split view, a folded-open device): the list on the left, a new project on the right.
    private static let wideWidth: CGFloat = 620

    private var projectList: some View {
        GeometryReader { geo in
            if geo.size.width >= Self.wideWidth { wideHome(geo.size) } else { narrowHome }
        }
        .background(Color(.systemBackground))
        .wiqoConfirmation(item: $pendingDelete, title: { _ in String(localized: "Proje silinsin mi?") }) { project in
            Button("Sil", role: .destructive) { Task { await model.delete(project.id) } }
        } message: { project in
            Text("\"\(project.name)\": dosyalar ve geçmiş tüm cihazlardan silinir; geri alınamaz.")
        }
        .sheet(isPresented: $showingPrivacy) { ActPrivacySheet() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .writerConsent(isPresented: $showingConsent, deviceOnly: mode == .deviceOnly) { startCreate() }
    }

    private var narrowHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let note = model.syncNote {
                    Label(note, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                if model.projects.isEmpty {
                    emptyState
                } else {
                    if showsSearch { searchField }
                    rows
                }
            }
            .padding(.leading, RovaDesign.screenPadding)
            .padding(.trailing, ActDock<EmptyView>.reservedWidth)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.syncAll() }
        .overlay(alignment: .trailing) { listDock }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    }

    /// New, search, import, privacy: the list's actions, one tap each.
    private var listDock: some View {
        ActDock(groups: [
            [
                ActDockItem(id: "new", systemImage: "plus", label: String(localized: "Yeni proje")) { composerFocused = true },
                ActDockItem(id: "search", systemImage: "magnifyingglass", label: String(localized: "Proje ara"), selected: showsSearch, disabled: model.projects.isEmpty) {
                    withAnimation(WiqoMotion.ease(0.25)) { showsSearch.toggle(); if !showsSearch { query = "" } }
                }
            ],
            [
                ActDockItem(id: "import", systemImage: "square.and.arrow.down", label: String(localized: "Dosyalardan aç")) { showingImporter = true },
                ActDockItem(id: "privacy", systemImage: "lock.shield", label: String(localized: "Gizlilik ve anahtar")) { showingPrivacy = true }
            ]
        ]) { EmptyView() }
    }

    private func wideHome(_ size: CGSize) -> some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if let note = model.syncNote {
                        Label(note, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                    if model.projects.isEmpty {
                        Text("Henüz proje yok. Sağdan başla.").font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
                    } else {
                        if showsSearch { searchField }
                        rows
                    }
                }
                .padding(.horizontal, RovaDesign.screenPadding)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
            .refreshable { await model.syncAll() }
            .frame(width: min(max(size.width * 0.42, 280), 420))
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    emptyState
                        .padding(.horizontal, RovaDesign.screenPadding)
                        .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                bottomBar
            }
            .overlay(alignment: .trailing) { listDock }
        }
    }

    // MARK: - Üst

    private var header: some View {
        Text("Projeler").font(.title2.weight(.bold))
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
                ActJobStrip(job: job) { Task { await model.cancel() } }
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
                placeholder: String(localized: "Ne yapalım?"),
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
        if model.needsConsent(mode: mode) { showingConsent = true } else { startCreate() }
    }

    private func startCreate() {
        model.recordConsent(mode: mode)
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
        let base = urls.first?.deletingPathExtension().lastPathComponent ?? String(localized: "Proje")
        if let id = model.importProject(name: base, files: files, mode: mode) {
            openedID = id
            model.notice = skipped > 0 ? String(localized: "\(skipped) dosya alınamadı (metin olmalı, en çok 100 KB).") : nil
        } else {
            model.notice = String(localized: "Dosyalar alınamadı. Türler: html, css, js, json, txt, md, py, svg, csv; en çok 100 KB.")
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
                    row("lock.icloud", String(localized: "Şifreli senkron"), String(localized: "Projelerin cihazların arasında şifreli gider; anahtar yalnız sende, sunucu içeriği okuyamaz."))
                    row("iphone", String(localized: "Yalnız bu cihaz"), String(localized: "Seçtiğin projeler hiçbir yere gönderilmez."))
                    row("text.badge.checkmark", String(localized: "Yazar model"), String(localized: "Bir istek yazılırken o isteğin dosyaları gider, saklanmaz."))
                }

                Section {
                    if revealed {
                        Text(model.recoveryCode).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Button("Kopyala") { UIPasteboard.general.string = model.recoveryCode; message = String(localized: "Kopyalandı.") }
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
                                message = String(localized: "Anahtar değişti; projeler yeniden eşitleniyor.")
                                code = ""
                                Task { await model.syncAll() }
                            } else {
                                message = String(localized: "Kod geçersiz; 55 karakteri kontrol et.")
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
    @State private var packageError: String?
    @State private var loadingPackages = false
    @State private var pendingErrors: [(level: String, text: String)] = []
    @StateObject private var exporter = ActExporter()
    @FocusState private var focused: Bool

    private enum WorkspaceTab: Hashable { case preview, code, history }

    private struct ConsoleLine: Identifiable {
        let id = UUID()
        let level: String
        let text: String
    }

    private static let starters: [(title: String, icon: String, prompt: String)] = [
        (String(localized: "Mobilde daha iyi göster"), "iphone", String(localized: "Sayfayı telefon ekranına göre düzenle: boşlukları, hizayı ve dokunma alanlarını iyileştir")),
        (String(localized: "Daha sade yap"), "minus.circle", String(localized: "Tasarımı daha sade ve düzenli yap; gereksiz süsleri ve kalabalığı kaldır")),
        (String(localized: "Hataları ara ve düzelt"), "ladybug", String(localized: "Kodu gözden geçir, çalışmayan veya hatalı yerleri bul ve düzelt")),
        (String(localized: "Erişilebilirliği artır"), "accessibility", String(localized: "Kontrastı, yazı okunurluğunu ve buton boyutlarını erişilebilirlik için iyileştir")),
        (String(localized: "Kısa açıklama ekle"), "text.alignleft", String(localized: "Sayfanın en üstüne ne işe yaradığını anlatan kısa bir açıklama ekle"))
    ]

    private var project: ActLocalProject? { model.project(projectID) }
    private var working: Bool { model.job?.projectID == projectID }
    private var canSend: Bool { model.job == nil && draft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }
    private var isWeb: Bool { project?.isWeb ?? true }

    /// Wide room (a phone held sideways, a split view, a folded-open device): preview on the left, code and the input on the right.
    private static let wideWidth: CGFloat = 620

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= Self.wideWidth
            // A phone held sideways has little height: the extra status lines give way to the code.
            let short = geo.size.height < 420
            VStack(spacing: 0) {
                if embedded && !wide { workspaceHeader(short: false) }
                if wide {
                    splitBody(width: geo.size.width, short: short)
                } else {
                    content
                        .padding(.trailing, ActDock<EmptyView>.reservedWidth)
                        .overlay(alignment: .trailing) { workspaceDock(wide: false) }
                    if !(tab == .code && editing) {
                        Divider()
                        footer(showConsole: isWeb && tab == .preview, short: false)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color(.systemBackground))
        .navigationTitle(embedded ? "" : (project?.name ?? String(localized: "Proje")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !embedded { ToolbarItem(placement: .topBarTrailing) { menu } } }
        .sheet(item: $exporter.shared) { file in ActShareSheet(url: file.url).presentationDetents([.medium, .large]) }
        .onChange(of: draft) { _, text in if text != "Sayfadaki konsol hatalarını düzelt" { pendingErrors = [] } }
        .sheet(isPresented: $showingDetails) { NavigationStack { CodeProjectDetailView(projectID: projectID) } }
        .fullScreenCover(isPresented: $showingFullScreen) { fullScreenPreview }
        .wiqoConfirmation(String(localized: "Proje silinsin mi?"), isPresented: $confirmingDelete) {
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

    private func workspaceHeader(short: Bool) -> some View {
        HStack(spacing: 10) {
            Button { onBack?() } label: { Label("Projeler", systemImage: "chevron.left") }
                .buttonStyle(.plain)
                .foregroundStyle(WiqoTheme.ink)
            Text(project?.name ?? String(localized: "Proje"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Image(systemName: project?.mode.systemImage ?? "lock.icloud").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16)
        .frame(height: short ? 34 : 44)
    }

    /// The preview stays on the left the whole time; the right side is for the code, the history and the input.
    private func splitBody(width: CGFloat, short: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if embedded { workspaceHeader(short: short) }
                stage
                if isWeb { consoleStrip.padding(.horizontal, 12).padding(.bottom, 6) }
            }
            .frame(width: min(max(width * 0.42, 300), 480))
            Divider()
            VStack(spacing: 0) {
                Group {
                    switch tab {
                    case .history: historyStage
                    default: codeStage
                    }
                }
                .padding(.trailing, ActDock<EmptyView>.reservedWidth)
                .overlay(alignment: .trailing) { workspaceDock(wide: true) }
                if !(tab != .history && editing) {
                    Divider()
                    footer(showConsole: false, short: short)
                }
            }
        }
    }

    // MARK: Dock

    /// Sides of the project (preview / code / history), the preview's tools and the project menu, in one slim column on the right.
    private func workspaceDock(wide: Bool) -> some View {
        var sides: [ActDockItem] = []
        if !wide {
            sides.append(ActDockItem(id: "preview", systemImage: isWeb ? "iphone" : "play.rectangle", label: isWeb ? String(localized: "Önizleme") : String(localized: "Çıktı"), selected: tab == .preview) { tab = .preview })
        }
        sides.append(ActDockItem(id: "code", systemImage: "chevron.left.forwardslash.chevron.right", label: "Kod", selected: wide ? tab != .history : tab == .code) { tab = .code })
        sides.append(ActDockItem(id: "history", systemImage: "clock.arrow.circlepath", label: String(localized: "Geçmiş"), selected: tab == .history) { tab = .history })
        var groups = [sides]
        if isWeb && (wide || tab == .preview) {
            groups.append([
                ActDockItem(id: "device", systemImage: previewDevice.systemImage, label: previewDevice.title) {
                    let all = WiqoPreviewDevice.allCases
                    if let index = all.firstIndex(of: previewDevice) { withAnimation(.snappy(duration: 0.2)) { previewDevice = all[(index + 1) % all.count] } }
                },
                ActDockItem(id: "fullscreen", systemImage: "arrow.up.left.and.arrow.down.right", label: String(localized: "Tam ekran")) { showingFullScreen = true },
                ActDockItem(id: "reload", systemImage: "arrow.clockwise", label: String(localized: "Sayfayı yenile")) { reloadToken += 1 }
            ])
        }
        return ActDock(groups: groups) { if embedded { menu } }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .preview:
            stage
        case .code: codeStage
        case .history: historyStage
        }
    }

    /// The page on the whole screen, as a person would use it.
    private var fullScreenPreview: some View {
        ZStack(alignment: .topTrailing) {
            Color.white.ignoresSafeArea()
            if let project, let page = project.bundle {
                let packaged = ActPackages.shared.inlineCached(page)
                if packaged.missing.isEmpty {
                    WiqoHTMLWebView(
                        html: WiqoHTMLDocument.wrap(packaged.html, viewportWidth: previewDevice.viewportWidth, reduceMotion: reduceMotion),
                        projectDataKey: project.id,
                        reloadToken: reloadToken
                    )
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    packageCard(packaged.missing)
                }
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
        model.saveFiles(projectID, set: [path: editorText], summary: String(localized: "\(path) elle düzenlendi"))
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
        if !ok { model.notice = String(localized: "Dosya adı geçersiz ya da zaten var (türler: html, css, js, json, txt, md, py, svg, csv).") }
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
                        let packaged = ActPackages.shared.inlineCached(page)
                        if packaged.missing.isEmpty {
                            WiqoHTMLWebView(
                                html: WiqoHTMLDocument.wrap(packaged.html, viewportWidth: previewDevice.viewportWidth, reduceMotion: reduceMotion),
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
                            packageCard(packaged.missing)
                                .task(id: packaged.missing) { await loadPackages(page) }
                        }
                    } else {
                        Text("Bu projede açılacak bir sayfa (index.html) yok.").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    pythonStage
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The page asks for JavaScript packages that are not (yet) on this device, verified. It is not shown half-working.
    private func packageCard(_ missing: [String]) -> some View {
        VStack(spacing: 12) {
            Image(systemName: loadingPackages ? "arrow.down.circle" : "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(.secondary)
            Text(loadingPackages ? "Paketler indiriliyor ve doğrulanıyor…" : "Paket eksik (DEVICE_PACKAGE_MISSING)").font(.subheadline.weight(.semibold))
            Text(missing.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")).font(.custom("JetBrainsMono-Regular", size: 12, relativeTo: .caption)).foregroundStyle(.secondary)
            if let packageError, !loadingPackages {
                Text(packageError).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Tekrar dene") { if let page = project?.bundle { Task { await loadPackages(page) } } }.buttonStyle(.wiqoPill(.accent))
            } else if loadingPackages {
                ProgressView()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadPackages(_ page: String) async {
        guard !loadingPackages, let current = project else { return }
        loadingPackages = true
        packageError = nil
        defer { loadingPackages = false }
        do {
            _ = try await model.readyPage(for: current)
            reloadToken += 1
        } catch {
            packageError = (error as? LocalizedError)?.errorDescription ?? String(localized: "Paketler indirilemedi.")
        }
    }

    private var pythonStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Button { Task { await run() } } label: { Label(runResult == nil ? "Çalıştır" : "Tekrar çalıştır", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.wiqoPill(.accent))
                    .disabled(running || model.job != nil)
                if let pcOutput, !pcOutput.isEmpty {
                    outputCard(String(localized: "Mac çıktısı"), pcOutput, error: nil)
                }
                if let runResult {
                    outputCard(String(localized: "Çıktı"), runResult.stdout.isEmpty ? (runResult.timedOut ? String(localized: "Program zamanında bitmedi.") : String(localized: "Çıktı yok.")) : runResult.stdout, error: runResult.stderr.isEmpty ? nil : runResult.stderr)
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

    private func footer(showConsole: Bool, short: Bool) -> some View {
        VStack(spacing: 10) {
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(WiqoTheme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let busy = exporter.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.footnote)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if let exportError = exporter.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(WiqoTheme.red)
                    Text(exportError).font(.footnote).foregroundStyle(WiqoTheme.red).lineLimit(4)
                    Spacer(minLength: 4)
                    Button { exporter.error = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
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
            if showConsole { consoleStrip }
            if let job = model.job, job.projectID == projectID {
                ActJobStrip(job: job) { Task { await model.cancel() } }
                    .transition(.opacity)
            } else if !short, let latest = project?.history.first {
                changeStrip(latest)
            }
            ActComposerBar(
                text: $draft,
                placeholder: String(localized: "Ne değiştirelim?"),
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
                        Button { fixConsoleErrors(errors.map { (level: $0.level, text: $0.text) }) } label: {
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(entry.verified ? Color(red: 0.33, green: 0.62, blue: 0.42) : Color(red: 0.85, green: 0.62, blue: 0.28))
                    .frame(width: 6, height: 6)
                Text("v\(project?.versionNumber ?? 0) · \(entry.summary)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let notes = entry.notes, !notes.isEmpty, entry.verified {
                    Button { draft = String(localized: "Tasarım sorunlarını düzelt, başka bir şey değiştirme: ") + notes.joined(separator: "; "); focused = true } label: { Text("Düzelt").font(.footnote.weight(.medium)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(WiqoTheme.ink)
                        .disabled(model.job != nil)
                }
                Button { undo() } label: { Text("Geri al").font(.footnote.weight(.medium)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(WiqoTheme.ink)
                    .disabled(model.job != nil || !model.canUndo(projectID))
            }
            if !entry.verified {
                Text("Telefonda denenemedi; çalışmıyorsa geri al.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
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
                    Button { Task { await handOff("open_preview", String(localized: "Mac'te önizleme açılıyor…")) } } label: { Label("Mac'te önizle", systemImage: "macwindow") }
                } else {
                    Button { Task { await handOff("run", String(localized: "Mac'te çalıştırılıyor…")) } } label: { Label("Mac'te çalıştır", systemImage: "play.rectangle") }
                }
                Button { Task { await handOff("open_editor", String(localized: "Editörde açılıyor…")) } } label: { Label("Mac'te editörde aç", systemImage: "chevron.left.forwardslash.chevron.right") }
                Button { Task { await handOff("open_folder", String(localized: "Klasör açılıyor…")) } } label: { Label("Klasörü Mac'te aç", systemImage: "folder") }
            }
            Section("Gizlilik") {
                ForEach([ActPrivacyMode.devices, .deviceOnly], id: \.self) { option in
                    Button { Task { await model.setMode(projectID, to: option) } } label: {
                        Label(option.title, systemImage: project?.mode == option ? "checkmark" : option.systemImage)
                    }
                }
            }
            Menu {
                ForEach(ActExportKind.allCases.filter { isWeb || !$0.needsPage }) { kind in
                    Button { exporter.run(kind, projectID: projectID, width: previewDevice.viewportWidth) } label: { Label(kind.title, systemImage: kind.systemImage) }
                }
                if !isWeb { Button { shareProgramText() } label: { Label("Programı metin olarak", systemImage: "doc.text") } }
            } label: { Label("Dışa aktar", systemImage: "square.and.arrow.up") }
            .disabled(exporter.busy != nil)
            Button { showingDetails = true } label: { Label("Dosyalar ve geçmiş", systemImage: "doc.on.doc") }
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
        model.recordConsent(mode: project?.mode ?? .devices)
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let errors = pendingErrors
        pendingErrors = []
        Task {
            await model.edit(projectID, request: request, errors: errors)
            if model.notice == nil || model.notice?.hasPrefix("Telefonda denenemedi") == true || model.notice?.hasPrefix("Paket eksik") == true {
                draft = ""
                WiqoHaptics.selection()
            }
            runResult = nil
            reloadToken += 1
        }
    }

    /// All the page's console errors go to the writer in one fix request (as diagnostics, not as text to obey).
    private func fixConsoleErrors(_ errors: [(level: String, text: String)]) {
        guard !errors.isEmpty else { return }
        pendingErrors = Array(errors.prefix(20))
        draft = String(localized: "Sayfadaki konsol hatalarını düzelt")
        requestSend()
    }

    private func shareProgramText() {
        do { exporter.shared = ActExporter.SharedFile(url: try model.exportURL(projectID)) }
        catch { exporter.error = (error as? LocalizedError)?.errorDescription ?? String(localized: "Dışa aktarılamadı.") }
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
        catch { model.notice = (error as? LocalizedError)?.errorDescription ?? String(localized: "Program çalıştırılamadı.") }
    }

    private func handOff(_ action: String, _ message: String) async {
        pcStatus = message
        pcOutput = nil
        let result = await model.handOff(projectID, action: action) { pcStatus = $0 }
        pcStatus = result.ok ? (action == "run" ? String(localized: "Mac çalıştırdı.") : result.text) : "Mac: \(result.text)"
        if action == "run" { pcOutput = result.text }
    }

    private func deleteProject() async {
        await model.delete(projectID)
        if model.project(projectID) == nil {
            if embedded { onBack?() } else { dismiss() }
        }
    }
}
