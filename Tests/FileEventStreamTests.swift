// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import CoreServices
import Darwin
import Foundation

/// The shared FSEvents stream (Services/FileEvents/FileEventStream.swift) and
/// its clients' pure parts (T-42 part B): event flags, a checked start,
/// bounded retries, fseventsd restarts, the Claude sync watcher's routing and
/// narrowed paths, and the status line's stable temporary file.
///
/// Fixtures only: a fake backend, a fake scheduler and a fake fseventsd exit.
/// No real stream is registered, no process is signalled, and files are
/// written only under a scratch folder.
enum FileEventStreamTests {
    static func run(_ suite: TestSuite) {
        let scratch = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("brim-file-events-\(UUID().uuidString)", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        flags(suite)
        retries(suite)
        boundedRetries(suite)
        daemonRestart(suite)
        resumedReplacement(suite)
        daemonDiscovery(suite)
        folderEntries(suite, scratch)
        claudeSyncRoute(suite)
        narrowedPaths(suite, scratch)
        stableTemporary(suite, scratch)
        sourceContracts(suite)
    }

    // MARK: Fakes

    final class FakeHandle: FileEventHandle {
        private(set) var stopped = false
        var latestEventID: FSEventStreamEventId = 100
        func stop() { stopped = true }
    }

    final class FakeBackend: FileEventBackend {
        /// Each attempt's result, in order; `always` once they run out.
        var results: [Bool]
        var always: Bool
        private(set) var starts = 0
        /// Each attempt's `since`.
        private(set) var sinces: [FSEventStreamEventId?] = []
        private(set) var handles: [FakeHandle] = []
        private(set) var deliver: (([FileEventStream.Event]) -> Void)?

        init(_ results: [Bool] = [], always: Bool = true) {
            self.results = results
            self.always = always
        }

        /// What a failed attempt reports.
        var failure = FileEventFailure(stage: .start, paths: 1, watchRoot: true, openDescriptors: 45, softLimit: 256)

        func start(paths: [String], configuration: FileEventStream.Configuration, since: FSEventStreamEventId?,
                   queue: DispatchQueue, deliver: @escaping ([FileEventStream.Event]) -> Void)
            -> Result<FileEventHandle, FileEventFailure> {
            starts += 1
            sinces.append(since)
            let succeeds = results.isEmpty ? always : results.removeFirst()
            guard succeeds else { return .failure(failure) }
            self.deliver = deliver
            let handle = FakeHandle()
            handles.append(handle)
            return .success(handle)
        }
    }

    final class FakeScheduler {
        final class Job: FileEventCancellable {
            let delay: TimeInterval
            let queue: DispatchQueue
            let work: () -> Void
            private(set) var cancelled = false
            var fired = false
            init(_ delay: TimeInterval, _ queue: DispatchQueue, _ work: @escaping () -> Void) {
                self.delay = delay
                self.queue = queue
                self.work = work
            }
            func cancel() { cancelled = true }
        }

        private(set) var jobs: [Job] = []
        var delays: [TimeInterval] { jobs.map(\.delay) }
        var waiting: [Job] { jobs.filter { !$0.fired && !$0.cancelled } }

        var scheduler: FileEventScheduler {
            FileEventScheduler { [unowned self] delay, queue, work in
                let job = Job(delay, queue, work)
                jobs.append(job)
                return job
            }
        }

        /// Runs the first waiting job on the queue it was scheduled on, as
        /// its timer would (`queue`: the caller's, for reading).
        @discardableResult
        func fire(on queue: DispatchQueue) -> Bool {
            guard let job = waiting.first else { return false }
            job.fired = true
            job.queue.sync { job.work() }
            return true
        }
    }

    final class Calls {
        var resyncs = 0
        var batches: [FileEventStream.Batch] = []
    }

    static func makeStream(_ backend: FakeBackend, _ scheduler: FakeScheduler, queue: DispatchQueue,
                           daemon: FSEventsDaemonWatch? = nil, calls: Calls) -> FileEventStream {
        FileEventStream(name: "test", queue: queue, configuration: .init(latency: 0.1), backend: backend,
                        scheduler: scheduler.scheduler, daemon: daemon, observesPower: false,
                        handler: { calls.batches.append($0) }, resync: { calls.resyncs += 1 })
    }

    // MARK: Flags

    static func flags(_ suite: TestSuite) {
        func batch(_ flag: Int) -> FileEventStream.Batch {
            FileEventStream.Batch([FileEventStream.Event(path: "/x", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)),
                                   FileEventStream.Event(path: "/y", flags: FSEventStreamEventFlags(flag))])
        }
        for (flag, label) in [(kFSEventStreamEventFlagMustScanSubDirs, "MustScanSubDirs"),
                              (kFSEventStreamEventFlagUserDropped, "UserDropped"),
                              (kFSEventStreamEventFlagKernelDropped, "KernelDropped"),
                              (kFSEventStreamEventFlagEventIdsWrapped, "EventIdsWrapped")] {
            suite.expect(batch(flag).mustRescan && !batch(flag).rootChanged, "\(label) means events were lost: rescan")
        }
        let root = batch(kFSEventStreamEventFlagRootChanged)
        suite.expect(root.rootChanged && !root.mustRescan, "RootChanged is reported as a root change")
        let plain = batch(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        suite.expect(!plain.mustRescan && !plain.rootChanged && plain.paths == ["/x", "/y"],
                     "item events alone ask for neither, and keep their paths in order")
    }

    // MARK: Retries

    /// A stream whose start failed used to stay silent until Brim was
    /// relaunched (four copies ignored FSEventStreamStart's result).
    static func retries(_ suite: TestSuite) {
        let queue = DispatchQueue(label: "brim.tests.file-events.retry")
        let backend = FakeBackend([false, false, true])
        let scheduler = FakeScheduler()
        let calls = Calls()
        let stream = makeStream(backend, scheduler, queue: queue, calls: calls)
        queue.sync { stream.watch(["/scratch/a"]) }
        suite.expect(!queue.sync { stream.isRunning } && scheduler.delays == [1], "a failed start schedules a retry after 1 s")
        scheduler.fire(on: queue)
        suite.expect(!queue.sync { stream.isRunning } && scheduler.delays == [1, 2] && calls.resyncs == 0,
                     "a second failure backs off to 2 s, still not running and no resync yet")
        scheduler.fire(on: queue)
        suite.expect(queue.sync { stream.isRunning } && backend.starts == 3 && calls.resyncs == 1 && scheduler.waiting.isEmpty,
                     "the third attempt starts the stream and asks the client to resync once")
        backend.deliver?([FileEventStream.Event(path: "/scratch/a/f", flags: 0)])
        suite.expect(calls.batches.map(\.paths) == [["/scratch/a/f"]], "events of the running stream reach the handler")
        queue.sync { stream.watch(["/scratch/a"]) }
        suite.expect(backend.starts == 3 && calls.resyncs == 1, "the same paths do not restart a running stream")
        let firstHandle = backend.handles.last
        let staleDeliver = backend.deliver
        queue.sync { stream.watch(["/scratch/b"]) }
        suite.expect(backend.starts == 4 && firstHandle?.stopped == true && calls.resyncs == 1,
                     "new paths stop the old stream and start one, with no resync after a clean start")
        staleDeliver?([FileEventStream.Event(path: "/scratch/a/late", flags: 0)])
        suite.expect(calls.batches.count == 1, "a batch the stopped stream had already queued is dropped")
        queue.sync { stream.stop() }
        suite.expect(!queue.sync { stream.isRunning } && backend.handles.last?.stopped == true, "stop() stops the stream")
    }

    static func boundedRetries(_ suite: TestSuite) {
        let queue = DispatchQueue(label: "brim.tests.file-events.bounded")
        let backend = FakeBackend(always: false)
        let scheduler = FakeScheduler()
        let calls = Calls()
        let stream = makeStream(backend, scheduler, queue: queue, calls: calls)
        queue.sync { stream.watch(["/scratch/a"]) }
        while scheduler.fire(on: queue) {}
        suite.expect(scheduler.jobs.count == 10 && scheduler.delays == FileEventRetryPolicy.standard.delays
                        && backend.starts == 11 && scheduler.waiting.isEmpty,
                     "an always-failing start is retried exactly 10 times (1 s to 60 s), then waits: \(scheduler.delays)")
        suite.expect(FileEventRetryPolicy.standard.delays.reduce(0, +) <= 5 * 60 + 5,
                     "the retries span about 5 minutes")
        queue.sync { stream.watch(["/scratch/a"]) }
        suite.expect(backend.starts == 12 && scheduler.jobs.count == 11 && scheduler.jobs.last?.delay == 1,
                     "a later watch(_:) of the same paths starts a new sequence")
        let pending = scheduler.waiting.first
        queue.sync { stream.stop() }
        suite.expect(pending?.cancelled == true && scheduler.waiting.isEmpty, "stop() cancels a pending retry")
        // Sleep cancels a retry; wake makes one attempt at once.
        queue.sync { stream.watch(["/scratch/c"]) }
        let beforeSleep = scheduler.waiting.first
        queue.sync { stream.systemWillSleep() }
        let startsAsleep = backend.starts
        suite.expect(beforeSleep?.cancelled == true, "going to sleep cancels the pending retry")
        backend.always = true
        queue.sync { stream.systemDidWake() }
        suite.expect(backend.starts == startsAsleep + 1 && queue.sync { stream.isRunning } && calls.resyncs == 1,
                     "a wake makes one immediate attempt, and its success resyncs")
        queue.sync { stream.stop() }
    }

    // MARK: fseventsd restart

    static func daemonRestart(_ suite: TestSuite) {
        let queue = DispatchQueue(label: "brim.tests.file-events.daemon")
        final class Arms {
            var pids: [pid_t] = []
            var exits: [() -> Void] = []
            var cancelled = 0
        }
        final class Token: FileEventCancellable {
            let arms: Arms
            init(_ arms: Arms) { self.arms = arms }
            func cancel() { arms.cancelled += 1 }
        }
        let arms = Arms()
        var daemonPid: pid_t = 67_772
        // Its own scheduler: the daemon's discovery retries are not the streams'.
        let daemonScheduler = FakeScheduler()
        let daemon = FSEventsDaemonWatch(locate: { FSEventsDaemonWatch.Daemon(pid: daemonPid, startedAt: 1) }, arm: { pid, exited in
            arms.pids.append(pid)
            arms.exits.append(exited)
            return Token(arms)
        }, scheduler: daemonScheduler.scheduler, now: { 1_000 })
        let backend = FakeBackend()
        let other = FakeBackend()
        let scheduler = FakeScheduler()
        let calls = Calls()
        let otherCalls = Calls()
        let stream = makeStream(backend, scheduler, queue: queue, daemon: daemon, calls: calls)
        let second = makeStream(other, scheduler, queue: queue, daemon: daemon, calls: otherCalls)
        queue.sync {
            stream.watch(["/scratch/a"])
            second.watch(["/scratch/b"])
        }
        daemon.settle()
        suite.expect(arms.pids == [67_772], "the first running stream arms one exit watch on fseventsd: \(arms.pids)")
        daemonPid = 81_000
        backend.results = [false]
        arms.exits.first?()
        daemon.settle()
        queue.sync {}
        suite.expect(backend.handles.first?.stopped == true && other.handles.first?.stopped == true
                        && !queue.sync { stream.isRunning || second.isRunning },
                     "fseventsd exiting stops every registered stream")
        suite.expect(scheduler.waiting.map(\.delay) == [1, 1], "each stream re-creates itself after 1 s")
        scheduler.fire(on: queue)
        scheduler.fire(on: queue)
        suite.expect(!queue.sync { stream.isRunning } && calls.resyncs == 0
                        && queue.sync { second.isRunning } && otherCalls.resyncs == 1,
                     "a failed re-creation is not a recovery; a successful one resyncs once")
        daemon.settle()
        suite.expect(arms.pids == [67_772, 81_000], "after the first successful re-creation the new pid is watched: \(arms.pids)")
        scheduler.fire(on: queue)
        suite.expect(queue.sync { stream.isRunning } && calls.resyncs == 1 && otherCalls.resyncs == 1,
                     "the stream recovers on its next success and resyncs exactly once")
        daemon.settle()
        suite.expect(arms.pids.count == 2, "a recovery does not arm a second watch on the same daemon")
        queue.sync {
            stream.stop()
            second.stop()
        }
        daemon.settle()
        suite.expect(arms.cancelled >= 2, "the exit watch goes once no stream is left")
    }

    // MARK: Review fixes (T-42)

    /// Real failure: new paths replaced the stream with one started "since
    /// now", so a memory edit fseventsd had not delivered yet (its latency
    /// window) when a new project folder joined the paths was lost.
    static func resumedReplacement(_ suite: TestSuite) {
        let queue = DispatchQueue(label: "brim.tests.file-events.resume")
        let backend = FakeBackend()
        let scheduler = FakeScheduler()
        let calls = Calls()
        let stream = makeStream(backend, scheduler, queue: queue, calls: calls)
        queue.sync { stream.watch(["/r/sessions", "/r/projects/A/memory"]) }
        suite.expect(backend.sinces == [nil], "a first stream starts from now")
        backend.handles.last?.latestEventID = 9_001
        queue.sync { stream.watch(["/r/sessions", "/r/projects/A/memory", "/r/projects/B/memory"]) }
        suite.expect(backend.starts == 2 && backend.sinces.last == 9_001 && backend.handles.first?.stopped == true
                        && calls.resyncs == 0,
                     "new paths start the replacement from the old stream's last event id, so nothing pending is lost, with no full resync: \(backend.sinces)")
        backend.results = [false, true]
        backend.handles.last?.latestEventID = 9_050
        queue.sync { stream.watch(["/r/sessions"]) }
        scheduler.fire(on: queue)
        suite.expect(backend.sinces.suffix(2) == [9_050, 9_050] && queue.sync { stream.isRunning } && calls.resyncs == 1,
                     "a replacement whose first registration failed still resumes from that id, and its success resyncs once")
        queue.sync {
            stream.stop()
            stream.watch(["/r/sessions"])
        }
        suite.expect(backend.sinces.last == .some(nil), "after stop() a new stream starts from now again")
        queue.sync { stream.stop() }
    }

    /// Real failures: a failed fseventsd lookup was never retried; after a
    /// watched exit whose re-creations all failed nothing watched the new
    /// daemon; and a stream that registered with a daemon that died before
    /// it was found stayed dead.
    static func daemonDiscovery(_ suite: TestSuite) {
        let queue = DispatchQueue(label: "brim.tests.file-events.discovery")
        final class Fixture {
            var daemon: FSEventsDaemonWatch.Daemon?
            var armed: [pid_t] = []
            var exits: [pid_t: () -> Void] = [:]
            var clock: UInt64 = 1_000
        }
        final class Token: FileEventCancellable { func cancel() {} }
        let fixture = Fixture()
        let daemonScheduler = FakeScheduler()
        let watch = FSEventsDaemonWatch(locate: { fixture.daemon }, arm: { pid, exited in
            fixture.armed.append(pid)
            fixture.exits[pid] = exited
            return Token()
        }, scheduler: daemonScheduler.scheduler, now: { fixture.clock })
        let backend = FakeBackend()
        let scheduler = FakeScheduler()
        let calls = Calls()
        let stream = makeStream(backend, scheduler, queue: queue, daemon: watch, calls: calls)

        // 1. Not found at first: retried on the policy, without a stream start.
        queue.sync { stream.watch(["/scratch/a"]) }
        watch.settle()
        suite.expect(fixture.armed.isEmpty && daemonScheduler.waiting.map(\.delay) == [1],
                     "a failed lookup schedules another after 1 s")
        fixture.daemon = .init(pid: 500, startedAt: 900)
        daemonScheduler.fire(on: queue)
        suite.expect(fixture.armed == [500] && daemonScheduler.waiting.isEmpty,
                     "the retry finds the daemon and watches it, with no stream start needed")

        // 2. A watched exit whose re-creations all fail.
        backend.always = false
        fixture.daemon = .init(pid: 600, startedAt: 2_000)
        // Registrations from here on come after the new daemon started.
        fixture.clock = 3_000
        fixture.exits[500]?()
        watch.settle()
        queue.sync {}
        while scheduler.fire(on: queue) {}
        suite.expect(!queue.sync { stream.isRunning } && scheduler.waiting.isEmpty,
                     "the stream spent its retries on the restarted daemon")
        suite.expect(daemonScheduler.waiting.map(\.delay) == [1], "the next daemon is looked for after 1 s regardless")
        daemonScheduler.fire(on: queue)
        suite.expect(fixture.armed == [500, 600], "the new daemon is watched though no stream registered with it")
        backend.always = true
        let startsBefore = backend.starts
        fixture.exits[600]?()
        watch.settle()
        queue.sync {}
        scheduler.fire(on: queue)
        suite.expect(backend.starts == startsBefore + 1 && queue.sync { stream.isRunning } && calls.resyncs >= 1,
                     "a later restart is still seen: the given-up stream registers again and resyncs")
        queue.sync { stream.stop() }
        watch.settle()

        // 3. Registered with a daemon that died before it was found.
        let raceBackend = FakeBackend()
        let raceScheduler = FakeScheduler()
        let raceDaemonScheduler = FakeScheduler()
        let raceFixture = Fixture()
        raceFixture.clock = 5_000
        let raceWatch = FSEventsDaemonWatch(locate: { raceFixture.daemon }, arm: { pid, exited in
            raceFixture.armed.append(pid)
            return Token()
        }, scheduler: raceDaemonScheduler.scheduler, now: { raceFixture.clock })
        let raceCalls = Calls()
        let raced = makeStream(raceBackend, raceScheduler, queue: queue, daemon: raceWatch, calls: raceCalls)
        // The stream registers at 5 000 µs; the daemon found started at 6 000.
        raceFixture.daemon = .init(pid: 700, startedAt: 6_000)
        queue.sync { raced.watch(["/scratch/r"]) }
        raceWatch.settle()
        queue.sync {}
        suite.expect(raceFixture.armed == [700] && raceBackend.handles.first?.stopped == true
                        && raceScheduler.waiting.map(\.delay) == [1],
                     "a daemon that started after the stream registered: the stream registers again after 1 s")
        raceScheduler.fire(on: queue)
        raceWatch.settle()
        suite.expect(queue.sync { raced.isRunning } && raceCalls.resyncs == 1 && raceFixture.armed == [700],
                     "it recovers with one resync, and the watched daemon is not armed twice")
        // A daemon that started before the registration is the one it reached.
        let calmFixture = Fixture()
        calmFixture.daemon = .init(pid: 800, startedAt: 10)
        let calmScheduler = FakeScheduler()
        let calmWatch = FSEventsDaemonWatch(locate: { calmFixture.daemon }, arm: { pid, _ in
            calmFixture.armed.append(pid)
            return Token()
        }, scheduler: FakeScheduler().scheduler, now: { 5_000 })
        let calmBackend = FakeBackend()
        let calm = makeStream(calmBackend, calmScheduler, queue: queue, daemon: calmWatch, calls: Calls())
        queue.sync { calm.watch(["/scratch/c"]) }
        calmWatch.settle()
        queue.sync {}
        suite.expect(calmFixture.armed == [800] && calmBackend.starts == 1 && queue.sync { calm.isRunning },
                     "a daemon older than the registration restarts nothing")
        queue.sync {
            raced.stop()
            calm.stop()
        }
        raceWatch.settle()
        calmWatch.settle()
        suite.expect(raceDaemonScheduler.waiting.isEmpty, "no discovery waits once no stream is left")
    }

    /// Real failure: a config folder with no projects/ yet was never watched
    /// for one created later (the sessions-only stream reports nothing
    /// there), so its repos' memory stayed unsynced until a full run.
    static func folderEntries(_ suite: TestSuite, _ scratch: String) {
        let fm = FileManager.default
        let config = scratch + "/fresh-config"
        try? fm.createDirectory(atPath: config, withIntermediateDirectories: true)
        let queue = DispatchQueue(label: "brim.tests.file-events.entries")
        let fired = DispatchSemaphore(value: 0)
        let watch = FolderEntriesWatch(path: config + "/projects", queue: queue) { fired.signal() }
        queue.sync { watch.start() }
        suite.expect(queue.sync { watch.isArmed && !watch.watchingFolder },
                     "with no projects/ yet, its parent is watched")
        try? fm.createDirectory(atPath: config + "/projects", withIntermediateDirectories: false)
        let appeared = fired.wait(timeout: .now() + 5) == .success
        suite.expect(appeared && queue.sync { watch.watchingFolder },
                     "projects/ appearing is a change, and the watch moves onto it")
        try? fm.createDirectory(atPath: config + "/projects/-Users-x-Code-App", withIntermediateDirectories: false)
        suite.expect(fired.wait(timeout: .now() + 5) == .success, "a repo folder added to the new projects/ is a change")
        try? fm.removeItem(atPath: config + "/projects")
        let removed = fired.wait(timeout: .now() + 5) == .success
        suite.expect(removed && queue.sync { watch.isArmed && !watch.watchingFolder },
                     "projects/ going away is a change, and the parent is watched again")
        queue.sync { watch.cancel() }
        let missing = FolderEntriesWatch(path: scratch + "/no-such-folder/projects", queue: queue) {}
        queue.sync { missing.start() }
        suite.expect(queue.sync { !missing.isArmed }, "with the parent missing too nothing is armed, so the next update looks again")
        let sync = source("Sources/Brim/Modules/ClaudeAccounts/App/ClaudeSyncWatcher.swift")
        let update = sync.components(separatedBy: "    func update(configDirectories:").dropFirst().first?
            .components(separatedBy: "    func stop()").first ?? ""
        suite.expect(sync.contains("FolderEntriesWatch(path: folder + \"/projects\"") && !sync.contains("O_EVTONLY")
                        && !sync.contains("projectSources") && update.contains("where: \\.watchingFolder) { projectsChanged() }"),
                     "the sync watcher watches projects/ through FolderEntriesWatch, and an update re-arms a missing one")
    }

    // MARK: Claude sync watcher

    /// ClaudeSyncWatcher ignored event flags, and its per-path filter dropped
    /// the projects/ root a MustScanSubDirs event names: lost memory changes
    /// stayed unsynced until the next full run.
    static func claudeSyncRoute(_ suite: TestSuite) {
        let folders = ["/r/.claude-a"]
        let sessions = ["/r/.claude-a/sessions", "/r/.claude-b/sessions"]
        suite.expect(ClaudeSync.watchRoute(paths: ["/r/.claude-a/projects"], rescan: true, sessionRoots: sessions,
                                           folders: folders) == .full,
                     "a MustScanSubDirs batch on the projects/ root runs a full reconcile")
        suite.expect(ClaudeSync.watchRoute(paths: ["/r/.claude-a/projects"], rescan: false, sessionRoots: sessions,
                                           folders: folders) == .nothing,
                     "the same path without its flag matches no rule (the loss the flag now prevents)")
        suite.expect(ClaudeSync.watchRoute(paths: ["/r/.claude-a/projects/-Users-x-Code-App/memory/notes.md"], rescan: false,
                                           sessionRoots: sessions, folders: folders)
                        == .changes(sessions: false, memory: ["-Users-x-Code-App"]),
                     "a memory file routes to its repo's memory")
        suite.expect(ClaudeSync.watchRoute(paths: ["/r/.claude-b/sessions/4242.json"], rescan: false, sessionRoots: sessions,
                                           folders: folders) == .changes(sessions: true, memory: []),
                     "a sessions file routes to the running sessions")
        suite.expect(ClaudeSync.watchRoute(paths: ["/r/.claude-a/projects/S/abc.jsonl"], rescan: false, sessionRoots: sessions,
                                           folders: folders) == .nothing,
                     "a transcript write routes to nothing")
    }

    static func narrowedPaths(_ suite: TestSuite, _ scratch: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: scratch + "/config/projects/A/memory", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: scratch + "/config/projects/B", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: scratch + "/config/projects/.hidden", withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: URL(fileURLWithPath: scratch + "/config/projects/file.txt"))
        let root = scratch + "/config"
        let realRoot = ClaudeFileIO.realPath(root)
        var slugs = ClaudeSync.projectSlugs(folders: [realRoot])
        suite.expect(slugs == [realRoot: ["A", "B"]], "repo folders are listed without dot-names or files: \(slugs)")
        var paths = ClaudeSync.watchedPaths(configDirectories: [root], folders: [realRoot], slugs: slugs)
        suite.expect(paths == [realRoot + "/sessions", realRoot + "/projects/A/memory", realRoot + "/projects/B/memory"],
                     "sessions/ and every repo's memory/ are watched, one that does not exist yet too: \(paths)")
        suite.expect(!paths.contains(realRoot + "/projects") && !paths.contains { $0.hasSuffix("/projects") },
                     "no projects/ root is streamed: transcripts belong to the agent usage stream")
        try? fm.createDirectory(atPath: scratch + "/config/projects/C", withIntermediateDirectories: true)
        slugs = ClaudeSync.projectSlugs(folders: [realRoot])
        paths = ClaudeSync.watchedPaths(configDirectories: [root], folders: [realRoot], slugs: slugs)
        suite.expect(paths.contains(realRoot + "/projects/C/memory"), "a new repo folder adds its memory/ path")
    }

    // MARK: Status line's live file

    static func stableTemporary(_ suite: TestSuite, _ scratch: String) {
        let folder = scratch + "/live"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let target = folder + "/default.json"
        var failures = 0
        for index in 0..<100 {
            do {
                try ClaudeFileIO.writeAtomically(Data("{\"n\":\(index)}".utf8), to: target, temporary: .stableLocked)
            } catch {
                failures += 1
            }
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
        suite.expect(failures == 0 && names == [".default.json.lock", "default.json"],
                     "100 locked writes leave only the target and its lock file, no temporary names: \(names)")
        suite.expect((try? String(contentsOfFile: target, encoding: .utf8)) == "{\"n\":99}", "the last write is the content")
        var info = stat()
        suite.expect(stat(target, &info) == 0 && info.st_mode & 0o777 == 0o600, "the mode is kept")
        // Another writer holds the lock: this one is skipped, the file untouched.
        let holder = open(folder + "/.default.json.lock", O_RDWR | O_CLOEXEC)
        let locked = holder >= 0 && flock(holder, LOCK_EX | LOCK_NB) == 0
        var thrown: ClaudeFileError?
        do {
            try ClaudeFileIO.writeAtomically(Data("{\"n\":-1}".utf8), to: target, temporary: .stableLocked)
        } catch {
            thrown = error as? ClaudeFileError
        }
        if holder >= 0 { close(holder) }
        suite.expect(locked && thrown == .busy, "a held lock makes the write throw busy at once: \(String(describing: thrown))")
        suite.expect((try? String(contentsOfFile: target, encoding: .utf8)) == "{\"n\":99}"
                        && !FileManager.default.fileExists(atPath: folder + "/.default.json.tmp"),
                     "a skipped write leaves the target and no temporary file")
        suite.expect(ClaudeFileError.busy.message.contains("in progress"), "busy has words for the person")
        do {
            try ClaudeFileIO.writeAtomically(Data("ok".utf8), to: target, temporary: .stableLocked)
        } catch {
            suite.expect(false, "the lock is free again once released: \(error)")
        }
        // The default keeps unique names and makes no lock file.
        let plain = scratch + "/plain"
        try? FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        try? ClaudeFileIO.writeAtomically(Data("a".utf8), to: plain + "/rc")
        let plainNames = (try? FileManager.default.contentsOfDirectory(atPath: plain)) ?? []
        suite.expect(plainNames == ["rc"], "unique temporary names leave no lock file: \(plainNames)")
    }

    // MARK: Source contracts

    private static func source(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private static func swiftFiles(_ folder: String) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: folder)
        var files: [String] = []
        while let next = enumerator?.nextObject() as? String {
            if next.hasSuffix(".swift") { files.append(folder + "/" + next) }
        }
        return files.sorted()
    }

    static func sourceContracts(_ suite: TestSuite) {
        let streamFile = "Sources/Brim/Services/FileEvents/FileEventStream.swift"
        let creators = swiftFiles("Sources/Brim").filter { source($0).contains("FSEventStreamCreate(") }
        suite.expect(creators == [streamFile], "the only FSEventStreamCreate in Brim is FileEventStream's: \(creators)")
        let stream = source(streamFile)
        suite.expect(stream.contains("guard FSEventStreamStart(created) else"), "FileEventStream checks FSEventStreamStart's result")
        suite.expect(stream.contains("Rule 1 exception") && !stream.contains("repeating:") && !stream.contains("repeats: true")
                        && !stream.contains("scheduledTimer") && !stream.contains("asyncAfter"),
                     "the retry timer is a one-shot with its recorded reason, and nothing repeats")
        for file in ["Sources/Brim/Modules/ClaudeAccounts/App/ClaudeSyncWatcher.swift",
                     "Sources/Brim/Modules/ClaudeAccounts/App/ClaudeAccountsWatcher.swift",
                     "Sources/Brim/Modules/ClaudeAccounts/App/ClaudeMCPModel.swift",
                     "Sources/Brim/Services/AgentUsage/AgentUsageService.swift"] {
            let text = source(file)
            suite.expect(text.contains("FileEventStream(") && !text.contains("FSEventStream"),
                         "\(file) streams through FileEventStream")
        }
        let store = source("Sources/Brim/Services/AgentUsage/AgentUsageStore.swift")
        suite.expect(!store.isEmpty && !store.contains("AgentLogWatcher") && !store.contains("FSEventStream"),
                     "AgentLogWatcher is gone: FileEventStream replaced it")
        let uninstall = source("Sources/Brim/Services/Uninstall/UninstallerSupport.swift")
        suite.expect(!uninstall.contains("TrashRenames"), "TrashRenames is gone: the listing diff replaced it")

        // The sync watcher: flags reach the router, a full run reconciles
        // everything, and its stream never covers a projects/ root.
        let sync = source("Sources/Brim/Modules/ClaudeAccounts/App/ClaudeSyncWatcher.swift")
        let handle = sync.components(separatedBy: "private func handle(").dropFirst().first ?? ""
        let resync = sync.components(separatedBy: "private func resyncAll(").dropFirst().first?
            .components(separatedBy: "private func").first ?? ""
        suite.expect(handle.contains("batch.mustRescan || batch.rootChanged") && handle.contains("ClaudeSync.watchRoute(")
                        && handle.contains("case .full:") && resync.contains("reconcile(.all"),
                     "the sync watcher routes flagged batches to a full reconcile")
        let watches = sync.components(separatedBy: "\n").filter { $0.contains("stream.watch(") }
        suite.expect(!watches.isEmpty && watches.allSatisfy { $0.contains("ClaudeSync.watchedPaths(") }
                        && !sync.contains("+ \"/projects\" }"),
                     "the sync watcher streams only sessions/ and memory/ paths: \(watches)")
        let usage = source("Sources/Brim/Services/AgentUsage/AgentUsageService.swift")
        suite.expect(usage.contains("watcher?.watch(existing.map(\\.url.path))")
                        && usage.contains("rescan: batch.mustRescan || batch.rootChanged"),
                     "the agent usage stream, the one over transcripts, rescans on lost events")

        // The accounts watcher: exact files, so no WatchRoot; lost events
        // read everything again.
        let accounts = source("Sources/Brim/Modules/ClaudeAccounts/App/ClaudeAccountsWatcher.swift")
        suite.expect(accounts.contains("watchRoot: false") && accounts.contains("if batch.mustRescan { self?.fullLook(files: true) }")
                        && accounts.contains("resync: { [weak self] in self?.fullLook(files: true) }"),
                     "the accounts watcher runs without WatchRoot and takes a full look after lost events")
        // Only the status line's live write uses the locked stable name.
        let helper = source("Sources/Brim/Modules/ClaudeAccounts/ClaudeHelperCommands.swift")
        let lockedCallers = swiftFiles("Sources").filter { source($0).contains("temporary: .stableLocked") }
        suite.expect(helper.contains("writeAtomically(data, to: path, temporary: .stableLocked)")
                        && lockedCallers == ["Sources/Brim/Modules/ClaudeAccounts/ClaudeHelperCommands.swift"],
                     "only the status line's live file is written under the lock: \(lockedCallers)")
    }
}
