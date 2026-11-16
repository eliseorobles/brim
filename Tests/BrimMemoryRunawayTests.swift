// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation
import UserNotifications

/// T-52: the overnight memory exhaustion of 2026-11-14/15. A GreenUp XCTest
/// runner (pid 72497) went from start to a 561 GB footprint in 150 s; the
/// memory-tight episode opened at 05:35:58 (swap up 1.9 GB) and macOS began
/// killing apps for low swap at 05:36:20, while Brim only reported it and
/// every alert of the night was dropped because Brim's notifications were
/// off (authorization status 1). The decision: end a runaway
/// automatically and log it in Brim.
///
/// Fixtures only: nothing here signals, quits or kills a process, reads a
/// notification setting or posts a notification, and defaults are written
/// only to a scratch suite.
extension BrimMemoryTests {
    static func runawayAndAlerts(_ suite: TestSuite) {
        suite.run("memory runaway: the GreenUp runner is ended on the first read over half of RAM") { greenUpSeries(suite) }
        suite.run("memory runaway: system, root, Brim and protected processes are never signalled") { neverSignalled(suite) }
        suite.run("memory runaway: nothing outside an episode") { onlyInEpisode(suite) }
        suite.run("memory runaway: identity and size are checked again before each signal") { recheckBeforeSignals(suite) }
        suite.run("memory runaway: the Activity entry, the panel line and the notification") { runawayWording(suite) }
        suite.run("memory runaway: pressure and swapfile events read the holders at once") { immediateTriggers(suite) }
        suite.run("memory alerts: notifications off are shown, and a dropped alert is logged") { silentAlerts(suite) }
    }

    // MARK: Fixtures

    /// 128 GB, this Mac's hw.memsize.
    static let physicalMemory: UInt64 = 137_438_953_472
    static let runawayThreshold = MemoryRunawayBrake.threshold(physicalMemory: physicalMemory)

    /// The GreenUp XCTest runner in Clone 1 of iPhone 17, as the table reads
    /// it: pid and kernel start time from the night's activity log.
    static func greenUpRunner(gb: Double, startedAt: UInt64 = 1_794_742_442_374_761) -> ProcessRecord {
        let app = home + "/Library/Developer/XCTestDevices/52B91577-BE49-4E27-9EFC-374D88CEF827/data/Containers/Bundle/Application/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0/GreenUp.app/GreenUp"
        return ProcessRecord(pid: 72497, ppid: 71900, pgid: 72497, uid: 501, flags: 0, terminal: ProcessRecord.noTerminal,
                             startedAt: startedAt, name: "GreenUp", path: app, memory: .footprint(gigabytes(gb)),
                             cpuTime: 140, arguments: [app, "-XCTest", "All"], workingDirectory: "/")
    }

    /// The rest of the table during the incident: xcodebuild driving the
    /// test plan, a Claude session, a node dev server and root's
    /// WindowServer and kernel_task (restricted rows).
    static func incidentNeighbours(windowServerGB: Double = 1.7) -> [ProcessRecord] {
        let xcodebuild = "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
        return [
            ProcessRecord(pid: 71777, ppid: 70001, pgid: 71777, uid: 501, flags: 0, terminal: ProcessRecord.noTerminal,
                          startedAt: 1_794_742_300_000_000, name: "xcodebuild", path: xcodebuild,
                          memory: .footprint(gigabytes(0.9)), cpuTime: 30,
                          arguments: [xcodebuild, "test-without-building", "-project", "GreenUp.xcodeproj"],
                          workingDirectory: home + "/Code/GreenUp"),
            ProcessRecord(pid: 70001, ppid: 1, pgid: 70001, uid: 501, flags: 0, terminal: ProcessRecord.noTerminal,
                          startedAt: 1_794_700_000_000_000, name: "claude", path: home + "/.local/share/claude/versions/2.1.0",
                          memory: .footprint(gigabytes(0.7)), cpuTime: 600, arguments: ["claude"],
                          workingDirectory: home + "/Code/GreenUp"),
            ProcessRecord(pid: 4700, ppid: 1, pgid: 4700, uid: 501, flags: 0, terminal: ProcessRecord.noTerminal,
                          startedAt: 1_794_600_000_000_000, name: "node", path: home + "/.nvm/versions/node/v22.11.0/bin/node",
                          memory: .footprint(gigabytes(2)), cpuTime: 50, arguments: ["node", "server.js"],
                          workingDirectory: home + "/Code/socialmediaautomation"),
            systemRow(400, name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                      memory: .systemFootprint(gigabytes(windowServerGB))),
        ]
    }

    static func ranked(_ records: [ProcessRecord], context: MemoryContext) -> [MemoryHolder] {
        var history = MemoryHolderHistory()
        return MemoryHolders.rank(records, context: context, history: &history, now: now, thresholds: MemoryHolderThresholds())
    }

    private static var memoryService: String { holdersSource("Sources/Brim/Modules/Memory/MemoryService.swift") }

    // MARK: 1. The real failure: GreenUp 20 GB -> 300 GB inside the episode

    private static func greenUpSeries(_ suite: TestSuite) {
        suite.expect(runawayThreshold == gigabytes(64), "a runaway holds more than half of 128 GB: 64 GB")

        // The episode opens as it did at 05:35:58: swap up 1.9 GB over the calm baseline.
        var episode = MemoryTightEpisode()
        _ = episode.update(pressure: .normal, reading: measurement(minutes: -10, swap: 10.2))
        let opened = episode.update(pressure: .normal, reading: measurement(minutes: 0, swap: 12.0))
        suite.expect(episode.isTight && opened == .opened(.swapGrowth(gigabytes(12.0) - gigabytes(10.2))),
                     "the night's swap growth opens the episode: \(opened)")

        // The brake's reads every 3 s while the runner grows (about 3.6 GB/s
        // at its peak; 561 GB by its end). 64 GB exactly is not more than half.
        let series: [Double] = [20, 41, 64, 96, 180, 300]
        var signalled: Set<ProcessIdentity> = []
        var endedAt: [Int] = []
        var intervals: [TimeInterval] = []
        let ctx = context()
        for (index, gb) in series.enumerated() {
            let records = incidentNeighbours() + [greenUpRunner(gb: gb)]
            let read = MemoryRunawayBrake.read(records, context: ctx, threshold: runawayThreshold)
            if let target = MemoryRunawayBrake.target(read.over, threshold: runawayThreshold, memoryTight: episode.isTight,
                                                      excluded: signalled) {
                suite.expect(target.identity == greenUpRunner(gb: gb).identity && target.name == "GreenUp"
                                && target.canEnd && !target.isSystem,
                             "the target is the runner itself: \(target.name) \(target.identity)")
                endedAt.append(index)
                signalled.insert(target.identity)
            }
            let next = MemoryRunawayWatch.next(after: now, memoryTight: episode.isTight, asleep: false,
                                               largestOwn: read.largestOwn, threshold: runawayThreshold)
            intervals.append(next.map { $0.timeIntervalSince(now) } ?? -1)
        }
        suite.expect(endedAt == [3], "ended once, on the first read over 64 GB (96 GB), never again: \(endedAt)")
        suite.expect(intervals == [3, 3, 3, 3, 3, 3], "with a 20 GB runner the brake reads every 3 s: \(intervals)")

        // The full scan an outside event starts sees it the same way.
        let atOpen = ranked(incidentNeighbours() + [greenUpRunner(gb: 96)], context: ctx)
        suite.expect(MemoryRunawayBrake.target(atOpen, threshold: runawayThreshold, memoryTight: true, excluded: [])?.identity
                        == greenUpRunner(gb: 96).identity,
                     "a scan's Biggest now rows give the same target")

        // Wired: every outside-event scan and every brake read brakes, and
        // the brake's read rides the one deadline while the episode is open.
        let service = memoryService
        let finished = section(service, from: "    private func scanFinished(", to: "    /// The growth follow-up's next moment")
        suite.expect(finished.contains("if trigger.runsAutomaticTier { brake(ranked) }")
                        && finished.contains("planRunawayRead(largestOwn:") && finished.contains("armDeadline()"),
                     "a scan an outside event started brakes, then plans the brake's next read")
        let readFinished = section(service, from: "    private func runawayReadFinished(", to: "    /// Ends a runaway when there is one")
        suite.expect(readFinished.contains("brake(read.over)") && readFinished.contains("planRunawayRead(largestOwn: read.largestOwn)"),
                     "each brake read brakes and plans the next")
        let arm = section(service, from: "    private func armDeadline() {", to: "    // MARK: Runaway brake")
        suite.expect(arm.contains("[scanAt, runawayDue].compactMap") && arm.contains("runawayRead()")
                        && service.contains("(3) The runaway\n    /// brake's read, only while a memory-tight episode is open")
                        && service.contains("ProcessTable.snapshot(options: [.arguments, .workingDirectory])"),
                     "the brake's read rides the one deadline timer, its Rule 1 reason recorded, and reads the table once")
    }

    // MARK: 2. Never a system, root, Brim or protected process

    private static func neverSignalled(_ suite: TestSuite) {
        let ctx = context(keep: ["socialmediaautomation-keep"])
        func over(_ record: ProcessRecord) -> MemoryHolder? {
            let records = incidentNeighbours() + [record]
            let read = MemoryRunawayBrake.read(records, context: ctx, threshold: runawayThreshold)
            let fromRead = MemoryRunawayBrake.target(read.over, threshold: runawayThreshold, memoryTight: true, excluded: [])
            let fromScan = MemoryRunawayBrake.target(ranked(records, context: ctx), threshold: runawayThreshold,
                                                     memoryTight: true, excluded: [])
            return fromRead ?? fromScan
        }
        // Root's processes are restricted rows: their size comes from a coalition.
        let rootDaemon = ProcessRecord(pid: 300, ppid: 1, pgid: 300, uid: 0, flags: 0, terminal: ProcessRecord.noTerminal,
                                       startedAt: 1_794_000_000_000_000, name: "fseventsd", path: fseventsdPath,
                                       memory: .systemFootprint(gigabytes(300)), cpuTime: nil, reapedChildrenCPUTime: nil,
                                       restricted: true)
        suite.expect(over(rootDaemon) == nil, "a root daemon at 300 GB is never a runaway")
        suite.expect(over(systemRow(400, name: "WindowServer",
                                    path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                                    memory: .systemFootprint(gigabytes(300)))) == nil,
                     "WindowServer at 300 GB (another user's) is never a runaway")
        func own(_ pid: pid_t, name: String, path: String, arguments: [String]? = nil, cwd: String? = nil) -> ProcessRecord {
            ProcessRecord(pid: pid, ppid: 1, pgid: pid, uid: 501, flags: 0, terminal: ProcessRecord.noTerminal,
                          startedAt: 1_794_742_000_000_000 + UInt64(pid), name: name, path: path,
                          memory: .footprint(gigabytes(300)), cpuTime: 10, arguments: arguments ?? [path], workingDirectory: cwd)
        }
        let cases: [(String, ProcessRecord)] = [
            ("Brim itself", own(99_999, name: "Brim", path: "/Applications/Brim.app/Contents/MacOS/Brim")),
            ("loginwindow", own(500, name: "loginwindow", path: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow")),
            ("launchd by name", own(501, name: "launchd", path: "/sbin/launchd")),
            ("a system executable", own(502, name: "mds_stores", path: "/System/Library/Frameworks/CoreServices.framework/mds_stores")),
            ("an app", own(503, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari")),
            ("Xcode", own(504, name: "SourceKitService", path: "/Applications/Xcode.app/Contents/Developer/SourceKitService")),
            ("the Claude CLI", own(505, name: "claude", path: home + "/.local/share/claude/versions/2.1.0", arguments: ["claude"])),
            ("a login shell", own(506, name: "zsh", path: "/bin/zsh", arguments: ["-zsh"])),
            ("a kept process", own(507, name: "socialmediaautomation-keep", path: home + "/bin/socialmediaautomation-keep")),
            ("tmux", own(508, name: "tmux", path: "/opt/homebrew/bin/tmux")),
        ]
        for (label, record) in cases {
            suite.expect(over(record) == nil, "\(label) at 300 GB is never a runaway")
            suite.expect(!MemoryRunawayBrake.stillRunaway(record.identity, fresh: record, threshold: runawayThreshold, context: ctx),
                         "\(label) never passes the re-check before a signal either")
        }
        var restricted = greenUpRunner(gb: 300)
        restricted.restricted = true
        restricted.memory = .systemFootprint(gigabytes(300))
        suite.expect(!MemoryRunawayBrake.stillRunaway(restricted.identity, fresh: restricted, threshold: runawayThreshold, context: ctx),
                     "a process that reads as another user's at signal time is never signalled")
        let systemHolder = MemoryHolder(identity: restricted.identity, name: "GreenUp", path: restricted.path, kind: .system,
                                        memory: .systemFootprint(gigabytes(300)), perHour: nil, growing: false,
                                        isFSEventsLeak: false, isFSEvents: false, canEnd: true)
        suite.expect(MemoryRunawayBrake.target([systemHolder], threshold: runawayThreshold, memoryTight: true, excluded: []) == nil,
                     "a system row is never a target, whatever its canEnd says")
        let service = memoryService
        suite.expect(service.contains("guard isRunning, holder.canEnd, !holder.isSystem, !busy.contains(key)")
                        && service.contains("endHolder(target, runaway: (runawayThreshold, context))"),
                     "the brake ends through the holder End, which refuses system rows and anything without End")
        suite.expect(KillProcessSupport.isProtected(pid: 1) && KillProcessSupport.isProtected(pid: getpid())
                        && KillProcessSupport.isProtected(pid: 600, name: "WindowServer"),
                     "the signal path itself refuses launchd, Brim and WindowServer")
    }

    // MARK: 3. Only while memory is tight

    private static func onlyInEpisode(_ suite: TestSuite) {
        let ctx = context()
        let read = MemoryRunawayBrake.read(incidentNeighbours() + [greenUpRunner(gb: 300)], context: ctx, threshold: runawayThreshold)
        suite.expect(read.over.map(\.identity) == [greenUpRunner(gb: 300).identity] && read.largestOwn == gigabytes(300),
                     "the read finds the runner over the threshold")
        suite.expect(MemoryRunawayBrake.target(read.over, threshold: runawayThreshold, memoryTight: false, excluded: []) == nil,
                     "outside an episode nothing is a target, even at 300 GB")
        suite.expect(MemoryRunawayWatch.next(after: now, memoryTight: false, asleep: false, largestOwn: gigabytes(300),
                                             threshold: runawayThreshold) == nil
                        && MemoryRunawayWatch.next(after: now, memoryTight: true, asleep: true, largestOwn: gigabytes(300),
                                                   threshold: runawayThreshold) == nil,
                     "no brake read outside an episode or while the Mac sleeps")
        suite.expect(MemoryRunawayWatch.next(after: now, memoryTight: true, asleep: false, largestOwn: gigabytes(2),
                                             threshold: runawayThreshold) == now.addingTimeInterval(5)
                        && MemoryRunawayWatch.next(after: now, memoryTight: true, asleep: false, largestOwn: gigabytes(16),
                                                   threshold: runawayThreshold) == now.addingTimeInterval(3),
                     "5 s while nothing of the person's is big, 3 s from 16 GB (a quarter of the threshold)")
        // A queued brake action is cancelled when the episode closes, Keep
        // changes or the module stops; not by turning leftover cleanup off.
        let authority = MemoryActionAuthority()
        let first = authority.ticket(.runaway)
        authority.revoke(.autoCleanOff)
        suite.expect(authority.isCurrent(first), "turning leftover cleanup off leaves the brake be")
        authority.revoke(.episodeClosed)
        suite.expect(!authority.isCurrent(first), "the episode closing cancels a queued brake signal")
        let second = authority.ticket(.runaway)
        authority.revoke(.keepChanged)
        suite.expect(!authority.isCurrent(second), "a Keep change cancels a queued brake signal")
        let service = memoryService
        let pause = section(service, from: "    private func pauseFollowUp(asleep: Bool) {", to: "    private func refreshIdleApps()")
        suite.expect(pause.contains("if asleep { runawayDue = nil }") && service.contains("MemoryService.shared.pauseFollowUp(asleep: true)")
                        && service.contains("MemoryService.shared.pauseFollowUp(asleep: false)"),
                     "sleep stops the brake's reads; a locked screen does not")
        let read2 = section(service, from: "    private func runawayRead() {", to: "    private func runawayReadFinished(")
        suite.expect(read2.contains("guard isRunning, episode.isTight, !runawayReadInFlight else {")
                        && read2.contains("runawayDue = nil"),
                     "a brake read runs only while the episode is open")
    }

    // MARK: 4. Checked again right before each signal

    private static func recheckBeforeSignals(_ suite: TestSuite) {
        let ctx = context()
        let read = greenUpRunner(gb: 96)
        suite.expect(MemoryRunawayBrake.stillRunaway(read.identity, fresh: greenUpRunner(gb: 120), threshold: runawayThreshold, context: ctx),
                     "the same runner, still over the threshold: signalled")
        let reused = greenUpRunner(gb: 120, startedAt: read.startedAt + 5_000_000)
        suite.expect(!MemoryRunawayBrake.stillRunaway(read.identity, fresh: reused, threshold: runawayThreshold, context: ctx),
                     "the pid now names another process (another start time): skipped")
        suite.expect(!MemoryRunawayBrake.stillRunaway(read.identity, fresh: nil, threshold: runawayThreshold, context: ctx),
                     "gone, or unreadable: skipped")
        suite.expect(!MemoryRunawayBrake.stillRunaway(read.identity, fresh: greenUpRunner(gb: 40), threshold: runawayThreshold, context: ctx),
                     "back under the threshold by the signal (it was freeing memory): skipped")
        var unknown = greenUpRunner(gb: 120)
        unknown.memory = .unknown
        suite.expect(!MemoryRunawayBrake.stillRunaway(read.identity, fresh: unknown, threshold: runawayThreshold, context: ctx),
                     "a footprint that cannot be read is not over anything: skipped")
        suite.expect(!MemoryRunawayBrake.stillRunaway(read.identity, fresh: greenUpRunner(gb: 120), threshold: runawayThreshold,
                                                      context: context(keep: ["GreenUp"])),
                     "added to the Keep list since the read: skipped")

        let service = memoryService
        let end = section(service, from: "    private func endHolder(_ holder: MemoryHolder, runaway:", to: "    private func signalled(")
        let freshAt = end.range(of: "MemoryRunawayBrake.freshRecord(pid: identity.pid)")
        let recheckAt = end.range(of: "MemoryRunawayBrake.stillRunaway(")
        let ticketAt = end.range(of: "guard authority.isCurrent(ticket) else")
        let signalAt = end.range(of: "KillProcessService.signalVerified([identity], force: false)")
        suite.expect(freshAt != nil && recheckAt != nil && ticketAt != nil && signalAt != nil
                        && freshAt!.lowerBound < recheckAt!.lowerBound && recheckAt!.lowerBound < ticketAt!.lowerBound
                        && ticketAt!.lowerBound < signalAt!.lowerBound && end.contains("authority.ticket(runaway == nil ? .direct : .runaway)"),
                     "SIGTERM: a fresh read, the re-check, the ticket, then the signal, which checks the start time once more")
        let check = section(service, from: "    private func forceCheck(_ id: UUID) {", to: "    /// The log entry whose processes are still running")
        suite.expect(check.contains("entry.kind == .runawayEnded") && check.contains("force(id, runaway: (threshold, context))"),
                     "five seconds after SIGTERM a runaway still running is forced without a click")
        let force = section(service, from: "    private func force(_ entryID: UUID, runaway:", to: "    /// Quit (the app's own terminate")
        let forceRecheck = force.range(of: "MemoryRunawayBrake.stillRunaway(")
        let kill = force.range(of: "KillProcessService.signalVerified(survivors, force: true)")
        suite.expect(forceRecheck != nil && kill != nil && forceRecheck!.lowerBound < kill!.lowerBound
                        && force.contains("MemoryRunawayBrake.freshRecord(pid: identity.pid)"),
                     "SIGKILL goes only to a survivor read again as the same process, still over the threshold")
        suite.expect(service.contains("runawaySignalled.formUnion(members.filter { attempted.contains($0.pid) })")
                        && service.contains("excluded: runawaySignalled.union(brimEnding)"),
                     "a process the brake signalled, or one an End is acting on, is never picked by it again")
    }

    // MARK: 5. The Activity entry, the panel line and the notification

    private static func runawayWording(_ suite: TestSuite) {
        let text = FeatureStrings.memory(.enUS)
        let ctx = context()
        guard let holder = MemoryRunawayBrake.read([greenUpRunner(gb: 561)], context: ctx, threshold: runawayThreshold).over.first else {
            suite.expect(false, "the runner reads as a holder")
            return
        }
        let command = MemoryActivityEntry.Command(arguments: greenUpRunner(gb: 561).arguments ?? [], workingDirectory: "/")
        var entry = MemoryActivityEntry.runaway(holder, bytes: gigabytes(561), threshold: runawayThreshold, command: command,
                                                at: now)
        suite.expect(entry.kind == .runawayEnded && entry.title == "GreenUp" && entry.runawayBytes == gigabytes(561)
                        && entry.runawayThreshold == gigabytes(64) && entry.commands == [command],
                     "the entry keeps the name and project, the command line, the footprint and the threshold")
        suite.expect(text.logSentence(entry) == "Ended runaway GreenUp at 561 GB"
                        && text.logKind(entry) == "Ended runaway" && text.logTitle(entry) == "GreenUp at 561 GB",
                     "the Activity row reads \"Ended runaway GreenUp at 561 GB\": \(text.logSentence(entry))")
        let chrome = MemoryHolder(identity: ProcessIdentity(pid: 29446, startedAt: 1_794_720_342_420_956),
                                  name: "chrome-headless-shell", path: home + "/Library/Caches/ms-playwright/chromium_headless_shell-1179/chrome-headless-shell-mac-arm64/chrome-headless-shell",
                                  kind: .own(project: "socialmediaautomation", inAgentSession: nil),
                                  memory: .footprint(gigabytes(93.1)), perHour: nil, growing: false,
                                  isFSEventsLeak: false, isFSEvents: false, canEnd: true)
        let chromeEntry = MemoryActivityEntry.runaway(chrome, bytes: gigabytes(93.1), threshold: runawayThreshold, command: nil, at: now)
        suite.expect(text.logSentence(chromeEntry) == "Ended runaway chrome-headless-shell · socialmediaautomation at 93.1 GB",
                     "the project label is kept: \(text.logSentence(chromeEntry))")
        entry.outcome = .failed
        suite.expect(text.logSentence(entry) == "Could not end runaway GreenUp at 561 GB", "a signal that failed says so")
        entry.outcome = .done
        entry.forced = true
        entry.measuredBefore = measurement(minutes: 0, used: 120.7, swap: 20.9, compressor: 70.8)
        entry.measuredAfter = measurement(minutes: 1, used: 36.4, swap: 21.1, compressor: 5.5)
        let decoded = MemoryActivityLog.decoded(MemoryActivityLog(entries: [entry]).encoded())
        suite.expect(decoded.entries == [entry] && decoded.entries.first?.measuredChange?.used == -Int64(gigabytes(120.7) - gigabytes(36.4)),
                     "the entry survives a save and a load, with the measured change of the whole Mac")
        let old = #"[{"id":"6E0B7F4C-2B1E-4C1D-9C7E-3F8B2A1D0E9F","date":"2026-11-15T11:36:37Z","kind":"holderExited","title":"GreenUp","reasons":[],"commands":[],"footprint":602800000000,"outcome":"done","survivors":[],"targets":[]}]"#
        suite.expect(MemoryActivityLog.decoded(Data(old.utf8)).entries.first?.title == "GreenUp",
                     "a log written before the brake still loads")

        // The panel's line: the newest runaway until it is dismissed.
        var log = MemoryActivityLog()
        log.add(MemoryActivityEntry.alertNotShown(title: "Memory is tight", body: "GreenUp 96 GB.", text: text,
                                                  at: now.addingTimeInterval(-60)))
        log.add(entry)
        let name = "brim.tests.memory-runaway.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            suite.expect(false, "a scratch defaults suite opens")
            return
        }
        defer { defaults.removePersistentDomain(forName: name) }
        suite.expect(MemoryRunawayNotice.unseen(log, seenThrough: MemoryRunawayNotice.seenThrough(defaults))?.id == entry.id,
                     "a runaway nobody dismissed shows at the top of the panel")
        MemoryRunawayNotice.markSeen(entry, in: defaults)
        suite.expect(MemoryRunawayNotice.unseen(log, seenThrough: MemoryRunawayNotice.seenThrough(defaults)) == nil,
                     "dismissed, it goes, and stays gone across launches")
        let later = MemoryActivityEntry.runaway(chrome, bytes: gigabytes(93.1), threshold: runawayThreshold, command: nil,
                                                at: now.addingTimeInterval(600))
        log.add(later)
        suite.expect(MemoryRunawayNotice.unseen(log, seenThrough: MemoryRunawayNotice.seenThrough(defaults))?.id == later.id,
                     "a later runaway shows again")

        // The notification, through the module's one notifier.
        entry.outcome = .pending
        entry.forced = nil
        let plan = MemoryNotifications.runaway(entry, text: text)
        suite.expect(plan == MemoryNotificationPlan(kind: .runaway, title: "Brim ended a runaway process",
                                                    body: "Ended runaway GreenUp at 561 GB. It held more than half of the Mac's memory while memory was tight.",
                                                    actions: [.review]),
                     "the notification names it: \(plan.body)")
        let service = memoryService
        let signalled = section(service, from: "    private func signalled(", to: "    private func watchExit(")
        suite.expect(signalled.contains("if entry.kind == .runawayEnded { notifyRunaway(entry) }")
                        && service.contains("deliver(MemoryNotifications.runaway(entry, text: text), text: text)"),
                     "the brake's entry is posted through the memory notifier when its signal went out")
        let views = holdersSource("Sources/Brim/Modules/Memory/MemoryViews.swift")
        suite.expect(views.contains("MemoryRunawayNotice.unseen(service.log, seenThrough: service.runawaySeenThrough)")
                        && views.contains("service.dismissRunawayNotice()") && views.contains("Text(text.logSentence(entry))")
                        && views.contains("if MemoryNoticesView.shows(service, permissions) {"),
                     "the panel and Settings show the runaway line until it is dismissed")
    }

    // MARK: 6. Pressure and the swapfile watch read at once

    private static func immediateTriggers(_ suite: TestSuite) {
        let service = memoryService
        let pressure = section(service, from: "    private func pressureEvent(", to: "    private func rootExited(")
        suite.expect(pressure.contains("scan(.pressure)") && service.contains("onSwapChange: { MemoryService.shared.scan(.swap) }"),
                     "a kernel pressure event and a swapfile coming or going each start a scan at once")
        let triggers = holdersSource("Sources/Brim/Modules/Memory/MemoryTriggers.swift")
        let swapWatch = section(triggers, from: "    private func armSwapWatch() {", to: "    // MARK:")
        suite.expect(swapWatch.contains("self.onSwapChange()") && !swapWatch.contains("Timer") && !swapWatch.contains("asyncAfter"),
                     "the swapfile kqueue calls through with no delay")
        let monitor = holdersSource("Sources/Brim/Modules/Memory/MemoryPressureMonitor.swift")
        suite.expect(monitor.contains("eventMask: [.normal, .warning, .critical]") && monitor.contains("events.send(read)"),
                     "the pressure source fires on warn and critical, and every event reaches the module")
        suite.expect(MemoryScanTrigger.pressure.runsAutomaticTier && MemoryScanTrigger.swap.runsAutomaticTier
                        && MemoryScanTrigger.deadline.runsAutomaticTier
                        && MemoryScanTrigger.queued(after: .foreground, incoming: .pressure) == .pressure,
                     "those scans brake (the automatic tier's gate), and a queued one is never lost to the panel's")
        let queuedPending = section(service, from: "    private func scan(_ trigger: MemoryScanTrigger) {", to: "        scanInFlight = true")
        suite.expect(queuedPending.contains("pendingTrigger = MemoryScanTrigger.queued(after: pendingTrigger, incoming: trigger)"),
                     "an event during a running scan runs right after it")
    }

    // MARK: 7. Silent alerts

    private static func silentAlerts(_ suite: TestSuite) {
        // The night's status: UNAuthorizationStatus 1.
        let night = NotificationPermissionState(UNAuthorizationStatus(rawValue: 1) ?? .notDetermined)
        suite.expect(night == .denied && !night.delivers, "status 1 is denied: no alert can show")
        suite.expect(night.showsWarning(wantsAlerts: true) && !night.showsWarning(wantsAlerts: false),
                     "denied while memory notifications are wanted shows \"Brim can't alert you\"")
        suite.expect(!night.asksOnCheck(wantsAlerts: true), "a denial is never asked over again")
        let never = NotificationPermissionState(.notDetermined)
        suite.expect(never == .undetermined && never.asksOnCheck(wantsAlerts: true) && !never.asksOnCheck(wantsAlerts: false)
                        && !never.showsWarning(wantsAlerts: true) && !never.delivers,
                     "never asked: asked once on a check when alerts are wanted")
        suite.expect(NotificationPermissionState(.authorized).delivers && NotificationPermissionState(.provisional).delivers
                        && !NotificationPermissionState(.authorized).showsWarning(wantsAlerts: true),
                     "allowed (or provisional): delivered, no warning")
        suite.expect(NotificationPermissionState.settingsURL(bundleID: "com.roblesconsulting.brim")?.absoluteString
                        == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.roblesconsulting.brim"
                        && NotificationPermissionState.settingsURL(bundleID: nil)?.absoluteString
                        == "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
                     "the button opens Brim's own entry in System Settings' Notifications pane")

        // The 05:35:58 alert, dropped: kept in the Activity log instead.
        let text = FeatureStrings.memory(.enUS)
        let holder = MemoryHolder(identity: greenUpRunner(gb: 96).identity, name: "GreenUp", path: greenUpRunner(gb: 96).path,
                                  kind: .own(project: nil, inAgentSession: nil), memory: .footprint(gigabytes(96)),
                                  perHour: nil, growing: false, isFSEventsLeak: false, isFSEvents: false, canEnd: true)
        guard let plan = MemoryNotifications.plan(episodeNotifies: true, critical: false, holders: [holder], counts: nil,
                                                  canQuitSomething: false, notifiedLeak: nil, text: text).plan else {
            suite.expect(false, "the episode notification is planned")
            return
        }
        let dropped = MemoryActivityEntry.alertNotShown(title: plan.title, body: plan.body, text: text, at: now)
        suite.expect(text.logSentence(dropped) == "Alert not shown (notifications off): Memory is tight — GreenUp 96 GB."
                        && dropped.outcome == .nothingToDo,
                     "a dropped alert is logged with its words: \(text.logSentence(dropped))")

        let notifier = holdersSource("Sources/Brim/Services/Notifier.swift")
        let guardBody = section(notifier, from: "            guard permission.delivers else {", to: "            let content")
        suite.expect(guardBody.contains("delivered?(.dropped(permission))") && notifier.contains("delivered?(.delivered)"),
                     "Notifier tells its caller when an alert was dropped for authorization")
        let service = memoryService
        let deliver = section(service, from: "    private func deliver(_ plan: MemoryNotificationPlan", to: "    private func notificationAction(")
        suite.expect(deliver.contains("guard case .dropped = delivery else { return }")
                        && deliver.contains("log.add(.alertNotShown(title: plan.title, body: plan.body, text: text, at: Date()))")
                        && service.components(separatedBy: "Notifier.post(").count == 2,
                     "every memory alert goes through one post, and a dropped one is logged")
        suite.expect(service.contains("Permissions.shared.refreshNotifications(requestIfUndetermined: settings.notify)")
                        && section(service, from: "    func foreground() {", to: "    /// Settings changed")
                            .contains("Permissions.shared.refreshNotifications(requestIfUndetermined: settings.notify)")
                        && !service.contains("Notifier.requestPermission()"),
                     "launch and the panel or Settings opening read the permission (no polling) and ask only when never asked")
        let permissions = holdersSource("Sources/Brim/Core/Permissions.swift")
        suite.expect(permissions.contains("state.asksOnCheck(wantsAlerts: requestIfUndetermined)")
                        && permissions.contains("NotificationPermissionState.settingsURL(bundleID: Bundle.main.bundleIdentifier)")
                        && !permissions.contains("enum NotificationPermissionState"),
                     "Permissions holds the one permission state and the one Settings opener")
        let root = "Sources/Brim"
        let files = (FileManager.default.enumerator(atPath: root)?.allObjects as? [String]) ?? []
        let openers = files.filter { $0.hasSuffix(".swift") && holdersSource(root + "/" + $0).contains("Notifications-Settings.extension") }
        suite.expect(openers == ["Services/NotifierSupport.swift"], "one place names the Notifications pane: \(openers)")
        let views = holdersSource("Sources/Brim/Modules/Memory/MemoryViews.swift")
        suite.expect(views.contains("permissions.notifications.showsWarning(wantsAlerts: service.settings.notify)")
                        && views.contains("Text(text.notificationsOff)") && views.contains("permissions.openNotificationSettings()"),
                     "the Memory panel and Settings > Memory show the warning row with its button")
        suite.expect(text.notificationsOff == "Brim can't alert you: notifications are off", "the warning's words")
    }
}
