import Foundation
import SwiftUI

/// A user-facing group of the raw capability strings the backend gates tools on (see
/// RovaShared/Validation.swift's RovaCommandAuthority + the backend's matching maps) - lets the
/// Mac owner turn a whole category off ("never let Wiqo touch Mail") without having to know the
/// wire-level capability names.
struct CapabilityGroup: Identifiable {
    let id: String
    let title: String
    let icon: String
    let capabilities: [String]
}

enum RovaCapabilityCatalog {
    private static let manifestCapabilities = Set(RovaOperationManifest.advertisedCapabilities(for: .macOS))

    /// Every capability the Mac can ever advertise (mirrors MacRuntime.deviceInfo's list) minus
    /// `runtime.status`, which is harmless, read-only, and always on.
    private static let rawGroups: [CapabilityGroup] = [
        CapabilityGroup(id: "apps", title: "Uygulamalar", icon: "app.badge", capabilities: [
            "device.app.open", "device.app.open_by_name", "device.app.quit", "device.app.control", "device.app.list"
        ]),
        CapabilityGroup(id: "system", title: "Sistem Kontrolü", icon: "power", capabilities: [
            "device.system.power", "device.display", "device.audio", "device.media"
        ]),
        CapabilityGroup(id: "files", title: "Dosyalar", icon: "folder", capabilities: [
            "device.files.list", "device.files.read", "device.files.write", "device.files.move", "device.files.copy", "device.files.delete"
        ]),
        CapabilityGroup(id: "documents", title: "Belgeler", icon: "doc.text", capabilities: [
            "document.read", "document.edit", "artifact.save"
        ]),
        CapabilityGroup(id: "code", title: "Kod Çalıştırma", icon: "chevron.left.forwardslash.chevron.right", capabilities: [
            "device.code.execute"
        ]),
        CapabilityGroup(id: "screen", title: "Ekran ve Arayüz", icon: "rectangle.on.rectangle", capabilities: [
            "device.screen.capture", "device.screen.click", "device.ui.control"
        ]),
        CapabilityGroup(id: "clipboard", title: "Pano", icon: "doc.on.clipboard", capabilities: [
            "device.clipboard"
        ]),
        CapabilityGroup(id: "calendar", title: "Takvim", icon: "calendar", capabilities: [
            "calendar.read", "calendar.write"
        ]),
        CapabilityGroup(id: "reminders", title: "Hatırlatıcılar", icon: "checklist", capabilities: [
            "reminders.read", "reminders.write"
        ]),
        CapabilityGroup(id: "notes", title: "Notlar", icon: "note.text", capabilities: [
            "notes.write"
        ]),
        CapabilityGroup(id: "mail", title: "E-posta", icon: "envelope", capabilities: [
            "mail.send"
        ]),
        CapabilityGroup(id: "messaging", title: "Mesajlaşma", icon: "message", capabilities: [
            "device.messaging.send"
        ]),
        CapabilityGroup(id: "web", title: "Web ve Bağlantılar", icon: "link", capabilities: [
            "device.url.open", "device.shortcut.run", "device.browser.control"
        ])
    ]

    /// The manifest is the source of truth for what can be advertised. The UI keeps its human
    /// grouping, but stale labels cannot make an unsupported capability reach the backend.
    static let groups: [CapabilityGroup] = rawGroups.compactMap { group in
        let capabilities = group.capabilities.filter(manifestCapabilities.contains)
        return capabilities.isEmpty ? nil : CapabilityGroup(id: group.id, title: group.title, icon: group.icon, capabilities: capabilities)
    }
}

/// Persists which capability groups the user turned off - UserDefaults-backed, takes effect the
/// next time a phone connects (deviceInfo is recomputed per connection already), no extra
/// live-push plumbing needed.
@MainActor
final class CapabilityStore: ObservableObject {
    static let shared = CapabilityStore()

    private static let key = "wiqo.disabledCapabilities"
    @Published private(set) var disabled: Set<String>

    private init() {
        disabled = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    func isEnabled(_ capability: String) -> Bool {
        !disabled.contains(capability)
    }

    func setEnabled(_ enabled: Bool, for capability: String) {
        if enabled { disabled.remove(capability) } else { disabled.insert(capability) }
        UserDefaults.standard.set(Array(disabled), forKey: Self.key)
    }

    func isGroupFullyEnabled(_ group: CapabilityGroup) -> Bool {
        group.capabilities.allSatisfy(isEnabled)
    }

    func setGroupEnabled(_ enabled: Bool, for group: CapabilityGroup) {
        for capability in group.capabilities { setEnabled(enabled, for: capability) }
    }

    /// Filters a full capability list down to what's actually turned on - called once per
    /// connection when MacRuntime builds `deviceInfo`.
    func filter(_ capabilities: [String]) -> [String] {
        let supported = Set(RovaOperationManifest.advertisedCapabilities(for: .macOS))
        return Array(Set(capabilities.filter { supported.contains($0) && isEnabled($0) })).sorted()
    }
}

/// "Tam yetki": while on, the backend's PC agent may run multi-step tasks on this Mac without a
/// per-command phone signature or confirmation. Only the person at this Mac can turn it on; it
/// is off by default, shown in the menu bar while on, and one click turns it off again. The
/// capability switches above still apply to every agent command.
@MainActor
final class AgentAccessStore: ObservableObject {
    static let shared = AgentAccessStore()
    /// Registration feature the backend looks for (rova-backend src/agent/pcAgent.ts).
    static let feature = "agent.fullAccess"
    private static let key = "wiqo.agentFullAccess"

    @Published private(set) var isEnabled: Bool
    /// The agent step running right now, for the menu bar.
    @Published private(set) var currentStep: String?
    @Published private(set) var completedSteps = 0

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.key)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled { currentStep = nil }
        UserDefaults.standard.set(enabled, forKey: Self.key)
    }

    func stepStarted(_ label: String) { currentStep = label }

    func stepFinished() {
        currentStep = nil
        completedSteps += 1
    }
}

struct CapabilitiesSettingsView: View {
    @ObservedObject private var store = CapabilityStore.shared
    @ObservedObject private var agentAccess = AgentAccessStore.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { agentAccess.isEnabled }, set: { agentAccess.setEnabled($0) })) {
                    Label("Tam yetki (onaysız PC ajanı)", systemImage: "bolt.shield")
                }
                Text("Açıkken Wiqo çok adımlı işleri bu Mac'te telefon onayı beklemeden, adım adım yürütür. Aşağıda kapattığın yetenekler yine kullanılamaz. Menü çubuğundan tek tıkla kapatabilirsin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Kapatılan bir yetenek için Wiqo o aracı hiç görmez; en yakın telefon bağlantısından itibaren geçerli olur.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(RovaCapabilityCatalog.groups) { group in
                Section {
                    Toggle(isOn: Binding(
                        get: { store.isGroupFullyEnabled(group) },
                        set: { store.setGroupEnabled($0, for: group) }
                    )) {
                        Label(group.title, systemImage: group.icon)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
