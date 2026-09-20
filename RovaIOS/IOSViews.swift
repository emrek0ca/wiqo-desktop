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
    @State private var didCheckWelcome = false
    @State private var openPCSettingsAfterWelcome = false
    @State private var draftPrompt: String?

    var body: some View {
        NavigationStack {
            CopilotView(model: model, authSession: authSession, subscriptionStore: subscriptionStore, conversationID: conversationID, draftPrompt: draftPrompt)
                .id(conversationID)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
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
                        .accessibilityLabel("Sohbet geçmişi")
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
                            Button {
                                dismissKeyboard()
                                showTemplates = true
                            } label: {
                                Image(systemName: "clock.badge")
                            }
                            .accessibilityLabel("Otomasyon şablonları")
                            Button {
                                startNewChat()
                            } label: {
                                Image(systemName: "square.and.pencil")
                            }
                            .accessibilityLabel("Yeni sohbet")
                        }
                    }
                }
        }
        .task {
            prepareWelcomeIfNeeded()
            model.connect()
            await profileStore.refresh()
            await subscriptionStore.refresh()
            await refreshConversationsFromServer()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.connect()
                Task { await subscriptionStore.refresh() }
            }
        }
        .sheet(isPresented: $showSettings) {
            // General account settings only - PC control lives in its own screen (below), reached
            // from the chat toolbar's connection icon instead of being buried in this list.
            SettingsView(model: model, authSession: authSession, profileStore: profileStore, subscriptionStore: subscriptionStore)
        }
        .sheet(isPresented: $showPCSettings) {
            PCSettingsView(model: model, subscriptionStore: subscriptionStore)
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
                    openPCSettingsAfterWelcome = true
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
                    },
                    onNewChat: {
                        closeSidebar()
                        startNewChat()
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
              !UserDefaults.standard.bool(forKey: key) else { return }
        showWelcome = true
    }

    private func completeWelcome() {
        if let key = welcomeCompletionKey {
            UserDefaults.standard.set(true, forKey: key)
        }
        guard openPCSettingsAfterWelcome else { return }
        openPCSettingsAfterWelcome = false
        showPCSettings = true
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
        .onChange(of: model.isPaired) { _, paired in
            guard paired else { return }
            if hasSeenPairingCelebration {
                dismiss()
            } else {
                hasSeenPairingCelebration = true
                showingCelebration = true
            }
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
            Text("Mac'in bağlandı!")
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
    @State private var showingPaywall = false
    @State private var showingSignOutConfirmation = false
    @State private var showingPCSettings = false
    @State private var tasks: [RovaBackendClient.RovaTask] = []
    @State private var automations: [RovaBackendClient.RovaAutomation] = []
    @State private var taskAutomationError: String?
    @State private var accountInfo: RovaBackendClient.AccountInfo?
    @State private var inviteCodes: [RovaBackendClient.InviteCode] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    pcSection
                    accountSection
                    if taskAutomationError != nil || !pendingTasks.isEmpty || !activeAutomations.isEmpty {
                        tasksAutomationsSection
                    }
                    if accountInfo?.isFoundingMember == true || firstUnusedInviteCode != nil {
                        inviteSection
                    }
                    legalSection
                    signOutSection
                    versionFooter
                }
                .padding(RovaDesign.screenPadding)
            }
            .background(RovaDesign.canvas)
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Text("Kapat").font(.body.weight(.medium)) }
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(subscriptionStore: subscriptionStore)
            }
            .sheet(isPresented: $showingPCSettings) {
                PCSettingsView(model: model, subscriptionStore: subscriptionStore)
            }
        }
        .task {
            await loadTasksAndAutomations()
            await subscriptionStore.refresh()
            await loadAccountAndInviteCodes()
        }
    }

    private func loadAccountAndInviteCodes() async {
        async let fetchedAccount = try? RovaBackendClient.fetchAccountInfo()
        async let fetchedCodes = try? RovaBackendClient.fetchInviteCodes()
        accountInfo = await fetchedAccount
        inviteCodes = (await fetchedCodes) ?? []
    }

    private var firstUnusedInviteCode: String? {
        inviteCodes.first(where: { !$0.used })?.code
    }

    // MARK: PC

    /// The one thing this app is for, first: is the computer ready, and a way into its settings.
    private var pcSection: some View {
        Button { showingPCSettings = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(RovaConnectionStatus.color(for: model))
                    .frame(width: 44, height: 44)
                    .background(WiqoTheme.tint(RovaConnectionStatus.color(for: model)), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.isPaired ? "PC" : "PC ekle")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(model.isPaired ? model.userFacingConnectionLabel : "Bilgisayarını bağla ve telefondan yönet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if model.state == .connecting || model.isReconnecting {
                    ProgressView().controlSize(.small)
                } else {
                    WiqoChevron()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .wiqoCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(WiqoCardButtonStyle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Account

    private var accountSection: some View {
        WiqoSettingsGroup(title: "Hesap") {
            NavigationLink {
                ProfileSettingsView(profileStore: profileStore, authSession: authSession)
            } label: {
                HStack(spacing: 12) {
                    AvatarView(profile: profileStore.profile, image: profileStore.avatarImage, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profileStore.profile.visibleName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(profileStore.profile.email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    WiqoChevron()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 64)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(WiqoTheme.line).frame(height: 0.5).padding(.leading, 14)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(WiqoRowButtonStyle())

            planRow

            NavigationLink {
                ConnectedAccountsView()
            } label: {
                WiqoRow(systemImage: "link", title: "Bağlı hesaplar", subtitle: "Google, Notion", showsDivider: false)
            }
            .buttonStyle(WiqoRowButtonStyle())
        }
    }

    /// Current plan and today's usage, straight from the backend (`GET /billing/subscription`) -
    /// the same numbers copilot.ts/creativeTools.ts actually enforce, so this can never promise
    /// more than the backend will allow. See docs/abonelik.md for the full billing design.
    private var planRow: some View {
        let info = subscriptionStore.info
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(info.label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(info.tier == "free" ? "Yükselt" : "Planlar") { showingPaywall = true }
                    .buttonStyle(.wiqoPill(info.tier == "free" ? .accent : .secondary))
            }
            WiqoUsageBar(title: "Bugünkü mesajlar", used: info.usage.messages.used, limit: info.usage.messages.limit)
            WiqoUsageBar(title: "Bugünkü görseller", used: info.usage.images.used, limit: info.usage.images.limit)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WiqoTheme.line).frame(height: 0.5).padding(.leading, 14)
        }
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
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Otomasyonu iptal et")
                }
                .overlay(alignment: .bottom) {
                    if automation.id != activeAutomations.last?.id {
                        Rectangle().fill(WiqoTheme.line).frame(height: 0.5).padding(.leading, 56)
                    }
                }
            }
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

    // MARK: Invite

    /// The whole point is that Wiqo spreads through people who already use it: a founding-member
    /// badge for whoever got here early, and a code to hand a friend that credits both sides a
    /// Pro bonus the moment it's redeemed (see rova-backend's grantReferralBonus).
    private var inviteSection: some View {
        WiqoSettingsGroup(title: "Arkadaşını davet et") {
            if accountInfo?.isFoundingMember == true {
                WiqoRow(
                    systemImage: "seal.fill",
                    tint: .yellow,
                    title: "Kurucu üye",
                    showsDivider: firstUnusedInviteCode != nil
                ) { EmptyView() }
            }
            if let code = firstUnusedInviteCode {
                WiqoRow(
                    systemImage: "gift.fill",
                    title: code,
                    subtitle: "Katılırsa ikiniz de 14 gün Pro kazanırsınız.",
                    showsDivider: false
                ) {
                    ShareLink(item: "Wiqo'yu deniyorum, davet kodumla katıl ve ikimiz de Pro kazanalım: \(code)") {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                }
            }
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

    private var signOutSection: some View {
        WiqoSettingsGroup {
            Button(role: .destructive) {
                showingSignOutConfirmation = true
            } label: {
                WiqoRow(systemImage: "rectangle.portrait.and.arrow.right", title: "Çıkış yap", isDestructive: true, showsDivider: false) {
                    EmptyView()
                }
            }
            .buttonStyle(WiqoRowButtonStyle())
        }
        .confirmationDialog("Wiqo hesabından çıkmak istediğine emin misin?", isPresented: $showingSignOutConfirmation, titleVisibility: .visible) {
            Button("Çıkış yap", role: .destructive) { authSession.signOut(); dismiss() }
            Button("Vazgeç", role: .cancel) { }
        }
    }

    private var versionFooter: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return Text("Wiqo \(version) (\(build))")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
    }

    private func loadTasksAndAutomations() async {
        do {
            async let fetchedTasks = RovaBackendClient.fetchTasks()
            async let fetchedAutomations = RovaBackendClient.fetchAutomations()
            tasks = try await fetchedTasks
            automations = try await fetchedAutomations
            taskAutomationError = nil
        } catch {
            taskAutomationError = (error as? LocalizedError)?.errorDescription ?? "Görev ve otomasyonlar yüklenemedi."
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
                            quickActionsCard
                            mediaCard
                            displayCard
                            advancedPCSettingsSection
                        } else {
                            pairingPromptCard
                        }
                    } else {
                        pcUpsellCard
                    }
                }
                .padding(RovaDesign.screenPadding)
            }
            .background(RovaDesign.canvas)
            .navigationTitle("PC Ayarları")
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
        .confirmationDialog("PC'yi unutmak istediğine emin misin?", isPresented: $showingForgetMacConfirmation, titleVisibility: .visible) {
            Button("PC'yi unut", role: .destructive) { model.forgetPairing(); dismiss() }
            Button("Vazgeç", role: .cancel) { }
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
                            Text("\(device.platform) • \(device.capabilities.count) yetenek")
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
        .confirmationDialog("Bu cihazı listeden kaldırmak istediğine emin misin?", isPresented: Binding(
            get: { deletingDeviceID != nil },
            set: { if !$0 { deletingDeviceID = nil } }
        ), titleVisibility: .visible) {
            Button("Cihazı sil", role: .destructive) {
                guard let id = deletingDeviceID else { return }
                deletingDeviceID = nil
                backendDevices.removeAll { $0.id == id }
                Task { try? await RovaBackendClient.deleteDevice(id: id) }
            }
            Button("Vazgeç", role: .cancel) {}
        }
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
                    Label(status.macOSVersion, systemImage: "apple.logo")
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

    private var advancedPCSettingsSection: some View {
        RovaCard {
            DisclosureGroup {
                VStack(spacing: RovaDesign.cardSpacing) {
                    if !backendDevices.isEmpty { devicesCard }
                    capabilitiesCard
                    appsCard
                    clipboardCard
                    urlCard
                    connectionActionsCard
                    if !trustGrants.isEmpty { trustGrantsCard }
                    activityCard
                    if let error = model.lastError { errorCard(error) }
                }
                .padding(.top, 8)
            } label: {
                Label("Gelişmiş PC ayarları", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
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
        .confirmationDialog("PC kilitlenecek. Devam et?", isPresented: $showingLockConfirmation, titleVisibility: .visible) {
            Button("PC'yi kilitle", role: .destructive) {
                hapticImpact()
                Task {
                    let ok = await model.authenticateBiometrics(reason: "PC'yi kilitlemek için kimliğinizi doğrulayın")
                    if ok { _ = await model.send(.lockMac) }
                }
            }
            Button("Vazgeç", role: .cancel) { }
        }
        .confirmationDialog("PC uyku moduna alınacak. Devam et?", isPresented: $showingSleepConfirmation, titleVisibility: .visible) {
            Button("PC'yi uyut", role: .destructive) {
                hapticImpact()
                Task {
                    let ok = await model.authenticateBiometrics(reason: "PC'yi uykuya almak için kimliğinizi doğrulayın")
                    if ok { _ = await model.sleepMac() }
                }
            }
            Button("Vazgeç", role: .cancel) { }
        }
        .confirmationDialog("PC ekranı uyutulacak. Devam et?", isPresented: $showingDisplaySleepConfirmation, titleVisibility: .visible) {
            Button("Ekranı uyut", role: .destructive) {
                hapticImpact()
                Task { _ = await model.displaySleep() }
            }
            Button("Vazgeç", role: .cancel) { }
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
