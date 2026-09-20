import Foundation

/// The names this app stores its state under. An Xcode run is signed differently from the
/// installed app, so it keeps its own keychain items and paired-device records instead of asking
/// for access to (or overwriting) the installed app's.
enum MacStorage {
    #if DEBUG
    static let flavor = ".debug"
    #else
    static let flavor = ""
    #endif

    static let deviceIDKey = "rova.mac.device-id" + flavor
    static let pairedNameKey = "rova.mac.paired-name" + flavor
    static let pairedIDKey = "rova.mac.paired-id" + flavor
    static let welcomeCompletedKey = "rova.mac.welcome.completed" + flavor

    static let pairedTokenAccount = "paired-device-token" + flavor
    static let backendTokenAccount = "rova-backend-token" + flavor
    static let tlsCertificateLabel = "com.rova.local.tls-certificate" + flavor
    static let tlsKeyTag = Data(("com.rova.local.tls-key" + flavor).utf8)
}
