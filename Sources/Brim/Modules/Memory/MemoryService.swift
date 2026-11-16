// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import AppKit
import Combine
import Foundation
import os.log
import UserNotifications

/// An app in the "Heavy & idle" list.
struct MemoryIdleAppRow: Identifiable, Equatable {
    var app: MemoryApp
    var idleFor: TimeInterval
    /// Quit was asked and the app has not ended yet (a save sheet, say).
    var quitting: Bool
    var id: pid_t { app.pid }
}

/// What the fseventsd row shows from the `log stream` child: evidence,
/// never a notification by itself.
struct MemoryDaemonEvidence: Equatable {
    /// The latest "event table has grown too large" line.
    var tableTooLargeAt: Date?
    /// Clients fseventsd throttled ("SLOWDOWN"), newest first, with names
    /// once a scan resolved them.
    var slowClients: [(pid: pid_t, name: String?, at: Date)] = []

    static func == (left: MemoryDaemonEvidence, right: MemoryDaemonEvidence) -> Bool {
        left.tableTooLargeAt == right.tableTooLargeAt
            && left.slowClients.map(\.pid) == right.slowClients.map(\.pid)
            && left.slowClients.map(\.name) == right.slowClients.map(\.name)
    }
}

/// Brim's Memory module: finds what holds memory, names it, and, at most,
/// ends the high-confidence class on its own while memory is tight.
/// Unnoticeable while working: no badge, sound or popup while memory is
/// fine, one notification per memory-tight episode (plus one per fseventsd
/// leak), and every action logged with what it measurably changed. The one
/// memory notifier in the app.
///
/// Event-driven, with no repeating timer (code rule 1). A scan (one process
/// table read plus MemoryClassifier and MemoryHolders) runs on:
/// - memory pressure events (MemoryPressureMonitor),
/// - a swapfile appearing or going (MemoryTriggers' kqueue watch), and
///   SystemMonitor readings it already takes showing swap or the compressor
///   up sharply,
/// - apps launching and terminating, the Mac waking, the screen unlocking,
/// - the exit of a watched root (a terminal shell, an agent CLI, a test run's
///   parent, an MCP wrapper), whose former groups are then judged,
/// - the exit of a big holder (1 GB+), recorded with measured deltas,
/// - the Memory panel section or Settings page appearing (never acting),
/// - one one-shot deadline at a time: a candidate's idle window, or the
///   growth follow-up while something is elevated.
/// While a memory-tight episode is open, the runaway brake (T-52) also reads
/// the own processes' footprints every 3 to 5 s on that same deadline, and
/// ends one holding more than half of physical memory.
/// App activation only moves the idle clocks; it does not scan.
@MainActor
final class MemoryService: ObservableObject {
    static let shared = MemoryService()

    @Published private(set) var summary = MemorySummary()
    @Published private(set) var findings: [MemoryFinding] = []
    @Published private(set) var idleApps: [MemoryIdleAppRow] = []
    @Published private(set) var testRunActive = false
    @Published private(set) var log = MemoryActivityLog()
    @Published private(set) var isRunning = false
    @Published private(set) var settings = MemorySettings()
    /// Findings (and holders) an action is ending right now.
    @Published private(set) var busy: Set<String> = []
    /// "Biggest now": what holds the memory.
    @Published private(set) var holders: [MemoryHolder] = []
    /// Other users' processes whose memory could not be measured.
    @Published private(set) var notMeasuredSystem = 0
    /// A memory-tight episode is open: the automatic tier may act.
    @Published private(set) var memoryTight = false
    @Published private(set) var daemonEvidence = MemoryDaemonEvidence()
    @Published private(set) var lastScan: MemoryScanCost?
    /// The newest runaway the person dismissed from the panel was ended then.
    @Published private(set) var runawaySeenThrough: Date?

    nonisolated private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brim", category: "memory")
    nonisolated static let categoryIdentifier = "brim.memory.pressure"
    nonisolated static let holderCategoryIdentifier = "brim.memory.holder"
    nonisolated static let quitThemAction = "brim.memory.quit-them"
    nonisolated static let reviewAction = "brim.memory.review"
    nonisolated static let copyRestartAction = "brim.memory.copy-restart"

    private var observations = MemoryObservations()
    private var clock = MemoryActivityClock(startingAt: ProcessInfo.processInfo.systemUptime)
    private var lastUsed: [pid_t: TimeInterval] = [:]
    private var apps: [pid_t: MemoryApp] = [:]
    private var quitting: [pid_t: UUID] = [:]
    private var episode = MemoryTightEpisode()
    private var lastMeasurement: MemoryMeasurement?
    private var history = MemoryHolderHistory()
    private var followUp = MemoryFollowUp()
    private var followUpDue: Date?
    private var followUpBytes: UInt64 = 0
    private var classifierDeadline: Date?
    private var lastTableLine: Date?
    private var scanInFlight = false
    private var pendingTrigger: MemoryScanTrigger?
    private var rootSources: [ProcessIdentity: DispatchSourceProcess] = [:]
    private var rootGroups: [ProcessIdentity: Set<pid_t>] = [:]
    private var exitSources: [ProcessIdentity: DispatchSourceProcess] = [:]
    private var holderWatches: [ProcessIdentity: HolderWatch] = [:]
    private var watches: [UUID: MemoryActionWatch] = [:]
    private var forceChecks: [UUID: Timer] = [:]
    /// Every process the automatic tier has signalled and that is still
    /// listed: never signalled by it again. Filled when a signal was
    /// attempted, never at the pick: a group the re-check skipped stays eligible.
    private var autoSignalled: Set<ProcessIdentity> = []
    /// The processes each busy End acts on (by busy key), from the click or
    /// the automatic tier's pick until its signal; then `watches` has them.
    private var busyTargets: [String: [ProcessIdentity]] = [:]
    /// Apps Brim asked to quit, kept while the app or a big helper it is
    /// responsible for is still listed: their exits are Brim's, not "outside".
    private var quitApps: Set<pid_t> = []
    /// Tickets for actions waiting on `actionQueue`, checked right before
    /// each signal (MemoryActionAuthority).
    private let authority = MemoryActionAuthority()
    /// Counts scans as they start, so Quit them acts on a scan begun after
    /// the click, never on one already running when it came.
    private var scanGeneration = 0
    private var quitThemAfterScan: Int?
    private var deadline: Timer?
    /// The runaway brake (T-52): more than half of physical memory.
    private let runawayThreshold = MemoryRunawayBrake.threshold(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    /// The brake's next read while an episode is open; it rides `deadline`.
    private var runawayDue: Date?
    private var runawayReadInFlight = false
    /// Processes the brake signalled: never picked by it again, so a signal
    /// kill() cannot deliver is not retried in a loop. Their rows keep End
    /// and Force for the person.
    private var runawaySignalled: Set<ProcessIdentity> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var pressureSubscription: AnyCancellable?
    private var triggers: MemoryTriggers?
    private let scanQueue = DispatchQueue(label: "brim.memory.scan", qos: .utility)
    private let actionQueue = DispatchQueue(label: "brim.memory.action", qos: .userInitiated)

    /// A big holder watched for its exit. FSEventsDaemonWatch (FileEvents) also
    /// watches fseventsd's exit, to re-create file-event streams; this one
    /// is generic (any tracked holder of 1 GB+) and only records the exit
    /// with measured deltas. Neither is fseventsd-restart code.
    private struct HolderWatch {
        var source: DispatchSourceProcess
        var title: String
        var bytes: UInt64
        var restartedByLaunchd: Bool
        /// Its responsible process when armed (an app for its helpers):
        /// read while it runs, since an exited pid has none to read.
        var owner: pid_t
    }

    /// At most this many holders are watched for their exit at once.
    private static let maximumHolderWatches = 8

    // MARK: Entry points for callers on the main thread that are not marked so

    /// The feature runtime's binding for the Memory monitor feature.
    nonisolated static func syncWithFeature() {
        MainActor.assumeIsolated { shared.syncWithPreferences() }
    }

    /// The notification's buttons. True when the response was this module's.
    nonisolated static func handleNotification(_ response: UNNotificationResponse) -> Bool {
        let category = response.notification.request.content.categoryIdentifier
        guard category == categoryIdentifier || category == holderCategoryIdentifier else { return false }
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated { shared.notificationAction(action) }
        }
        return true
    }

    // MARK: Lifecycle

    /// Runs while the Memory monitor feature is installed.
    func syncWithPreferences() {
        if AppFeature.monitorMemory.isAvailable { start() } else { stop() }
    }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        settings = MemorySettings(.standard)
        log = MemoryActivityLog.decoded(Self.logURL.flatMap { try? Data(contentsOf: $0) })
        runawaySeenThrough = MemoryRunawayNotice.seenThrough(.standard)
        clock = MemoryActivityClock(startingAt: Self.uptime)
        // An already elevated level opens an episode at the first scan.
        summary.pressure = MemoryPressureMonitor.shared.level
        // An app's use before Brim started is unknown: its clock starts now.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            lastUsed[app.processIdentifier] = clock.reading(at: Self.uptime)
        }
        pressureSubscription = MemoryPressureMonitor.shared.events.sink { level in
            MainActor.assumeIsolated { MemoryService.shared.pressureEvent(level) }
        }
        observeWorkspace()
        let triggers = MemoryTriggers(
            onSwapChange: { MemoryService.shared.scan(.swap) },
            onDaemonLog: { MemoryService.shared.daemonLogged($0) },
            onMonitorReading: { MemoryService.shared.monitorReading(swapUsed: $0, compressed: $1) })
        self.triggers = triggers
        triggers.start()
        // Whether an alert can reach the screen at all, read now: asked once
        // when never asked, a warning row when off (T-52).
        Permissions.shared.refreshNotifications(requestIfUndetermined: settings.notify)
        scan(.start)
    }

    private func stop() {
        guard isRunning else { return }
        isRunning = false
        // Actions still waiting on the queue never signal now.
        authority.revoke(.stopped)
        pressureSubscription = nil
        triggers?.stop()
        triggers = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers = []
        distributedObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        distributedObservers = []
        rootSources.values.forEach { $0.cancel() }
        rootSources = [:]
        rootGroups = [:]
        exitSources.values.forEach { $0.cancel() }
        exitSources = [:]
        holderWatches.values.forEach { $0.source.cancel() }
        holderWatches = [:]
        forceChecks.values.forEach { $0.invalidate() }
        forceChecks = [:]
        watches = [:]
        autoSignalled = []
        busyTargets = [:]
        quitApps = []
        quitThemAfterScan = nil
        deadline?.invalidate()
        deadline = nil
        runawayDue = nil
        runawayReadInFlight = false
        runawaySignalled = []
        findings = []
        idleApps = []
        holders = []
        apps = [:]
        lastUsed = [:]
        quitting = [:]
        busy = []
        observations = MemoryObservations()
        episode = MemoryTightEpisode()
        memoryTight = false
        lastMeasurement = nil
        history = MemoryHolderHistory()
        followUp = MemoryFollowUp()
        followUpDue = nil
        classifierDeadline = nil
        testRunActive = false
    }

    /// The panel section or the Settings page appeared. It scans and never
    /// acts: `.foreground` does not run the automatic tier.
    func foreground() {
        guard isRunning else { return }
        reloadSettings()
        Permissions.shared.refreshNotifications(requestIfUndetermined: settings.notify)
        scan(.foreground)
    }

    /// Settings changed from the Settings page.
    func reloadSettings() {
        let fresh = MemorySettings(.standard)
        guard fresh != settings else { return }
        let notifyTurnedOn = fresh.notify && !settings.notify
        // An action already queued was decided under the old settings.
        if fresh.keep != settings.keep { authority.revoke(.keepChanged) }
        if settings.autoClean && !fresh.autoClean { authority.revoke(.autoCleanOff) }
        settings = fresh
        if notifyTurnedOn { Permissions.shared.refreshNotifications(requestIfUndetermined: true) }
        refreshIdleApps()
        if isRunning { scan(.foreground) }
    }

    // MARK: Events

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ handle: @escaping @MainActor (Notification) -> Void) {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { handle(note) }
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { note in
            guard let app = Self.app(note) else { return }
            MemoryService.shared.touch(app.processIdentifier)
            MemoryService.shared.scan(.launch)
        }
        on(NSWorkspace.didTerminateApplicationNotification) { note in
            guard let app = Self.app(note) else { return }
            MemoryService.shared.appTerminated(app.processIdentifier)
        }
        on(NSWorkspace.didActivateApplicationNotification) { note in
            guard let app = Self.app(note) else { return }
            MemoryService.shared.touch(app.processIdentifier)
        }
        on(NSWorkspace.didDeactivateApplicationNotification) { note in
            // In use until this moment.
            guard let app = Self.app(note) else { return }
            MemoryService.shared.touch(app.processIdentifier)
        }
        on(NSWorkspace.willSleepNotification) { _ in
            MemoryService.shared.clock.pause(.asleep, at: Self.uptime)
            MemoryService.shared.pauseFollowUp(asleep: true)
        }
        on(NSWorkspace.didWakeNotification) { _ in
            MemoryService.shared.clock.resume(.asleep, at: Self.uptime)
            MemoryService.shared.scan(.wake)
        }
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                MemoryService.shared.clock.pause(.locked, at: Self.uptime)
                MemoryService.shared.pauseFollowUp(asleep: false)
            }
        })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                MemoryService.shared.clock.resume(.locked, at: Self.uptime)
                MemoryService.shared.scan(.unlock)
            }
        })
    }

    nonisolated private static func app(_ note: Notification) -> NSRunningApplication? {
        note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    nonisolated private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func touch(_ pid: pid_t) {
        lastUsed[pid] = clock.reading(at: Self.uptime)
        refreshIdleApps()
    }

    private func appTerminated(_ pid: pid_t) {
        lastUsed[pid] = nil
        apps[pid] = nil
        if let entryID = quitting.removeValue(forKey: pid) {
            let after = MemorySystemReads.measurement()
            log.update(entryID) { entry in
                entry.outcome = .done
                entry.estimatedFreed = entry.estimatedBytes
                entry.measuredAfter = after
            }
            saveLog()
        }
        refreshIdleApps()
        scan(.terminate)
    }

    private func pressureEvent(_ level: MemoryPressure) {
        summary.pressure = level
        scan(.pressure)
    }

    private func rootExited(_ root: ProcessIdentity) {
        rootSources.removeValue(forKey: root)?.cancel()
        let now = Date()
        for group in rootGroups.removeValue(forKey: root) ?? [] where observations.rootExits[group] == nil {
            observations.rootExits[group] = now
        }
        scan(.rootExit)
    }

    /// A SystemMonitor reading it took anyway (for the panel, notch or menu
    /// bar): a scan only when swap or the compressor jumped since the last
    /// measurement. Comparisons only; nothing here starts a sampler. The
    /// scan never acts (`.monitorReading`): SystemMonitor samples memory
    /// because the panel is open, against a measurement that may be an hour
    /// old, and opening the panel never ends anything.
    private func monitorReading(swapUsed: UInt64?, compressed: UInt64?) {
        guard isRunning, MemoryMeasuredChange.monitorReadingWarrantsScan(swapUsed: swapUsed, compressed: compressed,
                                                                          last: lastMeasurement) else { return }
        scan(.monitorReading)
    }

    /// A line fseventsd logged: evidence on its row, and a table line keeps
    /// the growth follow-up armed for a day. It never notifies by itself.
    private func daemonLogged(_ event: MemoryDaemonLogEvent) {
        switch event {
        case .tableTooLarge(let at):
            daemonEvidence.tableTooLargeAt = at
            lastTableLine = at
            if followUpDue == nil, !clock.isPaused {
                followUpDue = followUp.next(after: Date(), elevated: true, grew: false, clockPaused: false)
                armDeadline()
            }
        case .slowdown(let pid, let at):
            var clients = daemonEvidence.slowClients.filter { $0.pid != pid }
            clients.insert((pid, nil, at), at: 0)
            daemonEvidence.slowClients = Array(clients.prefix(5))
        }
    }

    // MARK: Scan

    private func scan(_ trigger: MemoryScanTrigger) {
        guard isRunning else { return }
        guard !scanInFlight else {
            // One scan follows the running one; an outside event's trigger
            // wins over the panel's, so a pressure event is never lost to it.
            pendingTrigger = MemoryScanTrigger.queued(after: pendingTrigger, incoming: trigger)
            return
        }
        scanInFlight = true
        scanGeneration += 1
        let generation = scanGeneration
        triggers?.ensureArmed(now: Self.uptime)
        let context = MemoryContext(uid: getuid(), home: NSHomeDirectory(), ownPID: getpid(), now: Date(),
                                    awake: Self.uptime, launchdJobs: nil, keep: settings.keep)
        let previous = observations
        var history = history
        let logChild = triggers?.logChildPID
        let slowClients = Set(daemonEvidence.slowClients.map(\.pid))
        let regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .map { app in
                (pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                 name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                 url: app.bundleURL, active: app.isActive)
            }
        scanQueue.async {
            let began = ProcessInfo.processInfo.systemUptime
            var context = context
            var records = ProcessTable.snapshot(options: [.arguments, .workingDirectory, .systemMemory])
            context.powerAssertions = MemorySystemReads.powerAssertionHolders()
            context.audioActive = MemorySystemReads.audioActive()
            // `launchctl list` only when a living group leader asks for it.
            let launchctlRan = MemoryClassifier.needsLaunchdJobs(records, context: context)
            if launchctlRan { context.launchdJobs = MemorySystemReads.launchdJobs() }
            let socketTargets = MemoryClassifier.socketCandidates(records, context: context)
            for index in records.indices where socketTargets.contains(records[index].pid) {
                records[index].sockets = ProcessTable.sockets(pid: records[index].pid)
            }
            var result = MemoryClassifier.scan(records, context: context, observations: previous)
            // "Left by VS Code": the app responsible for a leftover, as a label only.
            for index in result.findings.indices where result.findings[index].orphanedSince != nil {
                guard let first = result.findings[index].members.first else { continue }
                let owner = ResponsibleProcess.owner(of: first.pid)
                guard owner != first.pid, owner > 1, ProcessTable.startTime(pid: owner) != nil else { continue }
                result.findings[index].leftBy = ResponsibleProcess.displayName(pid: owner, fallback: "")
            }
            let holders = MemoryHolders.rank(records, context: context, history: &history, now: context.now,
                                             thresholds: MemoryHolderThresholds())
            let notMeasured = records.filter { $0.restricted && $0.memory == .unknown }.count
            let names = Dictionary(records.filter { slowClients.contains($0.pid) }.map { ($0.pid, $0.executableName) },
                                   uniquingKeysWith: { first, _ in first })
            // Each regular app's footprint: the app plus what it is responsible for.
            let apps = Self.apps(regularApps, records: records, context: context)
            let measurement = MemorySystemReads.measurement()
            let cost = MemoryScanCost(at: Date(), duration: ProcessInfo.processInfo.systemUptime - began, records: records,
                                      ownUID: context.uid, socketTables: socketTargets.count, launchctlRan: launchctlRan,
                                      logChildCPU: logChild.flatMap { ProcessTable.record(pid: $0)?.cpuTime })
            Self.logger.info("\(cost.logLine(trigger: String(describing: trigger)), privacy: .public)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MemoryService.shared.scanFinished(result, apps: apps, holders: holders, history: history,
                                                      notMeasured: notMeasured, slowClientNames: names,
                                                      measurement: measurement, cost: cost, trigger: trigger,
                                                      generation: generation,
                                                      previousExits: Set(previous.rootExits.keys))
                }
            }
        }
    }

    nonisolated private static func apps(_ regularApps: [(pid: pid_t, bundleID: String?, name: String, url: URL?, active: Bool)],
                                         records: [ProcessRecord], context: MemoryContext) -> [MemoryApp] {
        let appPIDs = Set(regularApps.map(\.pid))
        var footprints: [pid_t: UInt64] = [:]
        var startTimes: [pid_t: UInt64] = [:]
        var audioApps = Set<pid_t>()
        var assertionApps = Set<pid_t>()
        for record in records where record.uid == context.uid && !record.restricted {
            let owner = appPIDs.contains(record.pid) ? record.pid : ResponsibleProcess.owner(of: record.pid)
            guard appPIDs.contains(owner) else { continue }
            footprints[owner, default: 0] += record.footprint ?? 0
            if record.pid == owner { startTimes[owner] = record.startedAt }
            if context.audioActive.contains(record.pid) { audioApps.insert(owner) }
            if context.powerAssertions.contains(record.pid) { assertionApps.insert(owner) }
        }
        return regularApps.map { app in
            MemoryApp(pid: app.pid, startedAt: startTimes[app.pid], bundleID: app.bundleID, name: app.name,
                      bundleURL: app.url, isActive: app.active, footprint: footprints[app.pid] ?? 0,
                      lastUsed: 0, playingAudio: audioApps.contains(app.pid),
                      holdsAssertion: assertionApps.contains(app.pid))
        }
    }

    private func scanFinished(_ result: MemoryScanResult, apps scanned: [MemoryApp], holders ranked: [MemoryHolder],
                              history recorded: MemoryHolderHistory, notMeasured: Int,
                              slowClientNames: [pid_t: String], measurement: MemoryMeasurement?, cost: MemoryScanCost,
                              trigger: MemoryScanTrigger, generation: Int, previousExits: Set<pid_t>) {
        scanInFlight = false
        guard isRunning else { return }
        if let measurement {
            lastMeasurement = measurement
            summary = MemorySystemReads.summary(measurement, pressure: summary.pressure)
        }
        switch episode.update(pressure: summary.pressure.episodeLevel, reading: measurement) {
        case .opened(let cause): Self.logger.notice("memory: tight (\(String(describing: cause), privacy: .public))")
        case .closed:
            Self.logger.notice("memory: no longer tight")
            // An automatic End still queued was picked while it was tight.
            authority.revoke(.episodeClosed)
        case .unchanged: break
        }
        memoryTight = episode.isTight
        observations.windows = result.observations.windows
        // Exits the scan dropped (their groups are gone) go; exits recorded
        // while it ran stay for the next one.
        let dropped = previousExits.subtracting(result.observations.rootExits.keys)
        observations.rootExits = observations.rootExits.filter { !dropped.contains($0.key) }
        findings = result.findings
        testRunActive = result.testRunActive
        holders = ranked
        history = recorded
        notMeasuredSystem = notMeasured
        lastScan = cost
        daemonEvidence.slowClients = daemonEvidence.slowClients.map { ($0.pid, slowClientNames[$0.pid] ?? $0.name, $0.at) }
        apps = Dictionary(scanned.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        busy = busy.filter { id in findings.contains { $0.id == id } || holders.contains { Self.busyKey($0) == id } }
        busyTargets = busyTargets.filter { busy.contains($0.key) }
        refreshIdleApps()
        rearmRoots(result.roots)
        rearmHolderExits(ranked)
        classifierDeadline = result.nextDeadline
        planFollowUp()
        // The runaway brake on a scan an outside event started (the same
        // gate as the automatic tier: never the panel's, Settings', a
        // monitor reading's or an action's own), then its next read.
        runawaySignalled = runawaySignalled.filter(ProcessTable.isAlive)
        if trigger.runsAutomaticTier { brake(ranked) }
        planRunawayRead(largestOwn: ranked.filter { !$0.isSystem }.compactMap(\.memory.footprint).max())
        armDeadline()
        // A process the automatic tier signalled stays remembered while it
        // is still listed (it ignored SIGTERM, or could not be signalled);
        // signalled() records it once a signal was attempted.
        autoSignalled.formIntersection(findings.flatMap(\.identities))
        if settings.autoClean {
            for finding in MemoryClassifier.autoTargets(findings, thresholds: MemoryThresholds(),
                                                        alreadySignalled: autoSignalled,
                                                        trigger: trigger, memoryTight: episode.isTight)
            where !busy.contains(finding.id) {
                end(finding, automatic: true, recheck: .automatic)
            }
        }
        // Quit them acts here, on the scan begun after the click: the idle
        // apps this scan recomputed, and leftovers judged again right
        // before each signal.
        if let after = quitThemAfterScan, generation > after {
            quitThemAfterScan = nil
            for row in idleApps where !row.quitting { quit(row) }
            for finding in MemoryClassifier.quitThemTargets(findings) where !busy.contains(finding.id) {
                end(finding, automatic: false, recheck: .idleConfirmed)
            }
        }
        if settings.notify { postNotifications() }
        if let next = pendingTrigger {
            pendingTrigger = nil
            scan(next)
        }
    }

    /// The growth follow-up's next moment, kept between scans: advanced when
    /// it came due or the elevated holder grew, cleared when nothing is
    /// elevated or the activity clock is paused (asleep or locked).
    ///
    /// "Elevated" is fseventsd at 256 MB or more, a growing holder, an open
    /// episode, or a "table has grown too large" line in the last 24 h. A
    /// system row merely above 256 MB is not: WindowServer always is, which
    /// would keep an hourly scan armed forever.
    private func planFollowUp() {
        let thresholds = MemoryHolderThresholds()
        let now = Date()
        let elevatedHolder = holders.first { $0.isFSEvents && $0.bytes >= thresholds.systemListFloor }
            ?? holders.first(where: \.growing)
        let recentTable = lastTableLine.map { now.timeIntervalSince($0) < 24 * 3600 } ?? false
        let elevated = elevatedHolder != nil || episode.isTight || recentTable
        guard elevated, !clock.isPaused else {
            followUpDue = followUp.next(after: now, elevated: false, grew: false, clockPaused: clock.isPaused)
            followUpBytes = 0
            return
        }
        let bytes = elevatedHolder?.bytes ?? 0
        let grew = bytes >= followUpBytes &+ thresholds.trackFloor
        let due = followUpDue.map { $0 <= now.addingTimeInterval(60) } ?? true
        guard due || grew else { return }
        followUpDue = followUp.next(after: now, elevated: true, grew: grew && followUpBytes > 0, clockPaused: false)
        followUpBytes = bytes
    }

    /// Asleep or locked: no follow-up waits; wake and unlock scan anyway.
    /// The runaway brake stops while asleep only: both runaways of T-52
    /// came while nobody was at the Mac.
    private func pauseFollowUp(asleep: Bool) {
        followUpDue = followUp.next(after: Date(), elevated: false, grew: false, clockPaused: true)
        if asleep { runawayDue = nil }
        armDeadline()
    }

    private func refreshIdleApps() {
        let now = clock.reading(at: Self.uptime)
        let threshold = TimeInterval(settings.idleHours) * 3600
        let candidates = apps.values.map { app -> MemoryApp in
            var app = app
            app.lastUsed = lastUsed[app.pid] ?? now
            return app
        }
        let idle = MemoryIdleApps.heavyIdle(candidates, clock: now, threshold: threshold, keep: settings.keep,
                                            ownBundleID: Bundle.main.bundleIdentifier)
        let rows = idle.map { MemoryIdleAppRow(app: $0, idleFor: now - $0.lastUsed, quitting: quitting[$0.pid] != nil) }
        if rows != idleApps { idleApps = rows }
    }

    /// Process-exit sources on the roots the scan found, re-armed per scan:
    /// a root's exit is the moment its former groups become orphans.
    private func rearmRoots(_ roots: [MemoryRoot]) {
        let wanted = Dictionary(roots.map { ($0.identity, $0.groups) }, uniquingKeysWith: { first, _ in first })
        for (identity, source) in rootSources where wanted[identity] == nil {
            source.cancel()
            rootSources[identity] = nil
        }
        rootGroups = wanted
        for identity in wanted.keys where rootSources[identity] == nil {
            let source = DispatchSource.makeProcessSource(identifier: identity.pid, eventMask: .exit, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { MemoryService.shared.rootExited(identity) }
            }
            source.resume()
            rootSources[identity] = source
        }
    }

    /// Exit sources on the biggest holders (1 GB+, at most 8), re-armed per
    /// scan. A process source registers without root, so system holders are
    /// watched too. Their exit is logged with what the Mac measurably
    /// changed: the generic way to prove what a restart did.
    private func rearmHolderExits(_ holders: [MemoryHolder]) {
        let floor = MemoryHolderThresholds().exitWatchFloor
        // Never one Brim itself is ending or quitting (nor a helper of an app
        // it is quitting): that exit is Brim's, logged as its End or Quit.
        let owners = Dictionary(holders.filter { $0.bytes >= floor }.map { holder in
            (holder.identity.pid, ResponsibleProcess.owner(of: holder.identity.pid))
        }, uniquingKeysWith: { first, _ in first })
        quitApps = MemoryHolderExitWatch.stillQuitting(quitApps, running: Set(apps.keys).union(quitting.keys),
                                                       holderOwners: Set(owners.values))
        let wanted = MemoryHolderExitWatch.targets(holders, floor: floor, limit: Self.maximumHolderWatches,
                                                   ending: brimEnding, quitApps: quitApps,
                                                   owner: { owners[$0] ?? $0 })
        let wantedIDs = Set(wanted.map(\.holder.identity))
        for (identity, watch) in holderWatches where !wantedIDs.contains(identity) {
            watch.source.cancel()
            holderWatches[identity] = nil
        }
        for (holder, owner) in wanted {
            let title = Self.holderTitle(holder)
            if var watch = holderWatches[holder.identity] {
                watch.bytes = holder.bytes
                watch.title = title
                holderWatches[holder.identity] = watch
                continue
            }
            let identity = holder.identity
            let source = DispatchSource.makeProcessSource(identifier: identity.pid, eventMask: .exit, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { MemoryService.shared.holderExited(identity) }
            }
            source.resume()
            holderWatches[identity] = HolderWatch(source: source, title: title, bytes: holder.bytes,
                                                  restartedByLaunchd: holder.isFSEvents, owner: owner)
            // One that ended before its source was armed raises no event.
            if ProcessTable.kernelStartTime(pid: identity.pid) != identity.startedAt { holderExited(identity) }
        }
    }

    /// The processes an End is acting on right now: busy groups and holders
    /// from the click (or the automatic tier's pick), then every signalled
    /// process until its exit is seen.
    private var brimEnding: Set<ProcessIdentity> {
        Set(busyTargets.filter { busy.contains($0.key) }.values.joined()).union(watches.values.flatMap(\.remaining))
    }

    private func holderExited(_ identity: ProcessIdentity) {
        guard let watch = holderWatches.removeValue(forKey: identity) else { return }
        watch.source.cancel()
        // Brim's own End or Quit: its own entry records it, and its exit is
        // no outside event (no scan that may run the automatic tier).
        guard !MemoryHolderExitWatch.isBrims(identity, owner: watch.owner, ending: brimEnding, quitApps: quitApps)
        else { return }
        var entry = MemoryActivityEntry(date: Date(), kind: .holderExited, title: watch.title, reasons: [])
        entry.estimatedBytes = watch.bytes
        entry.measuredBefore = lastMeasurement
        entry.measuredAfter = MemorySystemReads.measurement()
        entry.targets = [identity]
        entry.outcome = .done
        if watch.restartedByLaunchd { entry.restartedByLaunchd = true }
        log.add(entry)
        saveLog()
        Self.logger.notice("memory: \(watch.title, privacy: .public) ended outside Brim")
        scan(.holderExit)
    }

    nonisolated static func busyKey(_ holder: MemoryHolder) -> String { "h\(holder.identity.pid)-\(holder.identity.startedAt)" }

    nonisolated static func holderTitle(_ holder: MemoryHolder) -> String {
        MemoryFormat.title(name: holder.name, count: 1, project: holder.project)
    }

    /// Rule 1 exception, recorded here: ONE one-shot timer, never repeating,
    /// at the earliest of three moments. (1) A waiting candidate's idle and
    /// orphan windows end: the leftover test needs a second CPU reading then,
    /// and no event reports "this process stayed quiet for 30 minutes".
    /// (2) The growth follow-up, only while something is elevated: no event
    /// reports a process's memory growing while swap and pressure stay quiet
    /// (fseventsd grew 1.46 GB/h for a day that way). Its backoff is 10, 20,
    /// 40, then 60 min while the holder grows under 256 MB between scans;
    /// it is never armed while the Mac is asleep or locked. (3) The runaway
    /// brake's read, only while a memory-tight episode is open (T-52): no
    /// event reports one process's footprint racing toward the machine's
    /// size (the GreenUp runner went from start to 561 GB in 150 s, and the
    /// episode opened 40 s before macOS began killing apps), so the brake
    /// reads own footprints again every 3 s while one holds 16 GB or more,
    /// 5 s otherwise (MemoryRunawayWatch); never outside an episode or while
    /// the Mac sleeps, and it stops when the episode closes. Armed again
    /// after every scan and every brake read; it only reads.
    private func armDeadline() {
        deadline?.invalidate()
        deadline = nil
        let scanAt = [classifierDeadline, followUpDue].compactMap { $0 }.min()?.addingTimeInterval(1)
        guard let fire = [scanAt, runawayDue].compactMap({ $0 }).min() else { return }
        // Rule 1 exception (the reasons and the backoff are above).
        let timer = Timer(fire: fire, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { MemoryService.shared.deadlineFired() }
        }
        // The brake keeps its seconds; a window or the follow-up can slip 30 s.
        timer.tolerance = fire == runawayDue ? 0.5 : 30
        RunLoop.main.add(timer, forMode: .common)
        deadline = timer
    }

    /// A full scan when an idle window or the follow-up is due (it brakes
    /// too), else the brake's own light read.
    private func deadlineFired() {
        let soon = Date().addingTimeInterval(1)
        if runawayDue == nil || [classifierDeadline, followUpDue].contains(where: { $0.map { $0 <= soon } ?? false }) {
            scan(.deadline)
        } else {
            runawayRead()
        }
    }

    // MARK: Runaway brake

    /// When the brake reads next: while an episode is open and the Mac is
    /// awake, 3 or 5 s from now (MemoryRunawayWatch); otherwise never.
    private func planRunawayRead(largestOwn: UInt64?) {
        runawayDue = MemoryRunawayWatch.next(after: Date(), memoryTight: episode.isTight,
                                             asleep: clock.pauses.contains(.asleep), largestOwn: largestOwn,
                                             threshold: runawayThreshold)
    }

    /// The brake's read between scans: one table read of the own processes'
    /// footprints with their arguments and folders (about 35 ms for 1,900
    /// processes): no sockets, coalitions, classifier or launchctl, nothing
    /// spawned while memory is short.
    private func runawayRead() {
        runawayDue = nil
        guard isRunning, episode.isTight, !runawayReadInFlight else {
            // The deadline that fired may still carry a window or the follow-up.
            armDeadline()
            return
        }
        runawayReadInFlight = true
        let context = MemoryContext(uid: getuid(), home: NSHomeDirectory(), ownPID: getpid(), now: Date(),
                                    awake: Self.uptime, launchdJobs: nil, keep: settings.keep)
        let threshold = runawayThreshold
        scanQueue.async {
            let records = ProcessTable.snapshot(options: [.arguments, .workingDirectory])
            let read = MemoryRunawayBrake.read(records, context: context, threshold: threshold)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MemoryService.shared.runawayReadFinished(read) }
            }
        }
    }

    private func runawayReadFinished(_ read: MemoryRunawayRead) {
        runawayReadInFlight = false
        guard isRunning else { return }
        brake(read.over)
        planRunawayRead(largestOwn: read.largestOwn)
        armDeadline()
    }

    /// Ends a runaway when there is one: the biggest own process over half of
    /// physical memory while an episode is open, one Brim offers End for,
    /// not being ended and not signalled by the brake before.
    private func brake(_ holders: [MemoryHolder]) {
        guard let target = MemoryRunawayBrake.target(holders, threshold: runawayThreshold, memoryTight: episode.isTight,
                                                      excluded: runawaySignalled.union(brimEnding)) else { return }
        Self.logger.notice("memory: runaway \(Self.holderTitle(target), privacy: .public) at \(target.bytes) bytes")
        let context = MemoryContext(uid: getuid(), home: NSHomeDirectory(), ownPID: getpid(), now: Date(),
                                    awake: Self.uptime, launchdJobs: nil, keep: settings.keep)
        endHolder(target, runaway: (runawayThreshold, context))
    }

    func dismissRunawayNotice() {
        guard let newest = log.entries.first(where: { $0.kind == .runawayEnded }) else { return }
        runawaySeenThrough = newest.date
        MemoryRunawayNotice.markSeen(newest, in: .standard)
    }

    // MARK: Actions

    /// Ends a leftover group (or a stale MCP server, or shuts a Simulator
    /// clone down) from its row: one click, identity checked before each signal.
    func end(_ finding: MemoryFinding) {
        end(finding, automatic: false, recheck: nil)
    }

    /// The automatic tier and Quit them pass a `requirement`: the group is
    /// judged again from a table read right before the signal, and skipped
    /// when anything changed or cannot be read.
    private func end(_ finding: MemoryFinding, automatic: Bool, recheck requirement: MemoryRecheck?) {
        guard isRunning, finding.canEnd, !busy.contains(finding.id) else { return }
        if finding.helper == .simulatorClone {
            shutDown(finding)
            return
        }
        busy.insert(finding.id)
        busyTargets[finding.id] = finding.identities
        // Brim's own End is logged as an End, not as an exit outside Brim.
        for identity in finding.identities { holderWatches.removeValue(forKey: identity)?.source.cancel() }
        let authority = authority
        let ticket = authority.ticket(automatic ? .automatic : requirement == .idleConfirmed ? .quitThem : .direct)
        let members = finding.members
        let pids = Set(members.map(\.pid))
        let commands = members.filter { !pids.contains($0.ppid) }.compactMap { member in
            member.arguments.map { MemoryActivityEntry.Command(arguments: $0, workingDirectory: member.workingDirectory) }
        }
        let title = MemoryFormat.title(name: finding.name, count: finding.count, project: finding.project)
        let reasons = finding.reasons
        let findingID = finding.id
        let observations = observations
        let context = MemoryContext(uid: getuid(), home: NSHomeDirectory(), ownPID: getpid(), now: Date(),
                                    awake: Self.uptime, launchdJobs: nil, keep: settings.keep)
        actionQueue.async {
            var targets = members.map(\.identity)
            if let requirement {
                var fresh = ProcessTable.snapshot(options: [.arguments, .workingDirectory])
                for index in fresh.indices where fresh[index].pgid == finding.pgid {
                    fresh[index].sockets = ProcessTable.sockets(pid: fresh[index].pid)
                }
                var now = context
                now.now = Date()
                now.awake = Self.uptime
                now.powerAssertions = MemorySystemReads.powerAssertionHolders()
                now.audioActive = MemorySystemReads.audioActive()
                guard let identities = MemoryClassifier.recheck(finding, requirement: requirement, fresh: fresh,
                                                                context: now, observations: observations) else {
                    Self.logger.notice("memory: skipped \(title, privacy: .public): changed since the scan")
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { _ = MemoryService.shared.busy.remove(findingID) }
                    }
                    return
                }
                targets = identities
            }
            let before = MemorySystemReads.measurement()
            var footprints: [ProcessIdentity: UInt64] = [:]
            for member in members {
                footprints[member.identity] = ProcessTable.footprint(pid: member.pid) ?? member.footprint ?? 0
            }
            // Still allowed? Cleanup turned off, Keep changed, the episode
            // closed or the module stopped while this waited in the queue.
            guard authority.isCurrent(ticket) else {
                Self.logger.notice("memory: skipped \(title, privacy: .public): no longer allowed")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { _ = MemoryService.shared.busy.remove(findingID) }
                }
                return
            }
            // Identity (pid + kernel start time) is checked again right
            // before each signal, deepest first; SIGTERM only.
            let results = KillProcessService.signalVerified(targets, force: false)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MemoryService.shared.signalled(results, members: targets, footprints: footprints,
                                                   before: before, findingID: findingID,
                                                   entry: MemoryActivityEntry(date: Date(),
                                                                              kind: automatic ? .autoEnded : .ended,
                                                                              title: title, reasons: reasons,
                                                                              commands: commands))
                }
            }
        }
    }

    /// End on a "Biggest now" row: the person's own process only (never a
    /// system one, never automatic), SIGTERM after the identity check, logged
    /// with measured deltas like any End.
    func endHolder(_ holder: MemoryHolder) {
        endHolder(holder, runaway: nil)
    }

    /// `runaway`: the brake's End (T-52), with its threshold and context.
    /// Right before SIGTERM the process is read fresh and must still be the
    /// same one (pid and kernel start time), one Brim may end and over the
    /// threshold; it is logged as "Ended runaway" with its command line and
    /// footprint, and five seconds later a survivor still over the threshold
    /// gets SIGKILL (forceCheck).
    private func endHolder(_ holder: MemoryHolder, runaway: (threshold: UInt64, context: MemoryContext)?) {
        let key = Self.busyKey(holder)
        guard isRunning, holder.canEnd, !holder.isSystem, !busy.contains(key) else { return }
        busy.insert(key)
        busyTargets[key] = [holder.identity]
        // Brim's own End is logged as an End, not as an exit outside Brim.
        holderWatches.removeValue(forKey: holder.identity)?.source.cancel()
        let identity = holder.identity
        let title = Self.holderTitle(holder)
        let known = holder.memory.footprint ?? 0
        let authority = authority
        let ticket = authority.ticket(runaway == nil ? .direct : .runaway)
        actionQueue.async {
            let before = MemorySystemReads.measurement()
            var entry = MemoryActivityEntry(date: Date(), kind: .ended, title: title, reasons: [])
            var footprints = [identity: ProcessTable.footprint(pid: identity.pid) ?? known]
            if let runaway {
                let fresh = MemoryRunawayBrake.freshRecord(pid: identity.pid)
                guard MemoryRunawayBrake.stillRunaway(identity, fresh: fresh, threshold: runaway.threshold,
                                                      context: runaway.context), let fresh else {
                    Self.logger.notice("memory: skipped runaway \(title, privacy: .public): changed since the read")
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { _ = MemoryService.shared.busy.remove(key) }
                    }
                    return
                }
                let bytes = fresh.footprint ?? known
                footprints[identity] = bytes
                let command = fresh.arguments.map {
                    MemoryActivityEntry.Command(arguments: $0, workingDirectory: fresh.workingDirectory)
                }
                entry = .runaway(holder, bytes: bytes, threshold: runaway.threshold, command: command, at: Date())
            }
            guard authority.isCurrent(ticket) else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { _ = MemoryService.shared.busy.remove(key) }
                }
                return
            }
            let results = KillProcessService.signalVerified([identity], force: false)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MemoryService.shared.signalled(results, members: [identity], footprints: footprints, before: before,
                                                   findingID: key, entry: entry)
                }
            }
        }
    }

    private func signalled(_ results: [pid_t: KillProcessService.VerifiedSignal], members: [ProcessIdentity],
                           footprints: [ProcessIdentity: UInt64], before: MemoryMeasurement?, findingID: String,
                           entry: MemoryActivityEntry) {
        var entry = entry
        // The automatic tier never signals these again while they are
        // listed, nor the runaway brake while they live.
        if entry.kind == .autoEnded || entry.kind == .runawayEnded {
            let tried: [KillProcessService.VerifiedSignal] = [.sent, .refused, .failed]
            let attempted = Set(results.filter { tried.contains($0.value) }.keys)
            if entry.kind == .autoEnded {
                autoSignalled.formUnion(MemoryClassifier.signalledByTier(members, attempted: attempted))
            } else {
                runawaySignalled.formUnion(members.filter { attempted.contains($0.pid) })
            }
        }
        let sent = members.filter { results[$0.pid] == .sent }
        entry.targets = sent
        entry.estimatedBytes = sent.reduce(0) { $0 + (footprints[$1] ?? 0) }
        entry.measuredBefore = before
        if sent.isEmpty {
            entry.outcome = members.allSatisfy({ results[$0.pid] == .gone || results[$0.pid] == .stale })
                ? .nothingToDo : .failed
            busy.remove(findingID)
            // A runaway that ended on its own between the read and the
            // signal is nothing Brim did: no entry, no alert.
            guard entry.kind != .runawayEnded || entry.outcome == .failed else {
                scan(.action)
                return
            }
            log.add(entry)
            saveLog()
            if entry.kind == .runawayEnded { notifyRunaway(entry) }
            // Gone already: one scan updates the lists. A failed signal is
            // left at that (no rescan), so a target kill() cannot reach is
            // never retried in a loop.
            if entry.outcome == .nothingToDo { scan(.action) }
            return
        }
        log.add(entry)
        saveLog()
        if entry.kind == .runawayEnded { notifyRunaway(entry) }
        watches[entry.id] = MemoryActionWatch(findingID: findingID, remaining: Set(sent), footprints: footprints,
                                              before: before)
        // Rule 1 exception, recorded here: a one-shot five seconds after the
        // signal decides whether to offer Force (the runaway brake forces
        // itself then). The exits themselves arrive through process
        // sources; this only looks at who is still left.
        let check = Timer(fire: Date().addingTimeInterval(5), interval: 0, repeats: false) { [id = entry.id] _ in
            MainActor.assumeIsolated { MemoryService.shared.forceCheck(id) }
        }
        RunLoop.main.add(check, forMode: .common)
        forceChecks[entry.id] = check
        for identity in sent { watchExit(identity, entry: entry.id) }
    }

    private func watchExit(_ identity: ProcessIdentity, entry: UUID) {
        exitSources[identity]?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: identity.pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { MemoryService.shared.memberExited(identity, entry: entry) }
        }
        source.resume()
        exitSources[identity] = source
        // One that ended before its source was armed raises no event: one
        // look now settles it.
        if !ProcessTable.isAlive(identity) { memberExited(identity, entry: entry) }
    }

    private func memberExited(_ identity: ProcessIdentity, entry id: UUID) {
        exitSources.removeValue(forKey: identity)?.cancel()
        guard var watch = watches[id], watch.exit(identity) else { return }
        watches[id] = watch
        guard watch.isComplete else { return }
        forceChecks.removeValue(forKey: id)?.invalidate()
        watches[id] = nil
        let estimated = watch.estimatedFreed
        let after = MemorySystemReads.measurement()
        log.update(id) { entry in
            entry.outcome = .done
            entry.survivors = []
            entry.estimatedFreed = estimated
            entry.measuredAfter = after
        }
        saveLog()
        if let findingID = watch.findingID { busy.remove(findingID) }
        Self.logger.notice("memory: ended \(watch.exited.count) processes, est. \(estimated) bytes")
        scan(.action)
    }

    private func forceCheck(_ id: UUID) {
        guard let watch = watches[id] else { return }
        let survivors = watch.remaining.filter(ProcessTable.isAlive)
        for gone in watch.remaining.subtracting(survivors) { memberExited(gone, entry: id) }
        guard !survivors.isEmpty, watches[id] != nil else { return }
        forceChecks[id] = nil
        log.update(id) { entry in
            entry.outcome = .stillRunning
            entry.survivors = Array(survivors)
        }
        saveLog()
        if let findingID = watch.findingID { busy.remove(findingID) }
        // The brake does not wait for a click: a runaway still running five
        // seconds after SIGTERM gets SIGKILL, if it is still the same
        // process, still one Brim may end and still over the threshold.
        if let entry = log.entry(id), entry.kind == .runawayEnded, let threshold = entry.runawayThreshold {
            let context = MemoryContext(uid: getuid(), home: NSHomeDirectory(), ownPID: getpid(), now: Date(),
                                        awake: Self.uptime, launchdJobs: nil, keep: settings.keep)
            force(id, runaway: (threshold, context))
        }
    }

    /// The log entry whose processes are still running five seconds after
    /// SIGTERM, for a finding's row.
    func stillRunningEntry(for finding: MemoryFinding) -> MemoryActivityEntry? {
        let identities = Set(finding.identities)
        return log.entries.first { $0.outcome == .stillRunning && !identities.isDisjoint(with: $0.survivors) }
    }

    /// Force: SIGKILL for whoever is still running, identity checked again.
    /// The watch that completes the entry is in place before the signal,
    /// also after Brim restarted, when the first signal's watch is gone.
    func force(_ entryID: UUID) {
        force(entryID, runaway: nil)
    }

    /// `runaway`: the brake's own SIGKILL five seconds after its SIGTERM.
    /// The entry stays its runaway entry (marked forced), and each survivor
    /// is read fresh right before the signal: one no longer the same
    /// process, no longer one Brim may end or no longer over the threshold
    /// is left for the person's Force.
    private func force(_ entryID: UUID, runaway: (threshold: UInt64, context: MemoryContext)?) {
        guard let entry = log.entry(entryID), entry.outcome == .stillRunning, !entry.survivors.isEmpty else { return }
        let listed = entry.survivors
        log.update(entryID) { entry in
            // A runaway's entry stays one, forced by the brake or a click.
            if entry.kind == .runawayEnded { entry.forced = true } else { entry.kind = .forced }
            entry.outcome = .pending
        }
        var footprints: [ProcessIdentity: UInt64] = [:]
        for identity in listed { footprints[identity] = ProcessTable.footprint(pid: identity.pid) }
        watches[entryID] = MemoryActionWatch.forForce(existing: watches[entryID], survivors: listed,
                                                      footprints: footprints, before: entry.measuredBefore)
        let authority = authority
        let ticket = authority.ticket(runaway == nil ? .direct : .runaway)
        actionQueue.async {
            let survivors = runaway.map { check in
                listed.filter { identity in
                    MemoryRunawayBrake.stillRunaway(identity, fresh: MemoryRunawayBrake.freshRecord(pid: identity.pid),
                                                    threshold: check.threshold, context: check.context)
                }
            } ?? listed
            // Only stopping the module cancels a click; the survivors' watch
            // then completes or the entry stays still running.
            let results = authority.isCurrent(ticket) ? KillProcessService.signalVerified(survivors, force: true) : [:]
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let service = MemoryService.shared
                    let failed = survivors.contains { results[$0.pid] == .failed || results[$0.pid] == .refused }
                    if failed {
                        service.log.update(entryID) { $0.outcome = .failed }
                    } else if runaway != nil, service.log.entry(entryID)?.outcome == .pending,
                              !survivors.contains(where: { results[$0.pid] == .sent }) {
                        // Nothing was forced and nothing has exited since:
                        // still running, for the person to decide.
                        Self.logger.notice("memory: no SIGKILL for runaway \(entryID, privacy: .public): changed since SIGTERM")
                        service.log.update(entryID) { $0.forced = nil; $0.outcome = .stillRunning }
                    }
                    for identity in listed where service.exitSources[identity] == nil {
                        service.watchExit(identity, entry: entryID)
                    }
                    service.saveLog()
                }
            }
        }
    }

    /// Quit (the app's own terminate, as from its menu), through Kill
    /// Process's safe path; the row stays until the app really ends. The
    /// app's footprint (it plus what it is responsible for) and the whole
    /// Mac are read fresh at the click, not taken from the last scan.
    func quit(_ row: MemoryIdleAppRow) {
        guard isRunning, quitting[row.app.pid] == nil, let startedAt = row.app.startedAt else { return }
        var entry = MemoryActivityEntry(date: Date(), kind: .quitApp, title: row.app.name, reasons: [])
        entry.bundleURL = row.app.bundleURL
        entry.targets = [ProcessIdentity(pid: row.app.pid, startedAt: startedAt)]
        quitting[row.app.pid] = entry.id
        quitApps.insert(row.app.pid)
        // The app's exit, and its helpers', are Brim's Quit, not exits outside Brim.
        for (identity, watch) in holderWatches where identity.pid == row.app.pid || watch.owner == row.app.pid {
            watch.source.cancel()
            holderWatches[identity] = nil
        }
        refreshIdleApps()
        let pid = row.app.pid
        let name = row.app.name
        let fallback = row.app.footprint
        actionQueue.async {
            let before = MemorySystemReads.measurement()
            var footprint: UInt64 = 0
            for record in ProcessTable.snapshot() where !record.restricted {
                if record.pid == pid || ResponsibleProcess.owner(of: record.pid) == pid { footprint += record.footprint ?? 0 }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let service = MemoryService.shared
                    entry.estimatedBytes = footprint > 0 ? footprint : fallback
                    entry.measuredBefore = before
                    service.log.add(entry)
                    service.saveLog()
                    KillProcessService.shared.kill(pid: pid, name: name, startedAt: startedAt, force: false)
                }
            }
        }
    }

    /// Reopen a quit app.
    func reopen(_ entryID: UUID) {
        guard let url = log.entry(entryID)?.bundleURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Shuts down a Simulator clone a finished test plan left booted. Never
    /// while an `xcodebuild test` runs: that test plan owns its clones.
    private func shutDown(_ finding: MemoryFinding) {
        guard let udid = finding.simulatorUDID, !testRunActive else { return }
        busy.insert(finding.id)
        let findingID = finding.id
        var entry = MemoryActivityEntry(date: Date(), kind: .shutDownSimulator,
                                        title: "Simulator " + String(udid.prefix(8)), reasons: [])
        entry.estimatedBytes = finding.footprint
        actionQueue.async {
            // Checked again at the click: a test plan started since the scan
            // owns the clones again.
            let driverAlive = ProcessTable.snapshot(options: [.arguments]).contains(where: MemoryRules.isXcodeTestDriver)
            let before = MemorySystemReads.measurement()
            let status = driverAlive ? -1 : Shell.run("/usr/bin/xcrun", ["simctl", "--set", "testing", "shutdown", udid],
                                                     timeout: 60).status
            let after = status == 0 ? MemorySystemReads.measurement() : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let service = MemoryService.shared
                    entry.outcome = status == 0 ? .done : .failed
                    entry.measuredBefore = before
                    entry.measuredAfter = after
                    if status == 0 { entry.estimatedFreed = entry.estimatedBytes }
                    service.log.add(entry)
                    service.saveLog()
                    service.busy.remove(findingID)
                    service.scan(.action)
                }
            }
        }
    }

    /// Adds a finding's executable (or an app's bundle id) to the Keep list.
    func keep(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = settings.keep
        guard !list.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        list.append(trimmed)
        UserDefaults.standard.set(list, forKey: DefaultsKey.memoryKeepList)
        reloadSettings()
    }

    func removeFromKeep(_ entry: String) {
        let list = settings.keep.filter { $0 != entry }
        UserDefaults.standard.set(list, forKey: DefaultsKey.memoryKeepList)
        reloadSettings()
    }

    // MARK: Notification

    /// The one memory notification path: (1) once per memory-tight episode,
    /// naming what holds the memory; (2) the fseventsd leak outside an
    /// episode, once per fseventsd identity, remembered across launches.
    private func postNotifications() {
        let text = FeatureStrings.memory(L10n.shared.language)
        let apps = idleApps.filter { !$0.quitting }
        let leftovers = MemoryClassifier.quitThemTargets(findings)
        let counts = apps.isEmpty && leftovers.isEmpty ? nil
            : text.notificationBody(apps: apps.count, hours: settings.idleHours,
                                    appsSize: MemoryFormat.bytes(apps.reduce(0) { $0 + $1.app.footprint }),
                                    leftovers: leftovers.count,
                                    leftoversSize: MemoryFormat.bytes(leftovers.reduce(0) { $0 + $1.footprint }))
        let decided = MemoryNotifications.plan(episodeNotifies: episode.shouldNotify(), critical: episode.isCritical,
                                               holders: holders, counts: counts,
                                               canQuitSomething: !apps.isEmpty || !leftovers.isEmpty,
                                               notifiedLeak: UserDefaults.standard.string(forKey: DefaultsKey.memoryNotifiedLeak),
                                               text: text)
        if let leak = decided.leakToMark {
            UserDefaults.standard.set(MemoryNotifications.leakKey(leak), forKey: DefaultsKey.memoryNotifiedLeak)
        }
        guard let plan = decided.plan else { return }
        deliver(plan, text: text)
    }

    /// (3) The runaway brake acted: its own notification, besides the
    /// episode's, naming what it ended (or could not).
    private func notifyRunaway(_ entry: MemoryActivityEntry) {
        guard settings.notify else { return }
        let text = FeatureStrings.memory(L10n.shared.language)
        deliver(MemoryNotifications.runaway(entry, text: text), text: text)
    }

    /// Posts a plan. One the system does not show (notifications off or
    /// never allowed) is recorded in the Activity log, so a missed alert
    /// can be read later (T-52: a night of alerts went nowhere).
    private func deliver(_ plan: MemoryNotificationPlan, text: MemoryStrings) {
        let actions = plan.actions.map { action -> UNNotificationAction in
            switch action {
            case .quitThem: return UNNotificationAction(identifier: Self.quitThemAction, title: text.quitThem, options: [])
            case .review: return UNNotificationAction(identifier: Self.reviewAction, title: text.review, options: [.foreground])
            case .copyRestart:
                return UNNotificationAction(identifier: Self.copyRestartAction, title: text.copyRestartCommand, options: [])
            }
        }
        let category = plan.kind == .episode ? Self.categoryIdentifier : Self.holderCategoryIdentifier
        Notifier.post(title: plan.title, body: plan.body,
                      category: UNNotificationCategory(identifier: category, actions: actions,
                                                       intentIdentifiers: [], options: [])) { delivery in
            guard case .dropped = delivery else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MemoryService.shared.alertNotShown(plan, text: text) }
            }
        }
    }

    private func alertNotShown(_ plan: MemoryNotificationPlan, text: MemoryStrings) {
        guard isRunning else { return }
        log.add(.alertNotShown(title: plan.title, body: plan.body, text: text, at: Date()))
        saveLog()
    }

    private func notificationAction(_ action: String) {
        switch action {
        case Self.quitThemAction: quitThem()
        case Self.copyRestartAction: Self.copyRestartCommand()
        case Self.reviewAction, UNNotificationDefaultActionIdentifier: review()
        default: break
        }
    }

    /// Copies `sudo killall fseventsd` for the person to run in Terminal.
    /// Brim never runs it: it has no root and never asks for it.
    static func copyRestartCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MemoryRules.fseventsdRestartCommand, forType: .string)
    }

    /// The notification's Quit them: nothing is quit or ended at the click.
    /// A scan starts, and the scan begun after the click quits the idle apps
    /// it recomputed and ends the leftover groups it confirms idle
    /// (`quitThemTargets`), each judged again right before its signal.
    /// Busy, measuring and uncertain groups are ended only from their own rows.
    func quitThem() {
        guard isRunning else { return }
        quitThemAfterScan = scanGeneration
        scan(.action)
    }

    func review() {
        SettingsRouter.shared.page = .memory
        appDelegate()?.openSettingsWindow()
    }

    // MARK: Log

    private static var logURL: URL? {
        PrivateFileStore.containerURL?.appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("activity.json")
    }

    /// Owner-only: the log keeps command lines and folders.
    private func saveLog() {
        guard let url = Self.logURL, let data = log.encoded() else { return }
        PrivateFileStore.createDirectory(at: url.deletingLastPathComponent())
        PrivateFileStore.write(data, to: url)
    }
}
