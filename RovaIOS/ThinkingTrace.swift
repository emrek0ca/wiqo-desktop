import Foundation

/// What Wiqo did while it worked on one message: the lines of its thinking timeline, oldest first.
///
/// Built from two sources that can arrive together. The backend's `activity` events carry an id,
/// a phase and an explicit close; plain `status` lines (older servers, and the phone's own
/// "bağlantı koptu" lines while it polls) only carry text. Both are folded in so the same line never
/// shows twice. Nothing is ever removed: unlike the reply text, a timeline line cannot be wrong.
struct ThinkingTrace: Codable, Hashable, Sendable {
    struct Step: Codable, Hashable, Identifiable, Sendable {
        enum State: String, Codable, Sendable {
            case running
            case done
            case failed
        }

        var id: String
        var phase: String
        var label: String
        var state: State
        var startedAt: Date
        var endedAt: Date?

        /// "Hava durumuna bakıyorum…" while running, "Hava durumuna bakıyorum" once it is behind us.
        var settledLabel: String {
            var text = label.trimmingCharacters(in: .whitespaces)
            while text.hasSuffix("…") || text.hasSuffix(".") { text.removeLast() }
            return text
        }
    }

    /// Phases that mean real work happened, as opposed to just reading and answering.
    private static let workPhases: Set<String> = ["plan", "tool", "device", "recover", "resume"]

    private(set) var steps: [Step] = []
    private(set) var startedAt: Date
    private(set) var endedAt: Date?
    /// When the timeline last moved. Drives the "hâlâ çalışıyorum" hint when it stays quiet.
    private(set) var lastChangeAt: Date
    /// The sub-agent at work (general / research / developer / execution) - drives the mascot.
    private(set) var persona: String?
    private var localCount = 0

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
        self.lastChangeAt = startedAt
    }

    var isFinished: Bool { endedAt != nil }
    var current: Step? { steps.last(where: { $0.state == .running }) }

    /// A plain chat turn stays a single shimmering line. Only a turn that actually used tools, the
    /// PC or a plan (or took several distinct steps) earns a visible timeline and a summary row.
    var showsTimeline: Bool {
        steps.contains { Self.workPhases.contains($0.phase) } || steps.count >= 3
    }

    func duration(now: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// A text-only status line. Ignored when it repeats the line already on screen.
    mutating func note(_ label: String, at date: Date = Date()) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !isFinished else { return }
        if steps.last?.label == label { return }
        closeRunning(as: .done, at: date)
        localCount += 1
        steps.append(Step(id: "local:\(localCount)", phase: "other", label: label, state: .running, startedAt: date))
        lastChangeAt = date
    }

    /// A backend `activity` event. Opens, adopts or closes a line by id.
    mutating func apply(id: String, phase: String, label: String, state: Step.State, persona: String? = nil, at date: Date = Date()) {
        if let persona, !isFinished { self.persona = persona }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !label.isEmpty else { return }
        if let index = steps.firstIndex(where: { $0.id == id }) {
            guard steps[index].state == .running, state != .running else { return }
            steps[index].state = state
            steps[index].endedAt = date
            lastChangeAt = date
            return
        }
        guard !isFinished else { return }
        // The server sends `status` and `activity` for the same moment; whichever lands first opens
        // the line and the other one just gives it its real id and phase.
        if let index = steps.indices.last, steps[index].id.hasPrefix("local:"), steps[index].label == label {
            steps[index].id = id
            steps[index].phase = phase
            if state != .running, steps[index].state == .running {
                steps[index].state = state
                steps[index].endedAt = date
            }
            lastChangeAt = date
            return
        }
        if state == .running { closeRunning(as: .done, at: date) }
        steps.append(Step(id: id, phase: phase, label: label, state: state, startedAt: date, endedAt: state == .running ? nil : date))
        lastChangeAt = date
    }

    /// The turn is over: whatever is still running is closed, and the clock stops.
    mutating func finish(failed: Bool = false, at date: Date = Date()) {
        guard !isFinished else { return }
        closeRunning(as: failed ? .failed : .done, at: date)
        endedAt = date
        lastChangeAt = date
    }

    /// A device follow-up turn continues the same timeline instead of starting a new one.
    mutating func reopen(at date: Date = Date()) {
        endedAt = nil
        lastChangeAt = date
    }

    private mutating func closeRunning(as state: Step.State, at date: Date) {
        for index in steps.indices where steps[index].state == .running {
            steps[index].state = state
            steps[index].endedAt = date
        }
    }
}

extension ThinkingTrace {
    /// "9 sn", "1 dk 12 sn".
    static func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = max(1, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds) sn" }
        let minutes = seconds / 60
        let rest = seconds % 60
        return rest == 0 ? "\(minutes) dk" : "\(minutes) dk \(rest) sn"
    }

    /// The collapsed row under a finished turn, e.g. "4 adımda tamamlandı · 9 sn".
    var summary: String {
        let duration = Self.formatDuration(self.duration())
        if steps.contains(where: { $0.state == .failed }) {
            return "\(steps.count) adım · \(duration) · bir adım tamamlanamadı"
        }
        return "\(steps.count) adımda tamamlandı · \(duration)"
    }
}
