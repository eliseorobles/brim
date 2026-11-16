// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// What tidying one duplicate folder does before it goes.
struct ClaudeTidyFolder: Equatable {
    var folder: String
    /// Files its conversations add to the kept account's folder.
    var copies: [ClaudeFolderMerge.Copy] = []
    /// Files the kept account's folder already has.
    var identical = 0
    /// history.jsonl lines the kept account's one lacks.
    var historyLines = 0
}

struct ClaudeTidyPlan: Equatable {
    /// The account the duplicates belong to, which stays (its folder).
    var keep: String
    var folders: [ClaudeTidyFolder]
    /// What stops the whole change; nothing runs while there is one.
    var problems: [String]
    /// The plan in words, read before "Make these changes".
    var lines: [String]

    var canRun: Bool { problems.isEmpty && !folders.isEmpty }
}

struct ClaudeTidyReport: Equatable {
    var lines: [String]
    var refused: Bool
    var failures: Int
    /// Folders moved to the Trash, to drop from the list.
    var removed: [String]
}

/// Removes an account's duplicate folders: other folders signed in to the
/// same account that are no account's. For each, in order: its
/// conversations, plans, tasks, file history and prompt history go into the
/// kept account's own config folder (~/.claude for the default account; each
/// account keeps its own conversations, ClaudeOwnFolders) with
/// ClaudeFileCopy's merge (never over a file, an older copy of a transcript
/// replaced); `claude auth logout` runs under that folder's environment so Claude
/// Code removes its own stored sign-in; the folder moves to the Trash, where
/// it can be recovered. Never the default folder, never a folder a Claude
/// Code session runs on. Planning only reads; the executor plans again and
/// refuses while anything blocks. Logging out and the Trash are handed in
/// (the app runs Claude Code; tests pass stand-ins).
enum ClaudeTidyUp {
    /// The account the duplicates belong to, and the folders to tidy.
    /// `listed` names the accounts in the person's list: a duplicate whose
    /// folder name matches none of them may be meant for an email not added
    /// yet, and the plan says so.
    static func plan(keep: ClaudeAccount, duplicates: [ClaudeAccount], home: String, listed: [String] = [],
                     isAlive: ClaudeProcessProbe = ClaudeSessionIndex.processIsAlive) -> ClaudeTidyPlan {
        let keepConfig = keep.configDirectory(home: home)
        let keepName = keep.isDefault ? "~/.claude, the default folder" : keep.folder
        var lines = ["Tidy up the folders signed in to the same account as \(keep.label), which stays in \(keepName)."]
        var problems: [String] = []
        var folders: [ClaudeTidyFolder] = []
        if duplicates.isEmpty { lines.append("No duplicate folders.") }
        for duplicate in duplicates {
            lines.append("")
            if duplicate.isDefault {
                let problem = "~/.claude is the default folder; Brim never removes it"
                problems.append(problem)
                lines.append("~/.claude: BLOCKED: \(problem)")
                continue
            }
            let folder = duplicate.folder
            lines.append("\(folder):")
            if !listed.isEmpty, !listed.contains(where: { ClaudeAccountList.nameMatch(folder: folder, label: $0) != nil }) {
                lines.append("  Its name matches no account in the list. If it is meant for an email you have not added, add that first: Add account reuses it.")
            }
            if let problem = ClaudeLaunchEnvironment.folderProblem(folder, home: home)?.message
                ?? (ClaudeFileIO.isSymlink(folder) || !ClaudeFileIO.isDirectory(folder) ? "it is not a folder of its own" : nil) {
                problems.append("\(folder): \(problem)")
                lines.append("  BLOCKED: \(problem)")
                continue
            }
            let live = ClaudeSessionIndex.liveSessions(configDirectory: folder, isAlive: isAlive)
            if !live.isEmpty {
                let names = live.map(ClaudeSessionIndex.describe).joined(separator: "; ")
                let problem = "\(live.count == 1 ? "a Claude Code session runs" : "\(live.count) Claude Code sessions run") on it: \(names); end \(live.count == 1 ? "it" : "them") with /exit first"
                problems.append("\(folder): \(problem)")
                lines.append("  BLOCKED: \(problem)")
            }
            let merge = mergePlan(folder: folder, into: keepConfig)
            folders.append(merge.tidy)
            lines += merge.lines.map { "  " + $0 }
            // `claude auth logout` revokes the folder's stored sign-in at
            // Anthropic before it clears it (Claude Code 2.1.325), which no
            // Trash brings back; that the other folders stay signed in is not
            // verified yet (ticket T-25).
            lines.append("  Sign out: run `claude auth logout` on this folder. Claude Code revokes this folder's sign-in at Anthropic and removes it here; that cannot be undone.")
            lines.append("  Not verified yet: that the other folders on this account stay signed in.")
            let own = ownEntries(folder: folder)
            if !own.isEmpty {
                let shown = own.prefix(12).joined(separator: ", ") + (own.count > 12 ? " and \(own.count - 12) more" : "")
                lines.append("  Not merged, so it goes to the Trash with the folder: \(shown).")
            }
            lines.append("  Move the folder to the Trash (recoverable) and drop it from Brim's list.")
        }
        if !problems.isEmpty { folders = [] }
        return ClaudeTidyPlan(keep: keep.folder, folders: folders, problems: problems, lines: lines)
    }

    /// The folder's own entries that the merge leaves (its settings,
    /// CLAUDE.md, skills, MCP servers in its .claude.json, caches), sorted:
    /// they go to the Trash with it. Links (the shared setup's) are not its own.
    static func ownEntries(folder: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { name in
            name != ".DS_Store" && !ClaudeOwnFolders.entries.contains(name)
                && !ClaudeSetupSharing.mergedLineFiles.contains(name) && !ClaudeFileIO.isSymlink(folder + "/" + name)
        }.sorted()
    }

    /// What merging one folder's conversations into `keepConfig` (the kept
    /// account's config folder) copies, in words. An entry of the kept
    /// folder that is still linked to ~/.claude takes the copies there,
    /// through the link.
    static func mergePlan(folder: String, into keepConfig: String) -> (tidy: ClaudeTidyFolder, lines: [String]) {
        var tidy = ClaudeTidyFolder(folder: folder)
        var lines: [String] = []
        let tag = ClaudeFileCopy.folderTag(folder)
        for name in ClaudeOwnFolders.entries.sorted() {
            let own = folder + "/" + name
            let kept = keepConfig + "/" + name
            if ClaudeFileIO.isSymlink(own) {
                lines.append("\(name): a link to the shared one; nothing of its own")
                continue
            }
            guard ClaudeFileIO.isDirectory(own) else { continue }
            guard !ClaudeFileIO.exists(kept) || ClaudeFileIO.isDirectory(kept, followingLinks: true) else {
                lines.append("\(name): \(kept) is not a folder; this folder's copy goes to the Trash with it")
                continue
            }
            let merge = ClaudeFileCopy.plan(from: own, into: kept, tag: tag)
            tidy.copies += merge.copies
            tidy.identical += merge.identical
            lines.append("\(name): " + (merge.isEmpty && merge.identical == 0 ? "nothing to copy"
                                                                               : ClaudeFileCopy.describe(merge) + " into \(kept)"))
        }
        for name in ClaudeSetupSharing.mergedLineFiles.sorted() {
            let own = folder + "/" + name
            guard ClaudeFileIO.isRegularFile(own) else { continue }
            let kept = ClaudeFileIO.realPath(keepConfig + "/" + name)
            let added = ClaudeSetupSharing.historyMerge(shared: ClaudeFileIO.read(kept, limit: .max) ?? Data(),
                                                        own: ClaudeFileIO.read(own, limit: .max) ?? Data()).added
            tidy.historyLines += added
            lines.append("\(name): " + (added > 0 ? "add \(added) line(s) to \(keepConfig)/\(name) by time, duplicates dropped"
                                                  : "nothing to add"))
        }
        return (tidy, lines)
    }

    /// Plans again and tidies folder by folder: merge, then log out, then the
    /// Trash. A folder whose merge or logout fails stays where it is, and a
    /// folder Claude Code did not sign out (its .claude.json still names an
    /// account) is never moved. `logout` returns nil when Claude Code signed
    /// the folder out, else why not; `trash` returns where the folder went.
    static func execute(keep: ClaudeAccount, duplicates: [ClaudeAccount], home: String,
                        isAlive: ClaudeProcessProbe = ClaudeSessionIndex.processIsAlive,
                        logout: (String) -> String?, trash: (String) throws -> String) -> ClaudeTidyReport {
        let current = plan(keep: keep, duplicates: duplicates, home: home, isAlive: isAlive)
        guard current.canRun else {
            return ClaudeTidyReport(lines: ["Refused; nothing was changed."] + current.problems.map { "BLOCKED: \($0)" },
                                    refused: true, failures: 0, removed: [])
        }
        let keepConfig = keep.configDirectory(home: home)
        var lines: [String] = []
        var failures = 0
        var removed: [String] = []
        for planned in current.folders {
            let folder = planned.folder
            // Never the default folder, whatever the plan said.
            guard !folder.isEmpty else { continue }
            do {
                // Planned again now: the kept folder keeps changing.
                let fresh = mergePlan(folder: folder, into: keepConfig).tidy
                try ClaudeFileCopy.apply(ClaudeFolderMerge(copies: fresh.copies, identical: fresh.identical))
                for name in ClaudeSetupSharing.mergedLineFiles.sorted() where ClaudeFileIO.isRegularFile(folder + "/" + name) {
                    try ClaudeSetupSharing.mergeHistory(own: folder + "/" + name, into: keepConfig + "/" + name)
                }
                lines.append("\(folder): merged \(fresh.copies.count) file(s) and \(fresh.historyLines) history line(s) into \(keepConfig)")
            } catch {
                failures += 1
                lines.append("\(folder): FAILED to merge (\(ClaudeFileError.message(error))); left in place")
                continue
            }
            if let problem = logout(folder) {
                failures += 1
                lines.append("\(folder): FAILED to sign out (\(problem)); left in place")
                continue
            }
            if ClaudeUsageDecoding.snapshot(configFile: folder + "/.claude.json")?.signedIn == true {
                failures += 1
                lines.append("\(folder): still signed in after `claude auth logout`; left in place")
                continue
            }
            lines.append("\(folder): signed out")
            do {
                let destination = try trash(folder)
                removed.append(folder)
                lines.append("\(folder): moved to the Trash (\(destination))")
            } catch {
                failures += 1
                lines.append("\(folder): FAILED to move to the Trash (\(ClaudeFileError.message(error))); it is signed out and still in place")
            }
        }
        return ClaudeTidyReport(lines: lines, refused: false, failures: failures, removed: removed)
    }
}
