// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Reads the same account-wide data as /usage through Claude Code's structured
/// control protocol. Claude handles authentication itself, including refreshing
/// its sign-in. No user message, model request, MCP server or tool is run, and
/// no hook but those an organization manages, which our `disableAllHooks`
/// cannot turn off.
///
/// A check runs only when ClaudeAccountsService asks, on an event, for
/// one account folder at a time (see ClaudeRefreshGate); nothing here repeats.
enum AgentClaudeServer {
    enum Failure: Error, Equatable {
        case missing, needsSignIn, outdated, unreachable
    }
    struct Summary: Equatable {
        let reading: ClaudeAccountReading
        let identity: ClaudeIdentity?
    }
    static let timeout: TimeInterval = 25
    /// Claude Code answers from the copy it saved, without asking the
    /// account, while that copy is younger than this.
    static let reuse: TimeInterval = 60
    /// The opt-outs a person may keep in Claude Code's user settings, which
    /// `--setting-sources ""` leaves out of a check.
    static let optOuts = ["DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]
    /// The proxy and certificates a network may need, which can be kept
    /// there too.
    static let networkSettings = ["HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "NODE_EXTRA_CA_CERTS"]

    /// Where Claude Code can be: where its installer, Homebrew and npm put
    /// it, along the app's PATH, then where Node version managers, Bun and
    /// pnpm keep global tools. The Claude app's own copy is left out: it has
    /// no sign-in of its own to check with.
    static func candidates(home: URL, searchPath: String? = nil) -> [URL] {
        // One list per line: Swift 6.0.3 cannot type-check them as one sum in time.
        var folders: [String] = [home.appending(path: ".local/bin").path,
                                 home.appending(path: ".claude/local").path, "/opt/homebrew/bin", "/usr/local/bin"]
        folders += (searchPath ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        folders += toolFolders(home: home)
        return folders.map { URL(fileURLWithPath: $0, isDirectory: true).appending(path: "claude") }
    }

    /// The folders that keep npm's global tools beside the Node that runs
    /// them, each manager's newest Node first, and Volta's, Bun's and pnpm's
    /// own. A Claude Code that needs Node finds it on this list too.
    static func toolFolders(home: URL) -> [String] {
        let path = { (relative: String) -> String in home.appending(path: relative).path }
        let fnm: [String] = ["Library/Application Support/fnm", ".local/share/fnm", ".fnm"].map(path)
        // One list per line, as above.
        var folders: [String] = [path(".volta/bin")]
        folders += fnm.map { $0 + "/aliases/default/bin" }
        folders += newest(in: path(".nvm/versions/node")).map { $0 + "/bin" }
        folders += fnm.flatMap { root in newest(in: root + "/node-versions").map { $0 + "/installation/bin" } }
        folders += newest(in: path(".asdf/installs/nodejs")).map { $0 + "/bin" }
        folders += newest(in: path(".local/share/mise/installs/node")).map { $0 + "/bin" }
        folders += [path(".bun/bin"), path("Library/pnpm"), path(".local/share/pnpm"), path(".npm-global/bin")]
        return folders
    }

    /// The folders in `folder` named for a version, as `v22.11.0` or
    /// `22.11.0`, newest first.
    private static func newest(in folder: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.compactMap { name -> (version: [Int], path: String)? in
            let parts = (name.hasPrefix("v") ? String(name.dropFirst()) : name).split(separator: ".").map { Int($0) }
            guard !parts.isEmpty, !parts.contains(nil) else { return nil }
            return (parts.compactMap { $0 }, folder + "/" + name)
        }
        .sorted { $1.version.lexicographicallyPrecedes($0.version) }
        .map(\.path)
    }

    /// The PATH a check gives Claude Code: `path`, the one the app gives
    /// Codex, then the version managers' folders. A Claude Code that runs on
    /// Node, as one in `~/.claude/local` does, finds one there, while the
    /// tools the system has still come from the system.
    static func searchPath(after path: String, home: URL) -> String {
        ([path] + toolFolders(home: home)).joined(separator: ":")
    }

    static func executable(home: URL, searchPath: String? = nil) -> URL? {
        candidates(home: home, searchPath: searchPath).first {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &directory) && !directory.boolValue
                && FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    /// The app's environment for a check: Claude Code never updates itself
    /// from one, and the opt-outs and the proxy the person keeps in its user
    /// settings apply as in their own sessions. The account folder owns the
    /// sign-in ("" is the default account).
    static func environment(_ base: [String: String], home: URL, folder: String = "") -> [String: String] {
        // The app may itself have been launched by another agent or account.
        // Its tokens, provider routing and config overrides must not replace
        // the chosen account's own sign-in. Network settings still apply.
        var environment = base.filter {
            optOuts.contains($0.key) || (!$0.key.hasPrefix("CLAUDE_") && !$0.key.hasPrefix("ANTHROPIC_"))
        }
        environment.removeValue(forKey: "CLAUDECODE")
        // The one rule for an account's CLAUDE_CONFIG_DIR (never set for
        // the default account) and CLAUDE_SECURESTORAGE_CONFIG_DIR (never set).
        environment = ClaudeLaunchEnvironment.environment(forFolder: folder, base: environment)
        environment["DISABLE_AUTOUPDATER"] = "1"
        let settingsFile = ClaudeSessionIndex.configDirectory(forFolder: folder, home: home.path) + "/settings.json"
        guard let data = ClaudeFileIO.read(settingsFile, limit: 4 << 20),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let settings = json["env"] as? [String: Any] else { return environment }
        // Claude Code lets its settings override the environment, and reads
        // a number or a switch there as text.
        for key in optOuts + networkSettings {
            switch settings[key] {
            case let text as String: environment[key] = text
            case let number as NSNumber:
                environment[key] = CFGetTypeID(number) == CFBooleanGetTypeID()
                    ? (number.boolValue ? "true" : "false") : number.stringValue
            default: break
            }
        }
        return environment
    }

    /// A cancellable, short-lived CLI invocation; pause/disable closes it too.
    final class Request {
        private let lock = NSLock()
        private var cancelled = false
        private var conversation: AgentCLIConversation?

        func cancel() {
            let active = lock.withLock { () -> AgentCLIConversation? in
                cancelled = true
                return conversation
            }
            active?.end()
        }

        /// Asks Claude Code for the account's plan limits, running it on the
        /// account folder `folder` ("" is the default account).
        func run(_ executable: URL, home: URL, environment: [String: String], folder: String = "",
                 timeout: TimeInterval = AgentClaudeServer.timeout) -> Result<Summary, Failure> {
            guard !lock.withLock({ cancelled }) else { return .failure(.unreachable) }
            // Never falls back to the default account when a folder is gone.
            guard ClaudeLaunchEnvironment.launchProblem(forFolder: folder, home: home.path) == nil else {
                return .failure(.needsSignIn)
            }
            let configFile = ClaudeUsageDecoding.configFile(forFolder: folder, home: home.path)
            let started = Date()
            let identity = ClaudeUsageDecoding.snapshot(configFile: configFile)?.identity
            let environment = AgentClaudeServer.environment(environment, home: home, folder: folder)
            let arguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
                "--verbose", "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--mcp-config",
                "{\"mcpServers\":{}}", "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}"]
            guard let channel = AgentCLIConversation(executable, arguments: arguments,
                                                     environment: environment, timeout: timeout) else { return .failure(.unreachable) }
            let accepted = lock.withLock { () -> Bool in
                guard !cancelled else { return false }
                conversation = channel
                return true
            }
            defer {
                channel.end()
                lock.withLock { conversation = nil }
            }
            guard accepted else { return .failure(.unreachable) }
            switch ask(channel, id: "initialize", request: ["subtype": "initialize"]) {
            case .failure(let failure): return .failure(failure)
            case .success: break
            }
            return ask(channel, id: "usage", request: ["subtype": "get_usage", "skip_behaviors": true])
                .flatMap { result in
                    guard !self.lock.withLock({ self.cancelled }) else { return .failure(.unreachable) }
                    guard result["rate_limits_available"] as? Bool == true else { return .failure(.needsSignIn) }
                    // The saved copy is read once Claude Code has exited, so
                    // what it fetched for this answer is on disk.
                    channel.end()
                    channel.waitForExit(timeout: 3)
                    let saved = ClaudeUsageDecoding.snapshot(configFile: configFile)
                    // The answer belongs to the account that was signed in
                    // when the check began, and to no other.
                    guard !self.lock.withLock({ self.cancelled }),
                          identity?.accountUuid == saved?.identity?.accountUuid else { return .failure(.unreachable) }
                    let fetched = saved?.cacheFetchedAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
                    // A copy saved before this check began was answered in place
                    // of the account, which was not reached.
                    if let fetched, started.timeIntervalSince(fetched) > AgentClaudeServer.reuse {
                        return .failure(.unreachable)
                    }
                    guard let reading = ClaudeUsageDecoding.reading(getUsage: result, observedAt: min(Date(), fetched ?? Date()))
                    else { return .failure(.unreachable) }
                    return .success(Summary(reading: reading, identity: identity))
                }
        }

        private func ask(_ channel: AgentCLIConversation, id: String,
                         request: [String: Any]) -> Result<[String: Any], Failure> {
            guard channel.send(["type": "control_request", "request_id": id, "request": request]) else { return .failure(.unreachable) }
            while let message = channel.next() {
                guard message["type"] as? String == "control_response",
                      let response = message["response"] as? [String: Any], response["request_id"] as? String == id else { continue }
                guard response["subtype"] as? String == "success" else {
                    let error = (response["error"] as? String ?? "").lowercased()
                    // A CLI from before the request answers "Unsupported control request subtype".
                    if error.contains("supported") || error.contains("unknown") { return .failure(.outdated) }
                    if error.contains("auth") || error.contains("login") || error.contains("sign in") { return .failure(.needsSignIn) }
                    return .failure(.unreachable)
                }
                return .success(response["response"] as? [String: Any] ?? [:])
            }
            return .failure(.unreachable)
        }
    }
}
