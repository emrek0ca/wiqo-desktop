import SwiftUI

/// Ayarlar > Görevler: everything Wiqo is doing or will do, on one page. What is running now (with Durdur), to-dos, scheduled automations
/// (switch on/off, run now, delete), what needs a look, the agents, and what Wiqo does on its own. Details open in a sheet, never a deeper page.
struct WiqoWorkView: View {
    @State private var agentTasks: [RovaBackendClient.AgentTaskDetail] = []
    @State private var todos: [RovaBackendClient.RovaTask] = []
    @State private var automations: [RovaBackendClient.RovaAutomation] = []
    @State private var reviewItems: [RovaBackendClient.AutomationReviewItem] = []
    @State private var agents: [RovaBackendClient.NamedAgent] = []
    @State private var watch: [RovaBackendClient.WatchSource] = []
    @State private var budget: RovaBackendClient.AgentBudget?
    @State private var standing: [RovaBackendClient.StandingRule] = []
    @State private var events: [RovaBackendClient.AgentEvent] = []
    @State private var auditEntries: [RovaBackendClient.AgentAuditEntry] = []

    @State private var loaded = false
    @State private var notice: Notice?
    @State private var busy: Set<String> = []
    @State private var pending: Pending?
    @State private var detail: Detail?
    @State private var showAllFinished = false

    private struct Notice: Equatable { let text: String; let isError: Bool }

    private enum Pending: Identifiable {
        case stopTask(RovaBackendClient.AgentTaskDetail)
        case deleteAutomation(RovaBackendClient.RovaAutomation)
        case deleteAgent(RovaBackendClient.NamedAgent)
        case forgetAgentMemory(RovaBackendClient.NamedAgent)
        var id: String {
            switch self {
            case .stopTask(let task): "stop-\(task.id)"
            case .deleteAutomation(let automation): "automation-\(automation.id)"
            case .deleteAgent(let agent): "agent-\(agent.id)"
            case .forgetAgentMemory(let agent): "memory-\(agent.id)"
            }
        }
    }

    private enum Detail: Identifiable {
        case task(RovaBackendClient.AgentTaskDetail)
        case automation(RovaBackendClient.RovaAutomation)
        case agent(RovaBackendClient.NamedAgent)
        case onItsOwn
        var id: String {
            switch self {
            case .task(let task): "task-\(task.id)"
            case .automation(let automation): "automation-\(automation.id)"
            case .agent(let agent): "agent-\(agent.id)"
            case .onItsOwn: "own"
            }
        }
    }

    private var running: [RovaBackendClient.AgentTaskDetail] { agentTasks.filter(\.isActive) }
    private var finished: [RovaBackendClient.AgentTaskDetail] { agentTasks.filter { !$0.isActive } }
    private var pendingTodos: [RovaBackendClient.RovaTask] { todos.filter { $0.status == "pending" } }
    /// Things that wait for the person: a result to confirm, an approval, an answer.
    private var attentionCount: Int { reviewItems.count + agentTasks.filter { $0.waiting != nil }.count }
    private var isEmpty: Bool { running.isEmpty && pendingTodos.isEmpty && automations.isEmpty && reviewItems.isEmpty && agents.isEmpty && finished.isEmpty }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 20) {
                if let notice { noticeBanner(notice) }
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    if attentionCount > 0 { attentionBanner(proxy) }
                    if isEmpty { emptyState }
                    if automations.isEmpty || agents.isEmpty { suggestionsSection }
                    if !running.isEmpty { runningSection.id("running") }
                    if !reviewItems.isEmpty { reviewSection.id("review") }
                    if !pendingTodos.isEmpty { todoSection }
                    if !automations.isEmpty { automationSection }
                    agentsSection
                    onItsOwnSection
                    if !finished.isEmpty { finishedSection }
                }
            }
            .padding(.horizontal, RovaDesign.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(WiqoSettingsStyle.canvas)
        }
        .navigationTitle("Görevler")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $detail) { item in detailSheet(item) }
        .wiqoConfirmation(
            item: $pending,
            title: { action in
                switch action {
                case .stopTask: String(localized: "Görev durdurulsun mu?")
                case .deleteAutomation: String(localized: "Otomasyon silinsin mi?")
                case .deleteAgent: String(localized: "Ajan silinsin mi?")
                case .forgetAgentMemory: String(localized: "Ajanın hafızası silinsin mi?")
                }
            },
            actions: { action in
                switch action {
                case .stopTask(let task):
                    Button("Görevi durdur", role: .destructive) { Task { await stop(task) } }
                case .deleteAutomation(let automation):
                    Button("Otomasyonu sil", role: .destructive) { Task { await delete(automation) } }
                case .deleteAgent(let agent):
                    Button("Ajanı sil", role: .destructive) { Task { await delete(agent) } }
                case .forgetAgentMemory(let agent):
                    Button("Hafızayı sil", role: .destructive) { Task { await forgetMemory(of: agent) } }
                }
            },
            message: { action in
                switch action {
                case .stopTask(let task): Text("“\(task.title)” bulunduğu adımda bırakılır; yarım sonuç teslim edilmez.")
                case .deleteAutomation(let automation): Text("“\(automation.prompt)” bir daha çalışmaz. Bu geri alınamaz.")
                case .deleteAgent(let agent): Text("\(agent.name) ve hafızası silinir. Bu geri alınamaz.")
                case .forgetAgentMemory(let agent): Text("\(agent.name) şimdiye kadar öğrendiklerini unutur; kendisi kalır.")
                }
            }
        )
    }

    // MARK: Sections

    /// Wiqo reads the page and says what needs the person first: one banner, one tap to the place.
    private func attentionBanner(_ proxy: ScrollViewProxy) -> some View {
        let waiting = agentTasks.filter { $0.waiting != nil }
        return Button {
            withAnimation { proxy.scrollTo(reviewItems.isEmpty ? "running" : "review", anchor: .top) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill").foregroundStyle(WiqoTheme.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attentionCount == 1 ? "1 şey senin kararını bekliyor" : "\(attentionCount) şey senin kararını bekliyor")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(waiting.first.map { "“\($0.title)”: \(status(of: $0))" } ?? String(localized: "Sonucu belirsiz kalan otomasyonlar var"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("Göster").font(.footnote.weight(.semibold)).foregroundStyle(WiqoTheme.orange)
            }
            .padding(14)
            .background(WiqoTheme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: WiqoTheme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// One tap starts what people usually want here; the chat opens with the sentence ready to send.
    private var suggestionsSection: some View {
        let ideas: [(String, String, String)] = [
            ("sun.max", String(localized: "Her sabah özet"), String(localized: "Her sabah 8'de bana günün özetini gönder")),
            ("calendar.badge.clock", String(localized: "Haftalık rapor"), String(localized: "Her cuma akşamı haftalık raporumu hazırlayıp hatırlat")),
            ("person.2.circle", String(localized: "Yeni ajan"), String(localized: "Bana her hafta sektör haberlerini özetleyen bir ajan kur"))
        ]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Önerilenler")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ideas, id: \.0) { idea in
                        Button {
                            NotificationCenter.default.post(name: .wiqoStartChat, object: idea.2)
                        } label: {
                            Label(idea.1, systemImage: idea.0)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .wiqoGlass(radius: 20)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            WiqoAgentMascot("general", size: 72)
            Text("Henüz görev yok")
                .font(.headline)
            Text("Wiqo'dan bir iş iste ya da “her sabah 8'de özet gönder” de; burada görünür.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var runningSection: some View {
        WiqoSettingsGroup(title: String(localized: "Şimdi çalışıyor")) {
            ForEach(Array(running.enumerated()), id: \.element.id) { index, task in
                workRow(showsDivider: index < running.count - 1) {
                    WiqoAgentMascot(task.persona, size: 40, isWorking: task.waiting == nil)
                } title: {
                    task.title
                } subtitle: {
                    status(of: task)
                } trailing: {
                    stopButton(task)
                } onTap: {
                    detail = .task(task)
                }
            }
        }
    }

    private var reviewSection: some View {
        WiqoSettingsGroup(title: String(localized: "İncelenecek")) {
            ForEach(Array(reviewItems.enumerated()), id: \.element.id) { index, item in
                workRow(showsDivider: index < reviewItems.count - 1) {
                    icon(item.status == "needs_attention" ? "exclamationmark.circle" : "clock", tint: item.status == "needs_attention" ? WiqoTheme.orange : .secondary)
                } title: {
                    item.title
                } subtitle: {
                    item.error ?? item.reply ?? (item.status == "needs_attention" ? String(localized: "Sonuç belirsiz") : String(localized: "Yarım kaldı"))
                } trailing: {
                    Menu {
                        if item.status == "needs_attention" {
                            Button("Tamamlandı", systemImage: "checkmark.circle") { Task { await resolve(item, as: "completed") } }
                            Button("Başarısız", systemImage: "xmark.circle") { Task { await resolve(item, as: "failed") } }
                        } else {
                            Button("Tekrar dene", systemImage: "arrow.clockwise") { Task { await retry(item) } }
                        }
                    } label: { menuLabel }
                } onTap: {}
            }
        }
    }

    private var todoSection: some View {
        WiqoSettingsGroup(title: String(localized: "Yapılacaklar")) {
            ForEach(Array(pendingTodos.enumerated()), id: \.element.id) { index, todo in
                workRow(showsDivider: index < pendingTodos.count - 1) {
                    Button { Task { await complete(todo) } } label: {
                        Image(systemName: busy.contains("todo-\(todo.id)") ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tamamlandı olarak işaretle")
                } title: {
                    todo.title
                } subtitle: { nil } trailing: { EmptyView() } onTap: {}
            }
        }
    }

    private var automationSection: some View {
        WiqoSettingsGroup(title: String(localized: "Zamanlanmış")) {
            ForEach(Array(automations.enumerated()), id: \.element.id) { index, automation in
                workRow(showsDivider: index < automations.count - 1) {
                    icon(automation.isActive ? "clock.arrow.circlepath" : "pause.circle", tint: automation.isActive ? WiqoTheme.ink : .secondary)
                } title: {
                    automation.prompt
                } subtitle: {
                    automationSubtitle(automation)
                } trailing: {
                    HStack(spacing: 0) {
                        Toggle("", isOn: Binding(
                            get: { automation.isActive },
                            set: { value in Task { await setActive(automation, active: value) } }
                        ))
                        .labelsHidden()
                        .disabled(busy.contains("automation-\(automation.id)"))
                        .accessibilityLabel(automation.isActive ? "Otomasyonu duraklat" : "Otomasyonu sürdür")
                        Menu {
                            Button("Şimdi çalıştır", systemImage: "play") { Task { await runNow(automation) } }
                                .disabled(!automation.isActive)
                            Button("Ayrıntılar", systemImage: "list.bullet") { detail = .automation(automation) }
                            Button("Sil", systemImage: "trash", role: .destructive) { pending = .deleteAutomation(automation) }
                        } label: { menuLabel }
                    }
                } onTap: {
                    detail = .automation(automation)
                }
            }
        }
    }

    private var agentsSection: some View {
        WiqoSettingsGroup(title: String(localized: "Ajanlarım")) {
            if agents.isEmpty {
                Text("Henüz ajan yok. “Bana haftalık özet çıkaran bir ajan kur” diyebilirsin.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                workRow(showsDivider: index < agents.count - 1) {
                    WiqoAgentMascot(agent.persona, size: 40)
                } title: {
                    agent.name
                } subtitle: {
                    agent.cron == nil ? String(localized: "İş verilince çalışır") : String(localized: "Rutini var")
                } trailing: {
                    Menu {
                        Button("Ayrıntılar", systemImage: "info.circle") { detail = .agent(agent) }
                        if !agent.memory.isEmpty {
                            Button("Hafızayı sil", systemImage: "eraser") { pending = .forgetAgentMemory(agent) }
                        }
                        if agent.isPrimary != true {
                            Button("Ajanı sil", systemImage: "trash", role: .destructive) { pending = .deleteAgent(agent) }
                        }
                    } label: { menuLabel }
                } onTap: {
                    detail = .agent(agent)
                }
            }
        }
    }

    private var onItsOwnSection: some View {
        WiqoSettingsGroup(title: String(localized: "Kendi başına")) {
            if let budget {
                HStack(spacing: 12) {
                    icon("sparkles", tint: WiqoTheme.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Kendi başına çalış").font(.body)
                        Text(budget.paused ? String(localized: "Duraklatıldı: izleme ve rutinler durdu")
                             : String(localized: "Bugün \(budget.usedTokens / 1000) bin / \(budget.limitTokens / 1000) bin birim kullandı"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(get: { !budget.paused }, set: { value in Task { await setPaused(!value) } }))
                        .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider().padding(.leading, 56)
            }
            workRow(showsDivider: false) {
                icon("slider.horizontal.3", tint: WiqoTheme.ink)
            } title: {
                String(localized: "İzleme, izinler ve geçmiş")
            } subtitle: {
                String(localized: "Mail ve takvim izleme, onaysız yapılanlar")
            } trailing: {
                WiqoChevron()
            } onTap: {
                detail = .onItsOwn
            }
        }
    }

    private var finishedSection: some View {
        let shown = showAllFinished ? finished : Array(finished.prefix(4))
        return WiqoSettingsGroup(title: String(localized: "Son biten")) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, task in
                workRow(showsDivider: index < shown.count - 1 || finished.count > 4) {
                    WiqoAgentMascot(task.persona, size: 34)
                } title: {
                    task.title
                } subtitle: {
                    status(of: task)
                } trailing: {
                    WiqoChevron()
                } onTap: {
                    detail = .task(task)
                }
            }
            if finished.count > 4 {
                Button { withAnimation { showAllFinished.toggle() } } label: {
                    Text(showAllFinished ? "Daha az göster" : "Tümünü göster (\(finished.count))")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(WiqoRowButtonStyle())
            }
        }
    }

    // MARK: Pieces

    private func workRow<Leading: View, Trailing: View>(
        showsDivider: Bool,
        @ViewBuilder leading: () -> Leading,
        title: () -> String,
        subtitle: () -> String?,
        @ViewBuilder trailing: () -> Trailing,
        onTap: (() -> Void)?
    ) -> some View {
        let tap = onTap
        let titleText = title()
        let subtitleText = subtitle()
        let leadingView = leading()
        let trailingView = trailing()
        return HStack(spacing: 12) {
            HStack(spacing: 12) {
                leadingView
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let subtitleText, !subtitleText.isEmpty {
                        Text(subtitleText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture { tap?() }
            trailingView
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(WiqoTheme.line).frame(height: 0.5).padding(.leading, 66) }
        }
    }

    private func icon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
    }

    private var menuLabel: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    private func stopButton(_ task: RovaBackendClient.AgentTaskDetail) -> some View {
        Button {
            pending = .stopTask(task)
        } label: {
            Text(busy.contains("task-\(task.id)") ? "Durduruluyor…" : "Durdur")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(WiqoTheme.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(WiqoTheme.tint(WiqoTheme.red), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy.contains("task-\(task.id)"))
        .accessibilityLabel("Görevi durdur")
    }

    private func noticeBanner(_ notice: Notice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? WiqoTheme.red : WiqoTheme.green)
            Text(notice.text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { self.notice = nil } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
        .padding(12)
        .background((notice.isError ? WiqoTheme.red : WiqoTheme.green).opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func status(of task: RovaBackendClient.AgentTaskDetail) -> String {
        if task.waiting?.reason == "approval" { return String(localized: "Onayını bekliyor") }
        if task.waiting?.reason == "answer" { return String(localized: "Yanıt bekliyor") }
        if task.isActive, let progress = task.progress, !progress.isEmpty { return progress }
        switch task.status {
        case "done": return String(localized: "Tamamlandı")
        case "failed": return String(localized: "Tamamlanamadı")
        case "cancelled": return String(localized: "Durduruldu")
        case "pending", "queued": return String(localized: "Sırada")
        default: return String(localized: "Çalışıyor")
        }
    }

    private func automationSubtitle(_ automation: RovaBackendClient.RovaAutomation) -> String {
        let schedule = automation.scheduleLabel ?? automation.cron
        return automation.isActive ? schedule : String(localized: "\(schedule) · duraklatıldı")
    }

    // MARK: Detail sheets

    @ViewBuilder
    private func detailSheet(_ item: Detail) -> some View {
        NavigationStack {
            Group {
                switch item {
                case .task(let task):
                    ScrollView {
                        AgentTaskCard(task: RovaBackendClient.AgentTaskRef(id: task.id, title: task.title, persona: task.persona))
                            .padding(RovaDesign.screenPadding)
                    }
                    .navigationTitle("Görev")
                case .automation(let automation):
                    AutomationDetailView(automation: automation)
                case .agent(let agent):
                    agentDetail(agent)
                        .navigationTitle(agent.name)
                case .onItsOwn:
                    onItsOwnDetail
                        .navigationTitle("Kendi başına")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Bitti") { detail = nil; Task { await load() } }.fontWeight(.medium)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func agentDetail(_ agent: RovaBackendClient.NamedAgent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    WiqoAgentMascot(agent.persona, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.name).font(.title3.weight(.bold))
                        Text(agent.cron == nil ? "İş verilince çalışır" : "Rutini var").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                WiqoSettingsGroup(title: String(localized: "Rolü")) {
                    Text(agent.role).font(.subheadline).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !agent.memory.isEmpty {
                    WiqoSettingsGroup(title: String(localized: "Hafızası")) {
                        Text(agent.memory).font(.footnote).textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button(role: .destructive) { detail = nil; pending = .forgetAgentMemory(agent) } label: {
                        Label("Hafızayı sil", systemImage: "eraser").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                if agent.isPrimary != true {
                    Button(role: .destructive) { detail = nil; pending = .deleteAgent(agent) } label: {
                        Label("Ajanı sil", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(RovaDesign.screenPadding)
        }
        .background(WiqoSettingsStyle.canvas)
    }

    private var onItsOwnDetail: some View {
        ScrollView {
            VStack(spacing: 18) {
                if !watch.isEmpty {
                    WiqoSettingsGroup(title: String(localized: "İzleme")) {
                        ForEach(Array(watch.enumerated()), id: \.element.id) { index, source in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.source == "gmail" ? "Gelen mailleri izle" : "Takvimi izle")
                                    Text(source.lastError ?? (source.source == "gmail" ? "Önemli olanı haber verir, gerisini sessizce not eder" : "Yeni ve değişen etkinlikleri takip eder"))
                                        .font(.caption)
                                        .foregroundStyle(source.lastError == nil ? Color.secondary : WiqoTheme.red)
                                }
                                Spacer(minLength: 8)
                                Toggle("", isOn: Binding(get: { source.enabled }, set: { value in Task { await setWatch(source.source, enabled: value) } })).labelsHidden()
                            }
                            .padding(14)
                            .overlay(alignment: .bottom) { if index < watch.count - 1 { Rectangle().fill(WiqoTheme.line).frame(height: 0.5).padding(.leading, 14) } }
                        }
                    }
                }
                if !standing.isEmpty {
                    WiqoSettingsGroup(title: String(localized: "Onay istemeden yap")) {
                        ForEach(Array(standing.enumerated()), id: \.element.id) { index, rule in
                            HStack {
                                Text(rule.label)
                                Spacer(minLength: 8)
                                Toggle("", isOn: Binding(
                                    get: { rule.enabled },
                                    set: { value in Task { if let updated = try? await RovaBackendClient.setStandingRule(rule.tool, enabled: value) { standing = updated } else { fail(String(localized: "Ayar kaydedilemedi.")) } } }
                                )).labelsHidden()
                            }
                            .padding(14)
                            .overlay(alignment: .bottom) { if index < standing.count - 1 { Rectangle().fill(WiqoTheme.line).frame(height: 0.5).padding(.leading, 14) } }
                        }
                        Text("30 gün geçerli, günde en fazla 10 kez. Mail göndermek ve silmek her zaman onay ister.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(14)
                    }
                }
                if !events.isEmpty {
                    WiqoSettingsGroup(title: String(localized: "Fark ettikleri")) {
                        ForEach(Array(events.prefix(6).enumerated()), id: \.element.id) { index, event in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.summary ?? event.title).font(.subheadline)
                                    Text(Self.eventStatus(event.status)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Menu {
                                    Button("Önemsiz, bir daha gösterme", systemImage: "bell.slash") { Task { try? await RovaBackendClient.sendEventFeedback(id: event.id, important: false); await load() } }
                                    Button("Önemliydi", systemImage: "bell.badge") { Task { try? await RovaBackendClient.sendEventFeedback(id: event.id, important: true); await load() } }
                                } label: { menuLabel }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) { if index < min(6, events.count) - 1 { Rectangle().fill(WiqoTheme.line).frame(height: 0.5).padding(.leading, 14) } }
                        }
                    }
                }
                if !auditEntries.isEmpty {
                    WiqoSettingsGroup(title: String(localized: "Ne yaptı?")) {
                        ForEach(Array(auditEntries.prefix(12).enumerated()), id: \.element.id) { index, entry in
                            Text(entry.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .overlay(alignment: .bottom) { if index < min(12, auditEntries.count) - 1 { Rectangle().fill(WiqoTheme.line).frame(height: 0.5).padding(.leading, 14) } }
                        }
                    }
                }
            }
            .padding(RovaDesign.screenPadding)
        }
        .background(WiqoSettingsStyle.canvas)
    }

    private static func eventStatus(_ status: String) -> String {
        switch status {
        case "notified": return String(localized: "Haber verdi")
        case "handled": return String(localized: "Ajan üzerinde çalışıyor")
        case "noted": return String(localized: "Not aldı")
        case "ignored": return String(localized: "Önemsiz bulundu")
        default: return String(localized: "Bekliyor")
        }
    }

    // MARK: Loading and actions

    private func load() async {
        async let tasks = try? RovaBackendClient.fetchAgentTasks()
        async let todoList = try? RovaBackendClient.fetchTasks()
        async let automationList = try? RovaBackendClient.fetchAutomations()
        async let review = try? RovaBackendClient.fetchAutomationReview()
        async let agentList = try? RovaBackendClient.fetchAgents()
        async let sources = try? RovaBackendClient.fetchWatchSources()
        async let budgetResult = try? RovaBackendClient.fetchAgentBudget()
        async let rules = try? RovaBackendClient.fetchStandingRules()
        async let eventList = try? RovaBackendClient.fetchAgentEvents()
        async let audit = try? RovaBackendClient.fetchAgentAudit()
        let results = await (tasks, todoList, automationList, review, agentList, sources, budgetResult, rules, eventList, audit)
        agentTasks = results.0 ?? agentTasks
        todos = results.1 ?? todos
        // Deleted, finished and expired automations stay out of the list; a paused one stays so it can be resumed or deleted.
        automations = (results.2 ?? automations).filter { $0.isActive || $0.lifecycleStatus == "paused" }
        reviewItems = results.3 ?? reviewItems
        agents = results.4 ?? agents
        watch = results.5 ?? watch
        budget = results.6 ?? budget
        standing = results.7 ?? standing
        events = results.8 ?? events
        auditEntries = results.9 ?? auditEntries
        if results.0 == nil && results.2 == nil && results.4 == nil && !loaded { fail(String(localized: "Görevler yüklenemedi. Bağlantını kontrol edip aşağı çek.")) }
        loaded = true
    }

    private func succeed(_ text: String) {
        notice = nil
        WiqoToastCenter.shared.show(text, kind: .success)
    }

    private func fail(_ text: String) {
        notice = Notice(text: text, isError: true)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func message(_ error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }

    private func guarded(_ key: String, _ work: () async -> Void) async {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        await work()
    }

    private func stop(_ task: RovaBackendClient.AgentTaskDetail) async {
        await guarded("task-\(task.id)") {
            do {
                try await RovaBackendClient.cancelAgentTask(id: task.id)
                succeed(String(localized: "Görev durduruldu"))
            } catch {
                fail(message(error, fallback: String(localized: "Görev durdurulamadı. Bir süre sonra tekrar dene.")))
            }
            await load()
        }
    }

    private func setActive(_ automation: RovaBackendClient.RovaAutomation, active: Bool) async {
        await guarded("automation-\(automation.id)") {
            do {
                _ = active ? try await RovaBackendClient.resumeAutomation(id: automation.id) : try await RovaBackendClient.pauseAutomation(id: automation.id)
                succeed(active ? String(localized: "Otomasyon sürdürüldü") : String(localized: "Otomasyon duraklatıldı"))
            } catch {
                fail(message(error, fallback: active ? String(localized: "Otomasyon sürdürülemedi.") : String(localized: "Otomasyon duraklatılamadı.")))
            }
            await load()
        }
    }

    private func runNow(_ automation: RovaBackendClient.RovaAutomation) async {
        await guarded("automation-\(automation.id)") {
            do {
                _ = try await RovaBackendClient.runAutomationNow(id: automation.id)
                succeed(String(localized: "Çalıştırıyorum"))
            } catch {
                fail(message(error, fallback: String(localized: "Otomasyon başlatılamadı.")))
            }
            await load()
        }
    }

    private func delete(_ automation: RovaBackendClient.RovaAutomation) async {
        await guarded("automation-\(automation.id)") {
            do {
                try await RovaBackendClient.cancelAutomation(id: automation.id)
                automations.removeAll { $0.id == automation.id }
                succeed(String(localized: "Otomasyon silindi"))
            } catch {
                fail(message(error, fallback: String(localized: "Otomasyon silinemedi.")))
            }
            await load()
        }
    }

    private func delete(_ agent: RovaBackendClient.NamedAgent) async {
        await guarded("agent-\(agent.id)") {
            do {
                try await RovaBackendClient.deleteAgent(id: agent.id)
                agents.removeAll { $0.id == agent.id }
                succeed(String(localized: "Ajan silindi"))
            } catch {
                fail(message(error, fallback: String(localized: "Ajan silinemedi.")))
            }
            await load()
        }
    }

    private func forgetMemory(of agent: RovaBackendClient.NamedAgent) async {
        await guarded("agent-\(agent.id)") {
            do {
                try await RovaBackendClient.forgetAgentMemory(id: agent.id)
                succeed(String(localized: "Hafıza silindi"))
            } catch {
                fail(message(error, fallback: String(localized: "Hafıza silinemedi.")))
            }
            await load()
        }
    }

    private func complete(_ todo: RovaBackendClient.RovaTask) async {
        await guarded("todo-\(todo.id)") {
            do {
                try await RovaBackendClient.completeTask(id: todo.id)
                todos.removeAll { $0.id == todo.id }
                UISelectionFeedbackGenerator().selectionChanged()
            } catch {
                fail(message(error, fallback: String(localized: "Görev tamamlanamadı.")))
            }
            await load()
        }
    }

    private func retry(_ item: RovaBackendClient.AutomationReviewItem) async {
        await guarded("review-\(item.runId)") {
            do {
                _ = try await RovaBackendClient.retryAutomationRun(automationID: item.automationId, runID: item.runId)
                succeed(String(localized: "Tekrar deniyorum"))
            } catch {
                fail(message(error, fallback: String(localized: "Tekrar denenemedi.")))
            }
            await load()
        }
    }

    private func resolve(_ item: RovaBackendClient.AutomationReviewItem, as resolution: String) async {
        await guarded("review-\(item.runId)") {
            do {
                _ = try await RovaBackendClient.resolveUnknownAutomationRun(automationID: item.automationId, runID: item.runId, resolution: resolution)
                succeed(String(localized: "Kaydedildi"))
            } catch {
                fail(message(error, fallback: String(localized: "Sonuç kaydedilemedi.")))
            }
            await load()
        }
    }

    private func setPaused(_ paused: Bool) async {
        if let updated = try? await RovaBackendClient.setAgentPaused(paused) { budget = updated } else { fail(String(localized: "Ayar kaydedilemedi.")) }
        auditEntries = (try? await RovaBackendClient.fetchAgentAudit()) ?? auditEntries
    }

    private func setWatch(_ source: String, enabled: Bool) async {
        if let updated = try? await RovaBackendClient.setWatchSource(source, enabled: enabled) { watch = updated } else { fail(String(localized: "Ayar kaydedilemedi.")) }
    }
}
