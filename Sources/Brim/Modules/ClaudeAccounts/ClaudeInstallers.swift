// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// What Brim put in place outside its own folders, so Undo takes away
/// exactly that and nothing the person wrote meanwhile. Kept beside
/// accounts.json as installs.json.
struct ClaudeInstallRecord: Codable, Equatable {
    struct Shell: Codable, Equatable {
        /// ~/.local/bin/brim-claude, and whether Brim made it.
        var link: String
        var linkTarget: String
        var linkCreated: Bool
        /// ~/.config/brim/claude.zsh.
        var script: String
        /// The file the line went into (~/.zshrc, or what it links to).
        var rcFile: String
        /// The line Brim added; nil when the file already had it.
        var rcLine: String?
        var rcBackup: String?
        var installedAt: Date
    }

    struct StatusLine: Codable, Equatable {
        /// The shared settings.json (or what it links to).
        var settings: String
        /// The exact text Brim inserted.
        var inserted: String
        /// Brim created the file: Undo deletes it while it holds only that.
        var createdFile: Bool
        var backup: String?
        var installedAt: Date
    }

    var shell: Shell?
    var statusLine: StatusLine?

    static func path(_ paths: ClaudeAccountsPaths) -> String { paths.stateDirectory + "/installs.json" }

    static func load(_ paths: ClaudeAccountsPaths) -> ClaudeInstallRecord {
        guard let data = ClaudeFileIO.read(path(paths), limit: 1 << 20),
              let record = try? ClaudeJSON.decoder().decode(ClaudeInstallRecord.self, from: data) else { return ClaudeInstallRecord() }
        return record
    }

    func save(_ paths: ClaudeAccountsPaths) throws {
        try paths.ensureDirectory(paths.stateDirectory)
        try ClaudeFileIO.writeAtomically(try ClaudeJSON.encoder().encode(self), to: Self.path(paths))
    }
}

/// The result of an install or an undo, in words.
struct ClaudeInstallReport: Equatable {
    var lines: [String]
    /// Refused before changing anything.
    var refused: Bool
    var failures: Int

    var succeeded: Bool { !refused && failures == 0 }

    static func refusal(_ problems: [String]) -> ClaudeInstallReport {
        ClaudeInstallReport(lines: ["Refused; nothing was changed."] + problems.map { "BLOCKED: " + $0 }, refused: true, failures: 0)
    }
}

enum ClaudeInstallFiles {
    /// "<path>.brim-backup-20261112-170512", made free with "-2", "-3", …
    static func backupPath(for path: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = path + ".brim-backup-" + formatter.string(from: now)
        var candidate = base
        var number = 2
        while ClaudeFileIO.exists(candidate) {
            candidate = base + "-\(number)"
            number += 1
        }
        return candidate
    }

    /// A copy of the file beside it, with its mode and dates.
    static func backUp(_ path: String, now: Date) throws -> String {
        let backup = backupPath(for: path, now: now)
        try ClaudeFileCopy.clone(path, to: backup)
        return backup
    }

    static func mode(of path: String, otherwise fallback: mode_t) -> mode_t {
        var info = stat()
        return stat(path, &info) == 0 ? mode_t(info.st_mode & 0o777) : fallback
    }
}

// MARK: - Shell integration

/// "Install shell integration": the helper on PATH, Brim's zsh functions in
/// ~/.config/brim/claude.zsh, and one line in ~/.zshrc that sources them,
/// after the direnv hook so a folder's CLAUDE_CONFIG_DIR is already set.
/// Nothing runs until the person confirms the plan; Undo takes back exactly
/// what the record says Brim did.
enum ClaudeShellIntegration {
    static let line = #"[[ -r "$HOME/.config/brim/claude.zsh" ]] && source "$HOME/.config/brim/claude.zsh"  # Brim: Claude accounts (claude, cc, cx)"#

    static func linkPath(home: String) -> String { home + "/.local/bin/brim-claude" }
    static func scriptPath(home: String) -> String { home + "/.config/brim/claude.zsh" }
    static func rcPath(home: String) -> String { home + "/.zshrc" }

    enum Status: Equatable {
        case notInstalled
        case installed
        /// Some parts are there, others not (or out of date).
        case partial
    }

    /// The zshrc text with `line` after the direnv hook (the first line that
    /// runs `direnv hook zsh`), or at the end when there is none.
    static func inserting(_ line: String, into text: String) -> String {
        guard !text.isEmpty else { return line + "\n" }
        var lines = text.components(separatedBy: "\n")
        let trailingNewline = text.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }
        if let hook = lines.firstIndex(where: { $0.contains("direnv hook zsh") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) {
            lines.insert(line, at: hook + 1)
        } else {
            lines.append(line)
        }
        return lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    /// The text without the line Brim added; nil when the line is not there.
    static func removing(_ line: String, from text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard let index = lines.firstIndex(of: line) else { return nil }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }

    /// `template` is this Brim's copy of the functions: an installed file
    /// with other content is out of date (an older Brim wrote it), so the
    /// status is partial and the install rewrites it.
    static func status(home: String, helper: String, template: Data?) -> Status {
        let link = linkPath(home: home)
        let linked = ClaudeFileIO.isSymlink(link) && ClaudeFileIO.linkDestination(link) == helper
        let path = scriptPath(home: home)
        let script = ClaudeFileIO.isRegularFile(path) && (template == nil || ClaudeFileIO.read(path) == template)
        let rc = ClaudeFileIO.read(ClaudeFileIO.realPath(rcPath(home: home)), limit: 4 << 20)
            .map { String(decoding: $0, as: UTF8.self).components(separatedBy: "\n").contains(line) } ?? false
        switch [linked, script, rc].filter({ $0 }).count {
        case 3: return .installed
        case 0: return ClaudeFileIO.exists(link) ? .partial : .notInstalled
        default: return .partial
        }
    }

    /// What the install would do, in words, and what stops it.
    static func plan(home: String, helper: String, template: Data?) -> (lines: [String], problems: [String]) {
        var lines: [String] = []
        var problems: [String] = []
        let link = linkPath(home: home)
        if !ClaudeFileIO.isRegularFile(helper) {
            problems.append("the helper \(helper) is missing from this copy of Brim")
        }
        if ClaudeFileIO.isSymlink(link) {
            let destination = ClaudeFileIO.linkDestination(link) ?? ""
            if destination == helper {
                lines.append("\(link): already links to this Brim's helper")
            } else if destination.hasSuffix("/Contents/Helpers/brim-claude") {
                lines.append("\(link): link it to \(helper) (it links to another Brim copy, \(destination))")
            } else {
                problems.append("\(link) already exists and links to \(destination), which is not Brim's; remove it first")
            }
        } else if ClaudeFileIO.exists(link) {
            problems.append("\(link) already exists and is not a link to Brim's helper; remove it first")
        } else {
            lines.append("\(link): link to \(helper) (creates \((link as NSString).deletingLastPathComponent) if needed)")
        }
        let script = scriptPath(home: home)
        if template == nil {
            problems.append("the zsh file brim-claude.zsh is missing from this copy of Brim")
        } else if ClaudeFileIO.read(script) == template {
            lines.append("\(script): already up to date")
        } else {
            lines.append("\(script): " + (ClaudeFileIO.exists(script) ? "replace with this Brim's version" : "write the claude, cc and cx functions"))
        }
        let rc = rcPath(home: home)
        let real = ClaudeFileIO.realPath(rc)
        let text = ClaudeFileIO.read(real, limit: 4 << 20).map { String(decoding: $0, as: UTF8.self) }
        if ClaudeFileIO.exists(rc) && text == nil {
            problems.append("\(rc) could not be read")
        } else if let text, text.components(separatedBy: "\n").contains(line) {
            lines.append("\(rc): already sources it")
        } else {
            let place = (text ?? "").contains("direnv hook zsh") ? "after the direnv hook line" : "at the end"
            lines.append("\(rc)\(real == rc ? "" : " (\(real))"): add one line \(place), after a timestamped backup:")
            lines.append("    " + line)
        }
        lines.append("Open a new terminal afterwards. Undo removes the line, the file and the link.")
        return (lines, problems)
    }

    static func install(home: String, helper: String, template: Data?, paths: ClaudeAccountsPaths,
                        now: Date = Date()) -> ClaudeInstallReport {
        let planned = plan(home: home, helper: helper, template: template)
        guard planned.problems.isEmpty, let template else { return .refusal(planned.problems) }
        var record = ClaudeInstallRecord.load(paths)
        var lines: [String] = []
        let link = linkPath(home: home)
        var linkCreated = record.shell?.linkCreated ?? false
        do {
            if ClaudeFileIO.isSymlink(link), ClaudeFileIO.linkDestination(link) != helper {
                guard unlink(link) == 0 else { throw ClaudeFileError.posix("unlink \(link)", errno) }
            }
            if !ClaudeFileIO.exists(link) {
                try FileManager.default.createDirectory(atPath: (link as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                guard symlink(helper, link) == 0 else { throw ClaudeFileError.posix("link \(link)", errno) }
                linkCreated = true
                lines.append("\(link): linked to \(helper)")
            }
            let script = scriptPath(home: home)
            try FileManager.default.createDirectory(atPath: (script as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if ClaudeFileIO.read(script) != template {
                try ClaudeFileIO.writeAtomically(template, to: script, mode: 0o644)
                lines.append("\(script): written")
            }
            let rc = ClaudeFileIO.realPath(rcPath(home: home))
            let existing = ClaudeFileIO.read(rc, limit: 4 << 20).map { String(decoding: $0, as: UTF8.self) }
            var added: String? = record.shell?.rcLine
            var backup: String? = record.shell?.rcBackup
            if !(existing ?? "").components(separatedBy: "\n").contains(line) {
                if existing != nil { backup = try ClaudeInstallFiles.backUp(rc, now: now) }
                let mode = ClaudeInstallFiles.mode(of: rc, otherwise: 0o644)
                try ClaudeFileIO.writeAtomically(Data(inserting(line, into: existing ?? "").utf8), to: rc, mode: mode)
                added = line
                lines.append("\(rc): line added" + (backup.map { "; backup at \($0)" } ?? ""))
            }
            record.shell = ClaudeInstallRecord.Shell(link: link, linkTarget: helper, linkCreated: linkCreated, script: script,
                                                     rcFile: rc, rcLine: added, rcBackup: backup, installedAt: now)
            try record.save(paths)
        } catch {
            lines.append("FAILED: \(error)")
            return ClaudeInstallReport(lines: lines, refused: false, failures: 1)
        }
        if lines.isEmpty { lines.append("Everything was already in place.") }
        lines.append("Open a new terminal to use claude, cc and cx.")
        return ClaudeInstallReport(lines: lines, refused: false, failures: 0)
    }

    static func undoPlan(paths: ClaudeAccountsPaths) -> [String] {
        guard let shell = ClaudeInstallRecord.load(paths).shell else { return ["Brim has not installed the shell integration."] }
        var lines: [String] = []
        if let line = shell.rcLine { lines.append("\(shell.rcFile): remove the line\n    \(line)") }
        lines.append("\(shell.script): delete")
        if shell.linkCreated { lines.append("\(shell.link): remove the link") }
        if let backup = shell.rcBackup { lines.append("The backup \(backup) stays.") }
        lines.append("Open terminals keep the functions until they close.")
        return lines
    }

    static func undo(paths: ClaudeAccountsPaths) -> ClaudeInstallReport {
        var record = ClaudeInstallRecord.load(paths)
        guard let shell = record.shell else { return .refusal(["Brim has not installed the shell integration."]) }
        var lines: [String] = []
        var failures = 0
        if let line = shell.rcLine {
            let text = ClaudeFileIO.read(shell.rcFile, limit: 4 << 20).map { String(decoding: $0, as: UTF8.self) }
            if let text, let removed = removing(line, from: text) {
                do {
                    try ClaudeFileIO.writeAtomically(Data(removed.utf8), to: shell.rcFile,
                                                     mode: ClaudeInstallFiles.mode(of: shell.rcFile, otherwise: 0o644))
                    lines.append("\(shell.rcFile): line removed")
                } catch {
                    failures += 1
                    lines.append("\(shell.rcFile): FAILED to remove the line (\(error))")
                }
            } else {
                lines.append("\(shell.rcFile): the line is no longer there; left alone")
            }
        }
        if ClaudeFileIO.isRegularFile(shell.script) {
            if unlink(shell.script) == 0 { lines.append("\(shell.script): deleted") } else {
                failures += 1
                lines.append("\(shell.script): FAILED to delete (errno \(errno))")
            }
        }
        if shell.linkCreated, ClaudeFileIO.isSymlink(shell.link) {
            if ClaudeFileIO.linkDestination(shell.link) == shell.linkTarget {
                if unlink(shell.link) == 0 { lines.append("\(shell.link): removed") } else {
                    failures += 1
                    lines.append("\(shell.link): FAILED to remove (errno \(errno))")
                }
            } else {
                lines.append("\(shell.link): now links elsewhere; left alone")
            }
        }
        record.shell = nil
        do { try record.save(paths) } catch {
            failures += 1
            lines.append("could not update \(ClaudeInstallRecord.path(paths)): \(error)")
        }
        return ClaudeInstallReport(lines: lines, refused: false, failures: failures)
    }
}

// MARK: - Status line

/// "Install status line": `statusLine {type: "command", command: "<brim-claude>
/// statusline"}` in the shared ~/.claude/settings.json, the live feed of every
/// session's plan windows. Inserted as text after a timestamped backup, so
/// the rest of the file keeps its order and spacing; refused when another
/// status line is set.
enum ClaudeStatusLineInstall {
    static func settingsPath(home: String) -> String { home + "/.claude/settings.json" }

    static func command(helper: String) -> String {
        ClaudeLaunchEnvironment.shellQuote(helper) + " statusline"
    }

    /// A status line Brim set: a command running brim-claude's statusline.
    static func isBrims(_ value: Any?) -> Bool {
        guard let object = ClaudeJSON.object(value), let command = ClaudeJSON.string(object["command"]) else { return false }
        return command.contains("brim-claude") && command.hasSuffix(" statusline")
    }

    enum Status: Equatable {
        case notInstalled
        case installed(command: String)
        /// Another status line is set: Brim leaves it alone.
        case other
    }

    static func status(home: String) -> Status {
        guard let data = ClaudeFileIO.read(ClaudeFileIO.realPath(settingsPath(home: home))),
              let json = ClaudeJSON.parse(data) as? [String: Any], let value = json["statusLine"] else { return .notInstalled }
        if isBrims(value), let command = ClaudeJSON.string(ClaudeJSON.object(value)?["command"]) { return .installed(command: command) }
        return value is NSNull ? .notInstalled : .other
    }

    /// The settings text with the status line first in the object, and the
    /// exact text inserted; nil when the text is not a JSON object.
    static func inserting(command: String, into text: String?) -> (text: String, inserted: String)? {
        let entry: [String: Any] = ["type": "command", "command": command]
        guard let value = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        let pair = "\"statusLine\": " + String(decoding: value, as: UTF8.self)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let inserted = "\n  " + pair + "\n"
            return ("{" + inserted + "}\n", inserted)
        }
        guard let brace = text.firstIndex(where: { !$0.isWhitespace }), text[brace] == "{",
              let original = ClaudeJSON.parse(Data(text.utf8)) as? [String: Any] else { return nil }
        let after = text[text.index(after: brace)...]
        let empty = after.trimmingCharacters(in: .whitespacesAndNewlines) == "}"
        let inserted = "\n  " + pair + (empty ? "\n" : ",")
        let result = String(text[...brace]) + inserted + after
        // The text must still parse, to the same settings plus the status line.
        guard let parsed = ClaudeJSON.parse(Data(result.utf8)) as? [String: Any] else { return nil }
        var expected = original
        expected["statusLine"] = entry
        guard NSDictionary(dictionary: parsed).isEqual(to: expected) else { return nil }
        return (result, inserted)
    }

    static func plan(home: String, helper: String) -> (lines: [String], problems: [String]) {
        let path = settingsPath(home: home)
        let real = ClaudeFileIO.realPath(path)
        let target = command(helper: helper)
        var problems: [String] = []
        var lines: [String] = []
        let text = ClaudeFileIO.read(real).map { String(decoding: $0, as: UTF8.self) }
        if ClaudeFileIO.exists(path), text == nil { problems.append("\(path) could not be read") }
        switch status(home: home) {
        case .other:
            problems.append("\(path) already sets another statusLine; Brim leaves it alone")
        case .installed(let current) where current == target:
            lines.append("\(path): already runs \(target)")
            return (lines, problems)
        case .installed:
            problems.append("\(path) runs an older Brim status line; Undo it first, then install again")
        case .notInstalled:
            if text != nil, inserting(command: target, into: text) == nil {
                problems.append("\(path) is not a JSON object Brim can add to safely")
            }
        }
        if problems.isEmpty {
            lines.append("\(path)\(real == path ? "" : " (\(real))"): add, after a timestamped backup,")
            lines.append("    \"statusLine\": {\"command\": \"\(target)\", \"type\": \"command\"}")
            lines.append("Every Claude Code session on every account then reports its 5-hour and weekly use to Brim as it works, with no extra requests. It shows one short line under the prompt.")
        }
        return (lines, problems)
    }

    static func install(home: String, helper: String, paths: ClaudeAccountsPaths, now: Date = Date()) -> ClaudeInstallReport {
        let planned = plan(home: home, helper: helper)
        guard planned.problems.isEmpty else { return .refusal(planned.problems) }
        guard case .notInstalled = status(home: home) else {
            return ClaudeInstallReport(lines: ["Already installed."], refused: false, failures: 0)
        }
        let real = ClaudeFileIO.realPath(settingsPath(home: home))
        let existing = ClaudeFileIO.read(real).map { String(decoding: $0, as: UTF8.self) }
        guard let edit = inserting(command: command(helper: helper), into: existing) else {
            return .refusal(["\(real) is not a JSON object Brim can add to safely"])
        }
        var record = ClaudeInstallRecord.load(paths)
        do {
            let backup = existing == nil ? nil : try ClaudeInstallFiles.backUp(real, now: now)
            try FileManager.default.createDirectory(atPath: (real as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try ClaudeFileIO.writeAtomically(Data(edit.text.utf8), to: real,
                                             mode: ClaudeInstallFiles.mode(of: real, otherwise: 0o644))
            record.statusLine = ClaudeInstallRecord.StatusLine(settings: real, inserted: edit.inserted,
                                                               createdFile: existing == nil, backup: backup, installedAt: now)
            try record.save(paths)
            return ClaudeInstallReport(lines: ["\(real): statusLine added" + (backup.map { "; backup at \($0)" } ?? ""),
                                               "Sessions pick it up at their next render."],
                                       refused: false, failures: 0)
        } catch {
            return ClaudeInstallReport(lines: ["FAILED: \(error)"], refused: false, failures: 1)
        }
    }

    static func undoPlan(paths: ClaudeAccountsPaths) -> [String] {
        guard let installed = ClaudeInstallRecord.load(paths).statusLine else { return ["Brim has not installed the status line."] }
        return ["\(installed.settings): remove the statusLine Brim added" + (installed.backup.map { "; the backup \($0) stays" } ?? "")]
    }

    static func undo(paths: ClaudeAccountsPaths) -> ClaudeInstallReport {
        var record = ClaudeInstallRecord.load(paths)
        guard let installed = record.statusLine else { return .refusal(["Brim has not installed the status line."]) }
        guard let text = ClaudeFileIO.read(installed.settings).map({ String(decoding: $0, as: UTF8.self) }),
              let range = text.range(of: installed.inserted),
              let current = ClaudeJSON.parse(Data(text.utf8)) as? [String: Any] else {
            return .refusal(["\(installed.settings) no longer holds the status line as Brim added it; edit it by hand"
                             + (installed.backup.map { " or restore \($0)" } ?? "")])
        }
        var result = text
        result.removeSubrange(range)
        var expected = current
        expected["statusLine"] = nil
        let remaining = result.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if installed.createdFile && expected.isEmpty && (remaining == "{}" || remaining == "{\n}") {
                guard unlink(installed.settings) == 0 else { throw ClaudeFileError.posix("delete \(installed.settings)", errno) }
            } else {
                guard let parsed = ClaudeJSON.parse(Data(result.utf8)) as? [String: Any],
                      NSDictionary(dictionary: parsed).isEqual(to: expected) else {
                    return .refusal(["\(installed.settings) changed around the status line; edit it by hand"])
                }
                try ClaudeFileIO.writeAtomically(Data(result.utf8), to: installed.settings,
                                                 mode: ClaudeInstallFiles.mode(of: installed.settings, otherwise: 0o644))
            }
            record.statusLine = nil
            try record.save(paths)
            return ClaudeInstallReport(lines: ["\(installed.settings): statusLine removed"], refused: false, failures: 0)
        } catch {
            return ClaudeInstallReport(lines: ["FAILED: \(error)"], refused: false, failures: 1)
        }
    }
}

// MARK: - Uninstall

/// What Brim put outside its own folders, taken back when Brim itself is
/// uninstalled (SelfUninstall, and `--uninstall`, which Tools/uninstall.sh
/// runs): the status line first, which every session on every account runs,
/// then the shell integration. Each undo removes exactly what installs.json
/// records and leaves alone what changed since. Then every copy of a
/// conversation Brim holds out of Claude Code's view goes back
/// (ClaudeSync.checkInEverything): its records are in the state folder, and
/// with Brim gone nothing would ever put it back. Brim's Claude state folder
/// goes after that, last, since installs.json is in it: the in-app uninstall
/// removes it here (`uninstall`), and Tools/uninstall.sh removes it with the
/// same checks once it has named what the undo left.
enum ClaudeInstallsRemoval {
    /// What happened, in words; nothing when nothing was installed.
    @discardableResult
    static func undoAll(paths: ClaudeAccountsPaths, home: String) -> [String] {
        let record = ClaudeInstallRecord.load(paths)
        var lines: [String] = []
        if record.statusLine != nil { lines += ClaudeStatusLineInstall.undo(paths: paths).lines }
        if record.shell != nil { lines += ClaudeShellIntegration.undo(paths: paths).lines }
        return lines + checkIn(paths: paths, home: home)
    }

    /// Every held copy back in view (ClaudeSync's check-out, T-40), last:
    /// once the shell integration is gone no wrapper launch checks one out
    /// again. The account folders are those accounts.json lists.
    static func checkIn(paths: ClaudeAccountsPaths, home: String) -> [String] {
        let accounts = ClaudeAccountsFile.load(paths)?.accounts ?? []
        let report = ClaudeSync.checkInEverything(configDirectories: ClaudeAccount.configDirectories(home: home, accounts: accounts),
                                                  statePath: ClaudeSync.statePath(paths))
        return report.checkedIn.map { "\($0): back in view (held while its conversation was open on another account)" }
            + report.kept + report.failures.map { "FAILED: " + $0 }
    }

    /// Everything Claude accounts leaves, for the in-app uninstall: what
    /// Brim installed, then its state folder. The order matters: the undo
    /// reads installs.json from the folder.
    @discardableResult
    static func uninstall(environment: [String: String]) -> [String] {
        let home = ClaudeHome.path(environment: environment)
        let paths = ClaudeAccountsPaths(environment: environment, home: home)
        return undoAll(paths: paths, home: home) + removeState(paths: paths, home: home).lines
    }

    /// Deletes Brim's Claude state folder: the accounts list, live readings,
    /// requests, session owners, sign-in links, MCP backups and the install
    /// record. Only a real folder goes, never a link, and only when both its
    /// path and the path it resolves to have the state folder's shape
    /// (`isStateFolder`); anything else is refused and left as it is. The
    /// variant folder above the standard one (~/.config/brim, or brim-dev)
    /// goes as well when that leaves it empty. ~/.config itself never does,
    /// and neither does the folder above a BRIM_CLAUDE_STATE_DIR.
    static func removeState(paths: ClaudeAccountsPaths, home: String) -> ClaudeInstallReport {
        let folder = paths.stateDirectory
        guard ClaudeFileIO.exists(folder) else { return ClaudeInstallReport(lines: [], refused: false, failures: 0) }
        guard isStateFolder(folder, home: home), ClaudeFileIO.isDirectory(folder),
              isStateFolder(ClaudeFileIO.realPath(folder), home: ClaudeFileIO.realPath(home)) else {
            return .refusal(["\(folder) is not a folder Brim keeps its Claude state in; it is left alone"])
        }
        do {
            // Removes links inside it as links: whatever they point at stays.
            try FileManager.default.removeItem(atPath: folder)
        } catch {
            return ClaudeInstallReport(lines: ["FAILED: \(folder): \(error.localizedDescription)"], refused: false, failures: 1)
        }
        var lines = ["\(folder): removed"]
        if folder == ClaudeAccountsPaths(environment: [:], home: home).stateDirectory {
            // rmdir removes only an empty folder, and never a link.
            let variant = (folder as NSString).deletingLastPathComponent
            if rmdir(variant) == 0 { lines.append("\(variant): removed (nothing else was in it)") }
        }
        return ClaudeInstallReport(lines: lines, refused: false, failures: 0)
    }

    /// Whether the path has the shape of Brim's Claude state folder: an
    /// absolute path with no empty, "." or ".." parts, below at least one
    /// folder, whose last part is "claude"; never inside Claude Code's own
    /// folders (~/.claude*), and never the home folder or a folder above it.
    /// Tools/uninstall.sh checks the same (`claude_state_shape`).
    static func isStateFolder(_ path: String, home: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.last == "claude"
            && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasPrefix(".claude") }
            && home != path && !home.hasPrefix(path + "/")
    }
}
