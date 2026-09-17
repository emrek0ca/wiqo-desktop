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
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    var body: some View {
        ZStack {
            RovaDesign.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 32)
                brandHeader
                Spacer()
                formCard
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
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

    private var brandHeader: some View {
        VStack(spacing: 14) {
            Image("WiqoMark")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
            Text("Wiqo")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Kişisel AI asistanın, her yerde.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
        .background(RovaDesign.cardSurface, in: RoundedRectangle(cornerRadius: RovaDesign.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
    }

    private var switchModeLabel: Text {
        (isRegistering ? Text("Zaten hesabın var mı? ") : Text("Hesabın yok mu? "))
            + Text(isRegistering ? "Giriş yap" : "Kayıt ol").fontWeight(.semibold).foregroundStyle(RovaDesign.ink)
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 8 && !isSubmitting
    }

    private func submit() async {
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
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
                .onChange(of: code) { _, newValue in
                    code = String(newValue.filter(\.isNumber).prefix(6))
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

            Button("Kodu tekrar gönder") {
                withAnimation(.easeInOut(duration: 0.18)) { step = .requestCode }
                errorMessage = nil
                code = ""
            }
            .buttonStyle(.plain)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func requestCode() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await RovaBackendClient.forgotPassword(email: email)
            infoMessage = "\(email) adresine bir kod gönderildi. Gelmediyse spam/gereksiz klasörünü kontrol et."
            withAnimation(.easeInOut(duration: 0.18)) { step = .resetPassword }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
