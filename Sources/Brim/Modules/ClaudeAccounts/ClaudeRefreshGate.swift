// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// When the app starts Claude Code for a get_usage check. Each check is a
/// whole Claude Code process, so it runs only on an event (the menu panel or
/// the AI page appearing, Refresh, wake from sleep, a brim-claude request, a
/// sign-in finishing), only for an account with a deciding window older than
/// 15 minutes (ClaudeAccountRanking.needsRefresh; Refresh and a sign-in skip
/// that), one at a time for the
/// whole app, and after a failure not again until a backoff passed: 1 minute,
/// doubling to 30. The backoff is looked at on the next event; nothing here
/// schedules a retry.
///
/// Pure: the service keeps one, asks it on every event and tells it what
/// happened.
struct ClaudeRefreshGate: Equatable {
    static let firstBackoff: TimeInterval = 60
    static let maximumBackoff: TimeInterval = 30 * 60

    struct Failure: Equatable {
        var count: Int
        var at: Date
    }

    /// Failures in a row per account id, cleared by an answer.
    private(set) var failures: [String: Failure] = [:]
    /// The account being checked now.
    private(set) var running: String?
    /// Accounts waiting their turn, in order.
    private(set) var waiting: [String] = []

    /// 0 before any failure, then 1, 2, 4, … minutes up to 30.
    static func backoff(afterFailures count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        return min(maximumBackoff, firstBackoff * Double(1 << min(count - 1, 10)))
    }

    func isChecking(_ id: String) -> Bool { running == id || waiting.contains(id) }

    /// Whether an event should queue a check of the account. Never twice at
    /// once. `force` (Refresh, a finished sign-in) skips the freshness and
    /// the backoff; any other event needs a stale reading (for `model`, the
    /// model new sessions run) and a passed backoff.
    func wants(_ id: String, reading: ClaudeAccountReading?, model: String?, now: Date, force: Bool) -> Bool {
        if isChecking(id) { return false }
        if force { return true }
        guard ClaudeAccountRanking.needsRefresh(reading, model: model, now: now) else { return false }
        if let failure = failures[id], now.timeIntervalSince(failure.at) < Self.backoff(afterFailures: failure.count) {
            return false
        }
        return true
    }

    /// Queues the check when the event calls for one; returns whether it did.
    @discardableResult
    mutating func request(_ id: String, reading: ClaudeAccountReading?, model: String?, now: Date, force: Bool) -> Bool {
        guard wants(id, reading: reading, model: model, now: now, force: force) else { return false }
        waiting.append(id)
        return true
    }

    /// The next check to start, when none is running.
    mutating func next() -> String? {
        guard running == nil, !waiting.isEmpty else { return nil }
        running = waiting.removeFirst()
        return running
    }

    /// The running check ended: an answer clears the account's failures, a
    /// failure counts one more.
    mutating func finished(_ id: String, succeeded: Bool, at now: Date) {
        if running == id { running = nil }
        if succeeded {
            failures[id] = nil
        } else {
            failures[id] = Failure(count: (failures[id]?.count ?? 0) + 1, at: now)
        }
    }

    /// The running check was stopped without an answer (the feature turned
    /// off): it counts as neither.
    mutating func cancelled() {
        running = nil
        waiting.removeAll()
    }

    /// Drops what belongs to accounts no longer listed.
    mutating func keep(only ids: Set<String>) {
        failures = failures.filter { ids.contains($0.key) }
        waiting.removeAll { !ids.contains($0) }
    }
}

/// requests/<ms>-<account id>: a brim-claude run asking the app for a fresh
/// check (pick and move write one when an account's reading is stale).
enum ClaudeRefreshRequests {
    /// The account ids asked for, oldest first, each once. Every request file
    /// is deleted once read; files whose name starts with "." are another
    /// writer's temporary files and are left alone.
    static func consume(_ paths: ClaudeAccountsPaths) -> [String] {
        let directory = paths.requestsDirectory
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
        var ids: [String] = []
        for name in names where !name.hasPrefix(".") {
            let path = directory + "/" + name
            guard ClaudeFileIO.isRegularFile(path) else { continue }
            var id = ClaudeFileIO.read(path, limit: 64 << 10)
                .flatMap { ClaudeJSON.parse($0) as? [String: Any] }
                .flatMap { ClaudeJSON.string($0["account"]) }
            if id == nil, let dash = name.firstIndex(of: "-") {
                id = String(name[name.index(after: dash)...])
            }
            unlink(path)
            if let id, !id.isEmpty, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }
}
