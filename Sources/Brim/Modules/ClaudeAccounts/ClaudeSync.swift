// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import CryptoKit
import Darwin
import Foundation

/// Every account folder holds a real copy of every conversation (ticket
/// T-38). Each account keeps its own projects/, file-history/,
/// plans/ and tasks/ (ClaudeOwnFolders), so Claude Code's permission roots,
/// which are plain prefixes of CLAUDE_CONFIG_DIR, stay real; this keeps those
/// folders one, so Claude Code's own /resume picker (and `claude --resume`,
/// `-c`) on any account lists every account's conversations and a plain
/// `--resume <id>` continues one there. Copies are APFS clones (no extra
/// disk), made beside the destination under a dot name and renamed into
/// place, only when the destination is still what was read.
///
/// The folders: ~/.claude and every account folder whose conversation entries
/// are real folders. A folder still linked to ~/.claude sees its files
/// already and is skipped.
///
/// The rules, per unit:
///   - A conversation: projects/<slug>/<sid>.jsonl with its session folder
///     (projects/<slug>/<sid>/: subagents, workflow journals and scripts,
///     tool results), file-history/<sid>/ and tasks/<sid>. Transcripts and
///     every other .jsonl are append-only: the longest copy wins, and a copy
///     that is missing or a byte-prefix of it is replaced by a clone of it.
///     Copies that diverged (neither is a prefix of the other: the
///     conversation went on on two accounts between syncs) are versions:
///     each is kept, never merged or deleted, and still takes its own older
///     copies; a folder without the conversation gets the version it last
///     ran with (the newest change); it is reported once. Other files are a
///     union by relative path; when copies differ, the copy in the folder
///     holding the winning transcript wins (per version). A conversation
///     that runs now in any folder (sessions/<pid>.json, pid alive, or a
///     process the app still sees running after its file went) is not
///     touched; it syncs when it ends.
///   - A plan (plans/*.md): union, the newest change wins.
///   - Memory (projects/<slug>/memory/, recursive): union, the newest change
///     wins (a tie between different contents is left alone and reported); a
///     copy that changed since the last sync and loses goes to the Trash
///     before it is replaced; a synced file deleted in one folder goes to the
///     Trash in the others. Regular files up to 1 MB; dotfiles, editor and
///     temporary names and links are skipped.
///
/// Deletion. Claude Code deletes old transcripts per folder (cleanupPeriodDays
/// in the shared settings), and a deleted file is never brought back. The
/// state (<state>/sync.json) records what the last sync left, per unit (size,
/// modification, the folders that held it) and the identity of each folder's
/// projects/ (as the last run that looked at every conversation saw it) and
/// plans/. A unit missing from a folder that held it, whose
/// folder is the same one the last sync saw, while every remaining copy is
/// unchanged, was deleted: the remaining copies go to the Trash when they are
/// older than the cleanup period (Claude Code would delete them anyway),
/// otherwise they are left as they are and no longer synced. Memory keeps its
/// own rule above (to the Trash, whatever its age). Never an unlink.
///
/// Check-out (T-40, "library checkout"). While a conversation is open in one
/// folder, its copies in the others are moved out of Claude Code's view, so
/// their /resume pickers and `claude --resume <id>` there cannot continue an
/// old copy and split it: each other copy that is the same as, or a
/// byte-prefix of, the open folder's goes (a rename) to
/// projects/<slug>/.brim-checked-out/<sid>.jsonl. Claude Code 2.1.325 lists a
/// folder's conversations as the files <slug>/*.jsonl directly in it, with a
/// session id for a name, and finds `--resume <id>` as <slug>/<id>.jsonl in
/// the working folder's slugs, its worktrees' and then every projects/<slug>/
/// (one level): a dot folder inside a slug, like the <sid>/ session folders,
/// is never read, so only the transcript moves. A copy that went another way
/// stays where it is (the divergence rule takes it). The check-out is
/// recorded in the state, with the process holding the conversation open,
/// before anything moves (a crash leaves a record to finish or undo). It
/// ends when that process exits (never when its pid file goes; an in-session
/// /resume keeps the conversation it left open until then): each held copy
/// goes back in place and the conversation syncs in the same run (its older
/// copies take the newest); a held copy whose place filled meanwhile is
/// removed when every byte of it is in the copy there, else it goes to the
/// Trash. While open, a conversation counts as running, so no run syncs it.
/// A conversation open in two folders at once (already split) is left to
/// the divergence rule; open twice in one folder (two processes writing one
/// file) it is one conversation, held until the last of them exits. A
/// process the caller saw exit no longer holds anything, even while its pid
/// still answers and its pid file is left (not yet reaped). The check-in
/// runs with one folder left too (an account removed from the list while a
/// conversation was open on it), and the uninstall checks in every held
/// copy, whatever holds it (checkInEverything): with Brim gone nothing
/// would, and Claude Code never lists one.
///
/// What starts a run (realtime, never a timer): a session starting or
/// switching conversation and a session ending (the app watches every
/// sessions/ folder and each running session's process), the app starting
/// and a migration (a full run), `brim-claude pick` and `resume` before a
/// launch (the working folder's repo), `brim-claude move` (that
/// conversation), and memory files changing (FSEvents). Every run checks out
/// what runs now and checks in what ended first. ClaudeSyncWatcher has the
/// app's side.
enum ClaudeSync {
    static let stateName = "sync.json"
    /// The folder inside projects/<slug>/ a conversation's copy waits in while
    /// the conversation is open in another account folder.
    static let checkoutFolder = ".brim-checked-out"
    static let memorySizeLimit: Int64 = 1 << 20
    /// Claude Code's cleanupPeriodDays when the shared settings name none.
    static let defaultCleanupDays: Double = 30

    /// What one run looks at.
    struct Scope: Equatable {
        /// Every conversation, plan and repo's memory.
        var everything = false
        /// Every conversation of these repos (projects/<slug>) and their memory.
        var slugs: Set<String> = []
        /// These conversations, by session id, in any repo.
        var sessions: Set<String> = []
        /// Only the memory of these repos.
        var memory: Set<String> = []

        static let all = Scope(everything: true)
    }

    struct Options {
        var isAlive: ClaudeProcessProbe = ClaudeSessionIndex.processIsAlive
        /// The Trash, recoverable; tests pass their own.
        var trash: (String) throws -> Void = ClaudeSync.trashItem
        var now = Date()
        var cleanupDays: Double = ClaudeSync.defaultCleanupDays
        /// Runs just before a destination is checked and replaced (tests
        /// change it there).
        var beforeWrite: (String) -> Void = { _ in }
        /// Conversations the caller knows still run besides those with a pid
        /// file: the app's watcher keeps a conversation running until its
        /// process exits (RunningSessions).
        var running: Set<String> = []
        /// Runs once, before this run waits for another to let go of the
        /// lock (brim-claude says so: a launch never looks frozen).
        var waiting: () -> Void = {}
        /// Processes the caller saw exit (the app's exit sources): their
        /// conversations are no longer open, even while the pid still
        /// answers (not yet reaped).
        var exited: Set<Int32> = []
    }

    struct Report: Equatable {
        var copied: [String] = []
        var trashed: [String] = []
        /// Copies that changed since the last sync and lost to a newer one:
        /// moved to the Trash before being replaced.
        var kept: [String] = []
        /// Left alone this run, with why.
        var skipped: [String] = []
        var failures: [String] = []
        /// Conversations found continued on two accounts, reported once.
        var diverged: [String] = []
        /// Units deleted in a folder while recent copies remain: left as they
        /// are and no longer synced.
        var left: [String] = []
        /// Conversations not touched because they run now.
        var running = 0
        /// Conversations looked at.
        var conversations = 0
        /// Copies moved out of view because the conversation is open in
        /// another folder (their places).
        var checkedOut: [String] = []
        /// Copies back in view because the conversation ended (their places).
        var checkedIn: [String] = []
        /// Conversations open now with copies held out of view, by session id
        /// -> the process holding them open and its config folder (the
        /// account it runs on).
        var open: [String: Open] = [:]

        var changed: Bool { !copied.isEmpty || !trashed.isEmpty || !checkedOut.isEmpty || !checkedIn.isEmpty }
    }

    /// The process holding a checked-out conversation open (T-50: brim-claude
    /// names it and waits on its exit).
    struct Open: Equatable {
        /// Its config folder (real path): the account it runs on.
        var config: String
        var pid: Int32
        /// When it started, to tell a reused pid.
        var started: Date?
    }

    /// A regular file's size and modification (ns since 1970), as lstat
    /// reads them.
    struct Stamp: Codable, Equatable {
        var size: Int64
        var modified: Int64
    }

    struct State: Codable, Equatable {
        struct Unit: Codable, Equatable {
            var size: Int64
            var modified: Int64
            /// The folders (real paths) that held it after the sync.
            var holders: [String]
        }

        struct Memory: Codable, Equatable {
            /// relative path -> sha256 (hex) of the content synced last.
            var files: [String: String] = [:]
            /// The projects/ folders (real paths) that took part -> the
            /// identity of their <slug>/memory folder at that sync.
            var folders: [String: String] = [:]
        }

        /// A conversation open in one folder whose copies elsewhere are out
        /// of view (ClaudeSync's check-out).
        struct Checkout: Codable, Equatable {
            /// The folder (real path) it is open in.
            var live: String
            /// The process holding it open, and when it started (seconds
            /// since 1970), to tell a reused pid.
            var pid: Int32
            var started: Double?
            /// That process's config folder (real path): the account it runs
            /// on. It differs from `live` for a folder still linked to
            /// ~/.claude, whose sessions write into ~/.claude's projects/.
            var config: String?
            /// The folders whose copy waits in <slug>/.brim-checked-out.
            var held: [String] = []
            /// Folders whose copy went another way, as it was seen (not read
            /// again while unchanged).
            var left: [String: Stamp]?
        }

        var version = 1
        /// "<slug>/<sid>" -> the transcript as synced last.
        var sessions: [String: Unit] = [:]
        /// plan file name -> as synced last.
        var plans: [String: Unit] = [:]
        /// slug -> its memory as synced last.
        var memory: [String: Memory] = [:]
        /// "s:<slug>/<sid>" or "p:<name>" -> the size its copies had when a
        /// deletion in one folder left them alone (no longer synced).
        var left: [String: Int64] = [:]
        /// "<slug>/<sid>" of conversations reported as continued on two accounts.
        var diverged: [String] = []
        /// <folder>/projects and <folder>/plans -> their identity at the last sync.
        var roots: [String: String] = [:]
        /// "<slug>/<sid>" -> its check-out, while it lasts.
        var checkouts: [String: Checkout] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            sessions = try values.decodeIfPresent([String: Unit].self, forKey: .sessions) ?? [:]
            plans = try values.decodeIfPresent([String: Unit].self, forKey: .plans) ?? [:]
            memory = try values.decodeIfPresent([String: Memory].self, forKey: .memory) ?? [:]
            left = try values.decodeIfPresent([String: Int64].self, forKey: .left) ?? [:]
            diverged = try values.decodeIfPresent([String].self, forKey: .diverged) ?? []
            roots = try values.decodeIfPresent([String: String].self, forKey: .roots) ?? [:]
            checkouts = try values.decodeIfPresent([String: Checkout].self, forKey: .checkouts) ?? [:]
        }

        static func load(_ path: String) -> State {
            guard let data = ClaudeFileIO.read(path, limit: 64 << 20),
                  let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
            return state
        }

        func save(_ path: String) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try ClaudeFileIO.writeAtomically(try encoder.encode(self), to: path)
        }
    }

    static func statePath(_ paths: ClaudeAccountsPaths) -> String { paths.stateDirectory + "/" + stateName }

    /// A session id as people read it: its first eight characters.
    static func shortId(_ id: String) -> String { String(id.prefix(8)) }

    /// The cleanup period the shared settings name, in days.
    static func cleanupDays(sharedSettings data: Data?) -> Double {
        guard let data, let json = ClaudeJSON.parse(data) as? [String: Any],
              let days = ClaudeJSON.number(json["cleanupPeriodDays"]), days > 0 else { return defaultCleanupDays }
        return days
    }

    /// The folders that take part, by real path, once each, in the order
    /// given: those whose conversation entries are all real folders (or not
    /// made yet).
    static func folders(configDirectories: [String]) -> [String] {
        var seen = Set<String>()
        var folders: [String] = []
        for directory in configDirectories where ClaudeFileIO.isDirectory(directory, followingLinks: true) {
            let real = ClaudeFileIO.realPath(directory)
            guard !ClaudeOwnFolders.entries.contains(where: { ClaudeFileIO.isSymlink(real + "/" + $0) }) else { continue }
            if seen.insert(real).inserted { folders.append(real) }
        }
        return folders
    }

    /// The slug of a path an event names under one of `folders`, when the
    /// path is inside a repo's memory/ folder.
    static func memorySlug(ofEvent path: String, folders: [String]) -> String? {
        for folder in folders where path.hasPrefix(folder + "/projects/") {
            let parts = path.dropFirst(folder.count + "/projects/".count).split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[1] == "memory" { return String(parts[0]) }
        }
        return nil
    }

    /// What one batch of file events asks the app's watcher to do.
    enum WatchRoute: Equatable {
        /// Events were lost or a watched root changed: everything is read again.
        case full
        /// A running session's file changed (`sessions`), or these repos' memory.
        case changes(sessions: Bool, memory: Set<String>)

        static let nothing = WatchRoute.changes(sessions: false, memory: [])
    }

    /// Routes a batch. `rescan`: the stream lost events or a watched root
    /// appeared, moved or went away (a MustScanSubDirs batch names only the
    /// folder to read again, which no per-path rule matches, so it must
    /// never fall through to the per-path split).
    static func watchRoute(paths: [String], rescan: Bool, sessionRoots: [String], folders: [String]) -> WatchRoute {
        if rescan { return .full }
        let sessions = paths.contains { path in sessionRoots.contains { path == $0 || path.hasPrefix($0 + "/") } }
        let memory = Set(paths.compactMap { memorySlug(ofEvent: $0, folders: folders) })
        return .changes(sessions: sessions, memory: memory)
    }

    /// The paths the app's watcher streams: every config folder's sessions/
    /// and `<real projects>/<slug>/memory` for every repo folder in each real
    /// projects/ (`slugs`, by folder). No projects/ root: transcripts belong
    /// to the agent usage stream alone. A memory/ folder that does not exist
    /// yet still reports its files once it is made.
    static func watchedPaths(configDirectories: [String], folders: [String], slugs: [String: [String]]) -> [String] {
        var seen = Set<String>()
        var paths = configDirectories.map { ClaudeFileIO.realPath($0) + "/sessions" }
        for folder in folders {
            paths += (slugs[folder] ?? []).sorted().map { folder + "/projects/" + $0 + "/memory" }
        }
        return paths.filter { seen.insert($0).inserted }
    }

    /// The repo folders in each folder's projects/, dot-names left out.
    static func projectSlugs(folders: [String]) -> [String: [String]] {
        var slugs: [String: [String]] = [:]
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder + "/projects")) ?? []
            slugs[folder] = names.filter { !$0.hasPrefix(".") && ClaudeFileIO.isDirectory(folder + "/projects/" + $0) }.sorted()
        }
        return slugs
    }

    // MARK: Run

    /// Brings what `scope` names to one state across the folders of
    /// `configDirectories` (ClaudeSync.folders). Running sessions are read
    /// from every one of `configDirectories`, linked or not. Holds an
    /// exclusive lock beside the state file while it runs, so the app and
    /// brim-claude never interleave.
    @discardableResult
    static func reconcile(configDirectories: [String], scope: Scope, statePath: String,
                          options: Options = Options()) -> Report {
        let folders = folders(configDirectories: configDirectories)
        // One folder syncs nothing, but a copy a check-out holds still goes
        // back once its process is gone (an account removed from the list
        // while a conversation was open on it, or one that became a link).
        guard folders.count > 1 || !State.load(statePath).checkouts.isEmpty else { return Report() }
        let held = lock(statePath, waiting: options.waiting)
        defer { unlock(held) }
        // A process seen to exit holds nothing open, even while its pid still
        // answers and its pid file is left (not yet reaped).
        let sessions = configDirectories.flatMap { ClaudeSessionIndex.liveSessions(configDirectory: $0, isAlive: options.isAlive) }
            .filter { !options.exited.contains($0.pid) }
        let run = Run(folders: folders, state: State.load(statePath), options: options,
                      live: Set(sessions.map(\.sessionId)).union(options.running))
        let before = run.state
        guard folders.count > 1 else {
            _ = checkInEnded(run, sessions: sessions)
            save(run, changedFrom: before, to: statePath)
            return run.report
        }
        // Check-in and check-out come first: a conversation that ended syncs
        // in this run, and one open now counts as running.
        var scope = scope
        scope.sessions.formUnion(settleCheckouts(run, sessions: sessions, statePath: statePath))
        for key in sessionKeys(run, scope: scope) { syncSession(key.slug, key.id, run) }
        syncPlans(run)
        let projects = folders.map { $0 + "/projects" }
        let memory = scope.everything ? memorySlugs(in: projects).union(run.state.memory.keys)
                                      : scope.slugs.union(scope.memory)
        for slug in memory.sorted() where isName(slug) { syncMemory(slug, folders: projects, run) }
        for folder in folders {
            // Every run looks at every plan.
            run.state.roots[folder + "/plans"] = identity(folder + "/plans")
            // A folder's projects/ is recorded only by a run that looked at
            // every conversation: a scoped run would record a folder made
            // again while its conversations' records still name it, and the
            // next full run would read every one it lacks as deleted there.
            // A scoped run forgets an identity that changed, so that full run
            // sees a new folder.
            let projects = folder + "/projects"
            if scope.everything {
                run.state.roots[projects] = identity(projects)
            } else if run.state.roots[projects] != run.rootsNow[projects] {
                run.state.roots[projects] = nil
            }
        }
        save(run, changedFrom: before, to: statePath)
        return run.report
    }

    /// Saves the run's state when it changed.
    private static func save(_ run: Run, changedFrom before: State, to statePath: String) {
        guard run.state != before else { return }
        do { try run.state.save(statePath) } catch {
            run.report.failures.append("could not save \(statePath): \(ClaudeFileError.message(error))")
        }
    }

    private final class Run {
        let folders: [String]
        var state: State
        var report = Report()
        let options: Options
        /// Conversations that run now (pid files, the caller's running ones
        /// and open check-outs): not synced.
        var live: Set<String>
        /// Each folder's projects/ and plans/ as they were when the run began.
        let rootsNow: [String: String]
        /// Older than this, a copy would have gone in Claude Code's cleanup.
        let cutoff: Int64

        init(folders: [String], state: State, options: Options, live: Set<String>) {
            self.folders = folders
            self.state = state
            self.options = options
            self.live = live
            var roots: [String: String] = [:]
            for folder in folders {
                for root in [folder + "/projects", folder + "/plans"] { roots[root] = ClaudeSync.identity(root) }
            }
            rootsNow = roots
            cutoff = Int64((options.now.timeIntervalSince1970 - options.cleanupDays * 86_400) * 1_000_000_000)
        }

        /// The root is the one the last sync saw: a folder made again (or
        /// new) is never read as having deleted anything.
        func sameRoot(_ root: String) -> Bool {
            guard let now = rootsNow[root] else { return false }
            return state.roots[root] == now
        }
    }

    // MARK: Conversations

    private static func sessionKeys(_ run: Run, scope: Scope) -> [(slug: String, id: String)] {
        var keys = Set<String>()
        func wanted(_ slug: String, _ id: String) -> Bool {
            scope.everything || scope.slugs.contains(slug) || scope.sessions.contains(id)
        }
        for folder in run.folders {
            let projects = folder + "/projects"
            let slugs = scope.everything || !scope.sessions.isEmpty
                ? ((try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? [])
                : Array(scope.slugs)
            for slug in slugs where isName(slug) && ClaudeFileIO.isDirectory(projects + "/" + slug) {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: projects + "/" + slug)) ?? []
                where name.hasSuffix(".jsonl") {
                    let id = String(name.dropLast(6))
                    if ClaudeSessionIndex.isSessionId(id), wanted(slug, id) { keys.insert(slug + "/" + id) }
                }
            }
        }
        // Recorded ones too, to see a deletion.
        for key in run.state.sessions.keys {
            if let (slug, id) = split(key), wanted(slug, id) { keys.insert(key) }
        }
        return keys.sorted().compactMap(split)
    }

    private static func split(_ key: String) -> (slug: String, id: String)? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        let slug = String(key[..<slash])
        let id = String(key[key.index(after: slash)...])
        return isName(slug) && ClaudeSessionIndex.isSessionId(id) ? (slug, id) : nil
    }

    static func transcriptPath(_ folder: String, slug: String, id: String) -> String {
        folder + "/projects/" + slug + "/" + id + ".jsonl"
    }

    private static func syncSession(_ slug: String, _ id: String, _ run: Run) {
        let key = slug + "/" + id
        var copies: [(folder: String, stamp: Stamp)] = []
        /// Folders with something other than a file where the transcript goes.
        var blocked = Set<String>()
        for folder in run.folders {
            let path = transcriptPath(folder, slug: slug, id: id)
            if let stamp = stamp(path) { copies.append((folder, stamp)) } else if !isAbsent(path) { blocked.insert(folder) }
        }
        guard !copies.isEmpty else {
            run.state.sessions[key] = nil
            run.state.left["s:" + key] = nil
            run.state.diverged.removeAll { $0 == key }
            return
        }
        // It runs now: its files are being written; it syncs when it ends.
        if run.live.contains(id) {
            run.report.running += 1
            return
        }
        run.report.conversations += 1
        if let size = run.state.left["s:" + key] {
            guard copies.contains(where: { $0.stamp.size != size }) else { return }
            // It went on since: synced again.
            run.state.left["s:" + key] = nil
        }
        let record = run.state.sessions[key]
        if let record {
            let deletedIn = run.folders.filter { folder in
                record.holders.contains(folder) && !copies.contains { $0.folder == folder } && !blocked.contains(folder)
                    && run.sameRoot(folder + "/projects")
            }
            let unchanged = copies.allSatisfy { $0.stamp == Stamp(size: record.size, modified: record.modified) }
            if !deletedIn.isEmpty && unchanged {
                let settled = deleted(id: id, key: "s:" + key, folders: copies.map(\.folder), deletedIn: deletedIn,
                                      stamp: copies[0].stamp, run, paths: { folder in
                                          [transcriptPath(folder, slug: slug, id: id), folder + "/projects/" + slug + "/" + id,
                                           folder + "/file-history/" + id, folder + "/tasks/" + id]
                                      })
                if settled { run.state.sessions[key] = nil }
                return
            }
        }
        let path = { (folder: String) in transcriptPath(folder, slug: slug, id: id) }
        let found = versions(copies, path: path, run)
        let source = found.all[found.primary].head
        // Each version's older copies (byte-prefixes) take its longest.
        for version in found.all {
            for copy in version.older where copy.stamp.size < version.head.stamp.size {
                place(path(version.head.folder), stamp: version.head.stamp, at: path(copy.folder), expect: .file(copy.stamp), run)
            }
        }
        let diverged = found.all.count > 1
        var filled: [String] = []
        for folder in run.folders where !copies.contains(where: { $0.folder == folder }) && !blocked.contains(folder) {
            // Continued on two accounts: a folder that held it and lost it
            // (Claude Code's cleanup there) is not given it again.
            if diverged, record?.holders.contains(folder) == true, run.sameRoot(folder + "/projects") { continue }
            place(path(source.folder), stamp: source.stamp, at: path(folder), expect: .nothing, run)
            filled.append(folder)
        }
        if diverged {
            if !run.state.diverged.contains(key) {
                run.state.diverged.append(key)
                run.report.diverged.append(id)
            }
        } else {
            run.state.diverged.removeAll { $0 == key }
        }
        // The session's own files follow the winning transcript; when it
        // went on on two accounts, each version's folders keep their own.
        for (index, version) in found.all.enumerated() {
            let among = diverged ? version.folders + (index == found.primary ? filled : []) : run.folders
            union("projects/" + slug + "/" + id, winner: version.head.folder, among: among, run)
            union("file-history/" + id, winner: version.head.folder, among: among, run)
            union("tasks/" + id, winner: version.head.folder, among: among, run)
        }
        var holders = run.folders.filter { folder in
            guard let stamp = stamp(path(folder)) else { return false }
            return diverged || stamp.size == source.stamp.size
        }
        if diverged, let record {
            // Kept, so a deletion there is never undone.
            holders += run.folders.filter { folder in
                !holders.contains(folder) && record.holders.contains(folder) && run.sameRoot(folder + "/projects")
            }
        }
        run.state.sessions[key] = State.Unit(size: source.stamp.size, modified: source.stamp.modified, holders: holders)
    }

    /// One version of a conversation: its longest copy and the copies that
    /// are the same or byte-prefixes of it (older copies).
    private struct Version {
        var head: (folder: String, stamp: Stamp)
        var older: [(folder: String, stamp: Stamp)] = []
        var folders: [String] { [head.folder] + older.map(\.folder) }
    }

    /// A conversation's copies by version. One version is the normal case;
    /// more are a conversation continued on two accounts. `primary` is the
    /// version it last ran with: the newest change of a longest copy. A copy
    /// that is a prefix of several versions (where they parted) goes with
    /// that one, else with the longest.
    private static func versions(_ copies: [(folder: String, stamp: Stamp)], path: (String) -> String,
                                 _ run: Run) -> (all: [Version], primary: Int) {
        let order = Dictionary(uniqueKeysWithValues: run.folders.enumerated().map { ($1, $0) })
        let sorted = copies.sorted { a, b in
            if a.stamp.size != b.stamp.size { return a.stamp.size > b.stamp.size }
            if a.stamp.modified != b.stamp.modified { return a.stamp.modified > b.stamp.modified }
            return order[a.folder, default: 0] < order[b.folder, default: 0]
        }
        var all: [Version] = []
        var parts: [(copy: (folder: String, stamp: Stamp), of: [Int])] = []
        for copy in sorted {
            let of = all.indices.filter { index in
                let head = all[index].head
                if copy.stamp == head.stamp { return true }
                return copy.stamp.size == head.stamp.size ? ClaudeFileCopy.identical(path(copy.folder), path(head.folder))
                                                          : ClaudeFileCopy.isStrictPrefix(path(copy.folder), of: path(head.folder))
            }
            if of.isEmpty { all.append(Version(head: copy)) } else { parts.append((copy, of)) }
        }
        // Sorted longest first, so the first newest head is the longest of them.
        let newest = all.map(\.head.stamp.modified).max()!
        let primary = all.firstIndex { $0.head.stamp.modified == newest }!
        for (copy, of) in parts { all[of.contains(primary) ? primary : of[0]].older.append(copy) }
        return (all, primary)
    }

    /// A unit deleted in `deletedIn`: its remaining copies (unchanged since
    /// the last sync) go to the Trash when older than the cleanup period,
    /// else they are left and no longer synced. Returns whether the unit's
    /// record goes (left, or every copy in the Trash).
    private static func deleted(id: String, key: String, folders: [String], deletedIn: [String], stamp: Stamp, _ run: Run,
                                paths: (String) -> [String]) -> Bool {
        guard stamp.modified < run.cutoff else {
            run.state.left[key] = stamp.size
            run.report.left.append("\(id): deleted in \(deletedIn.joined(separator: ", ")); the other copies are recent, so they stay as they are and are no longer synced")
            return true
        }
        var all = true
        for folder in folders {
            for path in paths(folder) where !isAbsent(path) {
                do {
                    try run.options.trash(path)
                    run.report.trashed.append(path)
                } catch {
                    all = false
                    run.report.failures.append("could not move \(path) to the Trash: \(ClaudeFileError.message(error))")
                }
            }
        }
        return all
    }

    /// A union of `relative` (a folder, or a file) across the folders
    /// `among`: .jsonl files by the append-only rule, others with `winner`'s
    /// copy winning (else the newest).
    private static func union(_ relative: String, winner: String, among folders: [String], _ run: Run) {
        var files: [String: [(folder: String, stamp: Stamp)]] = [:]
        /// Relative paths a folder has something other than a file at.
        var blocked: [String: Set<String>] = [:]
        for folder in folders {
            let base = folder + "/" + relative
            var info = stat()
            guard lstat(base, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                if let stamp = stamp(base) { files["", default: []].append((folder, stamp)) }
            case S_IFDIR:
                walk(base, "") { rel, stamp in
                    if let stamp { files[rel, default: []].append((folder, stamp)) } else { blocked[rel, default: []].insert(folder) }
                }
            default:
                blocked["", default: []].insert(folder)
            }
        }
        for (rel, copies) in files.sorted(by: { $0.key < $1.key }) {
            let path = { (folder: String) in folder + "/" + relative + (rel.isEmpty ? "" : "/" + rel) }
            let source: (folder: String, stamp: Stamp)
            let appendOnly = (rel.isEmpty ? relative : rel).hasSuffix(".jsonl")
            if appendOnly {
                source = copies.max { $0.stamp.size != $1.stamp.size ? $0.stamp.size < $1.stamp.size : $0.stamp.modified < $1.stamp.modified }!
            } else if let own = copies.first(where: { $0.folder == winner }) {
                source = own
            } else {
                let newest = copies.map(\.stamp.modified).max()!
                let tied = copies.filter { $0.stamp.modified == newest }
                if tied.count > 1, tied.contains(where: { !ClaudeFileCopy.identical(path($0.folder), path(tied[0].folder)) }) {
                    run.report.skipped.append("\(relative)/\(rel): copies changed at the same time; left alone")
                    continue
                }
                source = tied[0]
            }
            let from = path(source.folder)
            var plan: [(String, Expect)] = []
            var diverged = false
            for folder in folders where folder != source.folder && blocked[rel]?.contains(folder) != true {
                let to = path(folder)
                guard let copy = copies.first(where: { $0.folder == folder }) else {
                    if isAbsent(to) { plan.append((to, .nothing)) }
                    continue
                }
                if copy.stamp == source.stamp || ClaudeFileCopy.identical(to, from) { continue }
                if appendOnly && !ClaudeFileCopy.isStrictPrefix(to, of: from) {
                    diverged = true
                    break
                }
                plan.append((to, .file(copy.stamp)))
            }
            if diverged {
                run.report.skipped.append("\(relative)/\(rel): copies went different ways; left alone")
                continue
            }
            for (to, expect) in plan { place(from, stamp: source.stamp, at: to, expect: expect, run) }
        }
    }

    /// Calls `found` with each regular file under `directory` (relative
    /// path, stamp) and each thing that is not one (nil). Dot names (Brim's
    /// and editors' temporary files) are left out.
    private static func walk(_ directory: String, _ prefix: String, _ found: (String, Stamp?) -> Void) {
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted() where !name.hasPrefix(".") {
            let path = directory + "/" + name
            let relative = prefix.isEmpty ? name : prefix + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: walk(path, relative, found)
            case S_IFREG: found(relative, stamp(path))
            default: found(relative, nil)
            }
        }
    }

    // MARK: Check-out

    /// Where a folder's copy of a conversation waits while the conversation
    /// is open in another folder.
    static func heldPath(_ folder: String, slug: String, id: String) -> String {
        folder + "/projects/" + slug + "/" + checkoutFolder + "/" + id + ".jsonl"
    }

    /// Whether the process a check-out names still holds the conversation
    /// open: it has not been seen to exit and its pid still answers as that
    /// process.
    private static func isOpen(_ record: State.Checkout, _ options: Options) -> Bool {
        !options.exited.contains(record.pid)
            && options.isAlive(record.pid, record.started.map { Date(timeIntervalSince1970: $0) })
    }

    /// The folder of `folders` a running session's config folder writes its
    /// conversations into: itself, or for a folder still linked to
    /// ~/.claude, the folder its projects/ lands in.
    private static func folder(ofConfig config: String, in folders: [String]) -> String? {
        let real = ClaudeFileIO.realPath(config)
        if folders.contains(real) { return real }
        let projects = ClaudeFileIO.realPath(config + "/projects")
        return folders.first { ClaudeFileIO.realPath($0 + "/projects") == projects }
    }

    /// The slugs under which `folder` holds the conversation `id`: the
    /// session's working folder's first, else any (an in-session /resume can
    /// open one from another folder's slug).
    private static func slugs(holding id: String, in folder: String, cwd: String?) -> [String] {
        var hints: [String] = []
        if let cwd {
            for slug in [ClaudeSessionIndex.projectSlug(cwd), ClaudeSessionIndex.projectSlug(ClaudeFileIO.realPath(cwd))]
            where !hints.contains(slug) { hints.append(slug) }
        }
        let hit = hints.filter { isName($0) && stamp(transcriptPath(folder, slug: $0, id: id)) != nil }
        if !hit.isEmpty { return hit }
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder + "/projects")) ?? []).sorted().filter { slug in
            isName(slug) && stamp(transcriptPath(folder, slug: slug, id: id)) != nil
        }
    }

    /// Checks in every conversation whose process is gone, unless another
    /// session has it open in the same folder (open twice there): that one
    /// holds it now. Returns the session ids checked in (they sync in this
    /// run).
    private static func checkInEnded(_ run: Run, sessions: [ClaudeLiveSession]) -> Set<String> {
        var checkedIn = Set<String>()
        for (key, record) in run.state.checkouts.sorted(by: { $0.key < $1.key }) {
            guard let (slug, id) = split(key) else {
                run.state.checkouts[key] = nil
                continue
            }
            if isOpen(record, run.options) { continue }
            let projects = ClaudeFileIO.realPath(record.live + "/projects")
            if let next = sessions.filter({ $0.sessionId == id && ClaudeFileIO.realPath($0.configDirectory + "/projects") == projects })
                .min(by: { $0.pid < $1.pid }) {
                var handed = record
                handed.pid = next.pid
                handed.started = next.startedAt?.timeIntervalSince1970
                handed.config = ClaudeFileIO.realPath(next.configDirectory)
                run.state.checkouts[key] = handed
                continue
            }
            checkIn(slug, id, key: key, record, run)
            checkedIn.insert(id)
        }
        return checkedIn
    }

    /// Checks in what ended (checkInEnded), then checks out every
    /// conversation that runs now in one folder (by one session or several),
    /// and counts the open ones as running. Returns the session ids checked
    /// in (they sync in this run).
    private static func settleCheckouts(_ run: Run, sessions: [ClaudeLiveSession], statePath: String) -> Set<String> {
        let checkedIn = checkInEnded(run, sessions: sessions)
        var byId: [String: [ClaudeLiveSession]] = [:]
        for session in sessions { byId[session.sessionId, default: []].append(session) }
        for (id, running) in byId.sorted(by: { $0.key < $1.key }) where ClaudeSessionIndex.isSessionId(id) {
            // Every session on it writes into one folder (open twice there
            // is one file). Open in two folders (already split), or in one
            // that takes no part: left to the divergence rule.
            let lives = Set(running.map { folder(ofConfig: $0.configDirectory, in: run.folders) ?? "" })
            guard lives.count == 1, let live = lives.first, !live.isEmpty else { continue }
            let ordered = running.sorted { $0.pid < $1.pid }
            var found: [String] = []
            for session in ordered {
                for slug in slugs(holding: id, in: live, cwd: session.cwd) where !found.contains(slug) { found.append(slug) }
            }
            for slug in found {
                let key = slug + "/" + id
                // Open in another folder by a process that still runs: it
                // runs in two folders.
                if let record = run.state.checkouts[key], record.live != live { continue }
                checkOut(slug, id, key: key, session: ordered[0], live: live, run, statePath: statePath)
            }
        }
        for (id, open) in openNow(run.state, run.options) {
            run.live.insert(id)
            run.report.open[id] = open
        }
        return checkedIn
    }

    /// The conversations the state's check-outs hold open now, by session id.
    private static func openNow(_ state: State, _ options: Options) -> [String: Open] {
        var open: [String: Open] = [:]
        for (key, record) in state.checkouts where isOpen(record, options) {
            guard let (_, id) = split(key) else { continue }
            open[id] = Open(config: record.config ?? record.live, pid: record.pid,
                            started: record.started.map { Date(timeIntervalSince1970: $0) })
        }
        return open
    }

    /// What the check-outs recorded at `statePath` hold open now, read
    /// without the lock and without changing anything (brim-claude, before
    /// it picks a conversation; the app's menu).
    static func openCheckouts(statePath: String, isAlive: @escaping ClaudeProcessProbe) -> [String: Open] {
        var options = Options()
        options.isAlive = isAlive
        return openNow(State.load(statePath), options)
    }

    /// Moves every copy of the conversation in another folder that is the
    /// same as, or a byte-prefix of, the open folder's into that folder's
    /// .brim-checked-out, recording it first.
    private static func checkOut(_ slug: String, _ id: String, key: String, session: ClaudeLiveSession, live: String,
                                 _ run: Run, statePath: String) {
        let source = transcriptPath(live, slug: slug, id: id)
        guard let sourceStamp = stamp(source) else { return }
        var record = run.state.checkouts[key]
            ?? State.Checkout(live: live, pid: session.pid, started: session.startedAt?.timeIntervalSince1970,
                              config: ClaudeFileIO.realPath(session.configDirectory))
        var moving: [String] = []
        for folder in run.folders where folder != live {
            let slot = transcriptPath(folder, slug: slug, id: id)
            // A folder recorded as held whose copy is still in place: a run
            // that stopped between the record and the move; this finishes it.
            if record.held.contains(folder) && !isAbsent(heldPath(folder, slug: slug, id: id)) { continue }
            guard let slotStamp = stamp(slot), record.left?[folder] != slotStamp else { continue }
            if slotStamp == sourceStamp || ClaudeFileCopy.identical(slot, source) || ClaudeFileCopy.isStrictPrefix(slot, of: source) {
                moving.append(folder)
            } else {
                record.left = (record.left ?? [:]).merging([folder: slotStamp]) { _, new in new }
            }
        }
        guard !moving.isEmpty else {
            if run.state.checkouts[key] != nil || record.left != nil { run.state.checkouts[key] = record }
            return
        }
        let before = run.state.checkouts[key]
        record.held += moving.filter { !record.held.contains($0) }
        run.state.checkouts[key] = record
        // Recorded before anything moves: a run that stops part way leaves a
        // record the next run finishes (or undoes once the session ended).
        do { try run.state.save(statePath) } catch {
            run.state.checkouts[key] = before
            run.report.failures.append("could not record the check-out of \(shortId(id)) in \(statePath), so its copies stay in view: \(ClaudeFileError.message(error))")
            return
        }
        for folder in moving {
            let slot = transcriptPath(folder, slug: slug, id: id)
            let held = heldPath(folder, slug: slug, id: id)
            do {
                try FileManager.default.createDirectory(atPath: (held as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                // A copy left there by a check-out that never ended (a record
                // lost): every byte of it is in the copy now in place, or it
                // goes to the Trash.
                if !isAbsent(held) { try setAside(held, against: slot, run) }
                guard rename(slot, held) == 0 else { throw ClaudeFileError.posix("move \(slot) to \(held)", errno) }
                run.report.checkedOut.append(slot)
            } catch {
                run.report.failures.append("could not check out \(slot): \(ClaudeFileError.message(error))")
            }
        }
    }

    /// Puts each held copy back in place, or, where the place filled
    /// meanwhile, removes it when every byte of it is in the copy there and
    /// sends it to the Trash otherwise. The record goes once nothing is held.
    private static func checkIn(_ slug: String, _ id: String, key: String, _ record: State.Checkout, _ run: Run) {
        var remaining: [String] = []
        for folder in record.held {
            let slot = transcriptPath(folder, slug: slug, id: id)
            let held = heldPath(folder, slug: slug, id: id)
            guard !isAbsent(held) else { continue }
            if !putBack(held, at: slot, run) { remaining.append(folder) }
            // Only when empty.
            rmdir((held as NSString).deletingLastPathComponent)
        }
        if remaining.isEmpty {
            run.state.checkouts[key] = nil
        } else {
            var left = record
            left.held = remaining
            run.state.checkouts[key] = left
        }
    }

    /// Puts one held copy back in its place, or, where the place filled,
    /// sets it aside (setAside). Returns whether it is out of the dot folder.
    private static func putBack(_ held: String, at slot: String, _ run: Run) -> Bool {
        do {
            if isAbsent(slot) {
                guard rename(held, slot) == 0 else { throw ClaudeFileError.posix("move \(held) back to \(slot)", errno) }
            } else {
                try setAside(held, against: slot, run)
            }
            run.report.checkedIn.append(slot)
            return true
        } catch {
            run.report.failures.append("could not check in \(held): \(ClaudeFileError.message(error))")
            return false
        }
    }

    /// Puts every held copy back in view, whatever holds it open, for the
    /// uninstall: with Brim gone nothing would ever check one in, and Claude
    /// Code never lists it. Each record's copies first, then any held copy
    /// left without one (a record lost) in a projects/<slug>/.brim-checked-out
    /// of `configDirectories` or a folder a record names: each goes back in
    /// place, or is set aside where the place filled (setAside: removed when
    /// every byte of it is there, else to the Trash). Holds the sync lock
    /// when the state folder exists (it never makes one).
    static func checkInEverything(configDirectories: [String], statePath: String,
                                  trash: @escaping (String) throws -> Void = ClaudeSync.trashItem) -> Report {
        let held = ClaudeFileIO.isDirectory((statePath as NSString).deletingLastPathComponent) ? lock(statePath) : -1
        defer { unlock(held) }
        let run = Run(folders: [], state: State.load(statePath), options: Options(trash: trash), live: [])
        let before = run.state
        var places = configDirectories
        for (key, record) in run.state.checkouts.sorted(by: { $0.key < $1.key }) {
            places += [record.live] + record.held
            guard let (slug, id) = split(key) else {
                run.state.checkouts[key] = nil
                continue
            }
            checkIn(slug, id, key: key, record, run)
        }
        var seen = Set<String>()
        for place in places {
            let projects = ClaudeFileIO.realPath(place + "/projects")
            guard seen.insert(projects).inserted else { continue }
            for slug in ((try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? []).sorted() where isName(slug) {
                let folder = projects + "/" + slug + "/" + checkoutFolder
                for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
                where name.hasSuffix(".jsonl") && ClaudeSessionIndex.isSessionId(String(name.dropLast(6))) {
                    guard stamp(folder + "/" + name) != nil else { continue }
                    _ = putBack(folder + "/" + name, at: projects + "/" + slug + "/" + name, run)
                }
                // Only when empty.
                rmdir(folder)
            }
        }
        save(run, changedFrom: before, to: statePath)
        return run.report
    }

    /// Removes the held copy `held` when every byte of it is in `slot` (the
    /// same or a byte-prefix of it), else moves it to the Trash: never a
    /// byte lost.
    private static func setAside(_ held: String, against slot: String, _ run: Run) throws {
        if stamp(slot) != nil && (ClaudeFileCopy.identical(held, slot) || ClaudeFileCopy.isStrictPrefix(held, of: slot)) {
            guard unlink(held) == 0 else { throw ClaudeFileError.posix("remove \(held)", errno) }
            return
        }
        try run.options.trash(held)
        run.report.trashed.append(held)
        run.report.kept.append("\(held): a held copy that differs from \(slot); moved to the Trash")
    }

    // MARK: Plans

    private static func syncPlans(_ run: Run) {
        var names = Set(run.state.plans.keys)
        for folder in run.folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder + "/plans")) ?? []
            where !skipsName(name) && stamp(folder + "/plans/" + name) != nil {
                names.insert(name)
            }
        }
        for name in names.sorted() where isName(name) {
            let path = { (folder: String) in folder + "/plans/" + name }
            var copies: [(folder: String, stamp: Stamp)] = []
            var blocked = Set<String>()
            for folder in run.folders {
                if let stamp = stamp(path(folder)) { copies.append((folder, stamp)) } else if !isAbsent(path(folder)) { blocked.insert(folder) }
            }
            guard !copies.isEmpty else {
                run.state.plans[name] = nil
                run.state.left["p:" + name] = nil
                continue
            }
            if let size = run.state.left["p:" + name] {
                guard copies.contains(where: { $0.stamp.size != size }) else { continue }
                run.state.left["p:" + name] = nil
            }
            let record = run.state.plans[name]
            let recorded = record.map { Stamp(size: $0.size, modified: $0.modified) }
            if let record {
                let deletedIn = run.folders.filter { folder in
                    record.holders.contains(folder) && !copies.contains { $0.folder == folder } && !blocked.contains(folder)
                        && run.sameRoot(folder + "/plans")
                }
                if !deletedIn.isEmpty && copies.allSatisfy({ $0.stamp == recorded }) {
                    if deleted(id: "plans/" + name, key: "p:" + name, folders: copies.map(\.folder), deletedIn: deletedIn,
                               stamp: copies[0].stamp, run, paths: { [path($0)] }) {
                        run.state.plans[name] = nil
                    }
                    continue
                }
            }
            let newest = copies.map(\.stamp.modified).max()!
            let tied = copies.filter { $0.stamp.modified == newest }
            if tied.contains(where: { !ClaudeFileCopy.identical(path($0.folder), path(tied[0].folder)) }) {
                run.report.skipped.append("plans/\(name): copies changed at the same time; left alone")
                continue
            }
            let winner = tied[0]
            for folder in run.folders where folder != winner.folder && !blocked.contains(folder) {
                let to = path(folder)
                guard let copy = copies.first(where: { $0.folder == folder }) else {
                    place(path(winner.folder), stamp: winner.stamp, at: to, expect: .nothing, run)
                    continue
                }
                if copy.stamp == winner.stamp || ClaudeFileCopy.identical(to, path(winner.folder)) { continue }
                // Changed here too since the last sync: kept in the Trash.
                if copy.stamp != recorded {
                    do {
                        try run.options.trash(to)
                        run.report.trashed.append(to)
                        run.report.kept.append("\(to): changed here too, older than \(path(winner.folder)); moved to the Trash before it was replaced")
                    } catch {
                        run.report.failures.append("could not move \(to) to the Trash, so it was not replaced: \(ClaudeFileError.message(error))")
                        continue
                    }
                    place(path(winner.folder), stamp: winner.stamp, at: to, expect: .nothing, run)
                } else {
                    place(path(winner.folder), stamp: winner.stamp, at: to, expect: .file(copy.stamp), run)
                }
            }
            let holders = run.folders.filter { stamp(path($0))?.size == winner.stamp.size }
            run.state.plans[name] = State.Unit(size: winner.stamp.size, modified: winner.stamp.modified, holders: holders)
        }
    }

    // MARK: Memory

    /// Every slug with a memory/ folder in any of `projects` (projects/ folders).
    static func memorySlugs(in projects: [String]) -> Set<String> {
        var slugs = Set<String>()
        for folder in projects {
            for slug in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            where !slug.hasPrefix(".") && ClaudeFileIO.isDirectory(folder + "/" + slug + "/memory") {
                slugs.insert(slug)
            }
        }
        return slugs
    }

    /// Whether a file name is one sync leaves alone: dotfiles, editor and
    /// temporary names.
    static func skipsName(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasSuffix("~") || name.hasSuffix(".tmp") || name.contains(".tmp.")
            || name.hasSuffix(".swp") || name.hasPrefix("#")
    }

    struct MemoryCopy: Equatable {
        var path: String
        var stamp: Stamp
        var hash: String
    }

    /// What one projects/ folder holds of a slug's memory.
    struct MemoryListing: Equatable {
        /// The files sync covers, by relative path.
        var copies: [String: MemoryCopy] = [:]
        /// Relative paths that are there but left out (a link, over 1 MB,
        /// unreadable): never read as deleted, never written over.
        var skipped: Set<String> = []
        /// The memory folder's identity; nil when it is missing, a link or
        /// cannot be listed (the folder then takes no part in deletions).
        var identity: String?
    }

    /// The files under <projects>/<slug>/memory that sync covers.
    static func memoryListing(projects: String, slug: String, report skipped: inout [String]) -> MemoryListing {
        let root = projects + "/" + slug + "/memory"
        var listing = MemoryListing()
        guard let identity = identity(root), let top = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return listing
        }
        listing.identity = identity
        func walk(_ directory: String, _ prefix: String, _ names: [String]) {
            for name in names.sorted() {
                let path = directory + "/" + name
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                if skipsName(name) { continue }
                if ClaudeFileIO.isSymlink(path) {
                    skipped.append("\(path): a link")
                    listing.skipped.insert(relative)
                    continue
                }
                if ClaudeFileIO.isDirectory(path) {
                    walk(path, relative, (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
                    continue
                }
                guard let stamp = stamp(path) else {
                    listing.skipped.insert(relative)
                    continue
                }
                if stamp.size > memorySizeLimit {
                    skipped.append("\(path): over 1 MB")
                    listing.skipped.insert(relative)
                    continue
                }
                guard let data = FileManager.default.contents(atPath: path) else {
                    skipped.append("\(path): could not be read")
                    listing.skipped.insert(relative)
                    continue
                }
                listing.copies[relative] = MemoryCopy(path: path, stamp: stamp, hash: hash(data))
            }
        }
        walk(root, "", top)
        return listing
    }

    private static func syncMemory(_ slug: String, folders: [String], _ run: Run) {
        var record = run.state.memory[slug] ?? State.Memory()
        var present: [String: MemoryListing] = [:]
        for folder in folders { present[folder] = memoryListing(projects: folder, slug: slug, report: &run.report.skipped) }
        let paths = Set(present.values.flatMap(\.copies.keys)).union(record.files.keys)
        for relative in paths.sorted() {
            let copies = folders.compactMap { folder in present[folder]?.copies[relative].map { (folder, $0) } }
            guard !copies.isEmpty else {
                record.files[relative] = nil
                continue
            }
            let recorded = record.files[relative]
            // Deleted: gone from a folder whose memory folder is the one the
            // last sync saw, with nothing left at the path, while every
            // remaining copy still holds what that sync wrote.
            let deletedIn = folders.filter { folder in
                guard let listing = present[folder], let identity = listing.identity,
                      record.folders[folder] == identity, listing.copies[relative] == nil,
                      !listing.skipped.contains(relative) else { return false }
                return isAbsent(folder + "/" + slug + "/memory/" + relative)
            }
            if let recorded, !deletedIn.isEmpty, copies.allSatisfy({ $0.1.hash == recorded }) {
                var all = true
                for (_, copy) in copies {
                    do {
                        try run.options.trash(copy.path)
                        run.report.trashed.append(copy.path)
                    } catch {
                        all = false
                        run.report.failures.append("could not move \(copy.path) to the Trash: \(ClaudeFileError.message(error))")
                    }
                }
                if all { record.files[relative] = nil }
                continue
            }
            let newest = copies.map(\.1.stamp.modified).max()!
            let winners = copies.filter { $0.1.stamp.modified == newest }
            if Set(winners.map(\.1.hash)).count > 1 {
                run.report.skipped.append("\(slug)/memory/\(relative): copies changed at the same time; left alone")
                continue
            }
            let winner = winners[0].1
            // A folder that left the path out (a link, over 1 MB, unreadable)
            // keeps what it has, and the path stays unrecorded: no deletion
            // is ever read from it.
            var complete = !folders.contains { present[$0]?.skipped.contains(relative) == true }
            for folder in folders where present[folder]?.copies[relative]?.hash != winner.hash
                && present[folder]?.skipped.contains(relative) != true {
                let destination = folder + "/" + slug + "/memory/" + relative
                var expected = present[folder]?.copies[relative]
                if expected == nil, !isAbsent(destination) {
                    complete = false
                    run.report.skipped.append("\(destination): something other than a file is there; left alone")
                    continue
                }
                // Changed since the last sync (or never synced) and older than
                // the winner: an edit of its own, kept in the Trash.
                if let loser = expected, loser.hash != recorded {
                    guard stamp(loser.path) == loser.stamp,
                          FileManager.default.contents(atPath: loser.path).map(hash) == loser.hash else {
                        complete = false
                        run.report.skipped.append("\(destination): it changed during the sync; the next run takes it")
                        continue
                    }
                    do {
                        try run.options.trash(loser.path)
                        run.report.trashed.append(loser.path)
                        run.report.kept.append("\(loser.path): changed here too, older than \(winner.path); moved to the Trash before it was replaced")
                        expected = nil
                    } catch {
                        complete = false
                        run.report.failures.append("could not move \(loser.path) to the Trash, so it was not replaced: \(ClaudeFileError.message(error))")
                        continue
                    }
                }
                if !place(winner.path, stamp: winner.stamp, hash: winner.hash, at: destination,
                          expect: expected.map { .file($0.stamp) } ?? .nothing, run) {
                    complete = false
                }
            }
            // A copy that could not be written leaves the path unrecorded:
            // the next run unions it again instead of reading the gap as a
            // deletion.
            record.files[relative] = complete ? winner.hash : nil
        }
        // The folders that took part, with their memory folder as it is now
        // (after this run made any that were missing).
        record.folders = [:]
        for folder in folders {
            if let identity = identity(folder + "/" + slug + "/memory") { record.folders[folder] = identity }
        }
        run.state.memory[slug] = record.files.isEmpty ? nil : record
    }

    // MARK: Writing

    enum Expect: Equatable {
        /// Nothing is at the destination.
        case nothing
        /// The destination is still the file as read.
        case file(Stamp)
    }

    /// Clones `source` (read as `stamp`, and `hash` when given) to
    /// `destination` through a dot-named file beside it and a rename, unless
    /// the destination is no longer what `expect` says (the next run takes
    /// it) or the source changed. Missing folders are made with mode 0700.
    /// Records the outcome in the report; returns whether it wrote.
    @discardableResult
    private static func place(_ source: String, stamp: Stamp, hash: String? = nil, at destination: String,
                              expect: Expect, _ run: Run) -> Bool {
        do {
            try place(source, stamp: stamp, hash: hash, at: destination, expect: expect, beforeWrite: run.options.beforeWrite)
            run.report.copied.append(destination)
            return true
        } catch ClaudeFileError.posix(_, EAGAIN) {
            run.report.skipped.append("\(destination): it or its source changed during the sync; the next run takes it")
        } catch {
            run.report.failures.append("\(destination): \(ClaudeFileError.message(error))")
        }
        return false
    }

    static func place(_ source: String, stamp expected: Stamp, hash: String? = nil, at destination: String,
                      expect: Expect, beforeWrite: (String) -> Void = { _ in }) throws {
        let folder = (destination as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = folder + "/." + (destination as NSString).lastPathComponent
            + ".brim-sync-\(getpid())-\(UInt32.random(in: 0 ... .max))"
        // COPYFILE_CLONE clones on APFS (no extra disk) and copies the bytes
        // where the volume cannot clone; it keeps the dates and mode.
        guard copyfile(source, temporary, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
            throw ClaudeFileError.posix("copy \(source)", errno)
        }
        // The source as it was read: a clone of other bytes would carry them.
        guard Self.stamp(temporary)?.size == expected.size,
              hash == nil || FileManager.default.contents(atPath: temporary).map(Self.hash) == hash else {
            unlink(temporary)
            throw ClaudeFileError.posix("copy \(source)", EAGAIN)
        }
        beforeWrite(destination)
        let unchanged: Bool
        switch expect {
        case .nothing: unchanged = isAbsent(destination)
        case .file(let stamp): unchanged = Self.stamp(destination) == stamp
        }
        guard unchanged else {
            unlink(temporary)
            throw ClaudeFileError.posix("write \(destination)", EAGAIN)
        }
        guard rename(temporary, destination) == 0 else {
            let failure = ClaudeFileError.posix("rename \(destination)", errno)
            unlink(temporary)
            throw failure
        }
    }

    // MARK: Files

    /// A regular file's size and modification; nil for anything else.
    static func stamp(_ path: String) -> Stamp? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Stamp(size: Int64(info.st_size),
                     modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))
    }

    /// A real folder's device, inode and birth time; nil for anything else.
    /// A folder deleted and made again at the same path has another.
    static func identity(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec).\(info.st_birthtimespec.tv_nsec)"
    }

    /// Nothing at all is at `path`: lstat fails with ENOENT.
    static func isAbsent(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) != 0 && errno == ENOENT
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The Trash, recoverable; never an unlink.
    static func trashItem(_ path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    private static func isName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".." && !name.hasPrefix(".")
    }

    /// The sync's exclusive lock on <state>.lock, which every run holds (and
    /// a migration while it swaps a folder's entry): `waiting` runs first when
    /// another holds it, then this waits (a blocking flock the kernel wakes;
    /// nothing polls). -1 when it cannot be opened (the run goes on: the
    /// per-file checks still hold).
    static func lock(_ statePath: String, waiting: () -> Void = {}) -> Int32 {
        try? FileManager.default.createDirectory(atPath: (statePath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(statePath + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return -1 }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            waiting()
            flock(descriptor, LOCK_EX)
        }
        return descriptor
    }

    static func unlock(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// Which conversations run now, by process: the app's side
    /// (ClaudeSyncWatcher). A conversation ends when its process exits, never
    /// when its pid file goes: Claude Code removes sessions/<pid>.json at the
    /// start of its shutdown and writes the transcript's last rows after it
    /// (it flushes queued rows and appends the session's metadata again,
    /// 2.1.325). A /resume inside a session rewrites the file to the new
    /// conversation; the one it left ends with the process too, which writes
    /// its exit lines to it.
    struct RunningSessions: Equatable {
        /// pid -> every conversation the process ran while watched.
        private(set) var byProcess: [Int32: Set<String>] = [:]

        var ids: Set<String> { Set(byProcess.values.joined()) }

        /// Takes the pid files read now (`live`: pid -> session id) and the
        /// processes known to have exited; returns the conversations that
        /// ended (no process runs them any more).
        mutating func update(live: [Int32: String], exited: Set<Int32> = [], isAlive: (Int32) -> Bool) -> Set<String> {
            for (pid, id) in live where !exited.contains(pid) { byProcess[pid, default: []].insert(id) }
            var ended = Set<String>()
            for (pid, ids) in byProcess where exited.contains(pid) || (live[pid] == nil && !isAlive(pid)) {
                ended.formUnion(ids)
                byProcess[pid] = nil
            }
            return ended.subtracting(self.ids)
        }
    }
}
