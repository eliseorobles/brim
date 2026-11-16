// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

// MCP by repo: which repos Claude Code has run in, and which MCP servers each
// one gets, from every account folder's .claude.json, the installed plugins
// and the repo's own files. Read-only: switches are written by
// ClaudeMCPSettingsFile, servers are added and removed with Claude Code's CLI
// (ClaudeMCPCommand). Facts verified with Claude Code 2.1.325 in throwaway
// folders (2026-11-13).

/// The key Claude Code files a working directory under in .claude.json
/// (projects[<key>]: its local servers, /mcp toggles and trust), and the
/// folder whose .claude/settings.local.json applies there: the canonical git
/// root (a subfolder's repo, a worktree's main repo, symlinks resolved), or
/// the realpath outside git.
enum ClaudeRepoKey {
    static func root(of path: String) -> String {
        let real = ClaudeFileIO.realPath(path)
        var directory = real
        while true {
            let dotGit = directory + "/.git"
            if ClaudeFileIO.isDirectory(dotGit, followingLinks: true) { return directory }
            if ClaudeFileIO.isRegularFile(dotGit) { return mainRepo(gitFile: dotGit, folder: directory) ?? directory }
            if directory == "/" || directory.isEmpty { return real }
            directory = (directory as NSString).deletingLastPathComponent
        }
    }

    /// The repo's own git folder (a worktree's common one), whose
    /// info/exclude git reads; nil outside git.
    static func gitDirectory(root: String) -> String? {
        let dotGit = root + "/.git"
        if ClaudeFileIO.isDirectory(dotGit, followingLinks: true) { return ClaudeFileIO.realPath(dotGit) }
        guard ClaudeFileIO.isRegularFile(dotGit),
              let gitDirectory = pointer(in: dotGit, prefix: "gitdir:", relativeTo: root) else { return nil }
        return pointer(in: gitDirectory + "/commondir", prefix: nil, relativeTo: gitDirectory) ?? gitDirectory
    }

    /// A `.git` file's main repo: a worktree's git folder names the common
    /// one, which is <main repo>/.git. nil for a submodule (no commondir).
    private static func mainRepo(gitFile: String, folder: String) -> String? {
        guard let gitDirectory = pointer(in: gitFile, prefix: "gitdir:", relativeTo: folder),
              let common = pointer(in: gitDirectory + "/commondir", prefix: nil, relativeTo: gitDirectory),
              (common as NSString).lastPathComponent == ".git" else { return nil }
        return (common as NSString).deletingLastPathComponent
    }

    /// The path a git pointer file holds, resolved against `base`.
    private static func pointer(in file: String, prefix: String?, relativeTo base: String) -> String? {
        guard let data = ClaudeFileIO.read(file, limit: 64 << 10) else { return nil }
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix {
            guard text.hasPrefix(prefix) else { return nil }
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty, !text.contains("\n") else { return nil }
        let path = text.hasPrefix("/") ? text : base + "/" + text
        return ClaudeFileIO.realPath(URL(fileURLWithPath: path).standardizedFileURL.path)
    }
}

// MARK: - Repo list

struct ClaudeMCPRepo: Equatable, Identifiable {
    /// Its key (ClaudeRepoKey).
    var root: String
    /// The newest change of a transcript (<config>/projects/<slug>/*.jsonl)
    /// of any path that files under it, in any account's projects/; nil when
    /// there is none. Not the slug folder's own date: every sync write into
    /// it (ClaudeSync) moves that, while a clone keeps the transcript's.
    var lastUsed: Date?
    /// Added with Add repo… (kept in Brim's state).
    var added: Bool

    var id: String { root }
}

enum ClaudeMCPRepoList {
    /// Every repo the folders' .claude.json files name (their projects keys)
    /// and every one the person added: folded to its key, gone ones left
    /// out, the most recently used first, then by name.
    static func build(keys: [String], added: [String], projectsDirectories: [String]) -> [ClaudeMCPRepo] {
        var paths: [String: Set<String>] = [:]
        var addedRoots = Set<String>()
        for (index, path) in (added + keys).enumerated()
        where path.hasPrefix("/") && ClaudeFileIO.isDirectory(path, followingLinks: true) {
            let root = ClaudeRepoKey.root(of: path)
            guard root != "/" else { continue }
            paths[root, default: []].insert(path)
            if index < added.count { addedRoots.insert(root) }
        }
        let repos = paths.map { root, spellings -> ClaudeMCPRepo in
            let used = spellings.union([root]).flatMap { path in
                projectsDirectories.compactMap { newestTranscript(in: $0 + "/" + ClaudeSessionIndex.projectSlug(path)) }
            }.max()
            return ClaudeMCPRepo(root: root, lastUsed: used, added: addedRoots.contains(root))
        }
        return sorted(repos)
    }

    /// The newest modification of a transcript directly in `folder`.
    static func newestTranscript(in folder: String) -> Date? {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).compactMap { name in
            name.hasSuffix(".jsonl") && !name.hasPrefix(".") && ClaudeFileIO.isRegularFile(folder + "/" + name)
                ? ClaudeFileIO.modificationDate(folder + "/" + name) : nil
        }.max()
    }

    static func sorted(_ repos: [ClaudeMCPRepo]) -> [ClaudeMCPRepo] {
        repos.sorted { a, b in
            switch (a.lastUsed, b.lastUsed) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                let (nameA, nameB) = ((a.root as NSString).lastPathComponent.lowercased(),
                                      (b.root as NSString).lastPathComponent.lowercased())
                return nameA == nameB ? a.root < b.root : nameA < nameB
            }
        }
    }

    /// "~" for the home folder, else the folder's own name.
    static func name(_ root: String, home: String) -> String {
        root == home ? "~" : (root as NSString).lastPathComponent
    }

    /// The repos whose name or path holds the text, ignoring case.
    static func filter(_ repos: [ClaudeMCPRepo], _ text: String) -> [ClaudeMCPRepo] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return repos }
        return repos.filter { $0.root.lowercased().contains(needle) }
    }
}

// MARK: - What the folders hold

/// One account folder's .claude.json, as the MCP page needs it.
struct ClaudeMCPFolderConfig {
    var folder: String
    var label: String
    /// Top-level mcpServers: its user scope.
    var userServers: [String: Any]
    /// projects, by key.
    var projects: [String: [String: Any]]
    /// claudeAiMcpEverConnected entries that name a connector ("claude.ai <Name>").
    var connectors: [String]
    /// Servers waiting for this folder's own MCP sign-in (ClaudeMCPNeedsAuth).
    var needsSignIn: Set<String>
    /// The file was read as a JSON object. A missing or unreadable one says
    /// nothing about what the folder holds, so the folder is shown as
    /// unreadable and left out of every plan.
    var readable: Bool

    init(folder: String, label: String, configData: Data?, needsAuthCache: Data? = nil) {
        self.folder = folder
        self.label = label
        let parsed = configData.flatMap { ClaudeJSON.parse($0) as? [String: Any] }
        readable = parsed != nil
        let json = parsed ?? [:]
        userServers = ClaudeJSON.object(json["mcpServers"]) ?? [:]
        projects = (ClaudeJSON.object(json["projects"]) ?? [:]).compactMapValues { $0 as? [String: Any] }
        connectors = (ClaudeJSON.array(json["claudeAiMcpEverConnected"]) ?? []).compactMap { $0 as? String }
            .filter { $0.hasPrefix(ClaudeMCPCatalog.connectorPrefix) }
        needsSignIn = ClaudeMCPNeedsAuth.names(needsAuthCache)
    }

    func project(_ root: String) -> [String: Any] { projects[root] ?? [:] }
    func localServers(_ root: String) -> [String: Any] { ClaudeJSON.object(project(root)["mcpServers"]) ?? [:] }
    /// Names the /mcp toggle turned off for the repo in this folder only.
    func toggledOff(_ root: String) -> [String] {
        (ClaudeJSON.array(project(root)["disabledMcpServers"]) ?? []).compactMap { $0 as? String }
    }
    func trusts(_ root: String) -> Bool { ClaudeJSON.bool(project(root)["hasTrustDialogAccepted"]) == true }
}

/// Claude Code's record of the MCP servers an account folder still has to
/// sign in to: <folder>/mcp-needs-auth-cache.json, an object keyed by server
/// name. The one reader of it (the accounts list and the MCP page both use
/// it); names only, nothing else in the file is read.
enum ClaudeMCPNeedsAuth {
    static func path(configDirectory: String) -> String { configDirectory + "/mcp-needs-auth-cache.json" }

    static func names(_ data: Data?) -> Set<String> {
        guard let data, let json = ClaudeJSON.parse(data) as? [String: Any] else { return [] }
        return Set(json.keys)
    }
}

/// Whether Claude Code connects a repo's .mcp.json server for one account.
enum ClaudeMCPApproval: Equatable {
    case approved
    /// Nobody answered Claude Code's prompt yet.
    case notApproved
    case declined

    /// Declined when a disabledMcpjsonServers names it, approved when an
    /// enabledMcpjsonServers names it or enableAllProjectMcpServers is true,
    /// else not approved yet. `layers` are the user settings, the repo's
    /// .claude/settings.json and settings.local.json, and the folder's own
    /// projects[<repo>] in its .claude.json.
    static func of(_ name: String, layers: [[String: Any]]) -> ClaudeMCPApproval {
        func names(_ key: String) -> [String] {
            layers.flatMap { (ClaudeJSON.array($0[key]) ?? []).compactMap { $0 as? String } }
        }
        if names("disabledMcpjsonServers").contains(name) { return .declined }
        if names("enabledMcpjsonServers").contains(name)
            || layers.contains(where: { ClaudeJSON.bool($0["enableAllProjectMcpServers"]) == true }) { return .approved }
        return .notApproved
    }
}

// MARK: - Plugins

/// An MCP server a plugin ships.
struct ClaudeMCPPluginServer: Equatable {
    /// The plugin's own name (its plugin.json `name`).
    var plugin: String
    /// Its key in enabledPlugins: "stripe@claude-plugins-official",
    /// "productivity@synced", "heygen@skills-dir".
    var key: String
    var server: String
    var info: ClaudeMCPServerInfo
    /// A plugin installed for one repo only applies there.
    var projectPath: String?
    /// Synced and skills-dir plugins are on unless enabledPlugins says false.
    var implicit = false

    /// The name sessions know it by: plugin:<plugin>:<server>.
    var runtimeName: String { "plugin:" + plugin + ":" + server }
}

enum ClaudeMCPPlugins {
    /// The MCP servers of every installed plugin: the installs in
    /// ~/.claude/plugins/installed_plugins.json, the plugins synced from
    /// claude.ai (plugins/synced/<id>/<plugin>) and the ones under skills/.
    static func scan(home: String) -> [ClaudeMCPPluginServer] {
        let root = home + "/.claude"
        var found: [ClaudeMCPPluginServer] = []
        let installed = ClaudeFileIO.read(root + "/plugins/installed_plugins.json", limit: 4 << 20)
            .flatMap { ClaudeJSON.parse($0) as? [String: Any] }
        for (key, value) in (ClaudeJSON.object(installed?["plugins"]) ?? [:]).sorted(by: { $0.key < $1.key }) {
            for install in (value as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                guard let path = ClaudeJSON.string(install["installPath"]) else { continue }
                let scope = ClaudeJSON.string(install["scope"]) ?? "user"
                let project = scope == "user" ? nil : ClaudeJSON.string(install["projectPath"]).map(ClaudeRepoKey.root)
                found += servers(pluginRoot: path, key: key, projectPath: project, implicit: false)
            }
        }
        let synced = root + "/plugins/synced"
        for bucket in directories(synced) {
            for plugin in directories(synced + "/" + bucket) {
                let path = synced + "/" + bucket + "/" + plugin
                found += servers(pluginRoot: path, key: pluginName(path) + "@synced", projectPath: nil, implicit: true)
            }
        }
        for skill in directories(root + "/skills") {
            let path = root + "/skills/" + skill
            guard ClaudeFileIO.isRegularFile(path + "/.claude-plugin/plugin.json") else { continue }
            found += servers(pluginRoot: path, key: pluginName(path) + "@skills-dir", projectPath: nil, implicit: true)
        }
        // One entry per runtime name: a plugin installed twice is one server.
        var seen = Set<String>()
        return found.filter { seen.insert($0.runtimeName + "|" + ($0.projectPath ?? "")).inserted }
    }

    /// A plugin folder's servers: plugin.json's mcpServers (inline, or the
    /// file it names), else its .mcp.json.
    static func servers(pluginRoot: String, key: String, projectPath: String?, implicit: Bool) -> [ClaudeMCPPluginServer] {
        let manifest = ClaudeFileIO.read(pluginRoot + "/.claude-plugin/plugin.json", limit: 1 << 20)
            .flatMap { ClaudeJSON.parse($0) as? [String: Any] }
        let name = ClaudeJSON.string(manifest?["name"]) ?? String(key.split(separator: "@").first ?? "")
        var configs: [String: Any] = [:]
        switch manifest?["mcpServers"] {
        case let inline as [String: Any]:
            configs = inline
        case let file as String:
            configs = serverFile(pluginRoot + "/" + file)
        case let files as [Any]:
            for file in files.compactMap({ $0 as? String }) { configs.merge(serverFile(pluginRoot + "/" + file)) { a, _ in a } }
        default:
            configs = serverFile(pluginRoot + "/.mcp.json")
        }
        return configs.keys.sorted().map {
            ClaudeMCPPluginServer(plugin: name, key: key, server: $0, info: ClaudeMCPServerInfo(configs[$0]),
                                  projectPath: projectPath, implicit: implicit)
        }
    }

    /// A .mcp.json-shaped file: {"mcpServers": {...}} or the servers alone.
    static func serverFile(_ path: String) -> [String: Any] {
        guard let json = ClaudeFileIO.read(URL(fileURLWithPath: path).standardizedFileURL.path, limit: 1 << 20)
            .flatMap({ ClaudeJSON.parse($0) as? [String: Any] }) else { return [:] }
        if let servers = ClaudeJSON.object(json["mcpServers"]) { return servers }
        return json.filter { $0.value is [String: Any] }
    }

    /// Whether the plugin is on in the repo: the user settings'
    /// enabledPlugins, overridden by the repo's settings.json, then by its
    /// settings.local.json.
    static func isEnabled(_ plugin: ClaudeMCPPluginServer, settings: [[String: Any]]) -> Bool {
        var enabled = plugin.implicit
        for layer in settings {
            if let value = ClaudeJSON.bool(ClaudeJSON.object(layer["enabledPlugins"])?[plugin.key]) { enabled = value }
        }
        return enabled
    }

    private static func pluginName(_ path: String) -> String {
        ClaudeFileIO.read(path + "/.claude-plugin/plugin.json", limit: 1 << 20)
            .flatMap { ClaudeJSON.parse($0) as? [String: Any] }
            .flatMap { ClaudeJSON.string($0["name"]) } ?? (path as NSString).lastPathComponent
    }

    private static func directories(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            .filter { !$0.hasPrefix(".") && ClaudeFileIO.isDirectory(path + "/" + $0, followingLinks: true) }.sorted()
    }
}

// MARK: - The repo's own files

/// What a repo's own files say about MCP.
struct ClaudeMCPRepoFiles {
    /// .mcp.json's servers.
    var projectServers: [String: Any] = [:]
    /// .claude/settings.local.json, nil when there is none or it cannot be read.
    var localSettings: [String: Any]?
    /// Why Brim writes no switch into settings.local.json (not JSON, a byte
    /// order mark, a key named twice, a link); nil when it can.
    var localSettingsProblem: String?
    /// .claude/settings.json (often committed).
    var sharedSettings: [String: Any] = [:]

    static func read(root: String) -> ClaudeMCPRepoFiles {
        var files = ClaudeMCPRepoFiles()
        files.projectServers = ClaudeMCPPlugins.serverFile(root + "/.mcp.json")
        let local = ClaudeMCPSettingsFile.path(root: root)
        if let link = ClaudeMCPSettingsFile.linkProblem(root: root) {
            files.localSettingsProblem = ClaudeMCPSettingsError.link(link).message
        }
        if ClaudeFileIO.exists(local) {
            do {
                guard let data = ClaudeFileIO.read(local, limit: ClaudeMCPSettingsFile.sizeLimit) else {
                    throw ClaudeMCPSettingsError.unreadable(local)
                }
                _ = try ClaudeMCPSettingsFile.document(data, path: local)
                files.localSettings = ClaudeJSON.parse(data) as? [String: Any]
            } catch {
                files.localSettingsProblem = files.localSettingsProblem
                    ?? (error as? ClaudeMCPSettingsError)?.message ?? ClaudeMCPSettingsError.unreadable(local).message
            }
        }
        files.sharedSettings = ClaudeFileIO.read(root + "/.claude/settings.json", limit: ClaudeMCPSettingsFile.sizeLimit)
            .flatMap { ClaudeJSON.parse($0) as? [String: Any] } ?? [:]
        return files
    }
}

// MARK: - The catalog

/// One server on a repo's page, one switch.
struct ClaudeMCPEntry: Equatable, Identifiable {
    enum Group: Int, CaseIterable { case repo, user, plugin, connector }
    enum Source: Equatable { case local, project, user, plugin, connector }

    /// Whose deny turns it off now.
    enum Deny: Equatable {
        case none
        /// Brim's own entry in the repo's settings.local.json.
        case brim
        /// An entry Brim did not write: in settings.local.json (Brim may
        /// remove it once the person confirms) or in a file Brim never edits.
        case outside(removable: Bool)
    }

    /// Why it has no switch here: it runs in no account.
    enum Hidden: Equatable {
        /// Every account has a server of this repo at the same address
        /// (Claude Code drops the plugin's).
        case repoHasItsOwn
        /// Every account has one of the person's servers at the same address.
        case userHasSame
        /// The plugin is off in this repo (enabledPlugins).
        case pluginOff
        /// All claude.ai connectors are off in this repo.
        case connectorsOff
        /// A .mcp.json server no account approved yet.
        case notApproved
        /// A .mcp.json server every account declined.
        case declined
    }

    /// Its runtime name: what a deny names.
    var name: String
    var group: Group
    var source: Source
    var info: ClaudeMCPServerInfo?
    var deny: Deny = .none
    var hidden: Hidden?
    /// Labels of the accounts whose /mcp toggle turned it off here.
    var toggledIn: [String] = []
    /// Labels of the accounts that do not have it (local and user scope):
    /// what Copy to every account adds.
    var missingIn: [String] = []
    /// The accounts hold it differently, so Copy to every account copies
    /// nothing (local scope; user scope when the default account lacks it).
    var conflict = false
    /// Labels of the accounts whose Claude Code waits for its MCP sign-in.
    var signInIn: [String] = []
    /// Labels of the accounts that have not trusted the repo yet, for a
    /// server whose headers come from a headersHelper (Claude Code runs the
    /// helper only in a trusted folder; verified with 2.1.325).
    var untrustedIn: [String] = []
    /// Labels of the accounts where a server of this repo with the same name
    /// runs instead (a user server).
    var shadowedIn: [String] = []
    /// That is so in every account that has it.
    var shadowed = false
    /// Labels of the accounts where Claude Code drops this plugin for a
    /// server at the same address. It loses its switch only when that is
    /// every account (`hidden`).
    var hiddenIn: [String] = []
    /// A .mcp.json server: the accounts that have not approved it, and the
    /// ones that declined it.
    var notApprovedIn: [String] = []
    var declinedIn: [String] = []
    /// A server of the other group (this repo's, or the person's) has the
    /// same name, so this switch turns both off: denies match by name.
    var sharesName = false
    /// Brim added it here, as this kind ("stripe").
    var addedKind: String?

    var id: String { "\(group.rawValue)|\(name)" }
    var isOn: Bool { deny == .none }
    /// The switch turns it off or on. A deny Brim did not write is turned on
    /// only through a confirmation (Turn on…), never by the switch.
    var switchable: Bool { hidden == nil && (deny == .none || deny == .brim) }
}

struct ClaudeMCPRepoServers: Equatable {
    var root: String
    var entries: [ClaudeMCPEntry]
    /// The "All claude.ai connectors" switch (disableClaudeAiConnectors).
    var connectors: ClaudeMCPEntry.Deny
    /// Why no switch can be written into settings.local.json, or nil.
    var settingsProblem: String?
    /// Labels of the accounts whose .claude.json was read, in launch order.
    var accounts: [String] = []
    /// Labels of the accounts whose .claude.json is missing or unreadable:
    /// shown, and left out of every plan.
    var unreadable: [String] = []

    func group(_ group: ClaudeMCPEntry.Group) -> [ClaudeMCPEntry] { entries.filter { $0.group == group } }
    func entry(_ id: String) -> ClaudeMCPEntry? { entries.first { $0.id == id } }
    /// The labels, or nil when they are every account.
    func some(_ labels: [String]) -> [String]? { Set(labels) == Set(accounts) ? nil : labels }
}

enum ClaudeMCPCatalog {
    static let connectorPrefix = "claude.ai "

    /// The names `deniedMcpServers` turns off in a settings object.
    static func deniedNames(_ settings: [String: Any]?) -> [String] {
        (ClaudeJSON.array(settings?["deniedMcpServers"]) ?? []).compactMap {
            ClaudeJSON.object($0).flatMap { ClaudeJSON.string($0["serverName"]) }
        }
    }

    /// The repo's servers, each with its switch. `folders` are the account
    /// folders in launch order (the unreadable ones are only named),
    /// `userSettings` the shared ~/.claude/settings.json, `state` Brim's own
    /// record of what it switched and added. What runs differs per account
    /// (its own local and user servers, its /mcp toggles, its .mcp.json
    /// approvals), so each is worked out per account first.
    static func build(root: String, folders: [ClaudeMCPFolderConfig], files: ClaudeMCPRepoFiles,
                      userSettings: [String: Any], plugins: [ClaudeMCPPluginServer],
                      state: ClaudeMCPState) -> ClaudeMCPRepoServers {
        let readable = folders.filter(\.readable)
        let localDenied = Set(deniedNames(files.localSettings))
        let elsewhereDenied = Set(deniedNames(files.sharedSettings) + deniedNames(userSettings))
        let owned = Set(state.denies[root] ?? [])
        func deny(_ name: String) -> ClaudeMCPEntry.Deny {
            if localDenied.contains(name) { return owned.contains(name) ? .brim : .outside(removable: true) }
            if elsewhereDenied.contains(name) { return .outside(removable: false) }
            return .none
        }
        func labels(_ test: (ClaudeMCPFolderConfig) -> Bool) -> [String] { readable.filter(test).map(\.label) }
        let settingsLayers = [userSettings, files.sharedSettings, files.localSettings ?? [:]]
        func approval(_ name: String, _ folder: ClaudeMCPFolderConfig) -> ClaudeMCPApproval {
            ClaudeMCPApproval.of(name, layers: settingsLayers + [folder.project(root)])
        }
        /// What runs under a repo name in one account: its local server,
        /// else the .mcp.json one once that account approved it.
        func repoConfig(_ name: String, in folder: ClaudeMCPFolderConfig) -> Any? {
            if let local = folder.localServers(root)[name] { return local }
            if let project = files.projectServers[name], approval(name, folder) == .approved { return project }
            return nil
        }
        func common(_ entry: inout ClaudeMCPEntry) {
            let name = entry.name
            entry.deny = deny(name)
            entry.toggledIn = labels { $0.toggledOff(root).contains(name) }
            entry.signInIn = labels { $0.needsSignIn.contains(name) }
        }
        var entries: [ClaudeMCPEntry] = []

        // This repo only: local scope in any account, and .mcp.json.
        let repoNames = Set(readable.flatMap { $0.localServers(root).keys } + files.projectServers.keys).sorted()
        for name in repoNames {
            let holders = readable.filter { $0.localServers(root)[name] != nil }
            let config = holders.first.flatMap { $0.localServers(root)[name] } ?? files.projectServers[name]
            var entry = ClaudeMCPEntry(name: name, group: .repo, source: holders.isEmpty ? .project : .local,
                                       info: config.map(ClaudeMCPServerInfo.init))
            common(&entry)
            if entry.source == .local {
                entry.missingIn = labels { $0.localServers(root)[name] == nil }
                entry.conflict = Set(holders.compactMap { $0.localServers(root)[name].flatMap(ClaudeMCPMirror.comparable) }).count > 1
            } else {
                entry.notApprovedIn = labels { approval(name, $0) == .notApproved }
                entry.declinedIn = labels { approval(name, $0) == .declined }
                if !readable.isEmpty, !readable.contains(where: { approval(name, $0) == .approved }) {
                    entry.hidden = entry.declinedIn.count == readable.count ? .declined : .notApproved
                }
            }
            entry.addedKind = state.servers[name].flatMap { $0.repos.contains(root) ? $0.kind : nil }
            if entry.info?.usesHeadersHelper == true { entry.untrustedIn = labels { !$0.trusts(root) } }
            entries.append(entry)
        }

        // Your servers: user scope, the union across accounts.
        let userNames = Set(readable.flatMap(\.userServers.keys)).sorted()
        for name in userNames {
            let holders = readable.filter { $0.userServers[name] != nil }
            var entry = ClaudeMCPEntry(name: name, group: .user, source: .user,
                                       info: holders.first.map { ClaudeMCPServerInfo($0.userServers[name]) })
            common(&entry)
            entry.missingIn = labels { $0.userServers[name] == nil }
            entry.conflict = !holders.contains { $0.folder.isEmpty }
                && Set(holders.compactMap { $0.userServers[name].flatMap(ClaudeMCPMirror.comparable) }).count > 1
            entry.shadowedIn = holders.filter { repoConfig(name, in: $0) != nil }.map(\.label)
            entry.shadowed = !holders.isEmpty && entry.shadowedIn.count == holders.count
            entries.append(entry)
        }
        let userSet = Set(userNames)
        let repoSet = Set(repoNames)
        for index in entries.indices {
            entries[index].sharesName = entries[index].group == .repo ? userSet.contains(entries[index].name)
                                                                      : repoSet.contains(entries[index].name)
        }

        // Plugins: Claude Code drops one in an account where another enabled
        // server has the same endpoint; it loses its switch only where that
        // is every account.
        func covering(_ endpoint: String, in folder: ClaudeMCPFolderConfig) -> ClaudeMCPEntry.Hidden? {
            let off = Set(folder.toggledOff(root))
            func on(_ name: String) -> Bool { deny(name) == .none && !off.contains(name) }
            for name in repoNames where on(name) {
                if let config = repoConfig(name, in: folder), ClaudeMCPServerInfo(config).endpoint == endpoint { return .repoHasItsOwn }
            }
            for (name, config) in folder.userServers where on(name) && repoConfig(name, in: folder) == nil {
                if ClaudeMCPServerInfo(config).endpoint == endpoint { return .userHasSame }
            }
            return nil
        }
        for plugin in plugins where plugin.projectPath == nil || plugin.projectPath == root {
            guard !entries.contains(where: { $0.group == .plugin && $0.name == plugin.runtimeName }) else { continue }
            var entry = ClaudeMCPEntry(name: plugin.runtimeName, group: .plugin, source: .plugin, info: plugin.info)
            common(&entry)
            if !ClaudeMCPPlugins.isEnabled(plugin, settings: settingsLayers) {
                entry.hidden = .pluginOff
            } else if let endpoint = plugin.info.endpoint {
                let covered = readable.compactMap { folder in covering(endpoint, in: folder).map { (folder.label, $0) } }
                if !readable.isEmpty, covered.count == readable.count {
                    entry.hidden = covered.contains { $0.1 == .repoHasItsOwn } ? .repoHasItsOwn : .userHasSame
                } else {
                    entry.hiddenIn = covered.map { $0.0 }
                }
            }
            entries.append(entry)
        }

        // claude.ai connectors Brim has seen in any account.
        let connectorsLocal = ClaudeJSON.bool(files.localSettings?["disableClaudeAiConnectors"]) == true
        let connectorsElsewhere = ClaudeJSON.bool(files.sharedSettings["disableClaudeAiConnectors"]) == true
            || ClaudeJSON.bool(userSettings["disableClaudeAiConnectors"]) == true
        let connectors: ClaudeMCPEntry.Deny = connectorsLocal
            ? (state.connectorsOff.contains(root) ? .brim : .outside(removable: true))
            : (connectorsElsewhere ? .outside(removable: false) : .none)
        for name in Set(readable.flatMap(\.connectors)).sorted() {
            var entry = ClaudeMCPEntry(name: name, group: .connector, source: .connector)
            common(&entry)
            if connectors != .none { entry.hidden = .connectorsOff }
            entries.append(entry)
        }
        return ClaudeMCPRepoServers(root: root, entries: entries, connectors: connectors,
                                    settingsProblem: files.localSettingsProblem, accounts: readable.map(\.label),
                                    unreadable: folders.filter { !$0.readable }.map(\.label))
    }

    /// The local servers of every other repo, for Add server…'s Copy: one per
    /// (repo, name) whose folders agree on it, as canonical JSON.
    static func copyable(folders: [ClaudeMCPFolderConfig], excluding root: String) -> [ClaudeMCPCopySource] {
        var found: [String: [String: Set<String>]] = [:]
        for folder in folders where folder.readable {
            for (key, project) in folder.projects where key != root {
                for (name, config) in ClaudeJSON.object(project["mcpServers"]) ?? [:] {
                    if let json = ClaudeMCPMirror.comparable(config) { found[key, default: [:]][name, default: []].insert(json) }
                }
            }
        }
        var sources: [ClaudeMCPCopySource] = []
        for (key, servers) in found where ClaudeFileIO.isDirectory(key, followingLinks: true) {
            for (name, shapes) in servers where shapes.count == 1 {
                let config = folders.lazy.compactMap { ClaudeJSON.object($0.projects[key]?["mcpServers"])?[name] }.first
                if let config, let json = ClaudeMCPMirror.canonicalJSON(config) {
                    sources.append(ClaudeMCPCopySource(repo: key, name: name, json: json, info: ClaudeMCPServerInfo(config)))
                }
            }
        }
        return sources.sorted { $0.repo == $1.repo ? $0.name < $1.name : $0.repo < $1.repo }
    }

    /// Running sessions whose working directory files under the repo.
    static func openSessions(_ sessions: [ClaudeLiveSession], root: String) -> Int {
        var pids = Set<Int32>()
        for session in sessions {
            guard let cwd = session.cwd, ClaudeRepoKey.root(of: cwd) == root else { continue }
            pids.insert(session.pid)
        }
        return pids.count
    }
}

/// A server another repo has of its own, to copy into this one.
struct ClaudeMCPCopySource: Equatable, Identifiable {
    var repo: String
    var name: String
    /// Its configuration as canonical JSON: it can hold keys, so it is
    /// handed to the CLI and never shown.
    var json: String
    var info: ClaudeMCPServerInfo

    var id: String { repo + "|" + name }
}
