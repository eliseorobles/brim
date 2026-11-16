// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// One Claude Code CLI run that changes an account folder's MCP servers. The
/// app runs it (`claude` + arguments) under ClaudeMCPRun.environment, in
/// `directory` when it has one; Brim never edits .claude.json itself.
struct ClaudeMCPCommand: Equatable {
    enum Kind: Equatable { case add, remove }

    /// Where Claude Code files the server: the folder's user scope, or the
    /// local scope of one repo (projects[<repo>].mcpServers). The CLI takes
    /// no path for that: it files a local server under the repo it runs in.
    enum Scope: Equatable {
        case user
        case local(repo: String)
    }

    var kind: Kind
    var server: String
    /// The account folder it runs on ("" is the default account, run with
    /// CLAUDE_CONFIG_DIR removed).
    var folder: String
    var scope: Scope
    /// Arguments after `claude`.
    var arguments: [String]

    /// The working directory: the repo, for a local-scope change.
    var directory: String? {
        if case .local(let repo) = scope { return repo }
        return nil
    }

    static func add(_ server: String, json: String, folder: String) -> ClaudeMCPCommand {
        ClaudeMCPCommand(kind: .add, server: server, folder: folder, scope: .user,
                         arguments: ["mcp", "add-json", "-s", "user", server, json])
    }

    static func remove(_ server: String, folder: String) -> ClaudeMCPCommand {
        ClaudeMCPCommand(kind: .remove, server: server, folder: folder, scope: .user,
                         arguments: ["mcp", "remove", "-s", "user", server])
    }

    /// Adds the server to `repo`'s local scope in the folder. `claude mcp
    /// remove -s local` also deletes the server's MCP sign-in in that folder.
    static func addLocal(_ server: String, json: String, folder: String, repo: String) -> ClaudeMCPCommand {
        ClaudeMCPCommand(kind: .add, server: server, folder: folder, scope: .local(repo: repo),
                         arguments: ["mcp", "add-json", "-s", "local", server, json])
    }

    static func removeLocal(_ server: String, folder: String, repo: String) -> ClaudeMCPCommand {
        ClaudeMCPCommand(kind: .remove, server: server, folder: folder, scope: .local(repo: repo),
                         arguments: ["mcp", "remove", "-s", "local", server])
    }
}

/// What the MCP mirror would do, for every folder.
struct ClaudeMCPPlan: Equatable {
    struct Server: Equatable {
        var folder: String
        var name: String
    }

    var commands: [ClaudeMCPCommand] = []
    /// Servers a folder has that the shared list lacks: left as they are.
    var kept: [Server] = []
    /// What each folder holds now for each server a command replaces
    /// (folder, then server name, then its configuration as JSON). The app
    /// saves it (ClaudeMCPBackup) before any command runs.
    var replaced: [String: [String: String]] = [:]
    /// Servers whose configuration differs between folders: nothing is
    /// copied for them (local scope only).
    var conflicts: [String] = []
    /// The plan in words, server names only: a configuration can hold keys.
    var lines: [String] = []

    var isEmpty: Bool { commands.isEmpty }

    mutating func append(_ other: ClaudeMCPPlan) {
        commands += other.commands
        kept += other.kept
        replaced.merge(other.replaced) { _, new in new }
        conflicts += other.conflicts
        lines += other.lines
    }
}

/// The person's own MCP servers (user scope, `mcpServers` of each account
/// folder's .claude.json) are given to every account with Claude Code's own
/// CLI under that folder's environment: every account gets the union of what
/// the accounts hold, as Copy to every account says ("Not in X yet"). A
/// server the default account holds is copied as it has it, and a folder
/// holding another version gets it replaced after its own version is saved.
/// A server only other accounts hold is added where it is missing, the
/// default account included, when they all hold it alike; otherwise it is a
/// conflict and nothing changes. Nothing is ever removed.
///
/// A repo's own servers (local scope, projects[<repo>].mcpServers) are
/// mirrored the same way (`localPlan`), without replacing anything.
enum ClaudeMCPMirror {
    /// `mcpServers` of a .claude.json, or nil when the data is not a JSON
    /// object. A config without the key has no servers.
    static func servers(configData: Data) -> [String: Any]? {
        guard let json = ClaudeJSON.parse(configData) as? [String: Any] else { return nil }
        return ClaudeJSON.object(json["mcpServers"]) ?? [:]
    }

    /// One server's configuration as compact JSON with sorted keys, the form
    /// `claude mcp add-json` takes and two configurations are compared in.
    static func canonicalJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The user-scope plan. `servers` is what each readable folder holds
    /// (folder to name to configuration), `folders` those folders in launch
    /// order ("" is the default account), `describe` names a folder for the
    /// review. Removals first (only of differing servers, which are added
    /// again), then additions, each by name.
    static func plan(servers: [String: [String: Any]], folders: [String], describe: (String) -> String) -> ClaudeMCPPlan {
        var plan = ClaudeMCPPlan()
        var removals: [ClaudeMCPCommand] = []
        var additions: [ClaudeMCPCommand] = []
        for name in Set(folders.flatMap { (servers[$0] ?? [:]).keys }).sorted() {
            let holders = folders.filter { servers[$0]?[name] != nil }
            let source: String
            if servers[""]?[name] != nil {
                source = ""
            } else {
                let shapes = Set(holders.compactMap { servers[$0]?[name].flatMap(comparable) })
                guard shapes.count == 1, let first = holders.first else {
                    plan.conflicts.append(name)
                    plan.lines.append("\(name): differs between \(holders.map(describe).joined(separator: ", ")); nothing changes")
                    continue
                }
                source = first
            }
            guard let config = servers[source]?[name], let wanted = canonicalJSON(config), let shape = comparable(config) else {
                plan.kept.append(.init(folder: source, name: name))
                plan.lines.append("\(describe(source)): keep \(name) (Brim cannot read its configuration)")
                continue
            }
            let origin = source.isEmpty ? "" : " (from \(describe(source)))"
            for folder in folders where folder != source {
                guard let present = servers[folder]?[name] else {
                    additions.append(.add(name, json: wanted, folder: folder))
                    plan.lines.append("\(describe(folder)): add \(name)\(origin)")
                    continue
                }
                if comparable(present) == shape { continue }
                guard let own = canonicalJSON(present) else {
                    // Something Brim cannot read back is never replaced blind.
                    plan.kept.append(.init(folder: folder, name: name))
                    plan.lines.append("\(describe(folder)): keep \(name) (Brim cannot read its configuration)")
                    continue
                }
                removals.append(.remove(name, folder: folder))
                additions.append(.add(name, json: wanted, folder: folder))
                plan.replaced[folder, default: [:]][name] = own
                plan.lines.append("\(describe(folder)): replace \(name) with \(describe(source))'s version (its own is saved first; Undo puts it back)")
            }
        }
        plan.commands = removals + additions
        return plan
    }

    /// Whether a configuration can carry a secret (an env, a header or an
    /// argument), which `claude mcp add-json` takes on its command line.
    static func mayHoldSecrets(_ json: String) -> Bool {
        guard let config = ClaudeJSON.parse(Data(json.utf8)) as? [String: Any] else { return true }
        return ["env", "headers", "args"].contains { key in
            if let map = config[key] as? [String: Any] { return !map.isEmpty }
            if let list = config[key] as? [Any] { return !list.isEmpty }
            return config[key] != nil
        }
    }
}

extension ClaudeMCPMirror {
    /// projects[<repo>].mcpServers of a .claude.json: the repo's local-scope
    /// servers in that folder. Empty when the repo has no entry.
    static func localServers(configData: Data, repo: String) -> [String: Any] {
        guard let json = ClaudeJSON.parse(configData) as? [String: Any],
              let project = ClaudeJSON.object(ClaudeJSON.object(json["projects"])?[repo]) else { return [:] }
        return ClaudeJSON.object(project["mcpServers"]) ?? [:]
    }

    /// The configuration in the form two folders' copies are compared in:
    /// what `claude mcp add-json` fills in itself (an empty `args`, `env` or
    /// `headers`, the stdio type) does not make two copies differ.
    static func comparable(_ value: Any) -> String? {
        guard var config = value as? [String: Any] else { return canonicalJSON(value) }
        for key in ["args", "env", "headers"] {
            if let list = config[key] as? [Any], list.isEmpty { config[key] = nil }
            if let map = config[key] as? [String: Any], map.isEmpty { config[key] = nil }
        }
        if config["type"] == nil, config["command"] != nil { config["type"] = "stdio" }
        return canonicalJSON(config)
    }

    /// Gives every folder the repo's local-scope servers. `servers` is what
    /// each folder holds for the repo now (folder to name to configuration),
    /// `folders` every account folder in launch order; `describe` names a
    /// folder for the review. A server two folders hold differently is a
    /// conflict: listed, never copied. Nothing is removed or replaced.
    static func localPlan(repo: String, servers: [String: [String: Any]], folders: [String],
                          describe: (String) -> String) -> ClaudeMCPPlan {
        var plan = ClaudeMCPPlan()
        let names = Set(servers.values.flatMap(\.keys)).sorted()
        for name in names {
            let holders = folders.filter { servers[$0]?[name] != nil }
            let shapes = Set(holders.compactMap { servers[$0]?[name].flatMap(comparable) })
            guard shapes.count == 1, let first = holders.first,
                  let json = servers[first]?[name].flatMap(canonicalJSON) else {
                plan.conflicts.append(name)
                plan.lines.append("\(name): differs between \(holders.map(describe).joined(separator: ", ")); nothing changes")
                continue
            }
            for folder in folders where servers[folder]?[name] == nil {
                plan.commands.append(.addLocal(name, json: json, folder: folder, repo: repo))
                plan.lines.append("\(describe(folder)): add \(name) to this repo")
            }
        }
        return plan
    }
}

/// What the page shows of a server's configuration: its transport, host or
/// program, and how it signs in. Never a value of its env, headers or args.
struct ClaudeMCPServerInfo: Equatable {
    enum Transport: String, Equatable { case stdio, http, sse, ws, unknown }

    var transport: Transport
    /// The URL's host, for a remote server.
    var host: String?
    /// The program's file name, for a stdio server.
    var program: String?
    var usesHeadersHelper = false
    var hasAuthorizationHeader = false
    /// What Claude Code matches plugin servers and connectors against to
    /// drop duplicates: the URL (a trailing slash aside), or the command and
    /// its arguments.
    var endpoint: String?

    var isRemote: Bool { transport == .http || transport == .sse || transport == .ws }
    /// A remote server with no header or helper of its own: each account
    /// signs in to it with Claude Code's MCP sign-in (OAuth).
    var signsInItself: Bool { isRemote && !usesHeadersHelper && !hasAuthorizationHeader }

    /// "http · mcp.stripe.com", "stdio · npx".
    var summary: String {
        [transport == .unknown ? nil : transport.rawValue, host ?? program].compactMap { $0 }.joined(separator: " · ")
    }

    init(_ value: Any?) {
        let config = value as? [String: Any] ?? [:]
        let type = (config["type"] as? String)?.lowercased()
        let url = config["url"] as? String
        let command = config["command"] as? String
        switch type {
        case "stdio"?: transport = .stdio
        case "http"?, "streamable-http"?: transport = .http
        case "sse"?: transport = .sse
        case "ws"?: transport = .ws
        case nil where command != nil: transport = .stdio
        case nil where url != nil: transport = .http
        default: transport = .unknown
        }
        if let url {
            let components = URLComponents(string: url)
            host = components?.host?.lowercased()
            var spelled = url
            if spelled.hasSuffix("/") { spelled.removeLast() }
            endpoint = "url " + spelled
        }
        if let command {
            program = (command as NSString).lastPathComponent
            let args = (config["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            endpoint = (["command", command] + args).joined(separator: "\u{0}")
        }
        usesHeadersHelper = !(config["headersHelper"] as? String ?? "").isEmpty
        hasAuthorizationHeader = (config["headers"] as? [String: Any])?.keys
            .contains { $0.lowercased() == "authorization" } ?? false
    }
}

extension ClaudeMCPMirror {
    /// Why Claude Code would refuse the name, or nil: letters, digits, "-"
    /// and "_", as `claude mcp add` checks.
    static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "Type a name." }
        if name.count > 64 { return "Use at most 64 characters." }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "Use only letters, digits, - and _."
        }
        return nil
    }

    /// The server JSON a person pasted, as compact JSON, or why it cannot be
    /// one: a stdio server needs a command, an http or sse one an http(s)
    /// URL; args are strings, and env and headers map names to strings.
    static func pastedServer(_ text: String) -> Result<String, ClaudeMCPPasteProblem> {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let config = ClaudeJSON.parse(data) as? [String: Any] else { return .failure(.notAnObject) }
        let type = (config["type"] as? String) ?? (config["command"] != nil ? "stdio" : nil)
        switch type {
        case "stdio"?:
            guard let command = config["command"] as? String, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .failure(.missing("command"))
            }
            if let args = config["args"], !((args as? [Any])?.allSatisfy { $0 is String } ?? false) {
                return .failure(.wrongType("args"))
            }
            if let env = config["env"], !isStringMap(env) { return .failure(.wrongType("env")) }
        case "http"?, "sse"?:
            guard let url = config["url"] as? String, let components = URLComponents(string: url),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host?.isEmpty == false else {
                return .failure(.missing("url"))
            }
            if let headers = config["headers"], !isStringMap(headers) { return .failure(.wrongType("headers")) }
            if let helper = config["headersHelper"], !(helper is String) { return .failure(.wrongType("headersHelper")) }
        default:
            return .failure(.type)
        }
        guard let json = canonicalJSON(config) else { return .failure(.notAnObject) }
        return .success(json)
    }

    private static func isStringMap(_ value: Any) -> Bool {
        guard let map = value as? [String: Any] else { return false }
        return map.values.allSatisfy { $0 is String }
    }
}

enum ClaudeMCPPasteProblem: Error, Equatable {
    case notAnObject
    case type
    case missing(String)
    case wrongType(String)

    var message: String {
        switch self {
        case .notAnObject: return "Paste one server as a JSON object, like {\"type\":\"stdio\",\"command\":\"npx\"}."
        case .type: return "Set \"type\" to stdio, http or sse."
        case .missing("url"): return "An http or sse server needs a \"url\" that starts with https:// or http://."
        case .missing(let field): return "A stdio server needs a \"\(field)\"."
        case .wrongType("args"): return "\"args\" must be a list of strings."
        case .wrongType(let field): return "\"\(field)\" must map names to strings."
        }
    }
}

/// <state>/mcp-backups/<account key>-<time>.json (mode 0600): a folder's own
/// MCP server configurations, saved before the mirror replaced them. Undo
/// puts each back with Claude Code's CLI; a used backup is renamed
/// "*.restored" and kept.
struct ClaudeMCPBackup: Equatable, Codable {
    var folder: String
    var savedAt: Date
    /// Server name to configuration JSON.
    var servers: [String: String]

    enum CodingKeys: String, CodingKey { case folder, savedAt = "saved_at", servers }

    /// Writes one backup per folder, never over another; returns the files
    /// written.
    static func save(_ replaced: [String: [String: String]], paths: ClaudeAccountsPaths, now: Date) throws -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var written: [String] = []
        for (folder, servers) in replaced.sorted(by: { $0.key < $1.key }) where !servers.isEmpty {
            try paths.ensureDirectory(paths.mcpBackupsDirectory)
            let base = paths.mcpBackupsDirectory + "/" + ClaudeAccountKey.key(forFolder: folder) + "-" + formatter.string(from: now)
            var path = base + ".json"
            var number = 2
            while ClaudeFileIO.exists(path) || ClaudeFileIO.exists(path + ".restored") {
                path = base + "-\(number).json"
                number += 1
            }
            let backup = ClaudeMCPBackup(folder: folder, savedAt: now, servers: servers)
            try ClaudeFileIO.writeAtomically(try ClaudeJSON.encoder().encode(backup), to: path, mode: 0o600)
            written.append(path)
        }
        return written
    }

    /// The backups not restored yet, oldest first, with their files.
    static func pending(_ paths: ClaudeAccountsPaths) -> [(path: String, backup: ClaudeMCPBackup)] {
        let directory = paths.mcpBackupsDirectory
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
        return names.compactMap { name -> (String, ClaudeMCPBackup)? in
            let path = directory + "/" + name
            guard let data = ClaudeFileIO.read(path, limit: 4 << 20),
                  let backup = try? ClaudeJSON.decoder().decode(ClaudeMCPBackup.self, from: data) else { return nil }
            return (path, backup)
        }.sorted { $0.1.savedAt == $1.1.savedAt ? $0.0 < $1.0 : $0.1.savedAt < $1.1.savedAt }
    }

    /// The commands that put every pending backup back: each server as the
    /// oldest backup holding it saved it (the folder's own, before Brim first
    /// replaced it), removing the version there now first. `current` gives a
    /// folder's servers now.
    static func undoPlan(_ backups: [ClaudeMCPBackup], current: (String) -> [String: Any]) -> ClaudeMCPPlan {
        var originals: [String: [String: String]] = [:]
        for backup in backups {
            for (name, json) in backup.servers where originals[backup.folder]?[name] == nil {
                originals[backup.folder, default: [:]][name] = json
            }
        }
        var plan = ClaudeMCPPlan()
        for (folder, servers) in originals.sorted(by: { $0.key < $1.key }) {
            let now = current(folder)
            for (name, json) in servers.sorted(by: { $0.key < $1.key }) {
                if now[name].flatMap(ClaudeMCPMirror.canonicalJSON) == json {
                    plan.lines.append("\(folder): \(name) is already its own version")
                    continue
                }
                if now[name] != nil { plan.commands.append(.remove(name, folder: folder)) }
                plan.commands.append(.add(name, json: json, folder: folder))
                plan.lines.append("\(folder): put back its own \(name)")
            }
        }
        return plan
    }

    /// Marks backups used: "<file>.restored", kept beside the others.
    static func markRestored(_ files: [String]) {
        for file in files { rename(file, file + ".restored") }
    }
}
