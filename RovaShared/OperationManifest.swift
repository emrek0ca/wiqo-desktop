import Foundation

/// The platform names used by DeviceInfo and the native companion adapters. This is deliberately
/// separate from the wire version: adding a platform does not change CommandRequest/CommandResult.
public enum RovaPlatform: String, Codable, CaseIterable, Sendable {
    case macOS
    case windows
}

public enum RovaOperationTimeoutClass: String, Codable, CaseIterable, Sendable {
    case short
    case medium
    case long
}

/// The single native-operation catalogue shared by the Mac and Windows implementations.
/// Payload validation and authority remain payload-aware in RovaValidation/RovaCommandAuthority;
/// this catalogue describes the common boundary and keeps platform advertising deterministic.
public struct RovaOperationManifestEntry: Codable, Equatable, Sendable, Identifiable {
    public let operation: CommandType
    public let payloadKind: String
    public let capability: String
    public let authority: String
    public let isDestructive: Bool
    public let requiresUserPresence: Bool
    public let timeoutClass: RovaOperationTimeoutClass
    public let verificationRule: String
    public let supportedPlatforms: [RovaPlatform]

    public var id: String { operation.rawValue }

    public init(
        operation: CommandType,
        payloadKind: String,
        capability: String,
        authority: String,
        isDestructive: Bool,
        requiresUserPresence: Bool,
        timeoutClass: RovaOperationTimeoutClass,
        verificationRule: String,
        supportedPlatforms: [RovaPlatform]
    ) {
        self.operation = operation
        self.payloadKind = payloadKind
        self.capability = capability
        self.authority = authority
        self.isDestructive = isDestructive
        self.requiresUserPresence = requiresUserPresence
        self.timeoutClass = timeoutClass
        self.verificationRule = verificationRule
        self.supportedPlatforms = supportedPlatforms
    }
}

public enum RovaOperationManifest {
    public static let version = 3

    /// CommandType.allCases is declaration-ordered and therefore stable across every client.
    public static let entries: [RovaOperationManifestEntry] = CommandType.allCases.map(makeEntry)

    public static func entry(for operation: CommandType) -> RovaOperationManifestEntry {
        // The array is generated from allCases, so this lookup cannot fail. Keeping the fallback
        // here makes the method total if a future enum case is added before its metadata switch.
        entries.first(where: { $0.operation == operation }) ?? makeEntry(operation)
    }

    public static func supports(_ operation: CommandType, on platform: RovaPlatform) -> Bool {
        entry(for: operation).supportedPlatforms.contains(platform)
    }

    /// Capabilities are emitted in sorted order and de-duplicated so changing a Set elsewhere
    /// cannot silently destroy relay prompt-cache/tool-selection determinism.
    public static func advertisedCapabilities(for platform: RovaPlatform) -> [String] {
        Array(Set(entries.filter { $0.supportedPlatforms.contains(platform) }.map(\.capability))).sorted()
    }

    public static func encodedManifest() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ManifestDocument(version: version, operations: entries))
    }

    private static func makeEntry(_ operation: CommandType) -> RovaOperationManifestEntry {
        let capability = capability(for: operation)
        let platform: [RovaPlatform] = macOnly(operation)
            ? [.macOS]
            : windowsSupported(operation)
              ? [.macOS, .windows]
              : [.macOS]
        return RovaOperationManifestEntry(
            operation: operation,
            payloadKind: payloadKind(for: operation),
            capability: capability,
            authority: capability,
            isDestructive: destructive(for: operation),
            requiresUserPresence: presence(for: operation),
            timeoutClass: timeoutClass(for: operation),
            verificationRule: verificationRule(for: operation),
            supportedPlatforms: platform
        )
    }

    private static func capability(for operation: CommandType) -> String {
        switch operation {
        case .getSystemStatus, .ping: return "runtime.status"
        case .openApplication: return "device.app.open"
        case .openApplicationByName: return "device.app.open_by_name"
        case .controlApplication: return "device.app.control"
        case .quitApplication: return "device.app.quit"
        case .openURL: return "device.url.open"
        case .setVolume, .toggleMute: return "device.audio"
        case .setBrightness: return "device.display"
        case .mediaControl: return "device.media"
        case .setClipboardText, .getClipboardText, .getClipboardHistory: return "device.clipboard"
        case .lockMac, .sleepMac, .displaySleep: return "device.system.power"
        case .sendMessage: return "device.messaging.send"
        case .listCalendarEvents: return "calendar.read"
        case .createCalendarEvent: return "calendar.write"
        case .listReminders: return "reminders.read"
        case .createReminder, .completeReminder: return "reminders.write"
        case .createNote: return "notes.write"
        case .sendEmail: return "mail.send"
        case .listDesktopFiles, .listFiles, .searchFiles: return "device.files.list"
        case .readDesktopFile, .readFile, .sendFileToPhone: return "device.files.read"
        case .saveTextFile, .writeFile: return "device.files.write"
        case .moveDesktopFile, .renameDesktopFile, .moveFile: return "device.files.move"
        case .copyFile, .convertFile: return "device.files.copy"
        case .runFilePlan, .grantAgentAccess: return "device.files.list"
        case .deleteFile: return "device.files.delete"
        case .saveArtifact: return "artifact.save"
        case .readDocument: return "document.read"
        case .editDocument: return "document.edit"
        case .executeCode: return "device.code.execute"
        case .captureScreen: return "device.screen.capture"
        case .runShortcut: return "device.shortcut.run"
        case .controlUIElement: return "device.ui.control"
        case .clickScreen: return "device.screen.click"
        case .computerDesktop: return "device.desktop.control"
        case .listRunningApplications: return "device.app.list"
        case .computerBrowser, .endBrowserTask: return "device.browser.control"
        case .localAnalyze: return "local.analysis"
        case .fileUtility: return "device.files.utility"
        case .systemUtility: return "device.system.utility"
        }
    }

    private static func payloadKind(for operation: CommandType) -> String {
        switch operation {
        case .getSystemStatus, .lockMac, .sleepMac, .displaySleep, .toggleMute, .ping,
             .listCalendarEvents, .listReminders, .getClipboardText, .getClipboardHistory,
             .listRunningApplications:
            return "none"
        case .openApplication, .quitApplication: return "application"
        case .openApplicationByName: return "applicationQuery"
        case .controlApplication: return "applicationControl"
        case .openURL: return "url"
        case .setVolume: return "volume"
        case .setBrightness: return "brightness"
        case .mediaControl: return "media"
        case .setClipboardText: return "clipboardText"
        case .saveTextFile: return "textFile"
        case .sendMessage: return "message"
        case .createCalendarEvent: return "calendarEvent"
        case .createNote: return "note"
        case .sendEmail: return "email"
        case .createReminder: return "reminder"
        case .completeReminder: return "completeReminder"
        case .readDesktopFile, .readDocument: return "fileName"
        case .moveDesktopFile, .renameDesktopFile: return "fileMove"
        case .saveArtifact: return "artifactFile"
        case .listDesktopFiles: return "none"
        case .listFiles, .readFile, .sendFileToPhone, .writeFile, .moveFile, .copyFile, .convertFile, .deleteFile: return "fileOperation"
        case .runFilePlan: return "filePlan"
        case .grantAgentAccess: return "agentGrant"
        case .searchFiles: return "fileSearch"
        case .editDocument: return "document"
        case .executeCode: return "codeExecution"
        case .captureScreen: return "screenCapture"
        case .runShortcut: return "shortcut"
        case .controlUIElement: return "uiElement"
        case .clickScreen: return "screenClick"
        case .computerDesktop: return "computerDesktop"
        case .computerBrowser: return "computerBrowser"
        case .endBrowserTask: return "browserTask"
        case .localAnalyze: return "localAnalysis"
        case .fileUtility: return "fileUtility"
        case .systemUtility: return "systemUtility"
        }
    }

    private static func destructive(for operation: CommandType) -> Bool {
        switch operation {
        case .lockMac, .sleepMac, .displaySleep, .sendMessage, .sendEmail, .createNote,
             .createCalendarEvent, .createReminder, .completeReminder, .moveDesktopFile,
             .renameDesktopFile, .saveArtifact, .editDocument, .writeFile, .moveFile,
             .copyFile, .convertFile, .runFilePlan, .grantAgentAccess, .deleteFile, .executeCode, .clickScreen, .runShortcut:
            return true
        default:
            return false
        }
    }

    private static func presence(for operation: CommandType) -> Bool {
        destructive(for: operation) || [
            CommandType.saveTextFile, .readDocument, .listFiles, .searchFiles, .readFile, .sendFileToPhone, .writeFile,
            .moveFile, .copyFile, .convertFile, .deleteFile, .executeCode, .captureScreen,
            .controlUIElement, .clickScreen, .controlApplication, .getClipboardText,
            .getClipboardHistory, .computerDesktop, .computerBrowser, .localAnalyze, .fileUtility
        ].contains(operation)
    }

    private static func timeoutClass(for operation: CommandType) -> RovaOperationTimeoutClass {
        switch operation {
        case .readDocument, .editDocument, .saveArtifact, .executeCode, .runShortcut, .searchFiles, .sendFileToPhone, .convertFile, .runFilePlan, .computerDesktop, .computerBrowser, .localAnalyze, .fileUtility, .systemUtility:
            return .long
        case .listCalendarEvents, .createCalendarEvent, .listReminders, .createReminder,
             .completeReminder, .listDesktopFiles, .readDesktopFile, .listFiles, .readFile,
             .writeFile, .moveFile, .copyFile, .deleteFile, .saveTextFile, .endBrowserTask:
            return .medium
        default:
            return .short
        }
    }

    private static func verificationRule(for operation: CommandType) -> String {
        switch operation {
        case .getSystemStatus, .ping: return "system_status"
        case .openApplication, .openApplicationByName, .controlApplication, .quitApplication, .listRunningApplications: return "application_state"
        case .setVolume, .toggleMute, .setBrightness, .mediaControl: return "system_state"
        case .setClipboardText: return "clipboard_readback"
        case .getClipboardText, .getClipboardHistory: return "clipboard_snapshot"
        case .saveTextFile, .writeFile, .moveFile, .copyFile, .convertFile, .deleteFile, .saveArtifact, .runFilePlan: return "filesystem_state"
        case .grantAgentAccess: return "agent_grant"
        case .readDesktopFile, .readDocument, .listDesktopFiles, .listFiles, .searchFiles, .readFile: return "filesystem_snapshot"
        case .sendFileToPhone: return "artifact_delivery"
        case .editDocument: return "document_content"
        case .executeCode: return "process_exit"
        case .captureScreen: return "screen_capture"
        case .controlUIElement, .clickScreen, .computerDesktop: return "ui_observation"
        case .computerBrowser, .endBrowserTask: return "browser_state"
        case .localAnalyze: return "structured_local_result"
        case .fileUtility: return "filesystem_state"
        case .systemUtility: return "system_state"
        default: return "provider_acknowledgement"
        }
    }

    private static func macOnly(_ operation: CommandType) -> Bool {
        switch operation {
        case .sendMessage, .listCalendarEvents,
             .createCalendarEvent, .listReminders, .createReminder, .completeReminder,
             .createNote, .sendEmail, .runShortcut, .fileUtility, .systemUtility:
            return true
        default:
            return false
        }
    }

    /// Windows currently ships a deliberately small, verified adapter. Keeping this list
    /// beside the shared manifest prevents the capability catalogue from promising operations
    /// that the Windows companion cannot execute yet.
    private static func windowsSupported(_ operation: CommandType) -> Bool {
        switch operation {
        // No isolated code sandbox on Windows: code runs only through the signed terminal session.
        // Must match RovaWindows/WindowsCapabilityManifest.cs (checked by contracts/companion/check.sh).
        case .ping, .getSystemStatus, .openURL, .listRunningApplications,
             .openApplication, .openApplicationByName, .controlApplication, .quitApplication,
             .lockMac, .sleepMac, .displaySleep, .setVolume, .toggleMute, .mediaControl,
             .setClipboardText, .getClipboardText,
             .saveTextFile, .listDesktopFiles, .readDesktopFile, .moveDesktopFile, .renameDesktopFile,
             .listFiles, .searchFiles, .readFile, .sendFileToPhone, .writeFile, .moveFile, .copyFile, .deleteFile,
             .saveArtifact, .captureScreen, .computerDesktop, .computerBrowser, .endBrowserTask, .localAnalyze:
            return true
        default:
            return false
        }
    }
}

private struct ManifestDocument: Codable {
    let version: Int
    let operations: [RovaOperationManifestEntry]
}
