import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Shortcuts, on-screen controls, clicking and screen capture.
extension MacSystem {
    static func runShortcut(_ payload: ShortcutPayload) -> (data: CommandData?, error: RovaError?) {
        let snapshot = runProcess(
            executable: "/usr/bin/shortcuts",
            arguments: ["run", payload.shortcut.rawValue, "--output-type", "public.plain-text"],
            timeoutSeconds: payload.timeoutSeconds
        )
        let output = String(decoding: snapshot.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(decoding: snapshot.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if snapshot.timedOut {
            return (nil, RovaError(code: "SHORTCUT_TIMEOUT", message: "Shortcut çalıştırma süresi doldu.", category: "timeout"))
        }
        guard snapshot.exitCode == 0 else {
            if stderr.localizedCaseInsensitiveContains("not authorized") || stderr.localizedCaseInsensitiveContains("not permitted") || stderr.localizedCaseInsensitiveContains("permission") || stderr.localizedCaseInsensitiveContains("izin") {
                return (nil, RovaError(code: "SHORTCUT_PERMISSION_REQUIRED", message: "\(payload.shortcut.displayName) için Wiqo'nun Shortcuts/Otomasyon iznini açın. Ayarlar: x-apple.systempreferences:com.apple.preference.security?Privacy_Automation", category: "permission"))
            }
            let code = stderr.localizedCaseInsensitiveContains("not found") || stderr.localizedCaseInsensitiveContains("bulunamadı")
                ? "SHORTCUT_NOT_INSTALLED"
                : "SHORTCUT_FAILED"
            return (nil, RovaError(code: code, message: "\(payload.shortcut.displayName) çalıştırılamadı. Shortcut'ın Wiqo tarafından kurulduğunu kontrol edin.", category: "tool_failure"))
        }

        let observedState = observedShortcutState(payload.shortcut, output: output)
        let verified = observedState == payload.shortcut.expectedState
        let data = CommandData.shortcutResult(ShortcutExecutionContent(
            shortcut: payload.shortcut,
            output: String(output.prefix(4_000)),
            expectedState: payload.shortcut.expectedState,
            observedState: observedState,
            verified: verified
        ))
        guard verified else {
            return (data, RovaError(code: "SHORTCUT_VERIFICATION_FAILED", message: "\(payload.shortcut.displayName) çalıştı ancak istenen durum doğrulanamadı.", category: "tool_failure"))
        }
        return (data, nil)
    }

    private static func observedShortcutState(_ shortcut: WiqoShortcut, output: String) -> String? {
        let normalizedOutput = output.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        switch shortcut {
        case .wifiOn, .wifiOff:
            return currentWiFiState() ?? markerState(in: normalizedOutput)
        case .bluetoothOn, .bluetoothOff:
            return currentBluetoothState() ?? markerState(in: normalizedOutput)
        case .focusDoNotDisturbOn, .focusDoNotDisturbOff,
             .focusPersonalOn, .focusPersonalOff,
             .focusWorkOn, .focusWorkOff:
            return observedFocusState(shortcut, output: normalizedOutput)
        }
    }

    private static func markerState(in output: String) -> String? {
        if output.contains("wiqostate:on") || output.contains("state:on") { return "on" }
        if output.contains("wiqostate:off") || output.contains("state:off") { return "off" }
        return nil
    }

    private static func observedFocusState(_ shortcut: WiqoShortcut, output: String) -> String? {
        let inactiveMarkers = ["off", "kapali", "none", "no focus", "no active focus", "inactive", "devre disi"]
        let turningOff: Bool
        switch shortcut {
        case .focusDoNotDisturbOff, .focusPersonalOff, .focusWorkOff:
            turningOff = true
        default:
            turningOff = false
        }
        if inactiveMarkers.contains(where: output.contains) { return "off" }

        let targetMarkers: [String]
        switch shortcut {
        case .focusDoNotDisturbOn, .focusDoNotDisturbOff:
            targetMarkers = ["rahatsiz etme", "do not disturb", "default"]
        case .focusPersonalOn, .focusPersonalOff:
            targetMarkers = ["kisisel", "personal", "personal-time"]
        case .focusWorkOn, .focusWorkOff:
            targetMarkers = ["is", "work"]
        default:
            targetMarkers = []
        }
        if turningOff && targetMarkers.contains(where: output.contains) { return "on" }
        let allFocusMarkers = [
            "rahatsiz etme", "do not disturb", "default", "kisisel", "personal", "personal-time", "is", "work"
        ]
        if turningOff && allFocusMarkers.contains(where: output.contains) { return "off" }
        if targetMarkers.contains(where: output.contains) || output.contains("on") || output.contains("acik") || output.contains("enabled") {
            return "on"
        }
        return nil
    }

    private static func currentWiFiState() -> String? {
        let interfaceSnapshot = runProcess(executable: "/usr/sbin/networksetup", arguments: ["-listallhardwareports"], timeoutSeconds: 3)
        guard let interfaces = String(data: interfaceSnapshot.stdout, encoding: .utf8) else { return nil }
        let lines = interfaces.split(whereSeparator: \.isNewline).map(String.init)
        guard let wifiIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Hardware Port: Wi-Fi" }),
              wifiIndex + 1 < lines.count else { return nil }
        let deviceLine = lines[(wifiIndex + 1)...].first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Device:") })
        guard let deviceLine else { return nil }
        let device = deviceLine.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
        let snapshot = runProcess(executable: "/usr/sbin/networksetup", arguments: ["-getairportpower", device], timeoutSeconds: 3)
        let text = String(decoding: snapshot.stdout, as: UTF8.self).lowercased()
        if text.contains("on") { return "on" }
        if text.contains("off") { return "off" }
        return nil
    }

    private static func currentBluetoothState() -> String? {
        let snapshot = runProcess(executable: "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"], timeoutSeconds: 5)
        guard snapshot.exitCode == 0 else { return nil }
        let output = String(decoding: snapshot.stdout, as: UTF8.self).lowercased()
        if output.contains("\"controller_power_state\" : 1") || output.contains("\"controller_power_state\": 1") { return "on" }
        if output.contains("\"controller_power_state\" : 0") || output.contains("\"controller_power_state\": 0") { return "off" }
        if output.contains("bluetooth power: on") { return "on" }
        if output.contains("bluetooth power: off") { return "off" }
        return nil
    }

    static func controlUIElement(_ payload: UIElementPayload) -> (data: CommandData?, error: RovaError?) {
        guard hasAccessibilityAccess() else {
            return (nil, RovaError(code: "ACCESSIBILITY_PERMISSION_REQUIRED", message: "Wiqo'nun arayüz kontrolü için Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik bölümünden izin verin. Ayarlar: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", category: "permission"))
        }
        guard let runningApplication = NSRunningApplication.runningApplications(withBundleIdentifier: payload.bundleIdentifier).first,
              runningApplication.processIdentifier > 0 else {
            return (nil, RovaError(code: "UI_TARGET_NOT_RUNNING", message: "Hedef uygulama çalışmıyor; arayüz kontrolü için önce uygulamayı açın.", category: "tool_failure"))
        }

        let application = AXUIElementCreateApplication(runningApplication.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, 0.75)
        let roots: [AXUIElement]
        if let windowTitle = payload.windowTitle {
            roots = axWindows(of: application).filter { axMatches($0, text: windowTitle) }
            guard !roots.isEmpty else {
                return (nil, RovaError(code: "UI_WINDOW_NOT_FOUND", message: "Hedef pencere bulunamadı.", category: "tool_failure"))
            }
        } else {
            roots = [application]
        }

        let search = axMatches(roots: roots, label: payload.label, role: payload.role)
        guard !search.timedOut else {
            return (nil, RovaError(code: "UI_SEARCH_TIMEOUT", message: "Accessibility ağacı zamanında yanıt vermedi; hedef uygulama meşgul olabilir.", category: "timeout"))
        }
        let matches = search.matches
        guard matches.count == 1, let element = matches.first else {
            if matches.count > 1 {
                return (nil, RovaError(code: "UI_ELEMENT_AMBIGUOUS", message: "Birden fazla Accessibility öğesi eşleşti; daha net bir etiket veya rol belirtin.", category: "tool_failure"))
            }
            return (nil, RovaError(code: "UI_ELEMENT_NOT_FOUND", message: "Accessibility ağacında hedef öğe bulunamadı.", category: "tool_failure"))
        }

        let actionError: AXError
        switch payload.action {
        case .press:
            _ = AXUIElementSetMessagingTimeout(element, 0.75)
            actionError = AXUIElementPerformAction(element, kAXPressAction as CFString)
        case .setValue:
            guard let value = payload.value else {
                return (nil, RovaError(code: "INVALID_PAYLOAD", message: "Değer atama eylemi için value gerekli.", category: "validation"))
            }
            _ = AXUIElementSetMessagingTimeout(element, 0.75)
            actionError = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        }
        guard actionError == .success else {
            return (nil, RovaError(code: "UI_ACTION_FAILED", message: "Accessibility eylemi hedef öğeye uygulanamadı.", category: "tool_failure"))
        }

        Thread.sleep(forTimeInterval: 0.12)
        let content = uiElementContent(element, bundleIdentifier: payload.bundleIdentifier, matchedCount: 1, expectedValue: payload.expectedValue)
        guard payload.expectedValue == nil || content.verified else {
            return (.uiElement(content), RovaError(code: "UI_VERIFICATION_FAILED", message: "Accessibility eylemi uygulandı ancak beklenen değer doğrulanamadı.", category: "tool_failure"))
        }
        return (.uiElement(content), nil)
    }

    private struct AXSearchResult {
        let matches: [AXUIElement]
        let timedOut: Bool
    }

    private static func axMatches(roots: [AXUIElement], label: String, role: String?) -> AXSearchResult {
        let normalizedLabel = normalizeAXText(label)
        var queue = roots.map { ($0, 0) }
        var matches: [AXUIElement] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(5)
        while !queue.isEmpty && visited < 4_000 && Date() < deadline {
            let (element, depth) = queue.removeFirst()
            visited += 1
            guard depth <= 32 else { continue }
            let title = axString(element, attribute: kAXTitleAttribute)
            let description = axString(element, attribute: kAXDescriptionAttribute)
            let elementRole = axString(element, attribute: kAXRoleAttribute)
            let texts = [title, description].compactMap { $0 }.map(normalizeAXText)
            if texts.contains(normalizedLabel), (role == nil || normalizeAXText(elementRole ?? "") == normalizeAXText(role!)) {
                matches.append(element)
                if matches.count > 1 { return AXSearchResult(matches: matches, timedOut: false) }
            }
            for child in axChildren(element) {
                queue.append((child, depth + 1))
            }
        }
        return AXSearchResult(matches: matches, timedOut: !queue.isEmpty && Date() >= deadline)
    }

    private static func axWindows(of application: AXUIElement) -> [AXUIElement] {
        _ = AXUIElementSetMessagingTimeout(application, 0.75)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        _ = AXUIElementSetMessagingTimeout(element, 0.75)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }

    private static func axString(_ element: AXUIElement, attribute: String) -> String? {
        _ = AXUIElementSetMessagingTimeout(element, 0.75)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func axBool(_ element: AXUIElement, attribute: String) -> Bool? {
        _ = AXUIElementSetMessagingTimeout(element, 0.75)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func axMatches(_ element: AXUIElement, text: String) -> Bool {
        let normalized = normalizeAXText(text)
        return [axString(element, attribute: kAXTitleAttribute), axString(element, attribute: kAXDescriptionAttribute)]
            .compactMap { $0 }
            .map(normalizeAXText)
            .contains(normalized)
    }

    private static func normalizeAXText(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uiElementContent(_ element: AXUIElement, bundleIdentifier: String, matchedCount: Int, expectedValue: String?) -> UIElementContent {
        let value = axString(element, attribute: kAXValueAttribute) ?? axString(element, attribute: kAXValueDescriptionAttribute)
        let verified = expectedValue.map { normalizeAXText(value ?? "") == normalizeAXText($0) } ?? true
        return UIElementContent(
            bundleIdentifier: bundleIdentifier,
            title: axString(element, attribute: kAXTitleAttribute),
            role: axString(element, attribute: kAXRoleAttribute),
            value: value,
            description: axString(element, attribute: kAXDescriptionAttribute),
            enabled: axBool(element, attribute: kAXEnabledAttribute),
            matchedCount: matchedCount,
            verified: verified
        )
    }

    static func clickScreen(_ payload: ScreenClickPayload) -> (data: CommandData?, error: RovaError?) {
        guard hasAccessibilityAccess() else {
            return (nil, RovaError(code: "ACCESSIBILITY_PERMISSION_REQUIRED", message: "Ekran tıklaması için Wiqo'ya Erişilebilirlik izni verin. Ayarlar: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", category: "permission"))
        }
        guard CGPreflightScreenCaptureAccess() else {
            return (nil, RovaError(code: "SCREEN_RECORDING_PERMISSION_REQUIRED", message: "Ekran tıklamasının görüntüyle eşleşmesi için Wiqo'ya Ekran Kaydı izni verin. Ayarlar: x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture", category: "permission"))
        }
        let displayID = payload.displayID ?? CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else {
            return (nil, RovaError(code: "DISPLAY_NOT_FOUND", message: "Hedef ekran bulunamadı.", category: "tool_failure"))
        }
        let screenshotAspect = Double(payload.screenshotWidth) / Double(payload.screenshotHeight)
        let displayAspect = Double(bounds.width) / Double(bounds.height)
        guard abs(screenshotAspect - displayAspect) / displayAspect <= 0.25 else {
            return (nil, RovaError(code: "STALE_SCREEN_OBSERVATION", message: "Ekran gözlemi mevcut ekran düzeniyle eşleşmiyor; yeniden ekran görüntüsü alın.", category: "tool_failure"))
        }
        let point = CGPoint(
            x: bounds.minX + CGFloat(payload.normalizedX) * bounds.width,
            y: bounds.minY + CGFloat(payload.normalizedY) * bounds.height
        )
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return (nil, RovaError(code: "SCREEN_CLICK_UNAVAILABLE", message: "Ekran tıklaması başlatılamadı.", category: "tool_failure"))
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return (.screenClick(ScreenClickContent(displayID: displayID, x: point.x, y: point.y, expectedTarget: payload.expectedTarget)), nil)
    }

    static func captureScreen(_ payload: ScreenCapturePayload) async -> (data: CommandData?, error: RovaError?) {
        guard CGPreflightScreenCaptureAccess() else {
            return (nil, RovaError(code: "SCREEN_RECORDING_PERMISSION_REQUIRED", message: "Ekran görüntüsü için Sistem Ayarları > Gizlilik ve Güvenlik > Ekran ve Sistem Sesi Kaydı bölümünden Wiqo'ya izin verin. Ayarlar: x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture", category: "permission"))
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = payload.displayID.flatMap({ id in content.displays.first(where: { $0.displayID == id }) }) ?? content.displays.first else {
                return (nil, RovaError(code: "DISPLAY_NOT_FOUND", message: "Ekran bulunamadı.", category: "tool_failure"))
            }
            let scale = min(1.0, CGFloat(payload.maxWidth) / CGFloat(max(display.width, 1)))
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(CGFloat(display.width) * scale))
            configuration.height = max(1, Int(CGFloat(display.height) * scale))
            configuration.showsCursor = true
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let resized = resizedImage(image, maxWidth: payload.maxWidth) else {
                return (nil, RovaError(code: "SCREEN_CAPTURE_FAILED", message: "Ekran görüntüsü hazırlanamadı.", category: "tool_failure"))
            }
            var jpeg: Data?
            for quality in [0.72, 0.58, 0.42] {
                let rep = NSBitmapImageRep(cgImage: resized)
                if let candidate = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]), candidate.count <= maxScreenshotBytes {
                    jpeg = candidate
                    break
                }
            }
            guard let jpeg else {
                return (nil, RovaError(code: "SCREEN_TOO_LARGE", message: "Ekran görüntüsü güvenli aktarım sınırına sığmadı.", category: "tool_failure"))
            }
            let screenshot = ScreenshotContent(filename: "rova-screen-\(UUID().uuidString).jpg", mimeType: "image/jpeg", dataBase64: jpeg.base64EncodedString(), width: resized.width, height: resized.height)
            return (.screenshot(screenshot), nil)
        } catch {
            return (nil, RovaError(code: "SCREEN_CAPTURE_FAILED", message: "Ekran görüntüsü alınamadı. Screen Recording iznini kontrol edin.", category: "permission"))
        }
    }

    private static func resizedImage(_ image: CGImage, maxWidth: Int) -> CGImage? {
        let scale = min(1.0, CGFloat(maxWidth) / CGFloat(max(image.width, 1)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

private struct MacDesktopSnapshot {
    let taskId: String
    let id: String
    let generation: Int
    let applicationName: String?
    let applicationIdentifier: String?
    let windowTitle: String?
    let targets: [DesktopTarget]
    let elements: [String: AXUIElement]
    let points: [String: CGPoint]
    let fingerprint: String
    let expectedCursor: CGPoint?
    let updatedAt: Date
}

private final class MacDesktopSessionStore: @unchecked Sendable {
    static let shared = MacDesktopSessionStore()
    private static let lifetime: TimeInterval = 15 * 60
    private let lock = NSLock()
    private var generations: [String: Int] = [:]
    private var snapshots: [String: MacDesktopSnapshot] = [:]

    func nextGeneration(for taskId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let next = (generations[taskId] ?? 0) + 1
        generations[taskId] = next
        return next
    }

    func snapshot(for taskId: String) -> MacDesktopSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = snapshots[taskId] else { return nil }
        guard snapshot.updatedAt.timeIntervalSinceNow > -Self.lifetime else {
            snapshots.removeValue(forKey: taskId)
            generations.removeValue(forKey: taskId)
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: MacDesktopSnapshot) {
        lock.lock()
        let cutoff = Date().addingTimeInterval(-Self.lifetime)
        let expired = snapshots.values.filter { $0.updatedAt < cutoff }.map(\.taskId)
        for taskId in expired {
            snapshots.removeValue(forKey: taskId)
            generations.removeValue(forKey: taskId)
        }
        snapshots[snapshot.taskId] = snapshot
        lock.unlock()
    }

    func clear(taskId: String) {
        lock.lock()
        snapshots.removeValue(forKey: taskId)
        generations.removeValue(forKey: taskId)
        lock.unlock()
    }
}

@MainActor
private final class MacAgentCursorOverlay {
    static let shared = MacAgentCursorOverlay()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let cursor = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: cursor.x - 15, y: cursor.y - 15))
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
            self?.hideTask = nil
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 30, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = MacAgentCursorView(frame: panel.contentRect(forFrameRect: panel.frame))
        return panel
    }
}

private final class MacAgentCursorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let outer = bounds.insetBy(dx: 2, dy: 2)
        NSColor.systemPurple.withAlphaComponent(0.2).setFill()
        NSBezierPath(ovalIn: outer).fill()
        NSColor.systemPurple.setStroke()
        let path = NSBezierPath(ovalIn: outer.insetBy(dx: 3, dy: 3))
        path.lineWidth = 2
        path.stroke()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - 2, y: bounds.midY - 2, width: 4, height: 4)).fill()
    }
}

extension MacSystem {
    private static let desktopStore = MacDesktopSessionStore.shared
    private static let desktopTargetLimit = 80
    private static let desktopTraversalLimit = 1_500

    static func controlDesktop(_ payload: ComputerDesktopPayload) -> (data: CommandData?, error: RovaError?) {
        guard hasAccessibilityAccess() else {
            return (nil, RovaError(code: "ACCESSIBILITY_PERMISSION_REQUIRED", message: "Masaüstü kontrolü için Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik bölümünden Wiqo'ya izin verin.", category: "permission"))
        }
        if payload.action == .cancel {
            desktopStore.clear(taskId: payload.taskId)
            Task { @MainActor in MacAgentCursorOverlay.shared.hide() }
            return (.computerDesktop(DesktopControlContent(taskId: payload.taskId, action: .cancel, accessGranted: true, changed: false, verified: true)), nil)
        }

        if payload.action == .observe {
            return desktopObservation(taskId: payload.taskId, action: .observe, changed: false, verified: true)
        }
        if payload.action == .runSteps {
            return controlDesktopSteps(payload)
        }

        guard let prior = desktopStore.snapshot(for: payload.taskId) else {
            return (nil, RovaError(code: "DESKTOP_OBSERVATION_REQUIRED", message: "Önce masaüstünü gözlemleyip güncel hedefleri alın.", category: "tool_failure"))
        }
        if let snapshotId = payload.snapshotId, snapshotId != prior.id {
            return (nil, RovaError(code: "DESKTOP_STALE_OBSERVATION", message: "Masaüstü görünümü değişti; işlemden önce yeniden gözlemleyin.", category: "tool_failure"))
        }
        if desktopWasInterrupted(prior) {
            desktopStore.clear(taskId: payload.taskId)
            Task { @MainActor in MacAgentCursorOverlay.shared.hide() }
            return (nil, RovaError(code: "DESKTOP_USER_INTERRUPTED", message: "Kullanıcı fareyi devraldığı için masaüstü görevi güvenle durduruldu.", category: "permission"))
        }

        let operationError: RovaError?
        switch payload.action {
        case .move:
            operationError = desktopPoint(for: payload, snapshot: prior).flatMap { point in
                moveDesktopCursor(to: point)
            } ?? RovaError(code: "DESKTOP_TARGET_NOT_FOUND", message: "Hedef güncel masaüstü görünümünde bulunamadı.", category: "tool_failure")
        case .click, .doubleClick, .rightClick:
            guard let point = desktopPoint(for: payload, snapshot: prior) else {
                return (nil, RovaError(code: "DESKTOP_TARGET_NOT_FOUND", message: "Tıklama hedefi güncel masaüstü görünümünde bulunamadı.", category: "tool_failure"))
            }
            if let targetRef = payload.targetRef, let target = prior.targets.first(where: { $0.ref == targetRef }), desktopTargetIsSensitive(target) {
                return (nil, RovaError(code: "DESKTOP_SENSITIVE_ACTION_BLOCKED", message: "Bu hassas eylem genel masaüstü izniyle çalıştırılamaz.", category: "permission"))
            }
            operationError = clickDesktop(at: point, action: payload.action)
        case .scroll:
            if let targetRef = payload.targetRef, let point = prior.points[targetRef] {
                _ = moveDesktopCursor(to: point)
            }
            operationError = scrollDesktop(direction: payload.direction ?? "down", amount: payload.amount ?? 2)
        case .dragDrop:
            guard let sourceRef = payload.sourceRef, let destinationRef = payload.destinationRef,
                  let source = prior.points[sourceRef], let destination = prior.points[destinationRef] else {
                return (nil, RovaError(code: "DESKTOP_TARGET_NOT_FOUND", message: "Sürükleme kaynak veya hedefi artık görünür değil.", category: "tool_failure"))
            }
            operationError = dragDesktop(from: source, to: destination)
        case .type:
            guard let targetRef = payload.targetRef, let element = prior.elements[targetRef], let text = payload.text else {
                return (nil, RovaError(code: "DESKTOP_TARGET_NOT_FOUND", message: "Yazma hedefi artık görünür değil.", category: "tool_failure"))
            }
            guard let target = prior.targets.first(where: { $0.ref == targetRef }), !target.secure else {
                return (nil, RovaError(code: "DESKTOP_SECURE_FIELD_BLOCKED", message: "Parola ve güvenli metin alanları modele kapalıdır; bu alanı kendiniz doldurun.", category: "permission"))
            }
            operationError = typeDesktop(text, into: element)
        case .hotkey:
            operationError = sendDesktopHotkey(payload.keys ?? [])
        case .wait:
            Thread.sleep(forTimeInterval: Double(payload.amount ?? 250) / 1_000)
            operationError = nil
        case .observe, .runSteps, .cancel:
            operationError = nil
        }
        if let operationError { return (nil, operationError) }

        Thread.sleep(forTimeInterval: 0.18)
        return desktopObservation(taskId: payload.taskId, action: payload.action, changedFrom: prior.fingerprint, verified: true)
    }

    private static func controlDesktopSteps(_ payload: ComputerDesktopPayload) -> (data: CommandData?, error: RovaError?) {
        guard let steps = payload.steps, !steps.isEmpty, steps.count <= 8 else {
            return (nil, RovaError(code: "DESKTOP_STEPS_INVALID", message: "Toplu masaüstü görevi 1-8 güvenli adım içermelidir.", category: "validation"))
        }
        var evidence: [ActionVerificationEvidence] = []
        var lastContent: DesktopControlContent?
        for (index, step) in steps.enumerated() {
            let before = desktopStore.snapshot(for: payload.taskId)
            let nested = ComputerDesktopPayload(
                taskId: payload.taskId,
                action: step.action,
                snapshotId: step.action == .observe ? nil : before?.id,
                targetRef: step.targetRef,
                sourceRef: step.sourceRef,
                destinationRef: step.destinationRef,
                normalizedX: step.normalizedX,
                normalizedY: step.normalizedY,
                direction: step.direction,
                amount: step.amount,
                text: step.text,
                keys: step.keys,
                accessGranted: true
            )
            let outcome = controlDesktop(nested)
            let content: DesktopControlContent?
            if case .computerDesktop(let value)? = outcome.data { content = value } else { content = nil }
            if let content { lastContent = content }
            let after = desktopStore.snapshot(for: payload.taskId)
            evidence.append(ActionVerificationEvidence(
                index: index,
                action: step.action.rawValue,
                targetRef: step.targetRef ?? step.sourceRef,
                ok: outcome.error == nil,
                changed: content?.changed ?? (before?.fingerprint != after?.fingerprint),
                verified: outcome.error == nil && (content?.verified ?? false),
                before: ActionStateEvidence(identifier: before?.applicationIdentifier, title: before?.windowTitle, version: before?.generation),
                after: ActionStateEvidence(identifier: after?.applicationIdentifier, title: after?.windowTitle, version: after?.generation),
                errorCode: outcome.error?.code
            ))
            if let error = outcome.error {
                return (.computerDesktop(batchDesktopContent(taskId: payload.taskId, last: lastContent, evidence: evidence, verified: false)), error)
            }
        }
        return (.computerDesktop(batchDesktopContent(taskId: payload.taskId, last: lastContent, evidence: evidence, verified: evidence.allSatisfy { $0.verified })), nil)
    }

    private static func batchDesktopContent(taskId: String, last: DesktopControlContent?, evidence: [ActionVerificationEvidence], verified: Bool) -> DesktopControlContent {
        DesktopControlContent(
            taskId: taskId,
            action: .runSteps,
            snapshotId: last?.snapshotId,
            previousSnapshotId: last?.previousSnapshotId,
            applicationName: last?.applicationName,
            applicationIdentifier: last?.applicationIdentifier,
            windowTitle: last?.windowTitle,
            cursorX: last?.cursorX,
            cursorY: last?.cursorY,
            targets: last?.targets ?? [],
            addedTargets: last?.addedTargets ?? [],
            changedTargets: last?.changedTargets ?? [],
            removedTargetRefs: last?.removedTargetRefs ?? [],
            accessGranted: true,
            changed: evidence.contains { $0.changed },
            verified: verified,
            evidence: evidence
        )
    }

    private static func desktopObservation(taskId: String, action: ComputerDesktopAction, changedFrom: String? = nil, changed: Bool? = nil, verified: Bool) -> (data: CommandData?, error: RovaError?) {
        guard let application = NSWorkspace.shared.frontmostApplication, application.processIdentifier > 0 else {
            return (nil, RovaError(code: "DESKTOP_APP_UNAVAILABLE", message: "Ön plandaki uygulama belirlenemedi.", category: "tool_failure"))
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(appElement, 0.4)
        let roots = axWindows(of: appElement)
        let rootElements = roots.isEmpty ? [appElement] : roots
        let previous = desktopStore.snapshot(for: taskId)
        let generation = desktopStore.nextGeneration(for: taskId)
        let snapshotId = UUID().uuidString.lowercased()
        let desktopBounds = activeDesktopBounds()
        let deadline = Date().addingTimeInterval(2.5)
        var queue = rootElements.map { ($0, 0) }
        var visited = 0
        var targets: [DesktopTarget] = []
        var elements: [String: AXUIElement] = [:]
        var points: [String: CGPoint] = [:]
        var signatureCounts: [String: Int] = [:]

        while !queue.isEmpty && visited < desktopTraversalLimit && targets.count < desktopTargetLimit && Date() < deadline {
            let (element, depth) = queue.removeFirst()
            visited += 1
            guard depth <= 24 else { continue }
            let role = axString(element, attribute: kAXRoleAttribute) ?? ""
            let title = axString(element, attribute: kAXTitleAttribute)
            let description = axString(element, attribute: kAXDescriptionAttribute)
            let valueDescription = axString(element, attribute: kAXValueDescriptionAttribute)
            let name = [title, description, valueDescription].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: { !$0.isEmpty }) ?? role.replacingOccurrences(of: "AX", with: "")
            let secure = role.localizedCaseInsensitiveContains("secure") || (axString(element, attribute: kAXSubroleAttribute)?.localizedCaseInsensitiveContains("secure") == true)
            let enabled = axBool(element, attribute: kAXEnabledAttribute) ?? true
            let actions = desktopActions(for: element, role: role, secure: secure)
            if enabled, !actions.isEmpty, let frame = axFrame(element), frame.width > 1, frame.height > 1, frame.intersects(desktopBounds) {
                let boundedName = secure ? "Güvenli alan" : String(name.prefix(160))
                let normalizedRole = role.replacingOccurrences(of: "AX", with: "").lowercased()
                let signature = "\(normalizedRole)|\(normalizeAXText(boundedName))|\(actions.joined(separator: ","))"
                let occurrence = (signatureCounts[signature] ?? 0) + 1
                signatureCounts[signature] = occurrence
                let ref = "d-\(desktopShortHash("\(signature)|\(occurrence)"))"
                let normalized = DesktopTargetFrame(
                    x: Double((frame.minX - desktopBounds.minX) / desktopBounds.width),
                    y: Double((frame.minY - desktopBounds.minY) / desktopBounds.height),
                    width: Double(frame.width / desktopBounds.width),
                    height: Double(frame.height / desktopBounds.height)
                )
                targets.append(DesktopTarget(ref: ref, role: normalizedRole, name: boundedName, frame: normalized, actions: actions, enabled: true, secure: secure))
                elements[ref] = element
                points[ref] = CGPoint(x: frame.midX, y: frame.midY)
            }
            for child in axChildren(element).prefix(200) { queue.append((child, depth + 1)) }
        }

        let windowTitle = roots.first.flatMap { axString($0, attribute: kAXTitleAttribute) }
        let cursor = CGEvent(source: nil)?.location
        let cursorX = cursor.map { Double(($0.x - desktopBounds.minX) / desktopBounds.width) }
        let cursorY = cursor.map { Double(($0.y - desktopBounds.minY) / desktopBounds.height) }
        let fingerprint = ([application.bundleIdentifier ?? application.localizedName ?? "", windowTitle ?? ""] + targets.map { "\($0.role):\($0.name):\($0.frame.x):\($0.frame.y)" }).joined(separator: "|")
        let snapshot = MacDesktopSnapshot(taskId: taskId, id: snapshotId, generation: generation, applicationName: application.localizedName, applicationIdentifier: application.bundleIdentifier, windowTitle: windowTitle, targets: targets, elements: elements, points: points, fingerprint: fingerprint, expectedCursor: cursor, updatedAt: Date())
        desktopStore.save(snapshot)
        let didChange = changed ?? changedFrom.map { $0 != fingerprint } ?? false
        let oldTargets = Dictionary(uniqueKeysWithValues: (previous?.targets ?? []).map { ($0.ref, $0) })
        let newTargets = Dictionary(uniqueKeysWithValues: targets.map { ($0.ref, $0) })
        let addedTargets = targets.filter { oldTargets[$0.ref] == nil }
        let changedTargets = targets.filter { target in oldTargets[target.ref].map { $0 != target } ?? false }
        let removedTargetRefs = oldTargets.keys.filter { newTargets[$0] == nil }.sorted()
        let content = DesktopControlContent(taskId: taskId, action: action, snapshotId: snapshotId, previousSnapshotId: previous?.id, applicationName: application.localizedName, applicationIdentifier: application.bundleIdentifier, windowTitle: windowTitle, cursorX: cursorX, cursorY: cursorY, targets: targets, addedTargets: addedTargets, changedTargets: changedTargets, removedTargetRefs: removedTargetRefs, accessGranted: true, changed: didChange || !addedTargets.isEmpty || !changedTargets.isEmpty || !removedTargetRefs.isEmpty, verified: verified)
        return (.computerDesktop(content), nil)
    }

    private static func desktopShortHash(_ value: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    private static func desktopActions(for element: AXUIElement, role: String, secure: Bool) -> [String] {
        var value: CFArray?
        let names: [String]
        if AXUIElementCopyActionNames(element, &value) == .success, let raw = value as? [String] { names = raw } else { names = [] }
        let editable = role == kAXTextFieldRole as String || role == kAXTextAreaRole as String || role == kAXComboBoxRole as String
        let directControlRoles: Set<String> = [
            "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuItem",
            "AXSlider", "AXIncrementor", "AXCell", "AXRow", "AXTab", "AXDisclosureTriangle"
        ]
        let interactive = editable || names.contains(kAXPressAction as String) || directControlRoles.contains(role)
        guard interactive, axFrame(element) != nil else { return [] }
        var actions: [String] = []
        actions.append(contentsOf: ["move", "click", "double_click", "right_click"])
        if ["AXCell", "AXRow"].contains(role) { actions.append("drag_drop") }
        if editable && !secure { actions.append("type") }
        return Array(Set(actions)).sorted()
    }

    private static func desktopPoint(for payload: ComputerDesktopPayload, snapshot: MacDesktopSnapshot) -> CGPoint? {
        if let ref = payload.targetRef { return snapshot.points[ref] }
        guard let x = payload.normalizedX, let y = payload.normalizedY else { return nil }
        let bounds = activeDesktopBounds()
        return CGPoint(x: bounds.minX + CGFloat(x) * bounds.width, y: bounds.minY + CGFloat(y) * bounds.height)
    }

    private static func desktopWasInterrupted(_ snapshot: MacDesktopSnapshot) -> Bool {
        guard let expected = snapshot.expectedCursor, let current = CGEvent(source: nil)?.location else { return false }
        return hypot(current.x - expected.x, current.y - expected.y) > 120
    }

    private static func desktopTargetIsSensitive(_ target: DesktopTarget) -> Bool {
        if target.secure { return true }
        let text = target.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
        let blocked = ["delete", "erase", "remove", "sil", "kaldir", "purchase", "buy", "pay", "satin al", "ode", "send", "gonder", "transfer", "install", "uninstall"]
        return blocked.contains(where: text.contains)
    }

    private static func moveDesktopCursor(to point: CGPoint) -> RovaError? {
        let start = CGEvent(source: nil)?.location ?? point
        for step in 1...10 {
            let progress = CGFloat(step) / 10
            let current = CGPoint(x: start.x + (point.x - start.x) * progress, y: start.y + (point.y - start.y) * progress)
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: current, mouseButton: .left) else {
                return RovaError(code: "DESKTOP_INPUT_UNAVAILABLE", message: "Fare hareketi oluşturulamadı.", category: "tool_failure")
            }
            event.post(tap: .cghidEventTap)
            usleep(12_000)
        }
        guard let observed = CGEvent(source: nil)?.location, hypot(observed.x - point.x, observed.y - point.y) <= 4 else {
            return RovaError(code: "DESKTOP_INPUT_UNAVAILABLE", message: "Fare hedef konuma taşınamadı.", category: "tool_failure")
        }
        Task { @MainActor in MacAgentCursorOverlay.shared.show() }
        return nil
    }

    private static func clickDesktop(at point: CGPoint, action: ComputerDesktopAction) -> RovaError? {
        if let moveError = moveDesktopCursor(to: point) { return moveError }
        let button: CGMouseButton = action == .rightClick ? .right : .left
        let downType: CGEventType = action == .rightClick ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = action == .rightClick ? .rightMouseUp : .leftMouseUp
        let count = action == .doubleClick ? 2 : 1
        for index in 1...count {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
                return RovaError(code: "DESKTOP_INPUT_UNAVAILABLE", message: "Fare eylemi oluşturulamadı.", category: "tool_failure")
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(80_000)
        }
        return nil
    }

    private static func scrollDesktop(direction: String, amount: Int) -> RovaError? {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(direction == "up" ? amount : -amount), wheel2: 0, wheel3: 0) else {
            return RovaError(code: "DESKTOP_INPUT_UNAVAILABLE", message: "Kaydırma eylemi oluşturulamadı.", category: "tool_failure")
        }
        event.post(tap: .cghidEventTap)
        Task { @MainActor in MacAgentCursorOverlay.shared.show() }
        return nil
    }

    private static func dragDesktop(from source: CGPoint, to destination: CGPoint) -> RovaError? {
        if let moveError = moveDesktopCursor(to: source) { return moveError }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: source, mouseButton: .left) else {
            return RovaError(code: "DESKTOP_INPUT_UNAVAILABLE", message: "Sürükleme eylemi oluşturulamadı.", category: "tool_failure")
        }
        down.post(tap: .cghidEventTap)
        for step in 1...14 {
            let progress = CGFloat(step) / 14
            let point = CGPoint(x: source.x + (destination.x - source.x) * progress, y: source.y + (destination.y - source.y) * progress)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(18_000)
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: destination, mouseButton: .left)?.post(tap: .cghidEventTap)
        Task { @MainActor in MacAgentCursorOverlay.shared.show() }
        return nil
    }

    private static func typeDesktop(_ text: String, into element: AXUIElement) -> RovaError? {
        _ = AXUIElementSetMessagingTimeout(element, 0.5)
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
        guard result == .success else {
            return RovaError(code: "DESKTOP_TYPE_FAILED", message: "Metin hedef alana güvenli biçimde yazılamadı.", category: "tool_failure")
        }
        return nil
    }

    private static func sendDesktopHotkey(_ keys: [String]) -> RovaError? {
        let normalized = keys.map { $0.lowercased() }
        let modifierMap: [String: CGEventFlags] = ["command": .maskCommand, "control": .maskControl, "option": .maskAlternate, "alt": .maskAlternate, "shift": .maskShift]
        let keyMap: [String: CGKeyCode] = ["a": 0, "c": 8, "v": 9, "x": 7, "z": 6, "f": 3, "enter": 36, "escape": 53, "tab": 48, "arrowleft": 123, "arrowright": 124, "arrowdown": 125, "arrowup": 126]
        let modifiers = normalized.compactMap { modifierMap[$0] }.reduce(CGEventFlags()) { $0.union($1) }
        guard let keyName = normalized.last(where: { keyMap[$0] != nil }), let code = keyMap[keyName],
              let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            return RovaError(code: "DESKTOP_HOTKEY_BLOCKED", message: "Bu klavye kısayolu güvenli izin listesinde değil.", category: "permission")
        }
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return nil
    }

    private static func activeDesktopBounds() -> CGRect {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return displays.prefix(Int(count)).map(CGDisplayBounds).reduce(.null) { $0.union($1) }
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let rawPosition = positionValue, let rawSize = sizeValue,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let position = rawPosition as! AXValue
        let size = rawSize as! AXValue
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
