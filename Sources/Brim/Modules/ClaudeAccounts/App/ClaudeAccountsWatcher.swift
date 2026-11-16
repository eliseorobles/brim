// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// The feeds behind ClaudeAccountsService, off the main thread and without a
/// timer: one FileEventStream over exact paths (each folder's .claude.json,
/// each account's sessions folder, Brim's live/ and requests/ folders and the
/// shared settings.json) and a kqueue watch on the home folder's own entries,
/// which tells when a ~/.claude-<name> folder comes or goes. What an event
/// names is read here and handed over as one change.
///
/// .claude.json is rewritten for unrelated keys all the time, so its events
/// are frequent; the service acts only when cachedUsageUtilization's
/// fetchedAtMs grows (ClaudeUsageDecoding.isNewer), never on the write itself.
/// Its roots are those exact files, so the stream runs without WatchRoot:
/// with it every replace of .claude.json would read as a root change. When
/// events were lost, or the stream had to register again, everything the
/// plan names is read again (`fullLook`).
final class ClaudeAccountsWatcher {
    /// What to watch, set by the main thread.
    struct Plan: Equatable {
        var home: String
        var paths: ClaudeAccountsPaths
        /// Every folder whose .claude.json is watched: accounts and
        /// ~/.claude-<name> candidates ("" is the default account).
        var folders: [String]
        /// Account folders whose running sessions are counted.
        var accountFolders: [String]

        var sharedSettings: String { home + "/.claude/settings.json" }

        func sessionsDirectory(_ folder: String) -> String {
            ClaudeSessionIndex.configDirectory(forFolder: folder, home: home) + "/sessions"
        }

        var watchedPaths: [String] {
            var list = folders.map { ClaudeUsageDecoding.configFile(forFolder: $0, home: home) }
            list += accountFolders.map(sessionsDirectory)
            list += [paths.liveDirectory, paths.requestsDirectory, sharedSettings]
            var seen = Set<String>()
            return list.filter { seen.insert($0).inserted }
        }
    }

    /// What one batch of events found. Empty fields were not touched.
    struct Change {
        /// .claude.json states, by folder.
        var states: [String: ClaudeFolderState] = [:]
        /// Running sessions, by account folder.
        var sessions: [String: Int] = [:]
        /// Every live file, when live/ changed.
        var live: [String: ClaudeLiveFile]?
        /// Account ids a brim-claude run asked to check.
        var requests: [String] = []
        /// The shared settings.json, when it changed (nil inside: gone).
        var settings: Data??
        /// A full look at the disk, when a ~/.claude-<name> folder came or went
        /// or the service asked for one.
        var scan: (discovered: [String], states: [String: ClaudeFolderState])?

        var isEmpty: Bool {
            states.isEmpty && sessions.isEmpty && live == nil && requests.isEmpty && settings == nil && scan == nil
        }
    }

    private let queue = DispatchQueue(label: "brim.claude-accounts.watch", qos: .utility)
    /// Called on the watcher's queue.
    private let deliver: (Change) -> Void
    private let isAlive: ClaudeProcessProbe

    // Confined to `queue`.
    private var plan: Plan?
    private lazy var stream = FileEventStream(
        name: "claude-accounts", queue: queue, configuration: .init(latency: 1.5, watchRoot: false),
        handler: { [weak self] batch in
            if batch.mustRescan { self?.fullLook(files: true) } else { self?.handle(batch.paths) }
        },
        resync: { [weak self] in self?.fullLook(files: true) })
    private var homeSource: DispatchSourceFileSystemObject?
    private var candidates: [String] = []

    init(isAlive: @escaping ClaudeProcessProbe = ClaudeSessionIndex.processIsAlive, deliver: @escaping (Change) -> Void) {
        self.isAlive = isAlive
        self.deliver = deliver
    }

    /// Watches what `plan` names; a stream whose paths did not change keeps
    /// running.
    func update(_ plan: Plan) {
        queue.async { [self] in
            let first = self.plan == nil
            self.plan = plan
            if first {
                candidates = ClaudeAccountsDiscovery.candidateFolders(home: plan.home)
                watchHome(plan.home)
            }
            // A stream whose paths did not change keeps running.
            stream.watch(plan.watchedPaths)
        }
    }

    /// Reads again what events may have missed, on an explicit foreground
    /// event (the panel or a page appearing, wake): running sessions, whose
    /// process can end without touching its file, and the account folders.
    func lookAgain() {
        queue.async { [self] in fullLook(files: false) }
    }

    /// On `queue`: running sessions, the account folders and the live files;
    /// with `files` (events were lost) also every folder's .claude.json, the
    /// refresh requests and the shared settings, which only events report.
    private func fullLook(files: Bool) {
        guard let plan else { return }
        var change = Change()
        for folder in plan.accountFolders {
            change.sessions[folder] = ClaudeSessionIndex.liveSessions(configDirectory: ClaudeSessionIndex.configDirectory(
                forFolder: folder, home: plan.home), isAlive: isAlive).count
        }
        candidates = ClaudeAccountsDiscovery.candidateFolders(home: plan.home)
        change.scan = ClaudeAccountsDiscovery.scan(home: plan.home, listed: plan.accountFolders)
        change.live = ClaudeLiveFile.loadAll(plan.paths)
        if files {
            for folder in plan.folders { change.states[folder] = ClaudeAccountsDiscovery.state(folder: folder, home: plan.home) }
            change.requests = ClaudeRefreshRequests.consume(plan.paths)
            change.settings = .some(ClaudeFileIO.read(plan.sharedSettings, limit: 4 << 20))
        }
        deliver(change)
    }

    func stop() {
        queue.async { [self] in
            stream.stop()
            homeSource?.cancel()
            homeSource = nil
            plan = nil
        }
    }

    // MARK: Events

    /// On `queue`.
    private func handle(_ eventPaths: [String]) {
        guard let plan else { return }
        var change = Change()
        let configs = Dictionary(plan.folders.map { (ClaudeUsageDecoding.configFile(forFolder: $0, home: plan.home), $0) },
                                 uniquingKeysWith: { first, _ in first })
        let sessions = plan.accountFolders.map { (plan.sessionsDirectory($0), $0) }
        var liveTouched = false
        var requestsTouched = false
        func inside(_ path: String, _ directory: String) -> Bool { path == directory || path.hasPrefix(directory + "/") }
        for path in Set(eventPaths) {
            if let folder = configs[path] {
                if change.states[folder] == nil {
                    change.states[folder] = ClaudeAccountsDiscovery.state(folder: folder, home: plan.home)
                }
            } else if let match = sessions.first(where: { inside(path, $0.0) }) {
                if change.sessions[match.1] == nil {
                    change.sessions[match.1] = ClaudeSessionIndex.liveSessions(
                        configDirectory: (match.0 as NSString).deletingLastPathComponent, isAlive: isAlive).count
                }
            } else if inside(path, plan.paths.liveDirectory) {
                liveTouched = true
            } else if inside(path, plan.paths.requestsDirectory) {
                requestsTouched = true
            } else if path == plan.sharedSettings {
                change.settings = .some(ClaudeFileIO.read(plan.sharedSettings, limit: 4 << 20))
            }
        }
        if liveTouched { change.live = ClaudeLiveFile.loadAll(plan.paths) }
        if requestsTouched { change.requests = ClaudeRefreshRequests.consume(plan.paths) }
        if !change.isEmpty { deliver(change) }
    }

    // MARK: Home folder

    /// A directory's kqueue source fires when an entry in it is added,
    /// removed or renamed: here, when a ~/.claude-<name> folder comes or goes
    /// (and when ~/.claude.json is replaced, which costs one listing).
    private func watchHome(_ home: String) {
        let descriptor = open(home, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                                                               queue: queue)
        source.setEventHandler { [weak self] in self?.homeChanged() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        homeSource = source
    }

    private func homeChanged() {
        guard let plan else { return }
        let current = ClaudeAccountsDiscovery.candidateFolders(home: plan.home)
        guard current != candidates else { return }
        candidates = current
        var change = Change()
        change.scan = ClaudeAccountsDiscovery.scan(home: plan.home, listed: plan.accountFolders)
        deliver(change)
    }
}
