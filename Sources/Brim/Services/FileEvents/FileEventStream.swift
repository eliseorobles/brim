// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import AppKit
import CoreServices
import Darwin
import Foundation
import os

/// One FSEvents stream for a client: its own paths and latency, events with
/// their flags, a checked start, bounded retries, and re-creation when
/// fseventsd restarts. Every callback runs on the client's queue, and every
/// call into it is made there too.
///
/// It replaced five hand-rolled copies (T-42). Three of them ignored the
/// event flags, so a MustScanSubDirs or a dropped batch lost changes for good,
/// and four ignored FSEventStreamStart's result, so a stream that never
/// registered (fseventsd restarting answers `wait_for_startup: ETIMEDOUT` for
/// about 10 s) looked like a quiet folder until Brim was relaunched.
///
/// - A failed registration is retried on a bounded backoff (FileEventRetryPolicy).
///   After a success that followed a failure, or after a fseventsd restart,
///   `resync` runs once: the client looks again at what it may have missed.
/// - `FSEventsDaemonWatch` tells every stream when fseventsd exits; the
///   stream counts as recovered only once a new registration succeeded.
/// - New paths replace a running stream with one that resumes from the old
///   stream's last event id, so changes fseventsd had not delivered yet (its
///   latency window) reach the new stream instead of being lost.
final class FileEventStream {
    struct Event: Equatable {
        let path: String
        let flags: FSEventStreamEventFlags
        /// The file id, when the stream asked for extended data.
        let inode: UInt64?

        init(path: String, flags: FSEventStreamEventFlags, inode: UInt64? = nil) {
            self.path = path
            self.flags = flags
            self.inode = inode
        }
    }

    struct Batch: Equatable {
        let events: [Event]
        var paths: [String] { events.map(\.path) }
        /// MustScanSubDirs, UserDropped, KernelDropped or EventIdsWrapped:
        /// events were lost, so what they named must be read again.
        var mustRescan: Bool
        /// RootChanged: a watched root appeared, moved or went away.
        var rootChanged: Bool

        static let lostFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped)

        init(_ events: [Event]) {
            self.events = events
            mustRescan = events.contains { $0.flags & Self.lostFlags != 0 }
            rootChanged = events.contains { $0.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 }
        }
    }

    struct Configuration: Equatable {
        /// Seconds FSEvents coalesces a burst of writes into one batch.
        var latency: TimeInterval
        var fileEvents = true
        /// Reports a watched root appearing, moving or going away (and an
        /// ancestor of it being renamed). Off for streams over exact files
        /// that are replaced all the time (each replace would read as a root
        /// change), and for streams over many paths: the FSEvents client
        /// library opens one descriptor per watched path in Brim's own
        /// process for it, held while the stream lives, and a Finder-launched
        /// app's soft RLIMIT_NOFILE is 256 (T-52: 427 claude-sync paths made
        /// FSEventStreamCreate fail with EMFILE at index 285, every time).
        /// Without it a root that is created, renamed or removed still
        /// reports an item event at its own path, as long as the path is a
        /// real one (no link in it).
        var watchRoot = true
        var extendedData = false
    }

    /// Why the last registration failed, nil once one succeeded. Confined
    /// to `queue`; the log says it too.
    private(set) var lastFailure: FileEventFailure?

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brim", category: "file-events")

    let name: String
    let queue: DispatchQueue
    private let configuration: Configuration
    private let backend: FileEventBackend
    private let retry: FileEventRetryPolicy
    private let scheduler: FileEventScheduler
    private let daemon: FSEventsDaemonWatch?
    private let handler: (Batch) -> Void
    private let resync: () -> Void
    private var observers: [NSObjectProtocol] = []

    // Confined to `queue`.
    private var paths: [String] = []
    private var handle: FileEventHandle?
    /// Tells deliveries of a stopped stream, already queued, from the current one.
    private var generation = 0
    private var failures = 0
    private var pending: FileEventCancellable?
    /// Set by a failed registration or a fseventsd restart; the next success
    /// runs `resync` once and clears it.
    private var needsResync = false
    /// Where the next registration resumes: the replaced stream's last event
    /// id. Review fix, T-42: a replacement started "since now", so what the
    /// old stream had not delivered yet was lost (a memory edit pending while
    /// a new project folder joined the paths stayed unsynced).
    private var resumeFrom: FSEventStreamEventId?
    private var asleep = false

    var isRunning: Bool { handle != nil }

    init(name: String, queue: DispatchQueue, configuration: Configuration,
         backend: FileEventBackend = FSEventsBackend(), retry: FileEventRetryPolicy = .standard,
         scheduler: FileEventScheduler = .dispatch, daemon: FSEventsDaemonWatch? = .shared,
         observesPower: Bool = true,
         handler: @escaping (Batch) -> Void, resync: @escaping () -> Void) {
        self.name = name
        self.queue = queue
        self.configuration = configuration
        self.backend = backend
        self.retry = retry
        self.scheduler = scheduler
        self.daemon = daemon
        self.handler = handler
        self.resync = resync
        guard observesPower else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.systemWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.systemDidWake() }
            },
        ]
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        pending?.cancel()
        handle?.stop()
    }

    /// Watches `paths`. Restarts only when they changed, or when the last
    /// sequence of retries gave up; [] stops.
    func watch(_ paths: [String]) {
        dispatchPrecondition(condition: .onQueue(queue))
        if paths == self.paths, !paths.isEmpty, handle != nil || pending != nil { return }
        let resume = handle?.latestEventID ?? resumeFrom
        tearDown()
        self.paths = paths
        guard !paths.isEmpty else {
            resumeFrom = nil
            daemon?.unregister(self)
            return
        }
        resumeFrom = resume
        daemon?.register(self)
        failures = 0
        attempt()
    }

    /// Stops the stream and cancels any pending retry.
    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        tearDown()
        paths = []
        needsResync = false
        resumeFrom = nil
        daemon?.unregister(self)
    }

    private func tearDown() {
        pending?.cancel()
        pending = nil
        handle?.stop()
        handle = nil
        generation &+= 1
    }

    /// On `queue`: one registration.
    private func attempt() {
        pending = nil
        guard !paths.isEmpty, !asleep, handle == nil else { return }
        generation &+= 1
        let current = generation
        let result = backend.start(paths: paths, configuration: configuration, since: resumeFrom,
                                   queue: queue) { [weak self] events in
            guard let self, self.generation == current, !events.isEmpty else { return }
            self.handler(Batch(events))
        }
        switch result {
        case .success(let started):
            handle = started
            resumeFrom = nil
            failures = 0
            lastFailure = nil
            daemon?.streamStarted()
            if needsResync {
                needsResync = false
                resync()
            }
        case .failure(let failure):
            failures += 1
            needsResync = true
            lastFailure = failure
            // The reason once per sequence of retries, and again when they
            // are spent: "could not register" alone hid an EMFILE for a
            // night (T-52).
            if failures == 1 {
                Self.log.error("\(self.name, privacy: .public): could not register with fseventsd: \(failure.message, privacy: .public)")
            }
            if let delay = retry.delay(afterFailures: failures) {
                schedule(after: delay)
            } else {
                // Waits for a push: the next watch(_:), a wake or a fseventsd restart.
                Self.log.error("\(self.name, privacy: .public): could not register with fseventsd after \(self.failures) tries: \(failure.message, privacy: .public)")
            }
        }
    }

    private func schedule(after delay: TimeInterval) {
        pending?.cancel()
        pending = scheduler.schedule(delay, queue) { [weak self] in self?.attempt() }
    }

    /// On `queue`: fseventsd exited. The old registration is gone with it;
    /// a new one is made after a second, then on the retry policy.
    func daemonExited() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !paths.isEmpty else { return }
        pending?.cancel()
        pending = nil
        handle?.stop()
        handle = nil
        generation &+= 1
        failures = 0
        needsResync = true
        guard !asleep else { return }
        schedule(after: retry.daemonRestartDelay)
    }

    /// On `queue`: no retry runs while the Mac sleeps.
    func systemWillSleep() {
        dispatchPrecondition(condition: .onQueue(queue))
        asleep = true
        pending?.cancel()
        pending = nil
    }

    /// On `queue`: a stream that is not running makes one attempt at once,
    /// the start of a new sequence.
    func systemDidWake() {
        dispatchPrecondition(condition: .onQueue(queue))
        asleep = false
        guard handle == nil, !paths.isEmpty else { return }
        failures = 0
        attempt()
    }
}

/// What each client's stream costs in descriptors (T-52 audit). Only
/// WatchRoot spends any: one per watched path, held while the stream lives,
/// against a soft RLIMIT_NOFILE of 256 for a Finder-launched app (Brim holds
/// about 45 otherwise).
/// - claude-sync: every account's sessions/ plus `<projects>/<slug>/memory`
///   per repo folder, 427 paths on the maintainer's Mac and growing with every repo:
///   no WatchRoot (`.claudeSync`), so 0.
/// - claude-accounts: each folder's .claude.json, sessions/, live/,
///   requests/ and the shared settings, exact files replaced all the time:
///   no WatchRoot, so 0.
/// - claude-mcp: two per account plus up to five, only while the MCP page
///   is open: WatchRoot, 17 with six accounts.
/// - agent-usage: one projects/ per account (fewer while accounts share
///   one) plus four other agents' log folders: WatchRoot, 11 at most with
///   six accounts.
extension FileEventStream.Configuration {
    /// claude-sync's stream. No WatchRoot: its path count grows with every
    /// repo folder. What WatchRoot reported is still covered: a memory/ or
    /// sessions/ folder created, renamed or removed reports an item event at
    /// its own path (ClaudeSync routes it like any event inside it), a repo
    /// folder coming or going fires the FolderEntriesWatch on projects/, and
    /// a config folder coming or going reaches the watcher as an update from
    /// the accounts service.
    static let claudeSync = FileEventStream.Configuration(latency: 0.3, watchRoot: false)
}

/// A kqueue watch on a folder's entries (one added, removed or renamed;
/// writes deeper down do not fire it) that keeps working while the folder
/// does not exist yet: it then watches the parent, and the folder appearing
/// counts as a change and moves the watch onto it. `changed` and every call
/// run on `queue`. Review fix, T-42: ClaudeSyncWatcher gave up on a config
/// folder with no projects/ yet, so one created later was never watched
/// (its sessions-only stream reports nothing there) until a full run.
final class FolderEntriesWatch {
    let path: String
    private let queue: DispatchQueue
    private let changed: () -> Void
    private var source: DispatchSourceFileSystemObject?
    /// True while the folder itself is watched, false while its parent is
    /// (or, with the parent missing too, nothing is).
    private(set) var watchingFolder = false

    var isArmed: Bool { source != nil }

    init(path: String, queue: DispatchQueue, changed: @escaping () -> Void) {
        self.path = path
        self.queue = queue
        self.changed = changed
    }

    deinit { source?.cancel() }

    /// On `queue`: (re)arms on the folder, or on its parent while it is absent.
    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        arm()
    }

    func cancel() {
        source?.cancel()
        source = nil
        watchingFolder = false
    }

    private func arm() {
        cancel()
        let descriptor = open(path, O_EVTONLY)
        if descriptor >= 0 {
            watchingFolder = true
            watch(descriptor, folder: true)
            return
        }
        let parent = open((path as NSString).deletingLastPathComponent, O_EVTONLY)
        // The parent missing too: the owner's next start() looks again.
        guard parent >= 0 else { return }
        watch(parent, folder: false)
        // Created between the two opens: no event will say so.
        if access(path, F_OK) == 0 {
            arm()
            changed()
        }
    }

    private func watch(_ descriptor: Int32, folder: Bool) {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let moved = !source.data.isDisjoint(with: [.rename, .delete])
            if folder {
                // The folder itself moved or went: watch whatever has the
                // name now, or its parent until it is back.
                if moved { self.arm() }
                self.changed()
            } else if moved {
                // The parent itself moved or went.
                self.arm()
            } else if access(self.path, F_OK) == 0 {
                // An entry of the parent came: the folder is here now.
                self.arm()
                self.changed()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }
}

/// How long a stream waits before each new registration after a failure.
struct FileEventRetryPolicy: Equatable {
    /// 10 attempts over about 5 minutes, then none until a push.
    var delays: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60, 60, 60, 60]
    /// The first attempt after fseventsd exits.
    var daemonRestartDelay: TimeInterval = 1

    static let standard = FileEventRetryPolicy()

    /// The wait before the next attempt after `n` failures in a row, nil once
    /// every attempt is spent.
    func delay(afterFailures n: Int) -> TimeInterval? {
        n >= 1 && n <= delays.count ? delays[n - 1] : nil
    }
}

/// A running registration.
protocol FileEventHandle: AnyObject {
    func stop()
    /// The id of the newest event the stream has covered (at least the id
    /// current when it started): where a replacement resumes.
    var latestEventID: FSEventStreamEventId { get }
}

protocol FileEventCancellable: AnyObject {
    func cancel()
}

/// Creates and starts the stream. Real FSEvents in the app, a fake in tests.
protocol FileEventBackend {
    /// The running stream, or why it could not be created or started.
    /// `deliver` runs on `queue`. `since`: replay from this event id (nil: from now).
    func start(paths: [String], configuration: FileEventStream.Configuration, since: FSEventStreamEventId?,
               queue: DispatchQueue, deliver: @escaping ([FileEventStream.Event]) -> Void)
        -> Result<FileEventHandle, FileEventFailure>
}

/// Why a registration failed, with what can be measured about it. FSEvents
/// gives no error: FSEventStreamCreate returns NULL (and its errno is gone by
/// then, overwritten by its own cleanup) and FSEventStreamStart returns
/// false. What can be read is the descriptor budget, which is what WatchRoot
/// spends: one descriptor per watched path, opened in this process.
struct FileEventFailure: Error, Equatable {
    enum Stage: String, Equatable {
        /// FSEventStreamCreate returned NULL.
        case create = "FSEventStreamCreate"
        /// FSEventStreamStart returned false (fseventsd refused or is starting).
        case start = "FSEventStreamStart"
    }

    var stage: Stage
    var paths: Int
    var watchRoot: Bool
    /// Descriptors open in this process when it failed, nil when unread.
    var openDescriptors: Int?
    /// The soft RLIMIT_NOFILE, nil when unread.
    var softLimit: UInt64?

    /// WatchRoot's descriptor per path does not fit under the soft limit.
    var descriptorShortfall: Bool {
        guard watchRoot, let openDescriptors, let softLimit else { return false }
        return UInt64(openDescriptors + paths) > softLimit
    }

    var message: String {
        let budget = [openDescriptors.map { "\($0) descriptors open" }, softLimit.map { "soft limit \($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
        let measured = budget.isEmpty ? "" : " (\(budget))"
        if descriptorShortfall, let openDescriptors, let softLimit {
            return "\(stage.rawValue) failed for \(paths) paths with WatchRoot, which opens one descriptor per path: "
                + "\(openDescriptors) open + \(paths) > the soft limit of \(softLimit) (RLIMIT_NOFILE, EMFILE)"
        }
        switch stage {
        case .create:
            return "FSEventStreamCreate failed for \(paths) paths\(watchRoot ? " with WatchRoot" : "")\(measured)"
        case .start:
            return "FSEventStreamStart failed for \(paths) paths\(measured): fseventsd refused the registration (it answers ETIMEDOUT while it starts)"
        }
    }

    /// A failure with this process's descriptor budget read now.
    static func measured(_ stage: Stage, paths: Int, watchRoot: Bool) -> FileEventFailure {
        FileEventFailure(stage: stage, paths: paths, watchRoot: watchRoot,
                         openDescriptors: openDescriptorCount(), softLimit: softDescriptorLimit())
    }

    /// Descriptors open in this process (PROC_PIDLISTFDS), nil when unread.
    static func openDescriptorCount() -> Int? {
        let pid = getpid()
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        // Only the count of entries the kernel wrote is read.
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<proc_fdinfo>.alignment)
        defer { buffer.deallocate() }
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        return filled > 0 ? Int(filled) / MemoryLayout<proc_fdinfo>.stride : nil
    }

    /// The soft RLIMIT_NOFILE, nil when unread.
    static func softDescriptorLimit() -> UInt64? {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return nil }
        return UInt64(limit.rlim_cur)
    }
}

/// One-shot delayed work on a queue.
struct FileEventScheduler {
    let schedule: (_ delay: TimeInterval, _ queue: DispatchQueue, _ work: @escaping () -> Void) -> FileEventCancellable

    /// Rule 1 exception: a retry after a failed registration with fseventsd.
    /// No event reports that fseventsd is ready to take a client again (it
    /// answers ETIMEDOUT while it starts), so the only way back is to ask
    /// again later. The timer is one-shot, armed only after a failure, backs
    /// off 1 s → 60 s over at most 10 attempts (FileEventRetryPolicy), and is
    /// cancelled by stop() and when the Mac goes to sleep; a wake makes one
    /// immediate attempt instead.
    static let dispatch = FileEventScheduler { delay, queue, work in
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        let token = DispatchOneShot(timer)
        timer.setEventHandler { [weak token] in
            token?.cancel()
            work()
        }
        timer.resume()
        return token
    }

    private final class DispatchOneShot: FileEventCancellable {
        private var timer: DispatchSourceTimer?
        init(_ timer: DispatchSourceTimer) { self.timer = timer }
        deinit { timer?.cancel() }
        func cancel() {
            timer?.cancel()
            timer = nil
        }
    }
}

/// The app's backend: the only FSEventStreamCreate in Brim.
struct FSEventsBackend: FileEventBackend {
    func start(paths: [String], configuration: FileEventStream.Configuration, since: FSEventStreamEventId?,
               queue: DispatchQueue, deliver: @escaping ([FileEventStream.Event]) -> Void)
        -> Result<FileEventHandle, FileEventFailure> {
        guard !paths.isEmpty else {
            return .failure(FileEventFailure(stage: .create, paths: 0, watchRoot: configuration.watchRoot))
        }
        // Read before the stream exists, so a replacement resuming from it
        // misses nothing (an event seen twice is harmless).
        let startID = since ?? FSEventsGetCurrentEventId()
        let receiver = Receiver(deliver: deliver, extended: configuration.extendedData)
        // The stream holds the receiver until it is released, so a callback
        // already queued never outlives it.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(receiver).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Receiver>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Receiver>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, _ in
            guard let info else { return }
            let receiver = Unmanaged<Receiver>.fromOpaque(info).takeUnretainedValue()
            receiver.receive(count: count, eventPaths: eventPaths, flags: flags)
        }
        var flags = kFSEventStreamCreateFlagUseCFTypes
        if configuration.fileEvents { flags |= kFSEventStreamCreateFlagFileEvents }
        if configuration.watchRoot { flags |= kFSEventStreamCreateFlagWatchRoot }
        if configuration.extendedData { flags |= kFSEventStreamCreateFlagUseExtendedData }
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                                since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                configuration.latency, FSEventStreamCreateFlags(flags)) else {
            return .failure(.measured(.create, paths: paths.count, watchRoot: configuration.watchRoot))
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return .failure(.measured(.start, paths: paths.count, watchRoot: configuration.watchRoot))
        }
        return .success(Handle(created, startID: startID))
    }

    private final class Receiver {
        let deliver: ([FileEventStream.Event]) -> Void
        let extended: Bool
        init(deliver: @escaping ([FileEventStream.Event]) -> Void, extended: Bool) {
            self.deliver = deliver
            self.extended = extended
        }

        func receive(count: Int, eventPaths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>) {
            let list = unsafeBitCast(eventPaths, to: NSArray.self)
            var events: [FileEventStream.Event] = []
            events.reserveCapacity(min(count, list.count))
            let historyDone = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
            for index in 0..<min(count, list.count) {
                // The marker a replay ends with names no change.
                if flags[index] & historyDone != 0 { continue }
                if extended, let record = list[index] as? [String: Any], let path = record["path"] as? String {
                    let inode = (record["fileID"] as? NSNumber)?.uint64Value
                    events.append(FileEventStream.Event(path: path, flags: flags[index], inode: inode))
                } else if let path = list[index] as? String {
                    events.append(FileEventStream.Event(path: path, flags: flags[index]))
                }
            }
            deliver(events)
        }
    }

    private final class Handle: FileEventHandle {
        private var stream: FSEventStreamRef?
        private var latest: FSEventStreamEventId
        init(_ stream: FSEventStreamRef, startID: FSEventStreamEventId) {
            self.stream = stream
            latest = startID
        }
        deinit { stop() }

        var latestEventID: FSEventStreamEventId {
            guard let stream else { return latest }
            // "Since now" until the first event arrives.
            let seen = FSEventStreamGetLatestEventId(stream)
            if seen != FSEventStreamEventId(kFSEventStreamEventIdSinceNow) { latest = max(latest, seen) }
            return latest
        }

        func stop() {
            guard let stream else { return }
            _ = latestEventID
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}

/// Watches fseventsd itself while any stream exists: a kqueue exit source on
/// its pid (registers without root). When it exits, every stream re-creates
/// itself, and the daemon launchd starts next is found and watched on its
/// own, whether or not a stream manages to register with it, so a later
/// restart is still seen. Nothing is spawned or signalled.
///
/// Review fix, T-42: discovery used to ride a stream's successful start
/// only. A failed lookup was never retried, and after a watched exit whose
/// re-creations all failed nothing watched the new daemon. A stream that
/// registered with a daemon that died before it was found is caught too:
/// the daemon found started after that registration, so every stream
/// re-creates itself.
///
/// The Memory module may hold its own exit source on the same process (any
/// tracked holder of 1 GB or more): that one records measured deltas, this
/// one re-creates streams. Neither is fseventsd-restart code of the other.
final class FSEventsDaemonWatch {
    static let shared = FSEventsDaemonWatch()

    /// The running daemon: its pid and kernel start time (microseconds
    /// since 1970).
    struct Daemon: Equatable {
        let pid: pid_t
        let startedAt: UInt64
    }

    /// The daemon, or nil when it is not found.
    typealias Locate = () -> Daemon?
    /// Arms an exit watch on `pid`; `exited` may run on any queue.
    typealias Arm = (_ pid: pid_t, _ exited: @escaping () -> Void) -> FileEventCancellable?

    private let queue = DispatchQueue(label: "brim.file-events.daemon", qos: .utility)
    private let locate: Locate
    private let arm: Arm
    private let scheduler: FileEventScheduler
    private let retry: FileEventRetryPolicy
    /// Wall clock in microseconds since 1970, the daemon's start time's clock.
    private let now: () -> UInt64

    // Confined to `queue`.
    private final class Entry {
        weak var stream: FileEventStream?
        init(_ stream: FileEventStream) { self.stream = stream }
    }
    private var streams: [ObjectIdentifier: Entry] = [:]
    private var watching: (pid: pid_t, source: FileEventCancellable)?
    /// The earliest stream registration made while no daemon was watched:
    /// it may have been with a daemon that is gone.
    private var unconfirmed: UInt64?
    private var discovery: FileEventCancellable?
    private var discoveryFailures = 0

    init(locate: @escaping Locate = FSEventsDaemonWatch.findDaemon, arm: @escaping Arm = FSEventsDaemonWatch.exitSource,
         scheduler: FileEventScheduler = .dispatch, retry: FileEventRetryPolicy = .standard,
         now: @escaping () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1_000_000) }) {
        self.locate = locate
        self.arm = arm
        self.scheduler = scheduler
        self.retry = retry
        self.now = now
    }

    func register(_ stream: FileEventStream) {
        let entry = Entry(stream)
        let key = ObjectIdentifier(stream)
        queue.async { [self] in
            streams[key] = entry
        }
    }

    func unregister(_ stream: FileEventStream) {
        let key = ObjectIdentifier(stream)
        queue.async { [self] in
            streams[key] = nil
            prune()
        }
    }

    /// A stream registered: the daemon is up, so its pid can be watched.
    func streamStarted() {
        let registeredAt = now()
        queue.async { [self] in
            // A daemon already watched: a restart since fires its exit source.
            guard watching == nil else { return }
            unconfirmed = min(unconfirmed ?? registeredAt, registeredAt)
            discoveryFailures = 0
            discover()
        }
    }

    /// Waits until everything queued so far ran (tests).
    func settle() { queue.sync {} }

    private func prune() {
        streams = streams.filter { $0.value.stream != nil }
        guard streams.isEmpty else { return }
        watching?.source.cancel()
        watching = nil
        discovery?.cancel()
        discovery = nil
        discoveryFailures = 0
        unconfirmed = nil
    }

    /// On `queue`: finds the daemon and watches it, or tries again on the
    /// retry policy.
    private func discover() {
        discovery?.cancel()
        discovery = nil
        guard watching == nil else { return }
        prune()
        guard !streams.isEmpty else { return }
        if let daemon = locate(),
           let source = arm(daemon.pid, { [weak self] in self?.queue.async { self?.exited(daemon.pid) } }) {
            watching = (daemon.pid, source)
            discoveryFailures = 0
            let registered = unconfirmed
            unconfirmed = nil
            // A registration older than this daemon was made with the one
            // before it, which is gone: every stream registers again.
            if let registered, daemon.startedAt > registered { restartStreams() }
            return
        }
        discoveryFailures += 1
        guard let delay = retry.delay(afterFailures: discoveryFailures) else { return }
        schedule(after: delay)
    }

    /// Rule 1 exception, the stream retry's (FileEventScheduler.dispatch):
    /// no event reports that launchd has started fseventsd again. One-shot,
    /// armed only while streams exist and no daemon is watched, backing off
    /// 1 s to 60 s over at most 10 attempts, cancelled once no stream is left.
    private func schedule(after delay: TimeInterval) {
        discovery?.cancel()
        discovery = scheduler.schedule(delay, queue) { [weak self] in self?.discover() }
    }

    private func exited(_ pid: pid_t) {
        guard let watching, watching.pid == pid else { return }
        watching.source.cancel()
        self.watching = nil
        unconfirmed = nil
        restartStreams()
        // The next daemon is watched whether or not a stream registers with it.
        discoveryFailures = 0
        schedule(after: retry.daemonRestartDelay)
    }

    private func restartStreams() {
        for entry in streams.values {
            guard let stream = entry.stream else { continue }
            stream.queue.async { stream.daemonExited() }
        }
    }

    /// fseventsd: root's process of that name, from the shared process table.
    static func findDaemon() -> Daemon? {
        for pid in ProcessTable.pids() {
            guard let record = ProcessTable.record(pid: pid) else { continue }
            if record.uid == 0, record.executableName == "fseventsd" {
                return Daemon(pid: pid, startedAt: record.startedAt)
            }
        }
        return nil
    }

    static func exitSource(pid: pid_t, exited: @escaping () -> Void) -> FileEventCancellable? {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                      queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler(handler: exited)
        source.resume()
        let token = ProcessExitToken(source)
        // A process that exited before its source was made never fires it:
        // report the exit now (the caller records the watch first, on its queue).
        if ProcessTable.record(pid: pid) == nil {
            token.cancel()
            exited()
        }
        return token
    }

    private final class ProcessExitToken: FileEventCancellable {
        private var source: DispatchSourceProcess?
        init(_ source: DispatchSourceProcess) { self.source = source }
        deinit { source?.cancel() }
        func cancel() {
            source?.cancel()
            source = nil
        }
    }
}
