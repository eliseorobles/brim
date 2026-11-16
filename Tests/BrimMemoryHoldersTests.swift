// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// T-42: the Memory module sees what holds memory (system processes too,
/// unknown never 0), acts safely (opening the panel ends nothing, nothing
/// automatic unless memory is tight, every read known and judged again right
/// before a signal), notifies once and names the holder, and proves effects
/// with measured deltas. Each fix has a test that reproduces the real
/// failure, from the 2026-11-14 incident: fseventsd grew from 133 MB to
/// 54 GB, swap from 9.6 GB to 35.8 GB.
///
/// Fixtures only: nothing here signals, quits or kills a process, and no
/// test writes outside a scratch defaults suite.
extension BrimMemoryTests {
    static func runHolderGroups(_ suite: TestSuite) {
        suite.run("memory: safety gate") { safetyGate(suite) }
        suite.run("memory: re-check before signal") { recheckBeforeSignal(suite) }
        suite.run("memory: unknown is not zero") { unknownIsNotZero(suite) }
        suite.run("memory: system processes") { systemProcesses(suite) }
        suite.run("memory: holders and growth") { holdersAndGrowth(suite) }
        suite.run("memory: episodes") { episodes(suite) }
        suite.run("memory: notification text") { notificationText(suite) }
        suite.run("memory: measured deltas") { measuredDeltas(suite) }
        suite.run("memory: triggers and log child") { triggersAndLogChild(suite) }
        suite.run("memory: scan cost") { scanCost(suite) }
    }

    // MARK: Fixtures

    static let gib: Double = 1_073_741_824
    static let fseventsdPath = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/Versions/A/Support/fseventsd"

    /// fseventsd as the table lists it to a caller that is not root: a
    /// restricted row, its start time from kinfo_proc (19:15:46 on the day
    /// of the probe), its memory from its coalition or unknown.
    static func fseventsd(_ memory: ProcessMemory, pid: pid_t = 67772,
                          startedAt: UInt64 = 1_794_000_946_402_272) -> ProcessRecord {
        ProcessRecord(pid: pid, ppid: 1, pgid: pid, uid: 0, flags: 0, terminal: ProcessRecord.noTerminal,
                      startedAt: startedAt, name: "fseventsd", path: fseventsdPath, memory: memory,
                      cpuTime: nil, reapedChildrenCPUTime: nil, restricted: true)
    }

    static func systemRow(_ pid: pid_t, name: String, path: String, memory: ProcessMemory = .unknown) -> ProcessRecord {
        ProcessRecord(pid: pid, ppid: 1, pgid: pid, uid: 88, flags: 0, terminal: ProcessRecord.noTerminal,
                      startedAt: 1_793_900_000_000_000 + UInt64(pid), name: name, path: path, memory: memory,
                      cpuTime: nil, reapedChildrenCPUTime: nil, restricted: true)
    }

    static func megabytes(_ value: Double) -> UInt64 { UInt64(value * 1_048_576) }
    static func gigabytes(_ value: Double) -> UInt64 { UInt64(value * gib) }

    static func holdersSource(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// The text of `source` from `start` up to `end`.
    static func section(_ source: String, from start: String, to end: String) -> String {
        guard let from = source.range(of: start),
              let to = source.range(of: end, range: from.upperBound..<source.endIndex) else { return "" }
        return String(source[from.lowerBound..<to.lowerBound])
    }

    static func measurement(minutes: Double, used: Double = 100, swap: Double, compressor: Double = 10,
                            swapOutsMB: Double = 0) -> MemoryMeasurement {
        MemoryMeasurement(at: now.addingTimeInterval(minutes * 60), awake: awakeAtNow + minutes * 60,
                          used: gigabytes(used), compressorRAM: gigabytes(compressor), compressedLogical: 0,
                          swapUsed: gigabytes(swap), swapTotal: gigabytes(swap + 1),
                          swapOuts: megabytes(swapOutsMB), swapIns: 0)
    }

    // MARK: 1–4. Safety gate

    private static func safetyGate(_ suite: TestSuite) {
        let eligible = twoScans(orphanGroup())
        let group = eligible.findings(in: .autoLeftover)
        suite.expect(group.map(\.pgid) == [38773], "the fixture group is eligible for the automatic tier")
        func targets(_ trigger: MemoryScanTrigger, tight: Bool) -> [pid_t] {
            MemoryClassifier.autoTargets(eligible.findings, thresholds: MemoryThresholds(), trigger: trigger,
                                         memoryTight: tight).map(\.pgid)
        }
        // Real failure: opening the panel (.foreground) ran the tier.
        suite.expect(targets(.foreground, tight: true).isEmpty && targets(.action, tight: true).isEmpty,
                     "opening the panel or Settings, or the scan after an action, ends nothing, even while memory is tight")
        suite.expect(targets(.pressure, tight: true) == [38773] && targets(.swap, tight: true) == [38773],
                     "an outside event while memory is tight runs the tier")
        // The rule since 2026-11-14: automatic only during a memory-tight episode.
        suite.expect(targets(.launch, tight: false).isEmpty && targets(.pressure, tight: false).isEmpty
                        && targets(.deadline, tight: false).isEmpty,
                     "while memory is not tight nothing is automatic: leftovers are only listed")
        let text = FeatureStrings.memory(.enUS)
        let views = holdersSource("Sources/Brim/Modules/Memory/MemoryViews.swift")
        suite.expect(text.autoWhenTight == "auto when memory is tight"
                        && views.contains("service.memoryTight ? (text.endsAutomatically, .orange) : (text.autoWhenTight, nil)"),
                     "an eligible leftover's chip says it ends only when memory is tight")

        // 3. An unreadable socket blocks automatic action.
        var listener = socket_fdinfo()
        listener.psi.soi_kind = Int32(SOCKINFO_TCP)
        listener.psi.soi_proto.pri_tcp.tcpsi_state = Int32(TSI_S_LISTEN)
        listener.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(UInt16(8000).bigEndian)
        let socketType = UInt32(PROX_FDTYPE_SOCKET)
        let descriptors = [proc_fdinfo(proc_fd: 5, proc_fdtype: socketType), proc_fdinfo(proc_fd: 6, proc_fdtype: socketType),
                           proc_fdinfo(proc_fd: 7, proc_fdtype: UInt32(PROX_FDTYPE_VNODE))]
        let refused = ProcessTable.collectSockets(descriptors: descriptors) { fd in fd == 5 ? (listener, 0) : (nil, EPERM) }
        suite.expect(refused == nil, "a socket read the kernel refuses (EPERM) makes the answer unknown, not \"no socket\"")
        let closed = ProcessTable.collectSockets(descriptors: descriptors) { fd in fd == 5 ? (listener, 0) : (nil, EBADF) }
        suite.expect(closed?.listeningTCP == [8000],
                     "a descriptor closed between listing and reading (EBADF) is skipped: \(String(describing: closed))")
        var blindGroup = orphanGroup()
        blindGroup[3].sockets = nil
        let blind = twoScans(blindGroup)
        let blindRow = finding(blind, containing: 39177)
        suite.expect(blindRow?.bucket == .leftover && blindRow?.idleConfirmed == false && neverEnded(blind),
                     "a group with one unreadable descriptor table is one click, never automatic or in Quit them")

        // 4. An unreadable usage read blocks automatic action. Real failure:
        // a refused read became CPU 0, so a busy group read as idle.
        let worker = process(4600, pgid: 4599, path: home + "/.nvm/versions/node/v22.11.0/bin/node",
                             arguments: ["node", "worker.js"], mb: 400, cpu: 12, cwd: home + "/Code/app")
        var unreadable = worker
        unreadable.cpuTime = nil
        let cpuBlind = twoScans([worker], later: [unreadable])
        let cpuRow = finding(cpuBlind, containing: 4600)
        suite.expect(cpuRow?.reasons.contains(.unreadable) == true && cpuRow?.reasons.contains(.idle) == false
                        && cpuRow?.bucket == .leftover && cpuRow?.idleConfirmed == false && neverEnded(cpuBlind),
                     "a member whose CPU can't be read is \"can't read\", not idle, and never automatic: \(String(describing: cpuRow?.reasons))")
        var sizeless = worker
        sizeless.memory = .unknown
        let sizeBlind = twoScans([worker], later: [sizeless])
        let sizeRow = finding(sizeBlind, containing: 4600)
        suite.expect(sizeRow?.footprintIncomplete == true && sizeRow?.bucket == .leftover && neverEnded(sizeBlind),
                     "a member whose footprint can't be read keeps the group off the tier: its size floor can't be checked")
        suite.expect(MemoryFormat.size(gigabytes(1.2), incomplete: true, unknown: text.unknownSize) == "≥ 1.2 GB",
                     "a total with an unknown member is shown as a lower bound")
    }

    // MARK: 5. Re-check before the signal

    private static func recheckBeforeSignal(_ suite: TestSuite) {
        let first = MemoryClassifier.scan(orphanGroup(), context: context(), observations: MemoryObservations())
        let later = now.addingTimeInterval(31 * 60)
        let second = MemoryClassifier.scan(orphanGroup(), context: context(at: later), observations: first.observations)
        guard let target = finding(second, containing: 39177), target.bucket == .autoLeftover else {
            suite.expect(false, "the fixture group is eligible")
            return
        }
        let atSignal = later.addingTimeInterval(2)
        func recheck(_ fresh: [ProcessRecord], keep: [String] = [], requirement: MemoryRecheck = .automatic) -> [ProcessIdentity]? {
            MemoryClassifier.recheck(target, requirement: requirement, fresh: fresh,
                                     context: context(at: atSignal, keep: keep), observations: second.observations)
        }
        suite.expect(recheck(orphanGroup()) == target.identities && recheck(orphanGroup(), requirement: .idleConfirmed) == target.identities,
                     "nothing changed: the identities to signal are the finding's, deepest first")
        var serving = orphanGroup()
        var port = ProcessSockets()
        port.listeningTCP = [8000]
        serving[2].sockets = port
        suite.expect(recheck(serving) == nil, "a member that started listening on 8000 since the scan: skipped")
        let newcomer = process(39190, pgid: 38773, path: home + "/.pyenv/versions/greenup-test/bin/python3",
                               arguments: ["python3", "-c", "from multiprocessing.spawn import spawn_main"], mb: 29, cpu: 0)
        suite.expect(recheck(orphanGroup() + [newcomer]) == nil, "a member that joined the group since the scan: skipped")
        suite.expect(recheck(orphanGroup(), keep: ["python3"]) == nil, "a member now on the Keep list: skipped")
        var blind = orphanGroup()
        blind[1].sockets = nil
        suite.expect(recheck(blind) == nil, "a read that fails at signal time: skipped")

        let service = holdersSource("Sources/Brim/Modules/Memory/MemoryService.swift")
        let end = section(service, from: "    private func end(_ finding: MemoryFinding, automatic: Bool", to: "    func endHolder(")
        let recheckAt = end.range(of: "MemoryClassifier.recheck(")
        let signalAt = end.range(of: "signalVerified(")
        suite.expect(recheckAt != nil && signalAt != nil && recheckAt!.lowerBound < signalAt!.lowerBound
                        && end.contains("changed since the scan"),
                     "the automatic tier and Quit them judge the group again from a fresh table before the signal")
        let quitThem = section(service, from: "    func quitThem() {", to: "    func review() {")
        suite.expect(!quitThem.isEmpty && !quitThem.contains("quit(") && !quitThem.contains("end("),
                     "Quit them acts only after the fresh scan, never at the click")
    }

    // MARK: 6. Unknown is not zero

    private static func unknownIsNotZero(_ suite: TestSuite) {
        // Real failure: fseventsd's root pid was unreadable and counted as 0.
        suite.expect(ProcessTable.systemMemory(coalitionBytes: nil, liveTasks: 1, membersSeen: 1, carriesTotal: true,
                                               verified: true) == .unknown
                        && ProcessTable.systemMemory(coalitionBytes: megabytes(4), liveTasks: 1, membersSeen: 1,
                                                     carriesTotal: true, verified: false) == .unknown,
                     "an unread or unverified coalition read is unknown, never 0")
        let blind = fseventsd(.unknown)
        let read = BrimMemoryTests.Usage.memoryRows([blind])
        suite.expect(read.rows.isEmpty && read.notMeasured == ["fseventsd"],
                     "an unknown fseventsd is named as not measured, never listed as 0 B")
        var history = MemoryHolderHistory()
        let holders = MemoryHolders.rank([blind], context: context(), history: &history, now: now,
                                         thresholds: MemoryHolderThresholds())
        suite.expect(holders.isEmpty && !history.isTracked(blind.identity), "an unknown row is never ranked as 0 bytes")
        let text = FeatureStrings.memory(.enUS)
        suite.expect(MemoryFormat.size(ProcessMemory.unknown, unknown: text.unknownSize) == "unknown"
                        && ProcessMemory.unknown.footprint == nil && ProcessMemory.unknown.bytes == nil,
                     "an unknown size reads \"unknown\"")
    }

    // MARK: 7–8, 19. System processes

    private static func systemProcesses(_ suite: TestSuite) {
        suite.expect(ProcessTable.systemMemory(coalitionBytes: megabytes(4.1), liveTasks: 1, membersSeen: 1,
                                               carriesTotal: true, verified: true) == .systemFootprint(megabytes(4.1)),
                     "alone in its coalition (one live task, one member): the coalition's footprint is its own")
        suite.expect(ProcessTable.systemMemory(coalitionBytes: megabytes(87.5), liveTasks: 2, membersSeen: 1,
                                               carriesTotal: true, verified: true) == .coalitionTotal(megabytes(87.5), members: 2),
                     "launchd's coalition has a second live task: a group total, never launchd's own size")

        // The whole assignment, on a fixture table: own processes verify
        // the read; WindowServer's two tasks share one coalition.
        let windowServerPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
        var table: [ProcessRecord] = [
            process(1001, pgid: 1001, path: home + "/.nvm/versions/node/v22.11.0/bin/node", arguments: ["node"], mb: 120, cpu: 1),
            process(1002, pgid: 1002, path: home + "/.nvm/versions/node/v22.11.0/bin/node", arguments: ["node"], mb: 64, cpu: 1),
            process(1003, pgid: 1003, path: home + "/.nvm/versions/node/v22.11.0/bin/node", arguments: ["node"], mb: 300, cpu: 1),
            fseventsd(.unknown),
            systemRow(401, name: "WindowServer", path: windowServerPath),
            systemRow(400, name: "WindowServer", path: windowServerPath),
            process(700, pgid: 700, path: home + "/.nvm/versions/node/v22.11.0/bin/node", arguments: ["node"], mb: 50, cpu: 1),
            systemRow(701, name: "helperd", path: "/usr/libexec/helperd"),
        ]
        let coalitions: [pid_t: UInt64] = [1001: 1, 1002: 2, 1003: 3, 67772: 5, 400: 9, 401: 9, 700: 7, 701: 7]
        let usage: [UInt64: ProcessTable.CoalitionUsage] = [
            1: .init(tasksStarted: 1, tasksExited: 0, footprint: megabytes(120)),
            2: .init(tasksStarted: 1, tasksExited: 0, footprint: megabytes(64.2)),
            3: .init(tasksStarted: 4, tasksExited: 3, footprint: megabytes(300)),
            5: .init(tasksStarted: 3, tasksExited: 2, footprint: megabytes(4.1)),
            9: .init(tasksStarted: 9, tasksExited: 7, footprint: megabytes(1710)),
            7: .init(tasksStarted: 2, tasksExited: 0, footprint: megabytes(200)),
        ]
        // Read now, right around each coalition: here the table's own footprints.
        let fresh = Dictionary(table.compactMap { record in record.footprint.map { (record.pid, $0) } },
                               uniquingKeysWith: { first, _ in first })
        let verdict = ProcessTable.assignSystemMemory(&table, verdict: nil, coalition: { coalitions[$0] }, usage: { usage[$0] },
                                                      footprint: { fresh[$0] })
        func row(_ pid: pid_t) -> ProcessRecord? { table.first { $0.pid == pid } }
        suite.expect(verdict == true, "three own single-process coalitions that match verify the read")
        suite.expect(row(67772)?.memory == .systemFootprint(megabytes(4.1)), "fseventsd is measured: 4.1 MB, as top shows")
        suite.expect(row(400)?.memory == .coalitionTotal(megabytes(1710), members: 2) && row(401)?.memory == .unknown,
                     "WindowServer's two tasks: the group total on the lowest pid only, the other unknown")
        suite.expect(row(701)?.memory == .unknown && row(700)?.memory == .footprint(megabytes(50)),
                     "a coalition shared with own processes leaves the restricted row unknown: nothing counted twice")

        var unverified = table.map { record -> ProcessRecord in
            var record = record
            if record.restricted { record.memory = .unknown }
            return record
        }
        var mismatch = usage
        mismatch[2] = .init(tasksStarted: 1, tasksExited: 0, footprint: megabytes(64 * 1.3))
        let undecided = ProcessTable.assignSystemMemory(&unverified, verdict: nil, coalition: { coalitions[$0] },
                                                        usage: { mismatch[$0] }, footprint: { fresh[$0] })
        suite.expect(undecided == nil && unverified.filter(\.restricted).allSatisfy { $0.memory == .unknown },
                     "one coalition that disagrees with its own members among two that agree leaves the check undecided (asked again next snapshot): every system row stays unknown meanwhile")
        var wrongField = usage
        for id in [UInt64(1), 2, 3] {
            wrongField[id] = .init(tasksStarted: 1, tasksExited: 0, footprint: megabytes(4096))
        }
        wrongField[3] = .init(tasksStarted: 4, tasksExited: 3, footprint: megabytes(4096))
        var rejected = unverified
        suite.expect(ProcessTable.assignSystemMemory(&rejected, verdict: nil, coalition: { coalitions[$0] },
                                                     usage: { wrongField[$0] }, footprint: { fresh[$0] }) == false
                        && rejected.filter(\.restricted).allSatisfy { $0.memory == .unknown },
                     "a field that disagrees on every own coalition fails the check: every system row stays unknown")
        suite.expect(ProcessTable.coalitionReadVerified([(megabytes(10), megabytes(10)), (megabytes(5), megabytes(5.5)),
                                                         (megabytes(300), megabytes(303))]) == true
                        && ProcessTable.coalitionReadVerified([(megabytes(10), megabytes(10)), (megabytes(130), megabytes(100))]) == nil
                        && ProcessTable.coalitionReadVerified([(megabytes(10), megabytes(20)), (megabytes(130), megabytes(100)),
                                                               (megabytes(1), megabytes(9))]) == false
                        && ProcessTable.coalitionReadVerified([]) == nil
                        && ProcessTable.coalitionReadVerified([(megabytes(10), megabytes(10))]) == nil,
                     "verified: 3 within max(1 MiB, 2%); one off among few waits; off on every sample fails; too few samples wait")

        // 8. A root process can never be ended.
        let leak = fseventsd(.systemFootprint(gigabytes(54)))
        var history = MemoryHolderHistory()
        let ranked = MemoryHolders.rank([leak], context: context(), history: &history, now: now,
                                        thresholds: MemoryHolderThresholds())
        suite.expect(ranked.first?.isFSEvents == true && ranked.first?.canEnd == false && ranked.first?.isSystem == true
                        && leak.startedAt > 0,
                     "fseventsd, with its kinfo start time, is never offered End")
        let views = holdersSource("Sources/Brim/Modules/Memory/MemoryViews.swift")
        let row = section(views, from: "struct MemoryHolderRow: View {", to: "/// Chips laid out on as many lines")
        suite.expect(row.contains("} else if holder.canEnd {") && row.components(separatedBy: "service.endHolder(").count == 2
                        && row.contains("text.systemNeverEnded"),
                     "a holder row offers End only when holder.canEnd, and says a system process is never ended")
        let processTable = holdersSource("Sources/Brim/Modules/Memory/ProcessTable.swift")
        let startTime = section(processTable, from: "    static func startTime(pid: pid_t) -> UInt64? {",
                                to: "    /// Whether `identity` still names")
        suite.expect(startTime.contains("bsdInfo(pid)") && !startTime.contains("kernelStartTime"),
                     "the identity every destructive path checks still reads bsdinfo only, which root's processes refuse")
        let service = holdersSource("Sources/Brim/Modules/Memory/MemoryService.swift")
        suite.expect(service.contains("guard isRunning, holder.canEnd, !holder.isSystem, !busy.contains(key)"),
                     "End on a holder refuses system rows a second time")
        suite.expect(!processTable.contains("\"/bin/ps\"") && !processTable.contains("/usr/bin/top"),
                     "system memory is read in the one enumerator, never by spawning ps or top")

        // 19. Read-only, on this Mac.
        let live = ProcessTable.snapshot(options: [.systemMemory])
        let wrong = live.filter(\.restricted).filter { record in
            switch record.memory {
            case .systemFootprint(let bytes): return bytes == 0
            case .coalitionTotal(let bytes, let members): return bytes == 0 || members < 2
            case .footprint: return true
            case .unknown: return false
            }
        }
        suite.expect(!live.isEmpty && wrong.isEmpty,
                     "every other user's row is measured (> 0), a group total of 2+, or unknown: \(wrong.prefix(3).map(\.name))")
        if ProcessTable.coalitionReadsVerified == true, let daemon = live.first(where: MemoryRules.isFSEventsDaemon) {
            suite.expect(daemon.memory != .unknown && daemon.startedAt > 0 && ProcessTable.startTime(pid: daemon.pid) == nil,
                         "on this Mac fseventsd is measured and dated, and still has no identity to act on")
        }
    }

    // MARK: 9–11. Holders and growth

    private static func holdersAndGrowth(_ suite: TestSuite) {
        let thresholds = MemoryHolderThresholds()
        let text = FeatureStrings.memory(.enUS)
        // 9. The incident: 4 MB on Nov 4, 133 MB on Nov 13 06:14, 54 GiB on
        // Nov 14 19:11 (36 h 57 min later).
        let incident = now
        let nov13 = incident.addingTimeInterval(-(36 * 3600 + 57 * 60))
        let nov4 = incident.addingTimeInterval(-10 * 86_400)
        var history = MemoryHolderHistory()
        _ = MemoryHolders.rank([fseventsd(.systemFootprint(megabytes(4)))], context: context(at: nov4), history: &history,
                               now: nov4, thresholds: thresholds)
        let healthyThen = MemoryHolders.rank([fseventsd(.systemFootprint(megabytes(133)))], context: context(at: nov13),
                                             history: &history, now: nov13, thresholds: thresholds)
        suite.expect(healthyThen.isEmpty, "133 MB, fseventsd's healthy 8.5-day peak, is not listed")
        let ranked = MemoryHolders.rank([fseventsd(.systemFootprint(gigabytes(54)))], context: context(at: incident),
                                        history: &history, now: incident, thresholds: thresholds)
        let leak = ranked.first
        let perHour = Double(leak?.perHour ?? 0) / gib
        suite.expect(leak?.isFSEventsLeak == true && leak?.growing == true && perHour > 1.44 && perHour < 1.48,
                     "the 133 MB → 54 GB series names fseventsd, growing ≈ 1.46 GB/h: \(perHour)")
        let decided = MemoryNotifications.plan(episodeNotifies: false, critical: false, holders: ranked, counts: nil,
                                               canQuitSomething: false, notifiedLeak: nil, text: text)
        suite.expect(decided.plan?.kind == .leak && decided.plan?.title == "fseventsd is leaking memory"
                        && decided.plan?.body == "fseventsd (system) 54 GB, growing ~1.5 GB/h. Known macOS leak; Brim can't end it. Copy the restart command and run it in Terminal."
                        && decided.plan?.actions == [.copyRestart, .review] && decided.leakToMark == leak?.identity,
                     "the leak notification names it and offers Copy restart command: \(String(describing: decided.plan?.body))")
        let again = MemoryNotifications.plan(episodeNotifies: false, critical: false, holders: ranked, counts: nil,
                                             canQuitSomething: false,
                                             notifiedLeak: MemoryNotifications.leakKey(leak?.identity ?? ProcessIdentity(pid: 0, startedAt: 0)),
                                             text: text)
        suite.expect(again.plan == nil && again.leakToMark == nil, "once per fseventsd identity, also across a relaunch")
        // After a restart: a new identity (the pid may even be reused).
        let restarted = fseventsd(.systemFootprint(megabytes(4)), pid: 67772, startedAt: 1_794_500_100_000_000)
        let fresh = MemoryHolders.rank([restarted], context: context(at: incident.addingTimeInterval(120)),
                                       history: &history, now: incident.addingTimeInterval(120), thresholds: thresholds)
        let afterRestart = MemoryNotifications.plan(episodeNotifies: false, critical: false, holders: fresh, counts: nil,
                                                    canQuitSomething: false, notifiedLeak: nil, text: text)
        suite.expect(fresh.isEmpty && afterRestart.plan == nil && !history.isTracked(leak?.identity ?? restarted.identity)
                        && history.rate(of: restarted.identity, thresholds: thresholds) == nil,
                     "a restarted fseventsd starts a fresh series, and nothing is posted")

        // 10. A healthy fseventsd stays quiet: 3.8–4.3 MB across 25 min.
        var quietHistory = MemoryHolderHistory()
        var quiet: [MemoryHolder] = []
        for (minutes, mb) in [(0.0, 3.8), (10.0, 4.3), (25.0, 4.1)] {
            let at = now.addingTimeInterval(minutes * 60)
            quiet = MemoryHolders.rank([fseventsd(.systemFootprint(megabytes(mb)))], context: context(at: at),
                                       history: &quietHistory, now: at, thresholds: thresholds)
        }
        var followUp = MemoryFollowUp()
        let elevated = quiet.contains { $0.isFSEvents || $0.growing }
        suite.expect(quiet.isEmpty
                        && MemoryNotifications.plan(episodeNotifies: false, critical: false, holders: quiet, counts: nil,
                                                    canQuitSomething: false, notifiedLeak: nil, text: text).plan == nil
                        && followUp.next(after: now, elevated: elevated, grew: false, clockPaused: false) == nil,
                     "a healthy fseventsd is not listed, notifies nothing and arms no follow-up")

        // 11. T-43: node 39207 under zsh under a Claude session in GreenUp.
        let greenup = home + "/Code/GreenUp"
        let claude = process(39000, ppid: 38990, pgid: 39000, path: home + "/.local/share/claude/versions/2.1.0",
                             arguments: ["claude"], mb: 690, cpu: 600, cwd: greenup)
        let shell = process(39100, ppid: 39000, pgid: 39100, path: "/bin/zsh", arguments: ["/bin/zsh", "-c", "npm run dev"],
                            mb: 2, cpu: 0, cwd: greenup)
        func node(_ gb: Double) -> ProcessRecord {
            var record = process(39207, ppid: 39100, pgid: 39100, path: "/opt/homebrew/Cellar/node/26.13.0_2/bin/node",
                                 arguments: ["node", "server.js"], mb: 1, cpu: 900, cwd: greenup)
            record.memory = .footprint(gigabytes(gb))
            return record
        }
        var nodeHistory = MemoryHolderHistory()
        _ = MemoryHolders.rank([claude, shell, node(8)], context: context(), history: &nodeHistory, now: now,
                               thresholds: thresholds)
        let later = now.addingTimeInterval(30 * 60)
        let runaway = MemoryHolders.rank([claude, shell, node(35)], context: context(at: later), history: &nodeHistory,
                                         now: later, thresholds: thresholds)
        let nodeRow = runaway.first { $0.identity.pid == 39207 }
        suite.expect(nodeRow?.growing == true && nodeRow?.kind == .own(project: "GreenUp", inAgentSession: .claude)
                        && nodeRow?.canEnd == true && runaway.first?.identity.pid == 39207,
                     "a 35 GB node growing in a Claude session is named first, in its project, and can be ended")
        let line = nodeRow.map(text.holderLine) ?? ""
        suite.expect(line == "node · GreenUp (in a Claude session) 35 GB, growing ~54 GB/h.", "its sentence: \(line)")
        let episodeNote = MemoryNotifications.plan(episodeNotifies: true, critical: false, holders: runaway,
                                                   counts: "Apps unused for 8 h+: 1 (2 GB). Leftovers: 0 (Zero KB).",
                                                   canQuitSomething: true, notifiedLeak: nil, text: text)
        suite.expect(episodeNote.plan?.kind == .episode && episodeNote.plan?.title == "Memory is tight"
                        && episodeNote.plan?.body.hasPrefix(line) == true
                        && episodeNote.plan?.actions == [.quitThem, .review],
                     "the episode notification names the runaway first: \(String(describing: episodeNote.plan?.body))")
        // An own process merely big is not "growing": a Simulator clone's
        // 10 GB is many small processes.
        var flatHistory = MemoryHolderHistory()
        _ = MemoryHolders.rank([node(9)], context: context(), history: &flatHistory, now: now, thresholds: thresholds)
        let flat = MemoryHolders.rank([node(9.5)], context: context(at: later), history: &flatHistory, now: later,
                                      thresholds: thresholds)
        suite.expect(flat.first?.growing == false && flat.first?.perHour == nil,
                     "an own process must gain 2 GB+ to count as growing")
    }

    // MARK: 12. Episodes

    private static func episodes(_ suite: TestSuite) {
        // The incident's swap rose from 9.6 to 35.8 GB (the middle readings
        // are fixture steps); readings 20 min apart.
        var rising = MemoryTightEpisode()
        var changes: [MemoryTightEpisode.Change] = []
        var notified: [Bool] = []
        for (index, swap) in [9.6, 10.7, 13.0, 35.8].enumerated() {
            changes.append(rising.update(pressure: .normal, reading: measurement(minutes: Double(index) * 20, swap: swap)))
            notified.append(rising.shouldNotify())
        }
        suite.expect(changes.first == .unchanged && changes.dropFirst().first.map({
                        if case .opened(.swapGrowth) = $0 { return true } else { return false } }) == true
                        && notified == [false, true, false, false],
                     "the episode opens at the first +1 GiB of swap and notifies once: \(changes), \(notified)")

        var stale = MemoryTightEpisode()
        let staleChanges = (0..<4).map { stale.update(pressure: .normal, reading: measurement(minutes: Double($0) * 5, swap: 8.7)) }
        suite.expect(staleChanges.allSatisfy { $0 == .unchanged } && !stale.isTight,
                     "8.7 GB of old swap with no swap-outs never opens an episode")

        var atStart = MemoryTightEpisode()
        suite.expect(atStart.update(pressure: .warning, reading: measurement(minutes: 0, swap: 8.7)) == .opened(.pressure(.warning))
                        && atStart.isTight,
                     "pressure already at warning when the module starts opens an episode on the first update")
        _ = atStart.update(pressure: .critical, reading: measurement(minutes: 1, swap: 8.7))
        suite.expect(atStart.isCritical, "critical pressure makes the episode critical")
        let calm1 = atStart.update(pressure: .normal, reading: measurement(minutes: 2, swap: 8.7, swapOutsMB: 100))
        let calm2 = atStart.update(pressure: .normal, reading: measurement(minutes: 7, swap: 8.7, swapOutsMB: 105))
        let calm3 = atStart.update(pressure: .normal, reading: measurement(minutes: 12.5, swap: 9.0, swapOutsMB: 108))
        suite.expect(calm1 == .unchanged && calm2 == .unchanged && calm3 == .unchanged && atStart.isTight,
                     "swap that grew restarts the calm span")
        let calm4 = atStart.update(pressure: .normal, reading: measurement(minutes: 23, swap: 9.0, swapOutsMB: 110))
        suite.expect(calm4 == .closed && !atStart.isTight && atStart.swapBaseline == gigabytes(9.0),
                     "normal pressure and two quiet readings 10 min apart close it and re-baseline swap")

        var live = MemoryTightEpisode()
        _ = live.update(pressure: .normal, reading: measurement(minutes: 0, swap: 20, swapOutsMB: 1000))
        let swapping = live.update(pressure: .normal, reading: measurement(minutes: 2, swap: 20, swapOutsMB: 1300))
        suite.expect({ if case .opened(.swapOuts) = swapping { return true } else { return false } }(),
                     "300 MiB swapped out in 2 min opens an episode with swap used flat: \(swapping)")
        var slow = MemoryTightEpisode()
        _ = slow.update(pressure: .normal, reading: measurement(minutes: 0, swap: 20, swapOutsMB: 1000))
        suite.expect(slow.update(pressure: .normal, reading: measurement(minutes: 20, swap: 20, swapOutsMB: 1300)) == .unchanged,
                     "readings more than 15 min apart say nothing about live swap-outs")

        // A SystemMonitor reading it already took: a scan only on a jump.
        let last = measurement(minutes: 0, swap: 10, compressor: 20)
        suite.expect(MemoryMeasuredChange.monitorReadingWarrantsScan(swapUsed: gigabytes(11.1), compressed: nil, last: last)
                        && MemoryMeasuredChange.monitorReadingWarrantsScan(swapUsed: nil, compressed: gigabytes(22.5), last: last)
                        && !MemoryMeasuredChange.monitorReadingWarrantsScan(swapUsed: gigabytes(10.5), compressed: gigabytes(21),
                                                                            last: last)
                        && !MemoryMeasuredChange.monitorReadingWarrantsScan(swapUsed: gigabytes(40), compressed: nil, last: nil),
                     "a monitor reading scans only when swap rose 1 GiB or the compressor 2 GiB")
    }

    // MARK: 13. One alert path

    private static func notificationText(_ suite: TestSuite) {
        let text = FeatureStrings.memory(.enUS)
        let windowServer = MemoryHolder(identity: ProcessIdentity(pid: 400, startedAt: 1), name: "WindowServer", path: "",
                                        kind: .system, memory: .coalitionTotal(megabytes(1710), members: 2), perHour: nil,
                                        growing: false, isFSEventsLeak: false, isFSEvents: false, canEnd: false)
        var alone = windowServer
        alone.memory = .systemFootprint(gigabytes(6))
        suite.expect(text.holderLine(alone) == "WindowServer (system) 6 GB."
                        && text.holderLine(windowServer) == "WindowServer and 1 more (system) \(MemoryFormat.bytes(megabytes(1710))).",
                     "system holders' sentences: \(text.holderLine(windowServer))")
        suite.expect(MemoryFormat.rate(gigabytes(1.46)) == "~1.5 GB/h" && MemoryFormat.rate(gigabytes(54)) == "~54 GB/h"
                        && MemoryFormat.rate(megabytes(300)) == "~300 MB/h",
                     "rates: one decimal under 10, whole above, 1024-based")
        let critical = MemoryNotifications.plan(episodeNotifies: true, critical: true, holders: [], counts: nil,
                                                canQuitSomething: false, notifiedLeak: nil, text: text)
        suite.expect(critical.plan?.title == "Memory is critical" && critical.plan?.actions == [.review]
                        && critical.plan?.body == text.notificationNothing,
                     "a critical episode with nothing to name or quit still says so, with Review only")
        // Both would fire in one scan: only the episode posts, the leak counts as told.
        let leak = MemoryHolder(identity: ProcessIdentity(pid: 67772, startedAt: 5), name: "fseventsd", path: fseventsdPath,
                                kind: .system, memory: .systemFootprint(gigabytes(54)), perHour: gigabytes(1.46),
                                growing: true, isFSEventsLeak: true, isFSEvents: true, canEnd: false)
        let both = MemoryNotifications.plan(episodeNotifies: true, critical: false, holders: [leak, windowServer],
                                            counts: nil, canQuitSomething: false, notifiedLeak: nil, text: text)
        suite.expect(both.plan?.kind == .episode && both.plan?.actions == [.review, .copyRestart]
                        && both.leakToMark == leak.identity
                        && both.plan?.body == "fseventsd (system) 54 GB, growing ~1.5 GB/h. Known macOS leak; Brim can't end it.",
                     "with an episode open the leak rides the episode notification, with Copy restart command")
        suite.expect(MemoryNotifications.identity(fromKey: MemoryNotifications.leakKey(leak.identity)) == leak.identity
                        && MemoryNotifications.identity(fromKey: "garbage") == nil,
                     "the remembered leak identity round-trips")

        // One memory notification path.
        let paths = ["Sources/Brim/Services/SystemMonitor/MonitorAlertService.swift",
                     "Sources/Brim/Services/SystemMonitor/SystemMonitor.swift", "Sources/Brim/Core/FeatureCatalog.swift",
                     "Sources/Brim/UI/Settings/MonitorAlertsControls.swift", "Sources/Brim/Core/FeatureStrings.swift"]
        for path in paths {
            let source = holdersSource(path)
            // SystemMonitor's pressure read is what MemoryPressureMonitor
            // calls; only a subscription to the feed would be an alert.
            suite.expect(!source.isEmpty && !source.contains("MemoryPressureMonitor.shared") && !source.contains("monitorAlertMemory")
                            && !source.contains("alertMemory"),
                         "\(path) has no memory alert of its own")
        }
        let root = "Sources/Brim"
        let files = (FileManager.default.enumerator(atPath: root)?.allObjects as? [String]) ?? []
        let notifiers = files.filter { file in
            guard file.hasSuffix(".swift") else { return false }
            let source = holdersSource(root + "/" + file)
            return source.contains("Notifier.post(") && (source.contains("FeatureStrings.memory(") || source.contains("memoryTitle"))
        }
        suite.expect(notifiers == ["Modules/Memory/MemoryService.swift"], "MemoryService is the one memory notifier: \(notifiers)")
        let service = holdersSource("Sources/Brim/Modules/Memory/MemoryService.swift")
        suite.expect(service.contains("guard category == categoryIdentifier || category == holderCategoryIdentifier")
                        && service.contains("\"brim.memory.copy-restart\"")
                        && service.contains("setString(MemoryRules.fseventsdRestartCommand"),
                     "both memory categories are handled, and Copy restart command copies the command, never runs it")
        suite.expect(MemoryRules.fseventsdRestartCommand == "sudo killall fseventsd"
                        && !service.contains("Shell.run(\"/usr/bin/killall") && !service.contains("\"sudo\""),
                     "Brim never runs the restart itself")

        // The old alert's choice carries over, and its key goes.
        let name = "brim.tests.memory-alert.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            suite.expect(false, "a scratch defaults suite opens")
            return
        }
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "monitorAlertMemory")
        defaults.set(false, forKey: DefaultsKey.memoryNotify)
        Defaults.migrateMonitorAlertMemory(in: defaults)
        suite.expect(defaults.bool(forKey: DefaultsKey.memoryNotify) && defaults.object(forKey: "monitorAlertMemory") == nil,
                     "someone who had the critical-memory alert on keeps a memory notification; the old key is gone")
        defaults.set(false, forKey: "monitorAlertMemory")
        Defaults.migrateMonitorAlertMemory(in: defaults)
        suite.expect(defaults.bool(forKey: DefaultsKey.memoryNotify) && defaults.object(forKey: "monitorAlertMemory") == nil,
                     "an old alert that was off changes nothing but goes")
        suite.expect(Defaults.registeredDefaults[DefaultsKey.memoryNotify] as? Bool == true,
                     "the Memory notification is registered on")
    }

    // MARK: 14–15. Measured deltas and the follow-up

    private static func measuredDeltas(_ suite: TestSuite) {
        func reading(used: Double, swap: Double, compressor: Double) -> MemoryMeasurement {
            MemoryMeasurement(at: now, awake: awakeAtNow, used: gigabytes(used), compressorRAM: gigabytes(compressor),
                              compressedLogical: 0, swapUsed: gigabytes(swap), swapTotal: gigabytes(36),
                              swapOuts: 0, swapIns: 0)
        }
        let before = reading(used: 100, swap: 35.8, compressor: 24)
        let after = reading(used: 98.8, swap: 9.6, compressor: 1)
        let a = ProcessIdentity(pid: 10, startedAt: 1)
        var watch = MemoryActionWatch(findingID: "g1", remaining: [a], footprints: [a: gigabytes(1.2)], before: before)
        _ = watch.exit(a)
        let change = watch.measuredChange(after: after)
        func delta(_ new: Double, _ old: Double) -> Int64 { Int64(gigabytes(new)) - Int64(gigabytes(old)) }
        suite.expect(change?.used == delta(98.8, 100) && change?.swapUsed == delta(9.6, 35.8)
                        && change?.compressorRAM == delta(1, 24)
                        && abs(Double(change?.swapUsed ?? 0) / gib + 26.2) < 0.01,
                     "the measured change is the whole Mac's: used −1.2 G, swap −26.2 G, compressed −23 G")
        suite.expect(watch.estimatedFreed == gigabytes(1.2), "the estimate stays separate from what was measured")
        var entry = MemoryActivityEntry(date: now, kind: .ended, title: "node", reasons: [])
        entry.estimatedBytes = gigabytes(1.2)
        entry.measuredBefore = before
        entry.measuredAfter = after
        let text = FeatureStrings.memory(.enUS)
        suite.expect(entry.measuredChange == change && text.measuredChange(change!).hasPrefix("Mac: used −")
                        && text.estimated(MemoryFormat.bytes(entry.estimatedBytes)) == "est. 1.2 GB"
                        && text.measuredHelp.contains("other apps"),
                     "the activity row shows the estimate and the measured change apart, never \"freed\"")

        // A log written before the rename still loads; systemDelta is dropped.
        let old = """
        [{"id":"5B0A1F0E-6C1B-4B8E-9A40-2E4F3C1D2B11","date":"2026-11-12T10:00:00Z","kind":"autoEnded","title":"python3 ×7",\
        "reasons":[],"commands":[],"footprint":191889408,"reclaimed":191889408,"systemDelta":154140672,\
        "outcome":"done","survivors":[],"targets":[]}]
        """
        let decoded = MemoryActivityLog.decoded(Data(old.utf8))
        let reencoded = decoded.encoded().map { String(decoding: $0, as: UTF8.self) } ?? ""
        suite.expect(decoded.entries.count == 1 && decoded.entries.first?.estimatedBytes == 191_889_408
                        && decoded.entries.first?.estimatedFreed == 191_889_408 && decoded.entries.first?.measuredChange == nil
                        && !reencoded.contains("systemDelta") && reencoded.contains("\"footprint\""),
                     "an old entry decodes, keeps its estimate, and drops systemDelta")
        let fresh = MemoryActivityLog.decoded(MemoryActivityLog(entries: [entry]).encoded())
        suite.expect(fresh.entries.first?.measuredChange == change, "measurements survive a save and a load")

        // 15. The growth follow-up's backoff.
        var followUp = MemoryFollowUp()
        var gaps: [TimeInterval] = []
        var at = now
        for _ in 0..<5 {
            let next = followUp.next(after: at, elevated: true, grew: false, clockPaused: false)
            gaps.append((next ?? at).timeIntervalSince(at) / 60)
            at = next ?? at
        }
        suite.expect(gaps == [10, 20, 40, 60, 60], "elevated, not growing: 10, 20, 40, 60, 60 min: \(gaps)")
        let grew = followUp.next(after: at, elevated: true, grew: true, clockPaused: false)
        suite.expect(grew == at.addingTimeInterval(600), "growth brings it back to 10 min")
        suite.expect(followUp.next(after: at, elevated: false, grew: false, clockPaused: false) == nil
                        && followUp.next(after: at, elevated: true, grew: true, clockPaused: true) == nil,
                     "nothing elevated, or the Mac asleep or locked: no follow-up")
        let service = holdersSource("Sources/Brim/Modules/Memory/MemoryService.swift")
        suite.expect(service.contains("let scanAt = [classifierDeadline, followUpDue].compactMap { $0 }.min()?.addingTimeInterval(1)")
                        && service.contains("(2) The growth follow-up"),
                     "the follow-up rides the one existing one-shot deadline, its reason recorded")
    }

    // MARK: 16, 18. Triggers and the log child

    private static func triggersAndLogChild(_ suite: TestSuite) {
        let table = #"{"timestamp":"2026-11-14 14:02:11.123456-0800","eventMessage":"event table has grown too large. (filled 1048576 / mask 0xfffff)","processImagePath":"\#(fseventsdPath)","processID":67772}"#
        let slowdown = #"{"timestamp":"2026-11-14 14:02:12.000001-0800","eventMessage":"SLOWDOWN: client 0x7f9a1c0 (pid 13889) sleeping due to too many errors (num usleeps 12)","processID":67772}"#
        let other = #"{"timestamp":"2026-11-14 14:02:13.000000-0800","eventMessage":"Resolve user group list","processID":67772}"#
        let at = Date(timeIntervalSince1970: 1_794_693_731.123)
        let tableEvent = MemoryRules.daemonLogEvent(ndjsonLine: table)
        if case .tableTooLarge(let when)? = tableEvent {
            suite.expect(abs(when.timeIntervalSince(at)) < 0.01, "the table line keeps fseventsd's own timestamp: \(when)")
        } else {
            suite.expect(false, "the table line is read: \(String(describing: tableEvent))")
        }
        if case .slowdown(let pid, _)? = MemoryRules.daemonLogEvent(ndjsonLine: slowdown) {
            suite.expect(pid == 13889, "the slow client's pid is read")
        } else {
            suite.expect(false, "the SLOWDOWN line is read")
        }
        suite.expect(MemoryRules.daemonLogEvent(ndjsonLine: other) == nil
                        && MemoryRules.daemonLogEvent(ndjsonLine: "Filtering the log data using …") == nil,
                     "any other line, and the stream's header, are ignored")
        suite.expect(MemoryRules.daemonLogPredicate.contains("process == \"fseventsd\"")
                        && MemoryRules.daemonLogPredicate.contains("event table has grown too large"),
                     "the log stream is filtered to fseventsd's own lines")

        let recorded = ProcessIdentity(pid: 5150, startedAt: 1_794_400_000_000_000)
        func child(ppid: pid_t = 1, startedAt: UInt64 = 1_794_400_000_000_000, path: String = "/usr/bin/log") -> ProcessRecord {
            ProcessRecord(pid: 5150, ppid: ppid, pgid: 5150, uid: 501, flags: 0, terminal: ProcessRecord.noTerminal,
                          startedAt: startedAt, name: "log", path: path, memory: .footprint(megabytes(9)), cpuTime: 1)
        }
        suite.expect(MemoryRules.shouldEndLeftoverLogChild(recorded: recorded, current: child()),
                     "a log child an earlier Brim left, adopted by launchd, is ended")
        suite.expect(!MemoryRules.shouldEndLeftoverLogChild(recorded: recorded, current: child(startedAt: 1_794_400_000_000_001))
                        && !MemoryRules.shouldEndLeftoverLogChild(recorded: recorded, current: child(path: "/bin/sleep"))
                        && !MemoryRules.shouldEndLeftoverLogChild(recorded: recorded, current: child(ppid: 4242))
                        && !MemoryRules.shouldEndLeftoverLogChild(recorded: recorded, current: nil)
                        && !MemoryRules.shouldEndLeftoverLogChild(recorded: nil, current: child()),
                     "a reused pid, another program, or a child Brim still owns is never ended")

        var backoff = MemoryRestartBackoff()
        suite.expect(backoff.mayStart(at: 0), "the log child starts at once")
        backoff.started(at: 0)
        backoff.exited(at: 10)
        suite.expect(!backoff.mayStart(at: 60) && backoff.mayStart(at: 70), "after an exit it waits 1 min")
        backoff.started(at: 70)
        backoff.exited(at: 80)
        suite.expect(!backoff.mayStart(at: 199) && backoff.mayStart(at: 200), "then 2 min")
        for step in 0..<8 {
            let time = 1000 + Double(step) * 4000
            backoff.started(at: time)
            backoff.exited(at: time + 1)
        }
        suite.expect(backoff.delay == MemoryRestartBackoff.longest, "doubling stops at 30 min")
        backoff.started(at: 100_000)
        backoff.exited(at: 100_000 + 3600)
        suite.expect(backoff.notBefore == 100_000 + 3600 + 60, "an hour alive resets it to 1 min")

        // 18. Rule 1 in the triggers: push sources, no timer.
        let triggers = holdersSource("Sources/Brim/Modules/Memory/MemoryTriggers.swift")
        suite.expect(triggers.contains("makeFileSystemObjectSource") && triggers.contains("O_EVTONLY")
                        && triggers.contains("\"/System/Volumes/VM\"") && triggers.contains("SystemMonitor.shared.$snapshot")
                        && triggers.contains("func ensureArmed(now: TimeInterval)") && !triggers.contains("Timer(")
                        && triggers.contains("POSIX_SPAWN_SETPGROUP") && triggers.contains("willTerminateNotification")
                        && triggers.contains("KillProcessService.signalVerified(") && !triggers.contains("Darwin.kill("),
                     "triggers: a kqueue swapfile watch, SystemMonitor's own readings, a log child in its own group ended through the verified path, no timer")
        let monitor = holdersSource("Sources/Brim/Services/SystemMonitor/SystemMonitor.swift")
        suite.expect(!monitor.contains("alertMemory"), "the sampler no longer runs for a memory alert")
    }

    // MARK: 17. Scan cost

    private static func scanCost(_ suite: TestSuite) {
        // The shared argument buffer: one allocation reused, garbage past
        // what the kernel wrote never read.
        func procargs(_ path: String, _ arguments: [String], environment: String) -> [UInt8] {
            var bytes: [UInt8] = []
            withUnsafeBytes(of: Int32(arguments.count).littleEndian) { bytes += $0 }
            bytes += Array(path.utf8) + [0, 0, 0, 0]
            for argument in arguments { bytes += Array(argument.utf8) + [0] }
            return bytes + Array(environment.utf8) + [0]
        }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 512, alignment: 1)
        defer { buffer.deallocate() }
        _ = buffer.initializeMemory(as: UInt8.self, repeating: 0xFF)
        let long = procargs("/bin/sleep", ["sleep", "30", "--with-a-long-argument"], environment: "HOME=/x")
        let short = procargs("/bin/ls", ["ls"], environment: "A=b")
        long.withUnsafeBytes { buffer.copyMemory(from: $0) }
        let first = ProcessTable.parseArguments(buffer: UnsafeRawBufferPointer(buffer), size: long.count)
        short.withUnsafeBytes { buffer.copyMemory(from: $0) }
        let second = ProcessTable.parseArguments(buffer: UnsafeRawBufferPointer(buffer), size: short.count)
        suite.expect(first == ["sleep", "30", "--with-a-long-argument"] && second == ["ls"]
                        && ProcessTable.parseArguments(buffer: UnsafeRawBufferPointer(buffer), size: 2) == nil,
                     "argv parses the same through the reused buffer, whatever an earlier pid left in it")
        let me = ProcessTable.snapshot(options: [.arguments]).first { $0.pid == getpid() }
        suite.expect(me?.arguments == ProcessTable.arguments(pid: getpid()) && me?.arguments?.isEmpty == false,
                     "the snapshot's shared buffer and a single read agree on this test's argv")

        suite.expect(!MemoryClassifier.needsLaunchdJobs(orphanGroup(), context: context())
                        && !MemoryClassifier.needsLaunchdJobs(claudeShell(), context: context()),
                     "groups whose leader is gone never need launchctl")
        let detached = process(4700, pgid: 4700, path: home + "/.nvm/versions/node/v22.11.0/bin/node",
                               arguments: ["node", "worker.js"], mb: 200, cpu: 10)
        suite.expect(MemoryClassifier.needsLaunchdJobs(orphanGroup() + [detached], context: context()),
                     "a candidate group with a living leader does")
        let service = holdersSource("Sources/Brim/Modules/Memory/MemoryService.swift")
        suite.expect(service.components(separatedBy: "MemorySystemReads.launchdJobs()").count == 2
                        && service.contains("if launchctlRan { context.launchdJobs = MemorySystemReads.launchdJobs() }")
                        && service.contains("let launchctlRan = MemoryClassifier.needsLaunchdJobs("),
                     "launchctl list runs only under needsLaunchdJobs")

        let records = [fseventsd(.systemFootprint(megabytes(4))), fseventsd(.unknown, pid: 90),
                       process(4700, pgid: 4700, path: "/x/node", arguments: ["node"], mb: 10, cpu: 1)]
        let cost = MemoryScanCost(at: now, duration: 0.1824, records: records, ownUID: 501, socketTables: 31,
                                  launchctlRan: false, logChildCPU: 0.42)
        suite.expect(cost.logLine(trigger: "swap")
                        == "memory scan (swap): 3 processes (1 own, 1 system measured, 1 unknown), 31 socket tables, launchctl skipped, 182 ms, log child cpu 0.4 s",
                     "one log line per scan: \(cost.logLine(trigger: "swap"))")
        let text = FeatureStrings.memory(.enUS)
        suite.expect(text.lastScan("0.18", "1,622") == "Last scan: 0.18 s for 1,622 processes", "the Settings cost line")
    }
}
