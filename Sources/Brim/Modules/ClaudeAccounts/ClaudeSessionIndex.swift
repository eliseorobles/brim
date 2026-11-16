// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// A Claude Code session that is running now, from <config>/sessions/<pid>.json.
struct ClaudeLiveSession: Equatable {
    var pid: Int32
    var sessionId: String
    var cwd: String?
    /// "busy" or "idle".
    var status: String?
    /// "interactive", or another kind of run.
    var kind: String?
    /// No later than the process started, as its pid file tells: the file's
    /// startedAt, else the file's modification time (the process wrote the
    /// file, so it ran by then). A process that started after it is another
    /// program that reuses the pid (processIsAlive).
    var startedAt: Date?
    /// The Claude Code config folder the session runs on (~/.claude for the
    /// default account).
    var configDirectory: String
}

/// A conversation's transcript, <config>/projects/<cwd slug>/<session id>.jsonl.
struct ClaudeTranscript: Equatable {
    var sessionId: String
    var path: String
    var modified: Date
    /// The config folder it was found under.
    var configDirectory: String
}

/// The probe that tells whether a session's process still runs; tests pass
/// their own.
typealias ClaudeProcessProbe = (_ pid: Int32, _ startedAt: Date?) -> Bool

enum ClaudeSessionIndex {
    /// Claude Code's config folder for an account: ~/.claude for the default
    /// account (its global config, ~/.claude.json, sits outside it).
    static func configDirectory(forFolder folder: String, home: String) -> String {
        folder.isEmpty ? home + "/.claude" : folder
    }

    // MARK: Live sessions

    /// The sessions whose process runs, from <configDirectory>/sessions/*.json.
    static func liveSessions(configDirectory: String,
                             isAlive: ClaudeProcessProbe = processIsAlive) -> [ClaudeLiveSession] {
        let folder = configDirectory + "/sessions"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        var sessions: [ClaudeLiveSession] = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            guard let data = ClaudeFileIO.read(folder + "/" + name, limit: 1 << 20),
                  let json = ClaudeJSON.parse(data) as? [String: Any],
                  let sessionId = ClaudeJSON.string(json["sessionId"]) else { continue }
            let pidNumber = ClaudeJSON.number(json["pid"]) ?? Double(name.prefix { $0.isNumber }) ?? 0
            guard pidNumber > 0, pidNumber < Double(Int32.max) else { continue }
            let pid = Int32(pidNumber)
            let started = ClaudeJSON.number(json["startedAt"]).map { Date(timeIntervalSince1970: $0 / 1_000) }
                ?? ClaudeFileIO.modificationDate(folder + "/" + name)
            guard isAlive(pid, started) else { continue }
            sessions.append(ClaudeLiveSession(pid: pid, sessionId: sessionId, cwd: ClaudeJSON.string(json["cwd"]),
                                              status: ClaudeJSON.string(json["status"]),
                                              kind: ClaudeJSON.string(json["kind"]), startedAt: started,
                                              configDirectory: configDirectory))
        }
        return sessions
    }

    /// A running session in words, for the person to find it: "pid 4242 in
    /// /Users/x/Code/App (busy)".
    static func describe(_ session: ClaudeLiveSession) -> String {
        "pid \(session.pid)" + (session.cwd.map { " in \($0)" } ?? "") + (session.status.map { " (\($0))" } ?? "")
    }

    /// How much later than `startedAt` a process may seem to have started
    /// and still be the one that registered: Claude Code writes startedAt
    /// after its process starts (0.4 to 2 s after, measured 2026-11-14), so
    /// the slack covers only clock rounding and small clock corrections.
    static let startSlack: TimeInterval = 5

    /// Whether the process runs: kill(pid, 0) succeeds, or fails only for
    /// lack of permission. A process that started after the session
    /// registered (`startedAt`, plus startSlack) is another program that
    /// reuses the number, as after a crash that left its pid file behind.
    static func processIsAlive(_ pid: Int32, startedAt: Date?) -> Bool {
        guard pid > 0 else { return false }
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        if let startedAt, let processStart = processStartTime(pid),
           processStart.timeIntervalSince(startedAt) > startSlack {
            return false
        }
        return true
    }

    static func processStartTime(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    // MARK: Transcripts

    /// Claude Code's folder name for a working directory under projects/:
    /// every UTF-16 unit that is not an ASCII letter or digit becomes "-";
    /// a name longer than 200 is cut there and given "-" and a base-36 hash.
    static func projectSlug(_ path: String) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(path.utf16.count)
        for unit in path.utf16 {
            let ascii = (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5a) || (unit >= 0x61 && unit <= 0x7a)
            units.append(ascii ? unit : 0x2d)
        }
        let slug = String(decoding: units, as: UTF16.self)
        guard units.count > 200 else { return slug }
        return String(decoding: units.prefix(200), as: UTF16.self) + "-" + String(abs(Int64(javaHash(path))), radix: 36)
    }

    /// `(h << 5) - h + unit`, 32-bit, over the UTF-16 units.
    static func javaHash(_ text: String) -> Int32 {
        var hash: Int32 = 0
        for unit in text.utf16 { hash = (hash &<< 5) &- hash &+ Int32(unit) }
        return hash
    }

    /// The transcript folders a working directory can have: as given and with
    /// its symlinks resolved.
    static func transcriptFolders(configDirectory: String, cwd: String) -> [String] {
        var seen: [String] = []
        for path in [cwd, ClaudeFileIO.realPath(cwd)] {
            let folder = configDirectory + "/projects/" + projectSlug(path)
            if !seen.contains(folder) { seen.append(folder) }
        }
        return seen
    }

    /// A string Claude Code could have named a transcript after.
    static func isSessionId(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 128
            && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    /// Every conversation for `cwd` in the given config folders, newest
    /// first, each once. A projects/ folder shared by several accounts is
    /// read once; a conversation that several folders hold (ClaudeSync keeps
    /// a copy in each) is listed by its longest copy (then the newest, then
    /// the first found): copies are the same append-only transcript, so the
    /// longest holds the most.
    static func transcripts(cwd: String, configDirectories: [String]) -> [ClaudeTranscript] {
        var seenFolders = Set<String>()
        var copies: [String: [ClaudeTranscript]] = [:]
        var order: [String] = []
        for configDirectory in configDirectories {
            for folder in transcriptFolders(configDirectory: configDirectory, cwd: cwd) {
                let real = ClaudeFileIO.realPath(folder)
                guard seenFolders.insert(real).inserted else { continue }
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
                for name in names where name.hasSuffix(".jsonl") {
                    let id = String(name.dropLast(6))
                    let path = folder + "/" + name
                    guard isSessionId(id), ClaudeFileIO.isRegularFile(path),
                          let modified = ClaudeFileIO.modificationDate(path) else { continue }
                    if copies[id] == nil { order.append(id) }
                    copies[id, default: []].append(ClaudeTranscript(sessionId: id, path: path, modified: modified,
                                                                    configDirectory: configDirectory))
                }
            }
        }
        return order.compactMap { copies[$0].flatMap(longest) }.sorted { $0.modified > $1.modified }
    }

    /// The transcript of one session: under `cwd`'s folder first, then in any
    /// project folder of the given config folders; of several copies, the
    /// longest.
    static func transcript(sessionId: String, cwd: String?, configDirectories: [String]) -> ClaudeTranscript? {
        guard isSessionId(sessionId) else { return nil }
        if let cwd, let hit = transcripts(cwd: cwd, configDirectories: configDirectories)
            .first(where: { $0.sessionId == sessionId }) {
            return hit
        }
        var found: [ClaudeTranscript] = []
        var seen = Set<String>()
        for configDirectory in configDirectories {
            let projects = configDirectory + "/projects"
            let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? []
            for folder in folders.sorted() {
                let path = projects + "/" + folder + "/" + sessionId + ".jsonl"
                if ClaudeFileIO.isRegularFile(path), let modified = ClaudeFileIO.modificationDate(path),
                   seen.insert(ClaudeFileIO.realPath(path)).inserted {
                    found.append(ClaudeTranscript(sessionId: sessionId, path: path, modified: modified,
                                                  configDirectory: configDirectory))
                }
            }
        }
        return longest(found)
    }

    /// Of one conversation's copies: the longest, then the newest, then the
    /// first found.
    static func longest(_ copies: [ClaudeTranscript]) -> ClaudeTranscript? {
        let sized = copies.map { ($0, ClaudeFileCopy.size($0.path) ?? -1) }
        return sized.enumerated().max { a, b in
            if a.element.1 != b.element.1 { return a.element.1 < b.element.1 }
            if a.element.0.modified != b.element.0.modified { return a.element.0.modified < b.element.0.modified }
            return a.offset > b.offset
        }?.element.0
    }

    /// The folder name under projects/ a transcript sits in.
    static func slug(of transcript: ClaudeTranscript) -> String {
        ((transcript.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }
}

/// <state>/sessions/<session id>.json: the account folder each session ran
/// on last, as its status line (`brim-claude statusline`, which runs inside
/// the session with its CLAUDE_CONFIG_DIR) reported it. `move` reads it to
/// tell which account a conversation belongs to. The transcript cannot tell:
/// a fork copies the original account's `session-owner` records and adds
/// none for the account it runs on (verified with Claude Code 2.1.322 on
/// 2026-11-12). Written only when the folder is new for the session.
enum ClaudeSessionOwners {
    /// Records older than this are removed whenever a new one is written.
    static let kept: TimeInterval = 60 * 86_400

    /// The folder ("" for the default account) the session last ran on, or
    /// nil when no status line of it reached Brim.
    static func folder(sessionId: String, paths: ClaudeAccountsPaths) -> String? {
        guard ClaudeSessionIndex.isSessionId(sessionId),
              let data = ClaudeFileIO.read(paths.sessionFile(sessionId), limit: 64 << 10),
              let json = ClaudeJSON.parse(data) as? [String: Any] else { return nil }
        return json["folder"] as? String
    }

    /// Records that the session runs on `folder`, unless that is what the
    /// record already says; returns whether it wrote. Adding a record also
    /// removes those older than `kept`.
    @discardableResult
    static func record(sessionId: String, folder: String, paths: ClaudeAccountsPaths, now: Date) -> Bool {
        guard ClaudeSessionIndex.isSessionId(sessionId), Self.folder(sessionId: sessionId, paths: paths) != folder else {
            return false
        }
        let body: [String: Any] = ["session_id": sessionId, "folder": folder,
                                   "key": ClaudeAccountKey.key(forFolder: folder), "observed_at": ClaudeDate.format(now)]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return false }
        let path = paths.sessionFile(sessionId)
        let added = !ClaudeFileIO.exists(path)
        do {
            try paths.ensureDirectory(paths.sessionsDirectory)
            try ClaudeFileIO.writeAtomically(data, to: path)
        } catch {
            return false
        }
        if added { prune(paths, now: now) }
        return true
    }

    /// Removes records not written for `kept`.
    static func prune(_ paths: ClaudeAccountsPaths, now: Date) {
        let directory = paths.sessionsDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = directory + "/" + name
            if let modified = ClaudeFileIO.modificationDate(path), now.timeIntervalSince(modified) > kept { unlink(path) }
        }
    }
}
