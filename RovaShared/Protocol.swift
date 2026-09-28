import Foundation

public enum CommandStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case completed
    case failed
    case denied
    case unknown
}

public enum CommandType: String, Codable, CaseIterable, Sendable {
    case getSystemStatus
    case openApplication
    case openApplicationByName
    case controlApplication
    case openURL
    case lockMac
    case sleepMac
    case displaySleep
    case setBrightness
    case setVolume
    case toggleMute
    case mediaControl
    case setClipboardText
    case quitApplication
    case saveTextFile
    case ping
    case sendMessage
    case listCalendarEvents
    case createCalendarEvent
    case listReminders
    case createReminder
    case completeReminder
    case getClipboardText
    case getClipboardHistory
    case createNote
    case sendEmail
    case listDesktopFiles
    case readDesktopFile
    case moveDesktopFile
    case renameDesktopFile
    case saveArtifact
    case readDocument
    case editDocument
    case listFiles
    case searchFiles
    case readFile
    case sendFileToPhone
    case writeFile
    case moveFile
    case copyFile
    case deleteFile
    case executeCode
    case captureScreen
    case runShortcut
    case controlUIElement
    case clickScreen
    case listRunningApplications
    case computerBrowser
    case endBrowserTask
}

public enum MediaAction: String, Codable, CaseIterable, Sendable {
    case playPause
    case nextTrack
    case previousTrack
}

/// Shortcuts that Wiqo is allowed to invoke. The raw values are the exact names used by the
/// macOS Shortcuts app; keeping this as an enum prevents a model response from becoming an
/// arbitrary `shortcuts run <name>` command.
public enum WiqoShortcut: String, Codable, CaseIterable, Sendable {
    case focusDoNotDisturbOn = "Wiqo Focus - Rahatsız Etme Aç"
    case focusDoNotDisturbOff = "Wiqo Focus - Rahatsız Etme Kapat"
    case focusPersonalOn = "Wiqo Focus - Kişisel Aç"
    case focusPersonalOff = "Wiqo Focus - Kişisel Kapat"
    case focusWorkOn = "Wiqo Focus - İş Aç"
    case focusWorkOff = "Wiqo Focus - İş Kapat"
    case wifiOn = "Wiqo Wi-Fi Aç"
    case wifiOff = "Wiqo Wi-Fi Kapat"
    case bluetoothOn = "Wiqo Bluetooth Aç"
    case bluetoothOff = "Wiqo Bluetooth Kapat"

    public var expectedState: String {
        switch self {
        case .focusDoNotDisturbOn, .focusPersonalOn, .focusWorkOn, .wifiOn, .bluetoothOn:
            return "on"
        case .focusDoNotDisturbOff, .focusPersonalOff, .focusWorkOff, .wifiOff, .bluetoothOff:
            return "off"
        }
    }

    public var displayName: String { rawValue }

    public var resourceName: String {
        switch self {
        case .focusDoNotDisturbOn: return "WiqoFocusDoNotDisturbOn"
        case .focusDoNotDisturbOff: return "WiqoFocusDoNotDisturbOff"
        case .focusPersonalOn: return "WiqoFocusPersonalOn"
        case .focusPersonalOff: return "WiqoFocusPersonalOff"
        case .focusWorkOn: return "WiqoFocusWorkOn"
        case .focusWorkOff: return "WiqoFocusWorkOff"
        case .wifiOn: return "WiqoWiFiOn"
        case .wifiOff: return "WiqoWiFiOff"
        case .bluetoothOn: return "WiqoBluetoothOn"
        case .bluetoothOff: return "WiqoBluetoothOff"
        }
    }
}

public struct ShortcutPayload: Codable, Equatable, Sendable {
    public let shortcut: WiqoShortcut
    public let timeoutSeconds: Int

    public init(shortcut: WiqoShortcut, timeoutSeconds: Int = 15) {
        self.shortcut = shortcut
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum UIElementAction: String, Codable, CaseIterable, Sendable {
    case press
    case setValue
}

/// A bounded Accessibility request. The Mac only searches a running application and never
/// launches an arbitrary target as a side effect of this command.
public struct UIElementPayload: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let windowTitle: String?
    public let label: String
    public let role: String?
    public let action: UIElementAction
    public let value: String?
    public let expectedValue: String?

    public init(
        bundleIdentifier: String,
        windowTitle: String? = nil,
        label: String,
        role: String? = nil,
        action: UIElementAction,
        value: String? = nil,
        expectedValue: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.label = label
        self.role = role
        self.action = action
        self.value = value
        self.expectedValue = expectedValue
    }
}

/// Coordinates are normalized against the exact screenshot dimensions the model observed. This
/// prevents a stale pixel coordinate from silently targeting a different display layout.
public struct ScreenClickPayload: Codable, Equatable, Sendable {
    public let displayID: UInt32?
    public let normalizedX: Double
    public let normalizedY: Double
    public let screenshotWidth: Int
    public let screenshotHeight: Int
    public let expectedTarget: String?

    public init(
        displayID: UInt32? = nil,
        normalizedX: Double,
        normalizedY: Double,
        screenshotWidth: Int,
        screenshotHeight: Int,
        expectedTarget: String? = nil
    ) {
        self.displayID = displayID
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.screenshotWidth = screenshotWidth
        self.screenshotHeight = screenshotHeight
        self.expectedTarget = expectedTarget
    }
}

public struct ComputerBrowserPayload: Codable, Equatable, Sendable {
    public let taskId: String
    public let action: String
    public let url: String?
    public let targetRef: String?
    public let targetBy: String?
    public let target: String?
    public let role: String?
    public let value: String?
    public let direction: String?
    public let scrollAmount: Int?
    /// Set by the backend only after an approved observe result from this ephemeral task.
    public let contentAccessGranted: Bool?
    /// Set by the backend only after this task's one-time browser access approval was verified.
    public let interactionAccessGranted: Bool?
    /// fill: press Enter afterwards (GET/search forms only; the worker enforces it).
    public let submit: Bool?
    /// press: one of Enter, Escape, Tab, ArrowDown, ArrowUp.
    public let key: String?
    /// read: character offset of the next content chunk.
    public let offset: Int?

    public init(taskId: String, action: String, url: String? = nil, targetRef: String? = nil, targetBy: String? = nil, target: String? = nil, role: String? = nil, value: String? = nil, direction: String? = nil, scrollAmount: Int? = nil, contentAccessGranted: Bool? = nil, interactionAccessGranted: Bool? = nil, submit: Bool? = nil, key: String? = nil, offset: Int? = nil) {
        self.taskId = taskId
        self.action = action
        self.url = url
        self.targetRef = targetRef
        self.targetBy = targetBy
        self.target = target
        self.role = role
        self.value = value
        self.direction = direction
        self.scrollAmount = scrollAmount
        self.contentAccessGranted = contentAccessGranted
        self.interactionAccessGranted = interactionAccessGranted
        self.submit = submit
        self.key = key
        self.offset = offset
    }
}

public struct BrowserTaskPayload: Codable, Equatable, Sendable {
    public let taskId: String
    public init(taskId: String) { self.taskId = taskId }
}

public struct MessagePayload: Codable, Equatable, Sendable {
    public let recipient: String
    public let body: String

    public init(recipient: String, body: String) {
        self.recipient = recipient
        self.body = body
    }
}

public struct NotePayload: Codable, Equatable, Sendable {
    public let title: String
    public let body: String
    public let folderName: String?

    public init(title: String, body: String, folderName: String? = nil) {
        self.title = title
        self.body = body
        self.folderName = folderName
    }
}

public struct EmailPayload: Codable, Equatable, Sendable {
    public let to: String
    public let subject: String
    public let body: String

    public init(to: String, subject: String, body: String) {
        self.to = to
        self.subject = subject
        self.body = body
    }
}

public struct CalendarEventPayload: Codable, Equatable, Sendable {
    public let title: String
    public let startAt: Date
    public let endAt: Date
    public let calendarName: String?
    public let notes: String?
    public let location: String?

    public init(title: String, startAt: Date, endAt: Date, calendarName: String? = nil, notes: String? = nil, location: String? = nil) {
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.calendarName = calendarName
        self.notes = notes
        self.location = location
    }
}

public struct DesktopFileMovePayload: Codable, Equatable, Sendable {
    public let source: String
    public let destination: String

    public init(source: String, destination: String) {
        self.source = source
        self.destination = destination
    }
}

public enum ApplicationID: String, Codable, CaseIterable, Sendable {
    case safari
    case xcode
    case terminal
    case finder
    case visualStudioCode
    case mail
    case music
    case messages
    case notes
    case systemSettings

    public var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .xcode: return "Xcode"
        case .terminal: return "Terminal"
        case .finder: return "Finder"
        case .visualStudioCode: return "Visual Studio Code"
        case .mail: return "Mail"
        case .music: return "Music"
        case .messages: return "Messages"
        case .notes: return "Notes"
        case .systemSettings: return "System Settings"
        }
    }
}

/// Semantic application lifecycle operations. Unlike `ApplicationID`, the target is not a
/// compile-time list: the companion resolves a human name or bundle identifier against the
/// applications that are actually installed/running on that Mac.
public enum ApplicationControlAction: String, Codable, CaseIterable, Sendable {
    case open
    case activate
    case quit
}

public struct ApplicationControlPayload: Codable, Equatable, Sendable {
    public let action: ApplicationControlAction
    public let target: String
    public let bundleIdentifier: String?
    /// A graceful quit is always attempted first. Force termination is only allowed when the
    /// user explicitly requested it and the interactive presence gate has approved the step.
    public let force: Bool

    public init(action: ApplicationControlAction, target: String, bundleIdentifier: String? = nil, force: Bool = false) {
        self.action = action
        self.target = target
        self.bundleIdentifier = bundleIdentifier
        self.force = force
    }
}

public struct DeviceApplicationTarget: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let bundleIdentifier: String?
    public let isRunning: Bool
    public let supportedActions: [ApplicationControlAction]

    public var id: String { bundleIdentifier ?? name }

    public init(name: String, bundleIdentifier: String?, isRunning: Bool, supportedActions: [ApplicationControlAction]) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.isRunning = isRunning
        self.supportedActions = supportedActions
    }
}

public enum CapabilityAuthorityAccess: String, Codable, CaseIterable, Sendable {
    /// The authenticated paired-device request may run without another confirmation.
    case automatic
    /// The iPhone must perform the explicit local-presence/biometric approval step.
    case confirmation
    /// The user disabled this scope in Wiqo/macOS.
    case denied
    /// A required macOS TCC permission or dependency is not currently available.
    case unavailable
}

public struct DeviceCapabilityAuthority: Codable, Equatable, Sendable, Identifiable {
    public let capability: String
    public let displayName: String
    public let access: CapabilityAuthorityAccess
    public let requiredPermissions: [String]
    public let message: String?

    public var id: String { capability }

    public init(
        capability: String,
        displayName: String,
        access: CapabilityAuthorityAccess,
        requiredPermissions: [String] = [],
        message: String? = nil
    ) {
        self.capability = capability
        self.displayName = displayName
        self.access = access
        self.requiredPermissions = requiredPermissions
        self.message = message
    }
}

public struct TextFilePayload: Codable, Equatable, Sendable {
    public let filename: String
    public let content: String

    public init(filename: String, content: String) {
        self.filename = filename
        self.content = content
    }
}

public enum DocumentFormat: String, Codable, CaseIterable, Sendable {
    case doc
    case docx
    case xlsx
    case pdf
    case md
    case txt
    case csv
    case html
}

public struct DocumentPayload: Codable, Equatable, Sendable {
    public let filename: String
    public let format: DocumentFormat
    public let content: String
    public let overwrite: Bool

    public init(filename: String, format: DocumentFormat, content: String, overwrite: Bool = false) {
        self.filename = filename
        self.format = format
        self.content = content
        self.overwrite = overwrite
    }
}

public struct ArtifactFilePayload: Codable, Equatable, Sendable {
    public let artifactID: String
    public let filename: String
    public let mimeType: String
    public let downloadURL: String
    public let overwrite: Bool
    public let byteCount: Int64?
    public let sha256: String?

    public init(artifactID: String, filename: String, mimeType: String, downloadURL: String, overwrite: Bool = false, byteCount: Int64? = nil, sha256: String? = nil) {
        self.artifactID = artifactID
        self.filename = filename
        self.mimeType = mimeType
        self.downloadURL = downloadURL
        self.overwrite = overwrite
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// A path-based local operation. Paths are deliberately kept as strings on the wire; the Mac
/// validates and resolves them after symlink expansion immediately before touching the file
/// system. `page`/`pageSize` keep directory enumeration bounded.
public struct LocalFileOperationPayload: Codable, Equatable, Sendable {
    public let path: String
    public let destination: String?
    public let content: String?
    public let overwrite: Bool
    public let recursive: Bool
    public let page: Int
    public let pageSize: Int

    public init(
        path: String,
        destination: String? = nil,
        content: String? = nil,
        overwrite: Bool = false,
        recursive: Bool = false,
        page: Int = 0,
        pageSize: Int = 100
    ) {
        self.path = path
        self.destination = destination
        self.content = content
        self.overwrite = overwrite
        self.recursive = recursive
        self.page = page
        self.pageSize = pageSize
    }
}

public struct FileSearchPayload: Codable, Equatable, Sendable {
    public let query: String
    public let cursor: String?

    public init(query: String, cursor: String? = nil) {
        self.query = query
        self.cursor = cursor
    }
}

public struct CodeExecutionPayload: Codable, Equatable, Sendable {
    public let language: String
    public let code: String
    public let arguments: [String]
    public let timeoutSeconds: Int
    public let allowNetwork: Bool
    /// `sandbox` preserves the historical isolated execution path. `computer` is an explicit,
    /// user-approved local terminal command running in the selected working directory.
    public let scope: String
    public let shell: String?
    public let workingDirectory: String?

    private enum CodingKeys: String, CodingKey {
        case language, code, arguments, timeoutSeconds, allowNetwork, scope, shell, workingDirectory
    }

    public init(
        language: String,
        code: String,
        arguments: [String] = [],
        timeoutSeconds: Int = 30,
        allowNetwork: Bool = false,
        scope: String = "sandbox",
        shell: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.language = language
        self.code = code
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
        self.allowNetwork = allowNetwork
        self.scope = scope
        self.shell = shell
        self.workingDirectory = workingDirectory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.language = try container.decode(String.self, forKey: .language)
        self.code = try container.decode(String.self, forKey: .code)
        self.arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 30
        self.allowNetwork = try container.decodeIfPresent(Bool.self, forKey: .allowNetwork) ?? false
        self.scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? "sandbox"
        self.shell = try container.decodeIfPresent(String.self, forKey: .shell)
        self.workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
    }
}

public struct ScreenCapturePayload: Codable, Equatable, Sendable {
    public let displayID: UInt32?
    public let maxWidth: Int

    public init(displayID: UInt32? = nil, maxWidth: Int = 1600) {
        self.displayID = displayID
        self.maxWidth = maxWidth
    }
}

public struct InstalledApplicationInfo: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let bundleIdentifier: String?
    public let path: String

    public var id: String { path }

    public init(name: String, bundleIdentifier: String?, path: String) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
    }
}

public struct FileDataContent: Codable, Equatable, Sendable {
    public let path: String
    public let mimeType: String
    public let text: String?
    public let base64: String?
    public let truncated: Bool

    public init(path: String, mimeType: String, text: String? = nil, base64: String? = nil, truncated: Bool = false) {
        self.path = path
        self.mimeType = mimeType
        self.text = text
        self.base64 = base64
        self.truncated = truncated
    }
}

public struct ProcessOutputContent: Codable, Equatable, Sendable {
    public let language: String
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let truncated: Bool
    public let durationMs: Int

    public init(language: String, exitCode: Int32, stdout: String, stderr: String, truncated: Bool, durationMs: Int) {
        self.language = language
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
        self.durationMs = durationMs
    }
}

/// One command of a terminal plan (terminal-session-v2 run_plan), as the Mac ran it.
public struct TerminalStepResult: Codable, Equatable, Sendable {
    public let command: String
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let durationMs: Int
    public let truncated: Bool
    /// Not run because an earlier step failed (stop-on-failure).
    public let skipped: Bool

    public init(command: String, exitCode: Int32, stdout: String, stderr: String, durationMs: Int, truncated: Bool, skipped: Bool) {
        self.command = command
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.durationMs = durationMs
        self.truncated = truncated
        self.skipped = skipped
    }
}

/// Structured result of a terminal-session-v2 action: a command plan, a file read/write, a
/// search, or a multi-file edit. `workingDirectory` is the session folder after the action.
public struct TerminalResultContent: Codable, Equatable, Sendable {
    public let kind: String
    public let workingDirectory: String?
    public let steps: [TerminalStepResult]?
    public let text: String?
    public let files: [String]?
    public let totalLines: Int?

    public init(kind: String, workingDirectory: String? = nil, steps: [TerminalStepResult]? = nil, text: String? = nil, files: [String]? = nil, totalLines: Int? = nil) {
        self.kind = kind
        self.workingDirectory = workingDirectory
        self.steps = steps
        self.text = text
        self.files = files
        self.totalLines = totalLines
    }
}

/// A bounded status snapshot for a companion-owned background terminal job. Raw output stays in
/// the companion's short-lived in-memory job store and is fetched only when the user asks.
public struct TerminalJobContent: Codable, Equatable, Sendable {
    public let jobId: String
    public let status: String
    public let output: ProcessOutputContent?
    public let diff: String?
    public let applied: Bool?
    public let message: String?
    public let errorCode: String?

    public init(jobId: String, status: String, output: ProcessOutputContent? = nil, diff: String? = nil, applied: Bool? = nil, message: String? = nil, errorCode: String? = nil) {
        self.jobId = jobId
        self.status = status
        self.output = output
        self.diff = diff
        self.applied = applied
        self.message = message
        self.errorCode = errorCode
    }
}

public struct ScreenshotContent: Codable, Equatable, Sendable {
    public let filename: String
    public let mimeType: String
    public let dataBase64: String
    public let width: Int
    public let height: Int

    public init(filename: String, mimeType: String, dataBase64: String, width: Int, height: Int) {
        self.filename = filename
        self.mimeType = mimeType
        self.dataBase64 = dataBase64
        self.width = width
        self.height = height
    }
}

public struct ShortcutExecutionContent: Codable, Equatable, Sendable {
    public let shortcut: WiqoShortcut
    public let output: String
    public let expectedState: String
    public let observedState: String?
    public let verified: Bool

    public init(shortcut: WiqoShortcut, output: String, expectedState: String, observedState: String?, verified: Bool) {
        self.shortcut = shortcut
        self.output = output
        self.expectedState = expectedState
        self.observedState = observedState
        self.verified = verified
    }
}

public struct UIElementContent: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let title: String?
    public let role: String?
    public let value: String?
    public let description: String?
    public let enabled: Bool?
    public let matchedCount: Int
    public let verified: Bool

    public init(bundleIdentifier: String, title: String?, role: String?, value: String?, description: String?, enabled: Bool?, matchedCount: Int, verified: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.role = role
        self.value = value
        self.description = description
        self.enabled = enabled
        self.matchedCount = matchedCount
        self.verified = verified
    }
}

public struct ScreenClickContent: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let x: Double
    public let y: Double
    public let expectedTarget: String?

    public init(displayID: UInt32, x: Double, y: Double, expectedTarget: String?) {
        self.displayID = displayID
        self.x = x
        self.y = y
        self.expectedTarget = expectedTarget
    }
}

public struct BrowserTarget: Codable, Equatable, Sendable {
    public let ref: String
    public let role: String
    public let name: String
    /// Current value of a field or selected option, when there is one.
    public let value: String?
    public let checked: Bool?

    public init(ref: String, role: String, name: String, value: String? = nil, checked: Bool? = nil) {
        self.ref = ref
        self.role = role
        self.name = name
        self.value = value
        self.checked = checked
    }
}

public struct BrowserContent: Codable, Equatable, Sendable {
    public let taskId: String
    public let action: String?
    public let url: String?
    public let title: String?
    public let text: String?
    public let targets: [BrowserTarget]?
    public let pageVersion: Int?
    public let contentShared: Bool?
    public let interactionApproved: Bool?
    public let truncated: Bool?
    public let verified: Bool?
    public let closed: Bool?
    /// read: where the next chunk starts; nil at the end of the content.
    public let nextOffset: Int?

    public init(taskId: String, action: String? = nil, url: String? = nil, title: String? = nil, text: String? = nil, targets: [BrowserTarget]? = nil, pageVersion: Int? = nil, contentShared: Bool? = nil, interactionApproved: Bool? = nil, truncated: Bool? = nil, verified: Bool? = nil, closed: Bool? = nil, nextOffset: Int? = nil) {
        self.taskId = taskId
        self.action = action
        self.url = url
        self.title = title
        self.text = text
        self.targets = targets
        self.pageVersion = pageVersion
        self.contentShared = contentShared
        self.interactionApproved = interactionApproved
        self.truncated = truncated
        self.verified = verified
        self.closed = closed
        self.nextOffset = nextOffset
    }
}

public struct ApplicationControlContent: Codable, Equatable, Sendable {
    public let action: ApplicationControlAction
    public let resolvedName: String
    public let bundleIdentifier: String?
    public let stateBefore: String
    public let stateAfter: String
    public let changed: Bool
    public let verified: Bool
    public let candidates: [String]

    public init(
        action: ApplicationControlAction,
        resolvedName: String,
        bundleIdentifier: String?,
        stateBefore: String,
        stateAfter: String,
        changed: Bool,
        verified: Bool,
        candidates: [String] = []
    ) {
        self.action = action
        self.resolvedName = resolvedName
        self.bundleIdentifier = bundleIdentifier
        self.stateBefore = stateBefore
        self.stateAfter = stateAfter
        self.changed = changed
        self.verified = verified
        self.candidates = candidates
    }
}

public enum CommandPayload: Codable, Equatable, Sendable {
    case none
    case application(ApplicationID)
    case applicationQuery(String)
    case applicationControl(ApplicationControlPayload)
    case url(String)
    case volume(Int)
    case media(MediaAction)
    case brightness(Int)
    case clipboardText(String)
    case textFile(TextFilePayload)
    case message(MessagePayload)
    case calendarEvent(CalendarEventPayload)
    case fileName(String)
    case fileMove(DesktopFileMovePayload)
    case document(DocumentPayload)
    case artifactFile(ArtifactFilePayload)
    case fileOperation(LocalFileOperationPayload)
    case fileSearch(FileSearchPayload)
    case codeExecution(CodeExecutionPayload)
    case screenCapture(ScreenCapturePayload)
    case shortcut(ShortcutPayload)
    case uiElement(UIElementPayload)
    case screenClick(ScreenClickPayload)
    case computerBrowser(ComputerBrowserPayload)
    case browserTask(BrowserTaskPayload)
    case reminder(ReminderPayload)
    case completeReminder(CompleteReminderPayload)
    case note(NotePayload)
    case email(EmailPayload)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case none, application, applicationQuery, applicationControl, url, volume, media, brightness, clipboardText, textFile, message, calendarEvent, fileName, fileMove, document, artifactFile, fileOperation, fileSearch, codeExecution, screenCapture, shortcut, uiElement, screenClick, computerBrowser, browserTask, reminder, completeReminder, note, email }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .none:
            self = .none
        case .application:
            self = .application(try container.decode(ApplicationID.self, forKey: .value))
        case .applicationQuery:
            self = .applicationQuery(try container.decode(String.self, forKey: .value))
        case .applicationControl:
            self = .applicationControl(try container.decode(ApplicationControlPayload.self, forKey: .value))
        case .url:
            self = .url(try container.decode(String.self, forKey: .value))
        case .volume:
            self = .volume(try container.decode(Int.self, forKey: .value))
        case .media:
            self = .media(try container.decode(MediaAction.self, forKey: .value))
        case .brightness:
            self = .brightness(try container.decode(Int.self, forKey: .value))
        case .clipboardText:
            self = .clipboardText(try container.decode(String.self, forKey: .value))
        case .textFile:
            self = .textFile(try container.decode(TextFilePayload.self, forKey: .value))
        case .message:
            self = .message(try container.decode(MessagePayload.self, forKey: .value))
        case .calendarEvent:
            self = .calendarEvent(try container.decode(CalendarEventPayload.self, forKey: .value))
        case .fileName:
            self = .fileName(try container.decode(String.self, forKey: .value))
        case .fileMove:
            self = .fileMove(try container.decode(DesktopFileMovePayload.self, forKey: .value))
        case .document:
            self = .document(try container.decode(DocumentPayload.self, forKey: .value))
        case .artifactFile:
            self = .artifactFile(try container.decode(ArtifactFilePayload.self, forKey: .value))
        case .fileOperation:
            self = .fileOperation(try container.decode(LocalFileOperationPayload.self, forKey: .value))
        case .fileSearch:
            self = .fileSearch(try container.decode(FileSearchPayload.self, forKey: .value))
        case .codeExecution:
            self = .codeExecution(try container.decode(CodeExecutionPayload.self, forKey: .value))
        case .screenCapture:
            self = .screenCapture(try container.decode(ScreenCapturePayload.self, forKey: .value))
        case .shortcut:
            self = .shortcut(try container.decode(ShortcutPayload.self, forKey: .value))
        case .uiElement:
            self = .uiElement(try container.decode(UIElementPayload.self, forKey: .value))
        case .screenClick:
            self = .screenClick(try container.decode(ScreenClickPayload.self, forKey: .value))
        case .computerBrowser:
            self = .computerBrowser(try container.decode(ComputerBrowserPayload.self, forKey: .value))
        case .browserTask:
            self = .browserTask(try container.decode(BrowserTaskPayload.self, forKey: .value))
        case .reminder:
            self = .reminder(try container.decode(ReminderPayload.self, forKey: .value))
        case .completeReminder:
            self = .completeReminder(try container.decode(CompleteReminderPayload.self, forKey: .value))
        case .note:
            self = .note(try container.decode(NotePayload.self, forKey: .value))
        case .email:
            self = .email(try container.decode(EmailPayload.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .application(let id):
            try container.encode(Kind.application, forKey: .kind)
            try container.encode(id, forKey: .value)
        case .applicationQuery(let query):
            try container.encode(Kind.applicationQuery, forKey: .kind)
            try container.encode(query, forKey: .value)
        case .applicationControl(let payload):
            try container.encode(Kind.applicationControl, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .url(let value):
            try container.encode(Kind.url, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .volume(let level):
            try container.encode(Kind.volume, forKey: .kind)
            try container.encode(level, forKey: .value)
        case .media(let action):
            try container.encode(Kind.media, forKey: .kind)
            try container.encode(action, forKey: .value)
        case .brightness(let level):
            try container.encode(Kind.brightness, forKey: .kind)
            try container.encode(level, forKey: .value)
        case .clipboardText(let text):
            try container.encode(Kind.clipboardText, forKey: .kind)
            try container.encode(text, forKey: .value)
        case .textFile(let payload):
            try container.encode(Kind.textFile, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .message(let payload):
            try container.encode(Kind.message, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .calendarEvent(let payload):
            try container.encode(Kind.calendarEvent, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .fileName(let filename):
            try container.encode(Kind.fileName, forKey: .kind)
            try container.encode(filename, forKey: .value)
        case .fileMove(let payload):
            try container.encode(Kind.fileMove, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .document(let payload):
            try container.encode(Kind.document, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .artifactFile(let payload):
            try container.encode(Kind.artifactFile, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .fileOperation(let payload):
            try container.encode(Kind.fileOperation, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .fileSearch(let payload):
            try container.encode(Kind.fileSearch, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .codeExecution(let payload):
            try container.encode(Kind.codeExecution, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .screenCapture(let payload):
            try container.encode(Kind.screenCapture, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .shortcut(let payload):
            try container.encode(Kind.shortcut, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .uiElement(let payload):
            try container.encode(Kind.uiElement, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .screenClick(let payload):
            try container.encode(Kind.screenClick, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .computerBrowser(let payload):
            try container.encode(Kind.computerBrowser, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .browserTask(let payload):
            try container.encode(Kind.browserTask, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .reminder(let payload):
            try container.encode(Kind.reminder, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .completeReminder(let payload):
            try container.encode(Kind.completeReminder, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .note(let payload):
            try container.encode(Kind.note, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .email(let payload):
            try container.encode(Kind.email, forKey: .kind)
            try container.encode(payload, forKey: .value)
        }
    }
}

public struct ApplicationInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: ApplicationID
    public let name: String

    public init(id: ApplicationID, name: String = "") {
        self.id = id
        self.name = name.isEmpty ? id.displayName : name
    }
}

public struct SystemStatus: Codable, Equatable, Sendable {
    public let hostname: String
    public let macOSVersion: String
    public let batteryPercentage: Int?
    public let isCharging: Bool?
    public let uptimeSeconds: Double
    public let runtimeStatus: String
    public let volumePercentage: Int?
    public let brightnessPercentage: Int?

    public init(
        hostname: String,
        macOSVersion: String,
        batteryPercentage: Int?,
        isCharging: Bool?,
        uptimeSeconds: Double,
        runtimeStatus: String,
        volumePercentage: Int? = nil,
        brightnessPercentage: Int? = nil
    ) {
        self.hostname = hostname
        self.macOSVersion = macOSVersion
        self.batteryPercentage = batteryPercentage
        self.isCharging = isCharging
        self.uptimeSeconds = uptimeSeconds
        self.runtimeStatus = runtimeStatus
        self.volumePercentage = volumePercentage
        self.brightnessPercentage = brightnessPercentage
    }
}

public struct PingData: Codable, Equatable, Sendable {
    public let serverTime: Date

    public init(serverTime: Date = Date()) {
        self.serverTime = serverTime
    }
}

public struct DesktopFileInfo: Codable, Equatable, Sendable, Identifiable {
    public let filename: String
    public let byteCount: Int64
    public let modifiedAt: Date?
    public let isDirectory: Bool

    public var id: String { filename }

    public init(filename: String, byteCount: Int64, modifiedAt: Date?, isDirectory: Bool) {
        self.filename = filename
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
    }
}

public struct FileSystemEntry: Codable, Equatable, Sendable, Identifiable {
    public let path: String
    public let name: String
    public let fileType: String?
    public let byteCount: Int64
    public let modifiedAt: Date?
    public let isDirectory: Bool

    public var id: String { path }

    public init(path: String, name: String, byteCount: Int64, modifiedAt: Date?, isDirectory: Bool, fileType: String? = nil) {
        self.path = path
        self.name = name
        self.fileType = fileType
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
    }
}

public struct DesktopFileContent: Codable, Equatable, Sendable {
    public let filename: String
    public let content: String

    public init(filename: String, content: String) {
        self.filename = filename
        self.content = content
    }
}

public struct DocumentContent: Codable, Equatable, Sendable {
    public let filename: String
    public let format: DocumentFormat
    public let text: String

    public init(filename: String, format: DocumentFormat, text: String) {
        self.filename = filename
        self.format = format
        self.text = text
    }
}

public struct ClipboardHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public let text: String
    public let copiedAt: Date

    public var id: Date { copiedAt }

    public init(text: String, copiedAt: Date) {
        self.text = text
        self.copiedAt = copiedAt
    }
}

public struct ReminderPayload: Codable, Equatable, Sendable {
    public let title: String
    public let dueAt: Date?
    public let notes: String?
    public let listName: String?

    public init(title: String, dueAt: Date? = nil, notes: String? = nil, listName: String? = nil) {
        self.title = title
        self.dueAt = dueAt
        self.notes = notes
        self.listName = listName
    }
}

public struct CompleteReminderPayload: Codable, Equatable, Sendable {
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}

public struct ReminderInfo: Codable, Equatable, Sendable, Identifiable {
    public let identifier: String
    public let title: String
    public let dueAt: Date?
    public let notes: String?
    public let listName: String
    public let isCompleted: Bool

    public var id: String { identifier }

    public init(identifier: String, title: String, dueAt: Date?, notes: String?, listName: String, isCompleted: Bool) {
        self.identifier = identifier
        self.title = title
        self.dueAt = dueAt
        self.notes = notes
        self.listName = listName
        self.isCompleted = isCompleted
    }
}

public struct CalendarEventInfo: Codable, Equatable, Sendable, Identifiable {
    public let identifier: String
    public let title: String
    public let startAt: Date
    public let endAt: Date
    public let calendarName: String
    public let location: String?

    public var id: String { identifier }

    public init(identifier: String, title: String, startAt: Date, endAt: Date, calendarName: String, location: String?) {
        self.identifier = identifier
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.calendarName = calendarName
        self.location = location
    }
}

public struct RovaError: Codable, Equatable, Sendable, Error {
    public let code: String
    public let message: String
    public let category: String?

    public init(code: String, message: String, category: String? = nil) {
        self.code = code
        self.message = message
        self.category = category
    }
}

public struct CommandResult: Codable, Equatable, Sendable {
    public let commandID: UUID
    public let status: CommandStatus
    public let message: String
    public let startedAt: Date
    public let finishedAt: Date
    public let data: CommandData?
    public let error: RovaError?

    public init(
        commandID: UUID,
        status: CommandStatus,
        message: String,
        startedAt: Date,
        finishedAt: Date,
        data: CommandData? = nil,
        error: RovaError? = nil
    ) {
        self.commandID = commandID
        self.status = status
        self.message = message
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.data = data
        self.error = error
    }
}

public enum CommandData: Codable, Equatable, Sendable {
    case systemStatus(SystemStatus)
    case applications([ApplicationInfo])
    case ping(PingData)
    case fileContent(DesktopFileContent)
    case desktopFiles([DesktopFileInfo])
    case calendarEvents([CalendarEventInfo])
    case reminders([ReminderInfo])
    case clipboardText(String)
    case clipboardHistory([ClipboardHistoryEntry])
    case documentContent(DocumentContent)
    case installedApplications([InstalledApplicationInfo])
    case files([FileSystemEntry])
    case fileTransfer(String)
    case fileData(FileDataContent)
    case processOutput(ProcessOutputContent)
    case terminalJob(TerminalJobContent)
    case terminalResult(TerminalResultContent)
    case screenshot(ScreenshotContent)
    case shortcutResult(ShortcutExecutionContent)
    case uiElement(UIElementContent)
    case screenClick(ScreenClickContent)
    case computerBrowser(BrowserContent)
    case browserTask(BrowserContent)
    case applicationControl(ApplicationControlContent)
    case runningApplications([RunningApplicationInfo])

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case systemStatus, applications, ping, fileContent, desktopFiles, calendarEvents, reminders, clipboardText, clipboardHistory, documentContent, installedApplications, files, fileTransfer, fileData, processOutput, terminalJob, terminalResult, screenshot, shortcutResult, uiElement, screenClick, computerBrowser, browserTask, applicationControl, runningApplications }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .systemStatus:
            self = .systemStatus(try container.decode(SystemStatus.self, forKey: .value))
        case .applications:
            self = .applications(try container.decode([ApplicationInfo].self, forKey: .value))
        case .ping:
            self = .ping(try container.decode(PingData.self, forKey: .value))
        case .fileContent:
            self = .fileContent(try container.decode(DesktopFileContent.self, forKey: .value))
        case .desktopFiles:
            self = .desktopFiles(try container.decode([DesktopFileInfo].self, forKey: .value))
        case .calendarEvents:
            self = .calendarEvents(try container.decode([CalendarEventInfo].self, forKey: .value))
        case .reminders:
            self = .reminders(try container.decode([ReminderInfo].self, forKey: .value))
        case .clipboardText:
            self = .clipboardText(try container.decode(String.self, forKey: .value))
        case .clipboardHistory:
            self = .clipboardHistory(try container.decode([ClipboardHistoryEntry].self, forKey: .value))
        case .documentContent:
            self = .documentContent(try container.decode(DocumentContent.self, forKey: .value))
        case .installedApplications:
            self = .installedApplications(try container.decode([InstalledApplicationInfo].self, forKey: .value))
        case .files:
            self = .files(try container.decode([FileSystemEntry].self, forKey: .value))
        case .fileTransfer:
            self = .fileTransfer(try container.decode(String.self, forKey: .value))
        case .fileData:
            self = .fileData(try container.decode(FileDataContent.self, forKey: .value))
        case .processOutput:
            self = .processOutput(try container.decode(ProcessOutputContent.self, forKey: .value))
        case .terminalJob:
            self = .terminalJob(try container.decode(TerminalJobContent.self, forKey: .value))
        case .terminalResult:
            self = .terminalResult(try container.decode(TerminalResultContent.self, forKey: .value))
        case .screenshot:
            self = .screenshot(try container.decode(ScreenshotContent.self, forKey: .value))
        case .shortcutResult:
            self = .shortcutResult(try container.decode(ShortcutExecutionContent.self, forKey: .value))
        case .uiElement:
            self = .uiElement(try container.decode(UIElementContent.self, forKey: .value))
        case .screenClick:
            self = .screenClick(try container.decode(ScreenClickContent.self, forKey: .value))
        case .computerBrowser:
            self = .computerBrowser(try container.decode(BrowserContent.self, forKey: .value))
        case .browserTask:
            self = .browserTask(try container.decode(BrowserContent.self, forKey: .value))
        case .applicationControl:
            self = .applicationControl(try container.decode(ApplicationControlContent.self, forKey: .value))
        case .runningApplications:
            self = .runningApplications(try container.decode([RunningApplicationInfo].self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .systemStatus(let value):
            try container.encode(Kind.systemStatus, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .applications(let value):
            try container.encode(Kind.applications, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .ping(let value):
            try container.encode(Kind.ping, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .fileContent(let value):
            try container.encode(Kind.fileContent, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .desktopFiles(let value):
            try container.encode(Kind.desktopFiles, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .calendarEvents(let value):
            try container.encode(Kind.calendarEvents, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .reminders(let value):
            try container.encode(Kind.reminders, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .clipboardText(let value):
            try container.encode(Kind.clipboardText, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .clipboardHistory(let value):
            try container.encode(Kind.clipboardHistory, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .documentContent(let value):
            try container.encode(Kind.documentContent, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .installedApplications(let value):
            try container.encode(Kind.installedApplications, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .files(let value):
            try container.encode(Kind.files, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .fileTransfer(let value):
            try container.encode(Kind.fileTransfer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .fileData(let value):
            try container.encode(Kind.fileData, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .processOutput(let value):
            try container.encode(Kind.processOutput, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .terminalJob(let value):
            try container.encode(Kind.terminalJob, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .terminalResult(let value):
            try container.encode(Kind.terminalResult, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .screenshot(let value):
            try container.encode(Kind.screenshot, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .shortcutResult(let value):
            try container.encode(Kind.shortcutResult, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .uiElement(let value):
            try container.encode(Kind.uiElement, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .screenClick(let value):
            try container.encode(Kind.screenClick, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .computerBrowser(let value):
            try container.encode(Kind.computerBrowser, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .browserTask(let value):
            try container.encode(Kind.browserTask, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .applicationControl(let value):
            try container.encode(Kind.applicationControl, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .runningApplications(let value):
            try container.encode(Kind.runningApplications, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

/// What's actually open right now, as opposed to InstalledApplicationInfo (what's on disk,
/// used only for name-resolution candidates) - `isActive` is the one currently in the
/// foreground, since "which one am I looking at" is usually the follow-up question.
public struct RunningApplicationInfo: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let bundleIdentifier: String?
    public let isActive: Bool

    public var id: String { bundleIdentifier ?? name }

    public init(name: String, bundleIdentifier: String?, isActive: Bool) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.isActive = isActive
    }
}

public struct CommandRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let type: CommandType
    public let payload: CommandPayload
    public let createdAt: Date
    /// Version 2 signs the timestamp and canonical payload digest. Optional only so older wire
    /// requests decode far enough to receive an explicit INVALID_SIGNATURE rejection.
    public let signatureVersion: Int?
    public let createdAtEpochMs: Int64?
    public let signature: String?
    public let nonce: String?

    public init(
        id: UUID = UUID(),
        type: CommandType,
        payload: CommandPayload = .none,
        createdAt: Date = Date(),
        signatureVersion: Int? = 2,
        createdAtEpochMs: Int64? = nil,
        signature: String? = nil,
        nonce: String? = nil
    ) {
        self.id = id
        self.type = type
        self.payload = payload
        self.createdAt = createdAt
        self.signatureVersion = signatureVersion
        self.createdAtEpochMs = createdAtEpochMs ?? Int64((createdAt.timeIntervalSince1970 * 1_000).rounded(.down))
        self.signature = signature
        self.nonce = nonce
    }
}

public struct DeviceInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let hostname: String
    public let localIPAddress: String
    public let port: UInt16
    public let serviceStatus: String
    public let availableApplications: [ApplicationInfo]
    /// A privacy-bounded, path-free catalog of real applications on this Mac. It is advisory for
    /// semantic resolution; the Mac re-resolves and validates every target immediately before use.
    public let applicationTargets: [DeviceApplicationTarget]
    public let capabilities: [String]
    public let authorities: [DeviceCapabilityAuthority]
    /// "macOS" today; a future Windows companion reports "windows" here. Nothing in the wire
    /// protocol keys off this yet - it exists so a client can eventually branch on it (icons,
    /// available capabilities) without another protocol change.
    public let platform: String

    private enum CodingKeys: String, CodingKey {
        case id, displayName, hostname, localIPAddress, port, serviceStatus, availableApplications, applicationTargets, capabilities, authorities, platform
    }

    public init(
        id: UUID,
        displayName: String,
        hostname: String,
        localIPAddress: String,
        port: UInt16,
        serviceStatus: String,
        availableApplications: [ApplicationInfo],
        applicationTargets: [DeviceApplicationTarget] = [],
        capabilities: [String] = [],
        authorities: [DeviceCapabilityAuthority] = [],
        platform: String = "macOS"
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.localIPAddress = localIPAddress
        self.port = port
        self.serviceStatus = serviceStatus
        self.availableApplications = availableApplications
        self.applicationTargets = applicationTargets
        self.capabilities = capabilities
        self.authorities = authorities
        self.platform = platform
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        hostname = try container.decode(String.self, forKey: .hostname)
        localIPAddress = try container.decode(String.self, forKey: .localIPAddress)
        port = try container.decode(UInt16.self, forKey: .port)
        serviceStatus = try container.decode(String.self, forKey: .serviceStatus)
        availableApplications = try container.decode([ApplicationInfo].self, forKey: .availableApplications)
        applicationTargets = try container.decodeIfPresent([DeviceApplicationTarget].self, forKey: .applicationTargets) ?? []
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        authorities = try container.decodeIfPresent([DeviceCapabilityAuthority].self, forKey: .authorities) ?? []
        // Older companions did not send platform. macOS remains the safe legacy default.
        platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? "macOS"
    }
}

public struct PairingPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let host: String
    public let port: UInt16
    public let certificateFingerprint: String
    public let pairingCode: String
    public let expiresAt: Date

    public init(version: Int = 1, host: String, port: UInt16, certificateFingerprint: String, pairingCode: String, expiresAt: Date) {
        self.version = version
        self.host = host
        self.port = port
        self.certificateFingerprint = certificateFingerprint
        self.pairingCode = pairingCode
        self.expiresAt = expiresAt
    }
}

/// Bootstrap-only relay pairing data. It is deliberately separate from Protocol v2 command
/// messages: the QR contains a short-lived, one-use session secret, never a JWT or a permanent
/// device credential.
public struct RelayPairingPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let sessionID: String
    public let secret: String
    public let expiresAt: Date

    public init(version: Int = 1, sessionID: String, secret: String, expiresAt: Date) {
        self.version = version
        self.sessionID = sessionID
        self.secret = secret
        self.expiresAt = expiresAt
    }
}

public enum RovaPairingCode: Equatable, Sendable {
    case local(PairingPayload)
    case relay(RelayPairingPayload)
}

public struct PairingRequest: Codable, Equatable, Sendable {
    public let code: String
    public let deviceName: String
    public let deviceID: UUID

    public init(code: String, deviceName: String, deviceID: UUID) {
        self.code = code
        self.deviceName = deviceName
        self.deviceID = deviceID
    }
}

public struct PairingResponse: Codable, Equatable, Sendable {
    public let token: String
    public let deviceID: UUID
    public let certificateFingerprint: String

    public init(token: String, deviceID: UUID, certificateFingerprint: String) {
        self.token = token
        self.deviceID = deviceID
        self.certificateFingerprint = certificateFingerprint
    }
}

public struct AuthenticationRequest: Codable, Equatable, Sendable {
    public let token: String
    public let deviceID: UUID

    public init(token: String, deviceID: UUID) {
        self.token = token
        self.deviceID = deviceID
    }
}

public struct AuthenticationResponse: Codable, Equatable, Sendable {
    public let deviceInfo: DeviceInfo

    public init(deviceInfo: DeviceInfo) {
        self.deviceInfo = deviceInfo
    }
}

public enum WireMessage: Codable, Equatable, Sendable {
    case hello(DeviceInfo)
    case pair(PairingRequest)
    case pairAccepted(PairingResponse)
    case authenticate(AuthenticationRequest)
    case authenticated(AuthenticationResponse)
    case command(CommandRequest)
    case result(CommandResult)
    case failure(RovaError)
    /// The iPhone hands its Rova backend login session to the Mac over this already-authenticated
    /// local connection, once, so the Mac can open its own persistent channel to the backend
    /// (see MacBackendChannel) without needing a separate Mac-side login screen.
    case backendToken(String)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable {
        case hello, pair, pairAccepted, authenticate, authenticated, command, result, failure, backendToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .hello: self = .hello(try container.decode(DeviceInfo.self, forKey: .value))
        case .pair: self = .pair(try container.decode(PairingRequest.self, forKey: .value))
        case .pairAccepted: self = .pairAccepted(try container.decode(PairingResponse.self, forKey: .value))
        case .authenticate: self = .authenticate(try container.decode(AuthenticationRequest.self, forKey: .value))
        case .authenticated: self = .authenticated(try container.decode(AuthenticationResponse.self, forKey: .value))
        case .command: self = .command(try container.decode(CommandRequest.self, forKey: .value))
        case .result: self = .result(try container.decode(CommandResult.self, forKey: .value))
        case .failure: self = .failure(try container.decode(RovaError.self, forKey: .value))
        case .backendToken: self = .backendToken(try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let value): try container.encode(Kind.hello, forKey: .kind); try container.encode(value, forKey: .value)
        case .pair(let value): try container.encode(Kind.pair, forKey: .kind); try container.encode(value, forKey: .value)
        case .pairAccepted(let value): try container.encode(Kind.pairAccepted, forKey: .kind); try container.encode(value, forKey: .value)
        case .authenticate(let value): try container.encode(Kind.authenticate, forKey: .kind); try container.encode(value, forKey: .value)
        case .authenticated(let value): try container.encode(Kind.authenticated, forKey: .kind); try container.encode(value, forKey: .value)
        case .command(let value): try container.encode(Kind.command, forKey: .kind); try container.encode(value, forKey: .value)
        case .result(let value): try container.encode(Kind.result, forKey: .kind); try container.encode(value, forKey: .value)
        case .backendToken(let value): try container.encode(Kind.backendToken, forKey: .kind); try container.encode(value, forKey: .value)
        case .failure(let value): try container.encode(Kind.failure, forKey: .kind); try container.encode(value, forKey: .value)
        }
    }
}

public struct WireEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let message: WireMessage

    public init(version: Int = 1, requestID: UUID = UUID(), message: WireMessage) {
        self.version = version
        self.requestID = requestID
        self.message = message
    }
}
