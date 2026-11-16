// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// MCP by repo (T-29, fixed in the 2026-11-13 review pass): repo keys, the
/// repo list, the per-repo catalog from fixture .claude.json files and plugin
/// manifests (worked out per account), .mcp.json approvals, the deny-file
/// switches and the files Brim refuses to edit, git's view of
/// settings.local.json, the local and user mirrors, Stripe's OAuth server,
/// Brim's record (ownership, partial adds and removals, an undecodable
/// record), the CLI runner and the source rules. Everything runs in temporary
/// folders and scratch git repos; no real Claude Code folder, repo or Brim
/// state is read or written, and no `claude` is started.
///
/// One check runs only when asked, against a sandbox the caller made:
/// BRIM_TEST_CLAUDE_SANDBOX=<folder> (with BRIM_TEST_FAKE_MCP=<harmless stdio
/// server>) runs the real `claude` CLI on throwaway config folders and a
/// throwaway repo inside it.
enum BrimClaudeMCPTests {
    static func run(_ suite: TestSuite) {
        let scratch = BrimClaudeAccountsTests.Scratch()
        defer { scratch.remove() }
        repoKeys(suite, scratch)
        repoList(suite, scratch)
        plugins(suite, scratch)
        catalog(suite, scratch)
        perAccount(suite)
        approvals(suite)
        unreadableFolders(suite)
        orderedJSON(suite)
        denyFile(suite, scratch)
        refusedFiles(suite, scratch)
        gitChecks(suite, scratch)
        submodule(suite, scratch)
        localMirror(suite)
        userMirror(suite)
        mirrorEnvironment(suite, scratch)
        pastedServers(suite)
        stripe(suite)
        sessions(suite)
        state(suite, scratch)
        records(suite)
        runner(suite, scratch)
        sourceRules(suite)
        let environment = ProcessInfo.processInfo.environment
        if let sandbox = environment["BRIM_TEST_CLAUDE_SANDBOX"], let fake = environment["BRIM_TEST_FAKE_MCP"] {
            claudeIntegration(suite, sandbox: sandbox, fakeServer: fake)
        }
    }

    // MARK: Fixtures

    private static func write(_ path: String, _ text: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private static func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private static func mode(_ path: String) -> Int {
        var info = stat()
        return stat(path, &info) == 0 ? Int(info.st_mode & 0o777) : -1
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: String, home: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory, "-c", "user.email=test@example.com", "-c", "user.name=test"] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": home, "GIT_TERMINAL_PROMPT": "0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A scratch git repo with one commit.
    private static func repo(_ path: String, home: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        git(["init", "-q"], in: path, home: home)
        write(path + "/README", "x\n")
        git(["add", "README"], in: path, home: home)
        git(["commit", "-qm", "init"], in: path, home: home)
    }

    private static func folder(_ folder: String, _ label: String, _ json: String, needsAuth: String? = nil) -> ClaudeMCPFolderConfig {
        ClaudeMCPFolderConfig(folder: folder, label: label, configData: Data(json.utf8), needsAuthCache: needsAuth.map { Data($0.utf8) })
    }

    // MARK: Repo keys

    private static func repoKeys(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let home = scratch.folder("keys-home")
        let main = scratch.folder("keys/main")
        repo(main, home: home)
        let deeper = scratch.folder("keys/main/sub/deeper")
        suite.expect(ClaudeRepoKey.root(of: deeper) == main && ClaudeRepoKey.root(of: main) == main,
                     "a subfolder files under its repo's root")
        let worktree = scratch.root + "/keys/main-wt"
        let added = git(["worktree", "add", "-q", worktree], in: main, home: home)
        suite.expect(added.status == 0 && ClaudeRepoKey.root(of: worktree) == main
                     && ClaudeRepoKey.root(of: worktree + "/sub").hasPrefix(main),
                     "a worktree files under its main repo (.git -> gitdir -> commondir): \(added.output)")
        let link = scratch.root + "/keys/link-to-main"
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: main)
        suite.expect(ClaudeRepoKey.root(of: link) == main && ClaudeRepoKey.root(of: link + "/sub/deeper") == main,
                     "a path through a symlink files under the resolved repo")
        let plain = scratch.folder("keys/plain/psub")
        suite.expect(ClaudeRepoKey.root(of: plain) == plain && ClaudeRepoKey.root(of: scratch.root + "/keys/plain") == scratch.root + "/keys/plain",
                     "outside git each folder is its own key, its realpath")
        let module = scratch.folder("keys/module")
        write(module + "/.git", "gitdir: ../main/.git/modules/x\n")
        suite.expect(ClaudeRepoKey.root(of: module) == module, "a .git file without commondir (a submodule) is its own repo")
        suite.expect(ClaudeRepoKey.gitDirectory(root: main) == main + "/.git"
                     && ClaudeRepoKey.gitDirectory(root: worktree) == main + "/.git"
                     && ClaudeRepoKey.gitDirectory(root: plain) == nil,
                     "the git folder whose info/exclude applies: the repo's own, a worktree's common one")
    }

    // MARK: Repo list

    private static func repoList(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let home = scratch.folder("list-home")
        let alpha = scratch.folder("list/alpha")
        repo(alpha, home: home)
        let beta = scratch.folder("list/beta")
        let gamma = scratch.folder("list/Gamma")
        let delta = scratch.folder("list/delta")
        let projects = scratch.folder("list-home/.claude/projects")
        let otherProjects = scratch.folder("list-home/.claude-other/projects")
        /// A transcript last written at `seconds`, in a slug folder a sync
        /// wrote into just now: the real failure (review of T-38) read the
        /// folder's own date, which every sync write moves, so after the
        /// migration's full sync every repo was "used" then.
        func used(_ path: String, _ seconds: TimeInterval, in projects: String) {
            let folder = projects + "/" + ClaudeSessionIndex.projectSlug(path)
            write(folder + "/00000000-0000-4000-8000-000000000001.jsonl", "{}\n")
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)],
                                                   ofItemAtPath: folder + "/00000000-0000-4000-8000-000000000001.jsonl")
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder)
        }
        used(alpha + "/sub", 2_000, in: projects)
        used(beta, 3_000, in: projects)
        _ = scratch.folder("list/alpha/sub")
        // gamma was used only on another account, whose projects/ is its own.
        used(gamma, 1_000, in: otherProjects)
        let repos = ClaudeMCPRepoList.build(keys: [alpha, alpha + "/sub", beta, gamma, scratch.root + "/list/gone"],
                                            added: [delta], projectsDirectories: [projects, otherProjects])
        suite.expect(repos.map(\.root) == [beta, alpha, gamma, delta],
                     "repos fold their subfolders, drop gone paths, sort by last use then name: \(repos.map(\.root))")
        suite.expect(repos.first { $0.root == gamma }?.lastUsed == Date(timeIntervalSince1970: 1_000)
                        && ClaudeMCPRepoList.build(keys: [gamma], added: [], projectsDirectories: [projects]).first?.lastUsed == nil,
                     "a repo's last use counts every account's projects/, not only ~/.claude's")
        suite.expect(repos.first { $0.root == alpha }?.lastUsed == Date(timeIntervalSince1970: 2_000)
                     && repos.first { $0.root == delta }?.added == true && repos.first { $0.root == beta }?.added == false,
                     "a repo's last use is its newest transcript, not the folder's date; added repos are marked")
        suite.expect(ClaudeMCPRepoList.filter(repos, "GAM").map(\.root) == [gamma] && ClaudeMCPRepoList.filter(repos, " ").count == 4,
                     "search matches the path, any case")
        suite.expect(ClaudeMCPRepoList.name(home, home: home) == "~" && ClaudeMCPRepoList.name(alpha, home: home) == "alpha",
                     "the home folder reads as ~")
    }

    // MARK: Plugins

    private static func plugins(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let home = scratch.folder("plugins-home")
        let cache = home + "/.claude/plugins/cache/official"
        write(cache + "/stripe/1/.mcp.json", #"{"mcpServers":{"stripe":{"type":"http","url":"https://mcp.stripe.com"}}}"#)
        write(cache + "/stripe/1/.claude-plugin/plugin.json", #"{"name":"stripe"}"#)
        write(cache + "/xcode/1/.mcp.json", #"{"mcpServers":{"xcode":{"type":"stdio","command":"xcrun","args":["mcpbridge"]}}}"#)
        write(cache + "/xcode/1/.claude-plugin/plugin.json", #"{"name":"xcode-integration"}"#)
        write(cache + "/supabase/1/agents/claude/.mcp.json", #"{"mcpServers":{"supabase":{"type":"http","url":"https://mcp.supabase.com/mcp"}}}"#)
        write(cache + "/supabase/1/.claude-plugin/plugin.json", #"{"name":"supabase","mcpServers":"./agents/claude/.mcp.json"}"#)
        write(cache + "/resend/1/.claude-plugin/plugin.json", #"{"name":"resend","mcpServers":{"resend":{"type":"http","url":"https://mcp.resend.com"}}}"#)
        write(cache + "/playwright/1/.mcp.json", #"{"playwright":{"command":"npx","args":["@playwright/mcp@latest"]}}"#)
        write(cache + "/local/1/.mcp.json", #"{"mcpServers":{"only":{"type":"stdio","command":"x"}}}"#)
        write(home + "/.claude/plugins/installed_plugins.json", """
            {"version":2,"plugins":{
             "stripe@official":[{"scope":"user","installPath":"\(cache)/stripe/1"}],
             "xcode@official":[{"scope":"user","installPath":"\(cache)/xcode/1"}],
             "supabase@official":[{"scope":"user","installPath":"\(cache)/supabase/1"}],
             "resend@official":[{"scope":"user","installPath":"\(cache)/resend/1"}],
             "playwright@official":[{"scope":"user","installPath":"\(cache)/playwright/1"}],
             "local@official":[{"scope":"project","projectPath":"/nowhere/repo","installPath":"\(cache)/local/1"}]}}
            """)
        write(home + "/.claude/plugins/synced/bucket/productivity/.claude-plugin/plugin.json", #"{"name":"productivity"}"#)
        write(home + "/.claude/plugins/synced/bucket/productivity/.mcp.json", #"{"mcpServers":{"slack":{"type":"http","url":"https://mcp.slack.com/mcp"}}}"#)
        write(home + "/.claude/skills/heygen-skills/.claude-plugin/plugin.json", #"{"name":"heygen"}"#)
        write(home + "/.claude/skills/heygen-skills/.mcp.json", #"{"mcpServers":{"heygen":{"type":"http","url":"https://mcp.heygen.com/mcp/v1/"}}}"#)
        write(home + "/.claude/skills/plain-skill/SKILL.md", "no plugin here\n")
        let found = ClaudeMCPPlugins.scan(home: home)
        suite.expect(Set(found.map(\.runtimeName)) == ["plugin:stripe:stripe", "plugin:xcode-integration:xcode",
                                                       "plugin:supabase:supabase", "plugin:resend:resend",
                                                       "plugin:playwright:playwright", "plugin:local:only",
                                                       "plugin:productivity:slack", "plugin:heygen:heygen"],
                     "plugin servers get their runtime names from plugin.json's name, inline, named-file, flat, synced and skills-dir manifests: \(found.map(\.runtimeName))")
        suite.expect(found.first { $0.server == "only" }?.projectPath == "/nowhere/repo"
                     && found.first { $0.plugin == "productivity" }?.key == "productivity@synced"
                     && found.first { $0.plugin == "heygen" }?.key == "heygen@skills-dir"
                     && found.first { $0.plugin == "xcode-integration" }?.key == "xcode@official",
                     "each server keeps its enabledPlugins key and a project install's repo")
        let stripe = found.first { $0.plugin == "stripe" }!
        suite.expect(ClaudeMCPPlugins.isEnabled(stripe, settings: [["enabledPlugins": ["stripe@official": true]]])
                     && !ClaudeMCPPlugins.isEnabled(stripe, settings: [["enabledPlugins": ["stripe@official": true]],
                                                                        ["enabledPlugins": ["stripe@official": false]]])
                     && !ClaudeMCPPlugins.isEnabled(stripe, settings: [])
                     && ClaudeMCPPlugins.isEnabled(found.first { $0.plugin == "heygen" }!, settings: []),
                     "a repo's settings override the user's enabledPlugins; synced and skills-dir plugins are on unless set false")
    }

    // MARK: Catalog

    private static func catalog(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let root = scratch.folder("catalog/acme")
        let other = scratch.folder("catalog/beta")
        let stripe = #"{"type":"http","url":"https://mcp.stripe.com"}"#
        let defaultConfig = folder("", "rhodes", """
            {"mcpServers":{"mobbin":{"type":"http","url":"https://api.mobbin.com/mcp"},
                           "heygen":{"type":"http","url":"https://mcp.heygen.com/mcp/v1"},
                           "linear":{"type":"http","url":"https://mcp.linear.app/mcp"}},
             "claudeAiMcpEverConnected":["claude.ai Gmail","claude.ai Slack","appllama"],
             "mcpNeedsAuthNoticed":["linear"],
             "projects":{"\(root)":{"hasTrustDialogAccepted":true,
               "mcpServers":{"stripe-acme":\(stripe),
                             "whatnot":{"type":"http","url":"https://mcp.whatnot.com"},
                             "helped":{"type":"http","url":"https://mcp.helped.example","headersHelper":"/x/helper"},
                             "sendly":{"type":"stdio","command":"npx","args":["@sendly/mcp"],"env":{"SENDLY_API_KEY":"secret-value"}},
                             "linear":{"type":"http","url":"https://mcp.linear.app/mcp","headers":{"Authorization":"Bearer abc"}}},
               "disabledMcpServers":["mobbin"]},
              "\(other)":{"mcpServers":{"beta-only":{"type":"stdio","command":"b"}}}}}
            """, needsAuth: #"{"whatnot":{"timestamp":1},"plugin:vercel:vercel":{"timestamp":1}}"#)
        let stern = folder("/Users/x/.claude-stern", "stern", """
            {"mcpServers":{"mobbin":{"type":"http","url":"https://api.mobbin.com/mcp"},
                           "heygen":{"type":"http","url":"https://mcp.heygen.com/mcp/v1/"},
                           "resend":{"type":"http","url":"https://mcp.resend.com","headersHelper":"/x"}},
             "claudeAiMcpEverConnected":["claude.ai Google Drive"],
             "projects":{"\(root)":{"mcpServers":{"sendly":{"type":"stdio","command":"npx","args":["@sendly/mcp","--v2"]},
                                                  "stripe-acme":\(stripe)},
                                    "disabledMcpServers":["claude.ai Gmail"]}}}
            """, needsAuth: #"{"whatnot":{"timestamp":1}}"#)
        let plugins = [
            ClaudeMCPPluginServer(plugin: "stripe", key: "stripe@official", server: "stripe",
                                  info: ClaudeMCPServerInfo(["type": "http", "url": "https://mcp.stripe.com/"])),
            ClaudeMCPPluginServer(plugin: "heygen", key: "heygen@skills-dir", server: "heygen",
                                  info: ClaudeMCPServerInfo(["type": "http", "url": "https://mcp.heygen.com/mcp/v1/"]), implicit: true),
            ClaudeMCPPluginServer(plugin: "supabase", key: "supabase@official", server: "supabase",
                                  info: ClaudeMCPServerInfo(["type": "http", "url": "https://mcp.supabase.com/mcp"])),
            ClaudeMCPPluginServer(plugin: "vercel", key: "vercel@official", server: "vercel",
                                  info: ClaudeMCPServerInfo(["type": "http", "url": "https://mcp.vercel.com"])),
            ClaudeMCPPluginServer(plugin: "local", key: "local@official", server: "only",
                                  info: ClaudeMCPServerInfo(["command": "x"]), projectPath: other),
        ]
        var files = ClaudeMCPRepoFiles()
        files.projectServers = ["xcodebuildmcp": ["type": "stdio", "command": "npx", "args": ["xcodebuildmcp@latest"]]]
        files.localSettings = ["deniedMcpServers": [["serverName": "whatnot"], ["serverName": "plugin:vercel:vercel"]],
                               "enabledMcpjsonServers": ["xcodebuildmcp"], "permissions": ["allow": ["Bash(ls)"]]]
        files.sharedSettings = ["deniedMcpServers": [["serverName": "claude.ai Slack"]],
                                "enabledPlugins": ["supabase@official": false]]
        let userSettings: [String: Any] = ["enabledPlugins": ["stripe@official": true, "supabase@official": true,
                                                              "vercel@official": true, "local@official": true]]
        var state = ClaudeMCPState()
        state.denies[root] = ["whatnot"]
        state.servers["stripe-acme"] = ClaudeMCPServerRecord(kind: ClaudeMCPStripe.kind, repos: [root])
        let built = ClaudeMCPCatalog.build(root: root, folders: [defaultConfig, stern], files: files,
                                           userSettings: userSettings, plugins: plugins, state: state)
        func entry(_ group: ClaudeMCPEntry.Group, _ name: String) -> ClaudeMCPEntry? {
            built.entries.first { $0.group == group && $0.name == name }
        }
        suite.expect(built.group(.repo).map(\.name) == ["helped", "linear", "sendly", "stripe-acme", "whatnot", "xcodebuildmcp"],
                     "this repo only: local servers from any folder and .mcp.json: \(built.group(.repo).map(\.name))")
        suite.expect(entry(.repo, "whatnot")?.deny == .brim && entry(.repo, "whatnot")?.isOn == false
                     && entry(.repo, "whatnot")?.switchable == true && entry(.repo, "whatnot")?.signInIn == ["rhodes", "stern"]
                     && built.some(["rhodes", "stern"]) == nil && built.some(["stern"]) == ["stern"],
                     "Brim's own deny is its switch turned off; the accounts whose needs-auth cache names it need a sign-in each")
        suite.expect(entry(.repo, "sendly")?.conflict == true && entry(.repo, "whatnot")?.missingIn == ["stern"]
                     && entry(.repo, "stripe-acme")?.addedKind == ClaudeMCPStripe.kind && entry(.repo, "stripe-acme")?.missingIn == []
                     && entry(.repo, "helped")?.untrustedIn == ["stern"] && entry(.repo, "stripe-acme")?.untrustedIn == []
                     && entry(.repo, "xcodebuildmcp")?.source == .project && entry(.repo, "xcodebuildmcp")?.hidden == nil
                     && entry(.repo, "xcodebuildmcp")?.missingIn == [],
                     "conflicts, missing folders, Brim's Stripe server and the trust a headers helper waits for are shown")
        suite.expect(entry(.repo, "linear")?.signInIn == [] && entry(.user, "linear")?.shadowed == true
                     && entry(.user, "linear")?.shadowedIn == ["rhodes"]
                     && entry(.user, "linear")?.sharesName == true && entry(.repo, "linear")?.sharesName == true
                     && entry(.user, "mobbin")?.sharesName == false,
                     "mcpNeedsAuthNoticed is not a sign-in signal; this repo's own linear shadows the user one, and both switches say they match by name")
        suite.expect(built.group(.user).map(\.name) == ["heygen", "linear", "mobbin", "resend"]
                     && entry(.user, "resend")?.missingIn == ["rhodes"] && entry(.user, "mobbin")?.toggledIn == ["rhodes"]
                     && entry(.user, "mobbin")?.isOn == true,
                     "your servers: the union of every folder's user scope, with the /mcp toggles found in each")
        suite.expect(entry(.plugin, "plugin:stripe:stripe")?.hidden == .repoHasItsOwn
                     && entry(.plugin, "plugin:heygen:heygen")?.hidden == .userHasSame
                     && entry(.plugin, "plugin:supabase:supabase")?.hidden == .pluginOff
                     && entry(.plugin, "plugin:vercel:vercel")?.deny == .outside(removable: true)
                     && entry(.plugin, "plugin:vercel:vercel")?.switchable == false
                     && entry(.plugin, "plugin:vercel:vercel")?.signInIn == ["rhodes"]
                     && entry(.plugin, "plugin:local:only") == nil,
                     "plugins: dropped where every account has the same endpoint, off where the repo turns the plugin off; a foreign deny needs a confirmation")
        suite.expect(built.group(.connector).map(\.name) == ["claude.ai Gmail", "claude.ai Google Drive", "claude.ai Slack"]
                     && entry(.connector, "claude.ai Slack")?.deny == .outside(removable: false)
                     && entry(.connector, "claude.ai Gmail")?.toggledIn == ["stern"] && built.connectors == .none,
                     "connectors are the names any folder has seen; a deny in the shared settings.json is not Brim's to remove")
        var allOff = files
        allOff.localSettings?["disableClaudeAiConnectors"] = true
        var owning = state
        owning.connectorsOff = [root]
        suite.expect(ClaudeMCPCatalog.build(root: root, folders: [defaultConfig], files: allOff, userSettings: userSettings,
                                            plugins: [], state: owning).connectors == .brim
                     && ClaudeMCPCatalog.build(root: root, folders: [defaultConfig], files: allOff, userSettings: userSettings,
                                               plugins: [], state: state).group(.connector).allSatisfy { $0.hidden == .connectorsOff },
                     "All claude.ai connectors follows disableClaudeAiConnectors, Brim's when it set it")
        let summaries = built.entries.compactMap { $0.info?.summary }.joined(separator: " ")
        suite.expect(!summaries.contains("secret-value") && !summaries.contains("Bearer") && entry(.repo, "sendly")?.info?.summary == "stdio · npx"
                     && entry(.repo, "stripe-acme")?.info?.summary == "http · mcp.stripe.com"
                     && entry(.repo, "stripe-acme")?.info?.signsInItself == true && entry(.repo, "linear")?.info?.signsInItself == false
                     && entry(.repo, "helped")?.info?.signsInItself == false,
                     "a server shows its transport and host or program, never an env, header or arg value")
        let copies = ClaudeMCPCatalog.copyable(folders: [defaultConfig, stern], excluding: root)
        suite.expect(copies.map(\.name) == ["beta-only"] && copies.first?.repo == other,
                     "Copy from another repo offers the other repos' own servers")
        suite.expect(ClaudeMCPNeedsAuth.names(Data(#"{"a":{"timestamp":1},"claude.ai X":{"id":"i"}}"#.utf8)) == ["a", "claude.ai X"]
                     && ClaudeMCPNeedsAuth.names(Data("nope".utf8)).isEmpty && ClaudeMCPNeedsAuth.names(nil).isEmpty
                     && ClaudeMCPNeedsAuth.path(configDirectory: "/c") == "/c/mcp-needs-auth-cache.json",
                     "the needs-auth cache is read in one place, by its keys")
    }

    /// The real cases behind per-account hiding (2026-11-13): stern alone has
    /// a user-scope resend, and only the default account has a local xcode
    /// in mindrepapp. Claude Code drops the plugin in those accounts only.
    private static func perAccount(_ suite: TestSuite) {
        let root = "/Users/x/Code/mindrepapp"
        let xcode: [String: Any] = ["type": "stdio", "command": "xcrun", "args": ["mcpbridge"]]
        let rhodes = folder("", "rhodes", """
            {"mcpServers":{},"projects":{"\(root)":{"mcpServers":{"xcode":{"type":"stdio","command":"xcrun","args":["mcpbridge"]}}}}}
            """)
        let stern = folder("/s", "stern", """
            {"mcpServers":{"resend":{"type":"http","url":"https://mcp.resend.com/"}},"projects":{}}
            """)
        let work = folder("/w", "work", #"{"mcpServers":{"resend":{"type":"http","url":"https://mcp.resend.com"}},"projects":{"\#(root)":{"disabledMcpServers":["resend"]}}}"#)
        let plugins = [
            ClaudeMCPPluginServer(plugin: "resend", key: "resend@o", server: "resend",
                                  info: ClaudeMCPServerInfo(["type": "http", "url": "https://mcp.resend.com"])),
            ClaudeMCPPluginServer(plugin: "xcode-integration", key: "xcode@o", server: "xcode", info: ClaudeMCPServerInfo(xcode)),
        ]
        let enabled: [String: Any] = ["enabledPlugins": ["resend@o": true, "xcode@o": true]]
        let built = ClaudeMCPCatalog.build(root: root, folders: [rhodes, stern, work], files: ClaudeMCPRepoFiles(),
                                           userSettings: enabled, plugins: plugins, state: ClaudeMCPState())
        let resend = built.entries.first { $0.name == "plugin:resend:resend" }
        let xcodePlugin = built.entries.first { $0.name == "plugin:xcode-integration:xcode" }
        // The real failure: one account's server hid the plugin for all five.
        suite.expect(resend?.hidden == nil && resend?.switchable == true && resend?.hiddenIn == ["stern"],
                     "plugin:resend:resend keeps its switch; only stern (its own resend, not toggled off) drops it: \(String(describing: resend?.hiddenIn))")
        suite.expect(xcodePlugin?.hidden == nil && xcodePlugin?.hiddenIn == ["rhodes"],
                     "plugin:xcode-integration:xcode is hidden only in the account that has mindrepapp's local xcode")
        var denied = ClaudeMCPRepoFiles()
        denied.localSettings = ["deniedMcpServers": [["serverName": "xcode"]]]
        suite.expect(ClaudeMCPCatalog.build(root: root, folders: [rhodes], files: denied, userSettings: enabled, plugins: plugins,
                                            state: ClaudeMCPState()).entries.first { $0.name == "plugin:xcode-integration:xcode" }?.hiddenIn == [],
                     "a server switched off for the repo hides nothing")
        let everywhere = ClaudeMCPCatalog.build(root: root, folders: [rhodes], files: ClaudeMCPRepoFiles(), userSettings: enabled,
                                                plugins: plugins, state: ClaudeMCPState())
        suite.expect(everywhere.entries.first { $0.name == "plugin:xcode-integration:xcode" }?.hidden == .repoHasItsOwn,
                     "with one account, its local server hides the plugin there, which is everywhere")
        // Shadowing, per account: a user server is replaced only where the repo's own of that name runs.
        let both = folder("/b", "both", #"{"mcpServers":{"xcode":{"command":"other"}},"projects":{}}"#)
        let mine = folder("", "rhodes", #"{"mcpServers":{"xcode":{"command":"other"}},"projects":{"\#(root)":{"mcpServers":{"xcode":{"command":"xcrun"}}}}}"#)
        let shadow = ClaudeMCPCatalog.build(root: root, folders: [mine, both], files: ClaudeMCPRepoFiles(), userSettings: [:],
                                            plugins: [], state: ClaudeMCPState())
        let user = shadow.entries.first { $0.group == .user && $0.name == "xcode" }
        suite.expect(user?.shadowedIn == ["rhodes"] && user?.shadowed == false,
                     "a user server is shadowed in the accounts that have the repo's own of that name, not in the others")
    }

    /// .mcp.json servers run only where approved. The real case:
    /// ProjectManager's settings.local.json declines its .mcp.json `linear`.
    private static func approvals(_ suite: TestSuite) {
        let root = "/Users/x/Code/ProjectManager"
        suite.expect(ClaudeMCPApproval.of("linear", layers: [["disabledMcpjsonServers": ["linear"], "enableAllProjectMcpServers": true]]) == .declined
                     && ClaudeMCPApproval.of("linear", layers: [[:], ["enabledMcpjsonServers": ["linear"]]]) == .approved
                     && ClaudeMCPApproval.of("linear", layers: [["enableAllProjectMcpServers": true]]) == .approved
                     && ClaudeMCPApproval.of("linear", layers: [["enabledMcpjsonServers": []], [:]]) == .notApproved,
                     "a decline wins, then an approval or enableAllProjectMcpServers; otherwise it waits for the prompt")
        let linear: [String: Any] = ["type": "http", "url": "https://mcp.linear.app/mcp"]
        let rhodes = folder("", "rhodes", """
            {"mcpServers":{"linear":{"type":"stdio","command":"user-linear"}},
             "projects":{"\(root)":{"enabledMcpjsonServers":[],"disabledMcpjsonServers":[],
                                    "mcpServers":{"linear-server":{"command":"x"}}}}}
            """)
        let stern = folder("/s", "stern", #"{"mcpServers":{"linear":{"type":"stdio","command":"user-linear"}},"projects":{}}"#)
        let plugins = [ClaudeMCPPluginServer(plugin: "linear", key: "linear@o", server: "linear", info: ClaudeMCPServerInfo(linear))]
        var files = ClaudeMCPRepoFiles()
        files.projectServers = ["linear": linear]
        files.localSettings = ["disabledMcpjsonServers": ["linear"]]
        let enabled: [String: Any] = ["enabledPlugins": ["linear@o": true]]
        let declined = ClaudeMCPCatalog.build(root: root, folders: [rhodes, stern], files: files, userSettings: enabled,
                                              plugins: plugins, state: ClaudeMCPState())
        let project = declined.entries.first { $0.group == .repo && $0.name == "linear" }
        let user = declined.entries.first { $0.group == .user && $0.name == "linear" }
        let plugin = declined.entries.first { $0.name == "plugin:linear:linear" }
        suite.expect(project?.hidden == .declined && project?.switchable == false && project?.declinedIn == ["rhodes", "stern"],
                     "a .mcp.json server every account declined shows Declined here, without a switch")
        suite.expect(user?.shadowed == false && user?.shadowedIn == [] && plugin?.hidden == nil && plugin?.hiddenIn == [],
                     "a declined .mcp.json server shadows no user server and hides no plugin")
        files.localSettings = [:]
        let pending = ClaudeMCPCatalog.build(root: root, folders: [rhodes, stern], files: files, userSettings: enabled,
                                             plugins: plugins, state: ClaudeMCPState())
        suite.expect(pending.entries.first { $0.group == .repo && $0.name == "linear" }?.hidden == .notApproved,
                     "one nobody approved yet shows Not approved")
        var stApproved = stern
        stApproved.projects[root] = ["enabledMcpjsonServers": ["linear"]]
        let mixed = ClaudeMCPCatalog.build(root: root, folders: [rhodes, stApproved], files: files, userSettings: enabled,
                                           plugins: plugins, state: ClaudeMCPState())
        let mixedProject = mixed.entries.first { $0.group == .repo && $0.name == "linear" }
        suite.expect(mixedProject?.hidden == nil && mixedProject?.notApprovedIn == ["rhodes"]
                     && mixed.entries.first { $0.group == .user && $0.name == "linear" }?.shadowedIn == ["stern"]
                     && mixed.entries.first { $0.name == "plugin:linear:linear" }?.hiddenIn == ["stern"],
                     "approved in one account: a switch, and it shadows and hides only there")
    }

    /// A folder whose .claude.json is missing or unreadable says nothing
    /// about what it holds: it is named and left out of every plan.
    private static func unreadableFolders(_ suite: TestSuite) {
        let root = "/Users/x/Code/acme"
        let rhodes = folder("", "rhodes", #"{"mcpServers":{"u":{"command":"u"}},"projects":{"\#(root)":{"mcpServers":{"a":{"command":"a"}}}}}"#)
        let broken = ClaudeMCPFolderConfig(folder: "/broken", label: "broken", configData: Data("{ half".utf8))
        let missing = ClaudeMCPFolderConfig(folder: "/missing", label: "missing", configData: nil)
        suite.expect(!broken.readable && !missing.readable && rhodes.readable, "a missing or unreadable .claude.json is not readable")
        let built = ClaudeMCPCatalog.build(root: root, folders: [rhodes, broken, missing], files: ClaudeMCPRepoFiles(),
                                           userSettings: [:], plugins: [], state: ClaudeMCPState())
        suite.expect(built.unreadable == ["broken", "missing"] && built.accounts == ["rhodes"]
                     && built.entries.allSatisfy { $0.missingIn.isEmpty },
                     "unreadable folders are named, and never listed as missing a server")
        let local = ClaudeMCPMirror.localPlan(repo: root, servers: ["": rhodes.localServers(root)], folders: [""], describe: { $0 })
        suite.expect(local.isEmpty, "the repo mirror plans nothing for folders it could not read")
    }

    // MARK: JSON that keeps its order

    private static func orderedJSON(_ suite: TestSuite) {
        let text = """
            {
              "permissions": {
                "allow": [
                  "Bash(ls)",
                  "mcp__x\\u00e9"
                ],
                "deny": []
              },
              "number": 1.50,
              "big": 12345678901234567890,
              "empty": {},
              "flag": false
            }

            """
        let parsed = ClaudeOrderedJSON.parse(Data(text.utf8))
        suite.expect(parsed?.render() == String(text.dropLast()), "a file as Claude Code writes it renders back byte for byte")
        suite.expect(parsed?.members?.map(\.key) == ["permissions", "number", "big", "empty", "flag"]
                     && parsed?["number"] == .scalar("1.50") && parsed?["big"] == .scalar("12345678901234567890"),
                     "keys keep their order and numbers their spelling")
        suite.expect(ClaudeOrderedJSON.parse(Data("{nope".utf8)) == nil && ClaudeOrderedJSON.parse(Data("[1,2]".utf8))?.members == nil,
                     "only valid JSON parses")
        suite.expect(ClaudeOrderedJSON.quote("a\"b/c") == #""a\"b/c""#, "quoting escapes as JSON does, slashes left alone")
    }

    // MARK: settings.local.json

    private static func denyFile(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let root = scratch.folder("deny/repo")
        let file = ClaudeMCPSettingsFile.path(root: root)
        // A new file: created, two-space JSON, nothing else in it.
        let created = try? ClaudeMCPSettingsFile.apply(root: root, change: ClaudeMCPSwitchChange(deny: ["fake-local"]))
        suite.expect(created == true && read(file) == "{\n  \"deniedMcpServers\": [\n    {\n      \"serverName\": \"fake-local\"\n    }\n  ]\n}\n"
                     && mode(file) == 0o644,
                     "the first switch creates .claude/settings.local.json with Brim's deny alone: \(read(file))")
        // Claude Code's own keys, a foreign deny and a URL deny stay as they were.
        let existing = """
            {
              "permissions": {
                "allow": [
                  "Bash(git status)"
                ]
              },
              "deniedMcpServers": [
                {
                  "serverName": "theirs"
                },
                {
                  "serverUrl": "https://*.example.com/*"
                }
              ],
              "enabledMcpjsonServers": [
                "linear"
              ],
              "threshold": 1.50
            }

            """
        write(file, existing)
        chmod(file, 0o600)
        _ = try? ClaudeMCPSettingsFile.apply(root: root, change: ClaudeMCPSwitchChange(deny: ["mine"]))
        let after = read(file)
        let json = ClaudeJSON.parse(Data(after.utf8)) as? [String: Any]
        let denied = ClaudeMCPCatalog.deniedNames(json)
        suite.expect(denied == ["theirs", "mine"] && after.contains("\"serverUrl\": \"https://*.example.com/*\"")
                     && after.contains("\"threshold\": 1.50") && after.contains("\"Bash(git status)\"")
                     && after.hasPrefix("{\n  \"permissions\"") && mode(file) == 0o600,
                     "every other key, entry, spelling and the file's mode are kept: \(after)")
        _ = try? ClaudeMCPSettingsFile.apply(root: root, change: ClaudeMCPSwitchChange(allow: ["mine"]))
        suite.expect(read(file) == existing, "turning Brim's switch on again removes only its own entry, leaving the file as it was")
        _ = try? ClaudeMCPSettingsFile.apply(root: root, change: ClaudeMCPSwitchChange(deny: ["theirs"]))
        suite.expect(read(file) == existing, "a name denied already is not added twice")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: root + "/.claude")) ?? []).filter { $0 != "settings.local.json" }
        suite.expect(leftovers.isEmpty, "the atomic write leaves no temporary file: \(leftovers)")
        // Connectors.
        _ = try? ClaudeMCPSettingsFile.apply(root: root, change: ClaudeMCPSwitchChange(connectorsOff: true))
        suite.expect((ClaudeJSON.parse(Data(read(file).utf8)) as? [String: Any])?["disableClaudeAiConnectors"] as? Bool == true,
                     "All claude.ai connectors off sets disableClaudeAiConnectors")
        _ = try? ClaudeMCPSettingsFile.apply(root: root, change: ClaudeMCPSwitchChange(connectorsOff: false))
        suite.expect(read(file) == existing, "and turning them on removes it again")
        // Changed underneath: the write starts over from the new content.
        var calls = 0
        let retried = try? ClaudeMCPSettingsFile.apply(root: root, change: ClaudeMCPSwitchChange(deny: ["late"])) {
            calls += 1
            if calls == 1 { write(file, existing.replacingOccurrences(of: "\"linear\"", with: "\"linear\",\n    \"retell\"")) }
        }
        let merged = read(file)
        suite.expect(retried == true && calls == 2 && merged.contains("\"retell\"") && merged.contains("\"serverName\": \"late\""),
                     "a file Claude Code rewrote between the read and the write is read again, and both changes land: \(calls)")
        var always = 0
        do {
            try ClaudeMCPSettingsFile.apply(root: root, change: ClaudeMCPSwitchChange(deny: ["never"]), attempts: 3) {
                always += 1
                write(file, merged.replacingOccurrences(of: "late", with: "late\(always)"))
            }
            suite.expect(false, "a file that keeps changing is refused")
        } catch let error as ClaudeMCPSettingsError {
            suite.expect(error == .keptChanging(file) && always == 3 && !read(file).contains("never"),
                         "a file that changes on every try is left alone after three: \(error)")
        } catch {
            suite.expect(false, "unexpected error \(error)")
        }
        // A file that is not JSON, and a link, are never written.
        write(file, "{ not json")
        suite.expect((try? ClaudeMCPSettingsFile.apply(root: root, change: ClaudeMCPSwitchChange(deny: ["x"]))) == nil
                     && read(file) == "{ not json", "an unreadable settings file is refused and left as it was")
        try? FileManager.default.removeItem(atPath: file)
        try? FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: scratch.folder("deny/elsewhere") + "/target.json")
        suite.expect((try? ClaudeMCPSettingsFile.apply(root: root, change: ClaudeMCPSwitchChange(deny: ["x"]))) == nil
                     && ClaudeFileIO.isSymlink(file), "a settings file that is a link is refused")
        try? FileManager.default.removeItem(atPath: file)
        write(file, #"{"deniedMcpServers":"oops"}"#)
        suite.expect((try? ClaudeMCPSettingsFile.apply(root: root, change: ClaudeMCPSwitchChange(deny: ["x"]))) == nil,
                     "a deniedMcpServers that is not a list is someone else's to fix")
        // The exclude file's content.
        suite.expect(ClaudeMCPExclude.added(nil).map { String(decoding: $0, as: UTF8.self) } == "/.claude/settings.local.json\n"
                     && ClaudeMCPExclude.added(Data("# git ls-files\n*.log".utf8)).map { String(decoding: $0, as: UTF8.self) }
                        == "# git ls-files\n*.log\n/.claude/settings.local.json\n"
                     && ClaudeMCPExclude.added(Data("x\n.claude/settings.local.json\n".utf8)) == nil,
                     "the exclude line is added once, on a line of its own")
    }

    /// Files Brim will not edit, each refused with a reason the page shows
    /// too, and the line endings it keeps.
    private static func refusedFiles(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let root = scratch.folder("refused/repo")
        let file = ClaudeMCPSettingsFile.path(root: root)
        func refusal(_ text: String, _ change: ClaudeMCPSwitchChange = ClaudeMCPSwitchChange(deny: ["x"])) -> ClaudeMCPSettingsError? {
            write(file, text)
            do {
                try ClaudeMCPSettingsFile.apply(root: root, change: change)
                return nil
            } catch let error as ClaudeMCPSettingsError {
                return error
            } catch {
                return .io(.posix("unexpected", 0))
            }
        }
        let bom = "\u{FEFF}{\n  \"permissions\": {}\n}\n"
        // Read as bytes: reading a file as a String drops its byte order mark.
        suite.expect(refusal(bom) == .byteOrderMark(file) && FileManager.default.contents(atPath: file) == Data(bom.utf8)
                     && ClaudeMCPRepoFiles.read(root: root).localSettingsProblem == ClaudeMCPSettingsError.byteOrderMark(file).message,
                     "a file that starts with a byte order mark is refused, and the page says so the same way")
        let twice = "{\n  \"deniedMcpServers\": [],\n  \"deniedMcpServers\": [\n    {\n      \"serverName\": \"theirs\"\n    }\n  ]\n}\n"
        suite.expect(refusal(twice) == .duplicateKey(file, key: "deniedMcpServers") && read(file) == twice
                     && ClaudeMCPRepoFiles.read(root: root).localSettingsProblem?.contains("twice") == true,
                     "a key named twice is refused (Claude Code reads the last, JSONSerialization the first)")
        suite.expect(refusal(#"{"permissions":{"allow":[],"allow":["x"]}}"#) == .duplicateKey(file, key: "allow"),
                     "so is one named twice deeper in")
        let null = "{\n  \"deniedMcpServers\": null\n}\n"
        suite.expect(refusal(null) == .notAList(file) && read(file) == null
                     && refusal(null, ClaudeMCPSwitchChange(allow: ["x"])) == .notAList(file)
                     && ClaudeMCPCatalog.deniedNames(["deniedMcpServers": NSNull()]).isEmpty,
                     "deniedMcpServers: null is not a list: refused, and read as no denies")
        let crlf = "{\r\n  \"permissions\": {\r\n    \"allow\": [\r\n      \"Bash(ls)\"\r\n    ]\r\n  }\r\n}\r\n"
        suite.expect(refusal(crlf) == nil, "a file with CRLF line endings is edited")
        let written = read(file)
        suite.expect(written == "{\r\n  \"permissions\": {\r\n    \"allow\": [\r\n      \"Bash(ls)\"\r\n    ]\r\n  },\r\n  \"deniedMcpServers\": [\r\n    {\r\n      \"serverName\": \"x\"\r\n    }\r\n  ]\r\n}\r\n",
                     "and keeps them: \(written.debugDescription)")
        _ = try? ClaudeMCPSettingsFile.apply(root: root, change: ClaudeMCPSwitchChange(allow: ["x"]))
        suite.expect(read(file) == crlf, "turning it on again gives the CRLF file back byte for byte")
        // A .claude folder that is a link: nothing is written through it.
        let linked = scratch.folder("refused/linked")
        let elsewhere = scratch.folder("refused/elsewhere")
        try? FileManager.default.createSymbolicLink(atPath: linked + "/.claude", withDestinationPath: elsewhere)
        var thrown: ClaudeMCPSettingsError?
        do { try ClaudeMCPSettingsFile.apply(root: linked, change: ClaudeMCPSwitchChange(deny: ["x"])) } catch let error as ClaudeMCPSettingsError {
            thrown = error
        } catch {}
        suite.expect(thrown == .link(linked + "/.claude") && !ClaudeFileIO.exists(elsewhere + "/settings.local.json")
                     && ClaudeMCPRepoFiles.read(root: linked).localSettingsProblem == ClaudeMCPSettingsError.link(linked + "/.claude").message,
                     "a .claude folder that is a link is refused, nothing lands where it points, and the page says why")
    }

    // MARK: git

    private static func gitChecks(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let home = scratch.folder("git-home")
        let tracked = scratch.folder("git/tracked")
        repo(tracked, home: home)
        write(tracked + "/.claude/settings.local.json", "{}\n")
        git(["add", "-f", ".claude/settings.local.json"], in: tracked, home: home)
        git(["commit", "-qm", "settings"], in: tracked, home: home)
        suite.expect(ClaudeMCPGit.prepare(root: tracked, home: home) == .tracked,
                     "a repo that commits .claude/settings.local.json is refused")
        let open = scratch.folder("git/open")
        repo(open, home: home)
        let exclude = open + "/.git/info/exclude"
        let before = read(exclude)
        let prepared = ClaudeMCPGit.prepare(root: open, home: home)
        suite.expect(prepared == .ready(excluded: exclude) && read(exclude) == before + (before.isEmpty || before.hasSuffix("\n") ? "" : "\n") + "/.claude/settings.local.json\n"
                     && ClaudeMCPGit.check(root: open, home: home) == .answer(.fine),
                     "an untracked, unignored file is added to .git/info/exclude and git then ignores it: \(prepared)")
        write(open + "/.claude/settings.local.json", "{}\n")
        suite.expect(git(["status", "--porcelain"], in: open, home: home).output.isEmpty,
                     "git status shows nothing once the file is excluded")
        suite.expect(ClaudeMCPGit.prepare(root: open, home: home) == .ready(excluded: nil) && read(exclude).components(separatedBy: "settings.local.json").count == 2,
                     "the exclude is added once")
        let ignored = scratch.folder("git/ignored")
        repo(ignored, home: home)
        write(ignored + "/.gitignore", ".claude/settings.local.json\n")
        let ignoredBefore = read(ignored + "/.git/info/exclude")
        suite.expect(ClaudeMCPGit.prepare(root: ignored, home: home) == .ready(excluded: nil)
                     && read(ignored + "/.git/info/exclude") == ignoredBefore,
                     "a file the repo ignores already needs nothing")
        let plain = scratch.folder("git/plain")
        suite.expect(ClaudeMCPGit.prepare(root: plain, home: home) == .ready(excluded: nil), "outside git there is nothing to check")
        let worktree = scratch.root + "/git/open-wt"
        git(["worktree", "add", "-q", worktree], in: open, home: home)
        suite.expect(ClaudeRepoKey.root(of: worktree) == open, "a worktree's switches are its main repo's")
    }

    /// A real `git submodule`: its .git is a file naming
    /// <superproject>/.git/modules/<name>, with no commondir. The submodule is
    /// a repo of its own, and its exclude is the one in that folder.
    private static func submodule(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let home = scratch.folder("sub-home")
        let library = scratch.folder("sub/library")
        repo(library, home: home)
        let superproject = scratch.folder("sub/super")
        repo(superproject, home: home)
        let added = git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", library, "lib"], in: superproject, home: home)
        git(["commit", "-qm", "add lib"], in: superproject, home: home)
        let module = superproject + "/lib"
        let gitDirectory = ClaudeRepoKey.gitDirectory(root: module)
        suite.expect(added.status == 0 && ClaudeFileIO.isRegularFile(module + "/.git") && ClaudeRepoKey.root(of: module + "/x") == module
                     && gitDirectory == ClaudeFileIO.realPath(superproject + "/.git/modules/lib"),
                     "a submodule is its own repo, its git folder inside the superproject's: \(added.output) \(String(describing: gitDirectory))")
        let prepared = ClaudeMCPGit.prepare(root: module, home: home)
        let exclude = (gitDirectory ?? "") + "/info/exclude"
        write(module + "/.claude/settings.local.json", "{}\n")
        suite.expect(prepared == .ready(excluded: exclude) && read(exclude).contains("/.claude/settings.local.json")
                     && git(["status", "--porcelain"], in: module, home: home).output.isEmpty
                     && !git(["status", "--porcelain"], in: superproject, home: home).output.contains("lib"),
                     "the submodule's own exclude keeps the file out of both its status and the superproject's: \(prepared)")
    }

    // MARK: Local servers on every account

    private static func localMirror(_ suite: TestSuite) {
        let repo = "/Users/x/Code/acme"
        let stern = "/Users/x/.claude-stern"
        let work = "/Users/x/.claude-work"
        let held: [String: [String: Any]] = [
            "": ["fake": ["type": "stdio", "command": "/bin/fake", "args": []],
                 "sendly": ["type": "stdio", "command": "npx", "env": ["SENDLY_API_KEY": "secret-value"]],
                 "split": ["type": "stdio", "command": "a"]],
            stern: ["fake": ["command": "/bin/fake"], "split": ["type": "stdio", "command": "b"]],
            work: [:],
        ]
        let labels = ["": "rhodes", stern: "stern", work: "work"]
        let plan = ClaudeMCPMirror.localPlan(repo: repo, servers: held, folders: ["", stern, work], describe: { labels[$0] ?? $0 })
        suite.expect(plan.commands.map { "\(labels[$0.folder]!) \($0.server)" } == ["work fake", "stern sendly", "work sendly"],
                     "each folder gets the repo's servers it lacks, and copies that differ only in what add-json fills in agree: \(plan.commands.map(\.server))")
        suite.expect(plan.conflicts == ["split"] && !plan.commands.contains { $0.server == "split" }
                     && plan.lines.contains("split: differs between rhodes, stern; nothing changes"),
                     "a server two folders hold differently is shown and never copied: \(plan.lines)")
        suite.expect(!plan.lines.joined().contains("secret-value") && plan.commands.first { $0.server == "sendly" }?.arguments.last?.contains("secret-value") == true,
                     "the configuration goes to the CLI as it is, keys included, and never into the review")
        suite.expect(ClaudeMCPMirror.localServers(configData: Data(#"{"projects":{"/r":{"mcpServers":{"a":{}}}}}"#.utf8), repo: "/r").count == 1
                     && ClaudeMCPMirror.localServers(configData: Data("{}".utf8), repo: "/r").isEmpty,
                     "a folder's local servers are projects[<repo>].mcpServers")
    }

    /// Copy to every account for the person's own servers: the union of
    /// what the accounts hold, as "Not in X yet" says. The real case:
    /// stern's user-scope resend, which the default account lacks.
    private static func userMirror(_ suite: TestSuite) {
        let stern = "/Users/x/.claude-stern"
        let work = "/Users/x/.claude-work"
        let labels = ["": "rhodes", stern: "stern", work: "work"]
        let held: [String: [String: Any]] = [
            "": ["mobbin": ["type": "http", "url": "https://api.mobbin.com/mcp"]],
            stern: ["mobbin": ["type": "http", "url": "https://api.mobbin.com/mcp"],
                    "resend": ["type": "http", "url": "https://mcp.resend.com", "headersHelper": "/x"],
                    "split": ["command": "a"]],
            work: ["mobbin": ["url": "https://api.mobbin.com/mcp", "type": "http", "headers": [:]], "split": ["command": "b"]],
        ]
        let plan = ClaudeMCPMirror.plan(servers: held, folders: ["", stern, work], describe: { labels[$0] ?? $0 })
        suite.expect(plan.commands.map { "\(labels[$0.folder]!) \($0.kind) \($0.server)" } == ["rhodes add resend", "work add resend"],
                     "stern's resend goes to every account that lacks it, the default one included; equal copies are left alone: \(plan.lines)")
        suite.expect(plan.lines.contains("rhodes: add resend (from stern)") && plan.conflicts == ["split"]
                     && plan.lines.contains("split: differs between stern, work; nothing changes") && plan.replaced.isEmpty,
                     "the review says where a server comes from, and one held differently without the default account is a conflict")
        let shown = ClaudeMCPCatalog.build(root: "/r", folders: held.keys.sorted().map { key in
            ClaudeMCPFolderConfig(folder: key, label: labels[key]!, configData: try? JSONSerialization.data(withJSONObject: ["mcpServers": held[key]!]))
        }, files: ClaudeMCPRepoFiles(), userSettings: [:], plugins: [], state: ClaudeMCPState())
        let resend = shown.entries.first { $0.name == "resend" }
        let split = shown.entries.first { $0.name == "split" }
        suite.expect(Set(resend?.missingIn ?? []) == ["rhodes", "work"] && resend?.conflict == false && split?.conflict == true,
                     "the page's Not in X yet names exactly the accounts the plan adds it to")
    }

    private static func mirrorEnvironment(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let repo = "/Users/x/Code/My Repo"
        let home = URL(fileURLWithPath: scratch.folder("env-home"))
        let stern = scratch.folder("env-home/.claude-stern")
        let base = ["PATH": "/bin", "CLAUDE_CONFIG_DIR": "/Users/x/.claude", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/elsewhere",
                    "HOME": home.path, "ANTHROPIC_API_KEY": "not-this-one", "CLAUDECODE": "1"]
        let mine = ClaudeMCPCommand.addLocal("fake", json: "{}", folder: "", repo: repo)
        let theirs = ClaudeMCPCommand.removeLocal("fake", folder: stern, repo: repo)
        let defaults = ClaudeMCPRun.environment(for: mine, base: base, home: home)
        let other = ClaudeMCPRun.environment(for: theirs, base: base, home: home)
        suite.expect(defaults["CLAUDE_CONFIG_DIR"] == nil && defaults["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil && defaults["PATH"] == "/bin",
                     "the app's environment for the default folder has CLAUDE_CONFIG_DIR unset, never ~/.claude, and no secure-storage override")
        suite.expect(other["CLAUDE_CONFIG_DIR"] == stern && other["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil
                     && other["ANTHROPIC_API_KEY"] == nil && other["CLAUDECODE"] == nil && other["DISABLE_AUTOUPDATER"] == "1",
                     "for another folder: its exact folder, no secure-storage override, no token or session marker of the app's")
        suite.expect(mine.directory == repo && mine.arguments == ["mcp", "add-json", "-s", "local", "fake", "{}"]
                     && theirs.arguments == ["mcp", "remove", "-s", "local", "fake"]
                     && ClaudeMCPCommand.add("u", json: "{}", folder: "/f").directory == nil,
                     "a repo server's command runs in the repo, at local scope; a user one runs anywhere")
    }

    private static func pastedServers(_ suite: TestSuite) {
        suite.expect(ClaudeMCPMirror.nameProblem("stripe-acme_2") == nil && ClaudeMCPMirror.nameProblem("bad name") != nil
                     && ClaudeMCPMirror.nameProblem("") != nil && ClaudeMCPMirror.nameProblem("ä") != nil,
                     "server names are letters, digits, - and _, as Claude Code checks")
        let ok = #"{"type":"stdio","command":"npx","args":["x"],"env":{"K":"v"}}"#
        suite.expect(ClaudeMCPMirror.pastedServer(ok) == .success(#"{"args":["x"],"command":"npx","env":{"K":"v"},"type":"stdio"}"#)
                     && (try? ClaudeMCPMirror.pastedServer(#"{"command":"npx"}"#).get()) != nil
                     && (try? ClaudeMCPMirror.pastedServer(#"{"type":"http","url":"https://mcp.example.com","headers":{"A":"b"}}"#).get()) != nil
                     && (try? ClaudeMCPMirror.pastedServer(#"{"type":"sse","url":"http://127.0.0.1:9/sse"}"#).get()) != nil,
                     "stdio, http and sse servers with their required fields are taken")
        suite.expect(ClaudeMCPMirror.pastedServer("nope") == .failure(.notAnObject)
                     && ClaudeMCPMirror.pastedServer(#"{"type":"ws","url":"wss://x"}"#) == .failure(.type)
                     && ClaudeMCPMirror.pastedServer(#"{"type":"http"}"#) == .failure(.missing("url"))
                     && ClaudeMCPMirror.pastedServer(#"{"type":"http","url":"ftp://x"}"#) == .failure(.missing("url"))
                     && ClaudeMCPMirror.pastedServer(#"{"type":"stdio"}"#) == .failure(.missing("command"))
                     && ClaudeMCPMirror.pastedServer(#"{"command":"x","args":[1]}"#) == .failure(.wrongType("args"))
                     && ClaudeMCPMirror.pastedServer(#"{"command":"x","env":{"K":1}}"#) == .failure(.wrongType("env"))
                     && ClaudeMCPMirror.pastedServer(#"{"type":"http","url":"https://x.com","headers":[]}"#) == .failure(.wrongType("headers")),
                     "a pasted server without its required fields is refused, saying which")
        suite.expect(ClaudeMCPServerInfo(["type": "http", "url": "https://a.example.com/x/"]).endpoint
                     == ClaudeMCPServerInfo(["type": "http", "url": "https://a.example.com/x"]).endpoint
                     && ClaudeMCPServerInfo(["command": "npx", "args": ["a"]]).endpoint != ClaudeMCPServerInfo(["command": "npx", "args": ["b"]]).endpoint,
                     "endpoints match when only a trailing slash differs, and stdio ones by command and arguments")
    }

    // MARK: Stripe

    private static func stripe(_ suite: TestSuite) {
        suite.expect(ClaudeMCPStripe.config == #"{"type":"http","url":"https://mcp.stripe.com"}"#
                     && ClaudeMCPServerInfo(ClaudeJSON.parse(Data(ClaudeMCPStripe.config.utf8))).signsInItself
                     && !ClaudeMCPMirror.mayHoldSecrets(ClaudeMCPStripe.config),
                     "a repo's Stripe server is Stripe's hosted server alone: no header, no helper, signed in with OAuth per account")
        suite.expect(ClaudeMCPStripe.nicknameProblem("acme", taken: []) == nil && ClaudeMCPStripe.serverName(nickname: "acme") == "stripe-acme"
                     && ClaudeMCPStripe.nicknameProblem("Acme", taken: []) == .characters
                     && ClaudeMCPStripe.nicknameProblem("a b", taken: []) == .characters
                     && ClaudeMCPStripe.nicknameProblem("-a", taken: []) == .characters
                     && ClaudeMCPStripe.nicknameProblem("", taken: []) == .empty
                     && ClaudeMCPStripe.nicknameProblem("acme", taken: ["stripe-acme"]) == .taken,
                     "a nickname is lowercase letters, digits and -, and names a server nothing else uses (each name is its own sign-in)")
        suite.expect(ClaudeMCPMirror.mayHoldSecrets(#"{"command":"x","env":{"K":"v"}}"#) && ClaudeMCPMirror.mayHoldSecrets(#"{"command":"x","args":["--key=v"]}"#)
                     && !ClaudeMCPMirror.mayHoldSecrets(#"{"command":"x","args":[],"env":{}}"#),
                     "a server whose env, headers or args are set gets the command-line note in its review")
        let text = FeatureStrings.claudeAccounts(.enUS)
        let copy = [text.mcpStripeHelp, text.mcpStripeSignIn, text.mcpStripeSignInReview("stripe-acme"), text.mcpCommandLineNote,
                    text.mcpRemoveSignIn, text.mcpStillIn("x", ["stern"]), text.mcpLeftOut(["work"]), text.mcpSharesName]
        suite.expect(copy.allSatisfy { !$0.contains("\u{2014}") && !$0.lowercased().contains("keychain") && !$0.contains("rk_") }
                     && text.mcpCommandLineNote.contains("pass briefly through a command line")
                     && text.mcpOffInAccount(nil) == "Off in every account (set in /mcp)"
                     && text.mcpOffInAccount(["stern"]) == "Off in stern only (set in /mcp)",
                     "the copy speaks of Stripe's own sign-in, has no em dash, and says Off in every account instead of listing all")
    }

    // MARK: Sessions

    private static func sessions(_ suite: TestSuite) {
        let root = "/private/tmp/no-such-repo-\(UUID().uuidString)"
        func session(_ pid: Int32, _ cwd: String?) -> ClaudeLiveSession {
            ClaudeLiveSession(pid: pid, sessionId: "s\(pid)", cwd: cwd, status: "idle", kind: "interactive", startedAt: nil,
                              configDirectory: "/c")
        }
        let open = ClaudeMCPCatalog.openSessions([session(1, root), session(2, root), session(2, root), session(3, "/elsewhere"),
                                                  session(4, nil)], root: root)
        let text = FeatureStrings.claudeAccounts(.enUS)
        suite.expect(open == 2 && text.mcpOpenHere(2) == "2 open here keep their current servers until restarted."
                     && text.mcpOpenHere(1) == "1 open here keeps its current servers until restarted."
                     && text.mcpAppliesToNew == "Changes apply to new sessions.",
                     "the footer counts the running sessions in the repo, once each: \(open)")
    }

    private static func state(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let paths = ClaudeAccountsPaths(stateDirectory: scratch.folder("mcp-state") + "/claude")
        guard case .success(var state) = ClaudeMCPState.read(paths) else {
            suite.expect(false, "no record reads as an empty one")
            return
        }
        suite.expect(state == ClaudeMCPState(), "no record reads as an empty one")
        state.own("a", in: "/r")
        state.own("a", in: "/r")
        state.own("b", in: "/r")
        state.repos = ["/added"]
        state.servers["stripe-x"] = ClaudeMCPServerRecord(kind: ClaudeMCPStripe.kind, repos: ["/r"])
        try? state.save(paths)
        let loaded = try? ClaudeMCPState.read(paths).get()
        let saved = read(ClaudeMCPState.path(paths))
        suite.expect(loaded == state && loaded?.denies["/r"] == ["a", "b"] && mode(ClaudeMCPState.path(paths)) == 0o600
                     && !saved.contains("allowed_host") && !saved.contains("keychain"),
                     "Brim's MCP record round-trips, mode 0600, and holds names only: \(saved)")
        state.disown("a", in: "/r")
        state.disown("b", in: "/r")
        suite.expect(state.denies["/r"] == nil, "a repo with no switch of Brim's left drops out of the record")
        // A record from the key build still reads (its extra fields are ignored).
        write(ClaudeMCPState.path(paths), #"{"version":1,"servers":{"stripe-a":{"kind":"stripe","allowed_host":"mcp.stripe.com","keychain_account":"stripe-a","repos":["/r"]}}}"#)
        suite.expect((try? ClaudeMCPState.read(paths).get())?.servers["stripe-a"] == ClaudeMCPServerRecord(kind: "stripe", repos: ["/r"]),
                     "a record written with the old key fields decodes without them")
        // The real failure: a record that does not decode read as empty, and
        // the next save replaced it, losing which denies were Brim's.
        let broken = #"{"version":1,"denies":{"/r":"not a list"}}"#
        write(ClaudeMCPState.path(paths), broken)
        if case .failure(let problem) = ClaudeMCPState.read(paths) {
            suite.expect(problem == .unreadable(ClaudeMCPState.path(paths)) && problem.message.contains("changes nothing"),
                         "a record that exists but does not decode is a failure, never an empty record")
        } else {
            suite.expect(false, "a record that exists but does not decode is a failure, never an empty record")
        }
        suite.expect(read(ClaudeMCPState.path(paths)) == broken, "and it is left as it was")
    }

    /// Brim's record follows what really happened: a deny is Brim's only if
    /// its write added it; a server is recorded once a folder holds it and
    /// dropped only when every folder dropped it.
    private static func records(_ suite: TestSuite) {
        var state = ClaudeMCPState()
        // The real failure: switching off a server someone else had denied
        // already changed nothing, yet Brim claimed the deny and removed it later.
        state.record(ClaudeMCPSwitchChange(deny: ["theirs"]), in: "/r", changed: false)
        suite.expect(state.denies["/r"] == nil, "a deny that was there already is not claimed")
        state.record(ClaudeMCPSwitchChange(deny: ["mine"]), in: "/r", changed: true)
        state.record(ClaudeMCPSwitchChange(connectorsOff: true), in: "/r", changed: false)
        suite.expect(state.denies["/r"] == ["mine"] && state.connectorsOff.isEmpty, "only a write that changed the file is claimed")
        state.record(ClaudeMCPSwitchChange(connectorsOff: true), in: "/r", changed: true)
        state.record(ClaudeMCPSwitchChange(allow: ["mine"]), in: "/r", changed: false)
        state.record(ClaudeMCPSwitchChange(connectorsOff: false), in: "/r", changed: true)
        suite.expect(state.denies["/r"] == nil && state.connectorsOff.isEmpty, "turning on drops the claim either way")

        var added = ClaudeMCPState()
        added.recordAdded("stripe-a", kind: ClaudeMCPStripe.kind, root: "/r", folders: 0)
        suite.expect(added.servers.isEmpty, "nothing is recorded when no folder took the server")
        added.recordAdded("stripe-a", kind: ClaudeMCPStripe.kind, root: "/r", folders: 2)
        added.recordAdded("stripe-a", kind: nil, root: "/other", folders: 1)
        added.recordAdded("pasted", kind: nil, root: "/r", folders: 5)
        suite.expect(added.servers == ["stripe-a": ClaudeMCPServerRecord(kind: "stripe", repos: ["/r", "/other"])],
                     "a Stripe server is recorded once a folder holds it; a copy of it adds its repo; nothing else is recorded")
        var removed = added
        removed.recordRemoved("stripe-a", root: "/r", everywhere: false)
        suite.expect(removed == added, "a removal that did not reach every folder keeps the record")
        removed.recordRemoved("stripe-a", root: "/r", everywhere: true)
        removed.recordRemoved("stripe-a", root: "/other", everywhere: true)
        suite.expect(removed.servers.isEmpty, "the last repo's full removal drops it")
    }

    /// The loop the app runs commands with, on a fake process start.
    private static func runner(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let labels = ["": "rhodes", "/s": "stern", "/w": "work"]
        let commands = ["", "/s", "/w"].map { ClaudeMCPCommand.removeLocal("stripe-a", folder: $0, repo: "/r") }
        var ran: [String] = []
        let report = ClaudeMCPRun.run(commands, labels: labels) { command in
            ran.append(command.folder)
            return command.folder == "/s" ? (1, false) : (command.folder == "/w" ? (0, true) : (0, false))
        }
        suite.expect(ran == ["", "/s", "/w"] && report.failures == 2 && report.succeededCount == 1
                     && report.lines == ["rhodes: stripe-a removed", "stern: stripe-a FAILED (exit 1)", "work: stripe-a FAILED (exit 0, timed out)"]
                     && report.install.failures == 2 && !report.install.succeeded,
                     "each command runs once, one at a time; a failure or a timeout is reported by account: \(report.lines)")
        // The real failure: a remove that failed in some folders dropped
        // Brim's record and its switch as if it were gone everywhere.
        let partial = ClaudeMCPRun.removal(report, unreadable: [], labels: labels)
        suite.expect(!partial.everywhere && partial.stillIn == ["stern", "work"], "a partial removal says where it still is")
        var state = ClaudeMCPState()
        state.servers["stripe-a"] = ClaudeMCPServerRecord(kind: "stripe", repos: ["/r"])
        state.recordRemoved("stripe-a", root: "/r", everywhere: partial.everywhere)
        suite.expect(state.servers["stripe-a"]?.repos == ["/r"], "so Brim's record keeps it")
        let clean = ClaudeMCPRun.run(commands, labels: labels) { _ in (0, false) }
        suite.expect(ClaudeMCPRun.removal(clean, unreadable: [], labels: labels).everywhere
                     && !ClaudeMCPRun.removal(clean, unreadable: ["broken"], labels: labels).everywhere
                     && !ClaudeMCPRun.removal(ClaudeMCPRun.Report(refusal: "busy"), unreadable: [], labels: labels).everywhere,
                     "gone everywhere only when every command worked, no folder was unreadable, and it ran at all")
        let refused = ClaudeMCPRun.Report(refusal: "Brim is still making the last change.")
        suite.expect(refused.refused && refused.install.refused && refused.lines.last == "BLOCKED: Brim is still making the last change.",
                     "a refused run says why and changes nothing")
        let base = ClaudeMCPRun.base(executable: URL(fileURLWithPath: "/opt/tools/bin/claude"), home: URL(fileURLWithPath: scratch.folder("run-home")))
        suite.expect(base["PATH"]?.hasPrefix("/opt/tools/bin:") == true, "claude's own folder comes first on its PATH")
    }

    // MARK: Source rules

    private static func swiftFiles(_ folder: String) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: folder)
        var found: [String] = []
        while let next = enumerator?.nextObject() as? String {
            if next.hasSuffix(".swift") { found.append(folder + "/" + next) }
        }
        return found.sorted()
    }

    private static func sourceRules(_ suite: TestSuite) {
        // Nothing in Brim writes a .claude.json: Claude Code's CLI changes
        // servers, and its sessions own the file (under their own lock).
        let writers = ["writeAtomically(", ".write(to:", "createFile(", "copyItem(", "moveItem(", "rename(", "replaceItem"]
        var offenders: [String] = []
        for file in swiftFiles("Sources") {
            for (number, line) in read(file).components(separatedBy: "\n").enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && writers.contains(where: line.contains) && (line.contains("claude.json") || line.contains("configFile(")) {
                offenders.append("\(file):\(number + 1)")
            }
        }
        suite.expect(offenders.isEmpty, "no source writes a .claude.json directly: \(offenders)")
        let folder = "Sources/Brim/Modules/ClaudeAccounts"
        let mcp = ["ClaudeMCPMirror.swift", "ClaudeMCPRepos.swift", "ClaudeMCPSwitches.swift", "ClaudeMCPStripe.swift",
                   "App/ClaudeMCPModel.swift", "App/ClaudeMCPViews.swift", "App/ClaudeMCPGit.swift", "App/ClaudeMCPRun.swift"]
            .map { folder + "/" + $0 }
        for file in mcp {
            let code = read(file)
            suite.expect(!code.isEmpty, "\(file) reads back")
            for forbidden in ["Timer", "asyncAfter", "sleep(", "setInterval", "URLSession", "CLAUDE_SECURESTORAGE_CONFIG_DIR\"] = ",
                              "Claude Code-credentials", "SecItem"] {
                suite.expect(!code.contains(forbidden), "\(file) never uses \(forbidden)")
            }
        }
        let model = read(folder + "/App/ClaudeMCPModel.swift")
        suite.expect(model.contains("FileEventStream(") && !model.contains("FSEventStreamCreate"),
                     "the MCP page watches its files through the shared FileEventStream")
        // Stripe signs in with OAuth (decided 2026-11-13): no key, Keychain
        // item or headers helper of Brim's is left anywhere.
        var keyCode: [String] = []
        let helperFolder = "Sources/BrimClaude"
        let helperFiles = ((try? FileManager.default.contentsOfDirectory(atPath: helperFolder)) ?? []).sorted()
        for file in swiftFiles(folder) + helperFiles.map({ helperFolder + "/" + $0 }) + ["build.sh"] {
            let code = read(file)
            for token in ["mcp-headers", "mcp-key", "ClaudeMCPKey", "ClaudeMCPHeaders", "keychainAccount", "allowedHost", "SecItem",
                          "kSecClass", "import Security", "Brim MCP key", "rk_test_", "rk_live_"] where code.contains(token) {
                keyCode.append("\(file): \(token)")
            }
        }
        suite.expect(keyCode.isEmpty && helperFiles == ["main.swift"], "no MCP key code is left: \(keyCode) \(helperFiles)")
        let build = read("build.sh")
        suite.expect(build.contains("Sources/Brim/Modules/ClaudeAccounts/*.swift Sources/BrimClaude/main.swift \\\n")
                     && build.contains("        Sources/Brim/Modules/ClaudeAccounts/App/ClaudeMCPGit.swift\n")
                     && build.contains("        Sources/Brim/Modules/ClaudeAccounts/App/ClaudeMCPRun.swift\n"),
                     "build.sh builds brim-claude from the shared files and main.swift alone, and the git checks and runner into the tests")
        suite.expect(model.contains("ClaudeMCPRun.environment(for: command") && model.contains("ClaudeMCPRun.run(commands")
                     && !read(folder + "/ClaudeMCPMirror.swift").contains("func environment(base"),
                     "the app runs commands through ClaudeMCPRun, the path the tests check; there is no second one")
        let service = read(folder + "/App/ClaudeAccountsService.swift")
        suite.expect(service.contains("ClaudeMCPNeedsAuth.names(") && !service.contains("mcp-needs-auth-cache.json")
                     && !read(folder + "/App/ClaudeMCPModel.swift").contains("mcp-needs-auth-cache.json"),
                     "the needs-auth cache is parsed in one place")
        let settings = read(folder + "/App/ClaudeAccountsSettings.swift")
        suite.expect(settings.contains("ClaudeMCPWindow.show()") && !settings.contains("reviewMCP") && !service.contains("func planMCP")
                     && !service.contains("func runMCPCommands") && model.contains("func runUserMirror"),
                     "the Setup row opens the MCP page, which holds the one MCP implementation (the mirror moved there)")
    }

    // MARK: Opt-in: the real claude CLI on throwaway folders

    private static func claudeIntegration(_ suite: TestSuite, sandbox: String, fakeServer: String) {
        let home = NSHomeDirectory()
        let real = ClaudeFileIO.realPath(sandbox)
        guard real.hasPrefix("/private/tmp/") || real.hasPrefix("/private/var/folders/"),
              let executable = AgentClaudeServer.executable(home: URL(fileURLWithPath: home)) else {
            suite.expect(false, "BRIM_TEST_CLAUDE_SANDBOX must be a temporary folder, and claude must be installed")
            return
        }
        let cfgA = real + "/cfgA-" + UUID().uuidString.prefix(8)
        let cfgB = real + "/cfgB-" + UUID().uuidString.prefix(8)
        let repoPath = real + "/repo-" + UUID().uuidString.prefix(8)
        for folder in [cfgA, cfgB] { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        repo(repoPath, home: real)
        let base = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home, "ENABLE_CLAUDEAI_MCP_SERVERS": "false",
                    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1"]
        func claude(_ command: ClaudeMCPCommand) -> Int32 {
            precondition(command.folder.hasPrefix(real + "/"), "only throwaway folders")
            let result = BoundedProcessRunner.run(executable.path, command.arguments, timeout: 60, maxOutputBytes: 64 << 10,
                                                  environment: ClaudeMCPRun.environment(for: command, base: base, home: URL(fileURLWithPath: home)),
                                                  input: FileHandle.nullDevice,
                                                  currentDirectory: command.directory)
            return result.status
        }
        func list(_ folder: String) -> String {
            precondition(folder.hasPrefix(real + "/"), "only throwaway folders")
            let result = BoundedProcessRunner.run(executable.path, ["mcp", "list"], timeout: 90, maxOutputBytes: 64 << 10,
                                                  environment: ClaudeLaunchEnvironment.environment(forFolder: folder, base: base),
                                                  input: FileHandle.nullDevice, currentDirectory: repoPath)
            return String(decoding: result.output, as: UTF8.self)
        }
        func listed(_ output: String, _ name: String) -> Bool {
            output.components(separatedBy: "\n").contains { $0.hasPrefix(name + ":") }
        }
        let json = ClaudeMCPMirror.canonicalJSON(["type": "stdio", "command": fakeServer])!
        // 1. One folder gets a local server, as an account would.
        suite.expect(claude(.addLocal("fake-a", json: json, folder: cfgA, repo: repoPath)) == 0,
                     "the real CLI adds a local server in the first throwaway folder")
        // 2. Brim's mirror gives the second folder the repo's server.
        let configs = [cfgA, cfgB].map { folder in
            ClaudeMCPFolderConfig(folder: folder, label: (folder as NSString).lastPathComponent,
                                  configData: ClaudeFileIO.read(folder + "/.claude.json", limit: ClaudeUsageDecoding.configSizeLimit))
        }
        let key = ClaudeRepoKey.root(of: repoPath)
        var servers: [String: [String: Any]] = [:]
        for config in configs { servers[config.folder] = config.localServers(key) }
        let plan = ClaudeMCPMirror.localPlan(repo: key, servers: servers, folders: [cfgA, cfgB], describe: { $0 })
        suite.expect(key == repoPath && plan.commands.map(\.folder) == [cfgB] && plan.conflicts.isEmpty,
                     "the mirror plans fake-a for the second folder only: \(plan.lines)")
        let mirrored = plan.commands.map(claude)
        let before = list(cfgB)
        suite.expect(mirrored == [0] && listed(before, "fake-a"),
                     "claude mcp list in the second folder shows the mirrored local server: \(before)")
        print("claude integration: after the mirror, cfgB lists:\n" + before)
        // 3. A Brim switch hides it in both folders.
        let prepared = ClaudeMCPGit.prepare(root: key, home: real)
        let wrote = try? ClaudeMCPSettingsFile.apply(root: key, change: ClaudeMCPSwitchChange(deny: ["fake-a"]))
        let offB = list(cfgB)
        let offA = list(cfgA)
        suite.expect(prepared == .ready(excluded: ClaudeRepoKey.gitDirectory(root: key)! + "/info/exclude") && wrote == true
                     && !listed(offB, "fake-a") && !listed(offA, "fake-a"),
                     "a Brim deny in the repo's settings.local.json hides the server in every folder: \(offB)")
        print("claude integration: after Brim's deny, cfgB lists:\n" + offB + "\ncfgA lists:\n" + offA)
        // 4. On again.
        _ = try? ClaudeMCPSettingsFile.apply(root: key, change: ClaudeMCPSwitchChange(allow: ["fake-a"]))
        suite.expect(listed(list(cfgB), "fake-a"), "turning Brim's switch on again brings it back")
        // 5. Remove from every folder with the CLI.
        let removed = [cfgA, cfgB].map { claude(.removeLocal("fake-a", folder: $0, repo: key)) }
        suite.expect(removed == [0, 0] && !listed(list(cfgA), "fake-a"), "remove -s local takes it out of each folder")
        for folder in [cfgA, cfgB, repoPath] { try? FileManager.default.removeItem(atPath: folder) }
    }
}
