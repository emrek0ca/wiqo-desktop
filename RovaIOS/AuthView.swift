import SwiftUI

/// Login/register screen for Rova's backend account. Only auth fields live here - no server
/// configuration, no explanatory copy.
struct AuthView: View {
    var onAuthenticated: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("E-posta", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                    SecureField("Şifre", text: $password)
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
                            ProgressView()
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
            }
            .navigationTitle("Rova")
        }
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
