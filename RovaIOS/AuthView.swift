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
