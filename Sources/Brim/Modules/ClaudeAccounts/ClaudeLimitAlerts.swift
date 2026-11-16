// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// A window of an account with running sessions that reached its alert
/// level.
struct ClaudeLimitCrossing: Equatable {
    var accountID: String
    var label: String
    var kind: ClaudeWindowKind
    var utilization: Double
    var resetsAt: Date?
    /// One window until it renews: the account, the window and its renewal.
    var key: String
}

/// The notices the app gives while sessions run on an account that nears a
/// limit: its 5-hour window at 90 %, its weekly window or a scoped weekly
/// window that applies to the model at 95 %. One notice per window until it
/// renews. Pure: the service remembers the keys it notified.
enum ClaudeLimitAlerts {
    static let fiveHourLevel: Double = 90
    static let weeklyLevel: Double = 95

    static func level(_ kind: ClaudeWindowKind) -> Double {
        kind == .fiveHour ? fiveHourLevel : weeklyLevel
    }

    static func key(accountID: String, kind: ClaudeWindowKind, resetsAt: Date?) -> String {
        let renewal = resetsAt.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "-"
        return accountID + "|" + kind.label + "|" + renewal
    }

    /// Every applying window at or over its level, for the accounts given.
    static func over(_ ranks: [ClaudeAccountRank], accounts ids: Set<String>? = nil) -> [ClaudeLimitCrossing] {
        ranks.filter { ids?.contains($0.account.id) ?? true }.flatMap { rank in
            rank.windows.filter { $0.applies && $0.utilization >= level($0.kind) }.map { window in
                ClaudeLimitCrossing(accountID: rank.account.id, label: rank.account.label, kind: window.kind,
                                    utilization: window.utilization, resetsAt: window.resetsAt,
                                    key: key(accountID: rank.account.id, kind: window.kind, resetsAt: window.resetsAt))
            }
        }
    }

    /// What to notify now, and the keys to remember. Only accounts with a
    /// running session, in any of their folders, are notified. A key is
    /// remembered while its window stays over its level, so a renewal (a new
    /// key) can notify again.
    static func news(_ ranks: [ClaudeAccountRank], liveSessions: [String: Int],
                     notified: Set<String>) -> (news: [ClaudeLimitCrossing], remembered: Set<String>) {
        let all = over(ranks)
        let stillOver = Set(all.map(\.key))
        let live = Set(ranks.filter { rank in rank.folders.contains { (liveSessions[$0.id] ?? 0) > 0 } }.map(\.account.id))
        let news = all.filter { live.contains($0.accountID) && !notified.contains($0.key) }
        return (news, notified.intersection(stillOver).union(news.map(\.key)))
    }

    /// The account to move work to: the best-ranked usable one other than
    /// `accountID`.
    static func target(for accountID: String, in ranks: [ClaudeAccountRank]) -> ClaudeAccountRank? {
        ranks.first { $0.account.id != accountID && $0.isUsable }
    }
}
