// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// A Claude Code process that holds a conversation open: from its
/// sessions/<pid>.json, or from the sync's check-out record once that file is
/// gone while the process still runs (ClaudeSync).
struct ClaudeHolder: Equatable {
    var sessionId: String
    var pid: Int32
    var startedAt: Date?
    /// The config folder it runs on (the account).
    var configDirectory: String
}

/// Conversations held open by another process (T-50). `cx` and `claude
/// -r/-c/--resume` never continue an older conversation in place of one that
/// is still open: brim-claude names the process (account, tab, why it waits)
/// and waits on its exit (a kqueue process-exit source, never a poll), then
/// continues. Ctrl-C cancels the wait.
enum ClaudeHeldOpen {
    /// How a wait on a holder's exit ended.
    enum Outcome: Equatable {
        case exited
        case cancelled
    }

    /// Every conversation a process holds open now, by session id: the pid
    /// files of `configDirectories`, then the check-outs the sync recorded
    /// at `statePath` (a process whose pid file is gone already while it
    /// still writes its last rows).
    static func holders(configDirectories: [String], statePath: String,
                        isAlive: @escaping ClaudeProcessProbe) -> [String: ClaudeHolder] {
        var holders: [String: ClaudeHolder] = [:]
        for directory in configDirectories {
            for session in ClaudeSessionIndex.liveSessions(configDirectory: directory, isAlive: isAlive)
            where holders[session.sessionId] == nil {
                holders[session.sessionId] = ClaudeHolder(sessionId: session.sessionId, pid: session.pid,
                                                          startedAt: session.startedAt, configDirectory: directory)
            }
        }
        for (id, open) in ClaudeSync.openCheckouts(statePath: statePath, isAlive: isAlive) where holders[id] == nil {
            holders[id] = ClaudeHolder(sessionId: id, pid: open.pid, startedAt: open.started, configDirectory: open.config)
        }
        return holders
    }

    // MARK: Why it is open

    /// How much of a transcript's end is read for its last entries.
    static let tailBytes = 256 << 10

    /// Whether the conversation's newest copy ends paused at a usage limit:
    /// Claude Code waits in the open session ("Usage limit reached ·
    /// continuing automatically at 1:30am · esc to cancel", a system entry,
    /// 2.1.325; earlier versions wrote an API-error assistant entry).
    static func pausedAtUsageLimit(sessionId: String, cwd: String?, configDirectories: [String]) -> Bool {
        guard let transcript = ClaudeSessionIndex.transcript(sessionId: sessionId, cwd: cwd, configDirectories: configDirectories),
              let tail = tail(transcript.path) else { return false }
        return pausedAtUsageLimit(tail: tail)
    }

    /// The same, from the end of a transcript: walking back from the last
    /// entry to the last turn (a user prompt or an assistant entry), a
    /// usage-limit notice on the way means the session waits on it. Its
    /// first line is taken as cut off (a read from the middle of the file)
    /// unless `tail` starts with a newline.
    static func pausedAtUsageLimit(tail: Data) -> Bool {
        let lines = tail.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).dropFirst()
        for line in lines.reversed() where !line.isEmpty {
            guard let json = ClaudeJSON.parse(Data(line)) as? [String: Any] else { continue }
            switch json["type"] as? String {
            case "system":
                if mentionsLimit(json["content"]) { return true }
            case "assistant":
                let message = json["message"] as? [String: Any]
                return json["isApiErrorMessage"] as? Bool == true && mentionsLimit(message?["content"])
            case "user":
                if json["isMeta"] as? Bool == true { continue }
                return false
            default:
                continue
            }
        }
        return false
    }

    private static func mentionsLimit(_ content: Any?) -> Bool {
        let text: String
        if let string = content as? String {
            text = string
        } else if let parts = content as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        } else {
            return false
        }
        return text.range(of: "limit reached", options: .caseInsensitive) != nil
    }

    /// The last `tailBytes` of a file, or the whole file when shorter, then
    /// after a newline, so its first line counts.
    private static func tail(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return start == 0 ? Data("\n".utf8) + data : data
    }

    // MARK: The process

    /// The terminal the process runs in, as `ps` names it ("ttys012"); nil
    /// without one.
    static func terminal(pid: Int32) -> String? {
        guard let info = processInfo(pid) else { return nil }
        let device = info.kp_eproc.e_tdev
        guard device != -1, let name = devname(device, mode_t(S_IFCHR)) else { return nil }
        let text = String(cString: name)
        return text.isEmpty || text == "??" ? nil : text
    }

    /// Whether `pid` is this process or one it runs under (the Claude Code
    /// session whose Bash tool ran cx): waiting on it would never end.
    static func isSelfOrAncestor(_ pid: Int32) -> Bool {
        var current = getpid()
        for _ in 0..<64 {
            if current == pid { return true }
            guard current > 1, let parent = processInfo(current)?.kp_eproc.e_ppid, parent != current else { return false }
            current = parent
        }
        return false
    }

    private static func processInfo(_ pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    // MARK: Waiting

    /// Blocks until the holder's process exits (a kqueue process-exit source
    /// the kernel fires; nothing polls) or `interrupt` arrives (Ctrl-C, read
    /// through a signal source). Both sources are registered with the kernel
    /// (their registration handlers ran) before SIGINT is ignored; until then
    /// Ctrl-C keeps its default and ends brim-claude, so the shell starts
    /// nothing, and from then on the signal source records it. Ignoring it
    /// first dropped a Ctrl-C that came before the source listened, and the
    /// wait went on. `armed` runs at once after SIGINT is ignored (tests raise
    /// the interrupt there, the moment the old order lost it). A process that
    /// exited before the exit source listened never fires it, so the probe
    /// looks once after arming.
    static func waitForExit(_ holder: ClaudeHolder, interrupt: Int32 = SIGINT, armed: () -> Void = {},
                            isAlive: ClaudeProcessProbe = ClaudeSessionIndex.processIsAlive) -> Outcome {
        let queue = DispatchQueue(label: "brim-claude.wait-for-exit")
        let done = DispatchSemaphore(value: 0)
        let registered = DispatchSemaphore(value: 0)
        var cancelled = false
        let exit = DispatchSource.makeProcessSource(identifier: holder.pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { done.signal() }
        exit.setRegistrationHandler { registered.signal() }
        let cancel = DispatchSource.makeSignalSource(signal: interrupt, queue: queue)
        cancel.setEventHandler {
            cancelled = true
            done.signal()
        }
        cancel.setRegistrationHandler { registered.signal() }
        exit.resume()
        cancel.resume()
        registered.wait()
        registered.wait()
        let previous = signal(interrupt, SIG_IGN)
        defer {
            exit.cancel()
            cancel.cancel()
            signal(interrupt, previous)
        }
        armed()
        if !isAlive(holder.pid, holder.startedAt) { return queue.sync { cancelled } ? .cancelled : .exited }
        done.wait()
        return queue.sync { cancelled } ? .cancelled : .exited
    }
}

/// A conversation the sync holds out of view because a process keeps it
/// open on one account, as the menu shows it (T-50: Claude Code's /resume on
/// the other accounts cannot list it, so the menu says where it is).
struct ClaudeHeldConversation: Equatable, Identifiable {
    /// The session id.
    var id: String
    /// The account it is open on.
    var account: String
    /// Its transcript ends paused at a usage limit.
    var paused: Bool

    var shortId: String { ClaudeSync.shortId(id) }

    /// The sync's open check-outs (ClaudeSync.Report.open), in words: the
    /// account each runs on and whether it waits at a usage limit. Reads the
    /// end of each transcript, so callers run it off the main thread.
    static func describe(_ open: [String: ClaudeSync.Open], accounts: [ClaudeAccount], home: String) -> [ClaudeHeldConversation] {
        let configDirectories = ClaudeAccount.configDirectories(home: home, accounts: accounts)
        return open.keys.sorted().compactMap { id in
            guard let holder = open[id] else { return nil }
            let config = ClaudeFileIO.realPath(holder.config)
            let account = accounts.first { ClaudeFileIO.realPath($0.configDirectory(home: home)) == config }
            return ClaudeHeldConversation(id: id, account: ClaudeHelper.displayLabel(account, folder: account?.folder ?? holder.config),
                                          paused: ClaudeHeldOpen.pausedAtUsageLimit(sessionId: id, cwd: nil,
                                                                                    configDirectories: configDirectories))
        }
    }
}
