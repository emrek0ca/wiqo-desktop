import Foundation

/// Pure retry rules for StoreKit product loading. Keeping the schedule separate from StoreKit
/// makes the bounded behavior easy to verify without contacting Apple's catalog.
enum StoreKitLoadTrigger: Equatable {
    case startup
    case paywall
    case foreground
    case manual
}

enum StoreKitLoadPolicy {
    static let startupDelays: [TimeInterval] = [0, 1, 3]
    static let foregroundRetryInterval: TimeInterval = 30

    static func delays(for trigger: StoreKitLoadTrigger) -> [TimeInterval] {
        switch trigger {
        case .startup: return startupDelays
        case .paywall, .foreground, .manual: return [0]
        }
    }

    static func shouldRetryOnForeground(lastFailure: Date?, now: Date) -> Bool {
        guard let lastFailure else { return false }
        return now.timeIntervalSince(lastFailure) >= foregroundRetryInterval
    }
}
