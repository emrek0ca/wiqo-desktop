import SwiftUI

struct WiqoActivityView: View {
    @ObservedObject private var model: IOSConnectionModel
    private let focusConfirmationID: UUID?
    @State private var feed: RovaBackendClient.ActivityFeed?
    @State private var error: String?
    @State private var selectedPendingTask: RovaBackendClient.ActivityItem?
    @State private var cancellingTaskID: String?
    @State private var resolvingConfirmationID: UUID?
    @State private var terminalGrantDurations: [UUID: Int] = [:]
    @State private var cancelNotice: String?
    @Environment(\.dismiss) private var dismiss

    init(model: IOSConnectionModel, focusConfirmationID: UUID? = nil) {
        _model = ObservedObject(wrappedValue: model)
        self.focusConfirmationID = focusConfirmationID
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error { Text(error).font(.footnote).foregroundStyle(WiqoTheme.red) }
                    if let feed {
                        if feed.needsAttention.isEmpty && feed.upcoming.isEmpty && feed.recent.prefix(5).isEmpty {
                            VStack(spacing: 12) {
                                WiqoAgentMascot("general", size: 72)
                                Text("Her şey yolunda").font(.headline)
                                Text("Bekleyen bir şey yok. Wiqo bir iş yaptığında ya da senden bir şey istediğinde burada görürsün.")
                                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                        }
                        section(String(localized: "Senin kararını bekleyen"), items: feed.needsAttention)
                        section(String(localized: "Yaklaşan"), items: feed.upcoming)
                        section(String(localized: "Son etkinlik"), items: Array(feed.recent.prefix(5)))
                    } else if error == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(RovaDesign.screenPadding)
            }
            .background(RovaDesign.canvas)
            .task {
                await load()
                scrollToFocusedConfirmation(proxy)
            }
            .refreshable {
                await load()
                scrollToFocusedConfirmation(proxy)
            }
        }
        .navigationTitle("Etkinlik")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if focusConfirmationID != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
        .wiqoConfirmation(
            item: $selectedPendingTask,
            title: { task in
                task.ref?.type == "project" ? "Proje iptal edilsin mi?"
                    : task.ref?.type == "agent_task" ? "Arka plan görevi durdurulsun mu?"
                    : task.ref?.type == "terminal_grant" ? "Terminal oturumu kapatılsın mı?"
                    : String(localized: "PC işi iptal edilsin mi?")
            },
            actions: { item in
                Button(item.ref?.type == "project" ? "Projeyi iptal et"
                    : item.ref?.type == "agent_task" ? "Görevi durdur"
                    : item.ref?.type == "terminal_grant" ? "Oturumu kapat"
                    : "PC işini iptal et", role: .destructive) {
                    Task { await cancelPendingTask(item) }
                }
            },
            message: { item in
                Text(item.ref?.type == "project"
                     ? "Wiqo projeyi durdurur; o ana kadar yapılan kısım teslim edilmez."
                     : item.ref?.type == "agent_task"
                        ? "Wiqo görevi o adımda bırakır; yarım sonuç teslim edilmez."
                     : item.ref?.type == "terminal_grant"
                        ? "Oturum izni hemen kapatılır. PC çevrimdışıysa başlamış bir işin durduğu doğrulanamayabilir."
                        : "PC'ye gönderilmiş bir adımın sonucu belirsiz kalabilir; Wiqo bunu Etkinlik'te gösterecek.")
            }
        )
        .alert("Durum", isPresented: Binding(
            get: { cancelNotice != nil },
            set: { if !$0 { cancelNotice = nil } }
        )) {
            Button("Tamam", role: .cancel) { cancelNotice = nil }
        } message: {
            Text(cancelNotice ?? "")
        }
    }

    /// One group of the feed. A group with nothing in it is not drawn at all: the page shows only what exists.
    @ViewBuilder
    private func section(_ title: String, items: [RovaBackendClient.ActivityItem]) -> some View {
        if !items.isEmpty {
            WiqoSettingsGroup(title: title) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    activityRow(item)
                        .id(item.id)
                        .overlay(alignment: .bottom) {
                            if index < items.count - 1 { Rectangle().fill(WiqoTheme.line).frame(height: 0.5).padding(.leading, 62) }
                        }
                        .overlay {
                            if item.id == "confirmation:\(focusConfirmationID?.uuidString.lowercased() ?? "")" {
                                RoundedRectangle(cornerRadius: 12).stroke(WiqoTheme.orange.opacity(0.6), lineWidth: 1.5).padding(2)
                            }
                        }
                }
            }
        }
    }

    private func stateTint(_ state: String) -> Color {
        switch state {
        case "needs_approval", "needs_review", "waiting_for_pc": WiqoTheme.orange
        case "running", "watching": WiqoTheme.green
        case "failed": WiqoTheme.red
        default: .secondary
        }
    }

    private func activityRow(_ item: RovaBackendClient.ActivityItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let persona = item.persona {
                        WiqoAgentMascot(persona, size: 38, isWorking: item.state == "running")
                    } else {
                        Image(systemName: item.state == "done" ? "checkmark.circle" : item.state == "failed" ? "xmark.circle" : item.state == "scheduled" ? "clock" : "circle.dotted")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(stateTint(item.state))
                            .frame(width: 38, height: 38)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Text(label(for: item.state))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(stateTint(item.state))
                }
                Spacer(minLength: 4)
                if canCancel(item) {
                    Button { selectedPendingTask = item } label: {
                        Text(cancellingTaskID == item.id ? "İptal ediliyor…" : "İptal")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(WiqoTheme.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(WiqoTheme.tint(WiqoTheme.red), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(cancellingTaskID == item.id)
                }
            }
            if item.state == "needs_approval", item.ref?.type == "confirmation", let confirmation = item.confirmation {
                approvalControls(confirmation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func approvalControls(_ confirmation: RovaBackendClient.BackendConfirmation) -> some View {
        let visible = confirmation.details.keys.sorted().filter { !$0.hasPrefix("wiqo") && !(confirmation.details[$0] ?? "").isEmpty }
        VStack(alignment: .leading, spacing: 8) {
            if !visible.isEmpty {
                VStack(spacing: 4) {
                    ForEach(visible, id: \.self) { key in
                        HStack(alignment: .top, spacing: 8) {
                            Text(key).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(confirmation.details[key] ?? "").multilineTextAlignment(.trailing)
                        }
                        .font(.caption)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if confirmation.details["wiqoGrantId"] != nil {
                let duration = terminalGrantDurations[confirmation.id] ?? 0
                Menu {
                    Button("Yalnızca bu görev") { terminalGrantDurations[confirmation.id] = 0 }
                    Button("Bu klasör için 30 dakika") { terminalGrantDurations[confirmation.id] = 1_800 }
                    if (confirmation.details["wiqoGrantMaxSeconds"].flatMap(Int.init) ?? 1_800) > 1_800 {
                        Button("Bu klasör için 8 saat") { terminalGrantDurations[confirmation.id] = 8 * 60 * 60 }
                    }
                } label: {
                    Label("İzin: \(duration == 0 ? "bu görev" : duration > 1_800 ? "8 saat" : "30 dakika")", systemImage: "lock.shield")
                        .font(.caption.weight(.medium))
                }
            }
            HStack(spacing: 10) {
                Button { Task { await resolveConfirmation(confirmation, approved: false) } } label: {
                    Text("Reddet").frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
                Button { Task { await resolveConfirmation(confirmation, approved: true) } } label: {
                    Text(resolvingConfirmationID == confirmation.id ? "İletiliyor…" : "Onayla").frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
            }
            .font(.subheadline.weight(.semibold))
            .disabled(resolvingConfirmationID == confirmation.id)
        }
        .padding(.leading, 50)
    }

    private func label(for state: String) -> String {
        switch state {
        case "needs_approval": return "Onay bekliyor"
        case "needs_review": return "Kontrol gerekli"
        case "waiting_for_pc": return "PC bekleniyor"
        case "running": return "Çalışıyor"
        case "scheduled": return "Zamanlandı"
        case "watching": return "İzleniyor"
        case "done": return "Tamamlandı"
        case "failed": return "Başarısız"
        default: return String(localized: "Sonuç belirsiz")
        }
    }

    private func scrollToFocusedConfirmation(_ proxy: ScrollViewProxy) {
        guard let focusConfirmationID else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo("confirmation:\(focusConfirmationID.uuidString.lowercased())", anchor: .center)
        }
    }

    private func resolveConfirmation(_ confirmation: RovaBackendClient.BackendConfirmation, approved: Bool) async {
        guard resolvingConfirmationID == nil else { return }
        resolvingConfirmationID = confirmation.id
        defer {
            resolvingConfirmationID = nil
            terminalGrantDurations.removeValue(forKey: confirmation.id)
        }
        var terminalGrant: (grantId: String, signature: String)?
        var terminalGrantExpiresAt: Int?
        var terminalGrantScope = "task"
        let details = confirmation.details
        if approved, let grantId = details["wiqoGrantId"] {
            let maximumSeconds = details["wiqoGrantMaxSeconds"].flatMap(Int.init).map { min($0, 8 * 60 * 60) }
            let selectedDuration = terminalGrantDurations[confirmation.id] ?? 0
            if selectedDuration > 0 {
                terminalGrantScope = "session"
                let duration = selectedDuration > 1_800 ? maximumSeconds ?? selectedDuration : selectedDuration
                terminalGrantExpiresAt = Int(Date().timeIntervalSince1970) + duration - 30
            }
            guard let root = details["wiqoGrantRoot"], let mode = details["wiqoGrantMode"],
                  let expiresAt = terminalGrantExpiresAt ?? details["wiqoGrantExpiresAt"].flatMap(Int.init),
                  let signature = model.signTerminalGrant(grantId: grantId, rootDirectory: root, mode: mode, expiresAt: expiresAt, deviceId: details["wiqoGrantDeviceId"]) else {
                cancelNotice = String(localized: "Terminal izni bu telefonda imzalanamadı. PC eşleşmesini kontrol et.")
                return
            }
            terminalGrant = (grantId, signature)
        }
        do {
            _ = try await RovaBackendClient.resolveBackendConfirmation(id: confirmation.id, approved: approved, terminalGrant: terminalGrant, terminalGrantExpiresAt: terminalGrantExpiresAt, terminalGrantScope: terminalGrantScope)
            cancelNotice = approved ? String(localized: "Onaylandı; işlem çalıştırıldı.") : String(localized: "Reddedildi.")
        } catch {
            cancelNotice = (error as? LocalizedError)?.errorDescription ?? String(localized: "Onay iletilemedi.")
        }
        await load()
    }

    private func canCancel(_ item: RovaBackendClient.ActivityItem) -> Bool {
        (item.ref?.type == "pending_task" && ["waiting_for_pc", "running"].contains(item.state))
            || (item.ref?.type == "project" && item.state == "running")
            || (item.ref?.type == "agent_task" && item.state == "running")
            || (item.ref?.type == "terminal_job" && ["waiting_for_pc", "running"].contains(item.state))
            || (item.ref?.type == "terminal_grant" && item.state == "watching")
    }

    private func cancelPendingTask(_ item: RovaBackendClient.ActivityItem) async {
        if item.ref?.type == "project" {
            await cancelProject(item)
            return
        }
        if let reference = item.ref, reference.type == "agent_task", let id = Int(reference.id) {
            cancellingTaskID = item.id
            defer { cancellingTaskID = nil }
            do {
                try await RovaBackendClient.cancelAgentTask(id: id)
                cancelNotice = String(localized: "Arka plan görevi durduruldu.")
            } catch {
                cancelNotice = String(localized: "Görev durdurulamadı; zaten bitmiş olabilir.")
            }
            await load()
            return
        }
        if let reference = item.ref, reference.type == "terminal_grant" {
            cancellingTaskID = item.id
            defer { cancellingTaskID = nil }
            do {
                let result = try await RovaBackendClient.revokeTerminalGrant(id: reference.id)
                cancelNotice = result.unknownJobCount == 0
                    ? String(localized: "Terminal oturumu kapatıldı.")
                    : String(localized: "Terminal oturumu kapatıldı; PC çevrimdışı olduğu için \(result.unknownJobCount) başlamış işin durduğu doğrulanamadı.")
            } catch {
                cancelNotice = String(localized: "Oturum kapatılamadı. Etkinlik'i yenileyip durumu tekrar kontrol et.")
            }
            await load()
            return
        }
        if let reference = item.ref, reference.type == "terminal_job" {
            cancellingTaskID = item.id
            defer { cancellingTaskID = nil }
            do {
                let result = try await RovaBackendClient.cancelTerminalJob(id: reference.id)
                cancelNotice = result.state == "cancelled"
                    ? String(localized: "Terminal işi durduruldu.")
                    : result.state == "completed" || result.state == "failed"
                        ? "Terminal işi zaten \(result.state == "completed" ? "tamamlandı" : "başarısız oldu")."
                        : String(localized: "İşin durduğu doğrulanamadı; sonucu belirsiz olarak Etkinlik'te gösteriliyor.")
            } catch {
                cancelNotice = String(localized: "Terminal işi iptal edilemedi veya sonucu belirsiz. Etkinlik'i yenileyip durumu kontrol et.")
            }
            await load()
            return
        }
        guard let reference = item.ref, reference.type == "pending_task", let id = Int(reference.id), id > 0 else { return }
        cancellingTaskID = item.id
        defer { cancellingTaskID = nil }
        do {
            let result = try await RovaBackendClient.cancelDeferredTask(id: id)
            if result.cancelled == true && result.outcomeUnknown == false {
                cancelNotice = String(localized: "PC işi iptal edildi.")
            } else {
                cancelNotice = String(localized: "Wiqo işi kuyruktan aldı; PC'ye gönderilmiş bir adımın sonucu doğrulanamadı. Etkinlik'teki kontrol uyarısına bak.")
            }
            await load()
        } catch {
            cancelNotice = String(localized: "İptal isteğinin sonucu belirsiz. Etkinlik'i yenileyip PC işinin durumunu kontrol et.")
            await load()
        }
    }

    private func cancelProject(_ item: RovaBackendClient.ActivityItem) async {
        guard let reference = item.ref, let id = Int(reference.id), id > 0 else { return }
        cancellingTaskID = item.id
        defer { cancellingTaskID = nil }
        do {
            _ = try await RovaBackendClient.cancelProject(id: id)
            cancelNotice = String(localized: "Proje iptal edildi.")
        } catch {
            cancelNotice = String(localized: "Proje iptal edilemedi; bitmiş ya da zaten durmuş olabilir. Listeyi yeniledim.")
        }
        await load()
    }

    private func load() async {
        do { feed = try await RovaBackendClient.fetchActivity(); error = nil }
        catch { self.error = String(localized: "Etkinlikler yüklenemedi. Yeniden denemek için aşağı çek.") }
    }
}

/// Wiqo's single settings surface - profile, Mac connection and controls, automations, and
/// account actions all live here (Claude-app style: one scrollable settings screen, no separate
/// "Mac" tab/page). Every control below is unchanged from the previous Mac page; only the
/// container and the account actions' visibility changed.
struct ActivitySheetRoute: Identifiable {
    let id = UUID()
    let focusConfirmationID: UUID?
}
