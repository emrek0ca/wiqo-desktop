import SwiftUI

/// Login/register screen for Rova's backend account, required only for the AI copilot feature.
/// Mac pairing and manual control stay fully local and are never gated by this.
struct AuthView: View {
    var onAuthenticated: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var backendURLText = RovaBackendConfig.baseURL.absoluteString

    var body: some View {
        NavigationStack {
            Form {
                Section("Rova Hesabı") {
                    TextField("E-posta", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                    SecureField("Şifre (en az 8 karakter)", text: $password)
                    Picker("Mod", selection: $isRegistering) {
                        Text("Giriş Yap").tag(false)
                        Text("Kayıt Ol").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            HStack { ProgressView(); Text("Bağlanıyor…") }
                        } else {
                            Text(isRegistering ? "Kayıt Ol" : "Giriş Yap")
                        }
                    }
                    .disabled(
                        email.trimmingCharacters(in: .whitespaces).isEmpty
                            || password.count < 8 || isSubmitting
                    )
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                Section("Sunucu Adresi") {
                    TextField("http://…", text: $backendURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Rova AI'nin bağlandığı sunucu. Simülatörde varsayılan (localhost) çalışır; fiziksel cihazda test ederken Mac'inin yerel ağ adresini gir (ör. http://192.168.1.5:4000).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Rova AI Girişi")
        }
    }

    private func submit() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        if let url = URL(string: backendURLText.trimmingCharacters(in: .whitespaces)) {
            RovaBackendConfig.baseURL = url
        }
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
