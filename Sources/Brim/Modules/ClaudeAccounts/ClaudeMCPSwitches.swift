// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

// The per-repo MCP switches. A server is on everywhere until it is switched
// off for a repo; off is a `deniedMcpServers` entry ({"serverName": name}) in
// <repo>/.claude/settings.local.json, which every account folder reads, in
// subfolders and worktrees too, trusted or not (verified with Claude Code
// 2.1.325). Brim keeps a record of the entries it wrote and removes only
// those, unless the person confirms removing another.

// MARK: - Brim's record

/// <state>/mcp.json (mode 0600): the repos the person added, the switches
/// Brim turned off, the git excludes it added, and the servers it added. Only
/// the app reads and writes it. It holds names and paths, never a credential.
struct ClaudeMCPState: Codable, Equatable {
    static let currentVersion = 1

    var version = ClaudeMCPState.currentVersion
    /// Repos added with Add repo… (their keys).
    var repos: [String] = []
    /// Repo key to the server names Brim denied there.
    var denies: [String: [String]] = [:]
    /// Repos where Brim set disableClaudeAiConnectors.
    var connectorsOff: [String] = []
    /// Repos whose .git/info/exclude Brim added .claude/settings.local.json to.
    var excluded: [String] = []
    /// Servers Brim added, by name.
    var servers: [String: ClaudeMCPServerRecord] = [:]

    enum CodingKeys: String, CodingKey {
        case version, repos, denies, connectorsOff = "connectors_off", excluded, servers
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        repos = try container.decodeIfPresent([String].self, forKey: .repos) ?? []
        denies = try container.decodeIfPresent([String: [String]].self, forKey: .denies) ?? [:]
        connectorsOff = try container.decodeIfPresent([String].self, forKey: .connectorsOff) ?? []
        excluded = try container.decodeIfPresent([String].self, forKey: .excluded) ?? []
        servers = try container.decodeIfPresent([String: ClaudeMCPServerRecord].self, forKey: .servers) ?? [:]
    }

    static func path(_ paths: ClaudeAccountsPaths) -> String { paths.stateDirectory + "/mcp.json" }

    /// The record: an empty one when there is none yet, a failure when the
    /// file is there but cannot be read or decoded. A record that fails is
    /// never saved over (it holds which denies are Brim's), so every change
    /// that would update it is refused until it is fixed or deleted.
    static func read(_ paths: ClaudeAccountsPaths) -> Result<ClaudeMCPState, ClaudeMCPStateError> {
        let file = path(paths)
        guard ClaudeFileIO.exists(file) else { return .success(ClaudeMCPState()) }
        guard let data = ClaudeFileIO.read(file, limit: 4 << 20),
              let state = try? ClaudeJSON.decoder().decode(ClaudeMCPState.self, from: data) else {
            return .failure(.unreadable(file))
        }
        return .success(state)
    }

    func save(_ paths: ClaudeAccountsPaths) throws {
        try paths.ensureDirectory(paths.stateDirectory)
        try ClaudeFileIO.writeAtomically(try ClaudeJSON.encoder().encode(self), to: Self.path(paths), mode: 0o600)
    }

    mutating func own(_ name: String, in root: String) {
        var names = denies[root] ?? []
        if !names.contains(name) { names.append(name) }
        denies[root] = names
    }

    mutating func disown(_ name: String, in root: String) {
        let names = (denies[root] ?? []).filter { $0 != name }
        denies[root] = names.isEmpty ? nil : names
    }

    /// The record after a switch write. A deny (or "All claude.ai
    /// connectors" off) is Brim's only when this write put it in the file:
    /// one that was there already belongs to whoever wrote it, and Brim must
    /// never remove it later as its own. Turning on drops Brim's claim either
    /// way.
    mutating func record(_ change: ClaudeMCPSwitchChange, in root: String, changed: Bool) {
        if changed { for name in change.deny { own(name, in: root) } }
        for name in change.allow { disown(name, in: root) }
        switch change.connectorsOff {
        case true?: if changed && !connectorsOff.contains(root) { connectorsOff.append(root) }
        case false?: connectorsOff.removeAll { $0 == root }
        case nil: break
        }
    }

    /// The record after Brim added `name` to the repo in every folder:
    /// written only once the commands ran and at least one folder holds the
    /// server. `kind` is "stripe" for Add server…'s Stripe; a copy of a server
    /// Brim added keeps that server's kind; anything else is not recorded.
    mutating func recordAdded(_ name: String, kind: String?, root: String, folders added: Int) {
        guard added > 0 else { return }
        if var record = servers[name] {
            if !record.repos.contains(root) { record.repos.append(root) }
            servers[name] = record
        } else if let kind {
            servers[name] = ClaudeMCPServerRecord(kind: kind, repos: [root])
        }
    }

    /// The record after a removal: the repo leaves it only when every folder
    /// that could hold the server dropped it. A removal that failed in one
    /// folder, or a folder Brim could not read, keeps it.
    mutating func recordRemoved(_ name: String, root: String, everywhere: Bool) {
        guard everywhere, var record = servers[name] else { return }
        record.repos.removeAll { $0 == root }
        servers[name] = record.repos.isEmpty ? nil : record
    }
}

enum ClaudeMCPStateError: Error, Equatable {
    case unreadable(String)

    var message: String {
        switch self {
        case .unreadable(let path):
            return "Brim's MCP record \(path) could not be read, so Brim changes nothing until it is fixed or deleted."
        }
    }
}

/// A server Brim added to repos (Add server…): what kind, and where.
struct ClaudeMCPServerRecord: Codable, Equatable {
    /// "stripe".
    var kind: String
    /// The repos it was added to.
    var repos: [String]
}

// MARK: - JSON that keeps its order

/// A JSON value parsed with its keys in their order and every scalar as the
/// text it was written as, so a file Brim edits keeps everything it did not
/// touch: numbers, escapes and key order included.
indirect enum ClaudeOrderedJSON: Equatable {
    struct Member: Equatable {
        /// Decoded, for lookups.
        var key: String
        /// As written, quotes included.
        var rawKey: String
        var value: ClaudeOrderedJSON
    }

    case object([Member])
    case array([ClaudeOrderedJSON])
    /// A string (quotes included), number, true, false or null, as written.
    case scalar(String)

    /// Parses text JSONSerialization accepts as a whole document.
    static func parse(_ data: Data) -> ClaudeOrderedJSON? {
        guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return nil }
        var parser = Parser(bytes: Array(data))
        guard let value = parser.value() else { return nil }
        parser.skipSpace()
        return parser.index == parser.bytes.count ? value : nil
    }

    /// A JSON string literal for the text.
    static func quote(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]) else { return "\"\"" }
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    static func string(_ text: String) -> ClaudeOrderedJSON { .scalar(quote(text)) }

    /// The value as JSONSerialization reads it.
    var decoded: Any? {
        try? JSONSerialization.jsonObject(with: Data(render().utf8), options: [.fragmentsAllowed])
    }

    var members: [Member]? {
        if case .object(let members) = self { return members }
        return nil
    }

    subscript(key: String) -> ClaudeOrderedJSON? {
        members?.first { $0.key == key }?.value
    }

    /// The first key some object in the value names twice, or nil. Claude
    /// Code (JSON.parse) takes the last of them and JSONSerialization the
    /// first, so such a file is never edited: the two would disagree.
    var duplicateKey: String? {
        switch self {
        case .object(let members):
            var seen = Set<String>()
            for member in members where !seen.insert(member.key).inserted { return member.key }
            return members.lazy.compactMap(\.value.duplicateKey).first
        case .array(let items):
            return items.lazy.compactMap(\.duplicateKey).first
        case .scalar:
            return nil
        }
    }

    /// The object with `key` set to `value` (kept in its place, else added
    /// last), or removed when `value` is nil.
    func setting(_ key: String, _ value: ClaudeOrderedJSON?) -> ClaudeOrderedJSON {
        guard var members else { return self }
        if let index = members.firstIndex(where: { $0.key == key }) {
            if let value { members[index].value = value } else { members.remove(at: index) }
        } else if let value {
            members.append(Member(key: key, rawKey: Self.quote(key), value: value))
        }
        return .object(members)
    }

    /// As JSON.stringify(value, null, 2) writes it.
    func render(indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent + 2)
        let close = String(repeating: " ", count: indent)
        switch self {
        case .scalar(let text):
            return text
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { pad + $0.render(indent: indent + 2) }.joined(separator: ",\n") + "\n" + close + "]"
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            return "{\n" + members.map { pad + $0.rawKey + ": " + $0.value.render(indent: indent + 2) }
                .joined(separator: ",\n") + "\n" + close + "}"
        }
    }

    /// A recursive-descent reader for input JSONSerialization already
    /// accepted.
    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) { index += 1 }
        }

        mutating func value() -> ClaudeOrderedJSON? {
            skipSpace()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return array()
            case UInt8(ascii: "\""): return stringLiteral().map(ClaudeOrderedJSON.scalar)
            default:
                let start = index
                while index < bytes.count, !",]} \t\n\r".utf8.contains(bytes[index]) { index += 1 }
                return index > start ? .scalar(String(decoding: bytes[start..<index], as: UTF8.self)) : nil
            }
        }

        mutating func stringLiteral() -> String? {
            let start = index
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    return String(decoding: bytes[start..<index], as: UTF8.self)
                default: index += 1
                }
            }
            return nil
        }

        mutating func object() -> ClaudeOrderedJSON? {
            index += 1
            var members: [Member] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipSpace()
                guard let rawKey = stringLiteral(),
                      let key = ClaudeOrderedJSON.scalar(rawKey).decoded as? String else { return nil }
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                index += 1
                guard let value = value() else { return nil }
                members.append(Member(key: key, rawKey: rawKey, value: value))
                skipSpace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                return nil
            }
        }

        mutating func array() -> ClaudeOrderedJSON? {
            index += 1
            var items: [ClaudeOrderedJSON] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                guard let item = value() else { return nil }
                items.append(item)
                skipSpace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                return nil
            }
        }
    }
}

// MARK: - .claude/settings.local.json

enum ClaudeMCPSettingsError: Error, Equatable {
    /// The file is there but is not a JSON object.
    case unreadable(String)
    /// It starts with a byte order mark, which JSON.parse refuses.
    case byteOrderMark(String)
    /// An object in it names a key twice.
    case duplicateKey(String, key: String)
    /// Its deniedMcpServers is there but is not a list.
    case notAList(String)
    /// The file, or the .claude folder it is in, is a link: Brim does not
    /// write through it or replace it.
    case link(String)
    /// Another program kept rewriting it while Brim tried to.
    case keptChanging(String)
    case io(ClaudeFileError)

    var message: String {
        switch self {
        case .unreadable(let path): return "\(path) is not valid JSON, so Brim leaves it alone."
        case .byteOrderMark(let path):
            return "\(path) starts with a byte order mark, so Brim leaves it alone. Save it as UTF-8 without one."
        case .duplicateKey(let path, let key):
            return "\(path) has the key \"\(key)\" twice, so Brim leaves it alone. Keep one of them."
        case .notAList(let path): return "\(path) has a deniedMcpServers that is not a list, so Brim leaves it alone."
        case .link(let path): return "\(path) is a link, so Brim leaves it alone."
        case .keptChanging(let path): return "\(path) kept changing while Brim wrote it. Try again."
        case .io(let error): return error.message
        }
    }
}

/// One change to a repo's switches.
struct ClaudeMCPSwitchChange: Equatable {
    /// Server names to deny (off).
    var deny: [String] = []
    /// Server names whose deny to remove (on).
    var allow: [String] = []
    /// disableClaudeAiConnectors: true to set it, false to remove it, nil to
    /// leave it as it is.
    var connectorsOff: Bool?
}

enum ClaudeMCPSettingsFile {
    static let sizeLimit = 4 << 20

    static func path(root: String) -> String { root + "/.claude/settings.local.json" }

    /// The file's content as Brim may edit it, or why not: no byte order
    /// mark, a JSON object, no key named twice. The page reads the file with
    /// the same rules, so what it shows and what a switch would write agree.
    static func document(_ data: Data, path: String) throws -> ClaudeOrderedJSON {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { throw ClaudeMCPSettingsError.byteOrderMark(path) }
        guard let parsed = ClaudeOrderedJSON.parse(data), parsed.members != nil else {
            throw ClaudeMCPSettingsError.unreadable(path)
        }
        if let key = parsed.duplicateKey { throw ClaudeMCPSettingsError.duplicateKey(path, key: key) }
        return parsed
    }

    /// The settings with the change made and everything else kept as it was:
    /// every other key, every other deny entry (by name or URL), their order,
    /// their spelling and the file's line endings. nil when nothing changes.
    /// Written as Claude Code writes it, two spaces per level.
    static func edited(_ data: Data?, change: ClaudeMCPSwitchChange, path: String) throws -> Data? {
        let document: ClaudeOrderedJSON
        var crlf = false
        if let data, !data.isEmpty {
            document = try self.document(data, path: path)
            crlf = data.range(of: Data("\r\n".utf8)) != nil
        } else {
            document = .object([])
        }
        var original: [ClaudeOrderedJSON]?
        if case .array(let items)? = document["deniedMcpServers"] { original = items }
        if document["deniedMcpServers"] != nil, original == nil, !(change.deny.isEmpty && change.allow.isEmpty) {
            // A deniedMcpServers that is not a list (null included) is
            // someone else's to fix.
            throw ClaudeMCPSettingsError.notAList(path)
        }
        var entries = original ?? []
        // Only an entry that is a server name alone is removed: one that also
        // names a URL or a command is not the switch Brim writes.
        func name(_ item: ClaudeOrderedJSON) -> String? {
            guard let members = item.members, members.count == 1, members[0].key == "serverName" else { return nil }
            return members[0].value.decoded as? String
        }
        let removing = Set(change.allow)
        entries.removeAll { name($0).map(removing.contains) ?? false }
        for server in change.deny where !entries.contains(where: { ($0["serverName"]?.decoded as? String) == server }) {
            entries.append(.object([.init(key: "serverName", rawKey: ClaudeOrderedJSON.quote("serverName"),
                                          value: .string(server))]))
        }
        var next = document
        if entries != (original ?? []) {
            next = next.setting("deniedMcpServers", entries.isEmpty ? nil : .array(entries))
        }
        switch change.connectorsOff {
        case true?: next = next.setting("disableClaudeAiConnectors", .scalar("true"))
        case false?: next = next.setting("disableClaudeAiConnectors", nil)
        case nil: break
        }
        guard next != document else { return nil }
        let text = next.render() + "\n"
        // A JSON string holds no raw line break, so every one is layout.
        return Data((crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text).utf8)
    }

    /// Reads, changes and writes the file atomically (a temporary file and a
    /// rename, its mode kept). When the file changed between the read and
    /// the write it starts over from the new content, up to `attempts`
    /// times. `beforeWrite` runs just before the final check (tests change
    /// the file there). Returns whether it wrote: false when the file already
    /// said what the change asks, which Brim's record must not claim.
    @discardableResult
    static func apply(root: String, change: ClaudeMCPSwitchChange, attempts: Int = 3,
                      beforeWrite: () -> Void = {}) throws -> Bool {
        let file = path(root: root)
        if let link = linkProblem(root: root) { throw ClaudeMCPSettingsError.link(link) }
        for _ in 0 ..< max(1, attempts) {
            let before = ClaudeFileIO.exists(file) ? ClaudeFileIO.read(file, limit: sizeLimit) : nil
            if ClaudeFileIO.exists(file), before == nil { throw ClaudeMCPSettingsError.unreadable(file) }
            guard let after = try edited(before, change: change, path: file) else { return false }
            beforeWrite()
            let now = ClaudeFileIO.exists(file) ? ClaudeFileIO.read(file, limit: sizeLimit) : nil
            guard now == before else { continue }
            do {
                try FileManager.default.createDirectory(atPath: root + "/.claude", withIntermediateDirectories: true)
                try ClaudeFileIO.writeAtomically(after, to: file, mode: mode(file) ?? 0o644)
            } catch let error as ClaudeFileError {
                throw ClaudeMCPSettingsError.io(error)
            }
            return true
        }
        throw ClaudeMCPSettingsError.keptChanging(file)
    }

    /// The .claude folder or the settings file when it is a link: writing
    /// through either would change a file outside the repo.
    static func linkProblem(root: String) -> String? {
        let folder = root + "/.claude"
        if ClaudeFileIO.isSymlink(folder) { return folder }
        let file = path(root: root)
        return ClaudeFileIO.isSymlink(file) ? file : nil
    }

    private static func mode(_ path: String) -> mode_t? {
        var info = stat()
        return stat(path, &info) == 0 ? info.st_mode & 0o777 : nil
    }
}

// MARK: - Keeping the file out of git

/// What git says about a repo's .claude/settings.local.json before Brim
/// first writes a switch there.
enum ClaudeMCPGitCheck: Equatable {
    /// Not a git repo, or the file is ignored already.
    case fine
    /// The repo commits the file: a switch would be shared with everyone.
    case tracked
    /// Neither tracked nor ignored: Brim adds it to .git/info/exclude.
    case needsExclude

    static func decide(isRepo: Bool, tracked: Bool, ignored: Bool) -> ClaudeMCPGitCheck {
        guard isRepo else { return .fine }
        if tracked { return .tracked }
        return ignored ? .fine : .needsExclude
    }
}

enum ClaudeMCPExclude {
    /// Anchored at the repo's top, as git reads info/exclude.
    static let pattern = "/.claude/settings.local.json"

    static func path(gitDirectory: String) -> String { gitDirectory + "/info/exclude" }

    /// The exclude file with the pattern added on a line of its own, or nil
    /// when a line already names the file.
    static func added(_ existing: Data?) -> Data? {
        let text = existing.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(pattern) || lines.contains(String(pattern.dropFirst())) { return nil }
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        return Data((text + separator + pattern + "\n").utf8)
    }

    /// Adds the pattern to the repo's info/exclude (created when missing);
    /// returns the file when it wrote.
    static func add(gitDirectory: String) throws -> String? {
        let file = path(gitDirectory: gitDirectory)
        let existing = ClaudeFileIO.read(file, limit: 1 << 20)
        if ClaudeFileIO.exists(file), existing == nil { throw ClaudeFileError.posix("read \(file)", EINVAL) }
        guard let next = added(existing) else { return nil }
        try FileManager.default.createDirectory(atPath: gitDirectory + "/info", withIntermediateDirectories: true)
        var info = stat()
        let mode: mode_t = stat(file, &info) == 0 ? info.st_mode & 0o777 : 0o644
        try ClaudeFileIO.writeAtomically(next, to: file, mode: mode)
        return file
    }
}
