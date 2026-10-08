import SwiftUI

struct WiqoGoalsView: View {
    @State private var goals: [RovaBackendClient.RovaGoal] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error { Text(error).font(.footnote).foregroundStyle(WiqoTheme.red) }
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                } else if goals.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "target").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text("Henüz hedef yok").font(.headline)
                        Text("Sohbette bir hedef söylediğinde burada ilerlemesini görürsün.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    WiqoSettingsGroup {
                        ForEach(Array(goals.enumerated()), id: \.element.id) { index, goal in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(goal.title).font(.body).lineLimit(2)
                                    Spacer(minLength: 8)
                                    Text(goal.total == 0 ? "—" : "\(goal.done)/\(goal.total)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                ProgressView(value: Double(goal.done), total: Double(max(1, goal.total)))
                                    .tint(goal.total > 0 && goal.done >= goal.total ? WiqoTheme.green : Color.accentColor)
                            }
                            .padding(14)
                            .overlay(alignment: .bottom) { if index < goals.count - 1 { Rectangle().fill(WiqoTheme.line).frame(height: 0.5).padding(.leading, 14) } }
                        }
                    }
                }
            }
            .padding(.horizontal, RovaDesign.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(WiqoSettingsStyle.canvas)
        .navigationTitle("Hedefler")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = goals.isEmpty
        defer { isLoading = false }
        do { goals = try await RovaBackendClient.fetchGoals(); error = nil }
        catch { self.error = String(localized: "Hedefler yüklenemedi. Yeniden denemek için aşağı çek.") }
    }
}
