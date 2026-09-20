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
