import SwiftUI

/// Wiqo's thinking timeline while a turn is in flight.
///
/// A plain chat turn is one shimmering line. A turn that uses tools, the PC or a plan grows into a
/// stack: finished lines settle with a check, the current one shimmers with its own clock, so the
/// user can see the work moving instead of a single static label. When nothing new has arrived for
/// a while the current line says so, so a long PC wait never looks frozen.
struct ThinkingTimelineView: View {
    let trace: ThinkingTrace
    var fallbackLabel = String(localized: "Bakıyorum…")

    /// Only this many finished lines stay visible above the current one; older ones fold into "+N".
    private static let visibleHistory = 4
    /// After this long without a new line, the current one admits it is still working.
    private static let quietThreshold: TimeInterval = 6

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                if trace.showsTimeline {
                    history
                }
                currentLine(now: context.date)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .wiqoAnimation(WiqoMotion.ease(0.3), value: trace.steps)
        .accessibilityElement(children: .combine)
    }

    private var finishedSteps: [ThinkingTrace.Step] {
        trace.steps.filter { $0.state != .running }
    }

    @ViewBuilder
    private var history: some View {
        let finished = finishedSteps
        let hidden = max(0, finished.count - Self.visibleHistory)
        if hidden > 0 {
            Text("+\(hidden) adım")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 24)
        }
        ForEach(finished.suffix(Self.visibleHistory)) { step in
            ThinkingStepRow(step: step)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func currentLine(now: Date) -> some View {
        let current = trace.current
        // Between the last line closing and the reply arriving, keep the last line instead of
        // flashing back to the generic fallback.
        let label = current?.label ?? trace.steps.last?.label ?? fallbackLabel
        let quiet = now.timeIntervalSince(trace.lastChangeAt) >= Self.quietThreshold
        let elapsed = now.timeIntervalSince(current?.startedAt ?? trace.startedAt)
        return HStack(alignment: .center, spacing: 8) {
            if trace.showsTimeline, let persona = trace.persona {
                // The sub-agent doing the work, moving in character while the turn runs.
                WiqoAgentMascot(persona, size: 44, isWorking: true)
            } else if trace.showsTimeline {
                ThinkingPulse()
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                WiqoStatusLine(text: label)
                    .font(.subheadline)
                if quiet {
                    Text("Hâlâ üzerinde çalışıyorum")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 8)
            // A clock only once it is worth reading; a two-second answer should not show one.
            if elapsed >= 3 {
                Text(ThinkingTrace.formatDuration(elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
            }
        }
        .wiqoAnimation(WiqoMotion.ease(0.3), value: quiet)
    }
}

/// The collapsed record of a finished turn above its reply: "4 adımda tamamlandı · 9 sn". Tapping
/// it unfolds every line Wiqo went through.
struct ThinkingSummaryView: View {
    let trace: ThinkingTrace
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(WiqoMotion.slide()) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    if let persona = trace.persona {
                        WiqoAgentMascot(persona, size: 29)
                    }
                    Text(trace.summary)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Adımları gizler" : "Adımları gösterir")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(trace.steps) { step in
                        ThinkingStepRow(step: step)
                    }
                }
                .padding(.leading, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ThinkingStepRow: View {
    let step: ThinkingTrace.Step

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: step.state == .failed ? "xmark" : Self.symbol(for: step.phase))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(step.state == .failed ? AnyShapeStyle(WiqoTheme.red) : AnyShapeStyle(.tertiary))
                .frame(width: 16)
            Text(step.settledLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let endedAt = step.endedAt, endedAt.timeIntervalSince(step.startedAt) >= 1 {
                Text(ThinkingTrace.formatDuration(endedAt.timeIntervalSince(step.startedAt)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    static func symbol(for phase: String) -> String {
        switch phase {
        case "understand": "sparkle"
        case "plan": "list.bullet"
        case "tool": "wrench.and.screwdriver"
        case "device": "desktopcomputer"
        case "verify": "checkmark.seal"
        case "compose": "text.alignleft"
        case "recover": "arrow.triangle.2.circlepath"
        case "resume": "play"
        default: "checkmark"
        }
    }
}

/// A small breathing dot next to the line that is still running.
private struct ThinkingPulse: View {
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 7, height: 7)
            .opacity(dimmed ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dimmed = true }
            }
            .accessibilityHidden(true)
    }
}
