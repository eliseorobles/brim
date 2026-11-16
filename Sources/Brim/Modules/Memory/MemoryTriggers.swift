// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import AppKit
import Combine
import Darwin
import Foundation
import os.log

/// The Memory module's push feeds besides pressure and workspace events:
/// - a kqueue watch on /System/Volumes/VM, which fires when macOS creates or
///   removes a swapfile;
/// - SystemMonitor's snapshots, only while SystemMonitor already samples
///   memory for the panel, notch or menu bar (subscribing starts nothing);
/// - one long-lived `log stream` child, filtered to fseventsd's "table has
///   grown too large" and "SLOWDOWN" lines: supporting evidence only, which
///   never notifies by itself.
///
/// No timer (code rule 1): a revoked watch and a stopped log child are
/// re-armed from `ensureArmed`, which every scan calls, so recovery rides
/// events the module already has.
///
/// Admitted gap: push signals miss swap filling existing swapfiles, and the
/// log line may never appear. From a fully healthy state the first
/// detection waits for the next event (a launch, an unlock, the panel
/// opening, a pressure change). At the incident's 1.46 GB/h, fseventsd
/// crosses 1 GB about 40 minutes after onset; on this Mac those events come
/// many times an hour. Once something is elevated, MemoryService's one-shot
/// follow-up covers the rest.
@MainActor
final class MemoryTriggers {
    nonisolated private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brim", category: "memory")
    nonisolated static let swapFolder = "/System/Volumes/VM"
    nonisolated static let logTool = "/usr/bin/log"

    private let onSwapChange: () -> Void
    private let onDaemonLog: (MemoryDaemonLogEvent) -> Void
    private let onMonitorReading: (_ swapUsed: UInt64?, _ compressed: UInt64?) -> Void
    private let queue = DispatchQueue(label: "brim.memory.triggers", qos: .utility)

    private var running = false
    private var swapSource: DispatchSourceFileSystemObject?
    private var monitorSubscription: AnyCancellable?
    private var terminateObserver: NSObjectProtocol?
    private var logChild: LogChild?
    private var logBackoff = MemoryRestartBackoff()

    /// The running log child, for the scan cost line (its CPU is readable:
    /// it is this app's own child).
    var logChildPID: pid_t? { logChild?.identity.pid }

    init(onSwapChange: @escaping () -> Void, onDaemonLog: @escaping (MemoryDaemonLogEvent) -> Void,
         onMonitorReading: @escaping (_ swapUsed: UInt64?, _ compressed: UInt64?) -> Void) {
        self.onSwapChange = onSwapChange
        self.onDaemonLog = onDaemonLog
        self.onMonitorReading = onMonitorReading
    }

    func start() {
        guard !running else { return }
        running = true
        endLeftoverLogChild()
        armSwapWatch()
        monitorSubscription = SystemMonitor.shared.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                MainActor.assumeIsolated { self?.onMonitorReading(snapshot.memorySwapUsed, snapshot.memoryCompressed) }
            }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        ensureArmed(now: ProcessInfo.processInfo.systemUptime)
    }

    func stop() {
        guard running else { return }
        running = false
        swapSource?.cancel()
        swapSource = nil
        monitorSubscription = nil
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
        endLogChild()
    }

    /// Called at every scan start: re-arms a revoked swap watch, restarts the log child when it is
    /// due (no timer), so recovery rides events the module already has.
    func ensureArmed(now: TimeInterval) {
        guard running else { return }
        if swapSource == nil { armSwapWatch() }
        if logChild == nil, logBackoff.mayStart(at: now) { startLogChild(now: now) }
    }

    // MARK: Swapfile watch

    private func armSwapWatch() {
        let descriptor = open(Self.swapFolder, O_EVTONLY)
        guard descriptor >= 0 else {
            Self.logger.notice("memory: could not watch \(Self.swapFolder, privacy: .public): errno \(errno)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .link, .rename, .delete, .revoke],
                                                               queue: queue)
        source.setEventHandler { [weak self, weak source] in
            let events = source?.data ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if events.contains(.delete) || events.contains(.revoke) || events.contains(.rename) {
                        // The folder went away or was replaced: ensureArmed
                        // opens it again at the next scan.
                        self.swapSource?.cancel()
                        self.swapSource = nil
                    }
                    self.onSwapChange()
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        swapSource = source
    }

    // MARK: fseventsd log child

    private struct LogChild {
        let identity: ProcessIdentity
        let exitSource: DispatchSourceProcess
        let readSource: DispatchSourceRead
    }

    /// The child's output not yet split into lines; touched only on `queue`.
    private final class LineBuffer {
        var pending = Data()
    }

    /// A child an earlier Brim recorded and did not end (it crashed): ended
    /// when it is still that child, `/usr/bin/log`, adopted by launchd.
    private func endLeftoverLogChild() {
        let recorded = MemoryNotifications.identity(fromKey: UserDefaults.standard.string(forKey: DefaultsKey.memoryLogChild))
        UserDefaults.standard.removeObject(forKey: DefaultsKey.memoryLogChild)
        guard let recorded else { return }
        queue.async {
            guard MemoryRules.shouldEndLeftoverLogChild(recorded: recorded, current: ProcessTable.record(pid: recorded.pid))
            else { return }
            _ = KillProcessService.signalVerified([recorded], force: false)
            Self.logger.notice("memory: ended a log stream child an earlier run left (pid \(recorded.pid))")
        }
    }

    private func startLogChild(now: TimeInterval) {
        var pipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe) == 0 else { return }
        let readEnd = pipe[0]
        let writeEnd = pipe[1]
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group, and none of this app's other descriptors.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let words = [Self.logTool, "stream", "--style", "ndjson", "--predicate", MemoryRules.daemonLogPredicate]
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { for argument in argv { free(argument) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, Self.logTool, &actions, &attributes, argv, environ)
        close(writeEnd)
        // A spawned child is owned from here: its exit source reaps it and
        // endLogChild ends it, even when bsdinfo can't be read (a child that
        // already exited is a zombie, which bsdinfo refuses).
        guard status == 0, let identity = MemoryRules.spawnedChildIdentity(
            pid: pid, bsdStart: ProcessTable.startTime(pid: pid), kernelStart: ProcessTable.kernelStartTime(pid: pid))
        else {
            close(readEnd)
            // No such process in the kernel at all: nothing left to own.
            if status == 0 { _ = waitpid(pid, nil, WNOHANG) }
            logBackoff.started(at: now)
            logBackoff.exited(at: now)
            Self.logger.notice("memory: could not start log stream (status \(status))")
            return
        }
        UserDefaults.standard.set(MemoryNotifications.leakKey(identity), forKey: DefaultsKey.memoryLogChild)
        logBackoff.started(at: now)

        let lines = LineBuffer()
        let readSource = DispatchSource.makeReadSource(fileDescriptor: readEnd, queue: queue)
        readSource.setEventHandler { [weak self, weak readSource] in
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = read(readEnd, &buffer, buffer.count)
            guard count > 0 else {
                readSource?.cancel()
                return
            }
            lines.pending.append(contentsOf: buffer.prefix(count))
            var events: [MemoryDaemonLogEvent] = []
            while let newline = lines.pending.firstIndex(of: 0x0A) {
                let line = String(decoding: lines.pending[lines.pending.startIndex..<newline], as: UTF8.self)
                lines.pending.removeSubrange(lines.pending.startIndex...newline)
                if let event = MemoryRules.daemonLogEvent(ndjsonLine: line) { events.append(event) }
            }
            // A runaway line without a newline is never kept whole.
            if lines.pending.count > 1 << 20 { lines.pending.removeAll() }
            guard !events.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { for event in events { self?.onDaemonLog(event) } }
            }
        }
        readSource.setCancelHandler { close(readEnd) }
        readSource.resume()

        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exitSource.setEventHandler { [weak self] in
            // Our own child: reap it so it leaves no zombie.
            _ = waitpid(pid, nil, 0)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.logChildExited(identity) }
            }
        }
        exitSource.resume()
        logChild = LogChild(identity: identity, exitSource: exitSource, readSource: readSource)
        // One that exited before its source was armed may raise no event:
        // a zombie (bsdinfo refused) is reaped now. A running child returns 0
        // here and stays with its exit source.
        if ProcessTable.startTime(pid: pid) == nil, waitpid(pid, nil, WNOHANG) == pid { logChildExited(identity) }
    }

    private func logChildExited(_ identity: ProcessIdentity) {
        guard let child = logChild, child.identity == identity else { return }
        child.exitSource.cancel()
        child.readSource.cancel()
        logChild = nil
        UserDefaults.standard.removeObject(forKey: DefaultsKey.memoryLogChild)
        logBackoff.exited(at: ProcessInfo.processInfo.systemUptime)
        Self.logger.notice("memory: log stream ended; restarts at a later scan")
    }

    /// Ends this app's own child, identity checked, and forgets it.
    private func endLogChild() {
        guard let child = logChild else { return }
        logChild = nil
        child.readSource.cancel()
        child.exitSource.cancel()
        let identity = child.identity
        let results = KillProcessService.signalVerified([identity], force: false)
        // Reaped off the triggers queue, so a slow exit never holds up events.
        if results[identity.pid] == .sent {
            DispatchQueue.global(qos: .utility).async { _ = waitpid(identity.pid, nil, 0) }
        } else if results[identity.pid] == .gone {
            // Gone already: a zombie of ours (bsdinfo refuses it, and its
            // exit source is cancelled) is reaped now. A reused pid reads
            // as stale and is never waited on.
            _ = waitpid(identity.pid, nil, WNOHANG)
        }
        UserDefaults.standard.removeObject(forKey: DefaultsKey.memoryLogChild)
        logBackoff = MemoryRestartBackoff()
    }
}
