import SwiftUI

struct RootView: View {
    @ObservedObject var model: IOSConnectionModel
    @ObservedObject var authSession: AuthSessionStore

    var body: some View {
        Group {
            if !authSession.isAuthenticated {
                AuthView { authSession.refresh() }
            } else {
                // Chatting with Wiqo never requires a paired Mac - exactly like asking ChatGPT or
                // Gemini a question. Pairing only gates the Mac-specific tools themselves; a
                // device action without a paired Mac simply fails with a clear message instead of
                // blocking the whole app upfront.
                WiqoHomeView(model: model, authSession: authSession)
            }
        }
        .tint(RovaDesign.ink)
        .wiqoToastHost()
        .onChange(of: authSession.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated {
                model.sendBackendTokenIfAvailable()
            } else {
                // A signed-out account must never leave its paired Mac (or anything else
                // device-scoped) reachable to whoever signs in next on this phone - covers every
                // sign-out path (menu button, an expired-token auto sign-out) from one place.
                model.forgetPairing()
            }
        }
        .task {
            // AuthSessionStore can start already authenticated after restoring the saved
            // account. In that case onChange does not fire, so give the paired Mac its current
            // backend session here as well; this is what keeps relay control available after an
            // app or network restart.
            if authSession.isAuthenticated {
                model.sendBackendTokenIfAvailable()
            }
        }
    }
}

private struct WiqoActivityView: View {
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
                VStack(alignment: .leading, spacing: 20) {
                    if let error { Text(error).font(.footnote).foregroundStyle(WiqoTheme.red) }
                    if let feed {
                        section("İlgi bekleyen", items: feed.needsAttention)
                        section("Yaklaşan", items: feed.upcoming)
                        section("Son etkinlik", items: feed.recent)
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
                    : "PC işi iptal edilsin mi?"
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

    private func section(_ title: String, items: [RovaBackendClient.ActivityItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            WiqoSettingsGroup {
                if items.isEmpty {
                    Text("Burada bir şey yok.").font(.subheadline).foregroundStyle(.secondary).padding(16)
                } else {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 10) {
                                if let persona = item.persona {
                                    WiqoAgentMascot(persona, size: 34, isWorking: item.state == "running")
                                }
                                Text(item.title).font(.body.weight(.medium))
                            }
                            if let detail = item.detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                            Text(label(for: item.state)).font(.caption).foregroundStyle(.secondary)
                            if item.state == "needs_approval", item.ref?.type == "confirmation",
                               let confirmation = item.confirmation {
                                ForEach(confirmation.details.keys.sorted().filter { !$0.hasPrefix("wiqo") }, id: \.self) { key in
                                    if let value = confirmation.details[key], !value.isEmpty {
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(key).foregroundStyle(.secondary)
                                            Spacer(minLength: 8)
                                            Text(value).multilineTextAlignment(.trailing)
                                        }
                                        .font(.caption)
                                    }
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
                                    .padding(.top, 4)
                                }
                                HStack {
                                    Spacer()
                                    Button("Reddet") { Task { await resolveConfirmation(confirmation, approved: false) } }
                                        .buttonStyle(.bordered)
                                        .disabled(resolvingConfirmationID == confirmation.id)
                                    Button(resolvingConfirmationID == confirmation.id ? "İletiliyor…" : "Onayla") {
                                        Task { await resolveConfirmation(confirmation, approved: true) }
                                    }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(resolvingConfirmationID == confirmation.id)
                                }
                                .font(.subheadline.weight(.semibold))
                                .padding(.top, 4)
                            }
                            if canCancel(item) {
                                HStack {
                                    Spacer()
                                    Button(cancellingTaskID == item.id ? "İptal ediliyor…" : "İptal") {
                                        selectedPendingTask = item
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .disabled(cancellingTaskID == item.id)
                                }
                                .padding(.top, 4)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .id(item.id)
                        .overlay {
                            if item.id == "confirmation:\(focusConfirmationID?.uuidString.lowercased() ?? "")" {
                                RoundedRectangle(cornerRadius: 16).stroke(RovaDesign.ink.opacity(0.25), lineWidth: 1.5)
                            }
                        }
                    }
                }
            }
        }
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
        default: return "Sonuç belirsiz"
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
                cancelNotice = "Terminal izni bu telefonda imzalanamadı. PC eşleşmesini kontrol et."
                return
            }
            terminalGrant = (grantId, signature)
        }
        do {
            _ = try await RovaBackendClient.resolveBackendConfirmation(id: confirmation.id, approved: approved, terminalGrant: terminalGrant, terminalGrantExpiresAt: terminalGrantExpiresAt, terminalGrantScope: terminalGrantScope)
            cancelNotice = approved ? "Onaylandı; işlem çalıştırıldı." : "Reddedildi."
        } catch {
            cancelNotice = (error as? LocalizedError)?.errorDescription ?? "Onay iletilemedi."
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
                cancelNotice = "Arka plan görevi durduruldu."
            } catch {
                cancelNotice = "Görev durdurulamadı; zaten bitmiş olabilir."
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
                    ? "Terminal oturumu kapatıldı."
                    : "Terminal oturumu kapatıldı; PC çevrimdışı olduğu için \(result.unknownJobCount) başlamış işin durduğu doğrulanamadı."
            } catch {
                cancelNotice = "Oturum kapatılamadı. Etkinlik'i yenileyip durumu tekrar kontrol et."
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
                    ? "Terminal işi durduruldu."
                    : result.state == "completed" || result.state == "failed"
                        ? "Terminal işi zaten \(result.state == "completed" ? "tamamlandı" : "başarısız oldu")."
                        : "İşin durduğu doğrulanamadı; sonucu belirsiz olarak Etkinlik'te gösteriliyor."
            } catch {
                cancelNotice = "Terminal işi iptal edilemedi veya sonucu belirsiz. Etkinlik'i yenileyip durumu kontrol et."
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
                cancelNotice = "PC işi iptal edildi."
            } else {
                cancelNotice = "Wiqo işi kuyruktan aldı; PC'ye gönderilmiş bir adımın sonucu doğrulanamadı. Etkinlik'teki kontrol uyarısına bak."
            }
            await load()
        } catch {
            cancelNotice = "İptal isteğinin sonucu belirsiz. Etkinlik'i yenileyip PC işinin durumunu kontrol et."
            await load()
        }
    }

    private func cancelProject(_ item: RovaBackendClient.ActivityItem) async {
        guard let reference = item.ref, let id = Int(reference.id), id > 0 else { return }
        cancellingTaskID = item.id
        defer { cancellingTaskID = nil }
        do {
            _ = try await RovaBackendClient.cancelProject(id: id)
            cancelNotice = "Proje iptal edildi."
        } catch {
            cancelNotice = "Proje iptal edilemedi; bitmiş ya da zaten durmuş olabilir. Listeyi yeniledim."
        }
        await load()
    }

    private func load() async {
        do { feed = try await RovaBackendClient.fetchActivity(); error = nil }
        catch { self.error = "Etkinlikler yüklenemedi. Yeniden denemek için aşağı çek." }
    }
}

private struct WiqoMemoryView: View {
    @State private var memories: [RovaBackendClient.StoredMemory] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var selected: RovaBackendClient.StoredMemory?
    @State private var confirmAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Wiqo'nun hatırladıklarını burada görebilir ve silebilirsin.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let error { Text(error).font(.footnote).foregroundStyle(WiqoTheme.red) }
                if isLoading { ProgressView().frame(maxWidth: .infinity) }
                else if memories.isEmpty { Text("Kayıtlı hafıza yok.").foregroundStyle(.secondary) }
                else {
                    WiqoSettingsGroup {
                        ForEach(memories) { memory in
                            HStack(alignment: .top, spacing: 12) {
                                Text(memory.content).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                                Button("Sil") { selected = memory }.font(.subheadline)
                            }
                            .padding(16)
                        }
                    }
                    Button("Tüm hafızayı sil", role: .destructive) { confirmAll = true }
                        .font(.subheadline)
                }
            }
            .padding(RovaDesign.screenPadding)
        }
        .background(RovaDesign.canvas)
        .navigationTitle("Hafıza")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .wiqoConfirmation(item: $selected, title: { _ in "Bu hafıza kaydı silinsin mi?" }) { memory in
            Button("Kaydı sil", role: .destructive) { Task { await remove(memory.id) } }
        } message: { _ in EmptyView() }
        .wiqoConfirmation("Tüm hafıza silinsin mi?", isPresented: $confirmAll) {
            Button("Tümünü sil", role: .destructive) { Task { await removeAll() } }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do { memories = try await RovaBackendClient.fetchStoredMemories(); error = nil }
        catch { self.error = "Hafıza yüklenemedi. Yeniden denemek için aşağı çek." }
    }

    private func remove(_ id: Int) async {
        do { try await RovaBackendClient.deleteStoredMemory(id: id); memories.removeAll { $0.id == id }; selected = nil; error = nil }
        catch { self.error = "Kayıt silinemedi. Tekrar dene." }
    }

    private func removeAll() async {
        do { try await RovaBackendClient.deleteAllStoredMemories(); memories = []; error = nil }
        catch { self.error = "Hafıza silinemedi. Tekrar dene." }
    }
}

private struct WiqoGoalsView: View {
    @State private var goals: [RovaBackendClient.RovaGoal] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Hedeflerini sohbette Wiqo'ya söyle. Alt görevler tamamlandıkça ilerleme burada güncellenir.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let error { Text(error).font(.footnote).foregroundStyle(WiqoTheme.red) }
                if isLoading { ProgressView().frame(maxWidth: .infinity) }
                else if goals.isEmpty { Text("Henüz hedef yok.").foregroundStyle(.secondary) }
                else {
                    WiqoSettingsGroup {
                        ForEach(goals) { goal in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(goal.title).font(.body.weight(.medium))
                                ProgressView(value: Double(goal.done), total: Double(max(1, goal.total)))
                                Text("\(goal.done) / \(goal.total) alt görev tamamlandı")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                        }
                    }
                }
            }
            .padding(RovaDesign.screenPadding)
        }
        .background(RovaDesign.canvas)
        .navigationTitle("Hedefler")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do { goals = try await RovaBackendClient.fetchGoals(); error = nil }
        catch { self.error = "Hedefler yüklenemedi. Yeniden denemek için aşağı çek." }
    }
}

/// Wiqo's main surface, ChatGPT-style: opens straight into a new conversation, a top bar (not a
/// bottom tab bar) carries the sidebar toggle, the connection status, and "new chat", and the
/// conversation history lives in a sliding sidebar instead of its own tab.
struct WiqoHomeView: View {
    @ObservedObject var model: IOSConnectionModel
    @ObservedObject var authSession: AuthSessionStore
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var profileStore = ProfileStore()
    @StateObject private var subscriptionStore = SubscriptionStore()
    @State private var conversationID = CopilotConversationStore.newIdentifier()
    @State private var conversations = CopilotConversationStore.all()
    @State private var showSidebar = false
    @State private var showSettings = false
    @State private var showPCSettings = false
    @State private var showTemplates = false
    @State private var showWelcome = false
    @State private var showQuickPairing = false
    @State private var openQuickPairingAfterWelcome = false
    @State private var openFirstCommandAfterPairing = false
    @State private var didCheckWelcome = false
    @State private var draftPrompt: String?
    @State private var pendingActivity: ActivitySheetRoute?

    private enum HomeMode: Hashable { case chat, act }
    @State private var mode: HomeMode = .chat
    private var actHandoffs: NotificationCenter.Publisher { NotificationCenter.default.publisher(for: .wiqoOpenInAct) }
    private var actProjectOpens: NotificationCenter.Publisher { NotificationCenter.default.publisher(for: .wiqoOpenProjectInAct) }

    var body: some View {
        NavigationStack {
            ZStack {
                CopilotView(model: model, authSession: authSession, subscriptionStore: subscriptionStore, conversationID: conversationID, draftPrompt: draftPrompt)
                    .id(conversationID)
                    .opacity(mode == .chat ? 1 : 0)
                    .allowsHitTesting(mode == .chat)
                    .accessibilityHidden(mode != .chat)
                ActView()
                    .onReceive(actHandoffs) { _ in mode = .act }
                    .onReceive(actProjectOpens) { _ in mode = .act }
                    .opacity(mode == .act ? 1 : 0)
                    .allowsHitTesting(mode == .act)
                    .accessibilityHidden(mode != .act)
            }
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        WiqoPillTabs<HomeMode>(
                            options: [
                                WiqoPillTabs<HomeMode>.Option(value: .chat, title: "Chat"),
                                WiqoPillTabs<HomeMode>.Option(value: .act, title: "Act")
                            ],
                            selection: $mode,
                            horizontalPadding: 8
                        )
                        .frame(width: 126)
                        .accessibilityLabel("Chat veya Act")
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismissKeyboard()
                            conversations = CopilotConversationStore.all()
                            withAnimation(.snappy(duration: 0.25)) { showSidebar = true }
                            Task { await refreshConversationsFromServer() }
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .fontWeight(.medium)
                        }
                        .accessibilityLabel("Yan menü")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 16) {
                            Button {
                                dismissKeyboard()
                                showPCSettings = true
                            } label: {
                                RovaConnectionIcon(model: model)
                            }
                            .accessibilityLabel("PC ayarları")
                            if mode == .chat {
                                Menu {
                                    Button { startNewChat() } label: { Label("Yeni sohbet", systemImage: "square.and.pencil") }
                                    Button {
                                        dismissKeyboard()
                                        showTemplates = true
                                    } label: { Label("Otomasyon şablonları", systemImage: "clock.badge") }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .accessibilityLabel("Sohbet eylemleri")
                            }
                        }
                    }
                }
        }
        .task {
            prepareWelcomeIfNeeded()
            model.connect()
            // Three independent requests: waiting for each in turn made the first screen wait for
            // the sum of them instead of the slowest one.
            async let profile: Void = profileStore.refresh()
            async let subscription: Void = subscriptionStore.start()
            async let history: Void = refreshConversationsFromServer()
            _ = await (profile, subscription, history)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.connect()
                Task {
                    await subscriptionStore.storeKit.retryProductsIfNeededOnForeground()
                    await subscriptionStore.refreshIfStale()
                }
            }
        }
        .onChange(of: mode) { _, new in
            dismissKeyboard()
            WiqoOrientation.allowLandscape(new == .act)
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiqoOpenAct)) { _ in
            mode = .act
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiqoOpenConversation)) { note in
            // "Sohbette devam et" from an automation run: close any sheet and open that chat.
            guard let id = note.object as? String, !id.isEmpty else { return }
            showSettings = false
            showPCSettings = false
            draftPrompt = nil
            conversations = CopilotConversationStore.all()
            conversationID = id
            mode = .chat
        }
        .onReceive(NotificationCenter.default.publisher(for: RovaApprovalNotificationRoute.notificationName)) { note in
            let storedID = RovaApprovalNotificationRoute.consume()?.uuidString
            let notificationID = storedID ?? (note.object as? String)
            presentActivity(notificationID)
        }
        .onReceive(NotificationCenter.default.publisher(for: RovaApprovalNotificationRoute.activityNotificationName)) { _ in
            _ = RovaApprovalNotificationRoute.consumeActivity()
            presentActivity(nil)
        }
        .onAppear {
            if let approvalID = RovaApprovalNotificationRoute.consume()?.uuidString {
                presentActivity(approvalID)
            } else if RovaApprovalNotificationRoute.consumeActivity() {
                presentActivity(nil)
            }
        }
        .sheet(isPresented: $showSettings) {
            // General account settings only - PC control lives in its own screen (below), reached
            // from the chat toolbar's connection icon instead of being buried in this list.
            SettingsView(model: model, authSession: authSession, profileStore: profileStore, subscriptionStore: subscriptionStore)
        }
        .sheet(item: $pendingActivity) { route in
            NavigationStack {
                WiqoActivityView(model: model, focusConfirmationID: route.focusConfirmationID)
            }
        }
        .sheet(isPresented: $showPCSettings) {
            PCSettingsView(model: model, subscriptionStore: subscriptionStore)
        }
        .sheet(isPresented: $showQuickPairing, onDismiss: completeQuickPairing) {
            PairingView(model: model, onReady: {
                openFirstCommandAfterPairing = true
                showQuickPairing = false
            }, scanOnAppear: true)
        }
        .sheet(isPresented: $showTemplates) {
            AutomationTemplatesView { prompt in
                showTemplates = false
                conversations = CopilotConversationStore.all()
                draftPrompt = prompt
                conversationID = CopilotConversationStore.newIdentifier()
            }
        }
        .sheet(isPresented: $showWelcome, onDismiss: completeWelcome) {
            WiqoWelcomeView(
                onDismiss: { showWelcome = false },
                onConnect: {
                    openQuickPairingAfterWelcome = true
                    showWelcome = false
                }
            )
        }
        .overlay {
            if showSidebar {
                SidebarOverlay(
                    conversations: conversations,
                    currentID: conversationID,
                    profile: profileStore.profile,
                    avatarImage: profileStore.avatarImage,
                    onSelect: { id in
                        closeSidebar()
                        draftPrompt = nil
                        conversationID = id
                        mode = .chat
                    },
                    onNewChat: {
                        closeSidebar()
                        startNewChat()
                        mode = .chat
                    },
                    onDelete: { id in
                        if id == conversationID { conversationID = CopilotConversationStore.newIdentifier() }
                        CopilotConversationStore.delete(id: id)
                        withAnimation { conversations = CopilotConversationStore.all() }
                        Task { try? await RovaBackendClient.deleteConversationRemote(id: id) }
                    },
                    onDismiss: closeSidebar,
                    onOpenSettings: {
                        closeSidebar()
                        showSettings = true
                    }
                )
                .transition(.opacity)
            }
        }
    }

    private func startNewChat() {
        conversations = CopilotConversationStore.all()
        draftPrompt = nil
        conversationID = CopilotConversationStore.newIdentifier()
    }

    private var welcomeCompletionKey: String? {
        let identity = RovaBackendClient.currentUserID ?? RovaBackendClient.currentUserEmail
        guard let identity, !identity.isEmpty else { return nil }
        return "wiqo.welcome.completed.\(identity)"
    }

    private func prepareWelcomeIfNeeded() {
        guard !didCheckWelcome else { return }
        didCheckWelcome = true
        guard let key = welcomeCompletionKey,
              !UserDefaults.standard.bool(forKey: key),
              !model.isPaired else { return }
        showWelcome = true
    }

    private func completeQuickPairing() {
        guard openFirstCommandAfterPairing else { return }
        openFirstCommandAfterPairing = false
        if let key = welcomeCompletionKey {
            UserDefaults.standard.set(true, forKey: key)
        }
        conversations = CopilotConversationStore.all()
        draftPrompt = "Sesi kıs"
        conversationID = CopilotConversationStore.newIdentifier()
    }

    private func completeWelcome() {
        if openQuickPairingAfterWelcome {
            openQuickPairingAfterWelcome = false
            showQuickPairing = true
            return
        }
        if let key = welcomeCompletionKey {
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    /// Pulls this account's conversation list from the backend and folds it into the local cache -
    /// what brings history back after a reinstall or a new device, since full chat history used to
    /// live only in this device's UserDefaults. Safe to call often: it only ever fetches the cheap
    /// summary list, never full message bodies (those load lazily per-conversation, see
    /// CopilotView.loadRemoteMessagesIfNeeded).
    private func refreshConversationsFromServer() async {
        guard let remote = try? await RovaBackendClient.fetchConversations() else { return }
        conversations = CopilotConversationStore.mergeRemoteSummaries(remote)
    }

    private func closeSidebar() {
        withAnimation(.snappy(duration: 0.22)) { showSidebar = false }
    }

    private func presentActivity(_ value: String?) {
        showSettings = false
        if let value, let confirmationID = UUID(uuidString: value) {
            pendingActivity = ActivitySheetRoute(focusConfirmationID: confirmationID)
        } else if value == nil {
            pendingActivity = ActivitySheetRoute(focusConfirmationID: nil)
        }
    }
}

/// Standard, reliable app-wide keyboard dismissal - works regardless of which field currently
/// holds focus, so the sidebar/settings entry points don't need to know about the chat's own
/// input state.
@MainActor
private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

private struct SidebarOverlay: View {
    let conversations: [CopilotConversationSummary]
    let currentID: String
    let profile: UserProfile
    let avatarImage: UIImage?
    let onSelect: (String) -> Void
    let onNewChat: () -> Void
    let onDelete: (String) -> Void
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void

    @State private var query = ""
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(appeared ? 0.32 : 0)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)

            VStack(alignment: .leading, spacing: 0) {
                header
                searchField
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)

                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: query.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text(query.isEmpty ? "Henüz sohbet yok" : "Sonuç bulunamadı")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                            ForEach(sections, id: \.title) { section in
                                Text(section.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 24)
                                    .padding(.top, 14)
                                    .padding(.bottom, 4)
                                ForEach(section.items) { conversation in
                                    Button { onSelect(conversation.id) } label: {
                                        ConversationRow(conversation: conversation, isSelected: conversation.id == currentID)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) { onDelete(conversation.id) } label: {
                                            Label("Sohbeti sil", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .scrollDismissesKeyboard(.immediately)
                }

                Divider()
                profileRow
            }
            .frame(width: 304, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .offset(x: appeared ? 0 : -320)
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in if value.translation.width < -60 { dismiss() } }
            )
        }
        .onAppear {
            withAnimation(.snappy(duration: 0.25)) { appeared = true }
        }
    }

    private func dismiss() {
        withAnimation(.snappy(duration: 0.2)) { appeared = false }
        let onDismiss = onDismiss
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            onDismiss()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image("WiqoMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
            Text("Wiqo")
                .font(.title3.weight(.bold))
            Spacer()
            Button(action: onNewChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .accessibilityLabel("Yeni sohbet")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Sohbetlerde ara", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var profileRow: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 12) {
                AvatarView(profile: profile, image: avatarImage, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.visibleName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(profile.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profil ve ayarlar")
    }

    private var filtered: [CopilotConversationSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return conversations }
        return conversations.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || $0.preview.localizedCaseInsensitiveContains(needle)
        }
    }

    /// History grouped the way chat apps do: Today, Yesterday, last 7 days, older.
    private var sections: [(title: String, items: [CopilotConversationSummary])] {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        var today: [CopilotConversationSummary] = []
        var yesterday: [CopilotConversationSummary] = []
        var week: [CopilotConversationSummary] = []
        var older: [CopilotConversationSummary] = []
        for conversation in filtered {
            if calendar.isDateInToday(conversation.updatedAt) { today.append(conversation) }
            else if calendar.isDateInYesterday(conversation.updatedAt) { yesterday.append(conversation) }
            else if conversation.updatedAt > weekAgo { week.append(conversation) }
            else { older.append(conversation) }
        }
        return [("Bugün", today), ("Dün", yesterday), ("Son 7 gün", week), ("Daha eski", older)].filter { !$0.1.isEmpty }
    }
}

private struct ConversationRow: View {
    let conversation: CopilotConversationSummary
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(conversation.preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isSelected ? Color(.tertiarySystemFill) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
    }
}

struct PairingView: View {
    @ObservedObject var model: IOSConnectionModel
    var onReady: (() -> Void)? = nil
    var scanOnAppear = false
    @State private var showingScanner = false
    @State private var scanError: String?
    @State private var showingCelebration = false
    // Once ever, not on every re-pair (a lost connection reconnecting, a second Mac being added)
    // - the "show someone" moment only makes sense the very first time this account gets a PC.
    @AppStorage("wiqo.hasSeenPairingCelebration") private var hasSeenPairingCelebration = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                    .wiqoRiseIn()
                Text("PC'ye bağlan")
                    .font(.title2.weight(.semibold))
                    .wiqoRiseIn(delay: 0.08)
                Text("Wiqo PC'de gösterilen QR kodu tara.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .wiqoRiseIn(delay: 0.16)
                Button {
                    showingScanner = true
                } label: {
                    Label("QR tara", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.wiqoPill(.accent))
                .wiqoRiseIn(delay: 0.24)
                if model.isPairing {
                    WiqoStatusLine(text: "PC'yi bağlıyorum…")
                        .font(.subheadline)
                }
                if let error = scanError ?? model.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(WiqoTheme.red)
                        .multilineTextAlignment(.center)
                        .transition(.wiqoBlur)
                }
                Spacer()
            }
            .padding(28)
            .wiqoAnimation(WiqoMotion.slide(), value: model.isPairing)
            .wiqoAnimation(WiqoMotion.slide(), value: scanError ?? model.lastError)
            .navigationTitle("Wiqo")
            .sheet(isPresented: $showingScanner) {
                QRScannerView { value in
                    showingScanner = false
                    do {
                        switch try RovaQRCodec.decodePairingCode(value) {
                        case .local(let payload): model.pair(using: payload)
                        case .relay(let payload): model.pair(using: payload)
                        }
                        scanError = nil
                    } catch {
                        scanError = "Geçersiz Wiqo QR kodu."
                    }
                } onCancel: {
                    showingScanner = false
                }
                .ignoresSafeArea()
            }
        }
        // The scanner sheet already closes itself the instant a code is captured; this is what
        // closes the *outer* "PC'ye bağlan" screen once that scan actually finishes pairing -
        // without it, a successful pairing left the user staring at a screen that had already
        // done its job, with no obvious next step but to swipe it away manually.
        .onChange(of: model.state) { _, state in
            guard model.isPaired, state == .connected else { return }
            if let onReady {
                onReady()
                return
            }
            if hasSeenPairingCelebration {
                dismiss()
            } else {
                hasSeenPairingCelebration = true
                showingCelebration = true
            }
        }
        .onAppear {
            if scanOnAppear && !model.isPaired { showingScanner = true }
        }
        .sheet(isPresented: $showingCelebration, onDismiss: { dismiss() }) {
            PairingCelebrationView()
        }
    }
}

/// A one-time, one-shot "wow" moment right after the very first pairing - the whole product
/// spreads best when someone sees this happen in person, so the app should say so out loud
/// instead of leaving that realization to chance.
private struct PairingCelebrationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            WiqoCheckmark(color: WiqoTheme.green, lineWidth: 5)
                .frame(width: 54, height: 54)
                .padding(20)
                .background(WiqoTheme.tint(WiqoTheme.green), in: Circle())
            Text("PC'n bağlandı!")
                .font(.title2.weight(.bold))
                .wiqoRiseIn(delay: 0.2)
            Text("Şimdi yanındaki birine telefonundan söyle:")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .wiqoRiseIn(delay: 0.3)
            Text("\"Sesi kıs\"")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(WiqoTheme.inset, in: Capsule())
                .wiqoRiseIn(delay: 0.4)
            Text("Wiqo telefonundan gerçekten PC'ni kontrol ediyor - bunu görmek en iyi anlatımdır.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .wiqoRiseIn(delay: 0.5)
            Spacer()
            WiqoActionButton(title: "Harika!") { dismiss() }
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 32)
        .presentationDetents([.medium])
        .onAppear { WiqoHaptics.success() }
    }
}

/// Wiqo's single settings surface - profile, Mac connection and controls, automations, and
/// account actions all live here (Claude-app style: one scrollable settings screen, no separate
/// "Mac" tab/page). Every control below is unchanged from the previous Mac page; only the
/// container and the account actions' visibility changed.
private struct ActivitySheetRoute: Identifiable {
    let id = UUID()
    let focusConfirmationID: UUID?
}

/// Shared plain-row style for a tappable settings-style action (used by both the general and
/// PC-specific settings screens).
private func settingsRow(title: String, systemImage: String, isDestructive: Bool = false) -> some View {
    HStack(spacing: 10) {
        Image(systemName: systemImage).frame(width: 22)
        Text(title).font(.subheadline.weight(.medium))
        Spacer()
    }
    .foregroundStyle(isDestructive ? Color.red : Color.primary)
    .contentShape(Rectangle())
}

/// General account settings only - profile, plan, background tasks/automations, and sign-out.
/// PC pairing/control lives entirely in PCSettingsView (reached from the chat toolbar's
/// connection icon, or from the "PC ayarları" row below) so this screen never needs to load or
/// react to device/connection state at all.
struct SettingsView: View {
    @ObservedObject var model: IOSConnectionModel
    @ObservedObject var authSession: AuthSessionStore
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject var subscriptionStore: SubscriptionStore
    @State private var tasks: [RovaBackendClient.RovaTask] = []
    @State private var automations: [RovaBackendClient.RovaAutomation] = []
    @State private var reviewItems: [RovaBackendClient.AutomationReviewItem] = []
    @State private var taskAutomationError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var oauthProviders: [RovaBackendClient.OAuthProviderInfo] = RovaBackendClient.OAuthProviderInfo.builtIn
    @State private var oauthConnections: [RovaBackendClient.OAuthConnection] = []
    @State private var showingApps = false
    @State private var showingPaywall = false
    @State private var showingSignOutConfirmation = false
    @State private var styleError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    profileCard
                    connectionsGroup
                    styleGroup
                    workGroup
                    supportGroup
                }
                .padding(.horizontal, RovaDesign.screenPadding)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .background(WiqoSettingsStyle.canvas)
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Text("Kapat").font(.body.weight(.medium)) }
                }
            }
            .sheet(isPresented: $showingApps, onDismiss: { Task { await loadConnections() } }) {
                NavigationStack {
                    ConnectedAccountsView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Bitti") { showingApps = false }.fontWeight(.medium)
                            }
                        }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(subscriptionStore: subscriptionStore)
            }
            .wiqoConfirmation("Wiqo hesabından çıkmak istediğine emin misin?", isPresented: $showingSignOutConfirmation) {
                Button("Çıkış yap", role: .destructive) { authSession.signOut(); dismiss() }
            }
        }
        .wiqoToastHost(level: 1)
        .task {
            async let work: Void = loadTasksAndAutomations()
            async let connections: Void = loadConnections()
            async let plan: Void = subscriptionStore.refreshIfStale(maxAge: 60)
            _ = await (work, connections, plan)
        }
    }

    // MARK: Profile and plan

    private var profileCard: some View {
        let info = subscriptionStore.info
        return VStack(spacing: 12) {
            NavigationLink {
                AccountSettingsView(profileStore: profileStore, authSession: authSession, subscriptionStore: subscriptionStore)
            } label: {
                HStack(spacing: 12) {
                    AvatarView(profile: profileStore.profile, image: profileStore.avatarImage, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profileStore.profile.visibleName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(profileStore.profile.email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(info.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(WiqoTheme.tint(Color.accentColor), in: Capsule())
                    WiqoChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 14) {
                compactUsage("Mesaj", info.usage.messages)
                compactUsage("Görsel", info.usage.images)
                if info.tier == "free" {
                    Button("Yükselt") { showingPaywall = true }
                        .buttonStyle(.wiqoPill(.accent))
                }
            }
        }
        .padding(14)
        .wiqoGlass()
    }

    private func compactUsage(_ title: String, _ counter: SubscriptionInfo.UsageCounter) -> some View {
        let ratio = counter.limit > 0 ? min(1, Double(counter.used) / Double(counter.limit)) : 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(counter.used)/\(counter.limit)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: ratio)
                .tint(ratio > 0.85 ? WiqoTheme.orange : Color.accentColor)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bugünkü \(title.lowercased()) kullanımı \(counter.used) / \(counter.limit)")
    }

    // MARK: Connections

    private var connectionsGroup: some View {
        WiqoSettingsGroup(title: "Bağlantılar") {
            NavigationLink {
                PCSettingsView(model: model, subscriptionStore: subscriptionStore)
            } label: {
                WiqoRow(systemImage: "laptopcomputer", title: "PC", showsDivider: true) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.isPaired && model.userFacingConnectionLabel != "PC kapalı" ? WiqoTheme.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(model.isPaired ? model.userFacingConnectionLabel : "Bağla")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        WiqoChevron()
                    }
                }
            }
            .buttonStyle(WiqoRowButtonStyle())

            Button { showingApps = true } label: {
                WiqoRow(systemImage: "square.grid.2x2", title: "Uygulamalar", showsDivider: false) {
                    HStack(spacing: 6) {
                        if appsNeedingReconnect > 0 {
                            Text("Yeniden bağla")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(WiqoTheme.red)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(WiqoTheme.tint(WiqoTheme.red), in: Capsule())
                        } else {
                            Text(appsSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        WiqoChevron()
                    }
                }
            }
            .buttonStyle(WiqoRowButtonStyle())
        }
    }

    private var appsNeedingReconnect: Int {
        oauthConnections.filter { $0.status == "needs_reconnect" }.count
    }

    private var appsSummary: String {
        let connected = oauthConnections.count
        let names = oauthProviders.filter { provider in oauthConnections.contains { $0.provider == provider.id } }.map(\.name)
        if connected == 0 { return "\(oauthProviders.count) uygulama" }
        return names.count <= 2 ? names.joined(separator: ", ") : "\(connected) bağlı"
    }

    private func loadConnections() async {
        async let providers = RovaBackendClient.fetchOAuthProviders()
        async let connections = try? RovaBackendClient.fetchOAuthConnections()
        oauthProviders = await providers
        oauthConnections = (await connections) ?? oauthConnections
    }

    // MARK: Style (saved as it changes)

    private var styleGroup: some View {
        WiqoSettingsGroup(title: "Wiqo'nun tarzı") {
            WiqoRow(systemImage: "text.bubble", title: "Yanıt tonu", showsDivider: true) {
                Picker("Yanıt tonu", selection: styleBinding(\.tone, key: "tone")) {
                    Text("Varsayılan").tag(String?.none)
                    Text("Samimi").tag(String?.some("samimi"))
                    Text("Profesyonel").tag(String?.some("profesyonel"))
                    Text("Kısa ve öz").tag(String?.some("kisa"))
                    Text("Detaylı").tag(String?.some("detayli"))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.secondary)
            }
            WiqoRow(systemImage: "globe", title: "Yanıt dili", showsDivider: true) {
                Picker("Yanıt dili", selection: styleBinding(\.language, key: "language")) {
                    Text("Otomatik").tag(String?.none)
                    Text("Türkçe").tag(String?.some("tr"))
                    Text("English").tag(String?.some("en"))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.secondary)
            }
            WiqoRow(systemImage: "lightbulb", title: "Proaktif öneriler", showsDivider: false) {
                Toggle("Proaktif öneriler", isOn: Binding(
                    get: { profileStore.profile.proactiveEnabled },
                    set: { value in saveStyle(["proactiveEnabled": value]) }
                ))
                .labelsHidden()
            }
            if let styleError {
                Text(styleError)
                    .font(.caption)
                    .foregroundStyle(WiqoTheme.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func styleBinding(_ keyPath: KeyPath<UserProfile, String?>, key: String) -> Binding<String?> {
        Binding(
            get: { profileStore.profile[keyPath: keyPath] },
            set: { value in saveStyle([key: value ?? NSNull()]) }
        )
    }

    private func saveStyle(_ changes: [String: Any]) {
        Task {
            do {
                try await profileStore.update(changes)
                styleError = nil
                UISelectionFeedbackGenerator().selectionChanged()
            } catch {
                styleError = "Kaydedilemedi. Bağlantını kontrol edip tekrar dene."
            }
        }
    }

    // MARK: Wiqo's work

    private var workGroup: some View {
        WiqoSettingsGroup(title: "Wiqo'nun işleri") {
            NavigationLink { WiqoMemoryView() } label: {
                WiqoRow(systemImage: "brain.head.profile", title: "Hafıza", showsDivider: true)
            }
            .buttonStyle(WiqoRowButtonStyle())
            NavigationLink { tasksSettingsPage } label: {
                WiqoRow(systemImage: "checklist", title: "Görevler ve otomasyonlar", showsDivider: true) {
                    HStack(spacing: 6) {
                        Text(taskNavigationValue).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        WiqoChevron()
                    }
                }
            }
            .buttonStyle(WiqoRowButtonStyle())
            NavigationLink { WiqoGoalsView() } label: {
                WiqoRow(systemImage: "target", title: "Hedefler", showsDivider: true)
            }
            .buttonStyle(WiqoRowButtonStyle())
            NavigationLink { WiqoActivityView(model: model) } label: {
                WiqoRow(systemImage: "clock.arrow.circlepath", title: "Etkinlik", showsDivider: false)
            }
            .buttonStyle(WiqoRowButtonStyle())
        }
    }

    private var taskNavigationValue: String {
        if !reviewItems.isEmpty { return "İncele" }
        if !activeAutomations.isEmpty { return "\(activeAutomations.count) aktif" }
        return pendingTasks.isEmpty ? "" : "\(pendingTasks.count) bekliyor"
    }

    // MARK: Support and sign-out

    private var supportGroup: some View {
        WiqoSettingsGroup {
            NavigationLink { legalPage } label: {
                WiqoRow(systemImage: "questionmark.circle", title: "Destek ve yasal", showsDivider: true)
            }
            .buttonStyle(WiqoRowButtonStyle())
            Button { showingSignOutConfirmation = true } label: {
                WiqoRow(systemImage: "rectangle.portrait.and.arrow.right", title: "Çıkış yap", isDestructive: true, showsDivider: false) { EmptyView() }
            }
            .buttonStyle(WiqoRowButtonStyle())
        }
    }

    private var tasksSettingsPage: some View {
        ScrollView {
            VStack(spacing: 18) {
                if taskAutomationError != nil || !pendingTasks.isEmpty || !activeAutomations.isEmpty || !reviewItems.isEmpty {
                    tasksAutomationsSection
                } else {
                    ContentUnavailableView("Görev yok", systemImage: "checklist")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(RovaDesign.screenPadding)
        }
        .background(WiqoSettingsStyle.canvas)
        .navigationTitle("Görevler ve otomasyonlar")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var legalPage: some View {
        ScrollView {
            legalSection
                .padding(RovaDesign.screenPadding)
        }
        .background(WiqoSettingsStyle.canvas)
        .navigationTitle("Destek ve yasal")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Tasks and automations

    private var pendingTasks: [RovaBackendClient.RovaTask] {
        tasks.filter { $0.status == "pending" }
    }

    private var activeAutomations: [RovaBackendClient.RovaAutomation] {
        automations.filter(\.isActive)
    }

    private var tasksAutomationsSection: some View {
        WiqoSettingsGroup(title: "Görevler ve otomasyonlar") {
            NavigationLink {
                AgentTasksView()
            } label: {
                WiqoRow(systemImage: "point.3.connected.trianglepath.dotted", title: "Arka plan görevleri", subtitle: "Çalışan ve biten uzun işler", showsDivider: true) { EmptyView() }
            }
            .buttonStyle(WiqoRowButtonStyle())
            NavigationLink {
                NamedAgentsView()
            } label: {
                WiqoRow(systemImage: "person.2.circle", title: "Ajanlarım", subtitle: "Rol, rutin ve hafıza", showsDivider: true) { EmptyView() }
            }
            .buttonStyle(WiqoRowButtonStyle())
            if let taskAutomationError {
                Text(taskAutomationError)
                    .font(.footnote)
                    .foregroundStyle(WiqoTheme.red)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(pendingTasks) { task in
                WiqoRow(
                    systemImage: "circle",
                    tint: .secondary,
                    title: task.title,
                    showsDivider: !activeAutomations.isEmpty || task.id != pendingTasks.last?.id
                ) { EmptyView() }
            }
            ForEach(activeAutomations) { automation in
                HStack(spacing: 0) {
                    NavigationLink {
                        AutomationDetailView(automation: automation)
                    } label: {
                        WiqoRow(
                            systemImage: "clock.arrow.circlepath",
                            title: automation.prompt,
                            subtitle: automation.cron,
                            showsDivider: false
                        ) { EmptyView() }
                    }
                    .buttonStyle(WiqoRowButtonStyle())
                    Button {
                        Task { await cancel(automation) }
                    } label: {
                        Menu {
                            Button("Şimdi çalıştır") {
                                Task { await runNow(automation) }
                            }
                            Button("Duraklat") {
                                Task { await pause(automation) }
                            }
                            Button("İptal et", role: .destructive) {
                                Task { await cancel(automation) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Otomasyon seçenekleri")
                }
                .overlay(alignment: .bottom) {
                    if automation.id != activeAutomations.last?.id {
                        Rectangle().fill(WiqoTheme.line).frame(height: 0.5).padding(.leading, 56)
                    }
                }
            }
            ForEach(reviewItems) { item in
                reviewRow(item, showsDivider: item.id != reviewItems.last?.id)
            }
        }
    }

    private func reviewRow(_ item: RovaBackendClient.AutomationReviewItem, showsDivider: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: item.status == "needs_attention" ? "exclamationmark.circle" : "clock")
                    .foregroundStyle(item.status == "needs_attention" ? WiqoTheme.orange : .secondary)
                    .frame(width: 22)
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Menu {
                    if item.status == "needs_attention" {
                        Button("Tamamlandı") { Task { await resolve(item, as: "completed") } }
                        Button("Başarısız") { Task { await resolve(item, as: "failed") } }
                    } else {
                        Button("Tekrar dene") { Task { await retry(item) } }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
            }
            if let message = item.error ?? item.reply, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(WiqoTheme.line).frame(height: 0.5).padding(.leading, 46) }
        }
    }

    private func cancel(_ automation: RovaBackendClient.RovaAutomation) async {
        do {
            try await RovaBackendClient.cancelAutomation(id: automation.id)
            await loadTasksAndAutomations()
            WiqoToastCenter.shared.show("Otomasyon iptal edildi", kind: .success)
        } catch {
            taskAutomationError = (error as? LocalizedError)?.errorDescription ?? "Otomasyon iptal edilemedi."
        }
    }

    private func runNow(_ automation: RovaBackendClient.RovaAutomation) async {
        do {
            _ = try await RovaBackendClient.runAutomationNow(id: automation.id)
            await loadTasksAndAutomations()
            WiqoToastCenter.shared.show("Çalıştırıyorum", kind: .success)
        } catch {
            taskAutomationError = (error as? LocalizedError)?.errorDescription ?? "Otomasyon başlatılamadı."
        }
    }

    private func pause(_ automation: RovaBackendClient.RovaAutomation) async {
        do {
            _ = try await RovaBackendClient.pauseAutomation(id: automation.id)
            await loadTasksAndAutomations()
            WiqoToastCenter.shared.show("Otomasyon duraklatıldı", kind: .success)
        } catch {
            taskAutomationError = (error as? LocalizedError)?.errorDescription ?? "Otomasyon duraklatılamadı."
        }
    }

    // MARK: Legal and account

    /// App Store Connect's Support URL is required to actually resolve to something useful, and
    /// Guideline 5.1.1 expects the same legal documents referenced at signup/purchase to also be
    /// reachable from within the app proper - not just at the point of purchase.
    private var legalSection: some View {
        WiqoSettingsGroup(title: "Yasal ve destek") {
            legalRow("Gizlilik Politikası", systemImage: "hand.raised", url: WiqoWebsite.privacyPolicyURL)
            legalRow("Kullanım Şartları", systemImage: "doc.text", url: WiqoWebsite.termsOfServiceURL)
            legalRow("Destek", systemImage: "questionmark.circle", url: WiqoWebsite.supportURL, showsDivider: false)
        }
    }

    private func legalRow(_ title: String, systemImage: String, url: URL, showsDivider: Bool = true) -> some View {
        Button { openURL(url) } label: {
            WiqoRow(systemImage: systemImage, title: title, showsDivider: showsDivider) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WiqoTheme.ink3)
            }
        }
        .buttonStyle(WiqoRowButtonStyle())
    }

    private func loadTasksAndAutomations() async {
        do {
            async let fetchedTasks = RovaBackendClient.fetchTasks()
            async let fetchedAutomations = RovaBackendClient.fetchAutomations()
            async let fetchedReview = RovaBackendClient.fetchAutomationReview()
            tasks = try await fetchedTasks
            automations = try await fetchedAutomations
            reviewItems = (try? await fetchedReview) ?? []
            taskAutomationError = nil
        } catch {
            taskAutomationError = (error as? LocalizedError)?.errorDescription ?? "Görev ve otomasyonlar yüklenemedi."
        }
    }

    private func retry(_ item: RovaBackendClient.AutomationReviewItem) async {
        do {
            _ = try await RovaBackendClient.retryAutomationRun(automationID: item.automationId, runID: item.runId)
            await loadTasksAndAutomations()
            WiqoToastCenter.shared.show("Tekrar deniyorum", kind: .success)
        } catch {
            taskAutomationError = (error as? LocalizedError)?.errorDescription ?? "Tekrar denenemedi."
        }
    }

    private func resolve(_ item: RovaBackendClient.AutomationReviewItem, as resolution: String) async {
        do {
            _ = try await RovaBackendClient.resolveUnknownAutomationRun(automationID: item.automationId, runID: item.runId, resolution: resolution)
            await loadTasksAndAutomations()
            WiqoToastCenter.shared.show("Kaydedildi", kind: .success)
        } catch {
            taskAutomationError = (error as? LocalizedError)?.errorDescription ?? "Sonuç kaydedilemedi."
        }
    }
}

/// Everything about the paired Mac: pairing, live status, quick actions, media/display, apps,
/// clipboard/URL, trust grants, and connection activity. Reached either from the chat toolbar's
/// connection icon or from the "PC ayarları" row in general Settings - kept as its own screen so
/// PC control reads as one dedicated surface instead of being buried in a long general list, and
/// so PC connection state/polling never has to be set up just to open general Settings.
struct PCSettingsView: View {
    @ObservedObject var model: IOSConnectionModel
    @ObservedObject var subscriptionStore: SubscriptionStore
    @State private var showingLockConfirmation = false
    @State private var showingSleepConfirmation = false
    @State private var showingDisplaySleepConfirmation = false
    @State private var showingForgetMacConfirmation = false
    @State private var showingPairing = false
    @State private var showingPaywall = false
    @State private var volume: Double = 50
    @State private var brightness: Double = 80
    @State private var urlText = ""
    @State private var clipboardText = ""
    @State private var backendDevices: [RovaBackendClient.DeviceStatus] = []
    @State private var deletingDeviceID: String?
    @State private var renamingDeviceID: String?
    @State private var renameText = ""
    @State private var trustGrants: [RovaBackendClient.TrustGrant] = []
    /// Remote control and PC settings are two different jobs: one tab each, instead of one long page with a "Gelişmiş" fold.
    @State private var pcTab: PCTab = .control
    private enum PCTab: Hashable { case control, settings }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private var availableApps: [ApplicationInfo] {
        model.deviceInfo?.availableApplications ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: RovaDesign.cardSpacing) {
                    if subscriptionStore.info.pcAllowed {
                        if model.isPaired {
                            statusCard
                            Picker("Bölüm", selection: $pcTab) {
                                Text("Kontrol").tag(PCTab.control)
                                Text("Ayarlar").tag(PCTab.settings)
                            }
                            .pickerStyle(.segmented)
                            if pcTab == .control {
                                quickActionsCard
                                mediaCard
                                displayCard
                                appsCard
                                clipboardCard
                                urlCard
                            } else {
                                if !backendDevices.isEmpty { devicesCard }
                                capabilitiesCard
                                connectionActionsCard
                                if !trustGrants.isEmpty { trustGrantsCard }
                                activityCard
                            }
                            if let error = model.lastError { errorCard(error) }
                        } else {
                            pairingPromptCard
                        }
                    } else {
                        pcUpsellCard
                    }
                }
                .padding(RovaDesign.screenPadding)
            }
            .background(WiqoSettingsStyle.canvas)
            .navigationTitle("PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Text("Kapat").font(.body.weight(.medium)) }
                }
            }
            .sheet(isPresented: $showingPairing) {
                PairingView(model: model)
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(subscriptionStore: subscriptionStore)
            }
        }
        .task {
            model.connect()
            await loadDevicesAndTrust()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.connect()
                Task { await loadDevicesAndTrust() }
            }
        }
        .onChange(of: model.systemStatus) { _, status in
            if let level = status?.volumePercentage { volume = Double(level) }
            if let level = status?.brightnessPercentage { brightness = Double(level) }
        }
    }

    /// Shown instead of every other card when the current plan doesn't include PC access (Free) -
    /// the backend already refuses to hand the model any PC tools for these accounts (see
    /// rova-backend's ToolRegistry.forRequest), so this is purely about not showing controls that
    /// would just fail or mislead.
    private var pcUpsellCard: some View {
        RovaCard {
            HStack(spacing: 14) {
                Image(systemName: "lock.laptopcomputer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PC bağlantısı").font(.subheadline.weight(.semibold))
                    Text("PC'ni kontrol edebilmek için Pro veya Business'a geç.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Yükselt") { showingPaywall = true }
                    .buttonStyle(.wiqoPill(.accent))
            }
        }
    }

    private var connectionActionsCard: some View {
        RovaCard {
            Text("Bağlantı").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Button {
                Task { _ = await model.send(.ping) }
            } label: {
                settingsRow(title: "Bağlantıyı ölç", systemImage: "waveform.path.ecg")
            }
            Button {
                Task { _ = await model.send(.getSystemStatus) }
            } label: {
                settingsRow(title: "Durumu yenile", systemImage: "arrow.clockwise")
            }
            Divider()
            Button(role: .destructive) {
                showingForgetMacConfirmation = true
            } label: {
                settingsRow(title: "PC'yi unut", systemImage: "laptopcomputer.slash", isDestructive: true)
            }
        }
        .wiqoConfirmation("PC'yi unutmak istediğine emin misin?", isPresented: $showingForgetMacConfirmation) {
            Button("PC'yi unut", role: .destructive) { model.forgetPairing(); dismiss() }
        }
    }

    // MARK: - Cards

    private var devicesCard: some View {
        RovaCard {
            Label("Bağlı cihazlar", systemImage: "rectangle.3.group")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(backendDevices) { device in
                Button {
                    renameText = device.displayName
                    renamingDeviceID = device.id
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: device.online ? "circle.fill" : "circle")
                            .foregroundStyle(device.online ? .green : .secondary)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.displayName).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            Text("\(displayPlatformName(device.platform)) • \(device.capabilities.count) yetenek")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(device.online ? "Bağlı" : "Çevrimdışı")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(device.online ? .green : .secondary)
                        Image(systemName: "pencil")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        deletingDeviceID = device.id
                    } label: {
                        Label("Sil", systemImage: "trash")
                    }
                }
            }
            if backendDevices.count > 1 {
                Text("Birden fazla PC'n varsa isim vererek ayırt edebilirsin (\"Ofis PC\" gibi).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("PC'yi yeniden adlandır", isPresented: Binding(
            get: { renamingDeviceID != nil },
            set: { if !$0 { renamingDeviceID = nil } }
        )) {
            TextField("Örn. Ofis PC", text: $renameText)
            Button("Kaydet") {
                guard let id = renamingDeviceID else { return }
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    if let updated = try? await RovaBackendClient.renameDevice(id: id, name: name.isEmpty ? nil : name) {
                        if let index = backendDevices.firstIndex(where: { $0.id == id }) { backendDevices[index] = updated }
                    }
                }
            }
            Button("Vazgeç", role: .cancel) {}
        }
        .wiqoConfirmation(item: $deletingDeviceID, title: { _ in "Bu cihazı listeden kaldırmak istediğine emin misin?" }) { id in
            Button("Cihazı sil", role: .destructive) {
                backendDevices.removeAll { $0.id == id }
                Task { try? await RovaBackendClient.deleteDevice(id: id) }
            }
        } message: { _ in EmptyView() }
    }

    /// A live status view of what Wiqo can actually do on this Mac right now - answers "neden
    /// çalışmıyor" without needing to guess or wait for a failed attempt first.
    private var capabilitiesCard: some View {
        NavigationLink {
            DeviceCapabilitiesView(authorities: model.deviceInfo?.authorities ?? [])
        } label: {
            RovaCard {
                HStack(spacing: 14) {
                    Image(systemName: "checklist")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PC Yetenekleri").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text("PC'nde nelerin hazır olduğunu gör").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var pairingPromptCard: some View {
        RovaCard {
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PC ekle").font(.subheadline.weight(.semibold))
                    Text("PC'ni QR kodu okutarak bağla.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Bağla") { showingPairing = true }
                    .buttonStyle(.wiqoPill(.accent))
            }
        }
    }

    private var statusCard: some View {
        RovaCard {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.deviceInfo?.displayName ?? "PC").font(.headline)
                    HStack(spacing: 6) {
                        Text(statusText).font(.subheadline).foregroundStyle(statusColor)
                    }
                }
                Spacer()
                if model.state == .connecting { ProgressView() }
            }
            if model.state != .connected {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.isReconnecting ? "Bağlantıyı yeniden kuruyorum…" : model.userFacingConnectionError)
                            .font(.caption.weight(.medium))
                    }
                    Spacer(minLength: 8)
                    if !model.isReconnecting {
                        Button("Tekrar dene") {
                            model.retry()
                        }
                        .buttonStyle(.wiqoPill(.secondary))
                    }
                }
            }
            if let status = model.systemStatus {
                Divider()
                HStack {
                    Label("PC · \(status.macOSVersion)", systemImage: "desktopcomputer")
                    Spacer()
                    if let battery = status.batteryPercentage {
                        Label("\(battery)%\(status.isCharging == true ? " ⚡︎" : "")", systemImage: "battery.100")
                    }
                    Spacer()
                    Label(formatUptime(status.uptimeSeconds), systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var quickActionsCard: some View {
        RovaCard {
            Text("Hızlı Eylemler").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    RovaActionTile(title: "Kilitle", systemImage: "lock.fill", isDestructive: true) {
                        showingLockConfirmation = true
                    }
                    RovaActionTile(title: "Uyku", systemImage: "moon.fill", isDestructive: true) {
                        showingSleepConfirmation = true
                    }
                    RovaActionTile(title: "Ekran Uyut", systemImage: "display", isDestructive: true) {
                        showingDisplaySleepConfirmation = true
                    }
                    RovaActionTile(title: "Geri", systemImage: "backward.fill") {
                        hapticImpact(); Task { _ = await model.mediaControl(.previousTrack) }
                    }
                    RovaActionTile(title: "Oynat/Duraklat", systemImage: "playpause.fill") {
                        hapticImpact(); Task { _ = await model.mediaControl(.playPause) }
                    }
                    RovaActionTile(title: "İleri", systemImage: "forward.fill") {
                        hapticImpact(); Task { _ = await model.mediaControl(.nextTrack) }
                    }
                    RovaActionTile(title: "Sessiz", systemImage: "speaker.slash.fill") {
                        hapticImpact(); Task { _ = await model.toggleMute() }
                    }
                }
            }
            .disabled(model.state != .connected)
        }
        .wiqoConfirmation("PC kilitlenecek. Devam et?", isPresented: $showingLockConfirmation) {
            Button("PC'yi kilitle", role: .destructive) {
                hapticImpact()
                Task {
                    let ok = await model.authenticateBiometrics(reason: "PC'yi kilitlemek için kimliğinizi doğrulayın")
                    if ok { _ = await model.send(.lockMac) }
                }
            }
        }
        .wiqoConfirmation("PC uyku moduna alınacak. Devam et?", isPresented: $showingSleepConfirmation) {
            Button("PC'yi uyut", role: .destructive) {
                hapticImpact()
                Task {
                    let ok = await model.authenticateBiometrics(reason: "PC'yi uykuya almak için kimliğinizi doğrulayın")
                    if ok { _ = await model.sleepMac() }
                }
            }
        }
        .wiqoConfirmation("PC ekranı uyutulacak. Devam et?", isPresented: $showingDisplaySleepConfirmation) {
            Button("Ekranı uyut", role: .destructive) {
                hapticImpact()
                Task { _ = await model.displaySleep() }
            }
        }
    }

    private var mediaCard: some View {
        RovaCard {
            Text("Ses").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.1.fill").foregroundStyle(.secondary)
                Slider(value: $volume, in: 0...100, step: 5) { editing in
                    if !editing {
                        hapticImpact()
                        Task { _ = await model.setVolume(Int(volume)) }
                    }
                }
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            .disabled(model.state != .connected)
        }
    }

    private var displayCard: some View {
        RovaCard {
            Text("Parlaklık").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: "sun.min.fill").foregroundStyle(.secondary)
                Slider(value: $brightness, in: 0...100, step: 5) { editing in
                    if !editing {
                        hapticImpact()
                        Task { _ = await model.setBrightness(Int(brightness)) }
                    }
                }
                Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
            }
            .disabled(model.state != .connected)
        }
    }

    private var appsCard: some View {
        RovaCard {
            Text("Uygulamalar").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(availableApps) { app in
                        RovaActionTile(title: app.name, systemImage: icon(for: app.id)) {
                            hapticImpact()
                            Task { _ = await model.send(.openApplication, payload: .application(app.id)) }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { _ = await model.quitApplication(app.id) }
                            } label: {
                                Label("Kapat", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }
            .disabled(model.state != .connected)
            if !availableApps.isEmpty {
                Text("Kapatmak için basılı tut").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var clipboardCard: some View {
        RovaCard {
            Text("Pano").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                TextField("Metin yapıştır veya yaz…", text: $clipboardText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    guard !clipboardText.isEmpty else { return }
                    hapticImpact()
                    Task {
                        _ = await model.setClipboardText(clipboardText)
                        clipboardText = ""
                        hapticNotification(.success)
                    }
                } label: {
                    Image(systemName: "arrow.up.doc.fill")
                }
                .buttonStyle(.wiqoPill(.accent))
                .disabled(clipboardText.isEmpty || model.state != .connected)
            }
        }
    }

    private var urlCard: some View {
        RovaCard {
            Text("URL Aç").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            TextField("youtube.com", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit(openTypedURL)
            if let resolved = normalizedURL(from: urlText), resolved.absoluteString != urlText {
                Text(resolved.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Aç", action: openTypedURL)
                .disabled(model.state != .connected || normalizedURL(from: urlText) == nil)
        }
    }

    /// Turns free-form input ("youtube", "youtube.com", "https://youtube.com/watch?v=…") into a
    /// URL the Mac will actually accept - RovaValidation.isAllowedURL (the same check the Mac
    /// re-applies on its side) requires an explicit http/https scheme and a real host, so a bare
    /// word gets ".com" appended and a missing scheme gets "https://" prepended, the way a
    /// browser's own address bar completes a typed site name. Returns nil for anything that still
    /// can't resolve to a valid URL, which is what disables the "Aç" button.
    private func normalizedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var candidate = trimmed
        if !candidate.lowercased().hasPrefix("http://"), !candidate.lowercased().hasPrefix("https://") {
            candidate = "https://" + candidate
        }
        guard var components = URLComponents(string: candidate), let host = components.host, !host.isEmpty else { return nil }
        if !host.contains(".") {
            components.host = host + ".com"
        }
        guard let url = components.url, RovaValidation.isAllowedURL(url.absoluteString) else { return nil }
        return url
    }

    private func openTypedURL() {
        guard let resolved = normalizedURL(from: urlText) else { return }
        hapticImpact()
        Task { _ = await model.send(.openURL, payload: .url(resolved.absoluteString)) }
    }

    private var trustGrantsCard: some View {
        RovaCard {
            Text("Onaylı Eylemler").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text("Wiqo bunları daha önce onayladığın için artık sormadan yapıyor.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(trustGrants) { grant in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(grant.label).font(.subheadline)
                        Text(grant.grantedAt).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button {
                        Task {
                            try? await RovaBackendClient.revokeTrustGrant(id: grant.id)
                            trustGrants.removeAll { $0.id == grant.id }
                        }
                    } label: {
                        Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(grant.label) için onayı geri al")
                }
            }
        }
    }

    private var activityCard: some View {
        RovaCard {
            Text("Etkinlik").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if model.activities.isEmpty {
                Text("Henüz komut yok").foregroundStyle(.secondary).font(.subheadline)
            } else {
                ForEach(model.activities.prefix(8)) { activity in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.title).font(.subheadline.weight(.medium))
                        Text(activity.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func errorCard(_ error: String) -> some View {
        RovaCard {
            DisclosureGroup("Ayrıntı") {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 3)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func loadDevicesAndTrust() async {
        async let fetchedDevices = try? RovaBackendClient.fetchDevices()
        async let fetchedTrustGrants = try? RovaBackendClient.fetchTrustGrants()
        backendDevices = (await fetchedDevices) ?? []
        trustGrants = (await fetchedTrustGrants) ?? []
    }

    private func displayPlatformName(_ platform: String) -> String {
        let normalized = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isDesktopPlatform = normalized.contains("mac")
            || normalized.contains("windows")
            || normalized == "win32"
            || normalized.contains("linux")
            || normalized == "desktop"
        return isDesktopPlatform ? "PC" : platform
    }

    private var statusText: String {
        model.userFacingConnectionLabel
    }

    private var statusColor: Color {
        model.state == .connected ? .green : .secondary
    }

    private func icon(for id: ApplicationID) -> String {
        switch id {
        case .safari: return "safari"
        case .xcode: return "hammer"
        case .terminal: return "terminal"
        case .finder: return "face.smiling"
        case .visualStudioCode: return "chevron.left.forwardslash.chevron.right"
        case .mail: return "envelope.fill"
        case .music: return "music.note"
        case .messages: return "message.fill"
        case .notes: return "note.text"
        case .systemSettings: return "gearshape.fill"
        }
    }

    private func formatUptime(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let days = hours / 24
        if days > 0 {
            return "\(days)d \(hours % 24)h"
        } else if hours > 0 {
            return "\(hours)h \(totalMinutes % 60)m"
        } else {
            return "\(max(1, totalMinutes))m"
        }
    }

    private func hapticImpact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func hapticNotification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}
