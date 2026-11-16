// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// The numbers the rules use. One place, so the tests and Settings read the
/// same ones the scan does.
struct MemoryThresholds: Equatable {
    /// (d) A group smaller than this is listed, never ended automatically.
    var autoFloor: UInt64 = 50 << 20
    /// (g) Idle: less than `idleCPU` seconds of CPU over at least this long.
    var idleWindow: TimeInterval = 30 * 60
    var idleCPU: TimeInterval = 3
    /// (i) Orphaned for at least this long.
    var orphanedFor: TimeInterval = 30 * 60
    /// An MCP server older than this, and idle, is offered for ending.
    var staleMCPAge: TimeInterval = 2 * 3600
    /// A language server holding at least this much is suggested for a restart.
    var languageServerFloor: UInt64 = 400 << 20
    /// The automatic tier ends at most this many groups per event.
    var autoGroupsPerTrigger = 3
}

/// What started a scan. Only an outside event may run the automatic tier,
/// and only while memory is tight: the scan after an action (a member's
/// exit, a click) never does, so one pressure event ends at most
/// `autoGroupsPerTrigger` groups instead of chaining through every eligible
/// one, exit by exit; and opening the panel or Settings never ends anything.
///
/// `.monitorReading` is a SystemMonitor reading that jumped. SystemMonitor
/// samples memory while the panel is shown, so its first reading after the
/// panel opens is compared with a measurement up to an hour old: a scan it
/// starts is the panel's, and never acts (review fix, T-42). `.swap` is the
/// kqueue swapfile watch only.
enum MemoryScanTrigger: Equatable {
    case start, pressure, launch, terminate, wake, unlock, rootExit, foreground, deadline, action, swap, holderExit
    case monitorReading

    /// Outside events that may run the automatic tier, and only while memory is tight.
    /// Opening the panel or Settings (.foreground), a SystemMonitor reading
    /// (sampled because the panel is open) and the scan after an action never do.
    var runsAutomaticTier: Bool { self != .action && self != .foreground && self != .monitorReading }

    /// The one scan queued behind a running one: an outside event's trigger
    /// wins over one that never acts, so a pressure event is never lost to
    /// the panel's scan, and a scan that never acts never replaces one that may.
    static func queued(after pending: MemoryScanTrigger?, incoming: MemoryScanTrigger) -> MemoryScanTrigger {
        guard let pending else { return incoming }
        return pending.runsAutomaticTier && !incoming.runsAutomaticTier ? pending : incoming
    }
}

/// What `recheck` requires of a group judged again right before a signal.
enum MemoryRecheck: Equatable { case automatic, idleConfirmed }

/// What a scan knows besides the process table.
struct MemoryContext {
    var uid: uid_t
    var home: String
    var ownPID: pid_t
    /// Wall-clock time: when things started, ended and were first seen.
    var now: Date
    /// The awake clock (system uptime, seconds), which stops while the Mac
    /// sleeps: the idle windows run on it, so a window that spans a night
    /// asleep never counts as hours of idleness.
    var awake: TimeInterval
    /// Pids of the person's launchd jobs (`launchctl list`); nil when that
    /// could not be read, which keeps every pgid == pid group off the
    /// automatic tier.
    var launchdJobs: Set<pid_t>?
    /// Processes holding a power assertion (caffeinate and friends).
    var powerAssertions: Set<pid_t> = []
    /// Processes with audio running in or out.
    var audioActive: Set<pid_t> = []
    /// The person's Keep list: executable names or path prefixes.
    var keep: [String] = []
    var thresholds = MemoryThresholds()
}

enum MemoryBucket: String, CaseIterable, Codable {
    /// Every leftover test passed: the automatic tier may end it.
    case autoLeftover
    /// A leftover the person can end with one click.
    case leftover
    /// A leftover that still listens on a port: one click, ports shown.
    case orphanedDevServer
    /// A dev tool's own background server: shown, never ended.
    case selfDaemonized
    /// Protected, for information: test runs, dev servers, agents, services.
    case runningNow
    /// Regular apps unused for a while that hold a lot.
    case heavyIdleApp
    /// Language servers, stale MCP servers, idle Simulator clones.
    case longRunningHelper
}

enum MemoryRunningKind: String, Codable {
    case testRun, devServer, agentSession, service, powerAssertion, audio, network, terminal, kept, protectedTool
}

enum MemoryHelperKind: String, Codable {
    /// Suggestion only: restart it from its editor.
    case languageServer
    /// One click: an `npm exec … mcp` server a CLI started long ago and no
    /// longer talks to.
    case staleMCP
    /// One click: a Simulator clone a finished test plan left booted.
    case simulatorClone
}

/// Why a finding is where it is: its chips in the panel and its line in the
/// activity log.
enum MemoryReason: Hashable, Codable {
    case parentGone(since: Date)
    case idle
    case busy
    case measuring(until: Date)
    case noNetwork
    case listening(ports: [UInt16])
    case belowFloor
    case powerAssertion
    /// A member's CPU or footprint could not be read: never automatic.
    case unreadable
}

/// One row of the Memory lists: a process group (or one process) and what the
/// module makes of it.
struct MemoryFinding: Identifiable, Equatable {
    var id: String
    var bucket: MemoryBucket
    var pgid: pid_t
    /// The executable most members run.
    var name: String
    /// A project name, when the paths or working directory say one.
    var project: String?
    /// In signal order: deepest first.
    var members: [ProcessRecord]
    /// The known footprints summed; `footprintIncomplete` when a member's
    /// could not be read, shown as "≥ 1.2 GB".
    var footprint: UInt64
    var started: Date
    var orphanedSince: Date?
    var ports: [UInt16] = []
    /// It accepts connections on a Unix-domain socket (a local server).
    var listensLocally = false
    var running: MemoryRunningKind?
    var helper: MemoryHelperKind?
    var languageServer: MemoryRules.LanguageServer?
    /// A language server whose client is still running.
    var inUse = false
    /// Simulator clones a running test plan has booted.
    var simulators = 0
    var simulatorUDID: String?
    /// When a waiting leftover may become eligible: the one-shot deadline.
    var eligibleAt: Date?
    /// A leftover group whose leader is gone, whose latest window read idle,
    /// orphaned long enough, with readable sockets and paths: every check
    /// but the size floor. Only these are what the pressure notification's
    /// Quit them ends; a busy, measuring or uncertain group is ended only
    /// from its own row.
    var idleConfirmed = false
    var reasons: [MemoryReason] = []
    /// "Left by VS Code": the app responsible for it, filled in by the app.
    var leftBy: String?
    /// A member's footprint is unknown, so `footprint` is a lower bound.
    var footprintIncomplete = false

    var count: Int { members.count }
    var identities: [ProcessIdentity] { members.map(\.identity) }

    /// Adds a member's footprint to the total, or marks the total a lower
    /// bound when it is unknown.
    mutating func addFootprint(of record: ProcessRecord) {
        if let bytes = record.footprint { footprint += bytes } else { footprintIncomplete = true }
    }

    /// Whether the person can end it from its row.
    var canEnd: Bool {
        switch bucket {
        case .autoLeftover, .leftover, .orphanedDevServer: return true
        case .longRunningHelper: return helper == .staleMCP || helper == .simulatorClone
        case .selfDaemonized, .runningNow, .heavyIdleApp: return false
        }
    }
}

/// What earlier scans saw of a candidate: when it was first seen, since when
/// it is orphaned, and the CPU its members had when the idle window began.
struct MemoryWindow: Equatable {
    var firstSeen: Date
    var orphanedSince: Date
    /// The awake clock's reading when the idle window began.
    var windowStart: TimeInterval
    /// Each member's CPU (its own plus its reaped children's) at that moment;
    /// its keys are the members the window began with.
    var cpuAtStart: [ProcessIdentity: TimeInterval]
    /// Seen busy at least once. Such a group is judged again on events only
    /// (a root's exit, pressure, waking, the panel opening), never on a
    /// deadline, so a job that stays busy for days arms no chain of timers.
    var seenBusy = false
}

struct MemoryObservations: Equatable {
    /// By finding key.
    var windows: [String: MemoryWindow] = [:]
    /// When a watched root exited, by the process groups it and its children
    /// were in: the start of "orphaned" for those groups.
    var rootExits: [pid_t: Date] = [:]
}

/// A process watched for its exit (DispatchSource process source), and the
/// process groups its exit would orphan.
struct MemoryRoot: Equatable {
    var identity: ProcessIdentity
    var groups: Set<pid_t>
}

struct MemoryScanResult {
    var findings: [MemoryFinding]
    var observations: MemoryObservations
    /// A test driver is alive: `xcodebuild test`, a pytest/xdist or
    /// `node --test` parent, vitest or a jest worker. A lingering
    /// testmanagerd alone is not one.
    var testRunActive: Bool
    var roots: [MemoryRoot]
    /// The earliest moment a waiting candidate may become eligible.
    var nextDeadline: Date?

    func findings(in bucket: MemoryBucket) -> [MemoryFinding] { findings.filter { $0.bucket == bucket } }
}

/// The Memory module's judgement, pure: process table in, findings out. It
/// acts on whole process groups only, and a path alone never decides: a live
/// test run shares its interpreter path and argument shape with the leftovers
/// of an earlier one. Only the dead group leader, the idle CPU and the quiet
/// sockets tell them apart.
enum MemoryClassifier {
    static let maximumRoots = 128

    /// Pids whose sockets the scan needs: members of orphaned groups and the
    /// person's dev processes (for "dev server" rows). Everything else is left
    /// unread, so a scan reads a few dozen descriptor tables, not thousands.
    static func socketCandidates(_ records: [ProcessRecord], context: MemoryContext) -> Set<pid_t> {
        var pids = Set<pid_t>()
        for (pgid, members) in orphanGroups(records, context: context) where mayBeLeftover(pgid: pgid, members: members, context: context) {
            pids.formUnion(members.map(\.pid))
        }
        for record in records where record.uid == context.uid && record.ppid != 1
            && MemoryRules.hasDevSignature(record, home: context.home) && !MemoryRules.isProtectedTool(record) {
            pids.insert(record.pid)
        }
        return pids
    }

    static func scan(_ records: [ProcessRecord], context: MemoryContext,
                     observations previous: MemoryObservations) -> MemoryScanResult {
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        // Other users' processes are never this module's to list or end, so
        // no subtree it shows or signals reaches into them.
        let children = Dictionary(grouping: records.filter { $0.uid == context.uid && !$0.restricted }, by: \.ppid)
        var next = MemoryObservations(windows: [:], rootExits: previous.rootExits)
        var findings: [MemoryFinding] = []
        var deadlines: [Date] = []

        // Leftovers: orphaned process groups, judged whole.
        for (pgid, members) in orphanGroups(records, context: context).sorted(by: { $0.key < $1.key }) {
            if let finding = judgeOrphanGroup(pgid: pgid, members: members, context: context,
                                              previous: previous, next: &next) {
                findings.append(finding)
                if let eligibleAt = finding.eligibleAt { deadlines.append(eligibleAt) }
            }
        }
        let inLeftovers = Set(findings.flatMap { $0.members.map(\.pid) })

        // Running now: test runs (with their Simulator clones), agents, dev servers.
        let own = records.filter { $0.uid == context.uid && !$0.restricted && $0.pid != context.ownPID }
        let testDriverAlive = own.contains(where: MemoryRules.isXcodeTestDriver)
        var testRuns: [MemoryFinding] = []
        for root in own where MemoryRules.isTestRunRoot(root) && !inLeftovers.contains(root.pid) {
            if let parent = byPID[root.ppid], MemoryRules.isTestRunRoot(parent) { continue }
            let members = [root] + descendants(of: root.pid, children: children)
            var finding = makeFinding(id: "t\(root.pid)-\(root.startedAt)", bucket: .runningNow, pgid: root.pgid,
                                      members: members, context: context)
            finding.running = .testRun
            testRuns.append(finding)
        }
        // Xcode's test daemon counts toward the run it serves; with no
        // xcodebuild test alive it is an idle daemon and is not listed.
        if let index = testRuns.firstIndex(where: { $0.members.contains(where: MemoryRules.isXcodeTestDriver) }) {
            for daemon in own where MemoryRules.isXcodeTestDaemon(daemon)
                && !testRuns[index].members.contains(where: { $0.pid == daemon.pid }) {
                testRuns[index].addFootprint(of: daemon)
            }
        }
        for device in own.compactMap({ record in MemoryRules.simulatorDevice(record).map { (record, $0) } }) {
            let (launchd, info) = device
            let members = [launchd] + descendants(of: launchd.pid, children: children)
            if info.clone, testDriverAlive,
               let index = testRuns.firstIndex(where: { $0.members.contains(where: MemoryRules.isXcodeTestDriver) }) {
                testRuns[index].simulators += 1
                for member in members { testRuns[index].addFootprint(of: member) }
            } else if info.clone, !testDriverAlive {
                var finding = makeFinding(id: "s\(info.udid)", bucket: .longRunningHelper, pgid: launchd.pgid,
                                          members: members, context: context)
                finding.helper = .simulatorClone
                finding.simulatorUDID = info.udid
                finding.name = "Simulator"
                findings.append(finding)
            }
        }
        findings += testRuns

        for record in own where !inLeftovers.contains(record.pid) && record.ppid != 1 {
            guard let agent = MemoryRules.agentKind(record) else { continue }
            // A session the person started: not a sub-agent, and not an
            // app's or an editor's own backend (those belong to the app).
            if let parent = byPID[record.ppid], MemoryRules.isAgent(parent) || MemoryRules.isProtectedTool(parent) { continue }
            var finding = makeFinding(id: "a\(record.pid)-\(record.startedAt)", bucket: .runningNow, pgid: record.pgid,
                                      members: [record], context: context)
            finding.name = agent.rawValue
            // Its project is where it runs, not where it is installed.
            finding.project = record.workingDirectory.flatMap { $0 == context.home ? nil : ($0 as NSString).lastPathComponent }
            finding.running = .agentSession
            findings.append(finding)
        }

        for record in own where !inLeftovers.contains(record.pid) && record.ppid != 1 {
            guard let sockets = record.sockets, sockets.isListening, !MemoryRules.isAgent(record),
                  !MemoryRules.isProtectedTool(record), MemoryRules.hasDevSignature(record, home: context.home)
            else { continue }
            var finding = makeFinding(id: "d\(record.pid)-\(record.startedAt)", bucket: .runningNow, pgid: record.pgid,
                                      members: [record], context: context)
            finding.running = .devServer
            finding.ports = sockets.ports
            finding.listensLocally = !sockets.listeningLocal.isEmpty
            findings.append(finding)
        }

        // Long-running helpers: big language servers (suggestion only) and
        // stale MCP servers (one click).
        let sourceKitClients = records.contains { MemoryRules.languageServer($0) == .sourceKitLSP || $0.executableName == "Xcode" }
        for record in records where record.uid == context.uid {
            guard let server = MemoryRules.languageServer(record),
                  (record.footprint ?? 0) >= context.thresholds.languageServerFloor else { continue }
            var finding = makeFinding(id: "l\(record.pid)-\(record.startedAt)", bucket: .longRunningHelper,
                                      pgid: record.pgid, members: [record], context: context)
            finding.helper = .languageServer
            finding.languageServer = server
            finding.inUse = server == .sourceKit ? sourceKitClients : record.ppid != 1
            findings.append(finding)
        }
        for wrapper in own where MemoryRules.isMCPWrapper(wrapper) && wrapper.ppid != 1 {
            guard let parent = byPID[wrapper.ppid], MemoryRules.isAgent(parent),
                  context.now.timeIntervalSince(wrapper.startDate) >= context.thresholds.staleMCPAge else { continue }
            // Its own subtree, never its process group: the CLI shares it.
            let members = signalOrder([wrapper] + descendants(of: wrapper.pid, children: children))
            let key = "m\(wrapper.pid)-\(wrapper.startedAt)"
            let window = measure(key: key, members: members, orphanedSince: nil, context: context,
                                 previous: previous, next: &next)
            if window.idle == true {
                var finding = makeFinding(id: key, bucket: .longRunningHelper, pgid: wrapper.pgid,
                                          members: members, context: context)
                finding.helper = .staleMCP
                finding.reasons = [.idle]
                findings.append(finding)
            } else if let until = window.until, !window.seenBusy {
                // A server its CLI keeps using is judged again on events only.
                deadlines.append(until)
            }
        }

        let testRunActive = !testRuns.isEmpty || testDriverAlive
        return MemoryScanResult(findings: findings.sorted(by: order),
                                observations: pruned(next, records: records),
                                testRunActive: testRunActive,
                                roots: roots(own, byPID: byPID, children: children),
                                nextDeadline: deadlines.filter { $0 > context.now }.min())
    }

    /// The automatic tier's work for one event: nothing unless the event is
    /// an outside one (`runsAutomaticTier`) and memory is tight (the maintainer's
    /// rule, 2026-11-14: otherwise leftovers are only listed); then eligible
    /// groups, largest first, at most `autoGroupsPerTrigger`. A group with
    /// any member the tier has signalled before is never signalled again by
    /// it: one that ignores SIGTERM, or one kill() could not reach, is left
    /// to its row's Force or End, not retried on every later event.
    /// The processes the automatic tier counts as signalled: those a
    /// signal was attempted on (`attempted`: sent, refused or failed). A
    /// group the re-check skipped (nothing signalled) or whose members were
    /// already gone stays eligible, so its chip's "ends automatically" stays
    /// true (review fix, T-42: it used to be marked before the re-check ran).
    static func signalledByTier(_ members: [ProcessIdentity], attempted: Set<pid_t>) -> Set<ProcessIdentity> {
        Set(members.filter { attempted.contains($0.pid) })
    }

    static func autoTargets(_ findings: [MemoryFinding], thresholds: MemoryThresholds,
                            alreadySignalled: Set<ProcessIdentity> = [],
                            trigger: MemoryScanTrigger, memoryTight: Bool) -> [MemoryFinding] {
        guard trigger.runsAutomaticTier, memoryTight else { return [] }
        return Array(findings.filter { $0.bucket == .autoLeftover && alreadySignalled.isDisjoint(with: $0.identities) }
            .sorted { $0.footprint > $1.footprint }
            .prefix(thresholds.autoGroupsPerTrigger))
    }

    /// The group judged again from a table read just now, with the same observations:
    /// the identities to signal, or nil when anything changed or cannot be read.
    /// The caller reads the members' sockets, power assertions and audio
    /// fresh into `records` and `context`. Pure: the observations it
    /// computes are thrown away.
    static func recheck(_ finding: MemoryFinding, requirement: MemoryRecheck, fresh records: [ProcessRecord],
                        context: MemoryContext, observations: MemoryObservations) -> [ProcessIdentity]? {
        guard let members = orphanGroups(records, context: context)[finding.pgid],
              Set(members.map(\.identity)) == Set(finding.identities) else { return nil }
        var scratch = MemoryObservations(windows: [:], rootExits: observations.rootExits)
        guard let judged = judgeOrphanGroup(pgid: finding.pgid, members: members, context: context,
                                            previous: observations, next: &scratch) else { return nil }
        switch requirement {
        case .automatic: guard judged.bucket == .autoLeftover else { return nil }
        case .idleConfirmed: guard judged.idleConfirmed else { return nil }
        }
        // idleConfirmed already needs every read known; checked again here
        // so no future change to it can let an unknown through.
        guard !judged.footprintIncomplete, judged.members.allSatisfy({ $0.sockets != nil && $0.totalCPUTime != nil })
        else { return nil }
        return judged.identities
    }

    /// Whether this scan needs `launchctl list`: only when an orphan
    /// candidate group's leader is alive (pid == pgid), the one case the
    /// leftover test asks launchd about. Most scans skip the child process.
    static func needsLaunchdJobs(_ records: [ProcessRecord], context: MemoryContext) -> Bool {
        orphanGroups(records, context: context).contains { pgid, members in
            members.contains { $0.pid == pgid } && mayBeLeftover(pgid: pgid, members: members, context: context)
        }
    }

    /// What the pressure notification counts as leftovers and its Quit them
    /// ends: leftover groups whose latest window read idle and that passed
    /// the orphan-age, leader-gone, socket and path checks.
    static func quitThemTargets(_ findings: [MemoryFinding]) -> [MemoryFinding] {
        findings.filter { $0.idleConfirmed && ($0.bucket == .autoLeftover || $0.bucket == .leftover) }
    }

    /// Deepest first, so no parent outlives a child it could restart; within
    /// a depth, newest pid first.
    static func signalOrder(_ members: [ProcessRecord]) -> [ProcessRecord] {
        let byPID = Dictionary(members.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        func depth(_ record: ProcessRecord) -> Int {
            var depth = 0
            var current = record
            var seen: Set<pid_t> = [record.pid]
            while let parent = byPID[current.ppid], seen.insert(parent.pid).inserted {
                depth += 1
                current = parent
            }
            return depth
        }
        return members.map { ($0, depth($0)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.pid > $1.0.pid }
            .map(\.0)
    }

    // MARK: Leftover test

    /// (a) every member is the person's, (b) every member's parent is launchd
    /// or inside the group, and the group is not this app's. The table lists
    /// other users' processes too, so (a) sees a group whole.
    static func orphanGroups(_ records: [ProcessRecord], context: MemoryContext) -> [pid_t: [ProcessRecord]] {
        let groups = Dictionary(grouping: records.filter { $0.pgid > 1 }, by: \.pgid)
        return groups.filter { _, members in
            let pids = Set(members.map(\.pid))
            return members.allSatisfy { $0.uid == context.uid && !$0.restricted && $0.pid != context.ownPID && $0.pid > 1 }
                && members.contains { $0.ppid == 1 }
                && members.allSatisfy { $0.ppid == 1 || pids.contains($0.ppid) }
        }
    }

    /// The cheap part of the test, which also decides whose sockets are
    /// read: not a crash reporter, not a language server (a helper, below),
    /// not an app's, XPC service's or system daemon's own group, and some
    /// member carries a dev signature or holds a power assertion.
    private static func mayBeLeftover(pgid: pid_t, members: [ProcessRecord], context: MemoryContext) -> Bool {
        if members.contains(where: MemoryRules.isIntentionalDaemonizer) { return false }
        if members.contains(where: { MemoryRules.languageServer($0) != nil }) { return false }
        // An app, an XPC service or a system daemon leads its own group,
        // started by launchd. Apps are judged as apps (Heavy & idle).
        if let leader = members.first(where: { $0.pid == pgid }), MemoryRules.isAppOrSystemExecutable(leader) { return false }
        return members.contains { MemoryRules.hasDevSignature($0, home: context.home) || MemoryRules.isAgent($0)
            || MemoryRules.isSelfDaemonizingTool($0) || context.powerAssertions.contains($0.pid) }
    }

    private static func judgeOrphanGroup(pgid: pid_t, members unordered: [ProcessRecord], context: MemoryContext,
                                         previous: MemoryObservations,
                                         next: inout MemoryObservations) -> MemoryFinding? {
        let members = signalOrder(unordered)
        guard mayBeLeftover(pgid: pgid, members: members, context: context) else { return nil }

        // (c) Not launchd-managed. A living leader means pgid == pid: a
        // process that made its own group (a launchd job, a daemon, a job a
        // shell detached), which never reaches the automatic tier.
        let leader = members.first(where: { $0.pid == pgid })
        if let leader, let jobs = context.launchdJobs, jobs.contains(leader.pid) {
            guard MemoryRules.isHomebrew(leader) else { return nil }
            var finding = makeFinding(id: "v\(pgid)-\(leader.startedAt)", bucket: .runningNow, pgid: pgid,
                                      members: members, context: context)
            finding.running = .service
            return finding
        }
        // A tool's own background server or a session keeper, whether its
        // leader lives (fork + setsid) or is gone (a double fork).
        if members.contains(where: MemoryRules.isSelfDaemonizingTool) {
            return makeFinding(id: "y\(pgid)-\(leader?.startedAt ?? members.map(\.startedAt).min() ?? 0)",
                               bucket: .selfDaemonized, pgid: pgid, members: members, context: context)
        }

        let key = "g\(pgid)"
        func protected(_ kind: MemoryRunningKind) -> MemoryFinding {
            var finding = makeFinding(id: "p\(pgid)-\(members.map(\.startedAt).min() ?? 0)", bucket: .runningNow,
                                      pgid: pgid, members: members, context: context)
            finding.running = kind
            if kind == .powerAssertion { finding.reasons = [.powerAssertion] }
            return finding
        }
        if members.contains(where: { MemoryRules.isSystemProtected($0) }) { return nil }
        if members.contains(where: { context.powerAssertions.contains($0.pid) }) { return protected(.powerAssertion) }
        if members.contains(where: MemoryRules.isAgent) { return protected(.agentSession) }
        // (e) A positive dev signature on at least one member.
        guard members.contains(where: { MemoryRules.hasDevSignature($0, home: context.home) }) else { return nil }
        if members.contains(where: MemoryRules.isProtectedTool) { return protected(.protectedTool) }
        if members.contains(where: { context.audioActive.contains($0.pid) }) { return protected(.audio) }
        if members.contains(where: { MemoryRules.isKept($0, keep: context.keep) }) { return protected(.kept) }
        // (f) No controlling terminal.
        if !members.allSatisfy(\.hasNoTerminal) { return protected(.terminal) }
        // (h) No sockets. Listening (TCP, UDP or a Unix socket): an orphaned
        // dev server, one click. An unreadable descriptor table is unknown,
        // never "no sockets".
        var sockets = ProcessSockets()
        let socketsKnown = members.allSatisfy { $0.sockets != nil }
        for member in members { if let own = member.sockets { sockets.add(own) } }
        if sockets.isListening {
            var finding = makeFinding(id: key, bucket: .orphanedDevServer, pgid: pgid, members: members,
                                      context: context)
            finding.ports = sockets.ports
            finding.listensLocally = !sockets.listeningLocal.isEmpty
            let since = orphanedSince(key: key, pgid: pgid, members: members, context: context, previous: previous)
            // Kept only so the next scan remembers the first sighting.
            _ = measure(key: key, members: members, orphanedSince: since, context: context, previous: previous, next: &next)
            finding.orphanedSince = since
            finding.reasons = [.parentGone(since: since), .listening(ports: sockets.ports)]
            return finding
        }
        if sockets.established > 0 { return protected(.network) }

        // (g) idle and (i) orphaned long enough, measured across scans.
        let since = orphanedSince(key: key, pgid: pgid, members: members, context: context, previous: previous)
        let window = measure(key: key, members: members, orphanedSince: since, context: context,
                             previous: previous, next: &next)
        let thresholds = context.thresholds
        var finding = makeFinding(id: key, bucket: .leftover, pgid: pgid, members: members, context: context)
        finding.orphanedSince = since
        let aboveFloor = finding.footprint >= thresholds.autoFloor
        let orphanedLongEnough = context.now.timeIntervalSince(since) >= thresholds.orphanedFor
        let cpuKnown = members.allSatisfy { $0.totalCPUTime != nil }
        let footprintKnown = !finding.footprintIncomplete
        var reasons: [MemoryReason] = [.parentGone(since: since)]
        switch window.idle {
        case true?: reasons.append(.idle)
        case false?: reasons.append(.busy)
        case nil: if let until = window.until { reasons.append(.measuring(until: until)) }
        }
        if !cpuKnown || !footprintKnown { reasons.append(.unreadable) }
        if socketsKnown { reasons.append(.noNetwork) }
        if !aboveFloor { reasons.append(.belowFloor) }
        finding.reasons = reasons
        // Only a group whose leader is gone is ever more than one click:
        // the dead leader is what tells an orphan from a daemon. An
        // unreadable path, descriptor table, CPU time or footprint keeps it
        // one click too: unknown is never read as quiet, idle or small.
        let pathsKnown = members.allSatisfy { !$0.path.isEmpty }
        let qualifies = leader == nil && socketsKnown && pathsKnown && cpuKnown && footprintKnown
        finding.idleConfirmed = qualifies && window.idle == true && orphanedLongEnough
        if finding.idleConfirmed, aboveFloor {
            finding.bucket = .autoLeftover
        } else if qualifies, aboveFloor, !window.seenBusy {
            // The one-shot deadline: when both windows will have run. A
            // group once seen busy gets none; events judge it again.
            let windowEnd = window.until ?? context.now
            let orphanEnd = since.addingTimeInterval(thresholds.orphanedFor)
            let at = max(windowEnd, orphanEnd)
            if at > context.now { finding.eligibleAt = at }
        }
        return finding
    }

    /// Since when the group is orphaned: its root's observed exit when one
    /// was seen, else its first sighting.
    private static func orphanedSince(key: String, pgid: pid_t, members: [ProcessRecord], context: MemoryContext,
                                      previous: MemoryObservations) -> Date {
        let seen = sameGroup(previous.windows[key], members: members) ? previous.windows[key]?.orphanedSince : nil
        // A root's exit dates a group only once that group's leader is gone.
        let exit = members.contains { $0.pid == pgid } ? nil : previous.rootExits[pgid]
        let candidates = [seen, exit].compactMap { $0 }
        return candidates.min() ?? context.now
    }

    /// The idle measurement: less than `idleCPU` seconds of CPU across the
    /// members (their own and their reaped children's) since the window
    /// began, over at least `idleWindow` of awake time. Busy restarts the
    /// window, and so does a member ending or appearing: work that moved
    /// between processes is still work, even when no reading shows it.
    /// A member whose CPU could not be read makes the measurement unknown
    /// (idle nil, no deadline): a refused read once read as 0, so a busy
    /// group looked idle. Its window is kept unchanged for a later reading.
    private static func measure(key: String, members: [ProcessRecord], orphanedSince: Date?, context: MemoryContext,
                                previous: MemoryObservations,
                                next: inout MemoryObservations) -> (idle: Bool?, until: Date?, seenBusy: Bool) {
        let now = context.now
        let cpuKnown = members.allSatisfy { $0.totalCPUTime != nil }
        // An unreadable member counts from 0: once it reads, its whole CPU
        // time counts as used, which only ever restarts the window.
        let cpuNow = Dictionary(members.map { ($0.identity, $0.totalCPUTime ?? 0) }, uniquingKeysWith: { first, _ in first })
        let thresholds = context.thresholds
        guard let earlier = previous.windows[key], sameGroup(earlier, members: members) else {
            next.windows[key] = MemoryWindow(firstSeen: now, orphanedSince: orphanedSince ?? now,
                                             windowStart: context.awake, cpuAtStart: cpuNow)
            return (nil, cpuKnown ? now.addingTimeInterval(thresholds.idleWindow) : nil, false)
        }
        var window = earlier
        if let orphanedSince { window.orphanedSince = min(window.orphanedSince, orphanedSince) }
        guard cpuKnown else {
            next.windows[key] = window
            return (nil, nil, window.seenBusy)
        }
        let used = members.reduce(0.0) { total, member in
            total + max(0, (member.totalCPUTime ?? 0) - (earlier.cpuAtStart[member.identity] ?? 0))
        }
        let membersChanged = Set(cpuNow.keys) != Set(earlier.cpuAtStart.keys)
        if membersChanged || used >= thresholds.idleCPU {
            window.windowStart = context.awake
            window.cpuAtStart = cpuNow
            window.seenBusy = true
            next.windows[key] = window
            return (false, now.addingTimeInterval(thresholds.idleWindow), true)
        }
        next.windows[key] = window
        let elapsed = context.awake - window.windowStart
        guard elapsed < thresholds.idleWindow else { return (true, nil, window.seenBusy) }
        return (nil, now.addingTimeInterval(thresholds.idleWindow - elapsed), window.seenBusy)
    }

    /// A group is the one seen before while any member it had then lives on.
    private static func sameGroup(_ window: MemoryWindow?, members: [ProcessRecord]) -> Bool {
        guard let window else { return false }
        return members.contains { window.cpuAtStart[$0.identity] != nil }
    }

    // MARK: Helpers

    private static func makeFinding(id: String, bucket: MemoryBucket, pgid: pid_t, members sorted: [ProcessRecord],
                                    context: MemoryContext) -> MemoryFinding {
        var counts: [String: Int] = [:]
        for member in sorted { counts[member.executableName, default: 0] += 1 }
        let name = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
            ?? sorted.first?.executableName ?? "?"
        let project = sorted.lazy.compactMap { MemoryRules.projectHint($0, home: context.home) }.first
        var finding = MemoryFinding(id: id, bucket: bucket, pgid: pgid, name: name, project: project, members: sorted,
                                    footprint: 0, started: sorted.map(\.startDate).min() ?? context.now)
        for member in sorted { finding.addFootprint(of: member) }
        return finding
    }

    static func descendants(of pid: pid_t, children: [pid_t: [ProcessRecord]]) -> [ProcessRecord] {
        var result: [ProcessRecord] = []
        var seen: Set<pid_t> = [pid]
        var frontier = [pid]
        while !frontier.isEmpty, result.count < 4096 {
            var nextFrontier: [pid_t] = []
            for parent in frontier {
                for child in children[parent] ?? [] where seen.insert(child.pid).inserted {
                    result.append(child)
                    nextFrontier.append(child.pid)
                }
            }
            frontier = nextFrontier
        }
        return result
    }

    /// Roots whose exit can leave leftovers: terminal shells, agent CLIs, test
    /// run parents and MCP wrappers. Each carries the groups it and its
    /// children are in, the groups its exit would orphan.
    private static func roots(_ own: [ProcessRecord], byPID: [pid_t: ProcessRecord],
                              children: [pid_t: [ProcessRecord]]) -> [MemoryRoot] {
        func rank(_ record: ProcessRecord) -> Int? {
            if MemoryRules.isTestRunRoot(record) { return 0 }
            if MemoryRules.isAgent(record) { return 1 }
            if MemoryRules.isMCPWrapper(record) { return 2 }
            if MemoryRules.isTerminalShell(record), !record.hasNoTerminal { return 3 }
            return nil
        }
        var ranked: [(record: ProcessRecord, rank: Int)] = []
        for record in own {
            if let rank = rank(record) { ranked.append((record, rank)) }
        }
        ranked.sort { left, right in
            left.rank != right.rank ? left.rank < right.rank : left.record.pid < right.record.pid
        }
        return ranked.prefix(maximumRoots).map { entry -> MemoryRoot in
            // A root's exit orphans its own group only when it leads that
            // group: an MCP wrapper in its CLI's group leaves the CLI's
            // group whole. Its children's own groups lose their parent.
            let root = entry.record
            var groups = Set((children[root.pid] ?? []).map(\.pgid))
            if root.pgid != root.pid { groups.remove(root.pgid) }
            if root.pgid == root.pid { groups.insert(root.pgid) }
            return MemoryRoot(identity: root.identity, groups: groups)
        }
    }

    /// Keeps what the next scan needs: windows of groups still present and
    /// root exits for groups that still exist and whose leader is gone. A
    /// group whose leader still runs was not orphaned by any exit.
    private static func pruned(_ observations: MemoryObservations, records: [ProcessRecord]) -> MemoryObservations {
        let groups = Set(records.map(\.pgid))
        let pids = Set(records.map(\.pid))
        var result = observations
        result.rootExits = observations.rootExits.filter { groups.contains($0.key) && !pids.contains($0.key) }
        return result
    }

    private static func order(_ left: MemoryFinding, _ right: MemoryFinding) -> Bool {
        if left.bucket != right.bucket {
            return MemoryBucket.allCases.firstIndex(of: left.bucket)! < MemoryBucket.allCases.firstIndex(of: right.bucket)!
        }
        if left.footprint != right.footprint { return left.footprint > right.footprint }
        return left.id < right.id
    }
}
