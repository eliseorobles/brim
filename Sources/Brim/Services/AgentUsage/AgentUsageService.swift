// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation
import Network

/// Reads Claude Code, Codex and GitHub Copilot usage from local session logs, and
/// OpenCode usage from its database, while the AI section is on. The files
/// are read where they are,
/// incrementally, and nothing is copied or sent: only counters are kept, in
/// memory and in the app's private folder so the next launch reads only what
/// the agents wrote meanwhile. OpenCode's stay in memory only, and its
/// database is read again at each launch. Claude's plan limits come from
/// Brim's ClaudeAccountsService, which follows every Claude account. Costs
/// come from the price list inside the app.
///
/// Reading happens on a private queue; the main thread and that queue hand
/// work to each other asynchronously, except that a stop waits for progress
/// to be saved. The queue never waits for the main thread.
final class AgentUsageService: ObservableObject {
    static let shared = AgentUsageService()

    @Published private(set) var snapshot = AgentUsageSnapshot()
    let events = PassthroughSubject<AgentUsageEvent, Never>()

    /// The history the island can show: thirteen weeks for the activity map.
    static let horizon = TimeInterval(AgentUsageSnapshot.dayCount) * 86_400
    private static let tick: TimeInterval = 30
    /// File events report a written file only once it closes, and some
    /// agents keep their log open for the whole session: logs written in the
    /// last half hour, or holding a turn, are checked this often instead.
    private static let poll: TimeInterval = 2
    private static let pollWindow: TimeInterval = 30 * 60
    /// Coalesce a live log's bursts into one history and display update.
    private static let publishDelay: TimeInterval = 1
    /// How often progress is saved while agents write, besides on quit and
    /// pause; a launch after a crash reads again only what came after.
    private static let saveInterval: TimeInterval = 5 * 60

    private let queue = DispatchQueue(label: "com.roblesconsulting.brim.agent-usage", qos: .utility, autoreleaseFrequency: .workItem)
    private let home = FileManager.default.homeDirectoryForCurrentUser

    /// Lets a stop end a first read that is still going on the queue.
    private final class Cancellation {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    // Main thread.
    private var running = false
    /// Reading waits while the island is away; what was read stays.
    private var paused = false
    private var session = 0
    private var cancellation = Cancellation()
    private var timer: Timer?
    private var providers: [AgentProvider] = []
    /// Every Claude account's config folder ("" is the default
    /// account), whose logs are read.
    private var claudeFolders: [String] = [""]
    /// The Claude limits and plan ClaudeAccountsService last gave,
    /// applied again when reading starts over.
    private var claudeAccount: (limits: AgentLimits?, plan: AgentPlan?) = (nil, nil)

    // Confined to `queue`.
    private var readerSession = -1
    private var readerCancellation: Cancellation?
    private var enabled: Set<AgentProvider> = []
    private var store = AgentUsageStore()
    private var cursors: [String: AgentLogCursor] = [:]
    /// The one copy read of each Claude conversation that several account
    /// folders hold (AgentLogRoot.claudeCopyKey -> path).
    private var claudeCopies: [String: String] = [:]
    private var claudeRoots: [AgentLogRoot] = []
    /// File-level changes in the log folders, on `queue`: the only stream
    /// over Claude's projects/ transcripts. The system coalesces bursts, so a
    /// busy agent costs one callback a second at most.
    private var watcher: FileEventStream?
    private var watchedRoots: [AgentLogRoot] = []
    private var poller: DispatchSourceTimer?
    private var polling = false
    private var network: NWPathMonitor?
    /// When the Mac lost its network, and the uptime then, which leaves out
    /// sleep; nil while it has one.
    private var offlineSince: (date: Date, uptime: TimeInterval)?
    private var publishScheduled = false
    /// The last snapshot handed over, to tell when time alone changes it.
    private var published = AgentUsageSnapshot()
    private var claudePlan: AgentPlan?
    private var readerClaudeFolders: [String] = [""]
    private var shippedPrices: AgentPriceList?
    private var previousLimits: [AgentProvider: AgentLimits] = [:]
    /// Warned windows, each waiting for its renewal.
    private var warned: [String: (provider: AgentProvider, window: AgentLimitWindow)] = [:]
    private var budgetDay: Date?
    private var lastRootCheck = Date.distantPast
    /// Tells whether reading moved on since progress was last saved.
    /// Nil until this reading saved or resumed progress: the first save
    /// always replaces what is on disk, which may hold agents now off.
    private var savedMark: Int?
    private var lastSave = Date.distantPast

    private init() {}

    func syncWithPreferences() {
        CodexProfileLimitsService.shared.synchronize()
        guard NotchAgentSupport.isEnabled() else { stop(); return }
        let wanted = NotchAgentSupport.providers()
        let folders = ClaudeAccountsService.logFolders()
        // An agent turned off is no longer read at all, and one turned on is
        // read from its start: both take a fresh reading, which would not
        // resume progress saved for the old set, so it goes at once. Codex
        // accounts keep their checks: they read no log.
        if running, wanted != providers || folders != claudeFolders {
            stop(keepingProgress: false, pausingAccounts: false)
        }
        claudeFolders = folders
        if !running {
            running = true
            session += 1
            cancellation = Cancellation()
            providers = wanted
            start(session: session, providers: Set(wanted), cancellation: cancellation, claudeFolders: folders)
            setClaude(limits: claudeAccount.limits, plan: claudeAccount.plan)
        } else if paused {
            resume()
        }
    }

    /// Stops reading while the island is away, as with the display asleep or
    /// the Mac locked, and keeps what was read: reading every log again on the
    /// way back costs far more than the pause saves.
    func pause() {
        CodexProfileLimitsService.shared.pause()
        guard running, !paused else { return }
        paused = true
        timer?.invalidate()
        timer = nil
        queue.async { [self] in
            poller?.cancel()
            poller = nil
            watcher?.stop()
            saveProgress()
        }
    }

    /// Reads what the agents wrote meanwhile, from where each log stopped.
    private func resume() {
        paused = false
        startTimer()
        queue.async { [self] in
            guard readerSession >= 0 else { return }
            watch(AgentLogRoot.all(home: home, claudeFolders: readerClaudeFolders).filter { enabled.contains($0.provider) })
            filesChanged([], rescan: true)
            startPolling()
            // Time went by meanwhile: a window or the day may have moved on.
            schedulePublish()
        }
    }

    func stop(keepingProgress keeps: Bool = true, pausingAccounts: Bool = true) {
        if pausingAccounts { CodexProfileLimitsService.shared.pause() }
        // A first read still going stops at its next chunk, so the wait
        // below is short.
        if running { cancellation.cancel() }
        settleArchive(keeping: keeps && NotchAgentSupport.isEnabled())
        guard running else { return }
        running = false
        paused = false
        session += 1
        timer?.invalidate()
        timer = nil
        providers = []
        snapshot = AgentUsageSnapshot()
        queue.async { [self] in
            readerSession = -1
            readerCancellation = nil
            poller?.cancel()
            poller = nil
            watcher?.stop()
            watcher = nil
            watchedRoots = []
            network?.cancel()
            network = nil
            offlineSince = nil
            store = AgentUsageStore()
            cursors.removeAll()
            claudeCopies.removeAll()
            published = AgentUsageSnapshot()
            previousLimits.removeAll()
            warned.removeAll()
            budgetDay = nil
            claudePlan = nil
            savedMark = nil
            lastSave = .distantPast
        }
    }

    /// Limits an agent read from the account on request, newer than its
    /// logs until it writes again: after a banked reset, right away.
    func noteLimits(_ reading: AgentLimits) {
        guard running else { return }
        queue.async { [self] in
            guard readerSession >= 0, enabled.contains(reading.provider) else { return }
            store.updateLimits(reading)
            checkLimits()
            schedulePublish()
        }
    }

    /// The page appearing is one of the events on which
    /// ClaudeAccountsService checks the accounts whose limits are older than
    /// 15 minutes. A Settings preview asks nothing.
    func pageDidAppear(preview: Bool = false) {
        guard !preview else { return }
        ClaudeAccountsService.foregroundEvent()
    }

    /// Claude's plan limits come from ClaudeAccountsService, which
    /// follows every account; the island's strip, its resting allowance and
    /// the limit alerts show the account Claude works on. Main thread.
    func setClaude(limits: AgentLimits?, plan: AgentPlan?) {
        claudeAccount = (limits, plan)
        guard running else { return }
        queue.async { [self] in
            guard readerSession >= 0 else { return }
            claudePlan = enabled.contains(.claude) ? plan : nil
            if let limits, enabled.contains(.claude) { store.setLimits(limits) } else { store.clearLimits(.claude) }
            checkLimits()
            schedulePublish()
        }
    }

    // MARK: Reading

    private func startTimer() {
        // Rule 1 exception, pending its event-driven replacement (ticket T-01): a 30 s
        // tick still reads the open logs and the price list while the AI section reads usage.
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in self?.tickTimer() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func start(session: Int, providers: Set<AgentProvider>, cancellation: Cancellation,
                       claudeFolders: [String] = [""]) {
        startTimer()
        queue.async { [self] in
            readerSession = session
            readerCancellation = cancellation
            enabled = providers
            readerClaudeFolders = claudeFolders
            store = AgentUsageStore()
            cursors.removeAll()
            claudeCopies.removeAll()
            // Prices first, so the first read is already priced.
            loadPrices()
            // Keep the loading state until all initial history has been read.
            let horizon = Date().addingTimeInterval(-Self.horizon)
            let roots = AgentLogRoot.all(home: home, claudeFolders: claudeFolders).filter { providers.contains($0.provider) }
            claudeRoots = roots.filter { $0.provider == .claude }
            let files = AgentLogReader.discover(roots, since: horizon)
            // Resumes where the last launch stopped, among the logs there now.
            if let saved = AgentUsageArchive.load(), saved.providers == providers {
                let resumed = AgentUsageArchive.resume(saved, logs: Set(files.map(\.path)), since: horizon)
                (store, cursors) = (resumed.store, resumed.cursors)
                // What the resume took back leaves the disk at the next save.
                if resumed.unchanged { savedMark = progressMark }
            }
            for file in files {
                // A stop while reading leaves the rest for the next start.
                guard !cancellation.isCancelled else { return }
                read(file.path, provider: file.provider)
            }
            guard !cancellation.isCancelled else { return }
            let now = Date()
            // A turn left open by a crash would otherwise stay working.
            store.closeIdleTurns(now: now, after: NotchAgentSupport.idleTurn)
            closeEndedTurns(roots, atLaunch: true)
            store.reportsTransitions = true
            previousLimits = store.limits
            // A budget already passed before launch is history, not news.
            let today = Calendar.autoupdatingCurrent.startOfDay(for: now)
            if let budget = NotchAgentSupport.dailyBudget(),
               store.records.lazy.filter({ $0.date >= today }).reduce(0.0, { $0 + ($1.cost ?? 0) }) >= budget {
                budgetDay = today
            }
            watch(roots)
            startPolling()
            watchNetwork()
            publish()
            saveProgress()
        }
    }

    /// Saves progress, or removes it once the section is off, even what an
    /// earlier launch saved. Quitting stops the service too and ends the
    /// process right after, so this returns only once the file is settled.
    /// Main thread.
    private func settleArchive(keeping keeps: Bool) {
        queue.sync {
            if keeps { saveProgress() } else { AgentUsageArchive.remove() }
        }
    }

    /// Saves what was read, when reading moved on since the last save. Runs
    /// on `queue`.
    private func saveProgress() {
        guard readerSession >= 0 else { return }
        let mark = progressMark
        lastSave = Date()
        guard mark != savedMark else { return }
        // A log that started over while running still counts what its old
        // contents gave. Left out, the next launch reads it as rewritten.
        // Nothing from OpenCode's database is saved. Its open replies and
        // sessions live only in memory, so each launch reads it again.
        let kept = cursors.values.filter { !$0.restarted && $0.provider != .opencode }
        let contents = AgentUsageArchive.Contents(providers: enabled, store: store.saved, cursors: kept.map(\.saved))
        if AgentUsageArchive.save(contents) { savedMark = mark }
    }

    /// Changes whenever a log is read further, replaced or let go. OpenCode,
    /// which is never saved, leaves it alone.
    private var progressMark: Int {
        let records = store.records.reduce(0) { $1.provider == .opencode ? $0 : $0 + 1 }
        return cursors.values.reduce(records) { mark, cursor in
            guard cursor.provider != .opencode else { return mark }
            var hasher = Hasher()
            hasher.combine(cursor.path)
            hasher.combine(cursor.offset)
            hasher.combine(cursor.identity)
            return mark &+ hasher.finalize()
        }
    }

    /// Runs on `queue`.
    private func startPolling() {
        poller?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            defer { self.syncPolling() }
            let read = self.pollOpenLogs(within: Self.pollWindow)
            var stopped = self.store.closeSettledTurns(now: Date())
            // After the logs too, which can hold a reply or a command's
            // result written meanwhile.
            if let offline = self.offlineSince,
               self.store.closeOfflineTurns(since: offline.date,
                                            lasting: ProcessInfo.processInfo.systemUptime - offline.uptime,
                                            keeping: self.runningCommands) {
                stopped = true
            }
            // After the logs, so a turn its last lines ended ends as usual.
            guard self.closeEndedTurns(self.watchedRoots) || read || stopped else { return }
            self.checkLimits()
            self.schedulePublish()
        }
        poller = timer
        polling = false
        syncPolling()
        timer.resume()
    }

    /// The fast timer has no work once recent logs and active turns are gone.
    /// File events and the existing thirty-second sweep can arm it again.
    /// Never create a timer here: late work after pause or stop must stay idle.
    private func syncPolling(now: Date = Date()) {
        guard let poller else { return }
        let wanted = !store.turns.isEmpty || !store.waiting.isEmpty
            || cursors.values.contains { now.timeIntervalSince($0.modified) < Self.pollWindow }
        guard wanted != polling else { return }
        polling = wanted
        if wanted {
            poller.schedule(deadline: .now() + Self.poll, repeating: Self.poll, leeway: .milliseconds(500))
        } else {
            poller.schedule(deadline: .distantFuture)
        }
    }

    /// Reads the logs that grew, were replaced or disappeared since the last
    /// look, among those an agent may still be writing. True when that
    /// changed what is stored.
    private func pollOpenLogs(within window: TimeInterval) -> Bool {
        guard readerSession >= 0 else { return false }
        let now = Date()
        // A turn gone quiet, as while it waits for an approval, is noticed
        // as soon as its work resumes.
        var working = Set(store.turns.keys).union(store.waiting.keys)
        // An OpenCode turn is kept by database and session.
        for key in working {
            if let mark = key.firstIndex(of: "#") { working.insert(String(key[..<mark])) }
        }
        var changed = false
        for (path, cursor) in cursors
        where working.contains(path) || now.timeIntervalSince(cursor.modified) < window {
            if cursor.provider == .opencode {
                // A database changes in place: its write-ahead log grows instead.
                if let modified = AgentOpenCodeReader.modified(path), modified <= cursor.modified { continue }
                if read(path, provider: cursor.provider) { changed = true }
                continue
            }
            var info = stat()
            let exists = stat(path, &info) == 0
            guard !exists || UInt64(max(0, info.st_size)) != cursor.offset
                    || UInt64(info.st_ino) != cursor.identity else { continue }
            if read(path, provider: cursor.provider) { changed = true }
        }
        return changed
    }

    /// Claude Code retries for minutes without a word while the Mac is
    /// offline, then gives up; until it does, its turn would count on.
    /// Only notes when the network went: the poller, which reads the logs
    /// first and waits while the island is away, ends the turns once the
    /// Mac stays offline. Runs on `queue`.
    private func watchNetwork() {
        guard network == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, self.readerSession >= 0 else { return }
            let online = path.status == .satisfied
            if online {
                self.offlineSince = nil
            } else if self.offlineSince == nil {
                self.offlineSince = (Date(), ProcessInfo.processInfo.systemUptime)
            }
        }
        monitor.start(queue: queue)
        network = monitor
    }

    /// The logs whose turn waits on a shell command of its own; a subagent's
    /// commands are not counted. Runs on `queue`.
    private var runningCommands: Set<String> {
        Set(cursors.filter { !$0.value.state.runningCommands.isEmpty }.keys)
    }

    /// Ends the Claude turns whose process is gone. True when one was showing.
    @discardableResult
    private func closeEndedTurns(_ roots: [AgentLogRoot], atLaunch: Bool = false) -> Bool {
        guard store.showsClaudeTurn, roots.contains(where: { $0.provider == .claude }) else { return false }
        // Each account's own sessions folder, even when its logs are
        // shared with another account's.
        let folders = AgentLogRoot.claudeSessionFolders(home: home, claudeFolders: readerClaudeFolders)
        return store.closeEndedTurns(AgentSessionRegistry.read(folders), atLaunch: atLaunch)
    }

    /// True when the log had entries to apply, or was gone and took a
    /// working turn with it.
    @discardableResult
    private func read(_ path: String, provider: AgentProvider) -> Bool {
        guard let cancellation = readerCancellation, !cancellation.isCancelled else { return false }
        let copyKey = provider == .claude ? AgentLogRoot.claudeCopyKey(path, roots: claudeRoots) : nil
        guard FileManager.default.fileExists(atPath: path) else {
            cursors[path] = nil
            var changed = store.forget(file: path)
            if let copyKey, claudeCopies[copyKey] == path {
                claudeCopies[copyKey] = nil
                // The copy read went (Brim holds the other folders' copies
                // out of view while a conversation is open in one, and
                // Claude Code's cleanup runs per folder): another account's
                // copy of the conversation, the longest, is read instead.
                let others = claudeRoots.map { $0.url.path + "/" + copyKey }
                    .filter { $0 != path && FileManager.default.fileExists(atPath: $0) }
                if let next = others.max(by: { (AgentLogReader.size($0) ?? 0) < (AgentLogReader.size($1) ?? 0) }) {
                    changed = read(next, provider: provider) || changed
                }
            }
            return changed
        }
        // Another account's copy of a conversation already read here (Brim
        // keeps one in each account's projects/): read only when it is longer,
        // that is where the conversation goes on now, and then from where the
        // other copy's reading stopped.
        if let copyKey, let chosen = claudeCopies[copyKey], chosen != path {
            guard let size = AgentLogReader.size(path), size > (AgentLogReader.size(chosen) ?? 0) else { return false }
            if let old = cursors[chosen], let moved = AgentLogCursor(continuing: old, at: path) { cursors[path] = moved }
            cursors[chosen] = nil
            store.forget(file: chosen)
        }
        if let copyKey { claudeCopies[copyKey] = path }
        let cursor = cursors[path] ?? AgentLogCursor(path: path, provider: provider)
        cursors[path] = cursor
        var changed = false
        let now = Date()
        let consume: (Data) -> Void = { [self] line in
            // Apply in log order while the chunk is alive instead of retaining
            // every parsed entry until a potentially multi-gigabyte file ends.
            let entries = provider.reader.parse(line, state: &cursor.state, now: now)
            guard !entries.isEmpty else { return }
            changed = true
            let isSubagent = provider == .opencode && !cursor.state.parentSession.isEmpty
            let turnFile = provider == .opencode && !cursor.state.session.isEmpty ? "\(path)#\(cursor.state.session)" : path
            let tracksTurns = isSubagent ? false : cursor.tracksTurns
            let parent = isSubagent ? "\(path)#\(cursor.state.parentSession)"
                : cursor.parent ?? cursor.codexParent(among: cursors)
            let finished = store.apply(entries, file: turnFile, provider: provider, tracksTurns: tracksTurns,
                                       parent: parent, modified: cursor.modified, now: now)
            finished.forEach(report)
        }
        if provider.reader.readsFullHistoryFirst && cursor.offset == 0 {
            AgentLogReader.readCopilotHistory(cursor, shouldContinue: { !cancellation.isCancelled }, line: consume)
        } else {
            AgentLogReader.readAppended(cursor, since: now.addingTimeInterval(-Self.horizon),
                                        shouldContinue: { !cancellation.isCancelled }, line: consume)
        }
        return changed
    }

    private func watch(_ roots: [AgentLogRoot]) {
        let existing = roots.filter(\.exists)
        watchedRoots = existing
        claudeRoots = roots.filter { $0.provider == .claude }
        lastRootCheck = Date()
        if watcher == nil {
            watcher = FileEventStream(name: "agent-usage", queue: queue, configuration: .init(latency: 1.0),
                                      handler: { [weak self] batch in
                                          self?.filesChanged(batch.paths, rescan: batch.mustRescan || batch.rootChanged)
                                      },
                                      // Lost events or a new registration: every log is looked at again.
                                      resync: { [weak self] in self?.filesChanged([], rescan: true) })
        }
        watcher?.watch(existing.map(\.url.path))
    }

    private func filesChanged(_ paths: [String], rescan: Bool) {
        guard readerSession >= 0, !watchedRoots.isEmpty else { return }
        defer { syncPolling() }
        var changed = false
        if rescan {
            for file in AgentLogReader.discover(watchedRoots, since: Date().addingTimeInterval(-Self.horizon)) {
                if read(file.path, provider: file.provider) { changed = true }
            }
        } else {
            for path in Set(paths) where AgentLogReader.isLog(path) {
                let actualPath = path.hasSuffix("-wal") ? String(path.dropLast(4)) : path
                guard let root = watchedRoots.first(where: { $0.accepts(actualPath) }) else { continue }
                if read(actualPath, provider: root.provider) { changed = true }
            }
        }
        // Saved tool output and lines with nothing to keep do not change the
        // summary or require a display update.
        guard changed else { return }
        checkLimits()
        schedulePublish()
    }

    /// Bursts of writes publish once.
    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        queue.asyncAfter(deadline: .now() + Self.publishDelay) { [self] in
            publishScheduled = false
            publish()
        }
    }

    private func tickTimer() {
        guard running else { return }
        queue.async { [self] in
            guard readerSession >= 0 else { return }
            let now = Date()
            defer { syncPolling(now: now) }
            let before = inputs
            store.closeIdleTurns(now: now, after: NotchAgentSupport.idleTurn)
            store.dropRecords(before: now.addingTimeInterval(-Self.horizon))
            // A log kept open through a long pause reports nothing when work
            // resumes; the day's logs are looked at less often than recent ones.
            var changed = pollOpenLogs(within: 86_400)
            // A folder that appears later, like a first Codex session, is
            // picked up without a restart.
            if now.timeIntervalSince(lastRootCheck) > 300 {
                let roots = AgentLogRoot.all(home: home, claudeFolders: readerClaudeFolders).filter { enabled.contains($0.provider) }
                if roots.filter(\.exists) != watchedRoots {
                    for file in AgentLogReader.discover(roots, since: now.addingTimeInterval(-Self.horizon)) {
                        if read(file.path, provider: file.provider) { changed = true }
                    }
                    watch(roots)
                }
                lastRootCheck = now
            }
            checkLimits()
            reportRenewals(now: now)
            if now.timeIntervalSince(lastSave) >= Self.saveInterval { saveProgress() }
            // Publish only when stored values or sliding time windows change.
            if changed || inputs != before || AgentUsageSummary.movesWithClock(published, now: now) {
                schedulePublish()
            }
        }
    }

    /// The stored state a snapshot is made from, compared across a tick.
    private struct Inputs: Equatable {
        let records: Int
        let turns: [String: AgentLiveSession]
        let limits: [AgentProvider: AgentLimits]
        let codexPlan: String?
        let claudePlan: AgentPlan?
    }

    /// Runs on `queue`.
    private var inputs: Inputs {
        Inputs(records: store.records.count, turns: store.turns, limits: store.limits, codexPlan: store.codexPlan,
               claudePlan: claudePlan)
    }

    /// Runs on `queue` and hands the finished snapshot to the main thread.
    private func publish() {
        let session = readerSession
        guard session >= 0 else { return }
        var plans: [AgentProvider: AgentPlan] = [:]
        if let claudePlan { plans[.claude] = claudePlan }
        if let codex = AgentPlans.codex(planType: store.codexPlan) { plans[.codex] = codex }
        let next = store.snapshot(plans: plans, providers: enabled, now: Date())
        published = next
        checkBudget(next)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running, self.session == session else { return }
            if self.snapshot != next { self.snapshot = next }
        }
    }

    // MARK: Alerts

    /// Filters by the person's choices on the main thread, where they live.
    private func report(_ event: AgentUsageEvent) {
        let session = readerSession
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running, self.session == session else { return }
            switch event {
            case .finished(let provider, let duration, _, _, _):
                guard self.providers.contains(provider), let minimum = NotchAgentSupport.finishMinimum(),
                      duration >= minimum else { return }
            case .limitWarning(let provider, _), .limitReset(let provider, _):
                guard self.providers.contains(provider), NotchAgentSupport.limitThreshold() != nil else { return }
            case .budgetReached:
                guard NotchAgentSupport.dailyBudget() != nil else { return }
            }
            self.events.send(event)
        }
    }

    /// Runs on `queue` whenever limits may have changed.
    private func checkLimits() {
        guard store.reportsTransitions else { return }
        let threshold = NotchAgentSupport.limitThreshold() ?? NotchAgentSupport.defaultLimitThreshold
        for (provider, limits) in store.limits {
            for window in AgentLimitSupport.crossings(previous: previousLimits[provider], current: limits,
                                                      threshold: threshold) {
                warned[window.id] = (provider, window)
                report(.limitWarning(provider: provider, window: window))
            }
        }
        // A banked reset renews a warned window before its time, which is
        // news now rather than at the renewal it replaced or, as a Claude
        // week keeps its renewal, at that one.
        for (id, entry) in warned {
            guard let reading = store.limits[entry.provider],
                  let window = reading.windows.first(where: { $0.id == id }), window.usedPercent < threshold,
                  AgentLimitSupport.renewed(entry.window, to: window, observedAt: reading.observedAt) else { continue }
            warned[id] = nil
            report(.limitReset(provider: entry.provider, window: window))
        }
        previousLimits = store.limits
    }

    /// A warned window that renews brings its agent back: worth a word.
    private func reportRenewals(now: Date) {
        for (id, entry) in warned {
            guard let resets = entry.window.resetsAt, resets <= now else { continue }
            warned[id] = nil
            report(.limitReset(provider: entry.provider, window: entry.window))
        }
    }

    private func checkBudget(_ snapshot: AgentUsageSnapshot) {
        guard store.reportsTransitions, let budget = NotchAgentSupport.dailyBudget() else { return }
        let today = Calendar.autoupdatingCurrent.startOfDay(for: snapshot.now)
        let spent = snapshot.usage(.today).total.cost
        guard spent >= budget, budgetDay != today else { return }
        budgetDay = today
        report(.budgetReached(spent: spent, budget: budget))
    }

    // MARK: Prices

    /// The list inside the app. Runs on `queue`.
    private func loadPrices() {
        if shippedPrices == nil { shippedPrices = AgentPriceSource.bundled() }
        AgentPricing.install(shippedPrices ?? .empty)
    }
}
