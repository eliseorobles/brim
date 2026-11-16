// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// What giving one entry its own folder did, in words; `failed` when the
/// folder is its own but part of the record could not be written.
struct ClaudeOwnFolderResult: Equatable {
    var line: String
    var failed = false
}

/// Why an entry was not given its own folder, beyond a plain failure.
enum ClaudeOwnFolderFailure: Error, Equatable {
    /// Claude Code sessions started on the folder after the review; nothing
    /// was changed (with anything the roll back could not put back).
    case sessionsStarted(Int, [String])
    /// It failed before the swap or the swap failed; the link is in place.
    case stillLinked(String)
}

/// Each account keeps its own conversation folders (ticket T-38).
/// Claude Code checks every spelling of a path a tool touches, and its own
/// allowed roots (the session's folder, plans, auto memory, workflow scripts)
/// are plain prefixes of CLAUDE_CONFIG_DIR. Through a projects/ linked to
/// ~/.claude/projects, every landing is outside them and under a ".claude"
/// folder, which its sensitive-file guard refuses: workflows could not be
/// resumed, memory and plan writes asked the person. So projects/,
/// file-history/, plans/ and tasks/ are each account's own real folders, and
/// ClaudeSync keeps every conversation, plan and repo's memory in all of
/// them, so /resume lists everything on every account.
///
/// A folder Brim linked earlier (its .pre-brim/brim-share.json records the
/// entry, and the entry is still that link) is given its own: the new folder
/// is built beside the link (.<name>.brim-new, mode 0700), from the folder's
/// own pre-Brim copy when .pre-brim holds one (already merged into ~/.claude
/// when it was linked) or empty. The memory folders that copy holds move to
/// .pre-brim/memory-before-own-folders first: the shared memory replaces
/// them, and their files deleted since would otherwise come back. Then the
/// link and the new folder trade places in one atomic rename
/// (renamex_np RENAME_SWAP), so the entry is never missing, and the link,
/// now beside it, goes; a swap that fails changes nothing. The swap holds
/// the sync's lock, so no sync runs while it happens. The manifest drops the
/// entry and notes what was done. Nothing in ~/.claude is changed.
/// ClaudeSetupSharing runs the full sync right after.
///
/// A session that starts on the folder while this runs would write half its
/// conversation through the link and half into the new folder. So the run
/// holds the folder's migration lock (lockPath), which `brim-claude` waits
/// on before it starts or moves a conversation onto the folder, and checks
/// for live sessions again right before the swap.
enum ClaudeOwnFolders {
    /// The conversation entries, never linked.
    static let entries = ["projects", "file-history", "plans", "tasks"]
    static let stagingSuffix = ".brim-new"
    /// Under .pre-brim: memory folders the pre-Brim copy held before the
    /// shared memory replaced them.
    static let memoryAside = "memory-before-own-folders"

    static func staging(folder: String, name: String) -> String { folder + "/." + name + stagingSuffix }

    // MARK: Migration lock

    /// <state>/own-folders/<key of the folder's real path>.lock: held
    /// (exclusive) while Brim gives the folder its own folders.
    static func lockPath(folder: String, paths: ClaudeAccountsPaths) -> String {
        paths.stateDirectory + "/own-folders/" + ClaudeAccountKey.key(forFolder: ClaudeFileIO.realPath(folder)) + ".lock"
    }

    /// Takes the folder's migration lock, waiting for another run to end;
    /// -1 when the lock file cannot be made (the live-session checks still
    /// hold).
    static func lock(folder: String, paths: ClaudeAccountsPaths) -> Int32 {
        let path = lockPath(folder: folder, paths: paths)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return -1 }
        flock(descriptor, LOCK_EX)
        return descriptor
    }

    static func unlock(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// Whether Brim is giving `folder` its own folders right now; when it
    /// is, says so (`note`) and waits for it to finish (`wait`, a blocking
    /// shared flock: the kernel wakes it, nothing polls). Returns whether it
    /// waited.
    @discardableResult
    static func waitWhileMigrating(folder: String, paths: ClaudeAccountsPaths, note: () -> Void,
                                   wait: (Int32) -> Void = { _ = flock($0, LOCK_SH) }) -> Bool {
        guard !folder.isEmpty else { return false }
        let descriptor = open(lockPath(folder: folder, paths: paths), O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        guard errno == EWOULDBLOCK else { return false }
        note()
        wait(descriptor)
        flock(descriptor, LOCK_UN)
        return true
    }

    /// The manifest entry for `name` when the folder's entry still is the
    /// link Brim made; nil otherwise (already its own, or not Brim's).
    static func linkedEntry(folder: String, name: String) -> ClaudeShareManifest.Entry? {
        guard let entry = ClaudeShareManifest.load(folder: folder)?.entries.last(where: { $0.name == name }) else { return nil }
        let own = folder + "/" + name
        return ClaudeFileIO.isSymlink(own) && ClaudeSetupSharing.isLink(own, to: entry.linkedTo) ? entry : nil
    }

    /// Whether any conversation entry of the folder is still Brim's link.
    static func needsOwnFolders(_ folder: String) -> Bool {
        entries.contains { linkedEntry(folder: folder, name: $0) != nil }
    }

    /// The plan for one entry: nil when it is not Brim's link; `resumes`
    /// when a run that stopped part way left the new folder beside it.
    static func plan(folder: String, name: String) -> (entry: ClaudeShareManifest.Entry, resumes: Bool)? {
        guard let entry = linkedEntry(folder: folder, name: name) else { return nil }
        return (entry, ClaudeFileIO.isDirectory(staging(folder: folder, name: name)))
    }

    // MARK: Execute

    /// Gives `folder` its own `name`. The caller holds the folder's
    /// migration lock and checked that no session ran on the folder; this
    /// checks again right before the swap. A new folder left by a run that
    /// stopped part way is picked up as it is. Returns what was done, in
    /// words; throws ClaudeOwnFolderFailure. `statePath` is the sync's state
    /// (ClaudeSync.lock); `swap` trades the new folder and the link (tests
    /// watch it, or make it fail).
    static func perform(folder: String, name: String, now: Date, statePath: String,
                        isAlive: ClaudeProcessProbe = ClaudeSessionIndex.processIsAlive,
                        swap: (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_SWAP)) }) throws -> ClaudeOwnFolderResult {
        guard let entry = linkedEntry(folder: folder, name: name) else {
            throw ClaudeOwnFolderFailure.stillLinked("\(folder)/\(name) is not Brim's link")
        }
        let own = folder + "/" + name
        let staging = staging(folder: folder, name: name)
        let preBrim = folder + "/" + ClaudeSetupSharing.preBrimFolder
        var base: String?
        /// This run made the new folder empty: a roll back removes it.
        var made = false
        let resumed = ClaudeFileIO.exists(staging)
        if resumed {
            guard ClaudeFileIO.isDirectory(staging) else {
                throw ClaudeOwnFolderFailure.stillLinked("\(staging) is in the way and is not a folder")
            }
            // The earlier run started from the pre-Brim copy when that copy
            // is no longer in .pre-brim: it is this folder.
            if let stored = entry.storedAs, !ClaudeFileIO.exists(preBrim + "/" + stored) { base = stored }
        } else if let stored = entry.storedAs, ClaudeFileIO.isDirectory(preBrim + "/" + stored) {
            guard rename(preBrim + "/" + stored, staging) == 0 else {
                throw ClaudeOwnFolderFailure.stillLinked(ClaudeFileError.posix("move \(preBrim)/\(stored) to \(staging)", errno).message)
            }
            base = stored
        } else {
            guard mkdir(staging, 0o700) == 0 else {
                throw ClaudeOwnFolderFailure.stillLinked(ClaudeFileError.posix("make \(staging)", errno).message)
            }
            made = true
        }
        chmod(staging, 0o700)
        /// Memory folders of the pre-Brim copy moved aside this run, to put
        /// back on a roll back: (where it was, where it went).
        var aside: [(memory: String, saved: String)] = []
        /// Before the swap: the memory moved aside goes back, the pre-Brim
        /// copy goes back where it was, an empty start goes. What could not be
        /// put back, in words.
        func rollBack() -> [String] {
            var problems: [String] = []
            for (memory, saved) in aside.reversed() where rename(saved, memory) != 0 {
                problems.append(ClaudeFileError.posix("move \(saved) back to \(memory)", errno).message)
            }
            if let base {
                if rename(staging, preBrim + "/" + base) != 0 {
                    problems.append(ClaudeFileError.posix("move \(staging) back to \(preBrim)/\(base)", errno).message)
                }
            } else if made {
                try? FileManager.default.removeItem(atPath: staging)
            }
            return problems
        }
        func stillLinked(_ message: String) -> ClaudeOwnFolderFailure {
            .stillLinked(([message] + rollBack()).joined(separator: " "))
        }
        if name == "projects" {
            do {
                let slugs = (try? FileManager.default.contentsOfDirectory(atPath: staging)) ?? []
                for slug in slugs.sorted() where ClaudeFileIO.isDirectory(staging + "/" + slug + "/memory") {
                    let memory = staging + "/" + slug + "/memory"
                    let folder = preBrim + "/" + memoryAside
                    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    var target = folder + "/" + slug
                    var number = 1
                    while ClaudeFileIO.exists(target) {
                        target = folder + "/" + slug + ".\(number)"
                        number += 1
                    }
                    guard rename(memory, target) == 0 else { throw ClaudeFileError.posix("move \(memory) aside", errno) }
                    aside.append((memory, target))
                }
            } catch {
                throw stillLinked(ClaudeFileError.message(error))
            }
        }
        // No sync runs during the swap: one that listed the folders before it
        // skips this folder (an entry is still linked), one after sees it
        // whole.
        let syncLock = ClaudeSync.lock(statePath)
        defer { ClaudeSync.unlock(syncLock) }
        // A session that started on the folder since the review would write
        // through the link until the swap and into the new folder after it.
        let live = ClaudeSessionIndex.liveSessions(configDirectory: folder, isAlive: isAlive)
        guard live.isEmpty else { throw ClaudeOwnFolderFailure.sessionsStarted(live.count, rollBack()) }
        // The swap: the new folder and the link trade places in one rename,
        // so the entry is never missing; a swap that fails changes nothing.
        guard swap(staging, own) == 0 else {
            throw stillLinked(ClaudeFileError.posix("swap \(staging) and the link \(own)", errno).message)
        }
        // The link is beside the folder now, under the staging name.
        var linkLeft: String?
        if !ClaudeFileIO.isSymlink(staging) || unlink(staging) != 0 {
            linkLeft = ClaudeFileError.posix("remove the old link, now at \(staging)", errno).message
        }
        var manifest = ClaudeShareManifest.load(folder: folder) ?? ClaudeShareManifest()
        manifest.entries.removeAll { $0 == entry }
        manifest.ownedFolders = (manifest.ownedFolders ?? []) + [ClaudeShareManifest.OwnedFolder(
            name: name, at: ClaudeDate.format(now), base: base.map { ClaudeSetupSharing.preBrimFolder + "/" + $0 } ?? "empty")]
        var line = "own folder"
            + (base.map { ", from \(ClaudeSetupSharing.preBrimFolder)/\($0)" } ?? "")
            + (resumed ? ", picking up the run that stopped part way" : "")
        if !aside.isEmpty {
            line += "; the memory it had for \(aside.count) repo(s) moved to \(ClaudeSetupSharing.preBrimFolder)/\(memoryAside)"
        }
        if let linkLeft { line += "; but \(linkLeft)" }
        do {
            try manifest.save(folder: folder)
        } catch {
            return ClaudeOwnFolderResult(line: line + "; but \(ClaudeSetupSharing.preBrimFolder)/\(ClaudeSetupSharing.manifestName) still lists the link (\(ClaudeFileError.message(error))), so Undo will report it", failed: true)
        }
        return ClaudeOwnFolderResult(line: line, failed: linkLeft != nil)
    }
}
