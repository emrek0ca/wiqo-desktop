import SwiftUI

/// The "Act" tab: where apps, games, pages and programs are made. A description creates a project;
/// every project is a row in the list; opening one keeps all further changes on that project.
struct ActView: View {
    @State private var projects: [RovaBackendClient.CodeProject] = []
    @State private var loaded = false
    @State private var draft = ""
    @State private var creating = false
    @State private var notice: String?
    @State private var opened: OpenedProject?
    @State private var pendingDelete: RovaBackendClient.CodeProject?
    @FocusState private var composerFocused: Bool

    private struct OpenedProject: Hashable { let id: Int }

    private static let suggestions: [(title: String, prompt: String)] = [
        ("Sayaç", "Artır, azalt ve sıfırla butonları olan bir sayaç uygulaması yap"),
        ("Yapılacaklar", "Görev ekleme, silme ve tamamlandı işaretleme olan bir yapılacaklar listesi yap"),
        ("Hafıza oyunu", "4x4 kartlı basit bir hafıza kartı eşleştirme oyunu yap"),
        ("Kişisel site", "Kişisel tanıtım sayfası yap: adım, mesleğim ve iletişim bölümü olsun"),
        ("Python", "Python ile 1'den 100'e kadar asal sayıları yazdıran bir program yap")
    ]

    private var canCreate: Bool { !creating && draft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                composerCard
                projectsSection
            }
            .padding(.horizontal, RovaDesign.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(RovaDesign.canvas)
        .navigationDestination(item: $opened) { project in
            CodeProjectWorkspaceView(projectID: project.id)
        }
        .confirmationDialog("Proje silinsin mi?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible, presenting: pendingDelete) { project in
            Button("\(project.name) projesini sil", role: .destructive) { Task { await delete(project) } }
            Button("Vazgeç", role: .cancel) {}
        } message: { _ in
            Text("Dosyalar ve geçmiş silinir; geri alınamaz.")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Yeni proje

    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ne yapalım?")
                    .font(.title2.weight(.semibold))
                Text("Uygulama, oyun, web sayfası veya Python programı anlat; Wiqo yazsın, denesin, telefonda aç.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField("Örn. günlük su takibi uygulaması", text: $draft, axis: .vertical)
                .lineLimit(2...5)
                .focused($composerFocused)
                .disabled(creating)
                .padding(12)
                .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if draft.isEmpty && !creating {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.suggestions, id: \.title) { suggestion in
                            Button {
                                draft = suggestion.prompt
                                composerFocused = true
                            } label: {
                                Text(suggestion.title)
                                    .font(.footnote.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .frame(height: 32)
                                    .background(WiqoTheme.inset, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Button { Task { await create() } } label: {
                HStack(spacing: 8) {
                    if creating { ProgressView().controlSize(.small).tint(Color(.systemBackground)) }
                    Text(creating ? "Hazırlanıyor… genelde 10–30 sn" : "Oluştur")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.wiqoPill(.accent))
            .disabled(!canCreate)

            if let notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(WiqoTheme.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoCard(radius: 20)
    }

    // MARK: - Liste

    @ViewBuilder private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Projelerim").font(.headline)
                if !projects.isEmpty {
                    Text("\(projects.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(WiqoTheme.inset, in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 4)

            if !loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if projects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Henüz proje yok")
                        .font(.subheadline.weight(.medium))
                    Text("Yukarıya ne istediğini yaz; projen burada listelenir.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                VStack(spacing: 10) {
                    ForEach(projects) { project in
                        Button { opened = OpenedProject(id: project.id) } label: { ProjectRow(project: project) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { opened = OpenedProject(id: project.id) } label: { Label("Aç", systemImage: "arrow.up.right.square") }
                                Button(role: .destructive) { pendingDelete = project } label: { Label("Sil", systemImage: "trash") }
                            }
                    }
                }
            }
        }
    }

    // MARK: - İşlemler

    private func load() async {
        do {
            projects = try await RovaBackendClient.fetchCodeProjects()
            if creating == false { notice = nil }
        } catch {
            if projects.isEmpty { notice = "Projeler yüklenemedi." }
        }
        loaded = true
    }

    private func create() async {
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.count >= 3, !creating else { return }
        creating = true
        notice = nil
        composerFocused = false
        defer { creating = false }
        do {
            let result = try await RovaBackendClient.createCodeProject(request: request)
            draft = ""
            WiqoHaptics.selection()
            await load()
            opened = OpenedProject(id: result.project.id)
        } catch {
            notice = (error as? RovaBackendError)?.errorDescription ?? "Proje oluşturulamadı; biraz sonra tekrar dene."
        }
    }

    private func delete(_ project: RovaBackendClient.CodeProject) async {
        do {
            try await RovaBackendClient.deleteCodeProject(id: project.id)
            projects.removeAll { $0.id == project.id }
        } catch {
            notice = "Proje silinemedi."
        }
    }
}

private struct ProjectRow: View {
    let project: RovaBackendClient.CodeProject

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: project.kind == "web" ? "safari" : "terminal")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(WiqoTheme.ink)
                .frame(width: 40, height: 40)
                .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wiqoCard()
        .contentShape(Rectangle())
    }

    private var caption: String {
        var parts = [project.kind == "web" ? "Web" : "Python", "v\(project.version)"]
        if let when = Self.relative(project.updatedAt) { parts.append(when) }
        if project.share != nil { parts.append("paylaşılıyor") }
        return parts.joined(separator: " · ")
    }

    private static let sqlite: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relative(_ value: String) -> String? {
        guard let date = sqlite.date(from: value) else { return nil }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Proje çalışma alanı

/// One project, full screen: the running page (or the program's output) on top, one input at the
/// bottom. Whatever is typed there changes this project and nothing else.
struct CodeProjectWorkspaceView: View {
    let projectID: Int
    var isModal = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detail: RovaBackendClient.CodeProjectDetail?
    @State private var html: String?
    @State private var runResult: RovaBackendClient.CodeRunResult?
    @State private var draft = ""
    @State private var working = false
    @State private var notice: String?
    @State private var warning: String?
    @State private var reloadToken = 0
    @State private var showingDetails = false
    @State private var confirmingDelete = false
    @FocusState private var focused: Bool

    private var isWeb: Bool { detail?.project.kind != "python" }
    private var canSend: Bool { !working && draft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }
    private var latest: RovaBackendClient.CodeProjectVersion? { detail?.history.first }

    private var chips: [String] {
        isWeb ? ["Koyu tema", "Renkleri değiştir", "Başlığı değiştir", "Daha sade yap"] : ["Çıktıyı düzenle", "Örnek veri ekle", "Daha hızlı yap"]
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
            Divider()
            footer
        }
        .background(RovaDesign.canvas)
        .navigationTitle(detail?.project.name ?? "Proje")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isModal {
                ToolbarItem(placement: .topBarLeading) { Button("Kapat") { dismiss() } }
            }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .sheet(isPresented: $showingDetails, onDismiss: { Task { await load() } }) {
            NavigationStack { CodeProjectDetailView(projectID: projectID) }
        }
        .confirmationDialog("Proje silinsin mi?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Projeyi sil", role: .destructive) { Task { await deleteProject() } }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Dosyalar ve geçmiş silinir; geri alınamaz.")
        }
        .task {
            await RovaBackendClient.openCodeProject(id: projectID)
            await load()
        }
    }

    // MARK: Sahne

    @ViewBuilder private var stage: some View {
        ZStack {
            if detail == nil && notice == nil {
                ProgressView()
            } else if isWeb {
                if let html {
                    WiqoHTMLWebView(
                        html: WiqoHTMLDocument.wrap(html, viewportWidth: WiqoPreviewDevice.phone.viewportWidth, reduceMotion: reduceMotion),
                        projectDataKey: String(projectID),
                        reloadToken: reloadToken
                    )
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(WiqoTheme.lineStrong, lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                } else if notice == nil {
                    ProgressView()
                }
            } else {
                pythonStage
            }
            if working { workingOverlay }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pythonStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Button { Task { await run() } } label: { Label(runResult == nil ? "Çalıştır" : "Tekrar çalıştır", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.wiqoPill(.accent))
                    .disabled(working)
                if let runResult {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Çıktı").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(runResult.stdout.isEmpty ? (runResult.timedOut ? "Program zamanında bitmedi." : "Çıktı yok.") : runResult.stdout)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !runResult.stderr.isEmpty {
                            Text(runResult.stderr)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(WiqoTheme.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                    .wiqoCard()
                } else {
                    Text("Programı çalıştırınca çıktısı burada görünür.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(14)
        }
    }

    private var workingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Değişiklik hazırlanıyor")
                .font(.subheadline.weight(.medium))
            Text("Yazılıyor, denenip doğrulanıyor; genelde 10–30 sn.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .transition(.opacity)
    }

    // MARK: Alt bölüm

    private var footer: some View {
        VStack(spacing: 10) {
            if let notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(WiqoTheme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let latest { changeStrip(latest) }
            if draft.isEmpty && !working {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.self) { chip in
                            Button { draft = chip; focused = true } label: {
                                Text(chip)
                                    .font(.footnote.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .frame(height: 30)
                                    .background(WiqoTheme.inset, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ne değiştirelim?", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .disabled(working)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 38, height: 38)
                        .background(canSend ? WiqoTheme.ink : WiqoTheme.ink.opacity(0.25), in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Değişikliği uygula")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private func changeStrip(_ entry: RovaBackendClient.CodeProjectVersion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(entry.verified ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("v\(entry.version) · \(entry.summary)")
                    .font(.footnote)
                    .lineLimit(2)
                if !entry.verified {
                    Text("Çalışmıyor olabilir; geri al ya da düzeltmesini iste.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Button { Task { await undo() } } label: { Label("Geri al", systemImage: "arrow.uturn.backward").font(.footnote.weight(.medium)) }
                .buttonStyle(.plain)
                .foregroundStyle(WiqoTheme.ink)
                .disabled(working || (detail?.history.count ?? 0) < 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(WiqoTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var menu: some View {
        Menu {
            Button { Task { await undo() } } label: { Label("Son değişikliği geri al", systemImage: "arrow.uturn.backward") }
                .disabled(working || (detail?.history.count ?? 0) < 2)
            if isWeb {
                Button { reloadToken += 1 } label: { Label("Sayfayı yenile", systemImage: "arrow.clockwise") }
            }
            Button { showingDetails = true } label: { Label("Dosyalar, geçmiş, paylaşım", systemImage: "folder") }
            Divider()
            Button(role: .destructive) { confirmingDelete = true } label: { Label("Projeyi sil", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Proje menüsü")
    }

    // MARK: İşlemler

    private func load() async {
        do {
            detail = try await RovaBackendClient.fetchCodeProject(id: projectID)
            if detail?.project.kind == "web" {
                html = try await RovaBackendClient.fetchCodeProjectBundle(id: projectID)
                reloadToken += 1
            }
            notice = nil
        } catch {
            notice = detail == nil ? "Proje yüklenemedi." : "Önizleme açılamadı."
        }
    }

    private func send() async {
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.count >= 2, !working else { return }
        working = true
        notice = nil
        warning = nil
        focused = false
        defer { working = false }
        do {
            let result = try await RovaBackendClient.editCodeProject(id: projectID, request: request)
            draft = ""
            warning = result.verified ? nil : (result.problem ?? "Değişiklik doğrulanamadı.")
            WiqoHaptics.selection()
            runResult = nil
            await load()
        } catch {
            notice = (error as? RovaBackendError)?.errorDescription ?? "Değişiklik uygulanamadı; proje değişmedi."
        }
    }

    private func undo() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            try await RovaBackendClient.undoCodeProject(id: projectID)
            warning = nil
            runResult = nil
            await load()
        } catch {
            notice = "Geri alınacak değişiklik yok."
        }
    }

    private func run() async {
        working = true
        defer { working = false }
        do { runResult = try await RovaBackendClient.runCodeProject(id: projectID) }
        catch { notice = "Program çalıştırılamadı." }
    }

    private func deleteProject() async {
        do {
            try await RovaBackendClient.deleteCodeProject(id: projectID)
            dismiss()
        } catch {
            notice = "Proje silinemedi."
        }
    }
}
