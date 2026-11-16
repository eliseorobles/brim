// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import CoreServices
import Darwin
import Foundation

/// T-52: claude-sync never registered with fseventsd. WatchRoot makes the
/// FSEvents client library open one descriptor per watched path in Brim's
/// own process; claude-sync watched 427 paths (every account's sessions/ and
/// a memory/ per repo folder), and a Finder-launched app's soft
/// RLIMIT_NOFILE is 256, so FSEventStreamCreate failed with EMFILE at index
/// 285 on every try, all night. The tests ran under the shell's much higher
/// limit, so they passed.
///
/// The reproduction runs the real FSEventsBackend in a child process (this
/// test binary again, in its probe mode) that lowers its own soft limit to
/// 256 first, over claude-sync's real path layout for 430 repo folders
/// under a scratch folder. Nothing outside the scratch folder is touched,
/// and the only process signalled is that child, when it overruns.
extension FileEventStreamTests {
    static func descriptorChecks(_ suite: TestSuite) {
        suite.run("file events: the reason a registration failed") { failureReason(suite) }
        suite.run("file events: claude-sync registers under a 256 descriptor limit") { descriptorLimit(suite) }
    }

    // MARK: The reason, said

    private static func failureReason(_ suite: TestSuite) {
        // The night's numbers: 427 paths, Brim holding about 45 descriptors.
        let night = FileEventFailure(stage: .create, paths: 427, watchRoot: true, openDescriptors: 45, softLimit: 256)
        suite.expect(night.descriptorShortfall
                        && night.message == "FSEventStreamCreate failed for 427 paths with WatchRoot, which opens one descriptor per path: 45 open + 427 > the soft limit of 256 (RLIMIT_NOFILE, EMFILE)",
                     "the failure names WatchRoot's descriptor per path against the soft limit: \(night.message)")
        let fits = FileEventFailure(stage: .create, paths: 17, watchRoot: true, openDescriptors: 45, softLimit: 256)
        suite.expect(!fits.descriptorShortfall && fits.message == "FSEventStreamCreate failed for 17 paths with WatchRoot (45 descriptors open, soft limit 256)",
                     "a create that fails within budget says what was measured, nothing more: \(fits.message)")
        let refused = FileEventFailure(stage: .start, paths: 5, watchRoot: false, openDescriptors: 45, softLimit: 256)
        suite.expect(!refused.descriptorShortfall && refused.message.hasPrefix("FSEventStreamStart failed for 5 paths (45 descriptors open, soft limit 256)")
                        && refused.message.contains("ETIMEDOUT"),
                     "a refused start says fseventsd refused it: \(refused.message)")
        let unread = FileEventFailure(stage: .create, paths: 427, watchRoot: true)
        suite.expect(!unread.descriptorShortfall && unread.message == "FSEventStreamCreate failed for 427 paths with WatchRoot",
                     "an unread budget is not guessed: \(unread.message)")
        suite.expect((FileEventFailure.openDescriptorCount() ?? 0) >= 3 && (FileEventFailure.softDescriptorLimit() ?? 0) >= 256,
                     "this process's descriptors and soft limit can be read")

        // The stream keeps the reason and logs it with the first failure of a
        // sequence and when the retries are spent.
        let queue = DispatchQueue(label: "brim.tests.file-events.reason")
        let backend = FakeBackend([false, true])
        backend.failure = night
        let scheduler = FakeScheduler()
        let calls = Calls()
        let stream = makeStream(backend, scheduler, queue: queue, calls: calls)
        queue.sync { stream.watch(["/scratch/a"]) }
        suite.expect(queue.sync { stream.lastFailure } == night, "a failed registration keeps its reason")
        scheduler.fire(on: queue)
        suite.expect(queue.sync { stream.isRunning && stream.lastFailure == nil }, "a registration that succeeds clears it")
        let source = (try? String(contentsOfFile: "Sources/Brim/Services/FileEvents/FileEventStream.swift", encoding: .utf8)) ?? ""
        suite.expect(source.contains("could not register with fseventsd: \\(failure.message, privacy: .public)")
                        && source.contains("after \\(self.failures) tries: \\(failure.message, privacy: .public)"),
                     "the log line carries the reason, at the first failure and when the retries are spent")
    }

    // MARK: The reproduction, in a child under a 256 limit

    private static func descriptorLimit(_ suite: TestSuite) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-file-events-limit-\(UUID().uuidString)", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let real = ClaudeFileIO.realPath(scratch)

        // The configuration claude-sync had (WatchRoot on by default): the
        // night's failure, reproduced.
        let old = runProbe(scratch: real + "/old", configuration: "watch-root", folders: 430)
        suite.expect(old.status == 1 && old.lines.contains("soft limit 256") && old.lines.contains("paths 431")
                        && old.lines.contains { $0.hasPrefix("failed: FSEventStreamCreate failed for 431 paths with WatchRoot, which opens one descriptor per path") },
                     "with WatchRoot, 431 claude-sync paths fail under a soft limit of 256, and the reason says why: \(old)")

        // claude-sync's configuration now: it registers, and what WatchRoot
        // reported still arrives as item events at the root's own path.
        let now = runProbe(scratch: real + "/new", configuration: "claude-sync", folders: 430)
        suite.expect(FileEventStream.Configuration.claudeSync.watchRoot == false
                        && FileEventStream.Configuration.claudeSync.latency == 0.3,
                     "claude-sync's stream runs without WatchRoot, at its 0.3 s latency")
        suite.expect(now.status == 0 && now.lines.contains("soft limit 256") && now.lines.contains("paths 431")
                        && now.lines.contains("started"),
                     "claude-sync's 431 paths register under a soft limit of 256: \(now)")
        suite.expect(now.lines.contains("root events: made true, file true, renamed true"),
                     "a memory/ made after the start, a file in it and the folder renamed are all reported: \(now)")
    }

    private struct ProbeRun: CustomStringConvertible {
        var status: Int32
        var lines: [String]
        var description: String { "exit \(status): \(lines.joined(separator: " | "))" }
    }

    /// Runs this test binary in its probe mode and waits for it (30 s at
    /// most; an overrunning child is ended, the only process this signals).
    private static func runProbe(scratch: String, configuration: String, folders: Int) -> ProbeRun {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = [descriptorProbeFlag, scratch, configuration, String(folders)]
        let output = Pipe()
        child.standardOutput = output
        child.standardError = output
        let done = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in done.signal() }
        do { try child.run() } catch { return ProbeRun(status: -1, lines: ["could not start: \(error)"]) }
        // It prints a few short lines, far below a pipe's buffer, so it
        // never blocks on them before exiting.
        if done.wait(timeout: .now() + 30) == .timedOut {
            child.terminate()
            child.waitUntilExit()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        return ProbeRun(status: child.terminationStatus, lines: text.split(separator: "\n").map(String.init))
    }

    // MARK: Probe mode (the child)

    static let descriptorProbeFlag = "--file-events-descriptor-probe"

    /// `<test binary> --file-events-descriptor-probe <scratch> <claude-sync|watch-root> <repo folders>`:
    /// lowers this process's own soft RLIMIT_NOFILE to 256 (a Finder-launched
    /// app's), lays out claude-sync's paths under `<scratch>` (one config
    /// folder, its sessions/, the repo folders, every other one with a
    /// memory/), and starts the real FSEventsBackend once. Exit 0 when the
    /// stream started, 1 when it did not, 2 when the setup failed.
    static func descriptorProbe(_ arguments: [String]) -> Int32 {
        guard arguments.count == 3, let count = Int(arguments[2]), count > 0 else {
            print("usage: \(descriptorProbeFlag) <scratch> <claude-sync|watch-root> <repo folders>")
            return 2
        }
        let configuration: FileEventStream.Configuration
        switch arguments[1] {
        case "claude-sync": configuration = .claudeSync
        // What claude-sync's stream was until T-52: the default, WatchRoot on.
        case "watch-root": configuration = FileEventStream.Configuration(latency: 0.3)
        default:
            print("unknown configuration \(arguments[1])")
            return 2
        }
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 2 }
        limit.rlim_cur = min(256, limit.rlim_max)
        guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            print("setrlimit failed: errno \(errno)")
            return 2
        }
        print("soft limit \(FileEventFailure.softDescriptorLimit() ?? 0)")

        let config = arguments[0] + "/.claude-probe"
        let manager = FileManager.default
        do {
            try manager.createDirectory(atPath: config + "/sessions", withIntermediateDirectories: true)
            for index in 0..<count {
                let repo = config + "/projects/-Users-tester-Code-repo\(index)"
                try manager.createDirectory(atPath: index % 2 == 0 ? repo + "/memory" : repo, withIntermediateDirectories: true)
            }
        } catch {
            print("setup failed: \(error)")
            return 2
        }
        let folders = ClaudeSync.folders(configDirectories: [config])
        guard let folder = folders.first else {
            print("setup failed: no folder")
            return 2
        }
        let paths = ClaudeSync.watchedPaths(configDirectories: [config], folders: folders,
                                            slugs: ClaudeSync.projectSlugs(folders: folders))
        print("paths \(paths.count)")

        let queue = DispatchQueue(label: "brim.tests.file-events.probe")
        let root = folder + "/projects/-Users-tester-Code-repo1/memory"
        let seen = ProbeEvents(root: root)
        let result = FSEventsBackend().start(paths: paths, configuration: configuration, since: nil, queue: queue) {
            seen.add($0)
        }
        switch result {
        case .failure(let failure):
            print("failed: \(failure.message)")
            return 1
        case .success(let handle):
            print("started")
            defer { handle.stop() }
            // repo1 has no memory/: made after the start, a file saved in
            // it, then the folder renamed away. WatchRoot used to add a
            // RootChanged for these; the item events are what routes them.
            let made = (try? manager.createDirectory(atPath: root, withIntermediateDirectories: false)) != nil
                && manager.createFile(atPath: root + "/notes.md", contents: Data("x".utf8))
            let createdSeen = made && seen.waitFor(timeout: 5) { $0.made && $0.file }
            let moved = (try? manager.moveItem(atPath: root, toPath: root + ".old")) != nil
            let renamedSeen = moved && seen.waitFor(timeout: 5) { $0.renamed }
            let state = seen.current
            print("root events: made \(made && state.made), file \(made && state.file), renamed \(moved && state.renamed)"
                  + (createdSeen && renamedSeen ? "" : " (timed out)"))
            return 0
        }
    }

    /// The probe's events at the root it changes, signalled as they come.
    private final class ProbeEvents: @unchecked Sendable {
        struct State { var made = false, file = false, renamed = false }
        private let lock = NSCondition()
        private let root: String
        private var state = State()

        init(root: String) { self.root = root }

        var current: State {
            lock.lock()
            defer { lock.unlock() }
            return state
        }

        func add(_ events: [FileEventStream.Event]) {
            lock.lock()
            for event in events {
                let flags = Int(event.flags)
                if event.path == root, flags & kFSEventStreamEventFlagItemCreated != 0 { state.made = true }
                if event.path == root + "/notes.md" { state.file = true }
                if event.path == root, flags & kFSEventStreamEventFlagItemRenamed != 0, state.made { state.renamed = true }
            }
            lock.broadcast()
            lock.unlock()
        }

        func waitFor(timeout: TimeInterval, _ condition: (State) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            lock.lock()
            defer { lock.unlock() }
            while !condition(state) {
                if !lock.wait(until: deadline) { return condition(state) }
            }
            return true
        }
    }
}
