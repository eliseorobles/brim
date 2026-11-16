// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// What a finished sign-in left in the folder.
enum ClaudeSignInOutcome: Equatable {
    case rightAccount
    /// Signed in, to this other email.
    case otherAccount(String)
    case notSignedIn
}

/// The pure half of Brim's sign-in: Brim runs `claude auth login --claudeai
/// --email <expected>` itself, on the account's folder, with brim-claude as
/// its BROWSER. Claude Code runs `$BROWSER <link>` (one argument, no shell)
/// to open its sign-in page and `--email` becomes the page's login_hint
/// (verified with Claude Code 2.1.323 and 2.1.325, 2026-11-13). brim-claude
/// writes the link to a file Brim watches, and Brim opens it in a private
/// window, so whatever account the browser is signed in to cannot approve
/// the sign-in. When Claude Code exits, Brim reads the folder's .claude.json
/// oauthAccount and compares the email. Nothing here reads, copies or prints
/// a credential or keychain item.
enum ClaudeSignIn {
    static let urlFileVariable = "BRIM_SIGNIN_URL_FILE"
    static let browserVariable = "BROWSER"
    /// How long a sign-in may wait for the person before Brim ends it.
    static let timeout: TimeInterval = 15 * 60
    static let linkLimit = 8 << 10

    static func arguments(email: String) -> [String] {
        ["auth", "login", "--claudeai", "--email", email]
    }

    /// The child's environment: the account's (ClaudeLaunchEnvironment: the
    /// default folder with CLAUDE_CONFIG_DIR removed, another with its exact
    /// folder, CLAUDE_SECURESTORAGE_CONFIG_DIR removed), brim-claude as the
    /// browser, and the file it hands the link to.
    static func environment(folder: String, base: [String: String], helper: String, urlFile: String) -> [String: String] {
        var environment = ClaudeLaunchEnvironment.environment(forFolder: folder, base: base)
        environment[browserVariable] = helper
        environment[urlFileVariable] = urlFile
        return environment
    }

    // MARK: Links

    /// What brim-claude treats as a link to open rather than a subcommand.
    static func looksLikeLink(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("https://") || lowered.hasPrefix("http://")
    }

    /// The link, when it is one Brim opens: https, on claude.com, claude.ai
    /// or a subdomain of anthropic.com, with no user name, password or port
    /// of its own, no spaces or control characters, and at most 8 KB.
    static func acceptedLink(_ text: String) -> URL? {
        guard text.utf8.count <= linkLimit, !text.isEmpty,
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                  || CharacterSet.controlCharacters.contains($0) || !$0.isASCII }),
              let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, components.port == nil || components.port == 443,
              let host = components.percentEncodedHost?.lowercased(), !host.isEmpty,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              host == "claude.com" || host == "claude.ai"
                || (host.hasSuffix(".anthropic.com") && host.count > ".anthropic.com".count && !host.hasPrefix(".")),
              let url = components.url else { return nil }
        return url
    }

    // MARK: Files

    /// 32 hex digits from the system's random source.
    static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return ClaudeHex.string((0 ..< 16).map { _ in UInt8.random(in: 0 ... .max, using: &generator) })
    }

    static func isToken(_ text: Substring) -> Bool {
        text.count == 32 && text.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    static func urlFile(directory: String, token: String) -> String { directory + "/" + token + ".url" }

    /// The marker brim-claude leaves beside the URL file for a link it
    /// refused; it holds no link.
    static func refusedFile(forURLFile file: String) -> String {
        String(file.dropLast(4)) + ".refused"
    }

    /// <...>/signin/<token>.url: the only file brim-claude writes a link to.
    static func isURLFilePath(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        return path.hasPrefix("/") && !path.contains("/./") && !path.contains("/../")
            && (directory as NSString).lastPathComponent == "signin"
            && name.hasSuffix(".url") && isToken(name.dropLast(4))
    }

    /// A real folder (not a link) of this user that no one else can open.
    static func isPrivateDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        return info.st_uid == getuid() && info.st_mode & 0o077 == 0
    }

    /// Removes the links and markers sign-ins left (the app starts with no
    /// sign-in running); returns how many. Only files are removed.
    @discardableResult
    static func sweep(directory: String) -> Int {
        var removed = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        where name.hasSuffix(".url") || name.hasSuffix(".refused") || name.hasSuffix(".tmp") {
            let path = directory + "/" + name
            if ClaudeFileIO.isRegularFile(path), unlink(path) == 0 { removed += 1 }
        }
        return removed
    }

    // MARK: Private windows

    /// The flag that opens a private window, by the default browser's bundle
    /// identifier (lowercased). Safari, Arc and others have none: the sheet
    /// asks the person to copy the link into a private window instead.
    static let privateWindowFlags: [String: String] = [
        "com.google.chrome": "--incognito", "com.google.chrome.beta": "--incognito",
        "com.google.chrome.dev": "--incognito", "com.google.chrome.canary": "--incognito",
        "com.brave.browser": "--incognito", "com.brave.browser.beta": "--incognito",
        "com.brave.browser.nightly": "--incognito", "org.chromium.chromium": "--incognito",
        "com.vivaldi.vivaldi": "--incognito",
        "com.microsoft.edgemac": "--inprivate", "com.microsoft.edgemac.beta": "--inprivate",
        "com.microsoft.edgemac.dev": "--inprivate", "com.microsoft.edgemac.canary": "--inprivate",
        "org.mozilla.firefox": "--private-window", "org.mozilla.firefoxdeveloperedition": "--private-window",
        "org.mozilla.nightly": "--private-window",
    ]

    static func privateWindowFlag(bundleIdentifier: String?) -> String? {
        bundleIdentifier.flatMap { privateWindowFlags[$0.lowercased()] }
    }

    static let openTool = "/usr/bin/open"

    /// `open -na <app> --args <flag> <link>`: a private window of that browser.
    static func openArguments(app: String, flag: String, link: URL) -> [String] {
        ["-na", app, "--args", flag, link.absoluteString]
    }

    // MARK: After the sign-in

    /// What the folder holds once Claude Code exited, against the email the
    /// account expects (ignoring case).
    static func outcome(expected: String, snapshot: ClaudeConfigSnapshot?) -> ClaudeSignInOutcome {
        guard let snapshot, snapshot.signedIn, let email = snapshot.identity?.email else { return .notSignedIn }
        return ClaudeAccountList.sameEmail(email, expected) ? .rightAccount : .otherAccount(email)
    }

    /// Claude Code's own words for why it stopped, for the sheet: its last
    /// lines, without terminal codes, links or its usual prompts, at most
    /// 240 characters. nil when it said nothing useful.
    static func errorText(_ output: String) -> String? {
        var text = output
        for pattern in ["\u{1B}\\[[0-9;?]*[ -/]*[@-~]", "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)?", "https?://\\S+"] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let replacement = pattern.hasPrefix("https") ? "the link" : ""
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                       withTemplate: replacement)
        }
        let lines = text.components(separatedBy: .newlines)
            .map { String($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }) }
            .map(withoutRoutine)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let joined = lines.suffix(2).joined(separator: " ")
        return joined.count > 240 ? String(joined.prefix(239)) + "…" : joined
    }

    /// Claude Code's usual words at the start of a line: "Opening browser to
    /// sign in…", the line with the link, and the paste prompt.
    private static let routine = try? NSRegularExpression(
        pattern: "^(opening browser to sign in\\S*|if the browser didn['\u{2019}]t open, visit:( the link)?"
            + "|sign in at:( the link)?|paste code here( if prompted)? >)\\s*",
        options: [.caseInsensitive])

    /// The line without those words. The paste prompt ends without a
    /// newline, and its error ("Login failed: …", on stderr, which shares
    /// the pipe) follows it on the same line (Claude Code 2.1.325), so only
    /// the prompt goes and what follows it stays.
    private static func withoutRoutine(_ line: String) -> String {
        var line = line.trimmingCharacters(in: .whitespaces)
        while let routine, let match = routine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.range.length > 0, let range = Range(match.range, in: line) {
            line.removeSubrange(range)
            line = line.trimmingCharacters(in: .whitespaces)
        }
        return line
    }
}
