import SwiftUI

/// Ayarlar > Görevler: only what the person acts on. What is running (Durdur), to-dos, scheduled automations (on/off, run now, delete),
/// results to look at, the agents (delete), and one switch for Wiqo working on its own. No sub-pages.
struct WiqoWorkView: View {
    @State private var agentTasks: [RovaBackendClient.AgentTaskDetail] = []
    @State private var todos: [RovaBackendClient.RovaTask] = []
    @State private var automations: [RovaBackendClient.RovaAutomation] = []
    @State private var reviewItems: [RovaBackendClient.AutomationReviewItem] = []
    @State private var agents: [RovaBackendClient.NamedAgent] = []
    @State private var budget: RovaBackendClient.AgentBudget?

    @State private var loaded = false
    @State private var errorText: String?
    @State private var busy: Set<String> = []
    @State private var pending: Pending?

    private enum Pending: Identifiable {
        case stopTask(RovaBackendClient.AgentTaskDetail)
        case deleteAutomation(RovaBackendClient.RovaAutomation)
        case deleteAgent(RovaBackendClient.NamedAgent)
        var id: String {
            switch self {
            case .stopTask(let task): "stop-\(task.id)"
            case .deleteAutomation(let automation): "automation-\(automation.id)"
            case .deleteAgent(let agent): "agent-\(agent.id)"
            }
        }
    }

    private var running: [RovaBackendClient.AgentTaskDetail] { agentTasks.filter(\.isActive) }
    private var pendingTodos: [RovaBackendClient.RovaTask] { todos.filter { $0.status == "pending" } }
    private var isEmpty: Bool { running.isEmpty && pendingTodos.isEmpty && automations.isEmpty && reviewItems.isEmpty && agents.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let errorText { errorBanner(errorText) }
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    if isEmpty { emptyState }
                    if !reviewItems.isEmpty { reviewSection }
                    if !running.isEmpty { runningSection }
                    if !pendingTodos.isEmpty { todoSection }
                    if !automations.isEmpty { automationSection }
                    if !agents.isEmpty { agentsSection }
                    if let budget { autonomyRow(budget) }
                }
            }
            .padding(.horizontal, RovaDesign.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(WiqoSettingsStyle.canvas)
        .navigationTitle("Görevler")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .wiqoConfirmation(
            item: $pending,
            title: { action in
                switch action {
                case .stopTask: String(localized: "Görev durdurulsun mu?")
                case .deleteAutomation: String(localized: "Otomasyon silinsin mi?")
                case .deleteAgent: String(localized: "Ajan silinsin mi?")
                }
            },
            actions: { action in
                switch action {
                case .stopTask(let task): Button("Görevi durdur", role: .destructive) { Task { await stop(task) } }
                case .deleteAutomation(let automation): Button("Otomasyonu sil", role: .destructive) { Task { await delete(automation) } }
                case .deleteAgent(let agent): Button("Ajanı sil", role: .destructive) { Task { await delete(agent) } }
                }
            },
            message: { action in
                switch action {
                case .stopTask(let task): Text("“\(task.title)” bulunduğu adımda bırakılır; yarım sonuç teslim edilmez.")
                case .deleteAutomation(let automation): Text("“\(automation.prompt)” bir daha çalışmaz. Bu geri alınamaz.")
                case .deleteAgent(let agent): Text("\(agent.name) ve hafızası silinir. Bu geri alınamaz.")
                }
            }
        )
    }

    // MARK: Sections

    private var emptyState: some View {
        VStack(spacing: 10) {
            WiqoAgentMascot("general", size: 64)
            Text("Şu an bir iş yok").font(.headline)
            Text("Wiqo'dan bir iş iste ya da “her sabah 8'de özet gönder” de; burada görünür.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var reviewSection: some View {
        group(String(localized: "Bakman gerekenler"), count: reviewItems.count) { index in
            let item = reviewItems[index]
            row(icon: item.status == "needs_attention" ? "exclamationmark.circle" : "clock", tint: item.status == "needs_attention" ? WiqoTheme.orange : .secondary,
                title: item.title, subtitle: item.error ?? item.reply ?? String(localized: "Sonuç belirsiz")) {
                Menu {
                    if item.status == "needs_attention" {
                        Button("Tamamlandı", systemImage: "checkmark.circle") { Task { await resolve(item, as: "completed") } }
                        Button("Başarısız", systemImage: "xmark.circle") { Task { await resolve(item, as: "failed") } }
                    } else {
                        Button("Tekrar dene", systemImage: "arrow.clockwise") { Task { await retry(item) } }
                    }
                } label: { menuLabel }
            }
        }
    }

    private var runningSection: some View {
        group(String(localized: "Çalışıyor"), count: running.count) { index in
            let task = running[index]
            HStack(spacing: 12) {
                WiqoAgentMascot(task.persona, size: 38, isWorking: task.waiting == nil)
                titles(task.title, status(of: task))
                Spacer(minLength: 4)
                Button { pending = .stopTask(task) } label: {
                    Text(busy.contains("task-\(task.id)") ? "Durduruluyor…" : "Durdur")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(WiqoTheme.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(WiqoTheme.tint(WiqoTheme.red), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(busy.contains("task-\(task.id)"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var todoSection: some View {
        group(String(localized: "Yapılacaklar"), count: pendingTodos.count) { index in
            let todo = pendingTodos[index]
            HStack(spacing: 12) {
                Button { Task { await complete(todo) } } label: {
                    Image(systemName: "circle").font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tamamlandı olarak işaretle")
                Text(todo.title).font(.body).lineLimit(2)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    private var automationSection: some View {
        group(String(localized: "Zamanlanmış"), count: automations.count) { index in
            let automation = automations[index]
            HStack(spacing: 8) {
                titles(automation.prompt, automation.isActive ? (automation.scheduleLabel ?? automation.cron) : String(localized: "\(automation.scheduleLabel ?? automation.cron) · duraklatıldı"))
                    .padding(.leading, 14)
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(get: { automation.isActive }, set: { value in Task { await setActive(automation, active: value) } }))
                    .labelsHidden()
                    .disabled(busy.contains("automation-\(automation.id)"))
                Menu {
                    Button("Şimdi çalıştır", systemImage: "play") { Task { await runNow(automation) } }.disabled(!automation.isActive)
                    Button("Sil", systemImage: "trash", role: .destructive) { pending = .deleteAutomation(automation) }
                } label: { menuLabel }
            }
            .padding(.vertical, 6)
        }
    }

    private var agentsSection: some View {
        group(String(localized: "Ajanlarım"), count: agents.count) { index in
            let agent = agents[index]
            row(mascot: agent.persona, title: agent.name, subtitle: agent.role) {
                if agent.isPrimary != true {
                    Menu {
                        Button("Ajanı sil", systemImage: "trash", role: .destructive) { pending = .deleteAgent(agent) }
                    } label: { menuLabel }
                }
            }
        }
    }

    private func autonomyRow(_ budget: RovaBackendClient.AgentBudget) -> some View {
        WiqoSettingsGroup {
            HStack(spacing: 12) {
                titles(String(localized: "Kendi başına çalış"), budget.paused ? String(localized: "Duraklatıldı") : String(localized: "İzleme ve rutinler açık"))
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { !budget.paused }, set: { value in Task { await setPaused(!value) } })).labelsHidden()
            }
            .padding(14)
        }
    }

    // MARK: Pieces

    private func group<Row: View>(_ title: String, count: Int, @ViewBuilder row: @escaping (Int) -> Row) -> some View {
        WiqoSettingsGroup(title: title) {
            ForEach(0..<count, id: \.self) { index in
                row(index)
                    .overlay(alignment: .bottom) {
                        if index < count - 1 { Rectangle().fill(WiqoTheme.line).frame(height: 0.5).padding(.leading, 14) }
                    }
            }
        }
    }

    private func titles(_ title: String, _ subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
        }
    }

    private func row<Trailing: View>(icon: String? = nil, tint: Color = .secondary, mascot: String? = nil, title: String, subtitle: String?, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            if let mascot {
                WiqoAgentMascot(mascot, size: 38)
            } else if let icon {
                Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(tint).frame(width: 38, height: 38)
            }
            titles(title, subtitle)
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var menuLabel: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(WiqoTheme.red)
            Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            Button { errorText = nil } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary) }.buttonStyle(.plain)
        }
        .padding(12)
        .background(WiqoTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func status(of task: RovaBackendClient.AgentTaskDetail) -> String {
        if task.waiting?.reason == "approval" { return String(localized: "Onayını bekliyor") }
        if task.waiting?.reason == "answer" { return String(localized: "Yanıt bekliyor") }
        if let progress = task.progress, !progress.isEmpty { return progress }
        return String(localized: "Çalışıyor")
    }

    // MARK: Loading and actions

    private func load() async {
        async let tasks = try? RovaBackendClient.fetchAgentTasks()
        async let todoList = try? RovaBackendClient.fetchTasks()
        async let automationList = try? RovaBackendClient.fetchAutomations()
        async let review = try? RovaBackendClient.fetchAutomationReview()
        async let agentList = try? RovaBackendClient.fetchAgents()
        async let budgetResult = try? RovaBackendClient.fetchAgentBudget()
        let results = await (tasks, todoList, automationList, review, agentList, budgetResult)
        agentTasks = results.0 ?? agentTasks
        todos = results.1 ?? todos
        // Deleted, finished and expired automations stay out; a paused one stays so it can be resumed or deleted.
        automations = (results.2 ?? automations).filter { $0.isActive || $0.lifecycleStatus == "paused" }
        reviewItems = results.3 ?? reviewItems
        agents = results.4 ?? agents
        budget = results.5 ?? budget
        if results.0 == nil && results.2 == nil && results.4 == nil && !loaded { fail(String(localized: "Görevler yüklenemedi. Bağlantını kontrol edip aşağı çek.")) }
        loaded = true
    }

    private func succeed(_ text: String) {
        errorText = nil
        WiqoToastCenter.shared.show(text, kind: .success)
    }

    private func fail(_ text: String) {
        errorText = text
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
            do { try await RovaBackendClient.cancelAgentTask(id: task.id); succeed(String(localized: "Görev durduruldu")) }
            catch { fail(message(error, fallback: String(localized: "Görev durdurulamadı. Bir süre sonra tekrar dene."))) }
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
            do { _ = try await RovaBackendClient.runAutomationNow(id: automation.id); succeed(String(localized: "Çalıştırıyorum")) }
            catch { fail(message(error, fallback: String(localized: "Otomasyon başlatılamadı."))) }
            await load()
        }
    }

    private func delete(_ automation: RovaBackendClient.RovaAutomation) async {
        await guarded("automation-\(automation.id)") {
            do { try await RovaBackendClient.cancelAutomation(id: automation.id); automations.removeAll { $0.id == automation.id }; succeed(String(localized: "Otomasyon silindi")) }
            catch { fail(message(error, fallback: String(localized: "Otomasyon silinemedi."))) }
            await load()
        }
    }

    private func delete(_ agent: RovaBackendClient.NamedAgent) async {
        await guarded("agent-\(agent.id)") {
            do { try await RovaBackendClient.deleteAgent(id: agent.id); agents.removeAll { $0.id == agent.id }; succeed(String(localized: "Ajan silindi")) }
            catch { fail(message(error, fallback: String(localized: "Ajan silinemedi."))) }
            await load()
        }
    }

    private func complete(_ todo: RovaBackendClient.RovaTask) async {
        await guarded("todo-\(todo.id)") {
            do { try await RovaBackendClient.completeTask(id: todo.id); todos.removeAll { $0.id == todo.id }; UISelectionFeedbackGenerator().selectionChanged() }
            catch { fail(message(error, fallback: String(localized: "Görev tamamlanamadı."))) }
            await load()
        }
    }

    private func retry(_ item: RovaBackendClient.AutomationReviewItem) async {
        await guarded("review-\(item.runId)") {
            do { _ = try await RovaBackendClient.retryAutomationRun(automationID: item.automationId, runID: item.runId); succeed(String(localized: "Tekrar deniyorum")) }
            catch { fail(message(error, fallback: String(localized: "Tekrar denenemedi."))) }
            await load()
        }
    }

    private func resolve(_ item: RovaBackendClient.AutomationReviewItem, as resolution: String) async {
        await guarded("review-\(item.runId)") {
            do { _ = try await RovaBackendClient.resolveUnknownAutomationRun(automationID: item.automationId, runID: item.runId, resolution: resolution); succeed(String(localized: "Kaydedildi")) }
            catch { fail(message(error, fallback: String(localized: "Sonuç kaydedilemedi."))) }
            await load()
        }
    }

    private func setPaused(_ paused: Bool) async {
        if let updated = try? await RovaBackendClient.setAgentPaused(paused) { budget = updated } else { fail(String(localized: "Ayar kaydedilemedi.")) }
    }
}
