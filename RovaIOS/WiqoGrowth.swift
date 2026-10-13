import Foundation

/// The few levers of natural growth, and the rules that keep them honest. Nothing here nags: a store review is asked for only after real,
/// finished work, a handful of times at most (and Apple limits the prompt itself); sharing is always something the person starts, and what
/// travels with it is a plain link, never a mark on their picture.
enum WiqoGrowth {
    static let site = URL(string: "https://wiqoai.com")!

    private static let successesKey = "wiqo.growth.successes"
    private static let firstSeenKey = "wiqo.growth.firstSeen"
    private static let lastAskKey = "wiqo.growth.lastReviewAsk"
    private static let askedVersionKey = "wiqo.growth.reviewVersion"

    /// A task or a picture finished without a failure.
    static func recordSuccess(defaults: UserDefaults = .standard, now: Date = Date()) {
        if defaults.object(forKey: firstSeenKey) == nil { defaults.set(now, forKey: firstSeenKey) }
        defaults.set(defaults.integer(forKey: successesKey) + 1, forKey: successesKey)
    }

    /// Four finished tasks, two days of use, once per app version and at least ninety days apart: by then the person has seen what it does for them.
    static func reviewIsDue(version: String, defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        guard defaults.integer(forKey: successesKey) >= 4,
              let firstSeen = defaults.object(forKey: firstSeenKey) as? Date,
              now.timeIntervalSince(firstSeen) >= 2 * 86_400,
              defaults.string(forKey: askedVersionKey) != version else { return false }
        if let last = defaults.object(forKey: lastAskKey) as? Date, now.timeIntervalSince(last) < 90 * 86_400 { return false }
        return true
    }

    static func markReviewAsked(version: String, defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(now, forKey: lastAskKey)
        defaults.set(version, forKey: askedVersionKey)
    }

    /// Travels with a shared picture (the picture itself stays clean).
    static var imageShareMessage: String {
        String(localized: "Wiqo ile oluşturdum · \(site.absoluteString)")
    }

    /// The invite: the code, and where to get the app.
    static func inviteMessage(code: String) -> String {
        String(localized: "Wiqo'yu kullanıyorum: bilgisayarımı ve işlerimi telefondan yönetiyor, görsel ve belge üretiyor. Davet kodumla katılırsan ikimiz de Pro kazanıyoruz: \(code)\n\(site.absoluteString)")
    }
}
