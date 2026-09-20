import AppIntents
import Foundation

/// Siri/Shortcuts/Action Button entry points for the handful of PC actions worth a single voice
/// command or lock-screen tap. Deliberately goes through `RovaBackendClient.sendDeviceCommand`
/// (the backend relay), never `IOSConnectionModel`'s direct local-network socket - an intent can
/// fire with the app not running and no owning view around to hold that live connection, while
/// the relay only needs a stored auth token and a paired PC, exactly like the in-app fallback
/// already used when the phone isn't on the same network as the PC.
enum WiqoIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case deviceFailure(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: return "Önce Wiqo'ya giriş yap."
        case .deviceFailure(let message): return LocalizedStringResource(stringLiteral: message)
        }
    }
}

/// Reads the same device-pairing token IOSConnectionModel stores under "ios-device-token" -
/// there is no live IOSConnectionModel instance to ask when an intent fires with the app not
/// running, so this reads Keychain directly instead. Without a signature the Mac now rejects the
/// relayed command outright (see MacBackendChannel.executeInteractiveCommand), matching the direct
/// path's and the in-app relay fallback's trust requirement.
private func pairedDeviceToken() -> String? {
    guard let data = try? RovaKeychainStore.load(account: "ios-device-token") else { return nil }
    return String(data: data, encoding: .utf8)
}

private func performDeviceIntent(_ type: CommandType, payload: CommandPayload = .none, successMessage: String) async throws -> some IntentResult & ProvidesDialog {
    guard RovaBackendClient.isAuthenticated else { throw WiqoIntentError.notSignedIn }
    do {
        let commandID = UUID()
        let nonce = try? RovaCrypto.randomToken()
        let signature = pairedDeviceToken().map { RovaValidation.signRequest(id: commandID, type: type, nonce: nonce ?? "", token: $0) }
        let request = CommandRequest(id: commandID, type: type, payload: payload, signature: signature, nonce: nonce)
        let result = try await RovaBackendClient.sendDeviceCommand(request, deviceId: nil)
        if let error = result.error { throw WiqoIntentError.deviceFailure(error.message) }
        return .result(dialog: IntentDialog(stringLiteral: successMessage))
    } catch let error as WiqoIntentError {
        throw error
    } catch let error as LocalizedError {
        throw WiqoIntentError.deviceFailure(error.errorDescription ?? "Komut gönderilemedi.")
    } catch {
        throw WiqoIntentError.deviceFailure("Komut gönderilemedi.")
    }
}

struct LockPCIntent: AppIntent {
    static let title: LocalizedStringResource = "PC'yi Kilitle"
    static let description = IntentDescription("Wiqo ile eşleştirilmiş PC'yi uzaktan kilitler.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await performDeviceIntent(.lockMac, successMessage: "PC kilitlendi.")
    }
}

struct SleepPCIntent: AppIntent {
    static let title: LocalizedStringResource = "PC'yi Uyut"
    static let description = IntentDescription("Wiqo ile eşleştirilmiş PC'yi uyku moduna alır.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await performDeviceIntent(.sleepMac, successMessage: "PC uyku moduna alındı.")
    }
}

struct ToggleMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Sesi Kıs"
    static let description = IntentDescription("Wiqo ile eşleştirilmiş PC'nin sesini kısar veya açar.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await performDeviceIntent(.toggleMute, successMessage: "Ses durumu değiştirildi.")
    }
}

struct MediaPlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Müziği Oynat/Duraklat"
    static let description = IntentDescription("Wiqo ile eşleştirilmiş PC'de oynatmayı durdurur ya da devam ettirir.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await performDeviceIntent(.mediaControl, payload: .media(.playPause), successMessage: "Oynatma değiştirildi.")
    }
}

struct WiqoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LockPCIntent(),
            phrases: ["\(.applicationName) ile PC'mi kilitle"],
            shortTitle: "PC'yi Kilitle",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: SleepPCIntent(),
            phrases: ["\(.applicationName) ile PC'mi uyut"],
            shortTitle: "PC'yi Uyut",
            systemImageName: "moon.fill"
        )
        AppShortcut(
            intent: ToggleMuteIntent(),
            phrases: ["\(.applicationName) ile sesi kıs"],
            shortTitle: "Sesi Kıs",
            systemImageName: "speaker.slash.fill"
        )
        AppShortcut(
            intent: MediaPlayPauseIntent(),
            phrases: ["\(.applicationName) ile müziği duraklat"],
            shortTitle: "Oynat/Duraklat",
            systemImageName: "playpause.fill"
        )
    }
}
