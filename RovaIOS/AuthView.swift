import SwiftUI

/// Login/register screen for Wiqo's backend account. Only auth fields live here - no server
/// configuration, no explanatory copy, and no forced next step: `onAuthenticated()` drops the
/// user straight into chat. Pairing a Mac is a separate, entirely optional action from Settings.
struct AuthView: View {
    var onAuthenticated: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showingForgotPassword = false
    @State private var acceptedPrivacyPolicy = false
    @State private var acceptedTerms = false
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

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
                    Spacer()
                    formCard
                        .offset(y: -formCardLift(for: proxy.size.height))
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
                TextField("E-posta", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textFieldStyle(RovaAuthFieldStyle())
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }

                SecureField("Şifre", text: $password)
                    .textFieldStyle(RovaAuthFieldStyle())
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { if canSubmit { Task { await submit() } } }
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
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                focusedField = nil
                Task { await submit() }
            } label: {
                if isSubmitting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text(isRegistering ? "Hesap oluştur" : "Giriş yap")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSubmit)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
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
        .background(RovaDesign.cardSurface.opacity(0.92), in: RoundedRectangle(cornerRadius: RovaDesign.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: RovaDesign.cardRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
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
                    Image(systemName: isAccepted.wrappedValue ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(RovaDesign.ink)
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
                try await RovaBackendClient.register(email: email, password: password)
            } else {
                try await RovaBackendClient.login(email: email, password: password)
            }
            onAuthenticated()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "İşlem tamamlanamadı. Lütfen tekrar dene."
        }
    }
}

private struct RovaAuthFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    @State private var resendCooldownSecondsRemaining = 0
    @FocusState private var isCodeFieldFocused: Bool

    private enum Step { case requestCode, resetPassword }

    init(initialEmail: String, onCompleted: @escaping () -> Void) {
        self.initialEmail = initialEmail
        self.onCompleted = onCompleted
        _email = State(initialValue: initialEmail)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                switch step {
                case .requestCode: requestCodeForm
                case .resetPassword: resetPasswordForm
                }
                Spacer()
            }
            .padding(20)
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
        Group {
            Text("E-posta adresine 6 haneli bir sıfırlama kodu göndereceğiz.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("E-posta", text: $email)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textFieldStyle(RovaAuthFieldStyle())

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }

            Button {
                Task { await requestCode() }
            } label: {
                if isSubmitting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Kod gönder").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
        }
    }

    private var resetPasswordForm: some View {
        Group {
            if let infoMessage {
                Text(infoMessage).font(.subheadline).foregroundStyle(.secondary)
            }

            TextField("6 haneli kod", text: $code)
                .keyboardType(.numberPad)
                .textFieldStyle(RovaAuthFieldStyle())
                .focused($isCodeFieldFocused)
                .onChange(of: code) { _, newValue in
                    let sanitizedCode = String(newValue.filter(\.isNumber).prefix(6))
                    code = sanitizedCode
                    if sanitizedCode.count == 6 {
                        isCodeFieldFocused = false
                    }
                }

            SecureField("Yeni şifre (en az 8 karakter)", text: $newPassword)
                .textFieldStyle(RovaAuthFieldStyle())

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }

            Button {
                Task { await resetPassword() }
            } label: {
                if isSubmitting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Şifreyi sıfırla").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(code.count != 6 || newPassword.count < 8 || isSubmitting)

            Button(resendCooldownSecondsRemaining > 0 ? "Tekrar gönder (\(resendCooldownSecondsRemaining)sn)" : "Kodu tekrar gönder") {
                withAnimation(.easeInOut(duration: 0.18)) { step = .requestCode }
                errorMessage = nil
                code = ""
                resendCooldownSecondsRemaining = 0
            }
            .buttonStyle(.plain)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .disabled(resendCooldownSecondsRemaining > 0)
        }
    }

    private func requestCode() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await RovaBackendClient.forgotPassword(email: email)
            infoMessage = "\(email) adresine bir kod gönderildi. Gelmediyse spam/gereksiz klasörünü kontrol et."
            resendCooldownSecondsRemaining = 30
            withAnimation(.easeInOut(duration: 0.18)) { step = .resetPassword }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Şifre sıfırlama kodu istenemedi. Lütfen tekrar dene."
        }
    }

    private func resetPassword() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await RovaBackendClient.resetPassword(email: email, code: code, newPassword: newPassword)
            onCompleted()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Şifre sıfırlanamadı. Lütfen tekrar dene."
        }
    }
}
