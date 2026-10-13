import PhotosUI
import SwiftUI

/// The signed-in user's profile as the backend's `/profile` endpoint returns it. Name, avatar and
/// form of address are shown in the app; tone, language, location and proactive suggestions are
/// read by Wiqo itself when it answers.
struct UserProfile: Codable, Equatable {
    var email: String
    var createdAt: String?
    var displayName: String?
    var preferredAddress: String?
    var avatarKind: String
    var avatarEmoji: String?
    var avatarColor: String?
    var avatarImage: String?
    var tone: String?
    var language: String?
    var location: String?
    var proactiveEnabled: Bool

    static func placeholder(email: String?) -> UserProfile {
        UserProfile(email: email ?? "", avatarKind: "initial", proactiveEnabled: false)
    }

    /// The name shown across the app: the chosen display name, otherwise the e-mail's local part.
    var visibleName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        return local.isEmpty ? String(localized: "Wiqo hesabı") : local
    }
}

/// Owns the profile for the current account. The last known copy is cached in a file namespaced by
/// the account id, so the avatar and name appear instantly on launch and never leak across accounts.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profile: UserProfile
    @Published private(set) var avatarImage: UIImage?

    private let cacheURL: URL?

    init() {
        let userID = RovaBackendClient.currentUserID
        cacheURL = userID.flatMap { id in
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("wiqo-profile-\(id).json")
        }
        var cached = UserProfile.placeholder(email: RovaBackendClient.currentUserEmail)
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode(UserProfile.self, from: data) {
            cached = decoded
        }
        profile = cached
        avatarImage = Self.decodeAvatar(cached)
    }

    func refresh() async {
        guard let fresh = try? await RovaBackendClient.fetchProfile() else { return }
        apply(fresh)
    }

    func update(_ changes: [String: Any]) async throws {
        guard !changes.isEmpty else { return }
        let body = try JSONSerialization.data(withJSONObject: changes)
        apply(try await RovaBackendClient.updateProfile(body: body))
    }

    private func apply(_ fresh: UserProfile) {
        if fresh.avatarImage != profile.avatarImage { avatarImage = Self.decodeAvatar(fresh) }
        profile = fresh
        guard let cacheURL, let data = try? JSONEncoder().encode(fresh) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: [.atomic, .completeFileProtection])
    }

    func clearCache() {
        if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
    }

    private static func decodeAvatar(_ profile: UserProfile) -> UIImage? {
        guard let base64 = profile.avatarImage, let data = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: data)
    }
}

enum AvatarPalette {
    static let keys = ["indigo", "blue", "teal", "green", "orange", "pink", "purple", "graphite"]

    static func color(_ key: String?) -> Color {
        switch key {
        case "blue": return Color(red: 0.16, green: 0.47, blue: 0.96)
        case "teal": return Color(red: 0.05, green: 0.62, blue: 0.64)
        case "green": return Color(red: 0.20, green: 0.66, blue: 0.33)
        case "orange": return Color(red: 0.95, green: 0.52, blue: 0.13)
        case "pink": return Color(red: 0.91, green: 0.29, blue: 0.53)
        case "purple": return Color(red: 0.55, green: 0.33, blue: 0.90)
        case "graphite": return Color(red: 0.36, green: 0.39, blue: 0.44)
        default: return Color(red: 0.33, green: 0.36, blue: 0.86)
        }
    }

    static let emojis = ["😀", "😎", "🤓", "🧑‍💻", "🚀", "🌟", "🔥", "🎧", "🎨", "📚", "⚡️", "🌿", "🐱", "🦊", "🐼", "🦁", "🍀", "☕️", "🎯", "🏔️", "🌊", "🎮", "🧠", "💼"]
}

/// One avatar everywhere (sidebar, settings, profile editor): photo, emoji on a color, or the
/// name's initial on a color.
struct AvatarView: View {
    let profile: UserProfile
    var image: UIImage?
    var size: CGFloat = 32

    var body: some View {
        Group {
            if profile.avatarKind == "photo", let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [AvatarPalette.color(profile.avatarColor), AvatarPalette.color(profile.avatarColor).opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    if profile.avatarKind == "emoji", let emoji = profile.avatarEmoji, !emoji.isEmpty {
                        Text(emoji).font(.system(size: size * 0.52))
                    } else {
                        Text(String(profile.visibleName.prefix(1)).uppercased())
                            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// Account and profile live on one page. Profile edits stay local until "Kaydet" is tapped.
struct AccountSettingsView: View {
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject var authSession: AuthSessionStore
    @ObservedObject var subscriptionStore: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: UserProfile
    @State private var draftImage: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingDeleteAccount = false
    @State private var showingSignOutConfirmation = false
    @State private var showingPaywall = false
    @State private var accountInfo: RovaBackendClient.AccountInfo?
    @State private var inviteCodes: [RovaBackendClient.InviteCode] = []
    @State private var deletePassword = ""
    @State private var isDeleting = false

    init(profileStore: ProfileStore, authSession: AuthSessionStore, subscriptionStore: SubscriptionStore) {
        self.profileStore = profileStore
        self.authSession = authSession
        self.subscriptionStore = subscriptionStore
        _draft = State(initialValue: profileStore.profile)
        _draftImage = State(initialValue: profileStore.avatarImage)
    }

    private var hasChanges: Bool { draft != profileStore.profile }

    var body: some View {
        Form {
            avatarSection
            Section {
                LabeledContent("Ad") {
                    TextField("Adın", text: binding(\.displayName))
                        .multilineTextAlignment(.trailing)
                        .textContentType(.name)
                }
                LabeledContent("Hitap") {
                    TextField("Örn. Emre, Hocam", text: binding(\.preferredAddress))
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Kimlik")
            } footer: {
                Text("Wiqo sana bu şekilde hitap eder.")
            }

            Section {
                LabeledContent("Konum") {
                    TextField("Örn. İstanbul", text: binding(\.location))
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Kişiselleştirme")
            } footer: {
                Text("Konum; hava durumu ve yakındaki öneriler için kullanılır.")
            }

            Section("Hesap") {
                LabeledContent("E-posta", value: draft.email)
                if let joined = joinedText {
                    LabeledContent("Üyelik", value: joined)
                }
            }

            if accountInfo?.isFoundingMember == true || firstUnusedInviteCode != nil {
                Section("Arkadaşını davet et") {
                    if accountInfo?.isFoundingMember == true {
                        Label("Kurucu üye", systemImage: "seal.fill")
                    }
                    if let code = firstUnusedInviteCode {
                        ShareLink(item: WiqoGrowth.inviteMessage(code: code)) {
                            Label(code, systemImage: "gift.fill")
                        }
                    }
                }
            }

            Section {
                Button("Hesabı sil", role: .destructive) {
                    deletePassword = ""
                    showingDeleteAccount = true
                }
                .disabled(isDeleting)
            } footer: {
                Text("Hesabın, sohbet hafızan, otomasyonların ve eşleşmiş cihazların kalıcı olarak silinir.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(RovaDesign.canvas)
        .navigationTitle("Profil")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Kaydet") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(!hasChanges)
                }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .task {
            async let fetchedAccount = try? RovaBackendClient.fetchAccountInfo()
            async let fetchedCodes = try? RovaBackendClient.fetchInviteCodes()
            accountInfo = await fetchedAccount
            inviteCodes = (await fetchedCodes) ?? []
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(subscriptionStore: subscriptionStore)
        }
        .wiqoConfirmation(String(localized: "Wiqo hesabından çıkmak istediğine emin misin?"), isPresented: $showingSignOutConfirmation) {
            Button("Çıkış yap", role: .destructive) { authSession.signOut(); dismiss() }
        }
        .onChange(of: profileStore.profile) { old, fresh in
            // Adopt a background refresh only while the user hasn't started editing.
            if draft == old {
                draft = fresh
                draftImage = profileStore.avatarImage
            }
        }
        .alert("Hata", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Tamam", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Hesabı kalıcı olarak sil", isPresented: $showingDeleteAccount) {
            SecureField("Şifre", text: $deletePassword)
            Button("Hesabı sil", role: .destructive) { Task { await deleteAccount() } }
            Button("Vazgeç", role: .cancel) { }
        } message: {
            Text("Bu işlem geri alınamaz. Onaylamak için şifreni gir.")
        }
    }

    private var firstUnusedInviteCode: String? {
        inviteCodes.first(where: { !$0.used })?.code
    }

    private var avatarSection: some View {
        Section {
            VStack(spacing: 16) {
                AvatarView(profile: draft, image: draftImage, size: 96)
                    .padding(.top, 6)
                Text(draft.visibleName)
                    .font(.title3.weight(.semibold))

                Picker("Avatar", selection: $draft.avatarKind) {
                    Text("Harf").tag("initial")
                    Text("Emoji").tag("emoji")
                    Text("Fotoğraf").tag("photo")
                }
                .pickerStyle(.segmented)

                switch draft.avatarKind {
                case "photo":
                    let pickerTitle = draftImage == nil ? String(localized: "Fotoğraf seç") : String(localized: "Fotoğrafı değiştir")
                    PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                        Label(pickerTitle, systemImage: "photo.on.rectangle")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.wiqoPill(.secondary))
                case "emoji":
                    emojiGrid
                    colorRow
                default:
                    colorRow
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .listRowBackground(Color.clear)
    }

    private var emojiGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
            ForEach(AvatarPalette.emojis, id: \.self) { emoji in
                Button {
                    draft.avatarEmoji = emoji
                } label: {
                    Text(emoji)
                        .font(.system(size: 22))
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(draft.avatarEmoji == emoji ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Emoji \(emoji)")
            }
        }
    }

    private var colorRow: some View {
        HStack(spacing: 10) {
            ForEach(AvatarPalette.keys, id: \.self) { key in
                let selected = (draft.avatarColor ?? "indigo") == key
                Button {
                    draft.avatarColor = key
                } label: {
                    Circle()
                        .fill(AvatarPalette.color(key))
                        .frame(width: 28, height: 28)
                        .overlay {
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? AvatarPalette.color(key) : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Renk \(key)")
            }
        }
    }

    private var joinedText: String? {
        guard let createdAt = draft.createdAt else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = parser.date(from: createdAt) else { return nil }
        return date.formatted(date: .long, time: .omitted)
    }

    /// Binds an optional text field of the draft; an empty field means "not set".
    private func binding(_ keyPath: WritableKeyPath<UserProfile, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let square = Self.squareThumbnail(image, side: 256),
              let jpeg = square.jpegData(compressionQuality: 0.82) else {
            errorMessage = String(localized: "Fotoğraf yüklenemedi.")
            return
        }
        draft.avatarImage = jpeg.base64EncodedString()
        draft.avatarKind = "photo"
        draftImage = square
    }

    private static func squareThumbnail(_ image: UIImage, side: CGFloat) -> UIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = side / min(size.width, size.height)
        let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2, width: drawSize.width, height: drawSize.height))
        }
    }

    private func save() async {
        let original = profileStore.profile
        var changes: [String: Any] = [:]
        func put(_ key: String, _ value: String?, _ old: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
            if normalized != old { changes[key] = normalized ?? NSNull() }
        }
        put("displayName", draft.displayName, original.displayName)
        put("preferredAddress", draft.preferredAddress, original.preferredAddress)
        put("avatarEmoji", draft.avatarEmoji, original.avatarEmoji)
        put("avatarColor", draft.avatarColor, original.avatarColor)
        put("avatarImage", draft.avatarImage, original.avatarImage)
        put("tone", draft.tone, original.tone)
        put("language", draft.language, original.language)
        put("location", draft.location, original.location)
        if draft.avatarKind == "photo" && draft.avatarImage == nil {
            errorMessage = String(localized: "Fotoğraf avatarı için önce bir fotoğraf seç.")
            return
        }
        if draft.avatarKind != original.avatarKind { changes["avatarKind"] = draft.avatarKind }
        if draft.proactiveEnabled != original.proactiveEnabled { changes["proactiveEnabled"] = draft.proactiveEnabled }

        isSaving = true
        defer { isSaving = false }
        do {
            try await profileStore.update(changes)
            draft = profileStore.profile
            draftImage = profileStore.avatarImage
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch RovaBackendError.notAuthenticated {
            authSession.signOut()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func deleteAccount() async {
        let password = deletePassword
        deletePassword = ""
        guard !password.isEmpty else {
            errorMessage = String(localized: "Hesabı silmek için şifreni gir.")
            return
        }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await RovaBackendClient.deleteAccount(password: password)
            // Local copies go too, while the account id is still known for their namespace.
            CopilotConversationStore.removeAllForCurrentUser()
            profileStore.clearCache()
            SubscriptionStore.clearCacheForCurrentUser()
            authSession.signOut()
        } catch RovaBackendError.notAuthenticated {
            authSession.signOut()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
