// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// Brim's Memory module: the shared process table, the leftover test on
/// process groups measured on the maintainer's Mac (fixtures from `ps` on 2026-11-12,
/// home folders shown as ~), the idle clock, the activity log, the strings,
/// and source contracts (no repeating timers, one memory notification path,
/// no `ps` enumeration). T-42's groups (safety gate, re-check, unknown reads,
/// system processes, holders, episodes, notifications, measured deltas,
/// triggers, scan cost) are in BrimMemoryHoldersTests.swift.
///
/// The only process any test signals is one this test spawns itself, in a
/// process group of its own; every other process is only read.
enum BrimMemoryTests {
    static func run(_ suite: TestSuite) {
        suite.run("memory: process table") { processTable(suite) }
        suite.run("memory: leftover groups") { leftovers(suite) }
        suite.run("memory: protected and inform-only") { protectedClasses(suite) }
        suite.run("memory: helpers and running now") { helpersAndRunning(suite) }
        suite.run("memory: test drivers") { testDrivers(suite) }
        suite.run("memory: session keepers and daemons") { sessionKeepers(suite) }
        suite.run("memory: what Quit them ends") { quitThem(suite) }
        suite.run("memory: idle windows") { idleWindows(suite) }
        suite.run("memory: sockets and paths") { socketsAndPaths(suite) }
        suite.run("memory: automatic tier limits") { automaticLimits(suite) }
        suite.run("memory: other users' processes") { otherUsers(suite) }
        suite.run("memory: verified signals") { verifiedSignals(suite) }
        suite.run("memory: idle apps and clock") { idleApps(suite) }
        suite.run("memory: activity log and settings") { logAndSettings(suite) }
        suite.run("memory: strings and registration") { stringsAndRegistration(suite) }
        suite.run("memory: source contracts") { sourceContracts(suite) }
        runHolderGroups(suite)
    }

    // MARK: Fixtures

    static let home = "/Users/tester"
    /// The moment the fixtures were read.
    static let now = Date(timeIntervalSince1970: 1_794_500_000)

    /// A `ps -o pid,ppid,pgid,tty,stat,etime,time,rss,args` row from the
    /// fixtures, ~ for the home folder. The rss column is RSS and is ignored:
    /// the footprint is given separately, read from `top`'s MEM column (or
    /// libproc) for the same process.
    static func record(_ line: String, footprintMB: Double, uid: uid_t = 501, at time: Date = now,
                       cpuDelta: TimeInterval = 0, sockets: ProcessSockets? = ProcessSockets(),
                       arguments: [String]? = nil, cwd: String? = nil) -> ProcessRecord {
        let columns = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let pid = pid_t(columns[0])!
        let tty = columns[3]
        let elapsed = seconds(etime: columns[5])
        let cpu = seconds(cputime: columns[6]) + cpuDelta
        let command = columns[8...].map { $0.replacingOccurrences(of: "~/", with: home + "/") }
        let path = command[0].contains("/") ? command[0] : ""
        let started = time.addingTimeInterval(-elapsed)
        var flags: UInt32 = 0
        var terminal = ProcessRecord.noTerminal
        if tty != "??" {
            flags |= ProcessRecord.controllingTerminalFlag
            terminal = 0x1000001
        }
        let pgid = pid_t(columns[2])!
        return ProcessRecord(pid: pid, ppid: pid_t(columns[1])!, pgid: pgid, uid: uid, flags: flags,
                             terminal: terminal,
                             startedAt: UInt64(started.timeIntervalSince1970 * 1_000_000),
                             name: (command[0] as NSString).lastPathComponent, path: path,
                             memory: .footprint(UInt64(footprintMB * 1_048_576)), cpuTime: cpu,
                             arguments: arguments ?? command, workingDirectory: cwd, sockets: sockets)
    }

    /// "[[dd-]hh:]mm:ss".
    static func seconds(etime: String) -> TimeInterval {
        let dayParts = etime.split(separator: "-")
        let days = dayParts.count == 2 ? Double(dayParts[0])! : 0
        let clock = dayParts.last!.split(separator: ":").map { Double($0)! }
        let total = clock.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
        return days * 86_400 + total
    }

    /// "mm:ss.xx" (minutes may exceed 59).
    static func seconds(cputime: String) -> TimeInterval {
        let parts = cputime.split(separator: ":").map { Double($0)! }
        return parts.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
    }

    /// fixtures/orphan-group-38773.txt: the greenup-test multiprocessing
    /// workers left 23 h after their pytest parent ended. Footprints are the
    /// live libproc reading of the same pids (29–30 MB each, 8 MB tracker).
    static func orphanGroup(busyWorker: Bool = false) -> [ProcessRecord] {
        let rows: [(String, Double)] = [
            ("39176     1 38773 ??       S    23:40:51   0:00.03   7152 ~/.pyenv/versions/greenup-test/bin/python3 -I -c from multiprocessing.resource_tracker import main;main(8)", 8),
            ("39177     1 38773 ??       S    23:40:51   0:55.79  14816 ~/.pyenv/versions/greenup-test/bin/python3 -I -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=9, pipe_handle=17) --multiprocessing-fork", 29),
            ("39178     1 38773 ??       S    23:40:51   0:56.29  14880 ~/.pyenv/versions/greenup-test/bin/python3 -I -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=9, pipe_handle=19) --multiprocessing-fork", 29),
            ("39179     1 38773 ??       S    23:40:51   0:54.41  14880 ~/.pyenv/versions/greenup-test/bin/python3 -I -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=9, pipe_handle=21) --multiprocessing-fork", 29),
            ("39181     1 38773 ??       S    23:40:51   0:54.21  14880 ~/.pyenv/versions/greenup-test/bin/python3 -I -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=9, pipe_handle=23) --multiprocessing-fork", 30),
            ("39182     1 38773 ??       S    23:40:51   0:54.56  14880 ~/.pyenv/versions/greenup-test/bin/python3 -I -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=9, pipe_handle=25) --multiprocessing-fork", 29),
            ("39183     1 38773 ??       S    23:40:51   0:54.67  14816 ~/.pyenv/versions/greenup-test/bin/python3 -I -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=9, pipe_handle=27) --multiprocessing-fork", 29),
        ]
        // A later scan sees the same processes (start times are absolute),
        // with the same CPU unless one got busy.
        return rows.enumerated().map { index, row in
            record(row.0, footprintMB: row.1, cpuDelta: busyWorker && index == 2 ? 5 : 0)
        }
    }

    /// ram-measure/dev.txt: a LIVE greenup-test run under a Claude Code
    /// Bash-tool shell, its workers in state R. Same interpreter path and
    /// argument shape as the leftovers above; footprints from top's MEM.
    static func liveRun() -> [ProcessRecord] {
        let python = "~/.pyenv/versions/greenup-test/bin/python3"
        return [
            record("73590 73069 73590 ttys011  S+   01-11:54:04  41:10.00 1036000 claude", footprintMB: 690),
            record("28085 73590 28085 ??       Ss      23:08   0:00.02   2144 /bin/zsh -c source ~/.claude/shell-snapshots/snapshot-zsh-1.sh && pytest", footprintMB: 2.1),
            record("32664 28085 28085 ??       S       22:05   0:03.10  34000 \(python) -m pytest -n 3", footprintMB: 34),
            record("32687 32664 28085 ??       S       22:05   0:00.10  14000 \(python) -I -c from multiprocessing.resource_tracker import main;main(6)", footprintMB: 8),
            record("22013 32664 28085 ??       R          01:08   0:40.00  60000 \(python) -c import sys;exec(eval(sys.stdin.readline()))", footprintMB: 70),
            record("22018 32664 28085 ??       R          01:08   0:41.00  60000 \(python) -c import sys;exec(eval(sys.stdin.readline()))", footprintMB: 70),
            record("22021 32664 28085 ??       R          01:08   0:39.00  60000 \(python) -c import sys;exec(eval(sys.stdin.readline()))", footprintMB: 70),
        ]
    }

    /// fixtures/ppid1-*.txt rows for the other classes measured that day.
    static let crashpad = "13399     1 13398 ??       S    02-22:05:21   0:00.01   5936 /Applications/Plaud.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler"
    static let adb = "74787     1 74787 ??       Ss   05-17:10:23   4:15.07  12144 adb"
    static let postgres = "42131     1 42131 ??       S    07-16:38:43   1:29.34  11184 /opt/homebrew/opt/postgresql@17/bin/postgres"
    static let caffeinate = "46514     1 46511 ??       SN   01-03:55:51   0:00.01    352 /usr/bin/caffeinate -dims"
    static let sourceKit = " 5043     1  5043 ??       Ss   01-12:23:14  32:34.93 2816544 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitd.framework/Versions/A/XPCServices/SourceKitService.xpc/Contents/MacOS/SourceKitService"
    static let sourceKitLSP = " 5010 73590  5010 ??       S    01-11:43:39   2:10.00  90000 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"

    /// The orphaned Claude Code Bash-tool shell (ps.txt 41264–41269, top's
    /// MEM 1.5 MB): a zsh sourcing a shell snapshot, with tail and head.
    static func claudeShell() -> [ProcessRecord] {
        [
            record("41264     1 41263 ??       SN      02:55:10   0:00.00    704 /bin/zsh -c source ~/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && make test | tail -5", footprintMB: 1.5),
            record("41265 41264 41263 ??       SN      02:55:10   0:00.00    500 /usr/bin/tail -5", footprintMB: 0.8),
            record("41267 41264 41263 ??       SN      02:55:10   0:00.00    600 /bin/zsh -c make test", footprintMB: 1.0),
            record("41269 41264 41263 ??       SN      02:55:10   0:00.00    500 /usr/bin/head -20", footprintMB: 0.8),
        ]
    }

    /// The awake clock at `now`. Unless a test says otherwise the Mac stays
    /// awake, so the awake clock moves with the wall clock.
    static let awakeAtNow: TimeInterval = 400_000

    static func context(at time: Date = now, awake: TimeInterval? = nil, jobs: Set<pid_t>? = [42131],
                        assertions: Set<pid_t> = [], keep: [String] = []) -> MemoryContext {
        MemoryContext(uid: 501, home: home, ownPID: 99_999, now: time,
                      awake: awake ?? awakeAtNow + time.timeIntervalSince(now), launchdJobs: jobs,
                      powerAssertions: assertions, keep: keep)
    }

    static func finding(_ result: MemoryScanResult, containing pid: pid_t) -> MemoryFinding? {
        result.findings.first { $0.members.contains { $0.pid == pid } }
    }

    /// A hand-built row for shapes the fixtures did not catch live: the
    /// person's own process, started two hours before `now`, no terminal.
    static func process(_ pid: pid_t, ppid: pid_t = 1, pgid: pid_t, path: String, arguments: [String], mb: Double,
                        cpu: TimeInterval, children: TimeInterval = 0, sockets: ProcessSockets? = ProcessSockets(),
                        cwd: String? = nil) -> ProcessRecord {
        var record = ProcessRecord(pid: pid, ppid: ppid, pgid: pgid, uid: 501, flags: 0,
                                   terminal: ProcessRecord.noTerminal,
                                   startedAt: UInt64(now.addingTimeInterval(-2 * 3600).timeIntervalSince1970 * 1_000_000) + UInt64(pid),
                                   name: String((path as NSString).lastPathComponent.prefix(16)), path: path,
                                   memory: .footprint(UInt64(mb * 1_048_576)), cpuTime: cpu, reapedChildrenCPUTime: children)
        record.arguments = arguments
        record.workingDirectory = cwd
        record.sockets = sockets
        return record
    }

    /// Two scans of a table, 31 minutes apart (awake), the second seeing
    /// `later` when given (the same processes with what changed).
    static func twoScans(_ records: [ProcessRecord], later: [ProcessRecord]? = nil,
                         jobs: Set<pid_t>? = [42131]) -> MemoryScanResult {
        let first = MemoryClassifier.scan(records, context: context(jobs: jobs), observations: MemoryObservations())
        return MemoryClassifier.scan(later ?? records, context: context(at: now.addingTimeInterval(31 * 60), jobs: jobs),
                                     observations: first.observations)
    }

    /// The automatic tier's targets on its most permissive event: an
    /// outside one while memory is tight.
    static func autoTargets(_ findings: [MemoryFinding],
                            alreadySignalled: Set<ProcessIdentity> = []) -> [MemoryFinding] {
        MemoryClassifier.autoTargets(findings, thresholds: MemoryThresholds(), alreadySignalled: alreadySignalled,
                                     trigger: .pressure, memoryTight: true)
    }

    static func neverEnded(_ result: MemoryScanResult) -> Bool {
        autoTargets(result.findings).isEmpty && MemoryClassifier.quitThemTargets(result.findings).isEmpty
    }

    // MARK: Process table

    private static func processTable(_ suite: TestSuite) {
        let table = ProcessTable.snapshot(options: [.arguments, .workingDirectory])
        let me = table.first { $0.pid == getpid() }
        suite.expect(me != nil && me?.ppid == getppid() && me?.pgid == getpgrp() && me?.uid == getuid(),
                     "the table lists this test with its parent, group and owner")
        suite.expect(me?.startedAt == ProcessTable.startTime(pid: getpid()) && (me?.startedAt ?? 0) > 0,
                     "the start time is the identity Kill Process checks")
        suite.expect((me?.footprint ?? 0) > 0 && (me?.arguments?.isEmpty == false) && me?.workingDirectory != nil,
                     "footprint, argv and working directory are read for own processes")
        suite.expect(ProcessTable.sockets(pid: getpid()) != nil, "own sockets are readable without lsof")
        suite.expect(ProcessTable.cpuNanoseconds()[getpid()] != nil, "the CPU pass covers this process")
        suite.expect(me?.restricted == false, "an own process is read in full")

        // Every process is listed, as `ps -A` listed them: the table once
        // left out all 338 processes of other users (root's daemons,
        // WindowServer) on the maintainer's Mac, because the kernel refuses
        // PROC_PIDTBSDINFO for them to a caller that is not root.
        let launchd = table.first { $0.pid == 1 }
        if getuid() == 0 {
            suite.expect(launchd != nil && launchd?.restricted == false, "as root, launchd is read in full")
        } else {
            suite.expect(launchd != nil && launchd?.uid == 0 && launchd?.ppid == 0 && launchd?.restricted == true,
                         "launchd (root's) is listed, from the kernel's short record: \(String(describing: launchd))")
            suite.expect(launchd?.path == "/sbin/launchd" && launchd?.executableName == "launchd",
                         "another user's process keeps its path and name")
            suite.expect(launchd?.startedAt == 0 && launchd?.memory == .unknown && launchd?.cpuTime == nil
                            && launchd?.reapedChildrenCPUTime == nil
                            && ProcessTable.startTime(pid: 1) == nil
                            && !ProcessTable.isAlive(ProcessIdentity(pid: 1, startedAt: launchd?.startedAt ?? 0)),
                         "another user's process has no identity to act on, and its footprint and CPU read as unknown, not 0")
            let others = table.filter { $0.uid != getuid() }
            suite.expect(!others.isEmpty && others.allSatisfy(\.restricted) && others.allSatisfy { $0.arguments == nil },
                         "other users' processes are listed, restricted, without their argv")
        }

        // KERN_PROCARGS2: argc, the executable path, padding, argv, then the environment.
        var buffer = Data()
        var argc = Int32(2).littleEndian
        buffer.append(Data(bytes: &argc, count: 4))
        buffer.append(Data("/bin/sleep\0\0\0\0sleep\030\0HOME=/x\0".utf8))
        suite.expect(ProcessTable.parseProcessArguments(buffer) == ["sleep", "30"],
                     "argv is read from KERN_PROCARGS2 and the environment is left alone")
        suite.expect(ProcessTable.parseProcessArguments(Data([1, 0])) == nil, "a short buffer reads as nothing")

        let listing = "PID\tStatus\tLabel\n-\t0\tcom.apple.idle\n42131\t0\thomebrew.mxcl.postgresql@17\n612\t-9\tcom.example\n"
        suite.expect(MemoryRules.launchdJobPIDs(fromList: listing) == [42131, 612],
                     "launchctl list gives the running jobs' pids")
    }

    // MARK: Leftovers

    private static func leftovers(_ suite: TestSuite) {
        let first = MemoryClassifier.scan(orphanGroup(), context: context(), observations: MemoryObservations())
        let seen = finding(first, containing: 39177)
        suite.expect(seen?.bucket == .leftover && seen?.count == 7 && seen?.pgid == 38773
                        && seen?.project == "greenup-test" && seen?.eligibleAt == now.addingTimeInterval(30 * 60),
                     "group 38773 is one leftover, measured first, eligible after the idle window: \(String(describing: seen?.bucket))")
        suite.expect(seen?.reasons.contains(.noNetwork) == true
                        && seen?.reasons.contains(.measuring(until: now.addingTimeInterval(30 * 60))) == true,
                     "its reasons say what is being measured")
        suite.expect(first.nextDeadline == now.addingTimeInterval(30 * 60), "one one-shot deadline is asked for")
        suite.expect(autoTargets(first.findings).isEmpty,
                     "nothing is ended on first sight")

        let later = now.addingTimeInterval(31 * 60)
        let second = MemoryClassifier.scan(orphanGroup(), context: context(at: later), observations: first.observations)
        let eligible = finding(second, containing: 39177)
        suite.expect(eligible?.bucket == .autoLeftover && eligible?.reasons.contains(.idle) == true,
                     "idle for the whole window, orphaned 30 min+, quiet and 50 MB+: auto-eligible")
        let targets = autoTargets(second.findings)
        suite.expect(targets.map(\.pgid) == [38773] && targets.first?.members.map(\.pid) == [39183, 39182, 39181, 39179, 39178, 39177, 39176],
                     "the whole group is the target, newest first at equal depth")

        let busy = MemoryClassifier.scan(orphanGroup(busyWorker: true), context: context(at: later),
                                         observations: first.observations)
        let notIdle = finding(busy, containing: 39177)
        suite.expect(notIdle?.bucket == .leftover && notIdle?.reasons.contains(.busy) == true
                        && autoTargets(busy.findings).isEmpty,
                     "5 s of CPU in the window: not eligible, and the window starts again")
        suite.expect(notIdle?.eligibleAt == nil && busy.nextDeadline == nil,
                     "a group seen busy arms no deadline: only events judge it again (no 30-minute chain)")

        var exited = MemoryObservations()
        exited.rootExits[38773] = now.addingTimeInterval(-2 * 3600)
        let fromExit = MemoryClassifier.scan(orphanGroup(), context: context(), observations: exited)
        suite.expect(finding(fromExit, containing: 39177)?.orphanedSince == now.addingTimeInterval(-2 * 3600),
                     "orphaned since the root's observed exit, not the first sighting")

        let unknownJobs = MemoryClassifier.scan(orphanGroup(), context: context(at: later, jobs: nil),
                                                observations: first.observations)
        suite.expect(finding(unknownJobs, containing: 39177)?.bucket == .autoLeftover,
                     "a group whose leader is gone needs no launchd answer")

        let kept = MemoryClassifier.scan(orphanGroup(), context: context(at: later, keep: ["python3"]),
                                         observations: first.observations)
        suite.expect(finding(kept, containing: 39177)?.running == .kept, "the Keep list protects a group")

        // Path alone is never enough: the live run shares the interpreter path.
        let mixed = MemoryClassifier.scan(orphanGroup() + liveRun(), context: context(at: later),
                                          observations: first.observations)
        let live = finding(mixed, containing: 22013)
        suite.expect(live?.bucket == .runningNow && live?.running == .testRun
                        && autoTargets(mixed.findings).allSatisfy {
                            !$0.members.contains { [22013, 22018, 22021, 32664, 32687].contains($0.pid) } },
                     "a live test run (leader alive, workers running) is protected next to its orphaned twin")
        suite.expect(mixed.testRunActive, "a pytest parent alive means a test run is in progress")

        // The Claude Code Bash-tool shell: a leftover, but tiny: one click only.
        let shellFirst = MemoryClassifier.scan(claudeShell(), context: context(), observations: MemoryObservations())
        let shellLater = MemoryClassifier.scan(claudeShell(), context: context(at: later), observations: shellFirst.observations)
        let shell = finding(shellLater, containing: 41264)
        suite.expect(shell?.bucket == .leftover && shell?.count == 4 && shell?.reasons.contains(.belowFloor) == true
                        && shell?.eligibleAt == nil && shell?.canEnd == true,
                     "a Claude Code Bash-tool shell below 50 MB is one click, never automatic")

        // An orphan still listening: an orphaned dev server, ports shown, one click.
        var listening = ProcessSockets()
        listening.listeningTCP = [5173]
        let server = record("51001     1 51000 ??       S    03:10:00   0:02.10  81234 /opt/homebrew/Cellar/node/26.13.0_2/bin/node ~/Code/site/node_modules/.bin/vite --port 5173",
                            footprintMB: 120, sockets: listening)
        let serverScan = MemoryClassifier.scan([server], context: context(), observations: MemoryObservations())
        let devServer = finding(serverScan, containing: 51001)
        suite.expect(devServer?.bucket == .orphanedDevServer && devServer?.ports == [5173] && devServer?.canEnd == true
                        && devServer?.project == "site",
                     "a leftover that still listens is an orphaned dev server, one click, with its port")
        let unknownSockets = record("51101     1 51100 ??       S    03:10:00   0:00.10  81234 /opt/homebrew/Cellar/node/26.13.0_2/bin/node build.js",
                                    footprintMB: 120, sockets: nil)
        let blind1 = MemoryClassifier.scan([unknownSockets], context: context(), observations: MemoryObservations())
        let blind2 = MemoryClassifier.scan([unknownSockets], context: context(at: later), observations: blind1.observations)
        suite.expect(finding(blind2, containing: 51101)?.bucket == .leftover,
                     "sockets that could not be read keep a group off the automatic tier")
    }

    // MARK: Protected and inform-only

    private static func protectedClasses(_ suite: TestSuite) {
        let records = [record(crashpad, footprintMB: 2.5), record(adb, footprintMB: 6),
                       record(postgres, footprintMB: 11), record(caffeinate, footprintMB: 0.3)]
        let result = MemoryClassifier.scan(records, context: context(assertions: [46514]), observations: MemoryObservations())
        suite.expect(finding(result, containing: 13399) == nil, "a crashpad handler daemonizes on purpose and is never listed")
        suite.expect(finding(result, containing: 74787)?.bucket == .selfDaemonized
                        && finding(result, containing: 74787)?.canEnd == false,
                     "adb (pgid == pid, not a launchd job) is a self-daemonized tool: inform only")
        suite.expect(finding(result, containing: 42131)?.bucket == .runningNow
                        && finding(result, containing: 42131)?.running == .service
                        && finding(result, containing: 42131)?.canEnd == false,
                     "postgres run by launchd for brew services is protected")
        suite.expect(finding(result, containing: 46514)?.running == .powerAssertion
                        && finding(result, containing: 46514)?.canEnd == false,
                     "caffeinate holding a power assertion is shown, never ended")
        let noAssertion = MemoryClassifier.scan(records, context: context(), observations: MemoryObservations())
        suite.expect(finding(noAssertion, containing: 46514) == nil,
                     "without a dev signature an orphan is not this module's to judge")
        let unknownJobs = MemoryClassifier.scan(records, context: context(jobs: nil), observations: MemoryObservations())
        suite.expect(finding(unknownJobs, containing: 42131)?.bucket != .autoLeftover
                        && unknownJobs.findings.allSatisfy { $0.bucket != .autoLeftover },
                     "with launchd unreadable, a pgid == pid group is never automatic")
        // A terminal job is protected: the group still has its tty.
        let terminalJob = record("60001     1 60000 ttys004  S    01:10:00   0:00.10  9000 /opt/homebrew/bin/python3 server.py",
                                 footprintMB: 80)
        let terminal = MemoryClassifier.scan([terminalJob], context: context(), observations: MemoryObservations())
        suite.expect(finding(terminal, containing: 60001)?.running == .terminal, "a group with a terminal is protected")

        // (a) is judged on the whole group: one member of another user's
        // (listed restricted) keeps all of it off every list, even after
        // the idle window, where the same group of the person's own is ended.
        var mixed = orphanGroup()
        mixed[0].uid = 0
        mixed[0].restricted = true
        mixed[0].startedAt = 0
        let later = now.addingTimeInterval(31 * 60)
        let mixedFirst = MemoryClassifier.scan(mixed, context: context(), observations: MemoryObservations())
        let mixedLater = MemoryClassifier.scan(mixed, context: context(at: later), observations: mixedFirst.observations)
        suite.expect(mixed.allSatisfy { finding(mixedFirst, containing: $0.pid) == nil && finding(mixedLater, containing: $0.pid) == nil }
                        && autoTargets(mixedLater.findings).isEmpty,
                     "a group with another user's member is never a leftover")
        // A subtree the module lists stops at other users' processes.
        var run = liveRun()
        let rootChild = ProcessRecord(pid: 22050, ppid: 32664, pgid: 28085, uid: 0, flags: 0,
                                      terminal: ProcessRecord.noTerminal, startedAt: 0,
                                      name: "sudo", path: "/usr/bin/sudo", memory: .unknown, cpuTime: nil,
                                      reapedChildrenCPUTime: nil, restricted: true)
        run.append(rootChild)
        let runScan = MemoryClassifier.scan(run, context: context(), observations: MemoryObservations())
        suite.expect(finding(runScan, containing: 32664)?.running == .testRun && finding(runScan, containing: 22050) == nil,
                     "another user's child of a test run is not one of its members")
    }

    // MARK: Helpers and running now

    private static func helpersAndRunning(_ suite: TestSuite) {
        let records = [record(sourceKit, footprintMB: 585), record(sourceKitLSP, footprintMB: 40)] + liveRun()
        let result = MemoryClassifier.scan(records, context: context(), observations: MemoryObservations())
        let sourceKitRow = finding(result, containing: 5043)
        suite.expect(sourceKitRow?.bucket == .longRunningHelper && sourceKitRow?.helper == .languageServer
                        && sourceKitRow?.inUse == true && sourceKitRow?.canEnd == false,
                     "SourceKitService with a live sourcekit-lsp client is a suggestion only")
        let agent = finding(result, containing: 73590)
        suite.expect(agent?.running == .agentSession && agent?.canEnd == false, "a claude session is shown as running now")
        suite.expect(result.roots.contains { $0.identity.pid == 32664 } && result.roots.contains { $0.identity.pid == 73590 },
                     "test-run parents and agent CLIs are watched for their exit")
        suite.expect(result.roots.first { $0.identity.pid == 73590 }?.groups == [73590, 28085, 5010],
                     "a root that leads its group orphans that group and its children's groups when it exits")
        suite.expect(result.roots.first { $0.identity.pid == 32664 }?.groups == [],
                     "a root inside another process's group (pytest under its shell) never stamps that group")

        // A stale MCP server under a live CLI: one click once idle for the window.
        let codex = record("94351 94065 94351 ttys002  S+   02-01:00:00  90:00.00 300000 /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                           footprintMB: 1209)
        // npm retitles itself: its argv reads as one string and blanks (read live, pid 62279).
        let wrapper = record("34396 94351 94351 ??       S    01-02:00:00   0:01.00  50000 /opt/homebrew/Cellar/node/26.13.0_2/bin/node",
                             footprintMB: 47, arguments: ["npm exec xcodebuildmcp@latest mcp", "", "", "", ""])
        let server = record("34400 34396 94351 ??       S    01-02:00:00   0:05.00  80000 node ~/.npm/_npx/1/node_modules/.bin/xcodebuildmcp mcp",
                            footprintMB: 80)
        let firstMCP = MemoryClassifier.scan([codex, wrapper, server], context: context(), observations: MemoryObservations())
        suite.expect(finding(firstMCP, containing: 34396) == nil && firstMCP.nextDeadline != nil,
                     "an MCP server is measured before it is offered")
        let later = now.addingTimeInterval(31 * 60)
        let secondMCP = MemoryClassifier.scan([codex, wrapper, server], context: context(at: later),
                                              observations: firstMCP.observations)
        let mcp = finding(secondMCP, containing: 34396)
        suite.expect(mcp?.helper == .staleMCP && mcp?.canEnd == true && mcp?.members.map(\.pid) == [34400, 34396],
                     "an idle MCP server 2 h+ old is offered: its own subtree, child first, never the CLI's group")
        suite.expect(finding(secondMCP, containing: 94351)?.running == .agentSession, "the CLI itself stays protected")
    }

    // MARK: Test drivers

    /// testmanagerd stays alive long after Xcode's test run ends (seen on this
    /// Mac with no xcodebuild left): by itself it is no run. Only an actual
    /// driver makes one: `xcodebuild test`, pytest/xdist, `node --test`,
    /// vitest, a jest worker.
    private static func testDrivers(_ suite: TestSuite) {
        let daemonPath = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/testmanagerd"
        let daemon = process(6100, pgid: 6100, path: daemonPath, arguments: [daemonPath], mb: 60, cpu: 3)
        let udid = "0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9"
        let simPath = "/Library/Developer/CoreSimulator/Volumes/iOS_23A343/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.0.simruntime/Contents/Resources/RuntimeRoot/sbin/launchd_sim"
        let clone = process(6200, pgid: 6200, path: simPath,
                            arguments: [simPath, "~/Library/Developer/XCTestDevices/\(udid)/data/var/run/launchd_bootstrap.plist"
                                .replacingOccurrences(of: "~/", with: home + "/")], mb: 400, cpu: 20)
        func xcodebuild(_ action: [String]?) -> ProcessRecord {
            var record = process(6300, ppid: 6000, pgid: 6000, path: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
                                 arguments: ["xcodebuild"], mb: 150, cpu: 30)
            record.arguments = action.map { ["/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"] + $0 }
            return record
        }
        func runs(_ result: MemoryScanResult) -> [MemoryFinding] { result.findings.filter { $0.running == .testRun } }

        let lingering = MemoryClassifier.scan([daemon], context: context(), observations: MemoryObservations())
        suite.expect(!lingering.testRunActive && runs(lingering).isEmpty && finding(lingering, containing: 6100) == nil,
                     "a lingering testmanagerd with no test driver alive is no test run in progress")
        let leftClone = MemoryClassifier.scan([daemon, clone], context: context(), observations: MemoryObservations())
        let cloneRow = finding(leftClone, containing: 6200)
        suite.expect(!leftClone.testRunActive && cloneRow?.helper == .simulatorClone && cloneRow?.canEnd == true,
                     "with only testmanagerd left, a Simulator clone the finished run left booted is offered")

        let testing = xcodebuild(["test", "-scheme", "GreenUp", "-destination", "platform=iOS Simulator,name=iPhone 17"])
        let live = MemoryClassifier.scan([testing, daemon, clone], context: context(), observations: MemoryObservations())
        let run = finding(live, containing: 6300)
        suite.expect(live.testRunActive && runs(live).count == 1 && run?.running == .testRun && run?.simulators == 1
                        && run?.footprint == UInt64(150 * 1_048_576) + (daemon.footprint ?? 0) + (clone.footprint ?? 0)
                        && finding(live, containing: 6200)?.helper != .simulatorClone,
                     "xcodebuild test is one run: its clone and testmanagerd count toward it and nothing is offered")
        suite.expect(MemoryRules.isXcodeTestDriver(xcodebuild(["test-without-building", "-xctestrun", "a.xctestrun"]))
                        && MemoryRules.isXcodeTestDriver(xcodebuild(nil))
                        && !MemoryRules.isXcodeTestDriver(xcodebuild(["build", "-scheme", "GreenUp"]))
                        && !MemoryRules.isXcodeTestDriver(daemon) && !MemoryRules.isTestRunRoot(daemon),
                     "xcodebuild drives a run when it tests (or its arguments are unreadable), not when it builds; testmanagerd never does")
        let building = MemoryClassifier.scan([xcodebuild(["build", "-scheme", "GreenUp"]), daemon, clone],
                                             context: context(), observations: MemoryObservations())
        suite.expect(!building.testRunActive && finding(building, containing: 6200)?.helper == .simulatorClone,
                     "an xcodebuild that only builds is no test run")

        let node = "/opt/homebrew/Cellar/node/26.13.0_2/bin/node"
        for (name, arguments) in [("node --test", [node, "--test", "--test-concurrency=4", "test/"]),
                                  ("vitest", [node, home + "/Code/app/node_modules/vitest/vitest.mjs", "run"]),
                                  ("a jest worker", [node, home + "/Code/app/node_modules/jest-worker/build/workers/processChild.js"])] {
            let driver = process(6400, ppid: 6000, pgid: 6000, path: node, arguments: arguments, mb: 90, cpu: 10)
            let result = MemoryClassifier.scan([driver, daemon], context: context(), observations: MemoryObservations())
            suite.expect(result.testRunActive && finding(result, containing: 6400)?.running == .testRun,
                         "\(name) is a test run in progress")
        }
    }

    // MARK: Session keepers and daemons (review: tmux, zellij, emacs, redis)

    private static func sessionKeepers(_ suite: TestSuite) {
        // A terminal multiplexer or editor daemon looks exactly like a
        // leftover: ppid 1, no terminal, a Unix socket at most, a Homebrew
        // path. Each shape (leader alive after fork + setsid, leader gone
        // after a double fork; socket or not) is shown and never ended.
        var local = ProcessSockets()
        local.listeningLocal = ["/private/tmp/tmux-501/default"]
        let keepers: [(path: String, arguments: [String])] = [
            ("/opt/homebrew/Cellar/tmux/3.5a/bin/tmux", ["tmux"]),
            ("/usr/bin/screen", ["SCREEN", "-dmS", "job"]),
            ("/opt/homebrew/Cellar/zellij/0.41.2/bin/zellij", ["zellij", "--server", "/var/folders/xx/T/zellij-501/0.41.2/work"]),
            ("/opt/homebrew/Cellar/emacs/30.1/bin/emacs-30.1", ["emacs", "--daemon"]),
            ("/opt/homebrew/Cellar/mosh/1.4.0/bin/mosh-server", ["mosh-server", "new"]),
            ("/opt/homebrew/Cellar/dtach/0.9/bin/dtach", ["dtach", "-n", "/tmp/job.sock", "make"]),
            ("/opt/homebrew/Cellar/abduco/0.6/bin/abduco", ["abduco", "-n", "job", "make"]),
        ]
        for (index, keeper) in keepers.enumerated() {
            let name = (keeper.path as NSString).lastPathComponent
            var shapes: [String] = []
            for leaderAlive in [true, false] {
                for sockets in [ProcessSockets(), local] {
                    let pid = pid_t(70_000 + index * 10 + (leaderAlive ? 0 : 1))
                    let server = process(pid, pgid: leaderAlive ? pid : pid - 1, path: keeper.path,
                                         arguments: keeper.arguments, mb: 150, cpu: 40, sockets: sockets)
                    var quiet = server
                    quiet.cpuTime = (quiet.cpuTime ?? 0) + 0.5
                    let result = twoScans([server], later: [quiet])
                    let row = finding(result, containing: pid)
                    if !(row?.bucket == .selfDaemonized && row?.canEnd == false && neverEnded(result)) {
                        shapes.append("leader \(leaderAlive ? "alive" : "gone"), \(sockets.isListening ? "socket" : "no socket"): \(String(describing: row?.bucket))")
                    }
                }
            }
            suite.expect(shapes.isEmpty, "\(name) is a session keeper: shown, never ended (\(shapes))")
        }

        // redis-server daemonized by a double fork (its leader is gone),
        // serving on a Unix socket only: still a tool's own server.
        let redis = process(4500, pgid: 4499, path: "/opt/homebrew/Cellar/redis/7.4.1/bin/redis-server",
                            arguments: ["redis-server", "/opt/homebrew/etc/redis-dev.conf"], mb: 300, cpu: 5, sockets: local)
        var redisLater = redis
        redisLater.cpuTime = 6
        let redisScan = twoScans([redis], later: [redisLater])
        suite.expect(finding(redisScan, containing: 4500)?.bucket == .selfDaemonized && neverEnded(redisScan),
                     "a self-daemonizer whose group leader is gone (double fork) is still inform-only")

        // A Homebrew binary is not a dev signature by itself.
        let formula = process(4550, pgid: 4549, path: "/opt/homebrew/Cellar/foo/1.0/bin/foo-server",
                              arguments: ["foo-server"], mb: 200, cpu: 1)
        suite.expect(!MemoryRules.hasDevSignature(formula, home: home) && finding(twoScans([formula]), containing: 4550) == nil,
                     "a Homebrew path alone is no dev signature: the formula's daemon is not a leftover")
        suite.expect(MemoryRules.hasDevSignature(process(4551, pgid: 4549, path: "/opt/homebrew/Cellar/node/26.13.0_2/bin/node",
                                                         arguments: ["node", "x.js"], mb: 1, cpu: 0), home: home),
                     "Homebrew's runtimes still count by their name")

        // A job a shell detached into its own group (pgid == pid, leader
        // alive): idle and quiet, but one click at most, never automatic.
        let detached = process(4700, pgid: 4700, path: home + "/.nvm/versions/node/v22.11.0/bin/node",
                               arguments: ["node", "worker.js"], mb: 200, cpu: 10)
        let detachedScan = twoScans([detached])
        let detachedRow = finding(detachedScan, containing: 4700)
        suite.expect(detachedRow?.bucket == .leftover && detachedRow?.canEnd == true && detachedRow?.eligibleAt == nil
                        && detachedRow?.reasons.contains(.idle) == true && neverEnded(detachedScan),
                     "a group whose leader is alive is never automatic and never in Quit them: \(String(describing: detachedRow?.bucket))")

        // A leftover serving on a Unix socket (the plugin broker's shape,
        // its agent child gone): an orphaned dev server, one click.
        let broker = process(4800, pgid: 4799, path: "/opt/homebrew/Cellar/node/26.13.0_2/bin/node",
                             arguments: ["node", home + "/.claude/plugins/cache/x/broker.mjs", "serve"], mb: 60, cpu: 2,
                             sockets: local)
        let brokerScan = twoScans([broker])
        let brokerRow = finding(brokerScan, containing: 4800)
        suite.expect(brokerRow?.bucket == .orphanedDevServer && brokerRow?.listensLocally == true
                        && brokerRow?.canEnd == true && neverEnded(brokerScan),
                     "a leftover listening on a Unix socket is an orphaned dev server, never automatic")
    }

    // MARK: What Quit them ends (review: busy, measuring, uncertain groups)

    private static func quitThem(_ suite: TestSuite) {
        // A busy detached python job (no tty, no TCP): what the notification
        // once counted and Quit them ended.
        let job = process(4400, pgid: 4399, path: home + "/.pyenv/versions/3.12.4/bin/python3.12",
                          arguments: ["python3", "train.py"], mb: 2048, cpu: 1000, cwd: home + "/Code/model")
        var working = job
        working.cpuTime = (working.cpuTime ?? 0) + 31 * 60
        let firstSight = MemoryClassifier.scan([job], context: context(), observations: MemoryObservations())
        suite.expect(finding(firstSight, containing: 4400)?.bucket == .leftover
                        && MemoryClassifier.quitThemTargets(firstSight.findings).isEmpty,
                     "a group seen once (still measuring) is never in Quit them")
        let busyScan = twoScans([job], later: [working])
        suite.expect(finding(busyScan, containing: 4400)?.reasons.contains(.busy) == true
                        && MemoryClassifier.quitThemTargets(busyScan.findings).isEmpty,
                     "a busy leftover is never in Quit them: only its own row's End reaches it")

        // A leader-alive group with launchd unreadable (could be a
        // LaunchAgent): never in Quit them.
        let agent = process(4900, pgid: 4900, path: home + "/.nvm/versions/node/v22.11.0/bin/node",
                            arguments: ["node", "agent.js"], mb: 90, cpu: 3)
        suite.expect(MemoryClassifier.quitThemTargets(twoScans([agent], jobs: nil).findings).isEmpty,
                     "a group launchd may own is never in Quit them")

        // What it does end: idle-confirmed groups, the tiny ones included.
        let idle = twoScans(orphanGroup() + claudeShell())
        let targets = MemoryClassifier.quitThemTargets(idle.findings)
        suite.expect(Set(targets.map(\.pgid)) == [38773, 41263]
                        && finding(idle, containing: 41264)?.bucket == .leftover
                        && finding(idle, containing: 41264)?.idleConfirmed == true,
                     "Quit them ends the idle-confirmed groups, below the automatic floor too: \(targets.map(\.pgid))")
    }

    // MARK: Idle windows (review: sleep, reaped children, membership)

    private static func idleWindows(_ suite: TestSuite) {
        // Seen 2 minutes before the lid closed, 2.5 s of CPU in those 2
        // minutes; the wake scan comes 8 hours later on the wall clock but
        // 2 minutes later on the awake clock.
        let worker = process(4600, pgid: 4599, path: home + "/.nvm/versions/node/v22.11.0/bin/node",
                             arguments: ["node", "worker.js"], mb: 400, cpu: 50, cwd: home + "/Code/app")
        var woke = worker
        woke.cpuTime = 52.5
        let first = MemoryClassifier.scan([worker], context: context(), observations: MemoryObservations())
        let wakeTime = now.addingTimeInterval(8 * 3600)
        let wake = MemoryClassifier.scan([woke], context: context(at: wakeTime, awake: awakeAtNow + 2 * 60),
                                         observations: first.observations)
        let row = finding(wake, containing: 4600)
        suite.expect(row?.bucket == .leftover && row?.reasons.contains(.measuring(until: wakeTime.addingTimeInterval(28 * 60))) == true
                        && row?.eligibleAt == wakeTime.addingTimeInterval(28 * 60) && neverEnded(wake),
                     "a window that spans sleep counts only awake time: 8 h asleep is not 30 min idle")
        let awakeLater = MemoryClassifier.scan([woke], context: context(at: wakeTime.addingTimeInterval(29 * 60),
                                                                        awake: awakeAtNow + 31 * 60),
                                               observations: wake.observations)
        suite.expect(finding(awakeLater, containing: 4600)?.bucket == .autoLeftover,
                     "after 30 awake minutes with under 3 s of CPU it is eligible")

        // Work done in children it reaps: the supervisor's own CPU is flat.
        let supervisor = process(4810, pgid: 4809, path: home + "/.pyenv/versions/3.12.4/bin/python3.12",
                                 arguments: ["python3", "scheduler.py"], mb: 120, cpu: 20, children: 600)
        var supervising = supervisor
        supervising.reapedChildrenCPUTime = (supervising.reapedChildrenCPUTime ?? 0) + 120
        let supervised = twoScans([supervisor], later: [supervising])
        suite.expect(finding(supervised, containing: 4810)?.reasons.contains(.busy) == true && neverEnded(supervised),
                     "CPU used by children a member reaped counts as the group's work")

        // A member that ends, or one that appears, during the window.
        let shrunk = twoScans(orphanGroup(), later: Array(orphanGroup().dropFirst()))
        suite.expect(finding(shrunk, containing: 39177)?.reasons.contains(.busy) == true && neverEnded(shrunk),
                     "a member that ended during the window restarts it")
        let newcomer = process(39190, pgid: 38773, path: home + "/.pyenv/versions/greenup-test/bin/python3",
                               arguments: ["python3", "-c", "from multiprocessing.spawn import spawn_main"], mb: 29, cpu: 0)
        let grown = twoScans(orphanGroup(), later: orphanGroup() + [newcomer])
        suite.expect(finding(grown, containing: 39177)?.reasons.contains(.busy) == true && neverEnded(grown),
                     "a member that appeared during the window restarts it")

        // Read live: a shell this test starts runs a CPU-bound child and
        // reaps it; the shell's own CPU barely moves, its children's does.
        // It ends by itself when its input closes: nothing is signalled.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "/bin/sh -c 'i=0; while [ $i -lt 150000 ]; do i=$((i+1)); done'; echo ready; read line"]
        let input = Pipe()
        let output = Pipe()
        shell.standardInput = input
        shell.standardOutput = output
        do {
            try shell.run()
            _ = output.fileHandleForReading.readData(ofLength: 6)
            let read = ProcessTable.record(pid: shell.processIdentifier)
            suite.expect((read?.reapedChildrenCPUTime ?? 0) >= 0.1 && (read?.reapedChildrenCPUTime ?? 0) > (read?.cpuTime ?? 0),
                         "the table reads a process's reaped children's CPU: \(String(describing: read?.reapedChildrenCPUTime)) s vs own \(String(describing: read?.cpuTime)) s")
            try? input.fileHandleForWriting.close()
            shell.waitUntilExit()
        } catch {
            suite.expect(false, "a shell could be started: \(error)")
        }
    }

    // MARK: Sockets and paths (review: refused reads, Unix listeners, argv[0])

    private static func socketsAndPaths(_ suite: TestSuite) {
        if getuid() != 0 {
            suite.expect(ProcessTable.sockets(pid: 1) == nil,
                         "a descriptor table the kernel refuses (launchd's) reads as unknown, not as no sockets")
        }
        let listed = Set(ProcessTable.pids())
        if let absent = (90_000...99_990).reversed().map({ pid_t($0) }).first(where: { !listed.contains($0) }) {
            suite.expect(ProcessTable.sockets(pid: absent) == nil, "a pid that is gone reads as unknown")
        }

        // A Unix socket this test listens on is read as listening; a
        // connected pair is not.
        let path = NSTemporaryDirectory() + "brim-memory-\(getpid()).sock"
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var pair: [Int32] = [-1, -1]
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let fits = path.utf8.count < MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in path.utf8.prefix(raw.count - 1).enumerated() { raw[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let listening = fits && bound == 0 && listen(listener, 1) == 0
        let paired = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0
        let mine = ProcessTable.sockets(pid: getpid())
        suite.expect(listening && paired && mine?.listeningLocal.filter { $0 == path }.count == 1 && mine?.isListening == true,
                     "a listening Unix socket is read as listening, a connected pair is not: \(String(describing: mine?.listeningLocal))")
        close(listener)
        if paired { close(pair[0]); close(pair[1]) }
        unlink(path)
        suite.expect(ProcessTable.sockets(pid: getpid())?.listeningLocal.contains(path) == false,
                     "a closed listener is gone from the next read")

        // A path libproc will not give: the protections read argv[0].
        var repl = process(62097, ppid: 4000, pgid: 4000, path: "", arguments: ["/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"],
                           mb: 40, cpu: 1)
        repl.name = "node_repl"
        suite.expect(MemoryRules.isProtectedTool(repl) && repl.protectionPaths == ["/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"],
                     "with no readable path, argv[0] still names a protected app's process")
        var xpc = repl
        xpc.arguments = ["/System/Library/Frameworks/Foo.framework/XPCServices/Foo.xpc/Contents/MacOS/Foo"]
        suite.expect(MemoryRules.isXPCService(xpc) && MemoryRules.isAppOrSystemExecutable(xpc),
                     "and an XPC service")
        // An orphan whose path cannot be read stays one click.
        let pathless = record("51201     1 51200 ??       S    03:10:00   0:00.10  81234 node build.js", footprintMB: 120)
        let pathlessScan = twoScans([pathless])
        suite.expect(pathless.path.isEmpty && finding(pathlessScan, containing: 51201)?.bucket == .leftover
                        && neverEnded(pathlessScan),
                     "a group with a member whose path is unreadable is never automatic")
    }

    // MARK: Automatic tier limits (review: per trigger, never twice, no chain)

    private static func automaticLimits(_ suite: TestSuite) {
        suite.expect(!MemoryScanTrigger.action.runsAutomaticTier && !MemoryScanTrigger.foreground.runsAutomaticTier
                        && !MemoryScanTrigger.monitorReading.runsAutomaticTier
                        && [MemoryScanTrigger.start, .pressure, .launch, .terminate, .wake, .unlock, .rootExit,
                            .deadline, .swap, .holderExit].allSatisfy(\.runsAutomaticTier),
                     "only outside events run the automatic tier; the scan after an exit or a click, and opening the panel, never do")

        var groups: [ProcessRecord] = []
        for index in 0..<10 {
            let pgid = pid_t(5000 + index * 10)
            for worker in 1...2 {
                groups.append(process(pgid + pid_t(worker), pgid: pgid, path: home + "/.pyenv/versions/3.12.4/bin/python3.12",
                                      arguments: ["python3", "-c", "from multiprocessing.spawn import spawn_main"],
                                      mb: 40, cpu: 2))
            }
        }
        let ten = twoScans(groups)
        let eligible = ten.findings(in: .autoLeftover)
        let targets = autoTargets(ten.findings)
        suite.expect(eligible.count == 10 && targets.count == 3, "one event ends at most 3 groups of 10 eligible")
        let signalled = Set(targets.flatMap(\.identities))
        let again = autoTargets(ten.findings, alreadySignalled: signalled)
        suite.expect(again.count == 3 && Set(again.map(\.pgid)).isDisjoint(with: targets.map(\.pgid)),
                     "a group the tier signalled is never its target again; the next event takes the next ones")
        let one = Set([eligible[0].members[0].identity])
        suite.expect(!autoTargets(ten.findings, alreadySignalled: one)
                        .contains { $0.pgid == eligible[0].pgid },
                     "one signalled member keeps its whole group off the tier")

        // Root exits stamp only the groups they orphan.
        let codex = record("94351 94065 94351 ttys002  S+   02-01:00:00  90:00.00 300000 /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                           footprintMB: 1209)
        let wrapper = record("34396 94351 94351 ??       S    01-02:00:00   0:01.00  50000 /opt/homebrew/Cellar/node/26.13.0_2/bin/node",
                             footprintMB: 47, arguments: ["npm exec xcodebuildmcp@latest mcp", "", "", "", ""])
        var stamped = MemoryObservations()
        stamped.rootExits[94351] = now.addingTimeInterval(-8 * 3600)
        let cli = MemoryClassifier.scan([codex, wrapper], context: context(), observations: stamped)
        suite.expect(cli.roots.first { $0.identity.pid == 34396 }?.groups == []
                        && cli.observations.rootExits[94351] == nil,
                     "an MCP wrapper in its CLI's group never stamps it, and a stamp on a group whose leader runs is dropped")
        let detached = process(4700, pgid: 4700, path: home + "/.nvm/versions/node/v22.11.0/bin/node",
                               arguments: ["node", "worker.js"], mb: 200, cpu: 10)
        var early = MemoryObservations()
        early.rootExits[4700] = now.addingTimeInterval(-8 * 3600)
        suite.expect(finding(MemoryClassifier.scan([detached], context: context(), observations: early), containing: 4700)?
                        .orphanedSince == now,
                     "a group whose leader runs is dated from its first sighting, not from another root's exit")

        // Force after a restart: a new watch on the survivors completes it.
        let a = ProcessIdentity(pid: 10, startedAt: 1)
        let b = ProcessIdentity(pid: 11, startedAt: 2)
        var watch = MemoryActionWatch.forForce(existing: nil, survivors: [a, b], footprints: [a: 100, b: 50], before: nil)
        suite.expect(watch.remaining == [a, b] && watch.findingID == nil && !watch.exit(ProcessIdentity(pid: 12, startedAt: 3)),
                     "Force with no watch left (Brim restarted) watches the survivors")
        let firstExit = watch.exit(a)
        let lastExit = watch.exit(b)
        suite.expect(firstExit && lastExit && watch.isComplete && watch.estimatedFreed == 150,
                     "their exits complete the entry and count the estimate of what ended")
        let kept = MemoryActionWatch(findingID: "g1", remaining: [a], footprints: [a: 1], before: nil)
        suite.expect(MemoryActionWatch.forForce(existing: kept, survivors: [a], footprints: [:], before: nil) == kept,
                     "a watch still running is kept as it is")
    }

    // MARK: Other users' processes (review: WindowServer's memory)

    private static func otherUsers(_ suite: TestSuite) {
        let table = ProcessTable.snapshot(options: [.systemMemory])
        let read = BrimMemoryTests.Usage.memoryRows(table)
        if let windowServer = table.first(where: { $0.executableName == "WindowServer" }) {
            let carrier = table.filter { $0.executableName == "WindowServer" }.contains { $0.memory != .unknown }
            suite.expect(read.rows.contains { $0.pid == windowServer.pid } || read.notMeasured.contains("WindowServer")
                            || carrier,
                         "WindowServer is accounted for in the memory list: measured, or named as not measured")
        }
        let unmeasured = table.filter { $0.restricted && $0.memory == .unknown }
        let measured = Set(table.filter { ($0.memory.bytes ?? 0) > 0 }.map(\.pid))
        suite.expect(read.notMeasured.count == unmeasured.count && read.rows.allSatisfy { measured.contains($0.pid) },
                     "every other user's process is measured or named as not measured, never dropped and never shown as 0")
        let text = FeatureStrings.memory(.enUS)
        suite.expect(text.otherUsersNotMeasured(338).contains("338"),
                     "the memory list says how many processes it could not measure")
    }

    // MARK: Verified signals (a child this test spawns, in its own group)

    private static func spawnSleep(group: pid_t) -> pid_t? {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, group)
        let words: [String] = ["/bin/sleep", "60"]
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { for argument in argv { free(argument) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, "/bin/sleep", nil, &attributes, argv, environ) == 0 ? pid : nil
    }

    /// Waits for this test's own child and says how it ended.
    private static func reap(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        guard waitpid(pid, &status, 0) == pid else { return nil }
        let signal = status & 0x7f
        return signal == 0 ? nil : signal
    }

    private static func verifiedSignals(_ suite: TestSuite) {
        guard let leader = spawnSleep(group: 0), let member = spawnSleep(group: leader) else {
            suite.expect(false, "a child process group could be spawned")
            return
        }
        let group = ProcessTable.snapshot().filter { $0.pgid == leader }
        suite.expect(Set(group.map(\.pid)) == [leader, member] && group.allSatisfy { $0.ppid == getpid() },
                     "the table sees exactly the test's own child group: \(group.map(\.pid))")
        guard let leaderStart = ProcessTable.startTime(pid: leader),
              let memberStart = ProcessTable.startTime(pid: member) else {
            suite.expect(false, "the children's start times are readable")
            return
        }

        // A start time that changed (a reused pid) is refused, and nothing is sent.
        let stale = BrimMemoryTests.Kill.signalVerified([ProcessIdentity(pid: member, startedAt: memberStart &+ 1)], force: false)
        suite.expect(stale[member] == .stale && ProcessTable.isAlive(ProcessIdentity(pid: member, startedAt: memberStart)),
                     "identity re-verification refuses a pid whose start time changed")

        // The real path, deepest first, ends exactly the child group.
        let ordered = MemoryClassifier.signalOrder(group).map(\.identity)
        let results = BrimMemoryTests.Kill.signalVerified(ordered, force: false)
        suite.expect(results.count == 2 && results.values.allSatisfy { $0 == .sent },
                     "every member of the test's own group is signalled once")
        suite.expect(reap(member) == SIGTERM && reap(leader) == SIGTERM, "SIGTERM ended both children")
        let after = BrimMemoryTests.Kill.signalVerified([ProcessIdentity(pid: leader, startedAt: leaderStart)], force: false)
        suite.expect(after[leader] == .gone || after[leader] == .stale, "an ended process is never signalled again")
    }

    // MARK: Idle apps and the activity clock

    private static func idleApps(_ suite: TestSuite) {
        var clock = MemoryActivityClock(startingAt: 0)
        suite.expect(clock.reading(at: 100) == 100, "the clock runs while awake")
        clock.pause(.asleep, at: 100)
        suite.expect(clock.reading(at: 5_000) == 100 && clock.isPaused, "it stops while the Mac sleeps")
        clock.pause(.locked, at: 5_000)
        clock.resume(.asleep, at: 6_000)
        suite.expect(clock.reading(at: 7_000) == 100, "waking behind the lock screen does not start it")
        clock.resume(.locked, at: 7_000)
        suite.expect(clock.reading(at: 7_500) == 600, "unlocking starts it again")

        let hour: TimeInterval = 3600
        func app(_ pid: pid_t, _ name: String, bundle: String, mb: UInt64, lastUsed: TimeInterval,
                 active: Bool = false, audio: Bool = false) -> MemoryApp {
            MemoryApp(pid: pid, startedAt: 1, bundleID: bundle, name: name, bundleURL: nil, isActive: active,
                      footprint: mb << 20, lastUsed: lastUsed, playingAudio: audio)
        }
        let apps = [app(501, "Pages", bundle: "com.apple.iWork.Pages", mb: 900, lastUsed: 0),
                    app(502, "Music", bundle: "com.apple.Music", mb: 600, lastUsed: 0, audio: true),
                    app(503, "Xcode", bundle: "com.apple.dt.Xcode", mb: 4000, lastUsed: 0),
                    app(504, "Brim", bundle: "com.roblesconsulting.brim", mb: 300, lastUsed: 0),
                    app(505, "Notes", bundle: "com.apple.Notes", mb: 120, lastUsed: 0),
                    app(506, "Maps", bundle: "com.apple.Maps", mb: 500, lastUsed: 7 * hour),
                    app(507, "Mail", bundle: "com.apple.mail", mb: 700, lastUsed: 0, active: true)]
        let idle = MemoryIdleApps.heavyIdle(apps, clock: 9 * hour, threshold: 8 * hour, keep: [],
                                            ownBundleID: "com.roblesconsulting.brim")
        suite.expect(idle.map(\.name) == ["Pages"],
                     "only unused, heavy, unprotected apps not playing audio are offered: \(idle.map(\.name))")
        suite.expect(MemoryIdleApps.heavyIdle(apps, clock: 9 * hour, threshold: 8 * hour, keep: ["com.apple.iWork.Pages"],
                                              ownBundleID: "com.roblesconsulting.brim").isEmpty,
                     "the Keep list keeps an app")
        suite.expect(MemoryIdleApps.heavyIdle(apps, clock: 9 * hour, threshold: 8 * hour, keep: [], ownBundleID: nil)
                        .map(\.name) == ["Pages", "Brim"],
                     "Brim is kept out by its own bundle id, not by its name")
        // Nine hours of wall time with two asleep: seven on the clock, under eight.
        var night = MemoryActivityClock(startingAt: 0)
        night.pause(.asleep, at: 3 * hour)
        night.resume(.asleep, at: 5 * hour)
        suite.expect(MemoryIdleApps.heavyIdle(apps, clock: night.reading(at: 9 * hour), threshold: 8 * hour,
                                              keep: [], ownBundleID: nil).isEmpty,
                     "time asleep never makes an app idle")
    }

    // MARK: Activity log and settings

    private static func logAndSettings(_ suite: TestSuite) {
        var log = MemoryActivityLog()
        for index in 0..<60 {
            log.add(MemoryActivityEntry(date: now.addingTimeInterval(TimeInterval(index)), kind: .autoEnded,
                                        title: "python3 ×7", reasons: [.parentGone(since: now), .idle, .noNetwork],
                                        commands: [.init(arguments: ["python3", "-m", "pytest"], workingDirectory: home + "/Code/x")]))
        }
        suite.expect(log.entries.count == 50 && log.entries.first?.date == now.addingTimeInterval(59),
                     "the log keeps the last 50 actions, newest first")
        let id = log.entries[0].id
        log.update(id) { $0.outcome = .done; $0.estimatedFreed = 183 << 20 }
        let decoded = MemoryActivityLog.decoded(log.encoded())
        suite.expect(decoded == log && decoded.entry(id)?.estimatedFreed == 183 << 20,
                     "the log survives a save and a load, reasons and commands included")
        suite.expect(MemoryActivityLog.decoded(Data("not json".utf8)).entries.isEmpty, "a damaged log reads as empty")

        let name = "brim.tests.memory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = MemorySettings(defaults)
        suite.expect(fresh.autoClean && fresh.notify && fresh.idleHours == 8 && fresh.keep.isEmpty,
                     "automatic cleanup and the notification are on by default; idle after 8 h")
        defaults.set(99, forKey: DefaultsKey.memoryIdleHours)
        defaults.set(["  adb ", ""], forKey: DefaultsKey.memoryKeepList)
        defaults.set(false, forKey: DefaultsKey.memoryAutoClean)
        let changed = MemorySettings(defaults)
        suite.expect(changed.idleHours == 48 && changed.keep == ["adb"] && !changed.autoClean,
                     "settings are read back sanitized")
        suite.expect(MemoryRules.roomForHeavyWork(compressed: 9 << 30) && !MemoryRules.roomForHeavyWork(compressed: 13 << 30),
                     "the header's marker is the 10 GB compressor rule")
    }

    // MARK: Strings and registration

    private static func stringsAndRegistration(_ suite: TestSuite) {
        for language in AppLanguage.allCases {
            let text = FeatureStrings.memory(language)
            let empty = Mirror(reflecting: text).children.compactMap { child -> String? in
                guard let value = child.value as? String else { return nil }
                return value.isEmpty ? child.label : nil
            }
            suite.expect(empty.isEmpty && text.usedOf("116 GB", "128 GB") == "116 GB of 128 GB used"
                            && text.parentGone("23 h") == "parent gone 23 h"
                            && text.notificationBody(apps: 3, hours: 8, appsSize: "4 GB", leftovers: 1, leftoversSize: "183 MB")
                                == "Apps unused for 8 h+: 3 (4 GB). Leftovers: 1 (183 MB)."
                            && text.notificationBody(apps: 0, hours: 8, appsSize: "", leftovers: 0, leftoversSize: "")
                                == text.notificationNothing,
                         "Memory has every string in \(language.rawValue) (English until translated): empty \(empty)")
        }
        suite.expect(MemoryFormat.duration(23 * 3600 + 40 * 60) == "23 h" && MemoryFormat.duration(10) == "1 min"
                        && MemoryFormat.duration(6.6 * 86_400) == "6 d"
                        && MemoryFormat.title(name: "python3", count: 7, project: "greenup-test") == "python3 ×7 · greenup-test",
                     "sizes and ages read short")
        typealias Section = MenuPanelSectionGateContract.PanelSectionID
        suite.expect(Section.memory.featureGate == [.monitorMemory] && Section.memory.visibilityKey == DefaultsKey.panelShowMemory
                        && Section.allCases.last == .claude,
                     "the panel's Memory section belongs to the Memory monitor feature, not the island")
        suite.expect(FeatureVisibilitySupport.features(for: .memory) == [.monitorMemory],
                     "the Memory settings page shows while the Memory monitor is installed")
    }

    // MARK: Source contracts

    private static func source(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private static func sourceContracts(_ suite: TestSuite) {
        // No repeating timers: only one-shots, each with its reason.
        let folder = "Sources/Brim/Modules/Memory"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".swift") }
        suite.expect(files.count >= 10 && files.contains("MemoryTriggers.swift"),
                     "the Memory sources are where the contract reads them: \(files)")
        var timerLines = 0
        for file in files {
            let text = source(folder + "/" + file)
            for banned in ["repeats: true", "scheduledTimer", "TimelineView(.periodic", "makeTimerSource",
                           "DispatchSourceTimer", "asyncAfter", "Thread.sleep", "usleep("] {
                suite.expect(!text.contains(banned), "\(file) uses no \(banned)")
            }
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("Timer(") && !line.contains("Timer?") {
                timerLines += 1
                let before = lines[max(0, index - 12)..<index].joined(separator: "\n")
                suite.expect(line.contains("repeats: false") && before.contains("Rule 1 exception"),
                             "\(file):\(index + 1) a one-shot timer with its recorded reason")
            }
        }

        suite.expect(timerLines == 2,
                     "the only timers are the one-shot deadline (idle windows and the growth follow-up) and the 5 s Force check: \(timerLines)")

        // One memory alert path: MonitorAlertService has no memory alert at all.
        let alerts = source("Sources/Brim/Services/SystemMonitor/MonitorAlertService.swift")
        suite.expect(!alerts.isEmpty && !alerts.contains("snapshot.memoryPressure") && !alerts.contains("memoryPressure ==")
                        && !alerts.contains("MemoryPressureMonitor") && !alerts.contains("monitorAlertMemory")
                        && alerts.contains("SystemMonitor.shared.setAlertsActive(enabled)"),
                     "MonitorAlertService has no memory alert; MemoryService is the one memory notifier")
        func sources(containing needle: String) -> Set<String> {
            let root = "Sources/Brim"
            let files = (FileManager.default.enumerator(atPath: root)?.allObjects as? [String]) ?? []
            return Set(files.filter { $0.hasSuffix(".swift") && source(root + "/" + $0).contains(needle) })
        }
        let pressureSources = sources(containing: "makeMemoryPressureSource")
        suite.expect(pressureSources == ["Modules/Memory/MemoryPressureMonitor.swift"],
                     "one pressure feed for alerts and the module: \(pressureSources)")
        let enumerators = sources(containing: "proc_listallpids(")
        suite.expect(enumerators == ["Modules/Memory/ProcessTable.swift"],
                     "one process enumerator: \(enumerators)")

        // One process enumerator, footprint not RSS, no ps parsing.
        let usage = source("Sources/Brim/Services/SystemMonitor/ProcessUsageService.swift")
        let kill = source("Sources/Brim/Services/KillProcess/KillProcessService.swift")
        let ports = source("Sources/Brim/Services/PortManager/PortManagerService.swift")
        suite.expect(!usage.isEmpty && !usage.contains("\"/bin/ps\"") && !usage.contains("proc_listallpids")
                        && usage.contains("ProcessTable.snapshot(options: [.systemMemory])")
                        && usage.contains("ProcessTable.cpuNanoseconds()"),
                     "the memory breakdown reads footprint from the shared table, with no ps and no second enumerator")
        suite.expect(!kill.isEmpty && !kill.contains("pid,ppid,pcpu,rss,comm") && !kill.contains("\"-eo\"")
                        && kill.contains("memoryBytes: Double(record.footprint ?? 0)") && kill.contains("ProcessTable.snapshot()"),
                     "Kill Process lists footprint from the shared table, never RSS from ps")
        let killView = source("Sources/Brim/UI/KillProcess/KillProcessView.swift")
        suite.expect(kill.contains("isProtected: record.restricted ||")
                        && kill.contains("startedAt: record.restricted ? nil : record.startedAt")
                        && kill.contains("metricsReadable: !record.restricted && record.footprint != nil && record.cpuTime != nil")
                        && killView.contains("entry.metricsReadable ?"),
                     "Kill Process lists other users' processes protected, with no start time, and shows no CPU or memory for them")
        suite.expect(!ports.contains("proc_listallpids") && ports.contains("ProcessTable.pids()"),
                     "Port manager's identities come from the same enumerator")
        let section = source("Sources/Brim/UI/MenuPanel/SystemSection.swift")
        suite.expect(usage.contains("Self.memoryRows(ProcessTable.snapshot(options: [.systemMemory]))")
                        && usage.contains("memoryNotMeasured = read.notMeasured.count")
                        && section.contains("ProcessUsageService.shared.memoryNotMeasuredCount()")
                        && section.contains("otherUsersNotMeasured(notMeasured)")
                        && killView.contains("FeatureStrings.memory(l10n.language).notMeasuredHelp"),
                     "the memory list and Kill Process say what they could not measure")

        // The service's wiring of the review fixes.
        let service = source("Sources/Brim/Modules/Memory/MemoryService.swift")
        func body(_ start: String, _ end: String) -> String {
            guard let from = service.range(of: start), let to = service.range(of: end, range: from.upperBound..<service.endIndex)
            else { return "" }
            return String(service[from.lowerBound..<to.lowerBound])
        }
        let quitThem = body("    func quitThem() {", "    func review() {")
        suite.expect(service.contains("let leftovers = MemoryClassifier.quitThemTargets(findings)")
                        && quitThem.contains("quitThemAfterScan = scanGeneration") && !quitThem.contains("end(")
                        && !quitThem.contains("quit(")
                        && service.contains("if let after = quitThemAfterScan, generation > after {")
                        && service.contains("end(finding, automatic: false, recheck: .idleConfirmed)"),
                     "Quit them acts only after a scan begun after the click, on idle-confirmed groups judged again before each signal")
        suite.expect(service.contains("trigger: trigger, memoryTight: episode.isTight)")
                        && service.contains("end(finding, automatic: true, recheck: .automatic)")
                        && service.contains("alreadySignalled: autoSignalled")
                        && service.contains("if entry.outcome == .nothingToDo { scan(.action) }"),
                     "the automatic tier runs once per outside event, never twice on one process, and a failed signal is not rescanned")
        let force = body("    func force(_ entryID: UUID) {", "    /// Quit (the app's own terminate")
        let watchAt = force.range(of: "MemoryActionWatch.forForce(")
        let signalAt = force.range(of: "signalVerified(survivors, force: true)")
        suite.expect(watchAt != nil && signalAt != nil && watchAt!.lowerBound < signalAt!.lowerBound,
                     "Force sets up the watch before it signals")
        suite.expect(service.contains("awake: Self.uptime"), "scans time idle windows on the awake clock")
    }
}
