// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Claude Code's get_usage check, run against stand-ins: the transport, the
/// environment each account folder gets, and where Claude Code is found.
/// When a check runs is ClaudeRefreshGate's (BrimClaudeAccountsAppTests).
enum AgentClaudeServerTests {
    static func run(_ suite: TestSuite) {
        discovery(suite)
        folders(suite)
        let folder = FileManager.default.temporaryDirectory.appending(path: "brim-claude-server-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // `--setting-sources ""` leaves out the person's user settings,
            // so their opt-outs come along by name, and only those.
            let settings = folder.appending(path: ".claude/settings.json")
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["env": ["DISABLE_TELEMETRY": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": 1,
                                                                "ANTHROPIC_BASE_URL": "https://example.invalid",
                                                                "HTTPS_PROXY": "http://proxy.invalid:8080", "NO_PROXY": "localhost",
                                                                "NODE_EXTRA_CA_CERTS": "/etc/proxy.pem"]]).write(to: settings)
            let child = AgentClaudeServer.environment(["PATH": "/usr/bin", "CLAUDECODE": "1", "DISABLE_ERROR_REPORTING": "1",
                                                       "HTTP_PROXY": "http://other.invalid"], home: folder)
            try FileManager.default.removeItem(at: settings)
            suite.expect(child == ["PATH": "/usr/bin", "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1",
                                   "DISABLE_ERROR_REPORTING": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                                   "HTTP_PROXY": "http://other.invalid", "HTTPS_PROXY": "http://proxy.invalid:8080",
                                   "NO_PROXY": "localhost", "NODE_EXTRA_CA_CERTS": "/etc/proxy.pem"]
                            && AgentClaudeServer.environment(["PATH": "/usr/bin"], home: folder)
                                == ["PATH": "/usr/bin", "DISABLE_AUTOUPDATER": "1"],
                         "a check keeps the person's Claude Code opt-outs and proxy, never updates it and turns nothing else off")
            let tool = folder.appending(path: "claude")
            try Data(standIn.utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            func run(_ mode: String, timeout: TimeInterval = 2) -> Result<AgentClaudeServer.Summary, AgentClaudeServer.Failure> {
                AgentClaudeServer.Request().run(tool, home: folder,
                    environment: ["PATH": "/usr/bin:/bin", "HOME": folder.path, "STAND_IN": mode, "CLAUDECODE": "nested"],
                    timeout: timeout)
            }
            let summary = try? run("ok").get()
            suite.expect(summary?.reading.fiveHour?.utilization == 100 && summary?.reading.sevenDay?.utilization == 9
                            && summary?.reading.fiveHour?.source == .check,
                         "a CLI conversation initializes and asks get_usage without a user prompt, hooks, tools or MCP")
            suite.expect(run("old") == .failure(.outdated) && run("unsupported") == .failure(.outdated)
                            && run("signedOut") == .failure(.needsSignIn) && run("unavailable") == .failure(.unreachable),
                         "old CLIs, signed-out accounts and temporary failures retain distinct outcomes")
            // After a failed fetch Claude Code answers from the copy it saved,
            // which is no new reading; one saved as it exits is.
            let saved = folder.appending(path: ".claude.json")
            func save(fetched: Date) throws {
                try JSONSerialization.data(withJSONObject: ["cachedUsageUtilization":
                    ["fetchedAtMs": fetched.timeIntervalSince1970 * 1_000, "utilization": [:] as [String: Any]]]).write(to: saved)
            }
            try save(fetched: Date().addingTimeInterval(-30 * 60))
            let seeded = run("ok")
            let checked = Date()
            let exited = try? run("saves").get()
            let recent = Date().addingTimeInterval(-5)
            try save(fetched: recent)
            let reused = try? run("ok").get()
            try? FileManager.default.removeItem(at: saved)
            suite.expect(seeded == .failure(.unreachable)
                            && (exited?.reading.observedAt).map { $0 > checked.addingTimeInterval(-1) && $0 <= Date() } == true
                            && abs((reused?.reading.observedAt ?? .distantPast).timeIntervalSince(recent)) < 0.01,
                         "an answer from Claude Code's saved copy keeps its own time and an old copy is a failure")
            let began = Date()
            suite.expect(run("silent", timeout: 0.15) == .failure(.unreachable)
                            && run("exit") == .failure(.unreachable) && Date().timeIntervalSince(began) < 2,
                         "a silent or exited CLI cannot block the caller past its bounded deadline")
            let request = AgentClaudeServer.Request()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { request.cancel() }
            let cancelling = Date()
            let cancelled = request.run(tool, home: folder, environment: ["PATH": "/usr/bin:/bin", "STAND_IN": "silent"], timeout: 10)
            suite.expect(cancelled == .failure(.unreachable) && Date().timeIntervalSince(cancelling) < 4,
                         "pause or disable closes an active CLI request rather than waiting for its full timeout")
            let missing = AgentClaudeServer.executable(home: folder, searchPath: nil)
            suite.expect(missing != tool, "CLI discovery never guesses an executable from a project folder")
        } catch { suite.expect(false, "Claude CLI fixture: \(error)") }
        let failures: [AgentClaudeServer.Failure] = [.missing, .needsSignIn, .outdated, .unreachable]
        suite.expect(AppLanguage.allCases.allSatisfy { language in
            Set(failures.map { FeatureStrings.notchAgents(language).claudeCode($0) }).count == failures.count
        }, "Settings says in every language why Claude Code could not check")
    }

    /// Each account folder is checked on its own sign-in, its logs are read,
    /// and nothing falls back to the default account.
    private static func folders(_ suite: TestSuite) {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appending(path: "brim-claude-folders-\(UUID())")
        defer { try? manager.removeItem(at: home) }
        do {
            try manager.createDirectory(at: home, withIntermediateDirectories: true)
            let work = home.appending(path: ".claude-work account").path
            for (folder, name, used) in [("", "personal", 91), (work, "work", 12)] {
                let config = ClaudeSessionIndex.configDirectory(forFolder: folder, home: home.path)
                try manager.createDirectory(atPath: config, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try saveAccount(name, to: ClaudeUsageDecoding.configFile(forFolder: folder, home: home.path))
                try Data(String(used).utf8).write(to: URL(fileURLWithPath: config + "/test-usage"))
                let log = URL(fileURLWithPath: config + "/projects/project/\(name).jsonl")
                try manager.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
                let line = #"{"type":"assistant","timestamp":\#(Date().timeIntervalSince1970),"sessionId":"\#(name)","requestId":"r-\#(name)","message":{"id":"m-\#(name)","model":"claude-opus-5-5","stop_reason":"end_turn","usage":{"input_tokens":\#(used),"output_tokens":1}}}"#
                try Data((line + "\n").utf8).write(to: log)
            }
            try environment(suite, home: home, work: work)
            try conversations(suite, home: home, work: work)
            logs(suite, home: home, work: work)
            let unsafe = home.appending(path: ".claude-open").path
            try manager.createDirectory(atPath: unsafe, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: unsafe)
            suite.expect(ClaudeLaunchEnvironment.launchProblem(forFolder: unsafe, home: home.path) != nil
                            && ClaudeLaunchEnvironment.launchProblem(forFolder: "/", home: home.path) != nil
                            && ClaudeLaunchEnvironment.launchProblem(forFolder: home.path, home: home.path) != nil
                            && ClaudeLaunchEnvironment.launchProblem(forFolder: "relative/profile", home: home.path) != nil
                            && ClaudeLaunchEnvironment.launchProblem(forFolder: home.path + "/.claude", home: home.path) != nil
                            && ClaudeLaunchEnvironment.launchProblem(forFolder: work, home: home.path) == nil
                            && AgentLogRoot.claudeConfigFolders(home: home, claudeFolders: [unsafe]).isEmpty,
                         "root, home, relative, spelled-out default and writable-by-others folders are never run, nor their logs read")
        } catch { suite.expect(false, "Claude account folders: \(error)") }
        let tiles = NotchAgentSupport.tiles(cards: [.limits], providers: [.claude, .codex], claudeAccounts: ["default", "575e0284"])
        suite.expect(tiles.map(\.accountID) == ["default", "575e0284", nil] && tiles.map(\.provider) == [.claude, .claude, .codex]
                        && NotchAgentSupport.height(of: Array(tiles.prefix(2))) == NotchAgentSupport.accountCardHeight
                        && NotchAgentSupport.tiles(cards: [.limits], providers: [.claude]) == [NotchAgentTile(card: .limits, provider: .claude)],
                     "each Claude account has a card of its own, with room for its name, refresh and failure")
    }

    private static func saveAccount(_ name: String, to path: String) throws {
        try JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": name, "emailAddress": "\(name)@example.invalid",
            "organizationUuid": "same-organization", "organizationType": "claude_max"]]).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private static func environment(_ suite: TestSuite, home: URL, work: String) throws {
        try JSONSerialization.data(withJSONObject: ["env": ["HTTPS_PROXY": "https://work-proxy.invalid",
            "DISABLE_TELEMETRY": "1", "CLAUDE_CONFIG_DIR": "/another-account", "ANTHROPIC_API_KEY": "unused-test-value"]])
            .write(to: URL(fileURLWithPath: work + "/settings.json"))
        let base = ["PATH": "/usr/bin:/bin", "HOME": home.path, "CLAUDE_CONFIG_DIR": "/wrong-account",
                    "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/wrong-store", "CLAUDE_CONFIG_PATH": "/wrong-profile",
                    "CLAUDE_CODE_OAUTH_TOKEN": "unused-test-value",
                    "ANTHROPIC_API_KEY": "unused-test-value", "ANTHROPIC_AUTH_TOKEN": "unused-test-value",
                    "ANTHROPIC_BASE_URL": "https://wrong.invalid", "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDECODE": "nested"]
        let selected = AgentClaudeServer.environment(base, home: home, folder: work)
        let ordinary = AgentClaudeServer.environment(base, home: home)
        suite.expect(selected["CLAUDE_CONFIG_DIR"] == work && ordinary["CLAUDE_CONFIG_DIR"] == nil
                        && selected["HTTPS_PROXY"] == "https://work-proxy.invalid" && selected["DISABLE_TELEMETRY"] == "1"
                        && selected["PATH"] == base["PATH"] && selected["HOME"] == home.path,
                     "the chosen folder and its network settings replace inherited configuration without changing HOME")
        let overrides = ["CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CONFIG_PATH", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY",
                         "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDECODE"]
        let isolated = [selected, ordinary].allSatisfy { env in overrides.allSatisfy { env[$0] == nil } }
        suite.expect(isolated, "an inherited token, provider or secure-storage folder cannot override either account")
    }

    private static func conversations(_ suite: TestSuite, home: URL, work: String) throws {
        let tool = home.appending(path: "test-claude")
        try Data(folderStandIn.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let base = ["PATH": "/usr/bin:/bin", "HOME": home.path, "CLAUDE_CONFIG_DIR": "/wrong-account"]
        let personal = try AgentClaudeServer.Request().run(tool, home: home, environment: base, timeout: 3).get()
        let selected = try AgentClaudeServer.Request().run(tool, home: home, environment: base, folder: work, timeout: 3).get()
        suite.expect(personal.identity?.accountUuid == "personal" && personal.reading.fiveHour?.utilization == 91
                        && selected.identity?.accountUuid == "work" && selected.reading.fiveHour?.utilization == 12,
                     "the real transport asks each account folder for its own allowance without a login or model request")
        let changed = AgentClaudeServer.Request().run(tool, home: home,
            environment: base.merging(["SWITCH_ACCOUNT": "1"], uniquingKeysWith: { _, new in new }), folder: work, timeout: 3)
        suite.expect(changed == .failure(.unreachable),
                     "an answer is rejected when the folder signed in to another account meanwhile, even in the same organization")
        try saveAccount("work", to: work + "/.claude.json")
        let marker = home.appending(path: "test-started")
        try FileManager.default.removeItem(at: marker)
        let answer = AgentClaudeServer.Request().run(tool, home: home, environment: base,
                                                    folder: home.appending(path: "removed-profile").path, timeout: 3)
        suite.expect(answer == .failure(.needsSignIn) && !FileManager.default.fileExists(atPath: marker.path),
                     "a missing folder never starts Claude Code, and never with the default account")
        let cancelled = AgentClaudeServer.Request()
        cancelled.cancel()
        suite.expect(cancelled.run(tool, home: home, environment: base, folder: work, timeout: 3) == .failure(.unreachable)
                        && !FileManager.default.fileExists(atPath: marker.path),
                     "a cancelled request cannot start later")
    }

    /// Every account's logs are read, once even when accounts share projects/,
    /// and each account's own sessions folder is watched.
    private static func logs(_ suite: TestSuite, home: URL, work: String) {
        let both = AgentLogRoot.all(home: home, claudeFolders: ["", work])
        let claude = both.filter { $0.provider == .claude }.map(\.url.path)
        suite.expect(claude.contains(AgentLogRoot.canonical(URL(fileURLWithPath: work + "/projects")).path)
                        && claude.contains(AgentLogRoot.canonical(home.appending(path: ".claude/projects")).path)
                        && both.filter { $0.provider != .claude } == AgentLogRoot.all(home: home).filter { $0.provider != .claude },
                     "every Claude account's logs are read, and the other agents' roots are unchanged")
        let host = AgentUsageReadTests.Host()
        host.home = home
        host.start(session: 1, providers: [.claude], cancellation: AgentUsageReadTests.Cancellation(), claudeFolders: ["", work])
        let combined = host.snapshot.usage(.today).total.tokens.input
        host.start(session: 2, providers: [.claude], cancellation: AgentUsageReadTests.Cancellation(), claudeFolders: [""])
        suite.expect(combined == 103 && host.snapshot.usage(.today).total.tokens.input == 91,
                     "usage counts every account's sessions: \(combined) with both, \(host.snapshot.usage(.today).total.tokens.input) with one")
        // Share setup links an account's projects/ to the default one's.
        let shared = home.appending(path: ".claude-shared").path
        try? FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: shared + "/projects", withDestinationPath: home.path + "/.claude/projects")
        let linked = AgentLogRoot.all(home: home, claudeFolders: ["", shared]).filter { $0.provider == .claude }
        let sessions = AgentLogRoot.claudeSessionFolders(home: home, claudeFolders: ["", shared]).map(\.path)
        suite.expect(linked.count == 2 && sessions.contains(shared + "/sessions") && sessions.contains(home.path + "/.claude/sessions"),
                     "a shared projects/ is read once, while each account keeps its own sessions folder")
        // Each account keeps its own projects/ now, with a copy of every
        // conversation (ClaudeSync, T-38): a conversation is read from one
        // copy and counted once.
        let clone = home.appending(path: ".claude-clone").path
        try? FileManager.default.createDirectory(atPath: clone + "/projects/project", withIntermediateDirectories: true)
        try? FileManager.default.copyItem(atPath: home.path + "/.claude/projects/project/personal.jsonl",
                                          toPath: clone + "/projects/project/personal.jsonl")
        // File events name real paths.
        let original = AgentLogRoot.canonical(URL(fileURLWithPath: home.path + "/.claude/projects/project/personal.jsonl")).path
        let cloned = AgentLogRoot.canonical(URL(fileURLWithPath: clone + "/projects/project/personal.jsonl")).path
        let roots = AgentLogRoot.all(home: home, claudeFolders: ["", work, clone]).filter { $0.provider == .claude }
        let found = AgentLogReader.discover(roots, since: .distantPast).map(\.path)
        suite.expect(found.filter { $0.hasSuffix("/project/personal.jsonl") }.count == 1,
                     "discovery lists a conversation two account folders hold once: \(found)")
        AgentUsageReadTests.AgentLogReader.linesFrom = []
        host.start(session: 3, providers: [.claude], cancellation: AgentUsageReadTests.Cancellation(), claudeFolders: ["", work, clone])
        let read = Set(AgentUsageReadTests.AgentLogReader.linesFrom.filter { $0.hasSuffix("/project/personal.jsonl") })
        suite.expect(FileManager.default.fileExists(atPath: cloned) && host.snapshot.usage(.today).total.tokens.input == 103
                        && read.count == 1,
                     "a conversation cloned into two account folders is read once and counted once: \(host.snapshot.usage(.today).total.tokens.input), \(read)")
        // The copy that grows is where the conversation goes on: reading
        // moves to it and starts where the other stopped.
        let chosen = read.first ?? original
        let other = chosen == original ? cloned : original
        let before = AgentUsageReadTests.AgentLogReader.linesFrom.count
        if let handle = FileHandle(forWritingAtPath: other) {
            handle.seekToEndOfFile()
            handle.write(Data("\n".utf8))
            try? handle.close()
        }
        host.filesChanged([other], rescan: false)
        let after = AgentUsageReadTests.AgentLogReader.linesFrom[before...]
        suite.expect(after.allSatisfy { $0 == other } && after.count <= 1 && host.cursors[other] != nil && host.cursors[chosen] == nil
                        && host.snapshot.usage(.today).total.tokens.input == 103,
                     "a longer copy takes over without its start being read again: \(Array(after))")
        // The copy read goes out of view (ClaudeSync's check-out holds it in
        // .brim-checked-out while the conversation is open on another
        // account): the other copy is read in its place and nothing is lost;
        // the held copy is never read.
        let heldFolder = (other as NSString).deletingLastPathComponent + "/" + ClaudeSync.checkoutFolder
        try? FileManager.default.createDirectory(atPath: heldFolder, withIntermediateDirectories: true)
        let heldCopy = heldFolder + "/personal.jsonl"
        rename(other, heldCopy)
        AgentUsageReadTests.AgentLogReader.linesFrom = []
        host.filesChanged([other, heldCopy], rescan: false)
        host.publish()
        suite.expect(host.cursors[other] == nil && host.cursors[chosen] != nil && host.cursors[heldCopy] == nil
                        && !AgentUsageReadTests.AgentLogReader.linesFrom.contains(heldCopy)
                        && host.snapshot.usage(.today).total.tokens.input == 103,
                     "a copy checked out of view hands its conversation to another account's copy: \(host.snapshot.usage(.today).total.tokens.input), \(AgentUsageReadTests.AgentLogReader.linesFrom)")
        rename(heldCopy, other)
        AgentUsageReadTests.AgentLogReader.linesFrom = []
    }

    private static let folderStandIn = #"""
    #!/bin/sh
    [ -z "$CLAUDECODE" ] && [ "$DISABLE_AUTOUPDATER" = 1 ] || exit 2
    [ -z "$CLAUDE_SECURESTORAGE_CONFIG_DIR" ] || exit 2
    [ "$1" = --print ] && [ "$2" = --input-format ] && [ "$3" = stream-json ] || exit 2
    profile="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    printf started > "$HOME/test-started"
    while IFS= read -r line; do
      case "$line" in
        *'"subtype":"initialize"'*)
          printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"initialize","response":{}}}' ;;
        *'"subtype":"get_usage"'*)
          case "$line" in *'"skip_behaviors":true'*) ;; *) exit 3 ;; esac
          [ "$SWITCH_ACCOUNT" = 1 ] && printf '%s' '{"oauthAccount":{"accountUuid":"another","emailAddress":"another@example.invalid","organizationUuid":"same-organization"}}' > "$profile/.claude.json"
          used=$(cat "$profile/test-usage")
          printf '{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":%s,"resets_at":"2099-10-28T15:00:00Z"}}}}}\n' "$used" ;;
        *) exit 4 ;;
      esac
    done
    """#

    /// Where people install Claude Code, each in a home of its own, with
    /// stand-ins that only exit.
    private static func discovery(_ suite: TestSuite) {
        func home() throws -> URL {
            let home = FileManager.default.temporaryDirectory.appending(path: "brim-claude-install-\(UUID())")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            return home
        }
        func make(_ relative: String, in home: URL, _ script: String = "#!/bin/sh\nexit 0\n") throws {
            let file = home.appending(path: relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(script.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        // Only what is in the home: the Mac running the tests may have its own Claude Code.
        func found(_ home: URL) -> [String] {
            AgentClaudeServer.candidates(home: home).map(\.path)
                .filter { $0.hasPrefix(home.path + "/") && FileManager.default.isExecutableFile(atPath: $0) }
                .map { String($0.dropFirst(home.path.count + 1)) }
        }
        let layouts = [".volta/bin/claude", "Library/Application Support/fnm/aliases/default/bin/claude",
                       ".local/share/fnm/node-versions/v22.3.0/installation/bin/claude",
                       ".nvm/versions/node/v22.3.0/bin/claude", ".asdf/installs/nodejs/22.3.0/bin/claude",
                       ".local/share/mise/installs/node/22.3.0/bin/claude", ".bun/bin/claude", "Library/pnpm/claude",
                       ".npm-global/bin/claude"]
        var homes: [URL] = []
        defer { homes.forEach { try? FileManager.default.removeItem(at: $0) } }
        do {
            var missed: [String] = []
            for layout in layouts {
                let home = try home()
                homes.append(home)
                try make(layout, in: home)
                if found(home) != [layout] { missed.append(layout) }
            }
            suite.expect(missed.isEmpty, "Claude Code is found where version managers, Bun and pnpm keep it: missed \(missed)")
            let several = try home()
            homes.append(several)
            for version in ["v9.11.2", "v22.3.0", "v20.11.0"] { try make(".nvm/versions/node/\(version)/bin/claude", in: several) }
            // The Claude app's own copy has no sign-in of its own to check with.
            let bundled = "Library/Application Support/Claude/claude-code/2.1.299/4fa9694b7975"
            try make(bundled + "/claude.app/Contents/MacOS/claude", in: several)
            try make(bundled + "/.verified", in: several, "")
            let ordered = found(several)
            try make(".local/bin/claude", in: several)
            suite.expect(ordered == [".nvm/versions/node/v22.3.0/bin/claude", ".nvm/versions/node/v20.11.0/bin/claude",
                                     ".nvm/versions/node/v9.11.2/bin/claude"]
                            && found(several).first == ".local/bin/claude",
                         "the newest Node's Claude Code comes first, the person's own install before it, and never the Claude app's copy")
            // ~/.claude/local runs on Node, which may live only in a version manager.
            let local = try home()
            homes.append(local)
            try make(".claude/local/claude", in: local, "#!/usr/bin/env node\n")
            try make(".nvm/versions/node/v22.3.0/bin/node", in: local, "#!/bin/sh\nshift\nexec /bin/sh \"$HOME/stand-in\" \"$@\"\n")
            try Data(standIn.utf8).write(to: local.appending(path: "stand-in"))
            // Only the stand-in in this home ever runs, never a Claude Code of the Mac's.
            let tool = AgentClaudeServer.executable(home: local).flatMap { $0.path.hasPrefix(local.path + "/") ? $0 : nil }
            // Without Homebrew's folders, which may hold a Node of the Mac's.
            let path = AgentClaudeServer.searchPath(after: "/usr/bin:/bin", home: local)
            let answer = tool.map { tool in
                AgentClaudeServer.Request().run(tool, home: local,
                    environment: ["PATH": path, "HOME": local.path, "STAND_IN": "ok"], timeout: 5)
            }
            suite.expect(tool?.path.hasSuffix("/.claude/local/claude") == true
                            && (try? answer?.get())?.reading.isEmpty == false && path.hasPrefix("/usr/bin:/bin:"),
                         "a Claude Code in ~/.claude/local runs on the Node a version manager keeps, after the system's tools")
        } catch { suite.expect(false, "Claude Code install fixture: \(error)") }
        let failures: [AgentClaudeServer.Failure] = [.missing, .needsSignIn, .outdated, .unreachable]
        suite.expect(AppLanguage.allCases.allSatisfy { language in
            Set(failures.map { FeatureStrings.notchAgents(language).claudeCode($0) }).count == failures.count
        }, "Settings says in every language why Claude Code could not check")
    }

    private static let standIn = #"""
    #!/bin/sh
    [ -z "$CLAUDECODE" ] && [ "$DISABLE_AUTOUPDATER" = 1 ] || exit 2
    [ "$1" = "--print" ] && [ "$2" = "--input-format" ] && [ "$3" = "stream-json" ] || exit 2
    flags="$*"
    case "$flags" in *'--no-session-persistence --tools  --strict-mcp-config --mcp-config {"mcpServers":{}} --setting-sources  --settings {"disableAllHooks":true}'*) ;; *) exit 2 ;; esac
    [ "$STAND_IN" = exit ] && exit 0
    while IFS= read -r line; do
      [ "$STAND_IN" = silent ] && continue
      case "$line" in
        *'"subtype":"initialize"'*)
          printf '%s\n' '{"type":"system","subtype":"status"}' '{"type":"control_response","response":{"subtype":"success","request_id":"initialize","response":{}}}' ;;
        *'"subtype":"get_usage"'*)
          case "$line" in *'"skip_behaviors":true'*) ;; *) exit 3 ;; esac
          case "$STAND_IN" in
            old) printf '%s\n' '{"type":"control_response","response":{"subtype":"error","request_id":"usage","error":"get_usage is not supported in this context"}}' ;;
            unsupported) printf '%s\n' '{"type":"control_response","response":{"subtype":"error","request_id":"usage","error":"Unsupported control request subtype: get_usage"}}' ;;
            signedOut) printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"rate_limits_available":false,"rate_limits":null}}}' ;;
            unavailable) printf '%s\n' '{"type":"control_response","response":{"subtype":"error","request_id":"usage","error":"temporary failure"}}' ;;
            *) printf '%s\n' 'not json' '{"type":"control_response","response":{"subtype":"success","request_id":"other","response":{}}}' \
              '{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":100,"resets_at":"2099-10-15T10:40:00Z"},"seven_day":{"utilization":9,"resets_at":"2099-10-17T23:00:00Z"}}}}}' ;;
          esac ;;
        *) exit 4 ;;
      esac
    done
    # Saves what it fetched on its way out.
    [ "$STAND_IN" = saves ] && printf '{"cachedUsageUtilization":{"fetchedAtMs":%s000}}\n' "$(date +%s)" > "$HOME/.claude.json"
    """#
}
