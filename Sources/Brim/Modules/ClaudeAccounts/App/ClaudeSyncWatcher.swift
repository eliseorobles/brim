// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation
import os

/// Runs ClaudeSync while Brim runs, on events, never a timer (code rule 1):
///   - a session starting, or switching conversation with /resume: the
///     sessions/ events below show a new conversation running, and a run
///     checks it out of the other folders within a second (FSEvents' 0.3 s
///     latency), so their /resume cannot continue an old copy of it
///     (ClaudeSync's check-out, T-40);
///   - a session ending: one FSEvents stream covers every config folder's
///     sessions/ (Claude Code writes sessions/<pid>.json when a session
///     starts and rewrites it when /resume switches conversation), and each
///     running session's process has a kqueue exit source. A conversation
///     ends when its process exits, not when the file goes: Claude Code
///     removes the file early in its shutdown and writes the transcript's
///     last rows after (ClaudeSync.RunningSessions). Until then every run
///     counts it as running. The conversations whose process exited are
///     checked in and synced, so the next /resume on any account lists them
///     as they ended;
///   - memory files changing: the same stream (FileEventStream) covers
///     `<real projects>/<slug>/memory` for every repo folder, never a whole
///     projects/ tree, so transcript writes (the agent usage stream's job)
///     never reach this watcher. A kqueue source on each real projects/
///     folder (FolderEntriesWatch: on the config folder until projects/
///     exists) tells when a repo folder comes or goes, and its memory/ path
///     joins the stream. A memory saved on one account reaches the others
///     within a second; FSEvents' own 0.3 s latency coalesces a burst;
///   - events lost (MustScanSubDirs, a dropped batch) or a stream that had
///     to register again: a full run, since what changed meanwhile is
///     unknown. The stream runs without WatchRoot (its paths grow with every
///     repo folder, and WatchRoot costs a descriptor each, T-52): a memory/
///     or sessions/ folder made, renamed or removed reports an item event at
///     its own path, which routes like any event inside it;
///   - the folders changing (the app starts, an account comes or goes, a
///     migration gives a folder its own projects/): a full run, with its
///     counts and duration logged. Clones make it cheap.
/// Everything runs on the watcher's own serial queue, off the main thread.
final class ClaudeSyncWatcher {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brim", category: "claude-sync")

    private let queue = DispatchQueue(label: "brim.claude-accounts.sync", qos: .utility)
    private let statePath: String
    private let sharedSettings: String
    /// Conversations found continued on two accounts (reported once), on
    /// the watcher's queue.
    private let diverged: ([String]) -> Void
    /// The conversations held open (ClaudeSync.Report.open) whenever a run
    /// finds them changed, on the watcher's queue (the menu's note, T-50).
    private let held: ([String: ClaudeSync.Open]) -> Void

    // Confined to `queue`.
    private var configDirectories: [String] = []
    private var folders: [String] = []
    /// Repo folders in each real projects/, by folder.
    private var slugs: [String: [String]] = [:]
    private var projectWatches: [String: FolderEntriesWatch] = [:]
    /// No WatchRoot (`.claudeSync`): one descriptor per memory/ path did
    /// not fit under a Finder-launched app's limit of 256 (T-52).
    private lazy var stream = FileEventStream(
        name: "claude-sync", queue: queue, configuration: .claudeSync,
        handler: { [weak self] batch in self?.handle(batch) },
        resync: { [weak self] in self?.resyncAll(why: "file events were lost") })
    private var running = ClaudeSync.RunningSessions()
    private var exitSources: [Int32: DispatchSourceProcess] = [:]
    private var lastOpen: [String: ClaudeSync.Open] = [:]

    init(statePath: String, sharedSettings: String, diverged: @escaping ([String]) -> Void,
         held: @escaping ([String: ClaudeSync.Open]) -> Void) {
        self.statePath = statePath
        self.sharedSettings = sharedSettings
        self.diverged = diverged
        self.held = held
    }

    /// Watches these config folders; runs a full sync when the folders that
    /// take part changed or `full` asks for one.
    func update(configDirectories: [String], full: Bool = false) {
        queue.async { [self] in
            let configsChanged = configDirectories != self.configDirectories
            self.configDirectories = configDirectories
            let next = ClaudeSync.folders(configDirectories: configDirectories)
            let changed = next != folders
            folders = next
            // The kqueue sources keep the repo list current in between; the
            // stream itself starts again only when its paths changed.
            if changed || configsChanged || full || !stream.isRunning {
                watchFolders()
            } else {
                // A watch whose folder and parent were both missing looks again.
                let missing = projectWatches.values.filter { !$0.isArmed }
                for watch in missing { watch.start() }
                if missing.contains(where: \.watchingFolder) { projectsChanged() }
            }
            refreshRunning()
            if changed || full { reconcile(.all, why: full ? "requested" : "folders changed") }
        }
    }

    func stop() {
        queue.async { [self] in
            stream.stop()
            for watch in projectWatches.values { watch.cancel() }
            projectWatches = [:]
            slugs = [:]
            for source in exitSources.values { source.cancel() }
            exitSources = [:]
            running = ClaudeSync.RunningSessions()
            folders = []
            lastOpen = [:]
        }
    }

    /// On `queue`.
    /// `exited`: processes whose exit source fired, whose conversations are
    /// no longer open even while the pid is not yet reaped.
    /// With fewer than two folders ClaudeSync.reconcile only checks in what
    /// a check-out still holds (and returns at once when nothing is held).
    private func reconcile(_ scope: ClaudeSync.Scope, why: String, exited: Set<Int32> = []) {
        let started = Date()
        let options = ClaudeSync.Options(cleanupDays: ClaudeSync.cleanupDays(sharedSettings: ClaudeFileIO.read(sharedSettings)),
                                         running: running.ids, exited: exited)
        let report = ClaudeSync.reconcile(configDirectories: configDirectories, scope: scope, statePath: statePath, options: options)
        let seconds = Date().timeIntervalSince(started)
        if scope.everything || report.changed || !report.failures.isEmpty {
            Self.log.info("sync (\(why, privacy: .public)): \(report.conversations) conversation(s), \(report.copied.count) copied, \(report.trashed.count) to the Trash, \(report.running) running, \(report.checkedOut.count) checked out, \(report.checkedIn.count) checked in, \(report.failures.count) failed, \(seconds, format: .fixed(precision: 2)) s")
        }
        for line in report.kept + report.left + report.failures { Self.log.notice("sync: \(line, privacy: .private)") }
        if !report.diverged.isEmpty {
            Self.log.notice("sync: continued on two accounts, each keeps its own version: \(report.diverged.joined(separator: ", "), privacy: .public)")
            diverged(report.diverged)
        }
        // Every run reads every check-out (a scoped one too).
        if report.open != lastOpen {
            lastOpen = report.open
            held(report.open)
        }
    }

    // MARK: Sessions

    /// On `queue`: reads every running session, keeps an exit source on each
    /// process until it exits (`exited`: the one whose source fired), checks
    /// out a conversation that started running and checks in and syncs the
    /// conversations whose process exited.
    private func refreshRunning(exited: Set<Int32> = []) {
        var now: [Int32: String] = [:]
        for directory in configDirectories {
            for session in ClaudeSessionIndex.liveSessions(configDirectory: directory) { now[session.pid] = session.sessionId }
        }
        let before = running.ids
        let ended = running.update(live: now, exited: exited, isAlive: { ClaudeSessionIndex.processIsAlive($0, startedAt: nil) })
        let started = running.ids.subtracting(before)
        for (pid, source) in exitSources where running.byProcess[pid] == nil {
            source.cancel()
            exitSources[pid] = nil
        }
        for pid in running.byProcess.keys where exitSources[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in self?.refreshRunning(exited: [pid]) }
            source.resume()
            exitSources[pid] = source
            // A process that exited before its source was made never fires it.
            if !ClaudeSessionIndex.processIsAlive(pid, startedAt: nil) { queue.async { [weak self] in self?.refreshRunning(exited: [pid]) } }
        }
        // Every run checks out what runs now first, so one run covers both.
        if !ended.isEmpty || !exited.isEmpty {
            reconcile(ClaudeSync.Scope(sessions: ended), why: "a session ended", exited: exited)
        } else if !started.isEmpty {
            reconcile(ClaudeSync.Scope(), why: "a session started")
        }
    }

    // MARK: Stream

    /// On `queue`: lists each real projects/ folder, keeps a kqueue watch on
    /// each, and points the stream at the sessions/ and memory/ paths.
    private func watchFolders() {
        for (folder, watch) in projectWatches where !folders.contains(folder) {
            watch.cancel()
            projectWatches[folder] = nil
        }
        for folder in folders where projectWatches[folder] == nil {
            // Fires when a repo folder comes or goes, or projects/ itself
            // appears; transcript writes deeper down do not fire it.
            let watch = FolderEntriesWatch(path: folder + "/projects", queue: queue) { [weak self] in
                self?.projectsChanged()
            }
            projectWatches[folder] = watch
            watch.start()
        }
        slugs = ClaudeSync.projectSlugs(folders: folders)
        stream.watch(ClaudeSync.watchedPaths(configDirectories: configDirectories, folders: folders, slugs: slugs))
    }

    /// On `queue`: a repo folder came or went. Its memory/ joins the stream,
    /// and a new one's memory is brought to one state across the folders.
    private func projectsChanged() {
        let next = ClaudeSync.projectSlugs(folders: folders)
        guard next != slugs else { return }
        var added = Set<String>()
        for (folder, names) in next { added.formUnion(Set(names).subtracting(slugs[folder] ?? [])) }
        slugs = next
        stream.watch(ClaudeSync.watchedPaths(configDirectories: configDirectories, folders: folders, slugs: slugs))
        if !added.isEmpty { reconcile(ClaudeSync.Scope(memory: added), why: "new project folder") }
    }

    /// On `queue`: what changed meanwhile is unknown, so everything is read
    /// again, then the folders' real paths, in case one moved.
    private func resyncAll(why: String) {
        refreshRunning()
        reconcile(.all, why: why)
        folders = ClaudeSync.folders(configDirectories: configDirectories)
        watchFolders()
    }

    /// On `queue`.
    private func handle(_ batch: FileEventStream.Batch) {
        let sessionRoots = configDirectories.map { ClaudeFileIO.realPath($0) + "/sessions" }
        switch ClaudeSync.watchRoute(paths: batch.paths, rescan: batch.mustRescan || batch.rootChanged,
                                     sessionRoots: sessionRoots, folders: folders) {
        case .full:
            resyncAll(why: "file events were dropped")
        case .changes(let sessions, let memory):
            if sessions { refreshRunning() }
            if !memory.isEmpty { reconcile(ClaudeSync.Scope(memory: memory), why: "memory changed") }
        }
    }
}
