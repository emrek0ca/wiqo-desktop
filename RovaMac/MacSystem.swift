import Foundation

struct MacAutomationTarget: Identifiable, Sendable {
    let id: String
    let title: String
    let bundleIdentifier: String
}

enum MacAutomationPermissionStatus: Sendable {
    case granted
    case denied
    case notChecked
    case unavailable
}

struct MacAutomationPermission: Identifiable, Sendable {
    let id: String
    let title: String
    let bundleIdentifier: String
    let status: MacAutomationPermissionStatus
    let message: String?

    var granted: Bool { status == .granted }
}

struct MacShortcutInstallationResult: Sendable {
    let alreadyInstalled: [WiqoShortcut]
    let openedForApproval: [WiqoShortcut]
    let missingResources: [WiqoShortcut]
}

/// Everything the Mac can do on the phone's behalf, grouped by topic in the `MacSystem+*.swift`
/// files next to this one: applications, permissions, device, files, personal data, UI control
/// and code execution.
enum MacSystem {}
