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
            "device.system.power", "device.display", "device.audio", "device.media", "device.system.utility"
        ]),
        CapabilityGroup(id: "files", title: "Dosyalar", icon: "folder", capabilities: [
            "device.files.list", "device.files.read", "device.files.write", "device.files.move", "device.files.copy", "device.files.delete", "device.files.utility"
        ]),
        CapabilityGroup(id: "documents", title: "Belgeler", icon: "doc.text", capabilities: [
            "document.read", "document.edit", "artifact.save"
        ]),
        CapabilityGroup(id: "code", title: "Kod Çalıştırma", icon: "chevron.left.forwardslash.chevron.right", capabilities: [
            "device.code.execute"
        ]),
        CapabilityGroup(id: "analysis", title: "Yerel Analiz", icon: "waveform.path.ecg.rectangle", capabilities: [
            "local.analysis"
        ]),
        CapabilityGroup(id: "screen", title: "Ekran ve Arayüz", icon: "rectangle.on.rectangle", capabilities: [
            "device.screen.capture", "device.screen.click", "device.ui.control", "device.desktop.control"
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

    /// Registration feature: this Mac accepts a task grant from the phone.
    static let grantFeature = "agent.taskGrant"
    /// Registration feature while a task grant is running: the backend executes the chat's own steps here without the phone.
    static let taskActiveFeature = "agent.taskActive"

    /// What the phone approved for one task: where the agent may touch files, until when.
    struct TaskGrant: Equatable {
        let folders: [String]
        let expiresAt: Date
        let label: String
    }

    /// Only these may run under a task grant (the permanent switch above still allows everything).
    /// Files and documents; never a delete, never apps, terminal or the screen.
    private static let taskTypes: Set<CommandType> = [
        .ping, .getSystemStatus, .listDesktopFiles, .readDesktopFile, .listFiles, .searchFiles, .readFile,
        .sendFileToPhone, .moveFile, .copyFile, .convertFile, .runFilePlan, .writeFile, .readDocument
    ]

    @Published private(set) var isEnabled: Bool
    @Published private(set) var taskGrant: TaskGrant?
    private var expiry: Task<Void, Never>?
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

    /// The backend may run agent commands: the permanent switch, or a task grant that has not expired.
    var isActive: Bool { isEnabled || (taskGrant.map { $0.expiresAt > Date() } ?? false) }

    /// A signed phone approval: `minutes` of work in these folders; 0 withdraws it.
    func grant(minutes: Int, folders: [String], label: String) {
        expiry?.cancel()
        guard minutes > 0 else {
            taskGrant = nil
            currentStep = nil
            return
        }
        let grant = TaskGrant(folders: folders, expiresAt: Date().addingTimeInterval(Double(minutes) * 60), label: label)
        taskGrant = grant
        expiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { if self?.taskGrant == grant { self?.taskGrant = nil; self?.currentStep = nil } }
        }
    }

    func revokeTaskGrant() { grant(minutes: 0, folders: [], label: "") }

    /// Why an agent command may not run, or nil. With the permanent switch everything may; under a
    /// task grant only file work, and only inside the granted folders.
    func denial(for request: CommandRequest) -> String? {
        if isEnabled { return nil }
        guard let grant = taskGrant, grant.expiresAt > Date() else { return "PC görev izni bitti; telefondan yeniden onayla." }
        guard Self.taskTypes.contains(request.type) else { return "Bu işlem görev izninin kapsamında değil." }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func absolute(_ raw: String) -> String {
            let expanded = raw == "~" ? home : raw.hasPrefix("~/") ? home + String(raw.dropFirst(1)) : raw
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        let roots = grant.folders.map(absolute)
        func inside(_ raw: String) -> Bool {
            let path = absolute(raw)
            return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        let ownFolders = ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 }
        func searchScopeOK(_ folder: String?) -> Bool {
            folder.map(inside) ?? ownFolders.allSatisfy { own in roots.contains { own == $0 || own.hasPrefix($0 + "/") } }
        }
        switch request.payload {
        case .fileOperation(let operation):
            return inside(operation.path) && (operation.destination.map(inside) ?? true) ? nil : "Bu yol görev izninin klasörlerinin dışında."
        case .fileSearch(let search):
            return searchScopeOK(search.folder) ? nil : "Arama görev izninin klasörlerinin dışına çıkıyor; klasör belirt."
        case .fileName:
            return inside("~/Desktop") ? nil : "Masaüstü görev izninde değil."
        case .filePlan(let plan):
            let allowed = plan.steps.allSatisfy { step in
                (step.path.map { $0.hasPrefix("$") || inside($0) } ?? true)
                    && (step.destination.map(inside) ?? true)
                    && (step.op == "search" ? searchScopeOK(step.folder) : (step.folder.map(inside) ?? true))
            }
            return allowed ? nil : "Plan görev izninin klasörlerinin dışına çıkıyor."
        default:
            return nil
        }
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
                Text("Açıkken Wiqo istediğin uygulama, ekran, tarayıcı, dosya, belge ve terminal işlemlerini tekrar telefon onayı istemeden yürütür. Aşağıda kapattığın yetenekler ve macOS izinleri geçerlidir. Menü çubuğundan kapatabilir, telefondan görevi durdurabilirsin.")
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
