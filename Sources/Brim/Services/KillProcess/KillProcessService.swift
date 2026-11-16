// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Darwin
import Foundation

/// One row of the live process list: either a single process, or - when
/// grouping is on - a responsible app with every helper process it owns
/// folded into it (`groupedCount > 1`).
struct KillProcessEntry: Identifiable, Equatable {
    let pid: pid_t
    let ppid: pid_t
    let name: String
    let path: String
    let cpuPercent: Double
    let memoryBytes: Double
    let isRegularApp: Bool
    let bundleURL: URL?
    let groupedCount: Int
    let isProtected: Bool
    /// Kernel start time in microseconds. A PID alone is reusable and is not a
    /// safe identity for a destructive action confirmed from an old row.
    let startedAt: UInt64?
    /// False for another user's process: the kernel does not tell a caller
    /// that is not root its CPU or memory, so the row shows neither.
    var metricsReadable = true

    var id: pid_t { pid }
}

/// Lists every running process (from the shared process table, the same
/// source `ProcessUsageService` uses for the resource breakdown; memory is the
/// kernel footprint, never RSS) and kills, force-kills, restarts, or tears down
/// whole process trees. Backs the Kill Process settings page.
final class KillProcessService: ObservableObject {
    static let shared = KillProcessService()

    enum SortBy: String {
        case cpu, memory, name, pid
    }

    private enum DirectKillResult {
        case killed, alreadyGone, needsAdmin, failed, stale
    }

    private struct KillTarget {
        let pid: pid_t
        let startedAt: UInt64
    }

    private struct AdminKillTarget {
        let target: KillTarget
        let startDescription: String
    }

    @Published private(set) var entries: [KillProcessEntry] = []
    @Published var query: String = ""
    @Published private(set) var sortBy: SortBy
    @Published private(set) var sortAscending: Bool
    @Published private(set) var groupRelated: Bool
    @Published private(set) var isRefreshing = false
    /// True once a snapshot has completed successfully at least once, so
    /// the view can tell "still loading for the first time" apart from
    /// "search matched nothing" - both look like an empty `entries` array
    /// otherwise.
    @Published private(set) var hasLoadedOnce = false

    private let cacheLock = NSLock()
    private var lastRefresh: TimeInterval = 0
    private let cacheFreshSeconds: TimeInterval = 3

    private var restartObserver: NSObjectProtocol?
    private var pendingRestartPID: pid_t?
    private var pendingRestartURL: URL?

    private init() {
        sortBy = SortBy(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.killProcessSortBy) ?? "cpu") ?? .cpu
        sortAscending = UserDefaults.standard.bool(forKey: DefaultsKey.killProcessSortAscending)
        groupRelated = UserDefaults.standard.bool(forKey: DefaultsKey.killProcessGroupRelated)
    }

    var sortedEntries: [KillProcessEntry] {
        let ascending = sortAscending
        return entries.sorted { lhs, rhs in
            switch sortBy {
            case .cpu:
                return KillProcessSupport.numberComesBefore(lhs.cpuPercent, rhs.cpuPercent,
                                                            lhsPID: lhs.pid, rhsPID: rhs.pid,
                                                            ascending: ascending)
            case .memory:
                return KillProcessSupport.numberComesBefore(lhs.memoryBytes, rhs.memoryBytes,
                                                            lhsPID: lhs.pid, rhsPID: rhs.pid,
                                                            ascending: ascending)
            case .name:
                return KillProcessSupport.nameComesBefore(lhs.name, rhs.name,
                                                          lhsPID: lhs.pid, rhsPID: rhs.pid,
                                                          ascending: ascending)
            case .pid:
                return KillProcessSupport.numberComesBefore(Double(lhs.pid), Double(rhs.pid),
                                                            lhsPID: lhs.pid, rhsPID: rhs.pid,
                                                            ascending: ascending)
            }
        }
    }

    var filteredEntries: [KillProcessEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return sortedEntries }
        return sortedEntries.filter {
            $0.name.lowercased().contains(needle) || String($0.pid) == needle
        }
    }

    /// Column-header sorting: clicking the active column flips direction,
    /// clicking a different one switches to it at that column's natural
    /// default direction (highest-first for CPU/memory/PID, A-Z for name).
    func toggleSort(_ value: SortBy) {
        if sortBy == value {
            sortAscending.toggle()
        } else {
            sortBy = value
            sortAscending = value == .name
        }
        UserDefaults.standard.set(sortBy.rawValue, forKey: DefaultsKey.killProcessSortBy)
        UserDefaults.standard.set(sortAscending, forKey: DefaultsKey.killProcessSortAscending)
    }

    func setGroupRelated(_ value: Bool) {
        groupRelated = value
        UserDefaults.standard.set(value, forKey: DefaultsKey.killProcessGroupRelated)
        refresh(force: true)
    }

    /// Refreshes the process list off the main thread and republishes on the
    /// main thread. `force` bypasses the freshness cache, so a kill's
    /// reconciling refresh and an explicit tap of the refresh button always
    /// see the current state. `completion` always fires on the main thread,
    /// even when the cache was already fresh, so a caller that needs the
    /// current snapshot can sequence off it instead of guessing at a delay.
    func refresh(force: Bool = false, completion: (() -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refresh(force: force, completion: completion) }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        cacheLock.lock()
        let fresh = !force && now - lastRefresh < cacheFreshSeconds
        cacheLock.unlock()
        guard !fresh else {
            completion?()
            return
        }

        isRefreshing = true
        let grouped = groupRelated
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rows = Self.snapshot(grouped: grouped)
            DispatchQueue.main.async {
                guard let self else {
                    completion?()
                    return
                }
                // A failed or empty snapshot (transient - a hiccup) must
                // never wipe a list that was already showing good data; only
                // a genuine snapshot replaces it.
                if let rows {
                    self.entries = rows
                    self.hasLoadedOnce = true
                }
                self.isRefreshing = false
                self.cacheLock.lock()
                self.lastRefresh = ProcessInfo.processInfo.systemUptime
                self.cacheLock.unlock()
                completion?()
            }
        }
    }

    // MARK: - Kill

    func kill(_ entry: KillProcessEntry, force: Bool) {
        guard !entry.isProtected, let target = Self.target(for: entry) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let removed = self.killBatch([target], force: force, adminPromptProcessName: entry.name)
            self.finishKill(removed: removed)
        }
    }

    /// Kills a process identified by its pid, name, and kernel start time.
    /// This is the shared safe path for rows supplied by another feature.
    func kill(pid: pid_t,
              name: String,
              startedAt: UInt64,
              force: Bool,
              completion: (() -> Void)? = nil) {
        guard !Self.isProtected(pid: pid, name: name) else {
            completion?()
            return
        }
        let target = KillTarget(pid: pid, startedAt: startedAt)
        DispatchQueue.global(qos: .userInitiated).async {
            let removed = self.killBatch([target], force: force, adminPromptProcessName: name)
            self.finishKill(removed: removed, completion: completion)
        }
    }

    /// Kills every currently listed process sharing this exact name.
    func killAll(named name: String, force: Bool) {
        let targets = entries.filter { $0.name == name && !$0.isProtected }
            .compactMap(Self.target(for:))
        guard !targets.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let removed = self.killBatch(targets, force: force, adminPromptProcessName: name)
            self.finishKill(removed: removed)
        }
    }

    /// Kills a process together with every descendant, deepest first, so a
    /// parent never outlives children it might otherwise try to restart.
    func killTree(_ entry: KillProcessEntry, force: Bool) {
        guard !entry.isProtected, let root = Self.target(for: entry) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard Self.identityMatches(root) else { return }
            let descendants = Self.descendants(of: entry.pid)
                .filter { !Self.isProtected(pid: $0) }
                .compactMap(Self.currentTarget(pid:))
            let targets = Array(descendants.reversed()) + [root]
            let removed = self.killBatch(targets, force: force, adminPromptProcessName: entry.name)
            self.finishKill(removed: removed)
        }
    }

    /// Sends the direct-kill signal to every pid, then escalates every pid
    /// that came back EPERM through a single `AdminShell` prompt, so killing
    /// several processes owned by another user asks for the password once.
    private func killBatch(_ targets: [KillTarget],
                           force: Bool,
                           adminPromptProcessName: String) -> Set<pid_t> {
        var removed = Set<pid_t>()
        var needsAdmin: [AdminKillTarget] = []
        for target in targets {
            guard !Self.isProtected(pid: target.pid), Self.identityMatches(target) else { continue }
            switch Self.attemptDirectKill(target: target, force: force) {
            case .killed, .alreadyGone:
                removed.insert(target.pid)
            case .needsAdmin:
                if let description = Self.currentStartDescription(pid: target.pid),
                   Self.identityMatches(target) {
                    needsAdmin.append(AdminKillTarget(target: target,
                                                      startDescription: description))
                }
            case .failed, .stale:
                break
            }
        }
        guard !needsAdmin.isEmpty else { return removed }

        let signalFlag = force ? "-9" : "-15"
        let command = needsAdmin.map { candidate in
            let pid = candidate.target.pid
            return "if [ \"$(LC_ALL=C /bin/ps -p \(pid) -o lstart= | /usr/bin/xargs)\" = '\(candidate.startDescription)' ]; then /bin/kill \(signalFlag) \(pid); fi"
        }.joined(separator: "; ")
        let prompt = String(format: FeatureStrings.killProcess(L10n.shared.language).adminPromptFormat,
                            adminPromptProcessName)
        if AdminShell.runSync(command, prompt: prompt) {
            for candidate in needsAdmin where !Self.identityMatches(candidate.target) {
                removed.insert(candidate.target.pid)
            }
        }
        return removed
    }

    private static func attemptDirectKill(target: KillTarget, force: Bool) -> DirectKillResult {
        guard identityMatches(target) else { return .stale }
        let pid = target.pid
        if let running = NSRunningApplication(processIdentifier: pid),
           !running.isTerminated, running.activationPolicy == .regular {
            guard identityMatches(target) else { return .stale }
            return (force ? running.forceTerminate() : running.terminate()) ? .killed : .failed
        }
        let signal = force ? SIGKILL : SIGTERM
        guard identityMatches(target) else { return .stale }
        if Darwin.kill(pid, signal) == 0 { return .killed }
        switch errno {
        case EPERM: return .needsAdmin
        case ESRCH: return .alreadyGone
        default: return .failed
        }
    }

    /// Removes killed rows immediately so the list feels responsive, then
    /// reconciles with a real snapshot shortly after - long enough for
    /// the kernel to have reaped the process, short enough nobody notices
    /// the wait.
    private func finishKill(removed: Set<pid_t>, completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            if !removed.isEmpty {
                self.entries.removeAll { removed.contains($0.pid) }
            }
        }
        // One-shot reconcile after the kernel reaps the process; not a poll.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refresh(force: true)
            completion?()
        }
    }

    /// Every descendant of `pid`, walked in memory from one process-table
    /// read. The BFS used to run `pgrep -P` once per pid it had found, so
    /// tearing down a tree of a few hundred processes forked that many short
    /// lived helpers one after another - seconds of stalling while the list
    /// had already dropped the rows.
    ///
    /// A grandchild forked between this snapshot and the signal is missed;
    /// the per-pid `pgrep` walk raced the same way, and `killBatch` still
    /// re-checks every target's identity before it signals anything.
    private static func descendants(of pid: pid_t) -> [pid_t] {
        let parents = ProcessTable.snapshot().map { (pid: $0.pid, ppid: $0.ppid) }
        return KillProcessSupport.descendants(of: pid, parents: parents)
    }

    // MARK: - Restart

    func canRestart(_ entry: KillProcessEntry) -> Bool {
        !entry.isProtected && entry.bundleURL != nil && entry.startedAt != nil
    }

    /// Terminates the app, waits for the real termination notification (not
    /// a fixed delay), then relaunches it.
    func restart(_ entry: KillProcessEntry) {
        guard !entry.isProtected,
              let url = entry.bundleURL,
              let target = Self.target(for: entry) else { return }
        cancelPendingRestart()
        pendingRestartPID = entry.pid
        pendingRestartURL = url
        restartObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let terminated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  terminated.processIdentifier == self?.pendingRestartPID else { return }
            self?.completeRestart()
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.attemptDirectKill(target: target, force: false)
            switch result {
            case .failed, .needsAdmin, .stale:
                DispatchQueue.main.async { self?.cancelPendingRestart() }
            case .killed, .alreadyGone:
                break
            }
        }
        // One-shot: an app that never ends (a save sheet) stops waiting here.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard self?.pendingRestartPID == entry.pid else { return }
            self?.cancelPendingRestart()
        }
    }

    private func completeRestart() {
        guard let url = pendingRestartURL else {
            cancelPendingRestart()
            return
        }
        cancelPendingRestart()
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, _ in
            self?.refresh(force: true)
        }
    }

    private func cancelPendingRestart() {
        if let restartObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(restartObserver)
        }
        restartObserver = nil
        pendingRestartPID = nil
        pendingRestartURL = nil
    }

    // MARK: - Protected Processes

    static func isProtected(pid: pid_t, name: String = "", path: String = "") -> Bool {
        KillProcessSupport.isProtected(pid: pid, name: name, path: path)
    }

    static func startTime(for pid: pid_t) -> UInt64? {
        currentStartTime(pid: pid)
    }

    private static func target(for entry: KillProcessEntry) -> KillTarget? {
        guard let startedAt = entry.startedAt else { return nil }
        return KillTarget(pid: entry.pid, startedAt: startedAt)
    }

    private static func currentTarget(pid: pid_t) -> KillTarget? {
        currentStartTime(pid: pid).map { KillTarget(pid: pid, startedAt: $0) }
    }

    private static func identityMatches(_ target: KillTarget) -> Bool {
        currentStartTime(pid: target.pid) == target.startedAt
    }

    private static func currentStartTime(pid: pid_t) -> UInt64? {
        ProcessTable.startTime(pid: pid)
    }

    private static func currentStartDescription(pid: pid_t) -> String? {
        let result = Shell.run("/usr/bin/env", ["LC_ALL=C", "/bin/ps", "-p", String(pid),
                                                "-o", "lstart="])
        guard result.status == 0 else { return nil }
        return KillProcessSupport.normalizedStartDescription(result.output)
    }

    // MARK: - Brim Memory: whole process groups

    enum VerifiedSignal: Equatable {
        case sent, gone, stale, refused, failed
    }

    /// Brim's Memory module ends a process group through here: one plain
    /// signal per process, in the order given (deepest first), each sent only
    /// while the pid still has the kernel start time the caller saw, read
    /// again right before that signal. Its targets are the person's own
    /// processes, so an EPERM is reported and never raised to an admin
    /// prompt, and no app is asked to quit here.
    static func signalVerified(_ targets: [ProcessIdentity], force: Bool) -> [pid_t: VerifiedSignal] {
        var results: [pid_t: VerifiedSignal] = [:]
        let signal = force ? SIGKILL : SIGTERM
        for target in targets {
            guard !isProtected(pid: target.pid) else {
                results[target.pid] = .refused
                continue
            }
            guard identityMatches(KillTarget(pid: target.pid, startedAt: target.startedAt)) else {
                results[target.pid] = currentStartTime(pid: target.pid) == nil ? .gone : .stale
                continue
            }
            if Darwin.kill(target.pid, signal) == 0 {
                results[target.pid] = .sent
            } else {
                results[target.pid] = errno == ESRCH ? .gone : .failed
            }
        }
        return results
    }

    // MARK: - Snapshot

    /// CPU time per process at the previous snapshot, so a refresh shows the
    /// CPU used since the one before (what `ps` approximated with its own
    /// decaying average).
    private static let cpuBaselineLock = NSLock()
    private static var cpuBaseline: (uptime: TimeInterval, date: Date, times: [ProcessIdentity: TimeInterval])?

    /// Nil on a failed or clearly-wrong snapshot (zero rows - never
    /// legitimately true on a running Mac), so a transient hiccup can be told
    /// apart from an actually-empty list.
    private static func snapshot(grouped: Bool) -> [KillProcessEntry]? {
        var records = ProcessTable.snapshot()
        guard !records.isEmpty else { return nil }
        var uptime = ProcessInfo.processInfo.systemUptime
        cpuBaselineLock.lock()
        var baseline = cpuBaseline
        cpuBaselineLock.unlock()
        if baseline == nil || uptime - (baseline?.uptime ?? 0) > 30 {
            // No recent baseline (the first open, or after a long pause):
            // measure once over a quarter second on this background queue,
            // rather than show every row at 0 %. A single measurement
            // window, not a repeating timer.
            baseline = (uptime, Date(), Self.cpuTimes(records))
            Thread.sleep(forTimeInterval: 0.25)
            records = ProcessTable.snapshot()
            uptime = ProcessInfo.processInfo.systemUptime
            guard !records.isEmpty else { return nil }
        }
        cpuBaselineLock.lock()
        cpuBaseline = (uptime, Date(), Self.cpuTimes(records))
        cpuBaselineLock.unlock()
        guard let baseline else { return nil }
        let elapsed = max(0.05, uptime - baseline.uptime)
        let rows = records.map { record -> KillProcessEntry in
            // A process started since the baseline used all its CPU time in
            // the window; any other one missing from it shows no use.
            // A refused usage read shows as unreadable, never as 0 % or 0 B.
            let cpu = record.cpuTime.map { now in
                let before = baseline.times[record.identity] ?? (record.startDate > baseline.date ? 0 : now)
                return max(0, now - before) / elapsed * 100
            } ?? 0
            let path = record.path.isEmpty ? record.name : record.path
            let running = NSRunningApplication(processIdentifier: record.pid)
            // Another user's process has no readable start time, so, as
            // always, its row is shown protected and never offered a kill.
            return KillProcessEntry(
                pid: record.pid,
                ppid: record.ppid,
                name: ResponsibleProcess.displayName(pid: record.pid, fallback: record.executableName),
                path: path,
                cpuPercent: cpu,
                memoryBytes: Double(record.footprint ?? 0),
                isRegularApp: running?.activationPolicy == .regular,
                bundleURL: running?.bundleURL,
                groupedCount: 1,
                isProtected: record.restricted || isProtected(pid: record.pid, name: record.executableName, path: path),
                startedAt: record.restricted ? nil : record.startedAt,
                metricsReadable: !record.restricted && record.footprint != nil && record.cpuTime != nil)
        }
        return (grouped ? groupedByApp(rows) : rows).sorted { $0.cpuPercent > $1.cpuPercent }
    }

    private static func cpuTimes(_ records: [ProcessRecord]) -> [ProcessIdentity: TimeInterval] {
        Dictionary(records.compactMap { record in record.cpuTime.map { (record.identity, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Folds helper processes under the app responsible for them, summing
    /// their CPU/memory - the same grouping `ProcessUsageService` applies to
    /// the resource breakdown, reused here via `ResponsibleProcess`.
    private static func groupedByApp(_ rows: [KillProcessEntry]) -> [KillProcessEntry] {
        var byOwner: [pid_t: [KillProcessEntry]] = [:]
        for row in rows {
            byOwner[ResponsibleProcess.owner(of: row.pid), default: []].append(row)
        }
        return byOwner.compactMap { owner, members in
            guard let primary = members.first(where: { $0.pid == owner }) else { return nil }
            let running = NSRunningApplication(processIdentifier: owner)
            let isProt = isProtected(pid: owner, name: primary.name, path: primary.path)
                || primary.startedAt == nil
            return KillProcessEntry(
                pid: owner,
                ppid: primary.ppid,
                name: ResponsibleProcess.displayName(pid: owner, fallback: primary.name),
                path: primary.path,
                cpuPercent: members.reduce(0) { $0 + $1.cpuPercent },
                memoryBytes: members.reduce(0) { $0 + $1.memoryBytes },
                isRegularApp: running?.activationPolicy == .regular,
                bundleURL: running?.bundleURL,
                groupedCount: members.count,
                isProtected: isProt,
                startedAt: primary.startedAt,
                metricsReadable: members.allSatisfy(\.metricsReadable))
        }
    }
}
