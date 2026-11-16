// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// Which window of an account a number belongs to.
enum ClaudeWindowKind: Hashable {
    case fiveHour
    case weekly
    /// A weekly window counting one model's use; the server's label.
    case scoped(String)

    var label: String {
        switch self {
        case .fiveHour: return "5h"
        case .weekly: return "weekly"
        case .scoped(let model): return model + " weekly"
        }
    }
}

/// One window as the ranking sees it at `now`.
struct ClaudeWindowState: Equatable {
    var kind: ClaudeWindowKind
    /// Percent used now: 0 once the window renewed after the reading.
    var utilization: Double
    /// When it renews next. After a weekly renewal Brim has not seen
    /// confirmed, the next one is estimated a week later; a 5-hour window
    /// that ran out has none (the next starts with the next request).
    var resetsAt: Date?
    /// The numbers are Brim's estimate (the window renewed since it was read).
    var estimated: Bool
    var observedAt: Date
    var source: ClaudeUsageSource
    /// The highest use at which the account still counts as usable.
    var limit: Double
    /// Whether the window counts for the model being run: the 5-hour and
    /// weekly windows always, a scoped one only for its model.
    var applies: Bool
    /// The server marks this scoped window as the one the account is
    /// measured against now (limits[].is_active). The panel shows such a
    /// window whatever the model hint; ranking still goes by `applies`.
    var serverActive = false

    var headroom: Double { max(0, 100 - utilization) }
    var blocks: Bool { applies && utilization >= limit }
}

enum ClaudeAccountStatus: Equatable {
    case usable
    /// Over a limit; usable again at `until` (nil when no reset time is known).
    case limited(until: Date?)
    /// No weekly reading yet.
    case unknown
    case signedOut

    var order: Int {
        switch self {
        case .usable: return 0
        case .limited: return 1
        case .unknown: return 2
        case .signedOut: return 3
        }
    }
}

struct ClaudeAccountRank: Equatable {
    /// The folder work on the account launches in (ClaudeAccountGroup.primary).
    var account: ClaudeAccount
    /// Every folder signed in to the account, `account` first: more than one
    /// when folders share a sign-in.
    var folders: [ClaudeAccount]
    var status: ClaudeAccountStatus
    var windows: [ClaudeWindowState]
    /// The applying window with the least headroom: what limits work on this
    /// account for the model being run.
    var binding: ClaudeWindowState?
    var weeklyResetsAt: Date?
    var fiveHourHeadroom: Double
    var newestObservation: Date?

    var bindingHeadroom: Double? { binding?.headroom }
    var isUsable: Bool { status == .usable }
    var sharesSignIn: Bool { folders.count > 1 }

    /// Whether `id` is one of the account's folders.
    func contains(_ id: String) -> Bool { folders.contains { $0.id == id } }
    /// Some applying window's numbers are estimated after a renewal.
    var estimated: Bool { windows.contains { $0.applies && $0.estimated } }
}

/// Orders accounts for new work. Pure: the app and the brim-claude helper
/// both rank with this file.
///
/// Folders that share a sign-in are one account (ClaudeAccountGroup): ranked
/// once, on their readings merged, under the folder launches use.
///
/// Usable means signed in, the 5-hour window under 95 %, the weekly window
/// under 98 % and, when the model being run is known, its scoped weekly
/// window under 98 %. Usable accounts come first, the soonest weekly renewal
/// first (use what would otherwise go unused), then the most 5-hour headroom;
/// then accounts over a limit, by when they become usable again; then
/// accounts with no reading; then signed-out ones.
enum ClaudeAccountRanking {
    static let fiveHourLimit: Double = 95
    static let weeklyLimit: Double = 98
    static let scopedLimit: Double = 98
    static let weekPeriod: TimeInterval = 7 * 86_400
    /// A reading older than this asks the app for a fresh get_usage check.
    static let freshness: TimeInterval = 15 * 60

    static func rank(_ accounts: [ClaudeAccount], readings: [String: ClaudeAccountReading],
                     model: String?, now: Date, launchable: (ClaudeAccount) -> Bool) -> [ClaudeAccountRank] {
        let assessed = ClaudeAccountsDiscovery.groups(accounts, launchable: launchable).enumerated().map { index, group in
            var rank = assess(group.primary, reading: reading(group.members, readings), model: model, now: now)
            rank.folders = group.members
            return (index, rank)
        }
        return assessed.sorted { left, right in
            let (a, b) = (left.1, right.1)
            if a.status.order != b.status.order { return a.status.order < b.status.order }
            switch (a.status, b.status) {
            case (.usable, .usable):
                if let order = ascending(a.weeklyResetsAt, b.weeklyResetsAt) { return order }
                if a.fiveHourHeadroom != b.fiveHourHeadroom { return a.fiveHourHeadroom > b.fiveHourHeadroom }
            case let (.limited(untilA), .limited(untilB)):
                if let order = ascending(untilA, untilB) { return order }
            default:
                break
            }
            return left.0 < right.0
        }.map(\.1)
    }

    /// nil when the two dates do not decide the order; a missing date sorts last.
    private static func ascending(_ a: Date?, _ b: Date?) -> Bool? {
        switch (a, b) {
        case let (a?, b?): return a == b ? nil : a < b
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return nil
        }
    }

    static func assess(_ account: ClaudeAccount, reading: ClaudeAccountReading?, model: String?,
                       now: Date) -> ClaudeAccountRank {
        var windows: [ClaudeWindowState] = []
        if let fiveHour = reading?.fiveHour {
            windows.append(state(.fiveHour, fiveHour, limit: fiveHourLimit, applies: true, now: now))
        }
        if let weekly = reading?.sevenDay {
            windows.append(state(.weekly, weekly, limit: weeklyLimit, applies: true, now: now))
        }
        for scoped in reading?.scoped ?? [] {
            var window = state(.scoped(scoped.model), scoped.window, limit: scopedLimit,
                               applies: scope(scoped.model, appliesTo: model), now: now)
            window.serverActive = scoped.active == true
            windows.append(window)
        }
        let applying = windows.filter(\.applies)
        let binding = applying.min { $0.headroom < $1.headroom }
        let weekly = windows.first { $0.kind == .weekly }
        // No 5-hour window means none is running: all of it is free.
        let fiveHourHeadroom = windows.first { $0.kind == .fiveHour }?.headroom ?? 100
        let status: ClaudeAccountStatus
        if account.signedIn == false {
            status = .signedOut
        } else if weekly == nil {
            status = .unknown
        } else {
            let blocking = applying.filter(\.blocks)
            if blocking.isEmpty {
                status = .usable
            } else {
                // Usable again once every blocking window renewed.
                let renewals = blocking.map(\.resetsAt)
                status = .limited(until: renewals.contains { $0 == nil } ? nil : renewals.compactMap { $0 }.max())
            }
        }
        return ClaudeAccountRank(account: account, folders: [account], status: status, windows: windows, binding: binding,
                                 weeklyResetsAt: weekly?.resetsAt, fiveHourHeadroom: fiveHourHeadroom,
                                 newestObservation: reading?.observedAt)
    }

    // MARK: Shared sign-ins

    /// One account's reading from all of its folders: per window, the newest
    /// observation wins (merge).
    static func reading(_ folders: [ClaudeAccount], _ readings: [String: ClaudeAccountReading]) -> ClaudeAccountReading? {
        merge(folders.map { readings[$0.id] })
    }

    /// A window as it stands at `now`: one whose renewal time passed counts
    /// as renewed at 0 %, estimated. A weekly window's next renewal is then
    /// estimated a week on; a 5-hour window gets none, because no 5-hour
    /// window runs until the account's next request starts one.
    static func state(_ kind: ClaudeWindowKind, _ window: ClaudeUsageWindow,
                      limit: Double, applies: Bool, now: Date) -> ClaudeWindowState {
        var utilization = window.utilization
        var resetsAt = window.resetsAt
        var estimated = false
        if let resets = window.resetsAt, resets <= now {
            if kind == .fiveHour {
                resetsAt = nil
            } else {
                let periods = (now.timeIntervalSince(resets) / weekPeriod).rounded(.down) + 1
                resetsAt = resets.addingTimeInterval(periods * weekPeriod)
            }
            utilization = 0
            estimated = true
        }
        return ClaudeWindowState(kind: kind, utilization: utilization, resetsAt: resetsAt, estimated: estimated,
                                 observedAt: window.observedAt, source: window.source, limit: limit, applies: applies)
    }

    /// Whether a scoped window (by its server label, as "Fable") counts for
    /// the model being run (an alias, an id or a display name, as "fable",
    /// "claude-fable-5" or "Fable 5"): every word of the label is a word of
    /// the model. Without a model nothing scoped applies.
    static func scope(_ displayName: String, appliesTo model: String?) -> Bool {
        guard let model else { return false }
        let label = words(displayName)
        return !label.isEmpty && label.isSubset(of: words(model))
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init))
    }

    // MARK: Merge

    /// One reading from several feeds of the same account: per window (5-hour,
    /// weekly, each scoped model) the newest observation wins and keeps its
    /// source. A feed that lacks a window says nothing about it, except a
    /// full report (scopedReportedAt): a scoped window observed before it
    /// that it does not list is gone, whichever feed holds that window and
    /// wherever it sits in the list. On equal times the later reading in the
    /// list wins.
    static func merge(_ readings: [ClaudeAccountReading?]) -> ClaudeAccountReading? {
        var merged = ClaudeAccountReading()
        func newer(_ current: ClaudeUsageWindow?, _ candidate: ClaudeUsageWindow?) -> ClaudeUsageWindow? {
            guard let candidate else { return current }
            guard let current else { return candidate }
            return candidate.observedAt >= current.observedAt ? candidate : current
        }
        var scoped: [String: ClaudeScopedWindow] = [:]
        var order: [String] = []
        var reports: [(at: Date, listed: Set<String>)] = []
        for reading in readings.compactMap({ $0 }) {
            merged.fiveHour = newer(merged.fiveHour, reading.fiveHour)
            merged.sevenDay = newer(merged.sevenDay, reading.sevenDay)
            if let reported = reading.scopedReportedAt {
                reports.append((reported, Set(reading.scoped.map { $0.model.lowercased() })))
                merged.scopedReportedAt = max(merged.scopedReportedAt ?? reported, reported)
            }
            for window in reading.scoped {
                let key = window.model.lowercased()
                if let current = scoped[key] {
                    if window.observedAt >= current.observedAt { scoped[key] = window }
                } else {
                    scoped[key] = window
                    if !order.contains(key) { order.append(key) }
                }
            }
        }
        // Only once every feed is in: a newer report later in the list must
        // not let an older window back in.
        merged.scoped = order.compactMap { key in
            guard let window = scoped[key],
                  !reports.contains(where: { $0.at > window.observedAt && !$0.listed.contains(key) }) else { return nil }
            return window
        }
        return merged.isEmpty ? nil : merged
    }

    /// accounts.json's reading for each account, merged with its live file.
    static func readings(_ file: ClaudeAccountsFile, live: [String: ClaudeLiveFile]) -> [String: ClaudeAccountReading] {
        var readings: [String: ClaudeAccountReading] = [:]
        for account in file.accounts {
            if let reading = merge([file.readings[account.id], live[account.id]?.reading]) {
                readings[account.id] = reading
            }
        }
        return readings
    }

    /// Whether the app should check the account again: no weekly reading,
    /// or one of the windows that decide where work goes is older than
    /// `freshness`. Those are the weekly window and every scoped window that
    /// applies to `model` or that the server marks active. A running
    /// session's status line keeps the weekly window new but never reports a
    /// scoped one, so the scoped windows are what age on a busy account.
    static func needsRefresh(_ reading: ClaudeAccountReading?, model: String?, now: Date) -> Bool {
        guard let reading, let weekly = reading.sevenDay else { return true }
        var oldest = weekly.observedAt
        for window in reading.scoped where window.active == true || scope(window.model, appliesTo: model) {
            oldest = min(oldest, window.observedAt)
        }
        return now.timeIntervalSince(oldest) > freshness
    }

    // MARK: Model

    /// The model new work will run: the one the caller names (`--model`), else
    /// the shared settings.json "model", else unknown.
    static func modelHint(explicit: String?, sharedSettings: Data?) -> String? {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        guard let sharedSettings, let json = ClaudeJSON.parse(sharedSettings) as? [String: Any] else { return nil }
        return ClaudeJSON.string(json["model"])
    }
}
