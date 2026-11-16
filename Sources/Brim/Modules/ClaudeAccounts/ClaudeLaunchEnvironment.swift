// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// The environment a Claude Code process gets for an account.
///
/// The default account is launched with CLAUDE_CONFIG_DIR removed, never set
/// to ~/.claude: Claude Code keys the keychain item and the global config to
/// the exact string, so an explicit ~/.claude selects another sign-in
/// ("Claude Code-credentials-<hash>" and ~/.claude/.claude.json) and the
/// session looks signed out. Every other account gets its folder string
/// exactly as written.
///
/// CLAUDE_SECURESTORAGE_CONFIG_DIR moves where Claude Code keeps credentials
/// and its token-refresh lock. Brim never sets it and removes it from every
/// launch, so each account's sign-in stays where Claude Code put it.
enum ClaudeLaunchEnvironment {
    static let configDirectoryVariable = "CLAUDE_CONFIG_DIR"
    static let secureStorageVariable = "CLAUDE_SECURESTORAGE_CONFIG_DIR"

    static func environment(forFolder folder: String, base: [String: String]) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: secureStorageVariable)
        if folder.isEmpty {
            environment.removeValue(forKey: configDirectoryVariable)
        } else {
            environment[configDirectoryVariable] = folder
        }
        return environment
    }

    static func environment(for account: ClaudeAccount, base: [String: String]) -> [String: String] {
        environment(forFolder: account.folder, base: base)
    }

    /// A zsh/sh command line that runs `executable` (looked up on PATH) on the
    /// account, for a Terminal window or the clipboard:
    /// `env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CONFIG_DIR claude …`
    /// for the default account,
    /// `env -u CLAUDE_SECURESTORAGE_CONFIG_DIR CLAUDE_CONFIG_DIR='<folder>' claude …`
    /// for another.
    static func commandLine(forFolder folder: String, arguments: [String], executable: String = "claude") -> String {
        var words = ["env", "-u", secureStorageVariable]
        if folder.isEmpty {
            words += ["-u", configDirectoryVariable]
        } else {
            words.append(configDirectoryVariable + "=" + shellQuote(folder))
        }
        words.append(shellQuote(executable))
        words += arguments.map(shellQuote)
        return words.joined(separator: " ")
    }

    /// A Terminal .command file that starts `executable` with `arguments` on
    /// the account folder: it deletes itself (it holds nothing worth keeping),
    /// goes to `directory`, and runs the command through the person's
    /// interactive zsh, so their PATH and setup apply, under the same
    /// environment rules as every other launch.
    static func terminalScript(forFolder folder: String, arguments: [String], executable: String,
                               directory: String) -> String {
        let command = commandLine(forFolder: folder, arguments: arguments, executable: executable)
        return "#!/bin/zsh\n"
            + "rm -f -- \"$0\"\n"
            + "cd -- \(shellQuote(directory)) || exit 1\n"
            + "exec /bin/zsh -i -c \(shellQuote(command))\n"
    }

    /// The word as one shell word: unchanged when it holds only characters
    /// no shell treats specially, otherwise in single quotes.
    static func shellQuote(_ word: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !word.isEmpty, word.unicodeScalars.allSatisfy({ plain.contains($0) }), !word.hasPrefix("=") {
            return word
        }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Why a folder string cannot be an account's folder, or nil when it can.
    /// The string is the account's identity (its keychain item is keyed to
    /// it), so it is never normalized; a spelling that would select the wrong
    /// sign-in is refused instead.
    static func folderProblem(_ folder: String, home: String) -> ClaudeFolderProblem? {
        if folder.isEmpty { return nil }
        if folder.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .controlCharacters
        }
        guard folder.hasPrefix("/") else { return .relative }
        if folder.count > 1, folder.hasSuffix("/") { return .trailingSlash }
        let standardized = URL(fileURLWithPath: folder).standardizedFileURL.path
        let homeStandardized = URL(fileURLWithPath: home).standardizedFileURL.path
        if standardized == homeStandardized + "/.claude" { return .defaultFolderSpelledOut }
        if standardized == homeStandardized || standardized == "/" { return .notAFolderOfItsOwn }
        return nil
    }

    /// Why Claude Code must not be started on the folder from here, or nil
    /// when it may: a spelling that selects another sign-in, a folder that is
    /// gone (Claude Code would make an empty, signed-out one), or one that
    /// is not the person's own or that other users can write (its settings
    /// could run their hooks). The one folder check the app, its get_usage
    /// check and the brim-claude helper share.
    static func launchProblem(forFolder folder: String, home: String) -> String? {
        if let problem = folderProblem(folder, home: home) { return problem.message }
        guard !folder.isEmpty else { return nil }
        var info = stat()
        guard stat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return "its folder \(folder) is missing" }
        if info.st_uid != getuid() { return "its folder \(folder) belongs to another user" }
        if info.st_mode & 0o022 != 0 { return "its folder \(folder) can be written by other users" }
        return nil
    }
}

enum ClaudeFolderProblem: Equatable {
    /// Claude Code would resolve it against the working directory.
    case relative
    /// A different spelling of the same folder hashes to another keychain item.
    case trailingSlash
    /// ~/.claude written out selects another keychain item and
    /// ~/.claude/.claude.json: the default account is "" (unset) instead.
    case defaultFolderSpelledOut
    /// The home folder or the root.
    case notAFolderOfItsOwn
    case controlCharacters

    var message: String {
        switch self {
        case .relative: return "the folder must be an absolute path"
        case .trailingSlash: return "the folder must not end in a slash"
        case .defaultFolderSpelledOut:
            return "~/.claude is the default account: leave CLAUDE_CONFIG_DIR unset for it instead of naming the folder"
        case .notAFolderOfItsOwn: return "the folder must be a Claude Code config folder of its own"
        case .controlCharacters: return "the folder name contains control characters"
        }
    }
}
