import SwiftUI

/// Login/register screen for Wiqo's backend account. Only auth fields live here - no server
/// configuration, no explanatory copy, and no forced next step: `onAuthenticated()` drops the
/// user straight into chat. Pairing a Mac is a separate, entirely optional action from Settings.
struct AuthView: View {
    var onAuthenticated: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var inviteCode = ""
    @State private var isRegistering = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showingForgotPassword = false
    @State private var acceptedPrivacyPolicy = false
    @State private var acceptedTerms = false
    @State private var showsPassword = false
    @State private var errorTick = 0
    @FocusState private var focusedField: Field?

    private enum Field { case email, password, inviteCode }

    var body: some View {
        ZStack {
            RovaDesign.canvas.ignoresSafeArea()

            // Keep the decorative layer fixed while only the interactive content reflows for the keyboard.
            GeometryReader { proxy in
                authBackground(size: proxy.size)
            }
            .ignoresSafeArea()

            GeometryReader { proxy in
                VStack(spacing: 0) {
                    Spacer(minLength: 32)
                    brandHeader
                        .offset(y: -brandHeaderLift(for: proxy.size.height))
                        .wiqoRiseIn()
                    Spacer()
                    formCard
                        .offset(y: -formCardLift(for: proxy.size.height))
                        .wiqoRiseIn(delay: 0.12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { focusedField = nil }
        .sheet(isPresented: $showingForgotPassword) {
            ForgotPasswordView(initialEmail: email) {
                showingForgotPassword = false
                onAuthenticated()
            }
        }
    }

    private func authBackground(size: CGSize) -> some View {
        return Image("WiqoBackground")
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
            // The image belongs to the lower canvas; its upper edge should dissolve naturally.
            .mask(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.28), location: 0.08),
                        .init(color: .black, location: 0.24),
                        .init(color: .black, location: 1)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .opacity(0.78)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func brandHeaderLift(for height: CGFloat) -> CGFloat {
        min(max(height * 0.07, 28), 56)
    }

    private func formCardLift(for height: CGFloat) -> CGFloat {
        min(max(height * 0.08, 32), 72)
    }

    private var brandHeader: some View {
        VStack(spacing: 6) {
            Image("WiqoMark")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .shadow(color: RovaDesign.ink.opacity(0.2), radius: 7, y: 3)
            Text("Wiqo")
                .font(.system(size: 32, weight: .bold, design: .rounded))
        }
    }

    private var formCard: some View {
        VStack(spacing: 14) {
            Text(isRegistering ? "Hesap oluştur" : "Giriş yap")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 10) {
                WiqoField(isFocused: focusedField == .email, hasError: errorMessage != nil) {
                    TextField("E-posta", text: $email)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                }

                WiqoField(isFocused: focusedField == .password, hasError: errorMessage != nil) {
                    HStack(spacing: 8) {
                        Group {
                            if showsPassword {
                                TextField("Şifre", text: $password)
                            } else {
                                SecureField("Şifre", text: $password)
                            }
                        }
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(isRegistering ? .newPassword : .password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(isRegistering ? .next : .go)
                        .onSubmit {
                            if isRegistering { focusedField = .inviteCode } else if canSubmit { Task { await submit() } }
                        }

                        Button {
                            showsPassword.toggle()
                        } label: {
                            Image(systemName: showsPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showsPassword ? "Şifreyi gizle" : "Şifreyi göster")
                    }
                }

                if isRegistering {
                    WiqoField(isFocused: focusedField == .inviteCode) {
                        TextField("Davet kodu (opsiyonel)", text: $inviteCode)
                            .textFieldStyle(.plain)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .inviteCode)
                            .submitLabel(.go)
                            .onSubmit { if canSubmit { Task { await submit() } } }
                    }
                    .transition(.wiqoBlur)
                }
            }

            if isRegistering && inviteCode.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Bir arkadaşının davet kodu varsa gir - ikiniz de 14 gün Pro kazanırsınız.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !isRegistering {
                Button("Şifremi unuttum") {
                    focusedField = nil
                    showingForgotPassword = true
                }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if isRegistering {
                registrationConsents
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(WiqoTheme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.wiqoBlur)
            }

            WiqoActionButton(title: isRegistering ? "Hesap oluştur" : "Giriş yap", isLoading: isSubmitting) {
                focusedField = nil
                Task { await submit() }
            }
            .disabled(!canSubmit && !isSubmitting)

            Button {
                withAnimation(WiqoMotion.slide()) {
                    isRegistering.toggle()
                    errorMessage = nil
                }
            } label: {
                switchModeLabel
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .wiqoCard(radius: RovaDesign.cardRadius)
        .wiqoShake(trigger: errorTick)
        .wiqoAnimation(WiqoMotion.slide(), value: errorMessage)
    }

    private var switchModeLabel: Text {
        (isRegistering ? Text("Zaten hesabın var mı? ") : Text("Hesabın yok mu? "))
            + Text(isRegistering ? "Giriş yap" : "Kayıt ol").fontWeight(.semibold).foregroundStyle(RovaDesign.ink)
    }

    private var registrationConsents: some View {
        VStack(alignment: .leading, spacing: 10) {
            consentRow(
                title: "Gizlilik Politikası'nı okudum ve kabul ediyorum.",
                linkTitle: "Gizlilik Politikası'nı aç",
                destination: WiqoWebsite.privacyPolicyURL,
                isAccepted: $acceptedPrivacyPolicy
            )
            consentRow(
                title: "Kullanım Şartları'nı okudum ve kabul ediyorum.",
                linkTitle: "Kullanım Şartları'nı aç",
                destination: WiqoWebsite.termsOfServiceURL,
                isAccepted: $acceptedTerms
            )
        }
    }

    private func consentRow(
        title: String,
        linkTitle: String,
        destination: URL,
        isAccepted: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isAccepted.wrappedValue.toggle()
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    WiqoCheckbox(isOn: isAccepted.wrappedValue)
                    Text(title)
                        .font(.footnote)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(title)
            .accessibilityValue(isAccepted.wrappedValue ? "Seçili" : "Seçili değil")

            Link(linkTitle, destination: destination)
                .font(.caption.weight(.medium))
                .padding(.leading, 32)
        }
    }

    private var canSubmit: Bool {
        let credentialsAreValid = !email.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 8
        let consentsAreValid = !isRegistering || (acceptedPrivacyPolicy && acceptedTerms)
        return credentialsAreValid && consentsAreValid && !isSubmitting
    }

    private func submit() async {
        guard canSubmit else { return }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            if isRegistering {
                try await RovaBackendClient.register(email: email, password: password, inviteCode: inviteCode)
            } else {
                try await RovaBackendClient.login(email: email, password: password)
            }
            onAuthenticated()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "İşlem tamamlanamadı. Lütfen tekrar dene."
            errorTick += 1
            WiqoHaptics.failure()
        }
    }
}

/// The consent box: an empty well that fills and draws its check when accepted.
private struct WiqoCheckbox: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isOn ? WiqoTheme.ink : WiqoTheme.inset)
            .frame(width: 22, height: 22)
            .overlay {
                if isOn {
                    WiqoCheckmark(color: Color(uiColor: .systemBackground), lineWidth: 2)
                        .padding(4)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(WiqoTheme.lineStrong, lineWidth: 1)
                }
            }
            .wiqoAnimation(WiqoMotion.ease(0.2), value: isOn)
            .accessibilityHidden(true)
    }
}

/// Two steps in one sheet: request a 6-digit code by email, then use it (plus a new password) to
/// actually reset - never both fields at once, so there's no confusing moment where a code field
/// sits empty above a password field before the user has even asked for a code yet. Successfully
/// resetting also signs the user in (the backend returns a fresh token either way - see
/// RovaBackendClient.resetPassword), so this sheet's completion handler goes straight to
/// `onAuthenticated()`, same as a normal login.
struct ForgotPasswordView: View {
    let initialEmail: String
    var onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var email: String
    @State private var code = ""
    @State private var newPassword = ""
    @State private var step: Step = .requestCode
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var errorTick = 0
    @State private var resendCooldownSecondsRemaining = 0
    @FocusState private var focusedField: ResetField?

    private enum Step { case requestCode, resetPassword }
    private enum ResetField { case email, password }

    init(initialEmail: String, onCompleted: @escaping () -> Void) {
        self.initialEmail = initialEmail
        self.onCompleted = onCompleted
        _email = State(initialValue: initialEmail)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                switch step {
                case .requestCode:
                    requestCodeForm
                        .transition(.wiqoBlur)
                case .resetPassword:
                    resetPasswordForm
                        .transition(.wiqoBlur)
                }
                Spacer()
            }
            .padding(20)
            .wiqoShake(trigger: errorTick)
            .wiqoAnimation(WiqoMotion.slide(), value: step)
            .navigationTitle("Şifremi Unuttum")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
        .task(id: resendCooldownSecondsRemaining > 0) {
            guard resendCooldownSecondsRemaining > 0 else { return }
            while !Task.isCancelled && resendCooldownSecondsRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, resendCooldownSecondsRemaining > 0 else { return }
                resendCooldownSecondsRemaining -= 1
            }
        }
    }

    private var requestCodeForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("E-posta adresine 6 haneli bir sıfırlama kodu göndereceğiz.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            WiqoField(isFocused: focusedField == .email, hasError: errorMessage != nil) {
                TextField("E-posta", text: $email)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
                    .submitLabel(.send)
                    .onSubmit { if canRequestCode { Task { await requestCode() } } }
            }

            errorText

            WiqoActionButton(title: "Kod gönder", isLoading: isSubmitting) {
                Task { await requestCode() }
            }
            .disabled(!canRequestCode && !isSubmitting)
        }
    }

    private var resetPasswordForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let infoMessage {
                Text(infoMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            WiqoOTPField(code: $code, hasError: errorMessage != nil, autoFocus: true)
                .onChange(of: code) { _, newValue in
                    if newValue.count == 6 { focusedField = .password }
                }

            WiqoField(isFocused: focusedField == .password, hasError: false) {
                SecureField("Yeni şifre (en az 8 karakter)", text: $newPassword)
                    .textFieldStyle(.plain)
                    .textContentType(.newPassword)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { if canResetPassword { Task { await resetPassword() } } }
            }

            errorText

            WiqoActionButton(title: "Şifreyi sıfırla", isLoading: isSubmitting) {
                Task { await resetPassword() }
            }
            .disabled(!canResetPassword && !isSubmitting)

            Button(resendCooldownSecondsRemaining > 0 ? "Tekrar gönder (\(resendCooldownSecondsRemaining)sn)" : "Kodu tekrar gönder") {
                errorMessage = nil
                code = ""
                resendCooldownSecondsRemaining = 0
                step = .requestCode
            }
            .buttonStyle(.plain)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .disabled(resendCooldownSecondsRemaining > 0)
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(WiqoTheme.red)
                .transition(.wiqoBlur)
        }
    }

    private var canRequestCode: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty && !isSubmitting
    }

    private var canResetPassword: Bool {
        code.count == 6 && newPassword.count >= 8 && !isSubmitting
    }

    private func fail(_ message: String) {
        errorMessage = message
        errorTick += 1
        WiqoHaptics.failure()
    }

    private func requestCode() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await RovaBackendClient.forgotPassword(email: email)
            infoMessage = "\(email) adresine bir kod gönderildi. Gelmediyse spam/gereksiz klasörünü kontrol et."
            resendCooldownSecondsRemaining = 30
            step = .resetPassword
        } catch {
            fail((error as? LocalizedError)?.errorDescription ?? "Şifre sıfırlama kodu istenemedi. Lütfen tekrar dene.")
        }
    }

    private func resetPassword() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await RovaBackendClient.resetPassword(email: email, code: code, newPassword: newPassword)
            WiqoHaptics.success()
            onCompleted()
        } catch {
            fail((error as? LocalizedError)?.errorDescription ?? "Şifre sıfırlanamadı. Lütfen tekrar dene.")
        }
    }
}
