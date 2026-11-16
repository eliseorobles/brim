// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// What stops a share from running.
struct ClaudeShareProblem: Equatable {
    enum Kind: Equatable {
        /// The shared settings.json sets env.CLAUDE_CONFIG_DIR: Claude Code
        /// honors it, so every account linked to it would run on one folder.
        case settingsSetConfigDirectory
        /// The shared settings.json sets env.CLAUDE_SECURESTORAGE_CONFIG_DIR.
        case settingsSetSecureStorage
        case sharedRootMissing
        case folderMissing
        /// The folder is the shared root, or a link to it.
        case folderIsSharedRoot
        case folderIsLink
        case invalidFolder
        /// Claude Code sessions run on the folder.
        case liveSessions(Int)
    }

    var kind: Kind
    /// The account folder it concerns; nil for the shared root.
    var folder: String?
    var message: String

    /// Whether it stops the whole change. A running session stops only its
    /// own folder: the others go ahead.
    var blocksAll: Bool {
        if case .liveSessions = kind, folder != nil { return false }
        return true
    }
}

enum ClaudeShareAction: Equatable {
    /// The folder's entry already is the link.
    case alreadyLinked
    /// The shared root has no such entry: the folder's own stays as it is.
    case notInSharedRoot
    /// Neither has it.
    case absent
    /// The folder has no such entry: link it.
    case link
    /// Move the folder's entry to <folder>/.pre-brim/<name>, then link.
    case replace(preBrimName: String)
    /// Not linked until its verification passes (ClaudeSetupSharing.
    /// unverifiedEntries): the folder keeps its own.
    case keptPerAccount
    /// Not linked (as keptPerAccount), but the folder's lines the shared
    /// file lacks are added to it; the folder keeps its own file.
    case mergeOnly
    /// A conversation entry Brim linked earlier becomes the folder's own
    /// real folder (ClaudeOwnFolders), from .pre-brim/<base> when the folder
    /// kept its pre-Brim copy there, else empty; `resumes` picks up the new
    /// folder a run that stopped part way left.
    case ownFolder(base: String?, resumes: Bool)

    /// Whether carrying it out changes a file.
    var changesFiles: Bool {
        switch self {
        case .link, .replace, .mergeOnly, .ownFolder: return true
        case .alreadyLinked, .notInSharedRoot, .absent, .keptPerAccount: return false
        }
    }
}

/// What a folder's history.jsonl adds to the shared one.
struct ClaudeShareMerge: Equatable {
    /// history.jsonl lines the shared file lacks (duplicates dropped).
    var historyLines = 0
}

struct ClaudeShareStep: Equatable {
    var folder: String
    var name: String
    var action: ClaudeShareAction
    var merge: ClaudeShareMerge?
}

struct ClaudeSharePlan: Equatable {
    var sharedRoot: String
    var steps: [ClaudeShareStep]
    var problems: [ClaudeShareProblem]
    /// The plan in words, for the dry run the person reads first.
    var lines: [String]

    /// No problem stops the whole change (a running session stops only its
    /// folder).
    var canExecute: Bool { !problems.contains { $0.blocksAll } }
    /// The folders a running session keeps out of this run.
    var blockedFolders: Set<String> { Set(problems.compactMap { $0.blocksAll ? nil : $0.folder }) }
    var changesSomething: Bool {
        let blocked = blockedFolders
        return steps.contains { $0.action.changesFiles && !blocked.contains($0.folder) }
    }
    /// Whether some folder still links a conversation entry to the shared one.
    var needsOwnFolders: Bool { steps.contains { if case .ownFolder = $0.action { return true } else { return false } } }
}

struct ClaudeShareReport: Equatable {
    var lines: [String]
    /// Refused before changing anything.
    var refused: Bool
    var failures: Int

    var succeeded: Bool { !refused && failures == 0 }
}

/// Shares one Claude Code setup (~/.claude) with every other account folder,
/// by linking whole entries. Brim never edits .claude.json, sign-ins or any
/// per-account state.
///
/// Before an entry is linked, the folder's own copy moves into
/// <folder>/.pre-brim (never over an earlier one) and is recorded there, so
/// the undo puts it back. history.jsonl lines are merged by time without
/// duplicates, under Claude Code's own lock on that file. Entries whose
/// verification has not passed (unverifiedEntries) stay each account's own.
///
/// Conversation folders are each account's own (ClaudeOwnFolders.entries:
/// projects, file-history, plans, tasks) and never linked; a folder Brim
/// linked them in earlier gets its own folders back in the same review
/// (ownFolder steps), and ClaudeSync then copies every conversation, plan and
/// repo's memory into it, so /resume lists everything on every account.
///
/// The planner only reads; the executor plans again and refuses while the
/// shared settings set CLAUDE_CONFIG_DIR; a folder a session runs on is left
/// out of the run, and the others go ahead.
enum ClaudeSetupSharing {
    /// Linked to the shared root.
    static let linkedEntries = [
        "settings.json", "CLAUDE.md", "skills", "agents", "commands", "rules", "keybindings.json",
        "output-styles", "plugins",
    ]

    /// Kept per account, not linked, until a verification gate passes; each
    /// with what the gate found (Claude Code 2.1.322-2.1.323, 2026-11-12).
    /// Once one passes, moving its name into linkedEntries is the whole change.
    /// plugins/ passed on 2026-11-12: a config folder whose plugins/ links to
    /// ~/.claude/plugins lists all 17 installed plugins as enabled, loads their
    /// skills, agents and hooks (`claude plugin list` / `plugin details`), and
    /// writes nothing into the shared folder.
    static let unverifiedEntries: [(name: String, finding: String)] = [
        ("history.jsonl", "Claude Code never reads or writes a linked history.jsonl (its prompt history would not be saved), so each account keeps its own; its lines are added to the shared one"),
    ]

    /// Line files merged by time before the link.
    static let mergedLineFiles: Set<String> = ["history.jsonl"]

    /// Never linked: each account's own sign-in, caches and running state. A
    /// trailing "*" matches any continuation.
    static let neverLinked = [
        ".claude.json", "sessions", "ide", "remote-settings.json", "policy-limits.*", ".credentials.json",
        ".oauth_refresh.lock*", "statsig", "telemetry", "cache", "state", "stats-cache.json",
        "mcp-needs-auth-cache.json", "shell-snapshots", "session-env", "backups",
    ]

    static let preBrimFolder = ".pre-brim"
    static let manifestName = "brim-share.json"

    static func isNeverLinked(_ name: String) -> Bool {
        neverLinked.contains { pattern in
            pattern.hasSuffix("*") ? name.hasPrefix(String(pattern.dropLast())) : name == pattern
        }
    }

    // MARK: Guard

    /// Problems in the shared settings.json: env.CLAUDE_CONFIG_DIR would send
    /// every linked account to one folder, and env.CLAUDE_SECURESTORAGE_CONFIG_DIR
    /// would move every account's credentials. The app checks this on every
    /// change of the file.
    static func settingsProblems(_ settings: Data?) -> [ClaudeShareProblem] {
        guard let settings, let json = ClaudeJSON.parse(settings) as? [String: Any],
              let env = ClaudeJSON.object(json["env"]) else { return [] }
        var problems: [ClaudeShareProblem] = []
        if env[ClaudeLaunchEnvironment.configDirectoryVariable] != nil {
            problems.append(ClaudeShareProblem(kind: .settingsSetConfigDirectory, folder: nil,
                message: "the shared settings.json sets env.CLAUDE_CONFIG_DIR, which would run every account on one folder; remove it"))
        }
        if env[ClaudeLaunchEnvironment.secureStorageVariable] != nil {
            problems.append(ClaudeShareProblem(kind: .settingsSetSecureStorage, folder: nil,
                message: "the shared settings.json sets env.CLAUDE_SECURESTORAGE_CONFIG_DIR, which moves every account's sign-in; remove it"))
        }
        return problems
    }

    // MARK: Plan

    /// The plan for linking each folder's entries to `sharedRoot` (~/.claude)
    /// and for giving back its own conversation folders where Brim linked
    /// them. The default account's folder ("") is the shared root and is
    /// skipped. `labels` names the folders in the words of the review.
    static func plan(sharedRoot: String, folders: [String], labels: [String: String] = [:],
                     isAlive: ClaudeProcessProbe = ClaudeSessionIndex.processIsAlive) -> ClaudeSharePlan {
        var steps: [ClaudeShareStep] = []
        var problems = settingsProblems(ClaudeFileIO.read(sharedRoot + "/settings.json"))
        var lines = ["Share the Claude Code setup in \(sharedRoot) with \(folders.filter { !$0.isEmpty }.count) account folder(s)."]
        if !ClaudeFileIO.isDirectory(sharedRoot, followingLinks: true) {
            problems.append(ClaudeShareProblem(kind: .sharedRootMissing, folder: nil,
                                               message: "\(sharedRoot) is not a folder"))
        }
        let sharedReal = ClaudeFileIO.realPath(sharedRoot)
        for folder in folders where !folder.isEmpty {
            lines.append("")
            lines.append("\(folder):")
            if let problem = folderProblem(folder, sharedReal: sharedReal) {
                problems.append(problem)
                lines.append("  BLOCKED: \(problem.message)")
                continue
            }
            let live = ClaudeSessionIndex.liveSessions(configDirectory: folder, isAlive: isAlive)
            if !live.isEmpty {
                let problem = ClaudeShareProblem(kind: .liveSessions(live.count), folder: folder,
                    message: "\(live.count) Claude Code session(s) run on \(folder); end them (/exit) first")
                problems.append(problem)
                lines.append("  SKIPPED this time: \(problem.message), then review again")
            }
            var owned: [ClaudeShareStep] = []
            for name in ClaudeOwnFolders.entries {
                guard let found = ClaudeOwnFolders.plan(folder: folder, name: name) else { continue }
                owned.append(ClaudeShareStep(folder: folder, name: name,
                                             action: .ownFolder(base: found.entry.storedAs, resumes: found.resumes), merge: nil))
            }
            if !owned.isEmpty {
                let label = labels[folder] ?? ClaudeHelper.displayLabel(nil, folder: folder)
                lines.append("  Gives \(label) its own conversation folders so workflows, memory and plans work there. "
                             + "Every conversation stays listed in /resume on every account (clones, no extra disk).")
                for step in owned {
                    steps.append(step)
                    lines.append("  " + describe(step, sharedRoot: sharedRoot))
                }
            }
            for name in linkedEntries {
                let step = plannedStep(folder: folder, name: name, sharedRoot: sharedRoot)
                steps.append(step)
                lines.append("  " + describe(step, sharedRoot: sharedRoot))
            }
            for entry in unverifiedEntries {
                let step = unverifiedStep(folder: folder, name: entry.name, sharedRoot: sharedRoot)
                steps.append(step)
                lines.append("  " + describe(step, sharedRoot: sharedRoot))
            }
            lines.append("  Never linked (this account's own): " + (ClaudeOwnFolders.entries + neverLinked).joined(separator: ", "))
        }
        for problem in problems where problem.folder == nil {
            lines.append("BLOCKED: \(problem.message)")
        }
        return ClaudeSharePlan(sharedRoot: sharedRoot, steps: steps, problems: problems, lines: lines)
    }

    private static func folderProblem(_ folder: String, sharedReal: String) -> ClaudeShareProblem? {
        if !folder.hasPrefix("/") {
            return ClaudeShareProblem(kind: .invalidFolder, folder: folder, message: "\(folder) is not an absolute path")
        }
        if ClaudeFileIO.isSymlink(folder) {
            return ClaudeShareProblem(kind: .folderIsLink, folder: folder, message: "\(folder) is a link, not a folder of its own")
        }
        if !ClaudeFileIO.isDirectory(folder) {
            return ClaudeShareProblem(kind: .folderMissing, folder: folder, message: "\(folder) is not a folder")
        }
        if ClaudeFileIO.realPath(folder) == sharedReal {
            return ClaudeShareProblem(kind: .folderIsSharedRoot, folder: folder, message: "\(folder) is the shared folder itself")
        }
        return nil
    }

    static func plannedStep(folder: String, name: String, sharedRoot: String) -> ClaudeShareStep {
        let shared = sharedRoot + "/" + name
        let own = folder + "/" + name
        // A shared entry that is itself a link counts when it leads somewhere.
        guard FileManager.default.fileExists(atPath: shared) else {
            return ClaudeShareStep(folder: folder, name: name,
                                   action: ClaudeFileIO.exists(own) ? .notInSharedRoot : .absent, merge: nil)
        }
        if ClaudeFileIO.isSymlink(own), isLink(own, to: shared) {
            return ClaudeShareStep(folder: folder, name: name, action: .alreadyLinked, merge: nil)
        }
        guard ClaudeFileIO.exists(own) else {
            return ClaudeShareStep(folder: folder, name: name, action: .link, merge: nil)
        }
        var merge: ClaudeShareMerge?
        if mergedLineFiles.contains(name), ClaudeFileIO.isRegularFile(own) {
            merge = ClaudeShareMerge(historyLines: historyMerge(shared: ClaudeFileIO.read(shared, limit: .max) ?? Data(),
                                                                own: ClaudeFileIO.read(own, limit: .max) ?? Data()).added)
        }
        return ClaudeShareStep(folder: folder, name: name,
                               action: .replace(preBrimName: freePreBrimName(folder: folder, name: name)), merge: merge)
    }

    /// An entry kept per account: a line file whose lines the shared one
    /// lacks gets them added (the shared file must be a regular file already);
    /// anything else stays exactly as it is.
    static func unverifiedStep(folder: String, name: String, sharedRoot: String) -> ClaudeShareStep {
        let shared = ClaudeFileIO.realPath(sharedRoot + "/" + name)
        let own = folder + "/" + name
        if mergedLineFiles.contains(name), ClaudeFileIO.isRegularFile(own), ClaudeFileIO.isRegularFile(shared) {
            let added = historyMerge(shared: ClaudeFileIO.read(shared, limit: .max) ?? Data(),
                                     own: ClaudeFileIO.read(own, limit: .max) ?? Data()).added
            if added > 0 {
                return ClaudeShareStep(folder: folder, name: name, action: .mergeOnly, merge: ClaudeShareMerge(historyLines: added))
            }
        }
        return ClaudeShareStep(folder: folder, name: name, action: .keptPerAccount, merge: nil)
    }

    /// What the verification gate found for an unverified entry.
    static func finding(_ name: String) -> String {
        unverifiedEntries.first { $0.name == name }?.finding ?? "not verified yet"
    }

    /// Whether the link at `path` leads to `target` (as written, or once both
    /// are resolved).
    static func isLink(_ path: String, to target: String) -> Bool {
        guard let destination = ClaudeFileIO.linkDestination(path) else { return false }
        let absolute = destination.hasPrefix("/") ? destination
            : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
        let standardized = (absolute as NSString).standardizingPath
        return standardized == (target as NSString).standardizingPath
            || ClaudeFileIO.realPath(path) == ClaudeFileIO.realPath(target)
    }

    /// <name>, or <name>.1, <name>.2, … : the first one .pre-brim does not hold.
    static func freePreBrimName(folder: String, name: String) -> String {
        let base = folder + "/" + preBrimFolder + "/"
        if !ClaudeFileIO.exists(base + name) { return name }
        var number = 1
        while ClaudeFileIO.exists(base + name + ".\(number)") { number += 1 }
        return name + ".\(number)"
    }

    // MARK: history.jsonl

    /// The shared history with the folder's lines added: ordered by their
    /// "timestamp" (a line without one keeps the time of the line before it in
    /// its file), the shared file's lines first on equal times, identical
    /// lines once.
    static func historyMerge(shared: Data, own: Data) -> (data: Data, added: Int) {
        let sharedLines = lines(shared)
        var seen = Set(sharedLines)
        var entries: [(time: Double, source: Int, index: Int, line: String)] = []
        var added = 0
        var last = -Double.infinity
        for (index, line) in sharedLines.enumerated() {
            last = timestamp(line) ?? last
            entries.append((last, 0, index, line))
        }
        last = -Double.infinity
        for (index, line) in lines(own).enumerated() {
            last = timestamp(line) ?? last
            guard seen.insert(line).inserted else { continue }
            entries.append((last, 1, index, line))
            added += 1
        }
        entries.sort { a, b in
            if a.time != b.time { return a.time < b.time }
            if a.source != b.source { return a.source < b.source }
            return a.index < b.index
        }
        let text = entries.map(\.line).joined(separator: "\n")
        return (Data((text.isEmpty ? "" : text + "\n").utf8), added)
    }

    private static func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func timestamp(_ line: String) -> Double? {
        guard let json = ClaudeJSON.parse(Data(line.utf8)) as? [String: Any] else { return nil }
        return ClaudeJSON.number(json["timestamp"])
    }

    // MARK: Execute

    /// Plans again and carries the plan out, folder by folder and entry by
    /// entry. Refuses before changing anything while a problem stops the
    /// whole change; a folder a session runs on is left out, and says so,
    /// while the others go ahead.
    /// When a folder got its own conversation folders, every conversation,
    /// plan and repo's memory is synced into it right after (ClaudeSync, with
    /// `trash` for what it moves to the Trash).
    static func execute(sharedRoot: String, folders: [String], paths: ClaudeAccountsPaths, labels: [String: String] = [:],
                        now: Date = Date(),
                        isAlive: @escaping ClaudeProcessProbe = ClaudeSessionIndex.processIsAlive,
                        trash: @escaping (String) throws -> Void = ClaudeSync.trashItem) -> ClaudeShareReport {
        let current = Self.plan(sharedRoot: sharedRoot, folders: folders, labels: labels, isAlive: isAlive)
        guard current.canExecute else {
            return ClaudeShareReport(lines: ["Refused; nothing was changed."]
                                        + current.problems.filter(\.blocksAll).map { "BLOCKED: \($0.message)" },
                                     refused: true, failures: 0)
        }
        var lines: [String] = []
        var failures = 0
        for problem in current.problems where !problem.blocksAll {
            failures += 1
            lines.append("\(problem.folder ?? ""): not changed: \(problem.message), then run this again")
        }
        let blocked = current.blockedFolders
        // Each folder's steps run while holding its migration lock, which
        // brim-claude waits on before it starts or moves a conversation onto
        // the folder; a session that started since the review stops the
        // folder (checked again when the lock is taken, and right before
        // each swap).
        var stopped = Set<String>()
        var owned = 0
        var locked: (folder: String, descriptor: Int32)?
        defer { if let locked { ClaudeOwnFolders.unlock(locked.descriptor) } }
        for step in current.steps where step.action.changesFiles && !blocked.contains(step.folder) && !stopped.contains(step.folder) {
            if locked?.folder != step.folder {
                if let locked { ClaudeOwnFolders.unlock(locked.descriptor) }
                locked = (step.folder, ClaudeOwnFolders.lock(folder: step.folder, paths: paths))
                let live = ClaudeSessionIndex.liveSessions(configDirectory: step.folder, isAlive: isAlive).count
                if live > 0 {
                    stopped.insert(step.folder)
                    failures += 1
                    lines.append(sessionsStarted(step.folder, live, []))
                    continue
                }
            }
            do {
                if case .ownFolder = step.action {
                    let done = try ClaudeOwnFolders.perform(folder: step.folder, name: step.name, now: now,
                                                            statePath: ClaudeSync.statePath(paths), isAlive: isAlive)
                    owned += 1
                    if done.failed { failures += 1 }
                    lines.append("\(step.folder)/\(step.name): " + done.line)
                    continue
                }
                try perform(step, sharedRoot: sharedRoot)
                lines.append("\(step.folder)/\(step.name): " + describe(step, sharedRoot: sharedRoot, done: true))
            } catch ClaudeOwnFolderFailure.sessionsStarted(let count, let problems) {
                stopped.insert(step.folder)
                failures += 1
                lines.append(sessionsStarted(step.folder, count, problems))
            } catch ClaudeOwnFolderFailure.stillLinked(let message) {
                failures += 1
                lines.append("\(step.folder)/\(step.name): FAILED, still linked (\(message))")
            } catch {
                failures += 1
                lines.append("\(step.folder)/\(step.name): FAILED, not linked (\(error))")
            }
        }
        if let held = locked {
            ClaudeOwnFolders.unlock(held.descriptor)
            locked = nil
        }
        // The folders that got their own conversation folders are empty or
        // hold an old copy: every conversation, plan and repo's memory is
        // copied in now (clones). brim-claude waits on the sync's own lock.
        if owned > 0 {
            let started = Date()
            let report = ClaudeSync.reconcile(configDirectories: [sharedRoot] + folders, scope: .all,
                                              statePath: ClaudeSync.statePath(paths),
                                              options: ClaudeSync.Options(isAlive: isAlive, trash: trash, now: now,
                                                                          cleanupDays: ClaudeSync.cleanupDays(
                                                                              sharedSettings: ClaudeFileIO.read(sharedRoot + "/settings.json"))))
            lines.append(String(format: "Synced every account's conversations, plans and memory: %d file(s) copied (clones), %d conversation(s) left for when they end, in %.1f s.", locale: Locale(identifier: "en_US_POSIX"),
                                report.copied.count, report.running, Date().timeIntervalSince(started)))
            if !report.diverged.isEmpty {
                lines.append("Continued on two accounts, so each keeps its own version: " + report.diverged.joined(separator: ", "))
            }
            failures += report.failures.count
            lines += report.failures.map { "FAILED: " + $0 }
        }
        if lines.isEmpty { lines.append("Everything was already shared.") }
        return ClaudeShareReport(lines: lines, refused: false, failures: failures)
    }

    private static func sessionsStarted(_ folder: String, _ count: Int, _ problems: [String]) -> String {
        "\(folder): not changed: \(count) Claude Code session(s) started on it during the change; end them (/exit), then run this again"
            + (problems.isEmpty ? "" : " (" + problems.joined(separator: " ") + ")")
    }

    private static func perform(_ step: ClaudeShareStep, sharedRoot: String) throws {
        let shared = sharedRoot + "/" + step.name
        let own = step.folder + "/" + step.name
        if step.action == .mergeOnly {
            try mergeHistory(own: own, into: shared)
            return
        }
        if case .replace = step.action {
            if mergedLineFiles.contains(step.name), ClaudeFileIO.isRegularFile(own) {
                try mergeHistory(own: own, into: shared)
            }
            let folder = step.folder + "/" + preBrimFolder
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let stored = freePreBrimName(folder: step.folder, name: step.name)
            guard rename(own, folder + "/" + stored) == 0 else { throw ClaudeFileError.posix("move \(own)", errno) }
            guard symlink(shared, own) == 0 else {
                let failure = ClaudeFileError.posix("link \(own)", errno)
                rename(folder + "/" + stored, own)
                throw failure
            }
            do {
                try record(ClaudeShareManifest.Entry(name: step.name, storedAs: stored, linkedTo: shared), in: step.folder)
            } catch {
                // Unrecorded, the undo could not restore it: put it back now.
                unlink(own)
                rename(folder + "/" + stored, own)
                throw error
            }
        } else if step.action == .link {
            guard symlink(shared, own) == 0 else { throw ClaudeFileError.posix("link \(own)", errno) }
            do {
                try record(ClaudeShareManifest.Entry(name: step.name, storedAs: nil, linkedTo: shared), in: step.folder)
            } catch {
                unlink(own)
                throw error
            }
        }
    }

    /// Adds the folder's history lines to the shared history.jsonl while
    /// holding Claude Code's lock on it, then replaces it in one rename.
    static func mergeHistory(own: String, into shared: String) throws {
        let target = ClaudeFileIO.realPath(shared)
        let lock = try ClaudeHistoryLock.acquire(target)
        defer { lock.release() }
        let existing = ClaudeFileIO.read(target, limit: .max) ?? Data()
        let merged = historyMerge(shared: existing, own: ClaudeFileIO.read(own, limit: .max) ?? Data())
        guard merged.added > 0 else { return }
        var info = stat()
        let mode = stat(target, &info) == 0 ? mode_t(info.st_mode & 0o777) : 0o600
        try ClaudeFileIO.writeAtomically(merged.data, to: target, mode: mode)
    }

    // MARK: Undo

    /// The undo in words: which links go and which originals come back.
    static func undoPlan(folder: String, sharedRoot: String) -> [String] {
        guard let manifest = ClaudeShareManifest.load(folder: folder), !manifest.entries.isEmpty else {
            return ["\(folder): nothing to undo (no \(preBrimFolder)/\(manifestName))."]
        }
        var lines = ["\(folder):"]
        for entry in manifest.entries.reversed() {
            if let stored = entry.storedAs {
                lines.append("  \(entry.name): remove the link, move \(preBrimFolder)/\(stored) back")
            } else {
                lines.append("  \(entry.name): remove the link")
            }
        }
        lines.append("  Files and history lines copied into \(sharedRoot) stay there.")
        return lines
    }

    /// Removes the links Brim made and moves the originals back, newest
    /// first. A link that no longer leads to the shared entry is left alone.
    static func undo(folder: String, sharedRoot: String,
                     isAlive: ClaudeProcessProbe = ClaudeSessionIndex.processIsAlive) -> ClaudeShareReport {
        let live = ClaudeSessionIndex.liveSessions(configDirectory: folder, isAlive: isAlive)
        guard live.isEmpty else {
            return ClaudeShareReport(lines: ["Refused; nothing was changed.",
                "BLOCKED: \(live.count) Claude Code session(s) run on \(folder); end them (/exit) first"],
                                     refused: true, failures: 0)
        }
        guard var manifest = ClaudeShareManifest.load(folder: folder), !manifest.entries.isEmpty else {
            return ClaudeShareReport(lines: ["\(folder): nothing to undo."], refused: true, failures: 0)
        }
        var lines: [String] = []
        var failures = 0
        for entry in manifest.entries.reversed() {
            let own = folder + "/" + entry.name
            guard ClaudeFileIO.isSymlink(own), isLink(own, to: entry.linkedTo) else {
                failures += 1
                lines.append("\(own): not Brim's link any more; left alone")
                continue
            }
            guard unlink(own) == 0 else {
                failures += 1
                lines.append("\(own): FAILED to remove the link (errno \(errno))")
                continue
            }
            if let stored = entry.storedAs {
                let original = folder + "/" + preBrimFolder + "/" + stored
                guard rename(original, own) == 0 else {
                    failures += 1
                    lines.append("\(own): link removed, but \(original) could not be moved back (errno \(errno))")
                    continue
                }
                lines.append("\(own): restored from \(preBrimFolder)/\(stored)")
            } else {
                lines.append("\(own): link removed")
            }
            manifest.entries.removeAll { $0 == entry }
        }
        do {
            try manifest.save(folder: folder)
        } catch {
            failures += 1
            lines.append("could not update \(preBrimFolder)/\(manifestName): \(error)")
        }
        return ClaudeShareReport(lines: lines, refused: false, failures: failures)
    }

    private static func record(_ entry: ClaudeShareManifest.Entry, in folder: String) throws {
        var manifest = ClaudeShareManifest.load(folder: folder) ?? ClaudeShareManifest()
        manifest.entries.append(entry)
        try manifest.save(folder: folder)
    }

    // MARK: Words

    static func describe(_ step: ClaudeShareStep, sharedRoot: String, done: Bool = false) -> String {
        let target = sharedRoot + "/" + step.name
        var parts: [String] = []
        if let merge = step.merge, merge.historyLines > 0 {
            parts.append((done ? "added" : "add") + " \(merge.historyLines) line(s) to \(target) by time, duplicates dropped")
        }
        switch step.action {
        case .alreadyLinked:
            parts.append("already linked")
        case .notInSharedRoot:
            parts.append("not in \(sharedRoot); this folder's own copy stays")
        case .absent:
            parts.append("in neither folder; nothing to do")
        case .link:
            parts.append((done ? "linked" : "link") + " to \(target)")
        case .replace(let stored):
            parts.append((done ? "moved" : "move") + " to \(preBrimFolder)/\(stored), then " + (done ? "linked" : "link") + " to \(target)")
        case .keptPerAccount, .mergeOnly:
            parts.append("not linked: " + finding(step.name))
        case .ownFolder(let base, let resumes):
            if resumes {
                parts.append((done ? "replaced" : "replace") + " the link with this account's own folder, picking up "
                             + ClaudeOwnFolders.staging(folder: step.folder, name: step.name)
                             + ", left by a run that stopped part way")
            } else {
                parts.append((done ? "replaced" : "replace") + " the link with this account's own folder, "
                             + (base.map { "starting from \(preBrimFolder)/\($0)" } ?? "starting empty")
                             + "; then every conversation is synced into it")
            }
        }
        return "\(step.name): " + parts.joined(separator: "; ")
    }
}

/// <folder>/.pre-brim/brim-share.json: what the share moved and linked, in
/// order, so the undo restores exactly that.
struct ClaudeShareManifest: Equatable, Codable {
    struct Entry: Equatable, Codable {
        var name: String
        /// The original's name in .pre-brim; nil when the folder had none.
        var storedAs: String?
        var linkedTo: String
    }

    /// A conversation entry Brim linked earlier and gave back as the
    /// folder's own (ClaudeOwnFolders), for the record.
    struct OwnedFolder: Equatable, Codable {
        var name: String
        var at: String
        /// ".pre-brim/<name>" when it started from the pre-Brim copy, else "empty".
        var base: String
    }

    var version = 1
    var entries: [Entry] = []
    var ownedFolders: [OwnedFolder]? = nil

    static func path(folder: String) -> String {
        folder + "/" + ClaudeSetupSharing.preBrimFolder + "/" + ClaudeSetupSharing.manifestName
    }

    static func load(folder: String) -> ClaudeShareManifest? {
        guard let data = ClaudeFileIO.read(path(folder: folder), limit: 1 << 20) else { return nil }
        return try? JSONDecoder().decode(ClaudeShareManifest.self, from: data)
    }

    func save(folder: String) throws {
        let directory = folder + "/" + ClaudeSetupSharing.preBrimFolder
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try ClaudeFileIO.writeAtomically(try ClaudeJSON.encoder().encode(self), to: Self.path(folder: folder))
    }
}

/// Claude Code's lock on history.jsonl (proper-lockfile): the folder
/// "<real path>.lock", taken with mkdir, stale after 10 s without an update.
struct ClaudeHistoryLock {
    static let stale: TimeInterval = 10
    let path: String

    /// Waits a bounded time (about 3 s) for a lock another process holds:
    /// Claude Code holds it only while it appends a few lines. A lock older
    /// than `stale` belongs to a process that died and is taken over, as
    /// Claude Code itself does.
    static func acquire(_ file: String, attempts: Int = 60) throws -> ClaudeHistoryLock {
        let path = file + ".lock"
        for _ in 0 ..< attempts {
            if mkdir(path, 0o700) == 0 { return ClaudeHistoryLock(path: path) }
            guard errno == EEXIST else { throw ClaudeFileError.posix("lock \(path)", errno) }
            if let modified = ClaudeFileIO.modificationDate(path), Date().timeIntervalSince(modified) > stale {
                rmdir(path)
                continue
            }
            usleep(50_000)
        }
        throw ClaudeFileError.posix("lock \(path) is held", EBUSY)
    }

    func release() {
        rmdir(path)
    }
}
