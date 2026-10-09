import SwiftUI

/// General account settings only - profile, plan, background tasks/automations, and sign-out.
/// PC pairing/control lives entirely in PCSettingsView (reached from the chat toolbar's
/// connection icon, or from the "PC ayarları" row below) so this screen never needs to load or
/// react to device/connection state at all.
struct SettingsView: View {
    @ObservedObject var model: IOSConnectionModel
    @ObservedObject var authSession: AuthSessionStore
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject var subscriptionStore: SubscriptionStore
    /// What the Görevler row says at a glance: how many things are running and how many need a look.
    @State private var runningCount = 0
    @State private var attentionCount = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var oauthProviders: [RovaBackendClient.OAuthProviderInfo] = RovaBackendClient.OAuthProviderInfo.builtIn
    @State private var oauthConnections: [RovaBackendClient.OAuthConnection] = []
    @State private var showingApps = false
    @State private var showingSignOutConfirmation = false
    @State private var styleError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    profileCard
                    subscriptionGroup
                    connectionsGroup
                    styleGroup
                    workGroup
                    supportGroup
                }
                .padding(.horizontal, RovaDesign.screenPadding)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .background(RovaDesign.canvas)
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
            .wiqoConfirmation(String(localized: "Wiqo hesabından çıkmak istediğine emin misin?"), isPresented: $showingSignOutConfirmation) {
                Button("Çıkış yap", role: .destructive) { authSession.signOut(); dismiss() }
            }
        }
        .wiqoToastHost(level: 1)
        .task {
            async let work: Void = loadWorkSummary()
            async let connections: Void = loadConnections()
            async let plan: Void = subscriptionStore.refreshIfStale(maxAge: 60)
            _ = await (work, connections, plan)
        }
    }

    // MARK: Profile and plan

    private var profileCard: some View {
        VStack(spacing: 12) {
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
                    WiqoChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        }
        .padding(14)
        .wiqoGlass()
    }

    private var subscriptionGroup: some View {
        let info = subscriptionStore.info
        return WiqoSettingsGroup {
            NavigationLink {
                SubscriptionView(subscriptionStore: subscriptionStore)
            } label: {
                WiqoRow(
                    systemImage: "infinity",
                    title: String(localized: "Abonelik"),
                    subtitle: String(localized: "Bugün \(info.usage.messages.used)/\(info.usage.messages.limit) mesaj"),
                    showsDivider: false
                ) {
                    HStack(spacing: 6) {
                        Text(info.tier == "free" ? String(localized: "Pro'ya geç") : info.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(info.tier == "free" ? Color.accentColor : Color.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(WiqoTheme.tint(info.tier == "free" ? Color.accentColor : Color.secondary), in: Capsule())
                        WiqoChevron()
                    }
                }
            }
            .buttonStyle(WiqoRowButtonStyle())
        }
    }

    // MARK: Connections

    private var connectionsGroup: some View {
        WiqoSettingsGroup(title: String(localized: "Bağlantılar")) {
            NavigationLink {
                PCSettingsView(model: model, subscriptionStore: subscriptionStore)
            } label: {
                WiqoRow(systemImage: "laptopcomputer", title: "PC", showsDivider: true) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.isPaired && model.userFacingConnectionLabel != String(localized: "PC kapalı") ? WiqoTheme.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(model.isPaired ? model.userFacingConnectionLabel : String(localized: "Bağla"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        WiqoChevron()
                    }
                }
            }
            .buttonStyle(WiqoRowButtonStyle())

            Button { showingApps = true } label: {
                WiqoRow(systemImage: "square.grid.2x2", title: String(localized: "Uygulamalar"), showsDivider: false) {
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
        return names.count <= 2 ? names.joined(separator: ", ") : String(localized: "\(connected) bağlı")
    }

    private func loadConnections() async {
        async let providers = RovaBackendClient.fetchOAuthProviders()
        async let connections = try? RovaBackendClient.fetchOAuthConnections()
        oauthProviders = await providers
        oauthConnections = (await connections) ?? oauthConnections
    }

    // MARK: Style (saved as it changes)

    private var styleGroup: some View {
        WiqoSettingsGroup(title: String(localized: "Wiqo'nun tarzı")) {
            WiqoRow(systemImage: "text.bubble", title: String(localized: "Yanıt tonu"), showsDivider: true) {
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
            WiqoRow(systemImage: "globe", title: String(localized: "Yanıt dili"), showsDivider: true) {
                Picker("Yanıt dili", selection: styleBinding(\.language, key: "language")) {
                    Text("Otomatik").tag(String?.none)
                    Text("Türkçe").tag(String?.some("tr"))
                    Text("English").tag(String?.some("en"))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.secondary)
            }
            WiqoRow(systemImage: "lightbulb", title: String(localized: "Proaktif öneriler"), showsDivider: false) {
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
                styleError = String(localized: "Kaydedilemedi. Bağlantını kontrol edip tekrar dene.")
            }
        }
    }

    // MARK: Wiqo's work

    private var workGroup: some View {
        WiqoSettingsGroup(title: String(localized: "Wiqo'nun işleri")) {
            NavigationLink { WiqoWorkView() } label: {
                WiqoRow(systemImage: "checklist", title: String(localized: "Görevler"), showsDivider: true) {
                    HStack(spacing: 6) {
                        if attentionCount > 0 {
                            Text("\(attentionCount) incele")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(WiqoTheme.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(WiqoTheme.tint(WiqoTheme.orange), in: Capsule())
                        } else if runningCount > 0 {
                            Text("\(runningCount)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        WiqoChevron()
                    }
                }
            }
            .buttonStyle(WiqoRowButtonStyle())
            NavigationLink { WiqoGoalsView() } label: {
                WiqoRow(systemImage: "target", title: String(localized: "Hedefler"), showsDivider: false)
            }
            .buttonStyle(WiqoRowButtonStyle())
        }
    }

    private func loadWorkSummary() async {
        async let tasks = try? RovaBackendClient.fetchAgentTasks()
        async let review = try? RovaBackendClient.fetchAutomationReview()
        let (taskList, reviewList) = await (tasks, review)
        runningCount = taskList?.filter(\.isActive).count ?? runningCount
        attentionCount = (reviewList?.count ?? 0) + (taskList?.filter { $0.waiting != nil }.count ?? 0)
    }

    // MARK: Support and sign-out

    private var supportGroup: some View {
        WiqoSettingsGroup {
            NavigationLink { legalPage } label: {
                WiqoRow(systemImage: "questionmark.circle", title: String(localized: "Destek ve yasal"), showsDivider: true)
            }
            .buttonStyle(WiqoRowButtonStyle())
            Button { showingSignOutConfirmation = true } label: {
                WiqoRow(systemImage: "rectangle.portrait.and.arrow.right", title: String(localized: "Çıkış yap"), isDestructive: true, showsDivider: false) { EmptyView() }
            }
            .buttonStyle(WiqoRowButtonStyle())
        }
    }

    private var legalPage: some View {
        ScrollView {
            legalSection
                .padding(RovaDesign.screenPadding)
        }
        .background(RovaDesign.canvas)
        .navigationTitle("Destek ve yasal")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Legal and account

    /// App Store Connect's Support URL is required to actually resolve to something useful, and
    /// Guideline 5.1.1 expects the same legal documents referenced at signup/purchase to also be
    /// reachable from within the app proper - not just at the point of purchase.
    private var legalSection: some View {
        WiqoSettingsGroup(title: String(localized: "Yasal ve destek")) {
            legalRow(String(localized: "Gizlilik Politikası"), systemImage: "hand.raised", url: WiqoWebsite.privacyPolicyURL)
            legalRow(String(localized: "Kullanım Şartları"), systemImage: "doc.text", url: WiqoWebsite.termsOfServiceURL)
            legalRow(String(localized: "Destek"), systemImage: "questionmark.circle", url: WiqoWebsite.supportURL, showsDivider: false)
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
}
