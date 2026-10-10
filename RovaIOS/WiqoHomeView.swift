import SwiftUI

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
    /// The plans, offered once to a new account before the PC welcome.
    @State private var showFirstPlans = false
    @State private var showQuickPairing = false
    @State private var openQuickPairingAfterWelcome = false
    @State private var openFirstCommandAfterPairing = false
    @State private var didCheckWelcome = false
    @State private var draftPrompt: String?
    @State private var pendingActivity: ActivitySheetRoute?

    private enum HomeMode: String, Hashable { case chat, act }
    private static let modeKey = "wiqo.home.mode"
    /// The side the app opens on is the one it was left on.
    @State private var mode: HomeMode = HomeMode(rawValue: UserDefaults.standard.string(forKey: WiqoHomeView.modeKey) ?? "") ?? .chat
    @State private var chatHasNews = false
    @ObservedObject private var chatActivity = WiqoChatActivity.shared
    @ObservedObject private var actModel = ActModel.shared
    private var actHandoffs: NotificationCenter.Publisher { NotificationCenter.default.publisher(for: .wiqoOpenInAct) }
    private var actProjectOpens: NotificationCenter.Publisher { NotificationCenter.default.publisher(for: .wiqoOpenProjectInAct) }

    var body: some View {
        NavigationStack {
            ZStack {
                CopilotView(model: model, authSession: authSession, subscriptionStore: subscriptionStore, conversationID: conversationID, draftPrompt: draftPrompt)
                    .id(conversationID)
                    .opacity(mode == .chat ? 1 : 0)
                    .offset(x: mode == .chat ? 0 : -18)
                    .allowsHitTesting(mode == .chat)
                    .accessibilityHidden(mode != .chat)
                ActView()
                    // Theme, accent and text size are applied here again so Act can never miss a change made in Settings.
                    .wiqoAppearance()
                    .onReceive(actHandoffs) { _ in mode = .act }
                    .onReceive(actProjectOpens) { _ in mode = .act }
                    .opacity(mode == .act ? 1 : 0)
                    .offset(x: mode == .act ? 0 : 18)
                    .allowsHitTesting(mode == .act)
                    .accessibilityHidden(mode != .act)
            }
                .animation(WiqoMotion.ease(0.3), value: mode)
                .modifier(WiqoSideSwipe(canSwipe: !showSidebar) { toAct in
                    let next: HomeMode = toAct ? .act : .chat
                    guard next != mode else { return }
                    WiqoHaptics.selection()
                    withAnimation(WiqoMotion.ease(0.3)) { mode = next }
                })
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        WiqoModeSwitch<HomeMode>(
                            options: [
                                .init(value: .chat, title: String(localized: "Chat"),
                                      badge: mode == .act && chatHasNews ? .unread : (chatActivity.isWorking && mode == .act ? .working : .none)),
                                .init(value: .act, title: String(localized: "Act"),
                                      badge: actModel.job != nil && mode == .chat ? .working : .none)
                            ],
                            selection: $mode,
                            onReselect: { side in
                                switch side {
                                case .chat: NotificationCenter.default.post(name: .wiqoFocusComposer, object: nil)
                                case .act: NotificationCenter.default.post(name: .wiqoActHome, object: nil)
                                }
                            }
                        )
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
            UserDefaults.standard.set(new.rawValue, forKey: Self.modeKey)
            if new == .chat { chatHasNews = false }
        }
        .onChange(of: chatActivity.isWorking) { _, working in
            // A reply that finished while the person was in Act is marked on the Chat side.
            if !working && mode == .act { chatHasNews = true }
        }
        .onAppear { WiqoOrientation.allowLandscape(mode == .act) }
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
        .sheet(isPresented: $showFirstPlans, onDismiss: presentWelcomeIfNeeded) {
            PaywallView(subscriptionStore: subscriptionStore, introMode: true)
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

    private var plansOfferKey: String? {
        let identity = RovaBackendClient.currentUserID ?? RovaBackendClient.currentUserEmail
        guard let identity, !identity.isEmpty else { return nil }
        return "wiqo.plans.offered.\(identity)"
    }

    private func prepareWelcomeIfNeeded() {
        guard !didCheckWelcome else { return }
        didCheckWelcome = true
        Task { @MainActor in
            // The account's real plan first: a Pro account on a new phone is not offered Pro.
            await subscriptionStore.refreshIfStale(maxAge: 30)
            if let key = plansOfferKey, !UserDefaults.standard.bool(forKey: key), subscriptionStore.info.tier == "free" {
                UserDefaults.standard.set(true, forKey: key)
                showFirstPlans = true
                return
            }
            presentWelcomeIfNeeded()
        }
    }

    private func presentWelcomeIfNeeded() {
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
        draftPrompt = String(localized: "Sesi kıs")
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

struct SidebarOverlay: View {
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
        return [(String(localized: "Bugün"), today), (String(localized: "Dün"), yesterday), (String(localized: "Son 7 gün"), week), (String(localized: "Daha eski"), older)].filter { !$0.1.isEmpty }
    }
}

struct ConversationRow: View {
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

/// Left/right swipe between Chat and Act. Only a swipe that starts in the top or bottom band counts, so code blocks, tables and chip rows keep their own horizontal scrolling,
/// and the left edge stays with the sidebar.
private struct WiqoSideSwipe: ViewModifier {
    var canSwipe: Bool
    var onSwipe: (_ toAct: Bool) -> Void

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width, height: proxy.size.height)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24, coordinateSpace: .local).onEnded { value in
                        guard canSwipe else { return }
                        let dx = value.translation.width, dy = value.translation.height
                        let inBand = value.startLocation.y < 120 || value.startLocation.y > proxy.size.height - 170
                        guard inBand, value.startLocation.x > 24, abs(dx) > 70, abs(dx) > abs(dy) * 2 else { return }
                        onSwipe(dx < 0)
                    }
                )
        }
    }
}
