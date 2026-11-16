// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

// MARK: Settings

extension DefaultsKey {
    /// The automatic tier (orphaned dev groups only). Read with its default,
    /// on, so it needs no registration.
    static let memoryAutoClean = "brimMemoryAutoClean"
    /// Hours an app goes unused before it counts as idle (1–48, default 8).
    static let memoryIdleHours = "brimMemoryIdleHours"
    /// Executable names, path prefixes or bundle ids the module never touches.
    static let memoryKeepList = "brimMemoryKeepList"
    /// The notification when memory gets tight (registered on).
    static let memoryNotify = "brimMemoryNotify"
    /// The fseventsd identity ("pid:startedAt") the leak notification was
    /// posted for, so a relaunch of Brim does not post it again.
    static let memoryNotifiedLeak = "brimMemoryNotifiedLeak"
    /// The running `log stream` child ("pid:startedAt"), so a Brim that
    /// crashed can end its leftover child on the next start.
    static let memoryLogChild = "brimMemoryLogChild"
    /// Whether the menu panel shows the Memory section (shown by default).
    static let panelShowMemory = "panelShowMemory"
}

/// The module's settings, read from defaults with their defaults applied.
struct MemorySettings: Equatable {
    var autoClean = true
    var idleHours = 8
    var keep: [String] = []
    var notify = true

    static let idleHoursRange = 1...48

    init() {}

    init(_ defaults: UserDefaults) {
        autoClean = defaults.object(forKey: DefaultsKey.memoryAutoClean) as? Bool ?? true
        idleHours = Self.sanitizedIdleHours(defaults.object(forKey: DefaultsKey.memoryIdleHours) as? Int)
        keep = (defaults.stringArray(forKey: DefaultsKey.memoryKeepList) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        notify = defaults.object(forKey: DefaultsKey.memoryNotify) as? Bool ?? true
    }

    static func sanitizedIdleHours(_ value: Int?) -> Int {
        guard let value else { return 8 }
        return min(max(value, idleHoursRange.lowerBound), idleHoursRange.upperBound)
    }
}

// MARK: Activity clock

/// A clock that runs only while the Mac is awake and unlocked, so an app's
/// idle time never counts a night asleep or an hour behind the lock screen.
/// Readings are seconds; time comes from the caller (the system uptime).
struct MemoryActivityClock: Equatable {
    enum Pause: Hashable { case asleep, locked }

    private(set) var accumulated: TimeInterval = 0
    private(set) var runningSince: TimeInterval?
    private(set) var pauses: Set<Pause> = []

    init(startingAt time: TimeInterval) { runningSince = time }

    var isPaused: Bool { runningSince == nil }

    func reading(at time: TimeInterval) -> TimeInterval {
        guard let runningSince else { return accumulated }
        return accumulated + max(0, time - runningSince)
    }

    mutating func pause(_ reason: Pause, at time: TimeInterval) {
        if let runningSince { accumulated += max(0, time - runningSince) }
        runningSince = nil
        pauses.insert(reason)
    }

    mutating func resume(_ reason: Pause, at time: TimeInterval) {
        pauses.remove(reason)
        if pauses.isEmpty, runningSince == nil { runningSince = time }
    }
}

// MARK: Idle apps

/// A running regular app as the idle rules see it.
struct MemoryApp: Equatable, Identifiable {
    var pid: pid_t
    var startedAt: UInt64?
    var bundleID: String?
    var name: String
    var bundleURL: URL?
    var isActive: Bool
    /// The app plus every process it is responsible for.
    var footprint: UInt64
    /// The activity clock's reading when it was last frontmost (or launched).
    var lastUsed: TimeInterval
    /// One of its processes has audio running.
    var playingAudio = false
    /// It holds a power assertion.
    var holdsAssertion = false

    var id: pid_t { pid }
}

enum MemoryIdleApps {
    /// Apps smaller than this are not worth a row.
    static let heavyFloor: UInt64 = 200 << 20

    /// Apps never offered for quitting: Finder, terminals, IDEs, agents,
    /// containers and virtual machines, and Brim itself.
    static func isProtected(bundleID: String?, ownBundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased() else { return true }
        if let own = ownBundleID?.lowercased(), bundleID == own || bundleID.hasPrefix(own + ".") { return true }
        let exact: Set<String> = [
            "com.apple.finder", "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable",
            "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
            "com.apple.dt.xcode", "com.microsoft.vscode", "com.microsoft.vscodeinsiders",
            "com.todesktop.230313mzl4w4u92", "dev.zed.zed", "com.google.android.studio",
            "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex",
            "com.docker.docker", "dev.kdrag0n.macvirt", "com.utmapp.utm", "com.parallels.desktop.console",
            "com.vmware.fusion", "com.apple.iphonesimulator", "com.apple.systempreferences",
            "com.apple.mobilephone", "com.apple.facetime",
        ]
        return exact.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }

    /// Heavy and idle: unused for at least `threshold` seconds on the activity
    /// clock, not frontmost, not playing audio or holding a power assertion,
    /// not protected or kept, and at least `heavyFloor`. Largest first.
    static func heavyIdle(_ apps: [MemoryApp], clock: TimeInterval, threshold: TimeInterval,
                          keep: [String], ownBundleID: String?) -> [MemoryApp] {
        let kept = Set(keep.map { $0.lowercased() })
        return apps.filter { app in
            !app.isActive && !app.playingAudio && !app.holdsAssertion
                && app.footprint >= heavyFloor
                && clock - app.lastUsed >= threshold
                && !isProtected(bundleID: app.bundleID, ownBundleID: ownBundleID)
                && !kept.contains(app.bundleID?.lowercased() ?? "") && !kept.contains(app.name.lowercased())
        }
        .sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.pid < $1.pid }
    }
}

// MARK: Whole-Mac measurements and memory-tight episodes

/// One reading of the whole Mac's memory, taken on an event, never on a timer.
struct MemoryMeasurement: Codable, Equatable {
    /// Wall clock.
    var at: Date
    /// System uptime (the awake clock: it stops while the Mac sleeps).
    var awake: TimeInterval
    var used: UInt64
    /// Compressor pages × page size: the RAM the compressor occupies.
    var compressorRAM: UInt64
    /// total_uncompressed_pages_in_compressor × page size: what it holds.
    var compressedLogical: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    /// Cumulative bytes since boot (pages × page size).
    var swapOuts: UInt64
    var swapIns: UInt64
}

extension MemoryMeasurement {
    /// A measurement from its reads, nil when any of them failed. An unread
    /// swap is unknown, never 0 (review fix, T-42): a 0 that set the
    /// episode's first baseline made the next real reading look as if every
    /// byte of old swap had just been added, opening a memory-tight episode
    /// (and with it the automatic tier) from nothing, and it made false
    /// measured changes. No reading is better than a wrong one: the episode
    /// and the measured deltas skip it.
    static func reading(stats: VMStatisticsSnapshot?, used: UInt64?, total: UInt64?, compressorRAM: UInt64?,
                        swap: (used: UInt64, total: UInt64)?, page: UInt64, at: Date,
                        awake: TimeInterval) -> MemoryMeasurement? {
        guard let stats, let used, let total, total > 0, let compressorRAM, let swap else { return nil }
        return MemoryMeasurement(at: at, awake: awake, used: used, compressorRAM: compressorRAM,
                                 compressedLogical: stats.uncompressedPagesInCompressor &* page,
                                 swapUsed: swap.used, swapTotal: swap.total,
                                 swapOuts: stats.swapOuts &* page, swapIns: stats.swapIns &* page)
    }
}

/// The whole Mac's change between two measurements: "system change during
/// this interval", which other apps' work counts in too. Never "savings".
struct MemoryMeasuredChange: Equatable {
    var used: Int64
    var compressorRAM: Int64
    var swapUsed: Int64
    /// Bytes swapped out during the interval.
    var swapOuts: UInt64

    init(from before: MemoryMeasurement, to after: MemoryMeasurement) {
        used = Int64(clamping: after.used) - Int64(clamping: before.used)
        compressorRAM = Int64(clamping: after.compressorRAM) - Int64(clamping: before.compressorRAM)
        swapUsed = Int64(clamping: after.swapUsed) - Int64(clamping: before.swapUsed)
        swapOuts = after.swapOuts >= before.swapOuts ? after.swapOuts - before.swapOuts : 0
    }

    /// A SystemMonitor reading (taken for the panel, notch or menu bar,
    /// never started by this module) worth a scan: swap up 1 GiB or the
    /// compressor up 2 GiB since the module's own last measurement.
    static func monitorReadingWarrantsScan(swapUsed: UInt64?, compressed: UInt64?, last: MemoryMeasurement?) -> Bool {
        guard let last else { return false }
        if let swapUsed, swapUsed >= last.swapUsed &+ (1 << 30) { return true }
        if let compressed, compressed >= last.compressorRAM &+ (2 << 30) { return true }
        return false
    }
}

struct MemoryEpisodeThresholds: Equatable {
    /// macOS adds swap in 1 GiB swapfiles: one new file is the step.
    var swapGrowth: UInt64 = 1 << 30
    /// Live swap-outs: at least this rate (bytes per awake second) …
    var liveSwapOutRate: UInt64 = 1 << 20
    /// … and at least this much, between readings at most this far apart.
    var liveSwapOutMinimum: UInt64 = 64 << 20
    var liveSwapOutMaxGap: TimeInterval = 15 * 60
    /// Calm: under this many bytes swapped out across `calmSpan` awake.
    var calmSwapOuts: UInt64 = 16 << 20
    var calmSpan: TimeInterval = 10 * 60
}

/// Whether memory is tight right now: the only time the automatic tier acts
/// (decided 2026-11-14) and the span one notification covers. Opens on
/// kernel pressure above normal, swap used 1 GiB above the last calm
/// baseline, or live swap-outs; closes when pressure is normal and two
/// readings `calmSpan` apart show swap flat and under `calmSwapOuts` out,
/// and then the baseline moves to the swap used now. The first reading sets
/// the baseline, so swap left over from earlier (8.7 GB on this Mac when it
/// was written) opens nothing.
struct MemoryTightEpisode: Equatable {
    /// The kernel's pressure level as the episode reads it (MemoryService
    /// maps MemoryPressure onto it; an unknown read counts as normal).
    enum Pressure: Equatable { case normal, warning, critical }
    enum Cause: Equatable { case pressure(Pressure), swapGrowth(UInt64), swapOuts(bytesPerSecond: UInt64) }
    enum Change: Equatable { case opened(Cause), closed, unchanged }

    var thresholds = MemoryEpisodeThresholds()
    /// nil: not tight.
    private(set) var cause: Cause?
    private(set) var notified = false
    /// Swap used at the last calm reading (stale swap is not an episode).
    private(set) var swapBaseline: UInt64?
    private(set) var last: MemoryMeasurement?
    private(set) var calmSince: MemoryMeasurement?
    private(set) var pressure: Pressure = .normal

    var isTight: Bool { cause != nil }
    var isCritical: Bool { pressure == .critical }

    mutating func update(pressure: Pressure, reading: MemoryMeasurement?) -> Change {
        self.pressure = pressure
        defer { if let reading { last = reading } }
        if let reading, swapBaseline == nil { swapBaseline = reading.swapUsed }
        if pressure != .normal {
            calmSince = nil
            let wasTight = isTight
            cause = .pressure(pressure)
            return wasTight ? .unchanged : .opened(.pressure(pressure))
        }
        if isTight {
            guard let reading else { return .unchanged }
            guard let calm = calmSince, reading.swapUsed <= calm.swapUsed,
                  reading.swapOuts >= calm.swapOuts, reading.swapOuts - calm.swapOuts < thresholds.calmSwapOuts else {
                calmSince = reading
                return .unchanged
            }
            guard reading.awake - calm.awake >= thresholds.calmSpan else { return .unchanged }
            cause = nil
            notified = false
            calmSince = nil
            swapBaseline = reading.swapUsed
            return .closed
        }
        guard let reading, let opening = opening(reading) else { return .unchanged }
        cause = opening
        calmSince = nil
        return .opened(opening)
    }

    /// Once per episode.
    mutating func shouldNotify() -> Bool {
        guard isTight, !notified else { return false }
        notified = true
        return true
    }

    private func opening(_ reading: MemoryMeasurement) -> Cause? {
        if let baseline = swapBaseline, reading.swapUsed >= baseline &+ thresholds.swapGrowth {
            return .swapGrowth(reading.swapUsed - baseline)
        }
        guard let last, reading.awake > last.awake, reading.awake - last.awake <= thresholds.liveSwapOutMaxGap,
              reading.swapOuts >= last.swapOuts else { return nil }
        let swapped = reading.swapOuts - last.swapOuts
        let rate = UInt64(Double(swapped) / (reading.awake - last.awake))
        guard swapped >= thresholds.liveSwapOutMinimum, rate >= thresholds.liveSwapOutRate else { return nil }
        return .swapOuts(bytesPerSecond: rate)
    }
}

// MARK: What holds the memory

struct MemoryHolderThresholds: Equatable {
    var listCount = 5
    /// ≈ 2× fseventsd's 8.5-day healthy peak (133 MB); healthy now ~4 MB.
    var systemListFloor: UInt64 = 256 << 20
    /// 54 GB incident; 133 MB peak in 8.5 healthy days → no false alarm.
    var fseventsdLeak: UInt64 = 1 << 30
    /// Identities kept in history.
    var trackFloor: UInt64 = 256 << 20
    /// Own process: big …
    var ownGrowingFloor: UInt64 = 8 << 30
    /// … and +2 GB since an earlier sample.
    var growingGain: UInt64 = 2 << 30
    /// Samples at least this far apart before a rate is shown.
    var minSpan: TimeInterval = 15 * 60
    /// Tracked holders whose exit is recorded with measured deltas.
    var exitWatchFloor: UInt64 = 1 << 30
    /// Samples older than this are dropped: a rate is the growth over the
    /// last two days, not since a healthy reading a week ago.
    var window: TimeInterval = 48 * 3600
}

/// One row of "Biggest now".
struct MemoryHolder: Identifiable, Equatable {
    enum Kind: Equatable { case own(project: String?, inAgentSession: MemoryRules.Agent?), system }
    var identity: ProcessIdentity
    var name: String
    var path: String
    var kind: Kind
    /// `.unknown` rows are never ranked as 0.
    var memory: ProcessMemory
    /// Growth rate over the history window, wall clock; set while growing.
    var perHour: UInt64?
    var growing: Bool
    /// fseventsd at or above `fseventsdLeak`.
    var isFSEventsLeak: Bool
    /// fseventsd at all (its row carries the restart note and Copy).
    var isFSEvents: Bool
    /// Own, not an app's or the system's executable, not protected, an
    /// agent, an IDE, a terminal, kept, or Brim: one click, never automatic.
    var canEnd: Bool
    var id: ProcessIdentity { identity }

    var isSystem: Bool { kind == .system }
    var bytes: UInt64 { memory.bytes ?? 0 }
    var project: String? {
        if case .own(let project, _) = kind { return project }
        return nil
    }
    var agent: MemoryRules.Agent? {
        if case .own(_, let agent) = kind { return agent }
        return nil
    }
}

/// Samples of big holders, by pid + start time: at most 8 each, none older
/// than the window, and an identity's series dropped when it is gone.
struct MemoryHolderHistory: Equatable {
    struct Sample: Equatable { var at: Date; var bytes: UInt64 }
    static let samplesPerIdentity = 8
    private(set) var samples: [ProcessIdentity: [Sample]] = [:]

    func isTracked(_ identity: ProcessIdentity) -> Bool { samples[identity] != nil }

    mutating func record(_ holders: [(ProcessIdentity, UInt64)], at: Date, thresholds: MemoryHolderThresholds) {
        let present = Set(holders.map(\.0))
        samples = samples.filter { present.contains($0.key) }
        for (identity, bytes) in holders {
            var series = (samples[identity] ?? []).filter { at.timeIntervalSince($0.at) <= thresholds.window && $0.at < at }
            series.append(Sample(at: at, bytes: bytes))
            if series.count > Self.samplesPerIdentity {
                // Keep the oldest (the rate's start) and the newest ones.
                series = [series[0]] + series.suffix(Self.samplesPerIdentity - 1)
            }
            samples[identity] = series
        }
    }

    /// Growth from the oldest sample in the window to the newest, when they
    /// are at least `minSpan` apart: per hour, in total, and since when.
    func rate(of identity: ProcessIdentity, thresholds: MemoryHolderThresholds) -> (perHour: UInt64, gained: UInt64, since: Date)? {
        guard let series = samples[identity], let first = series.first, let last = series.last,
              last.at.timeIntervalSince(first.at) >= thresholds.minSpan else { return nil }
        let gained = last.bytes > first.bytes ? last.bytes - first.bytes : 0
        let hours = last.at.timeIntervalSince(first.at) / 3600
        return (UInt64(Double(gained) / hours), gained, first.at)
    }
}

enum MemoryHolders {
    /// Top `listCount` by size among own processes and measured system rows
    /// (system rows at `systemListFloor` or more), plus every growing row and
    /// the fseventsd row when ≥ systemListFloor; fseventsd first when it is
    /// the leak. A row whose memory is unknown is never ranked.
    static func rank(_ records: [ProcessRecord], context: MemoryContext, history: inout MemoryHolderHistory,
                     now: Date, thresholds: MemoryHolderThresholds) -> [MemoryHolder] {
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let measured = records.filter { record in
            guard let bytes = record.memory.bytes, bytes > 0 else { return false }
            return record.restricted || record.uid == context.uid
        }
        let tracked = measured.filter { record in
            (record.memory.bytes ?? 0) >= thresholds.trackFloor || history.isTracked(record.identity)
                || MemoryRules.isFSEventsDaemon(record)
        }
        history.record(tracked.map { ($0.identity, $0.memory.bytes ?? 0) }, at: now, thresholds: thresholds)

        let holders = measured.map { holder($0, byPID: byPID, context: context, history: history, thresholds: thresholds) }
        let listable = holders.filter { !$0.isSystem || $0.bytes >= thresholds.systemListFloor }
        let top = listable.sorted(by: larger).prefix(thresholds.listCount)
        var chosen = Set(top.map(\.identity))
        for holder in listable where holder.growing || (holder.isFSEvents && holder.bytes >= thresholds.systemListFloor) {
            chosen.insert(holder.identity)
        }
        return listable.filter { chosen.contains($0.identity) }.sorted { left, right in
            if left.isFSEventsLeak != right.isFSEventsLeak { return left.isFSEventsLeak }
            return larger(left, right)
        }
    }

    private static func larger(_ left: MemoryHolder, _ right: MemoryHolder) -> Bool {
        left.bytes != right.bytes ? left.bytes > right.bytes : left.identity.pid < right.identity.pid
    }

    /// One process as a "Biggest now" row (the runaway brake's read judges
    /// its processes the same way).
    static func holder(_ record: ProcessRecord, byPID: [pid_t: ProcessRecord], context: MemoryContext,
                       history: MemoryHolderHistory, thresholds: MemoryHolderThresholds) -> MemoryHolder {
        let bytes = record.memory.bytes ?? 0
        let isFSEvents = MemoryRules.isFSEventsDaemon(record)
        let rate = history.rate(of: record.identity, thresholds: thresholds)
        let growing: Bool
        if record.restricted {
            growing = (rate?.gained ?? 0) >= thresholds.trackFloor
        } else {
            growing = bytes >= thresholds.ownGrowingFloor && (rate?.gained ?? 0) >= thresholds.growingGain
        }
        let kind: MemoryHolder.Kind
        if record.restricted {
            kind = .system
        } else {
            let session = agentSession(of: record, byPID: byPID)
            let project = session.map { agent in
                agent.workingDirectory.flatMap { $0 == context.home || $0 == "/" ? nil : ($0 as NSString).lastPathComponent }
            } ?? MemoryRules.projectHint(record, home: context.home)
            kind = .own(project: project, inAgentSession: session.flatMap(MemoryRules.agentKind))
        }
        return MemoryHolder(identity: record.identity, name: record.executableName, path: record.path, kind: kind,
                            memory: record.memory, perHour: growing ? rate?.perHour : nil, growing: growing,
                            isFSEventsLeak: isFSEvents && (record.memory.footprint ?? 0) >= thresholds.fseventsdLeak,
                            isFSEvents: isFSEvents, canEnd: canEnd(record, context: context))
    }

    /// The agent CLI (Claude Code, Codex) this process runs under, found by
    /// walking its parents: what labels node 39207 "in a Claude session".
    static func agentSession(of record: ProcessRecord, byPID: [pid_t: ProcessRecord]) -> ProcessRecord? {
        var current = record
        var seen: Set<pid_t> = [record.pid]
        while let parent = byPID[current.ppid], parent.pid > 1, seen.insert(parent.pid).inserted, seen.count < 64 {
            if !parent.restricted, MemoryRules.agentKind(parent) != nil { return parent }
            current = parent
        }
        return nil
    }

    /// Whether Brim offers End for this process (and the runaway brake may
    /// end it): own, not Brim, not an app's or the system's executable, not
    /// protected, an agent, an IDE, a terminal, kept or self-daemonizing.
    static func canEnd(_ record: ProcessRecord, context: MemoryContext) -> Bool {
        guard !record.restricted, record.uid == context.uid, record.pid != context.ownPID, record.pid > 1,
              record.startedAt > 0, record.footprint != nil, !record.path.isEmpty else { return false }
        return !MemoryRules.isAppOrSystemExecutable(record) && !MemoryRules.isSystemProtected(record)
            && !MemoryRules.isProtectedTool(record) && !MemoryRules.isTerminalShell(record)
            && !MemoryRules.isKept(record, keep: context.keep) && !MemoryRules.isSelfDaemonizingTool(record)
            && !MemoryRules.isIntentionalDaemonizer(record) && !MemoryRules.isXcodeTestDriver(record)
    }
}

/// The growth follow-up: when no event reports a process's memory growing
/// while swap and pressure stay quiet, one scan after 10 min, then 20, 40
/// and 60 while the elevated holder grows less than 256 MB between them,
/// back to 10 when it grows more. Nothing elevated, or the Mac asleep or
/// locked: none. It rides the module's one one-shot deadline timer.
struct MemoryFollowUp: Equatable {
    static let first: TimeInterval = 10 * 60
    static let longest: TimeInterval = 60 * 60
    private(set) var interval: TimeInterval?

    mutating func next(after reading: Date, elevated: Bool, grew: Bool, clockPaused: Bool) -> Date? {
        guard elevated, !clockPaused else {
            interval = nil
            return nil
        }
        if grew || interval == nil {
            interval = Self.first
        } else {
            interval = min((interval ?? Self.first) * 2, Self.longest)
        }
        return reading.addingTimeInterval(interval ?? Self.first)
    }
}

/// When a stopped helper may start again: after 1 min, doubling to 30 min
/// per exit, reset once it has stayed up an hour. Event-driven: the caller
/// asks at its own events, nothing waits on a timer.
struct MemoryRestartBackoff: Equatable {
    static let shortest: TimeInterval = 60
    static let longest: TimeInterval = 30 * 60
    static let healthyRun: TimeInterval = 3600
    private(set) var delay: TimeInterval = shortest
    private(set) var notBefore: TimeInterval = 0
    private(set) var startedAt: TimeInterval?

    func mayStart(at now: TimeInterval) -> Bool { startedAt == nil && now >= notBefore }

    mutating func started(at now: TimeInterval) { startedAt = now }

    mutating func exited(at now: TimeInterval) {
        if let startedAt, now - startedAt >= Self.healthyRun { delay = Self.shortest }
        startedAt = nil
        notBefore = now + delay
        delay = min(delay * 2, Self.longest)
    }
}

// MARK: Scan cost

/// What one scan cost, measured: the Settings line and the log line.
struct MemoryScanCost: Equatable {
    var at: Date
    var duration: TimeInterval
    var processes: Int
    var own: Int
    var systemMeasured: Int
    var unknown: Int
    var socketTables: Int
    var launchctlRan: Bool
    /// The `log stream` child's CPU time so far, when it runs.
    var logChildCPU: TimeInterval?

    init(at: Date, duration: TimeInterval, records: [ProcessRecord], ownUID: uid_t, socketTables: Int,
         launchctlRan: Bool, logChildCPU: TimeInterval?) {
        self.at = at
        self.duration = duration
        processes = records.count
        own = records.filter { !$0.restricted && $0.uid == ownUID }.count
        systemMeasured = records.filter { $0.restricted && $0.memory.bytes != nil }.count
        unknown = records.filter { $0.memory == .unknown }.count
        self.socketTables = socketTables
        self.launchctlRan = launchctlRan
        self.logChildCPU = logChildCPU
    }

    /// "memory scan (swap): 1622 processes (805 own, 402 system measured,
    /// 415 unknown), 31 socket tables, launchctl skipped, 182 ms, log child cpu 0.4 s"
    func logLine(trigger: String) -> String {
        // A diagnostic line, not on screen: one fixed format whatever the region.
        let child = logChildCPU.map { String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "none"
        return "memory scan (\(trigger)): \(processes) processes (\(own) own, \(systemMeasured) system measured, "
            + "\(unknown) unknown), \(socketTables) socket tables, launchctl \(launchctlRan ? "run" : "skipped"), "
            + "\(Int((duration * 1000).rounded())) ms, log child cpu \(child)"
    }
}

// MARK: Notifications

/// What one scan posts, decided purely: MemoryService is the only memory
/// notifier and posts what this says.
struct MemoryNotificationPlan: Equatable {
    enum Kind: Equatable { case episode, leak, runaway }
    enum Action: Equatable { case quitThem, review, copyRestart }
    var kind: Kind
    var title: String
    var body: String
    var actions: [Action]
}

enum MemoryNotifications {
    /// How the leak notification remembers an fseventsd identity across launches.
    static func leakKey(_ identity: ProcessIdentity) -> String { "\(identity.pid):\(identity.startedAt)" }

    static func identity(fromKey key: String?) -> ProcessIdentity? {
        guard let parts = key?.split(separator: ":"), parts.count == 2,
              let pid = pid_t(parts[0]), let started = UInt64(parts[1]) else { return nil }
        return ProcessIdentity(pid: pid, startedAt: started)
    }

    /// The holder a notification names: the top growing one, else the top one.
    static func namedHolder(_ holders: [MemoryHolder]) -> MemoryHolder? {
        holders.first(where: \.growing) ?? holders.first
    }

    /// (1) once per tight episode, naming what holds the memory; (2) the
    /// fseventsd leak outside an episode, once per fseventsd identity. When
    /// both would fire, only (1) posts and the leak counts as notified.
    /// `leakToMark` is the identity to remember as notified.
    static func plan(episodeNotifies: Bool, critical: Bool, holders: [MemoryHolder], counts: String?,
                     canQuitSomething: Bool, notifiedLeak: String?,
                     text: MemoryStrings) -> (plan: MemoryNotificationPlan?, leakToMark: ProcessIdentity?) {
        let leak = holders.first(where: \.isFSEventsLeak)
        let leakIsNew = leak.map { leakKey($0.identity) != notifiedLeak } ?? false
        if episodeNotifies {
            var sentences: [String] = []
            let named = namedHolder(holders)
            if let named { sentences.append(text.holderLine(named)) }
            if let counts, !counts.isEmpty { sentences.append(counts) }
            var actions: [MemoryNotificationPlan.Action] = canQuitSomething ? [.quitThem, .review] : [.review]
            if named?.isFSEventsLeak == true { actions.append(.copyRestart) }
            let plan = MemoryNotificationPlan(kind: .episode,
                                              title: critical ? text.notificationCriticalTitle : text.notificationTitle,
                                              body: sentences.isEmpty ? text.notificationNothing : sentences.joined(separator: " "),
                                              actions: actions)
            return (plan, leakIsNew ? leak?.identity : nil)
        }
        guard let leak, leakIsNew else { return (nil, nil) }
        return (MemoryNotificationPlan(kind: .leak, title: text.leakTitle, body: text.holderLine(leak) + text.leakTail,
                                       actions: [.copyRestart, .review]), leak.identity)
    }

    /// (3) The runaway brake acted (T-52): "Ended runaway GreenUp at 561 GB.",
    /// or that it could not. Posted when the signal was sent, on top of the
    /// episode's notification.
    static func runaway(_ entry: MemoryActivityEntry, text: MemoryStrings) -> MemoryNotificationPlan {
        MemoryNotificationPlan(kind: .runaway, title: text.runawayNotificationTitle,
                               body: text.logSentence(entry) + "." + text.runawayNotificationTail, actions: [.review])
    }
}

// MARK: Activity log

/// One thing the module did, kept so the person can see what ended, why, and
/// how to start it again.
struct MemoryActivityEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case autoEnded, ended, forced, quitApp, shutDownSimulator, holderExited
        /// The runaway brake ended it (T-52).
        case runawayEnded
        /// A memory alert the system did not show (T-52).
        case alertNotShown
    }
    enum Outcome: String, Codable { case pending, done, stillRunning, failed, nothingToDo }

    struct Command: Codable, Equatable {
        var arguments: [String]
        var workingDirectory: String?
    }

    var id = UUID()
    var date: Date
    var kind: Kind
    var title: String
    var reasons: [MemoryReason]
    var commands: [Command] = []
    /// An estimate: the footprint the processes held, read right before the signal.
    var estimatedBytes: UInt64 = 0
    /// An estimate: the footprint of the members whose exit was observed.
    var estimatedFreed: UInt64?
    /// The whole Mac right before the action, and at the last exit: what
    /// the entry reports as measured, never as freed.
    var measuredBefore: MemoryMeasurement?
    var measuredAfter: MemoryMeasurement?
    /// A holder that ended outside Brim and that launchd starts again (fseventsd).
    var restartedByLaunchd: Bool?
    var outcome: Outcome = .pending
    /// Who is still running five seconds after the signal: what Force ends.
    var survivors: [ProcessIdentity] = []
    /// What every member was, for the exit watch.
    var targets: [ProcessIdentity] = []
    /// For Reopen after quitting an app.
    var bundleURL: URL?
    /// The runaway brake: the footprint read right before SIGTERM, the
    /// threshold it was over, and whether SIGKILL followed five seconds later.
    var runawayBytes: UInt64?
    var runawayThreshold: UInt64?
    var forced: Bool?

    /// The whole Mac's change between the action and the last exit.
    var measuredChange: MemoryMeasuredChange? {
        guard let measuredBefore, let measuredAfter else { return nil }
        return MemoryMeasuredChange(from: measuredBefore, to: measuredAfter)
    }

    /// The saved keys keep their old names, so logs written before the
    /// estimates were renamed still load (an old `systemDelta` is ignored).
    private enum CodingKeys: String, CodingKey {
        case id, date, kind, title, reasons, commands, outcome, survivors, targets, bundleURL
        case measuredBefore, measuredAfter, restartedByLaunchd, runawayBytes, runawayThreshold, forced
        case estimatedBytes = "footprint"
        case estimatedFreed = "reclaimed"
    }
}

/// An action's processes until each one's exit is observed: what completes
/// its log entry and what the entry reports as freed.
struct MemoryActionWatch: Equatable {
    var findingID: String?
    var remaining: Set<ProcessIdentity>
    var exited: Set<ProcessIdentity> = []
    /// Each member's footprint, read right before the signal.
    var footprints: [ProcessIdentity: UInt64]
    /// The whole Mac right before the signal.
    var before: MemoryMeasurement?

    var isComplete: Bool { remaining.isEmpty }
    /// An estimate: the footprints of the members seen exiting.
    var estimatedFreed: UInt64 { exited.reduce(0) { $0 + (footprints[$1] ?? 0) } }

    /// The whole Mac's change from the signal to `after`.
    func measuredChange(after: MemoryMeasurement) -> MemoryMeasuredChange? {
        before.map { MemoryMeasuredChange(from: $0, to: after) }
    }

    /// Records one member's exit; false when it is not one this watch waits for.
    mutating func exit(_ identity: ProcessIdentity) -> Bool {
        guard remaining.remove(identity) != nil else { return false }
        exited.insert(identity)
        return true
    }

    /// Force's watch: the one kept since the first signal, or, when Brim
    /// restarted since (watches live in memory only), a new one on the
    /// survivors, so their exit still completes the entry instead of
    /// leaving it pending for good.
    static func forForce(existing: MemoryActionWatch?, survivors: [ProcessIdentity],
                         footprints: [ProcessIdentity: UInt64], before: MemoryMeasurement?) -> MemoryActionWatch {
        if let existing { return existing }
        return MemoryActionWatch(findingID: nil, remaining: Set(survivors), footprints: footprints, before: before)
    }
}

/// Which big holders get an exit watch, and which exits are Brim's own.
/// The watch is the generic way to prove what a restart did ("Ended outside
/// Brim", with measured deltas), and its exit starts an outside-event scan
/// that may run the automatic tier. So it is never armed on a process Brim
/// itself is ending or quitting: that exit is Brim's, already logged as its
/// End or Quit (review fix, T-42: a quit app's 1 GB helper, and a group's
/// member between End and its signal, were watched and logged as ended
/// outside Brim, and their exit could chain past the per-event cap).
enum MemoryHolderExitWatch {
    /// `ending`: identities an End is acting on, from the click (or the
    /// automatic tier's pick) until each exit is seen. `quitApps`: pids of
    /// apps Brim asked to quit. `owner`: the process responsible for a pid
    /// (an app for its helpers; the pid itself otherwise).
    static func isBrims(_ identity: ProcessIdentity, owner: pid_t, ending: Set<ProcessIdentity>,
                        quitApps: Set<pid_t>) -> Bool {
        ending.contains(identity) || quitApps.contains(identity.pid) || quitApps.contains(owner)
    }

    /// The holders to watch (1 GB+, with a kernel start time, at most
    /// `limit`), each with its responsible process, read now: once a
    /// process has exited its responsible app can no longer be read.
    static func targets(_ holders: [MemoryHolder], floor: UInt64, limit: Int, ending: Set<ProcessIdentity>,
                        quitApps: Set<pid_t>, owner: (pid_t) -> pid_t) -> [(holder: MemoryHolder, owner: pid_t)] {
        var result: [(holder: MemoryHolder, owner: pid_t)] = []
        // Without a kernel start time "still the same process" can't be
        // told, and an exit would be a guess.
        for holder in holders where holder.bytes >= floor && holder.identity.startedAt > 0 {
            guard result.count < limit else { break }
            let responsible = owner(holder.identity.pid)
            guard !isBrims(holder.identity, owner: responsible, ending: ending, quitApps: quitApps) else { continue }
            result.append((holder, responsible))
        }
        return result
    }

    /// The quit apps still to treat as Brim's: those still running, or
    /// named responsible by a big holder still listed (a helper can
    /// outlive its app by a moment).
    static func stillQuitting(_ quitApps: Set<pid_t>, running: Set<pid_t>, holderOwners: Set<pid_t>) -> Set<pid_t> {
        quitApps.filter { running.contains($0) || holderOwners.contains($0) }
    }
}

/// Whether an action waiting on the action queue may still signal when its
/// turn comes. The queue is serial and one action can hold it for a while
/// (a Simulator shutdown waits up to 60 s), so an automatic End picked
/// while memory was tight could otherwise signal after cleanup was turned
/// off, the group was added to Keep, the episode closed or the module
/// stopped (review fix, T-42). A ticket is taken when the action is queued
/// and checked right before the signal; a revocation makes every earlier
/// ticket of the kinds it covers stale.
final class MemoryActionAuthority: @unchecked Sendable {
    enum Kind: Hashable, CaseIterable {
        /// The automatic tier.
        case automatic
        /// The notification's Quit them, after its scan.
        case quitThem
        /// A click on a row (End, Force).
        case direct
        /// The runaway brake's SIGTERM and its SIGKILL five seconds later.
        case runaway
    }

    enum Revocation: Equatable { case stopped, keepChanged, autoCleanOff, episodeClosed }

    struct Ticket: Equatable {
        let kind: Kind
        let generation: Int
    }

    private let lock = NSLock()
    private var generations: [Kind: Int] = [:]

    /// The kinds a revocation makes stale. A click is the person's own
    /// decision: only stopping the module cancels it. The runaway brake
    /// acts only while memory is tight and never on a kept process; it is
    /// not leftover cleanup, so turning that off leaves it be.
    static func revokes(_ revocation: Revocation) -> Set<Kind> {
        switch revocation {
        case .stopped: return Set(Kind.allCases)
        case .keepChanged: return [.automatic, .quitThem, .runaway]
        case .autoCleanOff: return [.automatic]
        case .episodeClosed: return [.automatic, .runaway]
        }
    }

    func ticket(_ kind: Kind) -> Ticket {
        lock.lock()
        defer { lock.unlock() }
        return Ticket(kind: kind, generation: generations[kind] ?? 0)
    }

    func revoke(_ revocation: Revocation) {
        lock.lock()
        defer { lock.unlock() }
        for kind in Self.revokes(revocation) { generations[kind, default: 0] += 1 }
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (generations[ticket.kind] ?? 0) == ticket.generation
    }
}

/// The last 50 actions, newest first.
struct MemoryActivityLog: Equatable {
    static let capacity = 50
    private(set) var entries: [MemoryActivityEntry] = []

    init(entries: [MemoryActivityEntry] = []) {
        self.entries = Array(entries.sorted { $0.date > $1.date }.prefix(Self.capacity))
    }

    mutating func add(_ entry: MemoryActivityEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    mutating func update(_ id: UUID, _ change: (inout MemoryActivityEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    func entry(_ id: UUID) -> MemoryActivityEntry? { entries.first { $0.id == id } }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(entries)
    }

    static func decoded(_ data: Data?) -> MemoryActivityLog {
        guard let data else { return MemoryActivityLog() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return MemoryActivityLog(entries: (try? decoder.decode([MemoryActivityEntry].self, from: data)) ?? [])
    }
}
