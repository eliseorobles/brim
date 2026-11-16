// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// T-42 review fixes for the Memory module (the Claude and Codex reviews of
/// 2026-11-14). Each test reproduces the failure the review described.
///
/// Fixtures only: nothing here signals, quits or kills a process, spawns a
/// child, or writes outside a scratch defaults suite.
extension BrimMemoryTests {
    static func reviewFixes(_ suite: TestSuite) {
        suite.run("memory review: a monitor reading never acts") { monitorReadingNeverActs(suite) }
        suite.run("memory review: Brim's own exits are not outside ones") { brimsOwnExits(suite) }
        suite.run("memory review: a skipped group stays eligible") { skippedGroupStaysEligible(suite) }
        suite.run("memory review: queued actions need current authorization") { queuedAuthorization(suite) }
        suite.run("memory review: unread swap is unknown") { unreadSwap(suite) }
        suite.run("memory review: the log child is owned from spawn") { ownedLogChild(suite) }
        suite.run("memory review: coalition check bracketed") { bracketedCoalitionCheck(suite) }
    }

    private static var reviewedService: String { holdersSource("Sources/Brim/Modules/Memory/MemoryService.swift") }

    private static func holderFixture(_ pid: pid_t, gb: Double, system: Bool = false,
                                      fsevents: Bool = false) -> MemoryHolder {
        MemoryHolder(identity: ProcessIdentity(pid: pid, startedAt: 1_794_000_000_000_000 + UInt64(pid)),
                     name: fsevents ? "fseventsd" : "proc\(pid)", path: fsevents ? fseventsdPath : "/x/proc\(pid)",
                     kind: system ? .system : .own(project: nil, inAgentSession: nil),
                     memory: system ? .systemFootprint(gigabytes(gb)) : .footprint(gigabytes(gb)),
                     perHour: nil, growing: false, isFSEventsLeak: fsevents && gb >= 1, isFSEvents: fsevents,
                     canEnd: !system)
    }

    // MARK: Claude review 1: opening the panel ends nothing

    /// Real failure: with memory tight, opening the panel started
    /// SystemMonitor's sampler; its first reading, compared with a
    /// measurement up to an hour old, queued a `.swap` scan, which won over
    /// the panel's `.foreground` scan and ran the automatic tier.
    private static func monitorReadingNeverActs(_ suite: TestSuite) {
        let eligible = twoScans(orphanGroup())
        suite.expect(eligible.findings(in: .autoLeftover).map(\.pgid) == [38773], "the fixture group is eligible")
        // The stale baseline: the last scan was a follow-up 60 minutes ago;
        // the compressor grew 2.5 GiB since, inside existing swapfiles.
        let stale = measurement(minutes: -60, swap: 10, compressor: 20)
        let panelReading = MemoryMeasuredChange.monitorReadingWarrantsScan(swapUsed: gigabytes(10.2),
                                                                           compressed: gigabytes(22.5), last: stale)
        suite.expect(panelReading, "the panel's first reading against the stale baseline warrants a scan")
        // The panel's own scan is in flight; the reading's scan queues behind it.
        let queued = MemoryScanTrigger.queued(after: .foreground, incoming: .monitorReading)
        let targets = MemoryClassifier.autoTargets(eligible.findings, thresholds: MemoryThresholds(),
                                                   trigger: queued, memoryTight: true)
        suite.expect(queued == .monitorReading && targets.isEmpty,
                     "the scan a panel-open reading queues ends nothing, even while memory is tight")
        suite.expect(MemoryScanTrigger.queued(after: .pressure, incoming: .monitorReading) == .pressure
                        && MemoryScanTrigger.queued(after: .monitorReading, incoming: .swap) == .swap
                        && MemoryScanTrigger.queued(after: nil, incoming: .foreground) == .foreground
                        && MemoryScanTrigger.queued(after: .swap, incoming: .pressure) == .pressure,
                     "an outside event's queued scan is never replaced by one that never acts, and replaces one that never acts")
        let reading = section(reviewedService, from: "    private func monitorReading(", to: "    /// A line fseventsd logged")
        suite.expect(reading.contains("scan(.monitorReading)") && !reading.contains("scan(.swap)")
                        && reviewedService.contains("pendingTrigger = MemoryScanTrigger.queued(after: pendingTrigger, incoming: trigger)"),
                     "a SystemMonitor reading scans as .monitorReading, never as the swapfile watch's .swap")
    }

    // MARK: Claude review 2: Brim's own End and Quit are not exits outside Brim

    /// Real failure: a quit app's 1 GB helper, and a group member between
    /// End and its signal, kept their exit watches; their exit was logged as
    /// "Ended outside Brim" and started a `.holderExit` scan that may run the
    /// automatic tier, past the per-event cap.
    private static func brimsOwnExits(_ suite: TestSuite) {
        let app: pid_t = 900
        let helper = holderFixture(901, gb: 1.5)
        let member = holderFixture(950, gb: 2)
        let unrelated = holderFixture(960, gb: 1.2)
        let daemon = holderFixture(67772, gb: 2, system: true, fsevents: true)
        let small = holderFixture(970, gb: 0.5)
        let owners: [pid_t: pid_t] = [901: app]
        let holders = [member, daemon, helper, unrelated, small]
        let floor = MemoryHolderThresholds().exitWatchFloor
        func watched(ending: Set<ProcessIdentity>, quitApps: Set<pid_t>) -> [pid_t] {
            MemoryHolderExitWatch.targets(holders, floor: floor, limit: 8, ending: ending, quitApps: quitApps,
                                          owner: { owners[$0] ?? $0 }).map(\.holder.identity.pid)
        }
        suite.expect(watched(ending: [], quitApps: []) == [950, 67772, 901, 960],
                     "with Brim acting on nothing every 1 GB+ holder is watched")
        suite.expect(watched(ending: [], quitApps: [app]) == [950, 67772, 960],
                     "quitting an app drops its 1.5 GB helper's exit watch: that exit is Brim's Quit")
        suite.expect(watched(ending: [member.identity], quitApps: []) == [67772, 901, 960],
                     "a group member between End and its signal is not watched again by a rescan")
        let armed = MemoryHolderExitWatch.targets(holders, floor: floor, limit: 8, ending: [], quitApps: [],
                                                  owner: { owners[$0] ?? $0 })
        suite.expect(armed.first { $0.holder.identity.pid == 901 }?.owner == app,
                     "each watch keeps the responsible app read while it runs")
        suite.expect(MemoryHolderExitWatch.isBrims(helper.identity, owner: app, ending: [], quitApps: [app])
                        && MemoryHolderExitWatch.isBrims(member.identity, owner: 950, ending: [member.identity], quitApps: [])
                        && !MemoryHolderExitWatch.isBrims(unrelated.identity, owner: 960, ending: [member.identity],
                                                          quitApps: [app]),
                     "a quit app's helper or an ending member exiting is Brim's own; anything else is outside")
        suite.expect(MemoryHolderExitWatch.stillQuitting([app], running: [], holderOwners: [app]) == [app]
                        && MemoryHolderExitWatch.stillQuitting([app], running: [app], holderOwners: []) == [app]
                        && MemoryHolderExitWatch.stillQuitting([app], running: [], holderOwners: []).isEmpty,
                     "a quit app stays Brim's while it runs or a big helper still names it, then is forgotten")

        let service = reviewedService
        let exited = section(service, from: "    private func holderExited(", to: "    nonisolated static func busyKey(")
        let guardAt = exited.range(of: "MemoryHolderExitWatch.isBrims(")
        let logAt = exited.range(of: "log.add(entry)")
        let scanAt = exited.range(of: "scan(.holderExit)")
        suite.expect(guardAt != nil && logAt != nil && scanAt != nil && guardAt!.lowerBound < logAt!.lowerBound
                        && guardAt!.lowerBound < scanAt!.lowerBound,
                     "a holder exit Brim caused is neither logged as outside Brim nor starts an outside-event scan")
        let quit = section(service, from: "    func quit(_ row: MemoryIdleAppRow) {", to: "    /// Reopen a quit app.")
        suite.expect(quit.contains("quitApps.insert(row.app.pid)") && quit.contains("watch.owner == row.app.pid"),
                     "Quit cancels the watches on the app and on every helper it is responsible for")
        let end = section(service, from: "    private func end(_ finding: MemoryFinding, automatic: Bool", to: "    func endHolder(")
        let targetsAt = end.range(of: "busyTargets[finding.id] = finding.identities")
        let queueAt = end.range(of: "actionQueue.async")
        suite.expect(targetsAt != nil && queueAt != nil && targetsAt!.lowerBound < queueAt!.lowerBound
                        && service.contains("ending: brimEnding, quitApps: quitApps"),
                     "an End's members count as Brim's from the click, before the queue runs, so a rescan can't re-arm them")
    }

    // MARK: Claude review 3: the tier marks only what it signalled

    /// Real failure: the tier recorded a group in autoSignalled before the
    /// re-check; a re-check that skipped it (a socket for a moment) still
    /// excluded it for as long as it was listed, while its chip said "ends
    /// automatically".
    private static func skippedGroupStaysEligible(_ suite: TestSuite) {
        let eligible = twoScans(orphanGroup())
        guard let group = eligible.findings(in: .autoLeftover).first else {
            suite.expect(false, "the fixture group is eligible")
            return
        }
        let skipped = MemoryClassifier.signalledByTier(group.identities, attempted: [])
        suite.expect(skipped.isEmpty && autoTargets(eligible.findings, alreadySignalled: skipped).map(\.pgid) == [38773],
                     "a group the re-check skipped is still offered on the next outside event")
        let attempted = Set(group.identities.map(\.pid))
        let signalled = MemoryClassifier.signalledByTier(group.identities, attempted: attempted)
        suite.expect(signalled == Set(group.identities) && autoTargets(eligible.findings, alreadySignalled: signalled).isEmpty,
                     "a group the tier did signal is not signalled by it again")
        let service = reviewedService
        let finished = section(service, from: "    private func scanFinished(", to: "    /// The growth follow-up's next moment")
        let signalledBody = section(service, from: "    private func signalled(", to: "    private func watchExit(")
        suite.expect(!finished.contains("autoSignalled.formUnion") && signalledBody.contains("entry.kind == .autoEnded")
                        && signalledBody.contains("MemoryClassifier.signalledByTier(members, attempted: attempted)")
                        && signalledBody.contains("[.sent, .refused, .failed]"),
                     "the tier records a process once a signal was attempted on it, never at the pick")
    }

    // MARK: Codex review 1: queued actions outlive nothing

    /// Real failure: an automatic End waiting behind a slow action (a
    /// Simulator shutdown waits up to 60 s) signalled after cleanup was
    /// turned off, the group was kept, the episode closed or the module
    /// stopped: nothing checked again before the signal.
    private static func queuedAuthorization(_ suite: TestSuite) {
        let authority = MemoryActionAuthority()
        let automatic = authority.ticket(.automatic)
        let quitThem = authority.ticket(.quitThem)
        let click = authority.ticket(.direct)
        suite.expect(authority.isCurrent(automatic) && authority.isCurrent(quitThem) && authority.isCurrent(click),
                     "tickets are current until something changes")
        authority.revoke(.autoCleanOff)
        suite.expect(!authority.isCurrent(automatic) && authority.isCurrent(quitThem) && authority.isCurrent(click),
                     "turning cleanup off cancels a queued automatic End, not a click")
        let afterOff = authority.ticket(.automatic)
        authority.revoke(.episodeClosed)
        suite.expect(!authority.isCurrent(afterOff), "the episode closing cancels a queued automatic End")
        let beforeKeep = authority.ticket(.automatic)
        authority.revoke(.keepChanged)
        suite.expect(!authority.isCurrent(beforeKeep) && !authority.isCurrent(quitThem) && authority.isCurrent(click),
                     "a Keep change cancels queued automatic and Quit them actions; a row's End stays the person's")
        authority.revoke(.stopped)
        suite.expect(!authority.isCurrent(click) && authority.isCurrent(authority.ticket(.automatic)),
                     "stopping the module cancels everything queued; a ticket taken after is current")

        let service = reviewedService
        let end = section(service, from: "    private func end(_ finding: MemoryFinding, automatic: Bool", to: "    func endHolder(")
        let recheckAt = end.range(of: "MemoryClassifier.recheck(")
        let checkAt = end.range(of: "guard authority.isCurrent(ticket) else")
        let signalAt = end.range(of: "KillProcessService.signalVerified(")
        suite.expect(recheckAt != nil && checkAt != nil && signalAt != nil && recheckAt!.lowerBound < checkAt!.lowerBound
                        && checkAt!.lowerBound < signalAt!.lowerBound
                        && end.contains("authority.ticket(automatic ? .automatic : requirement == .idleConfirmed ? .quitThem : .direct)"),
                     "an End checks its ticket after the re-check and right before the signal")
        let holderEnd = section(service, from: "    func endHolder(", to: "    private func signalled(")
        suite.expect(holderEnd.contains("guard authority.isCurrent(ticket) else"), "a holder's End checks its ticket too")
        let reload = section(service, from: "    func reloadSettings() {", to: "    // MARK: Events")
        suite.expect(reload.contains("if fresh.keep != settings.keep { authority.revoke(.keepChanged) }")
                        && reload.contains("if settings.autoClean && !fresh.autoClean { authority.revoke(.autoCleanOff) }")
                        && service.contains("authority.revoke(.episodeClosed)") && service.contains("authority.revoke(.stopped)"),
                     "Keep changes, cleanup turned off, the episode closing and stop() revoke tickets")
    }

    // MARK: Codex review 2: an unread swap is unknown, never 0

    /// Real failure: both swap reads failed and swap counted as 0; that set
    /// the episode's baseline, so the next real reading of old, unchanged
    /// swap looked like 8.7 GB of new swap and opened a memory-tight episode
    /// (and the automatic tier) with pressure normal and nothing swapped out.
    private static func unreadSwap(_ suite: TestSuite) {
        let stats = VMStatisticsSnapshot(wiredPages: 0, purgeablePages: 0, compressorPages: 0, externalPages: 0,
                                         internalPages: 0, tagStoragePages: 0, swapIns: 10, swapOuts: 20,
                                         uncompressedPagesInCompressor: 30)
        func read(swap: (used: UInt64, total: UInt64)?) -> MemoryMeasurement? {
            MemoryMeasurement.reading(stats: stats, used: gigabytes(100), total: gigabytes(128),
                                      compressorRAM: gigabytes(10), swap: swap, page: 16_384, at: now, awake: awakeAtNow)
        }
        suite.expect(read(swap: nil) == nil, "an unread swap makes no measurement, never one with 0 swap")
        let full = read(swap: (gigabytes(8.7), gigabytes(10)))
        suite.expect(full?.swapUsed == gigabytes(8.7) && full?.swapTotal == gigabytes(10) && full?.swapOuts == 20 * 16_384
                        && full?.compressedLogical == 30 * 16_384,
                     "a full read keeps every number")
        var zeroed = MemoryTightEpisode()
        _ = zeroed.update(pressure: .normal, reading: measurement(minutes: 0, swap: 0))
        let wrong = zeroed.update(pressure: .normal, reading: measurement(minutes: 5, swap: 8.7))
        suite.expect({ if case .opened(.swapGrowth) = wrong { return true } else { return false } }(),
                     "the failure: a 0-swap baseline turns old swap into an episode")
        var fixed = MemoryTightEpisode()
        let first = fixed.update(pressure: .normal, reading: read(swap: nil))
        let second = fixed.update(pressure: .normal, reading: measurement(minutes: 5, swap: 8.7))
        let third = fixed.update(pressure: .normal, reading: measurement(minutes: 10, swap: 8.7))
        suite.expect(first == .unchanged && second == .unchanged && third == .unchanged && !fixed.isTight
                        && fixed.swapBaseline == gigabytes(8.7),
                     "with the unread reading skipped, the first real one sets the baseline and old swap opens nothing")
        let reads = holdersSource("Sources/Brim/Modules/Memory/MemorySystemReads.swift")
        suite.expect(reads.contains("MemoryMeasurement.reading(") && !reads.contains("memory.swapUsed ?? 0")
                        && !reads.contains("xsu_total : 0"),
                     "the whole-Mac reading goes through the one builder, with no 0 for an unread swap")
    }

    // MARK: Codex review 6: the log child is owned from spawn

    /// Real failure: the child spawned, its bsdinfo read failed (a child
    /// that already exited is a zombie, which bsdinfo refuses), and it was
    /// dropped after one WNOHANG wait: a running child left unowned, or a
    /// zombie left unreaped, while the next one started.
    private static func ownedLogChild(_ suite: TestSuite) {
        suite.expect(MemoryRules.spawnedChildIdentity(pid: 5150, bsdStart: nil, kernelStart: 1_794_400_000_000_000)
                        == ProcessIdentity(pid: 5150, startedAt: 1_794_400_000_000_000),
                     "a child whose bsdinfo is refused still has an identity from the kernel's own record")
        suite.expect(MemoryRules.spawnedChildIdentity(pid: 5150, bsdStart: 7, kernelStart: 7)
                        == ProcessIdentity(pid: 5150, startedAt: 7)
                        && MemoryRules.spawnedChildIdentity(pid: 5150, bsdStart: nil, kernelStart: nil) == nil
                        && MemoryRules.spawnedChildIdentity(pid: 5150, bsdStart: 0, kernelStart: nil) == nil
                        && MemoryRules.spawnedChildIdentity(pid: 0, bsdStart: 7, kernelStart: 7) == nil,
                     "bsdinfo first; nil only when the kernel has no such process")
        let triggers = holdersSource("Sources/Brim/Modules/Memory/MemoryTriggers.swift")
        let start = section(triggers, from: "    private func startLogChild(", to: "    private func logChildExited(")
        let identityAt = start.range(of: "MemoryRules.spawnedChildIdentity(")
        let exitAt = start.range(of: "DispatchSource.makeProcessSource(identifier: pid")
        suite.expect(identityAt != nil && exitAt != nil && identityAt!.lowerBound < exitAt!.lowerBound
                        && !start.contains("let startedAt = ProcessTable.startTime(pid: pid)")
                        && start.contains("waitpid(pid, nil, WNOHANG) == pid { logChildExited(identity) }"),
                     "every spawned child gets an exit source that reaps it; a zombie found at once is reaped then")
        let end = section(triggers, from: "    private func endLogChild() {", to: "\n}\n")
        suite.expect(end.contains("results[identity.pid] == .gone") && end.contains("waitpid(identity.pid, nil, WNOHANG)")
                        && !triggers.contains("Darwin.kill("),
                     "ending a child that is already gone reaps its zombie; signals still go through the verified path")
    }

    // MARK: Codex review 7: the coalition check survives allocation

    /// Real failure: the check compared coalition reads with footprints read
    /// earlier in the walk over every process; an app allocating in between
    /// made one mismatch, and that one mismatch disabled system memory for
    /// the life of the process.
    private static func bracketedCoalitionCheck(_ suite: TestSuite) {
        let node = home + "/.nvm/versions/node/v22.11.0/bin/node"
        func table() -> [ProcessRecord] {
            [process(1001, pgid: 1001, path: node, arguments: ["node"], mb: 120, cpu: 1),
             process(1002, pgid: 1002, path: node, arguments: ["node"], mb: 64, cpu: 1),
             process(1003, pgid: 1003, path: node, arguments: ["node"], mb: 300, cpu: 1),
             fseventsd(.unknown)]
        }
        let coalitions: [pid_t: UInt64] = [1001: 1, 1002: 2, 1003: 3, 67772: 5]
        // 1002 allocated 26 MB after the walk read it: its coalition (read
        // later) and its footprint now both say 90 MB.
        let usage: [UInt64: ProcessTable.CoalitionUsage] = [
            1: .init(tasksStarted: 1, tasksExited: 0, footprint: megabytes(120)),
            2: .init(tasksStarted: 1, tasksExited: 0, footprint: megabytes(90)),
            3: .init(tasksStarted: 1, tasksExited: 0, footprint: megabytes(300)),
            5: .init(tasksStarted: 1, tasksExited: 0, footprint: megabytes(133)),
        ]
        let fresh: [pid_t: UInt64] = [1001: megabytes(120), 1002: megabytes(90), 1003: megabytes(300)]
        let walked = table().filter { !$0.restricted }.map { ($0.coalitionSample, usage[coalitions[$0.pid]!]!.footprint) }
        suite.expect(ProcessTable.coalitionReadVerified(walked.map { (coalition: $0.1, ownSum: $0.0) }) != true,
                     "the failure: against the walk's footprints, 1002's allocation is a mismatch")
        var records = table()
        let verdict = ProcessTable.assignSystemMemory(&records, verdict: nil, coalition: { coalitions[$0] },
                                                      usage: { usage[$0] }, footprint: { fresh[$0] })
        suite.expect(verdict == true && records.first { $0.pid == 67772 }?.memory == .systemFootprint(megabytes(133)),
                     "read right around each coalition, the members agree: the read is verified and fseventsd measured")
        // A member still growing between the two reads says nothing.
        var calls = 0
        var growing = table()
        let moving = ProcessTable.assignSystemMemory(&growing, verdict: nil, coalition: { coalitions[$0] },
                                                     usage: { usage[$0] }) { pid in
            calls += 1
            return pid == 1002 ? megabytes(90) + UInt64(calls) * megabytes(8) : fresh[pid]
        }
        suite.expect(moving == nil && growing.first { $0.pid == 67772 }?.memory == .unknown,
                     "a sample whose members moved between the reads is dropped: undecided, asked again, never false")
        let table = holdersSource("Sources/Brim/Modules/Memory/ProcessTable.swift")
        suite.expect(table.contains("usage: coalitionUsage, footprint: footprint(pid:))"),
                     "the app's check reads each member's footprint fresh")
    }
}

private extension ProcessRecord {
    /// The footprint the table walk read.
    var coalitionSample: UInt64 { footprint ?? 0 }
}
