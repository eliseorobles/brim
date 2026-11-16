// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// How the MCP page runs Claude Code's CLI: the one environment every
/// command gets and the loop that runs them, so the app and its tests share
/// one path (build.sh compiles this file into the tests). Process start-up is
/// handed in, so tests run the loop on a fake.
enum ClaudeMCPRun {
    /// One command and whether it worked.
    struct Outcome: Equatable {
        var command: ClaudeMCPCommand
        var succeeded: Bool
    }

    struct Report: Equatable {
        var outcomes: [Outcome] = []
        var lines: [String] = []
        /// Nothing ran: another change was running, or Claude Code is missing.
        var refused = false

        init() {}

        init(refusal: String) {
            lines = ClaudeInstallReport.refusal([refusal]).lines
            refused = true
        }

        var failures: Int { outcomes.filter { !$0.succeeded }.count }
        /// The folders each failed command ran on.
        var failedFolders: [String] { outcomes.filter { !$0.succeeded }.map(\.command.folder) }
        var succeededCount: Int { outcomes.filter(\.succeeded).count }
        var install: ClaudeInstallReport {
            ClaudeInstallReport(lines: lines.isEmpty ? ["Nothing to change."] : lines, refused: refused, failures: failures)
        }
    }

    /// The environment for `claude` itself: the app's own, with the folder
    /// of `claude` and the version managers' folders on PATH.
    static func base(executable: URL, home: URL) -> [String: String] {
        var base = AgentCodexServer.environment(for: executable, searchPath: nil)
        base["PATH"] = AgentClaudeServer.searchPath(after: base["PATH"] ?? "", home: home)
        return base
    }

    /// The command's environment: the app's check environment for its
    /// account folder (ClaudeLaunchEnvironment's rules: the default account
    /// without CLAUDE_CONFIG_DIR, none with CLAUDE_SECURESTORAGE_CONFIG_DIR;
    /// no token or provider routing of the app's own).
    static func environment(for command: ClaudeMCPCommand, base: [String: String], home: URL) -> [String: String] {
        AgentClaudeServer.environment(base, home: home, folder: command.folder)
    }

    /// Runs the commands one at a time and says, per account, what each did.
    /// Their arguments can hold a server's keys, so no argument is logged or
    /// shown.
    static func run(_ commands: [ClaudeMCPCommand], labels: [String: String],
                    execute: (ClaudeMCPCommand) -> (status: Int32, timedOut: Bool)) -> Report {
        var report = Report()
        for command in commands {
            let result = execute(command)
            let worked = result.status == 0 && !result.timedOut
            report.outcomes.append(Outcome(command: command, succeeded: worked))
            let who = labels[command.folder] ?? command.folder
            let verb = command.kind == .add ? "added" : "removed"
            report.lines.append(worked ? "\(who): \(command.server) \(verb)"
                                       : "\(who): \(command.server) FAILED (exit \(result.status)\(result.timedOut ? ", timed out" : ""))")
        }
        return report
    }

    /// What a removal from every folder that held the server leaves behind:
    /// the accounts that still hold it (their command failed) and whether it
    /// is gone everywhere Brim can tell (it ran, nothing failed, no folder
    /// was unreadable).
    static func removal(_ report: Report, unreadable: [String], labels: [String: String])
        -> (everywhere: Bool, stillIn: [String]) {
        let stillIn = report.failedFolders.map { labels[$0] ?? $0 }
        return (!report.refused && stillIn.isEmpty && unreadable.isEmpty, stillIn)
    }
}
