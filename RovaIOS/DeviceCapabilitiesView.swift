import SwiftUI

/// A read-only, live status view of what Wiqo can actually do on the currently paired Mac right
/// now - as opposed to RovaMac's own "Yetenekler" screen (CapabilitySettings.swift), which is
/// where the *toggle* lives. This reads the same `DeviceCapabilityAuthority` list the Mac already
/// reports every connection (MacSystem.capabilityAuthorities()), so it's never a second,
/// hand-maintained catalog that can drift from what the model itself is actually gated on.
struct DeviceCapabilitiesView: View {
    let authorities: [DeviceCapabilityAuthority]

    private var sorted: [DeviceCapabilityAuthority] {
        authorities.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if authorities.isEmpty {
                    Text("PC'ye bağlanınca burada güncel yetenekler görünecek.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        Text("Bu liste, bağlı PC'nin bildirdiği yetenekleri gösterir. Başka bir PC'de farklı olabilir.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        ForEach(sorted) { authority in
                            row(for: authority)
                        }
                    }
                }
            }
            .navigationTitle("PC Yetenekleri")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(for authority: DeviceCapabilityAuthority) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: authority.access))
                .foregroundStyle(color(for: authority.access))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(authority.displayName).font(.subheadline)
                if let message = authority.message, !message.isEmpty {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(label(for: authority.access))
                .font(.caption.weight(.medium))
                .foregroundStyle(color(for: authority.access))
        }
    }

    private func icon(for access: CapabilityAuthorityAccess) -> String {
        switch access {
        case .automatic: return "checkmark.circle.fill"
        case .confirmation: return "checkmark.shield.fill"
        case .denied: return "hand.raised.slash.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for access: CapabilityAuthorityAccess) -> Color {
        switch access {
        case .automatic: return .green
        case .confirmation: return .orange
        case .denied: return .secondary
        case .unavailable: return .red
        }
    }

    private func label(for access: CapabilityAuthorityAccess) -> String {
        switch access {
        case .automatic: return "Hazır"
        case .confirmation: return "Onaylı"
        case .denied: return "Kapalı"
        case .unavailable: return "İzin gerekiyor"
        }
    }
}
