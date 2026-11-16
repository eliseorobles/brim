// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// What git itself says about a repo's .claude/settings.local.json before
/// Brim writes a switch there: a committed file would share the switch with
/// everyone, so Brim refuses; a file git would pick up is added to the repo's
/// own .git/info/exclude, which is never committed. Compiled into the tests
/// (build.sh TEST_SOURCES), which run it on scratch repos.
enum ClaudeMCPGit {
    static let file = ".claude/settings.local.json"

    enum Prepared: Equatable {
        /// Ready to write; `excluded` is the exclude file Brim just extended.
        case ready(excluded: String?)
        /// The repo commits the file.
        case tracked
        /// git is missing or could not read the repo (its exit status).
        case gitFailed(Int32)
        case excludeFailed(String)
    }

    static func executable() -> String? {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/git") ? "/usr/bin/git" : nil
    }

    /// git's exit status, -1 when it could not run. Its environment names no
    /// GIT_DIR or work tree of the app's, and it never asks for input.
    static func run(_ arguments: [String], root: String, home: String) -> Int32 {
        guard let git = executable() else { return -1 }
        let environment = ["PATH": "/usr/bin:/bin", "HOME": home, "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
        let result = BoundedProcessRunner.run(git, ["-C", root] + arguments, timeout: 15, maxOutputBytes: 16 << 10,
                                              environment: environment, input: FileHandle.nullDevice)
        return result.timedOut ? -1 : result.status
    }

    enum Checked: Equatable {
        case answer(ClaudeMCPGitCheck)
        /// git's exit status when it could not answer.
        case failed(Int32)
    }

    /// `ls-files --error-unmatch` (0 tracked, 1 not) and `check-ignore -q`
    /// (0 ignored, 1 not); anything else is git failing.
    static func check(root: String, home: String) -> Checked {
        guard ClaudeRepoKey.gitDirectory(root: root) != nil else { return .answer(.fine) }
        let tracked = run(["ls-files", "--error-unmatch", "--", file], root: root, home: home)
        guard tracked == 0 || tracked == 1 else { return .failed(tracked) }
        let ignored = run(["check-ignore", "-q", "--", file], root: root, home: home)
        guard ignored == 0 || ignored == 1 else { return .failed(ignored) }
        return .answer(ClaudeMCPGitCheck.decide(isRepo: true, tracked: tracked == 0, ignored: ignored == 0))
    }

    /// Run before every switch is written (the check is cheap and the repo
    /// can change between writes).
    static func prepare(root: String, home: String) -> Prepared {
        switch check(root: root, home: home) {
        case .failed(let status): return .gitFailed(status)
        case .answer(.tracked): return .tracked
        case .answer(.fine): return .ready(excluded: nil)
        case .answer(.needsExclude):
            guard let gitDirectory = ClaudeRepoKey.gitDirectory(root: root) else { return .gitFailed(-1) }
            do {
                let written = try ClaudeMCPExclude.add(gitDirectory: gitDirectory)
                // git must now ignore it, or the exclude did not take.
                guard check(root: root, home: home) == .answer(.fine) else {
                    return .excludeFailed(ClaudeMCPExclude.path(gitDirectory: gitDirectory))
                }
                return .ready(excluded: written)
            } catch {
                return .excludeFailed(ClaudeFileError.message(error))
            }
        }
    }
}
