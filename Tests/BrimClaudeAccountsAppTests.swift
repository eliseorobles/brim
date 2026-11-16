// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// Brim's Claude accounts in the app: finding and naming the accounts, when a
/// get_usage check may run, the limit notices, the installers' plans, edits
/// and undos, Terminal scripts (Open Terminal), the island's cards and the strings. Every
/// file lives in a temporary folder; no real Claude Code folder, shell file
/// or Brim state is read or written, and no `claude` is started.
enum BrimClaudeAccountsAppTests {
    static func run(_ suite: TestSuite) {
        let scratch = BrimClaudeAccountsTests.Scratch()
        defer { scratch.remove() }
        discovery(suite, scratch)
        labels(suite, scratch)
        refreshGate(suite)
        requests(suite, scratch)
        alerts(suite)
        shellInstall(suite, scratch)
        statusLineInstall(suite, scratch)
        uninstallRemoval(suite, scratch)
        stateRemoval(suite, scratch)
        terminalScript(suite)
        islandCards(suite)
        sharedSignIn(suite, scratch)
        strings(suite)
    }

    static let now = BrimClaudeAccountsTests.now
    static let anyFolder = BrimClaudeAccountsTests.anyFolder

    private static func config(_ uuid: String, email: String, tier: String = "default_claude_max_20x",
                               organization: String = "00000000-0000-4000-8000-0000000000ff") -> String {
        """
        {"numStartups":3,"oauthAccount":{"accountUuid":"\(uuid)","emailAddress":"\(email)",
         "organizationUuid":"\(organization)","organizationType":"claude_max","organizationRateLimitTier":"\(tier)"},
         "cachedUsageUtilization":{"fetchedAtMs":1794510510573,"accountUuid":"\(uuid)",
          "utilization":{"seven_day":{"utilization":39,"resets_at":"2026-11-15T14:00:00Z"}}}}
        """
    }

    private static func write(_ path: String, _ text: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private static func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    // MARK: Discovery

    private static func discovery(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let home = scratch.folder("discovery-home")
        write(home + "/.claude.json", config("00000000-0000-4000-8000-00000000000a", email: "someone@example.com"))
        let work = scratch.folder("discovery-home/.claude-work")
        write(work + "/.claude.json", config("00000000-0000-4000-8000-00000000000b", email: "someone@example.me"))
        _ = scratch.folder("discovery-home/.claude-empty")
        let linked = scratch.folder("discovery-home/.claude-hard")
        hardLink(home + "/.claude.json", linked + "/.claude.json")
        try? FileManager.default.createSymbolicLink(atPath: home + "/.claude-link", withDestinationPath: work)
        write(home + "/.claude-file", "{}")
        let candidates = ClaudeAccountsDiscovery.candidateFolders(home: home)
        suite.expect(candidates == [home + "/.claude-empty", home + "/.claude-hard", home + "/.claude-work"],
                     "candidates are real ~/.claude-<name> folders, spelled home + name: \(candidates)")
        suite.expect(ClaudeAccountsDiscovery.state(folder: linked, home: home) == .unreadable
                        && ClaudeAccountsDiscovery.state(folder: home + "/.claude-empty", home: home) == .missing,
                     "a .claude.json that is another folder's (a second link) never makes a second account")
        let scan = ClaudeAccountsDiscovery.scan(home: home, listed: [])
        let accounts = ClaudeAccountsDiscovery.merge(stored: [], discovered: scan.discovered, states: scan.states)
        suite.expect(accounts.map(\.folder) == ["", work] && accounts.map(\.label) == ["example", "example.me"]
                        && accounts.map(\.id) == ["default", ClaudeAccountKey.key(forFolder: work)]
                        && accounts.allSatisfy { $0.signedIn == true && $0.plan == "Max 20x" },
                     "the default account and each signed-in ~/.claude-<name> folder are found and named from their email: \(accounts.map(\.label))")
        // The person's names stay; an account added but not signed in yet stays.
        var stored = accounts
        stored[1].label = "personal"
        let added = scratch.folder("discovery-home/.claude-new")
        stored.append(ClaudeAccount(label: "new", folder: added, signedIn: false))
        let again = ClaudeAccountsDiscovery.scan(home: home, listed: stored.map(\.folder))
        let kept = ClaudeAccountsDiscovery.merge(stored: stored, discovered: again.discovered, states: again.states)
        suite.expect(kept.map(\.label) == ["example", "personal", "new"] && kept.last?.signedIn == false,
                     "labels the person set and accounts waiting for their sign-in are kept")
        try? FileManager.default.removeItem(atPath: added)
        let gone = ClaudeAccountsDiscovery.merge(stored: kept, discovered: [], states: [:])
        suite.expect(gone.map(\.label) == ["example", "personal"] && gone[1].email == "someone@example.me",
                     "a folder that is gone takes its account along, and an unread file keeps what was known")
        let signedOut = ClaudeAccountsDiscovery.merge(stored: gone, discovered: [], states: ["": .missing])
        suite.expect(signedOut.first?.signedIn == false && signedOut.first?.isDefault == true,
                     "the default account without ~/.claude.json is signed out, never dropped")
        suite.expect(ClaudeAccountsDiscovery.merge(stored: [], discovered: [], states: [:]).map(\.folder) == [""],
                     "the default account is always listed")
    }

    private static func hardLink(_ from: String, _ to: String) {
        _ = Darwin.link(from, to)
    }

    private static func labels(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        suite.expect(ClaudeAccountsDiscovery.label(email: "pat@rhodesconsulting.com", folder: "", taken: []) == "rhodesconsulting"
                        && ClaudeAccountsDiscovery.label(email: "pat@example.me", folder: "/x/.claude-a", taken: []) == "example.me"
                        && ClaudeAccountsDiscovery.label(email: "pat@gmail.com", folder: "", taken: []) == "pat"
                        && ClaudeAccountsDiscovery.label(email: nil, folder: "/x/.claude-work", taken: []) == "work"
                        && ClaudeAccountsDiscovery.label(email: nil, folder: "", taken: []) == "default"
                        && ClaudeAccountsDiscovery.label(email: "pat@example.com", folder: "", taken: ["example", "example-2"]) == "example-3",
                     "a new account is named from its email's domain, its webmail name or its folder, uniquely")
        let others = ["work"]
        suite.expect(ClaudeAccountsDiscovery.labelProblem("", others: others) != nil
                        && ClaudeAccountsDiscovery.labelProblem("two words", others: others) != nil
                        && ClaudeAccountsDiscovery.labelProblem("Auto", others: others) != nil
                        && ClaudeAccountsDiscovery.labelProblem("WORK", others: others) != nil
                        && ClaudeAccountsDiscovery.labelProblem("elliotgrayco.me", others: others) == nil,
                     "a name is one shell word, not \"auto\", and unique")
        let home = scratch.folder("labels-home")
        _ = scratch.folder("labels-home/.claude-client")
        suite.expect(ClaudeAccountsDiscovery.newFolder(label: "Client", home: home) == home + "/.claude-client-2"
                        && ClaudeAccountsDiscovery.newFolder(label: "other", home: home) == home + "/.claude-other",
                     "a new account gets a folder of its own, never an existing one")
    }

    // MARK: When a check runs

    private static func refreshGate(_ suite: TestSuite) {
        let fresh = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 10, resetsAt: nil,
                                                                      observedAt: now.addingTimeInterval(-5 * 60), source: .live))
        let stale = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 10, resetsAt: nil,
                                                                      observedAt: now.addingTimeInterval(-16 * 60), source: .cache))
        var gate = ClaudeRefreshGate()
        suite.expect(gate.next() == nil, "no check starts without an event")
        suite.expect(!gate.request("a", reading: fresh, model: nil, now: now, force: false)
                        && gate.request("a", reading: stale, model: nil, now: now, force: false)
                        && gate.request("b", reading: nil, model: nil, now: now, force: false),
                     "an event checks only accounts whose deciding windows are over 15 minutes old, or that have none")
        suite.expect(!gate.request("a", reading: stale, model: nil, now: now, force: true) && gate.isChecking("a"),
                     "Refresh does not queue a second check of an account already waiting")
        suite.expect(gate.next() == "a" && gate.next() == nil && gate.isChecking("b"),
                     "one check runs at a time; the next waits for it")
        gate.finished("a", succeeded: false, at: now)
        suite.expect(!gate.request("a", reading: stale, model: nil, now: now.addingTimeInterval(30), force: false)
                        && gate.next() == "b",
                     "after a failure the account waits out its backoff")
        gate.finished("b", succeeded: true, at: now)
        suite.expect(gate.request("a", reading: stale, model: nil, now: now.addingTimeInterval(61), force: false),
                     "the backoff is looked at again on the next event, with no retry timer")
        _ = gate.next()
        gate.finished("a", succeeded: false, at: now)
        suite.expect(!gate.request("a", reading: stale, model: nil, now: now.addingTimeInterval(119), force: false)
                        && gate.request("a", reading: stale, model: nil, now: now.addingTimeInterval(121), force: false),
                     "the backoff doubles with each failure in a row")
        suite.expect((1...8).map { ClaudeRefreshGate.backoff(afterFailures: $0) } == [60, 120, 240, 480, 960, 1_800, 1_800, 1_800]
                        && ClaudeRefreshGate.backoff(afterFailures: 0) == 0,
                     "the backoff goes 1, 2, 4, 8, 16 minutes and stops at 30")
        _ = gate.next()
        gate.finished("a", succeeded: false, at: now)
        suite.expect(gate.request("a", reading: fresh, model: nil, now: now, force: true),
                     "Refresh and a finished sign-in skip the freshness and the backoff")
        _ = gate.next()
        gate.finished("a", succeeded: true, at: now)
        suite.expect(gate.failures["a"] == nil, "an answer clears the failures")
        _ = gate.request("c", reading: nil, model: nil, now: now, force: false)
        gate.keep(only: ["a"])
        suite.expect(gate.next() == nil, "an account no longer listed is not checked")

        // The real failure: a session on the account keeps its weekly window
        // live, while the server-active Fable window (which no status line
        // reports) is from a /usage days ago. The gate must still check it.
        let busy = ClaudeAccountReading(
            sevenDay: ClaudeUsageWindow(utilization: 46, resetsAt: nil, observedAt: now, source: .live),
            scoped: [ClaudeScopedWindow(model: "Fable", utilization: 62, resetsAt: nil, active: true,
                                        observedAt: now.addingTimeInterval(-2 * 86_400), source: .cache)])
        var live = ClaudeRefreshGate()
        suite.expect(live.request("d", reading: busy, model: "opus", now: now, force: false)
                        && ClaudeRefreshGate().wants("d", reading: busy, model: nil, now: now, force: false),
                     "a live weekly window does not hide a stale scoped one the server marks active")
        var idle = busy
        idle.scoped[0].active = false
        suite.expect(!ClaudeRefreshGate().wants("d", reading: idle, model: "opus", now: now, force: false)
                        && ClaudeRefreshGate().wants("d", reading: idle, model: "fable", now: now, force: false),
                     "an inactive scoped window counts only for its own model")
    }

    private static func requests(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let paths = ClaudeAccountsPaths(stateDirectory: scratch.folder("requests-state"))
        try? paths.ensureDirectory(paths.requestsDirectory)
        write(paths.requestsDirectory + "/1794514200000-575e0284", #"{"account":"575e0284","reason":"pick"}"#)
        write(paths.requestsDirectory + "/1794514201000-575e0284", #"{"account":"575e0284","reason":"move"}"#)
        write(paths.requestsDirectory + "/1794514202000-default", "not json")
        write(paths.requestsDirectory + "/.1794514203000-default.123.tmp", "{}")
        let ids = ClaudeRefreshRequests.consume(paths)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: paths.requestsDirectory)) ?? []
        suite.expect(ids == ["575e0284", "default"] && left == [".1794514203000-default.123.tmp"],
                     "requests are read once per account, deleted, and another writer's temporary file is left: \(ids) \(left)")
    }

    // MARK: Notices

    private static func alerts(_ suite: TestSuite) {
        let accounts = [ClaudeAccount(label: "personal", folder: "/tmp/.claude-p", signedIn: true),
                        ClaudeAccount(label: "work", folder: "", signedIn: true)]
        func reading(_ fiveHour: Double, weekly: Double, resets: Date) -> ClaudeAccountReading {
            ClaudeAccountReading(fiveHour: ClaudeUsageWindow(utilization: fiveHour, resetsAt: resets, observedAt: now, source: .live),
                                 sevenDay: ClaudeUsageWindow(utilization: weekly, resetsAt: now.addingTimeInterval(86_400),
                                                             observedAt: now, source: .live))
        }
        let soon = now.addingTimeInterval(3_600)
        var ranks = ClaudeAccountRanking.rank(accounts, readings: [accounts[0].id: reading(91, weekly: 40, resets: soon),
                                                                   accounts[1].id: reading(10, weekly: 20, resets: soon)],
                                              model: nil, now: now, launchable: anyFolder)
        let quiet = ClaudeLimitAlerts.news(ranks, liveSessions: [:], notified: [])
        suite.expect(quiet.news.isEmpty, "an account with no running session is not notified")
        let first = ClaudeLimitAlerts.news(ranks, liveSessions: [accounts[0].id: 2], notified: [])
        suite.expect(first.news.map(\.kind) == [.fiveHour] && first.news.first?.label == "personal"
                        && ClaudeLimitAlerts.target(for: accounts[0].id, in: ranks)?.account.label == "work",
                     "a running account at 90 % of its 5-hour window is notified, naming the account to move to")
        let repeated = ClaudeLimitAlerts.news(ranks, liveSessions: [accounts[0].id: 2], notified: first.remembered)
        suite.expect(repeated.news.isEmpty, "each window is notified once")
        ranks = ClaudeAccountRanking.rank(accounts, readings: [accounts[0].id: reading(93, weekly: 96, resets: soon.addingTimeInterval(5 * 3_600))],
                                          model: nil, now: now, launchable: anyFolder)
        let renewed = ClaudeLimitAlerts.news(ranks, liveSessions: [accounts[0].id: 1], notified: first.remembered)
        suite.expect(Set(renewed.news.map(\.kind)) == [.fiveHour, .weekly] && !renewed.remembered.contains(first.news[0].key),
                     "a renewed window can notify again, and a weekly window at 95 % does too")
        suite.expect(ClaudeLimitAlerts.level(.fiveHour) == 90 && ClaudeLimitAlerts.level(.weekly) == 95
                        && ClaudeLimitAlerts.level(.scoped("Fable")) == 95, "the alert levels")
    }

    // MARK: Installers

    private static func shellInstall(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let home = scratch.folder("shell-home")
        let paths = ClaudeAccountsPaths(stateDirectory: home + "/.config/brim/claude")
        let helper = scratch.folder("Brim.app/Contents/Helpers") + "/brim-claude"
        let template = Data("# Brim zsh\nclaude() { :; }\n".utf8)
        let rc = "export PATH=$HOME/.local/bin:$PATH\neval \"$(direnv hook zsh)\"\nalias ll='ls -l'\n"
        write(home + "/.zshrc", rc)
        suite.expect(!ClaudeShellIntegration.plan(home: home, helper: helper, template: template).problems.isEmpty,
                     "the install is refused while this Brim has no helper")
        write(helper, "#!/bin/sh\n")
        let plan = ClaudeShellIntegration.plan(home: home, helper: helper, template: template)
        suite.expect(plan.problems.isEmpty && plan.lines.contains { $0.contains("after the direnv hook line") }
                        && read(home + "/.zshrc") == rc && !ClaudeFileIO.exists(ClaudeShellIntegration.linkPath(home: home)),
                     "the plan says what changes and changes nothing")
        let report = ClaudeShellIntegration.install(home: home, helper: helper, template: template, paths: paths, now: now)
        let lines = read(home + "/.zshrc").components(separatedBy: "\n")
        let backups = ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []).filter { $0.hasPrefix(".zshrc.brim-backup-") }
        suite.expect(report.succeeded && lines[2] == ClaudeShellIntegration.line && lines[1].contains("direnv hook zsh")
                        && ClaudeFileIO.linkDestination(ClaudeShellIntegration.linkPath(home: home)) == helper
                        && ClaudeFileIO.read(ClaudeShellIntegration.scriptPath(home: home)) == template
                        && backups.count == 1 && read(home + "/" + backups[0]) == rc
                        && ClaudeShellIntegration.status(home: home, helper: helper, template: template) == .installed,
                     "the install links the helper, writes the functions and sources them after the direnv hook, after a backup")
        let newer = template + Data("# newer Brim\n".utf8)
        suite.expect(ClaudeShellIntegration.status(home: home, helper: helper, template: newer) == .partial,
                     "functions an older Brim wrote are out of date (partial), so the setup row offers the update")
        _ = ClaudeShellIntegration.install(home: home, helper: helper, template: newer, paths: paths, now: now)
        suite.expect(ClaudeFileIO.read(ClaudeShellIntegration.scriptPath(home: home)) == newer
                        && ClaudeShellIntegration.status(home: home, helper: helper, template: newer) == .installed,
                     "installing again writes this Brim's functions")
        _ = ClaudeShellIntegration.install(home: home, helper: helper, template: template, paths: paths, now: now)
        suite.expect(read(home + "/.zshrc").components(separatedBy: ClaudeShellIntegration.line).count == 2,
                     "installing again adds no second line")
        let undo = ClaudeShellIntegration.undo(paths: paths)
        suite.expect(undo.succeeded && read(home + "/.zshrc") == rc
                        && !ClaudeFileIO.exists(ClaudeShellIntegration.linkPath(home: home))
                        && !ClaudeFileIO.exists(ClaudeShellIntegration.scriptPath(home: home))
                        && ClaudeInstallRecord.load(paths).shell == nil,
                     "undo takes back exactly what the install did")
        try? FileManager.default.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: ClaudeShellIntegration.linkPath(home: home), withDestinationPath: "/usr/bin/true")
        suite.expect(ClaudeShellIntegration.install(home: home, helper: helper, template: template, paths: paths, now: now).refused
                        && read(home + "/.zshrc") == rc,
                     "a brim-claude on PATH that is not Brim's is left alone and nothing changes")
        suite.expect(ClaudeShellIntegration.inserting("L", into: "a\nb\n") == "a\nb\nL\n"
                        && ClaudeShellIntegration.inserting("L", into: "# eval \"$(direnv hook zsh)\"\nx") == "# eval \"$(direnv hook zsh)\"\nx\nL"
                        && ClaudeShellIntegration.inserting("L", into: "") == "L\n"
                        && ClaudeShellIntegration.removing("L", from: "a\nL\nb\n") == "a\nb\n"
                        && ClaudeShellIntegration.removing("L", from: "a\n") == nil,
                     "without an active direnv hook the line goes at the end, and removal takes only that line")
    }

    private static func statusLineInstall(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let home = scratch.folder("statusline-home")
        let paths = ClaudeAccountsPaths(stateDirectory: home + "/.config/brim/claude")
        let helper = "/Applications/Brim (Developer).app/Contents/Helpers/brim-claude"
        let settings = ClaudeStatusLineInstall.settingsPath(home: home)
        let original = "{\n  \"model\": \"opus\",\n  \"env\": {\n    \"A\": \"1\"\n  }\n}\n"
        write(settings, original)
        let plan = ClaudeStatusLineInstall.plan(home: home, helper: helper)
        suite.expect(plan.problems.isEmpty && read(settings) == original, "the plan changes nothing")
        let report = ClaudeStatusLineInstall.install(home: home, helper: helper, paths: paths, now: now)
        let installed = read(settings)
        let json = ClaudeJSON.parse(Data(installed.utf8)) as? [String: Any]
        let line = json?["statusLine"] as? [String: Any]
        suite.expect(report.succeeded && line?["type"] as? String == "command"
                        && line?["command"] as? String == "'/Applications/Brim (Developer).app/Contents/Helpers/brim-claude' statusline"
                        && json?["model"] as? String == "opus" && installed.hasPrefix("{\n  \"statusLine\": ")
                        && installed.hasSuffix("  \"model\": \"opus\",\n  \"env\": {\n    \"A\": \"1\"\n  }\n}\n")
                        && ClaudeStatusLineInstall.status(home: home) == .installed(command: line?["command"] as? String ?? ""),
                     "the status line is added as text, the rest of the file keeping its order and spacing: \(installed)")
        let undo = ClaudeStatusLineInstall.undo(paths: paths)
        suite.expect(undo.succeeded && read(settings) == original && ClaudeInstallRecord.load(paths).statusLine == nil,
                     "undo restores the file exactly")
        write(settings, #"{"statusLine":{"type":"command","command":"~/bin/my-line"}}"#)
        suite.expect(ClaudeStatusLineInstall.install(home: home, helper: helper, paths: paths, now: now).refused
                        && ClaudeStatusLineInstall.status(home: home) == .other,
                     "another status line is never replaced")
        try? FileManager.default.removeItem(atPath: settings)
        let created = ClaudeStatusLineInstall.install(home: home, helper: helper, paths: paths, now: now)
        suite.expect(created.succeeded && ClaudeFileIO.exists(settings), "a missing settings file is created")
        suite.expect(ClaudeStatusLineInstall.undo(paths: paths).succeeded && !ClaudeFileIO.exists(settings),
                     "and its undo removes it again")
        suite.expect(ClaudeStatusLineInstall.inserting(command: "x statusline", into: "[1]") == nil
                        && ClaudeStatusLineInstall.inserting(command: "x statusline", into: "{}")?.text == "{\n  \"statusLine\": {\"command\":\"x statusline\",\"type\":\"command\"}\n}",
                     "only a JSON object is edited")
    }

    /// The real failure: uninstalling Brim left every session's status line
    /// pointing at a helper that was gone.
    private static func uninstallRemoval(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let home = scratch.folder("uninstall-home")
        let paths = ClaudeAccountsPaths(stateDirectory: home + "/.config/brim/claude")
        let helper = scratch.folder("Uninstall/Brim.app/Contents/Helpers") + "/brim-claude"
        write(helper, "#!/bin/sh\n")
        let rc = "eval \"$(direnv hook zsh)\"\n"
        let original = "{\n  \"model\": \"opus\"\n}\n"
        let settings = ClaudeStatusLineInstall.settingsPath(home: home)
        write(home + "/.zshrc", rc)
        write(settings, original)
        let shell = ClaudeShellIntegration.install(home: home, helper: helper, template: Data("# zsh\n".utf8), paths: paths, now: now)
        let line = ClaudeStatusLineInstall.install(home: home, helper: helper, paths: paths, now: now)
        suite.expect(shell.succeeded && line.succeeded && ClaudeShellIntegration.status(home: home, helper: helper, template: Data("# zsh\n".utf8)) == .installed
                        && ClaudeStatusLineInstall.status(home: home) != .notInstalled,
                     "both are in place before the uninstall")
        let lines = ClaudeInstallsRemoval.undoAll(paths: paths, home: home)
        suite.expect(!lines.isEmpty && read(home + "/.zshrc") == rc && read(settings) == original
                        && !ClaudeFileIO.exists(ClaudeShellIntegration.linkPath(home: home))
                        && !ClaudeFileIO.exists(ClaudeShellIntegration.scriptPath(home: home))
                        && ClaudeInstallRecord.load(paths) == ClaudeInstallRecord(),
                     "uninstalling Brim takes back its status line and shell integration exactly: \(lines)")
        suite.expect(ClaudeInstallsRemoval.undoAll(paths: paths, home: home).isEmpty, "with nothing installed it does nothing")
        let inApp = read("Sources/Brim/Services/SelfUninstall.swift")
        let flag = read("Sources/Brim/Support/Uninstaller.swift")
        let script = read("Tools/uninstall.sh")
        suite.expect(inApp.contains("ClaudeInstallsRemoval.uninstall(environment: ProcessInfo.processInfo.environment)")
                        && flag.contains("ClaudeInstallsRemoval.undoAll(paths: .current, home:") && !flag.contains("removeState")
                        && script.contains("installs.json") && script.contains("claude_left"),
                     "the in-app uninstall takes it back, then removes the state folder; --uninstall only takes it back, so the script can still name whatever is left")
    }

    /// The real failure (T-20): uninstalling Brim left ~/.config/brim/claude
    /// behind. The in-app uninstall takes back what was installed, reading
    /// installs.json from that folder, then deletes the folder. Only Brim's
    /// own folder ever goes: a link, a folder inside ~/.claude*, the home
    /// folder or one above it, or a path of any other shape is refused.
    private static func stateRemoval(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let home = scratch.folder("state-home")
        let environment = ["HOME": home]
        let paths = ClaudeAccountsPaths(environment: environment, home: home)
        let helper = scratch.folder("State/Brim.app/Contents/Helpers") + "/brim-claude"
        write(helper, "#!/bin/sh\n")
        let rc = "eval \"$(direnv hook zsh)\"\n"
        let original = "{\n  \"model\": \"opus\"\n}\n"
        let settings = ClaudeStatusLineInstall.settingsPath(home: home)
        write(home + "/.zshrc", rc)
        write(settings, original)
        write(home + "/.config/other/keep", "keep")
        let installed = ClaudeShellIntegration.install(home: home, helper: helper, template: Data("# zsh\n".utf8), paths: paths, now: now).succeeded
            && ClaudeStatusLineInstall.install(home: home, helper: helper, paths: paths, now: now).succeeded
        write(paths.accountsFile, "{}")
        write(paths.liveFile(key: "a"), "{}")
        write(paths.sessionFile("s"), "{}")
        write(paths.mcpBackupsDirectory + "/a-20261113-000000.json", "{}")
        write(paths.requestsDirectory + "/a", "")
        let outside = scratch.folder("state-outside")
        write(outside + "/keep", "keep")
        symlink(outside, paths.stateDirectory + "/link")
        suite.expect(installed && paths.stateDirectory == home + "/.config/brim/claude"
                        && ClaudeFileIO.isRegularFile(ClaudeInstallRecord.path(paths)),
                     "the state folder and its install record are in place before the uninstall")
        let lines = ClaudeInstallsRemoval.uninstall(environment: environment)
        suite.expect(read(home + "/.zshrc") == rc && read(settings) == original
                        && !ClaudeFileIO.exists(ClaudeShellIntegration.linkPath(home: home))
                        && !ClaudeFileIO.exists(ClaudeShellIntegration.scriptPath(home: home)),
                     "the undo runs first, from the install record in the folder: \(lines)")
        suite.expect(!ClaudeFileIO.exists(paths.stateDirectory) && !ClaudeFileIO.exists(home + "/.config/brim"),
                     "then the state folder goes, and the variant folder it leaves empty: \(lines)")
        suite.expect(ClaudeFileIO.isDirectory(home + "/.config") && read(home + "/.config/other/keep") == "keep"
                        && read(outside + "/keep") == "keep",
                     "~/.config, its other folders and whatever a link inside the state folder pointed at stay")
        suite.expect(ClaudeInstallsRemoval.uninstall(environment: environment).isEmpty, "with nothing left it does nothing")

        let shared = scratch.folder("shared-home")
        write(shared + "/.config/brim/claude/accounts.json", "{}")
        write(shared + "/.config/brim/backups/keep", "keep")
        let sharedReport = ClaudeInstallsRemoval.removeState(paths: ClaudeAccountsPaths(environment: [:], home: shared), home: shared)
        suite.expect(sharedReport.succeeded && !ClaudeFileIO.exists(shared + "/.config/brim/claude")
                        && read(shared + "/.config/brim/backups/keep") == "keep",
                     "a variant folder with anything else in it stays: \(sharedReport.lines)")

        let override = scratch.folder("override") + "/claude"
        write(override + "/accounts.json", "{}")
        write(shared + "/.config/brim/claude/accounts.json", "{}")
        let overridden = ClaudeInstallsRemoval.uninstall(environment: ["HOME": shared, "BRIM_CLAUDE_STATE_DIR": override])
        suite.expect(!ClaudeFileIO.exists(override) && ClaudeFileIO.isDirectory(scratch.root + "/override")
                        && read(shared + "/.config/brim/claude/accounts.json") == "{}",
                     "BRIM_CLAUDE_STATE_DIR: that folder goes; the one above it and the standard folder stay: \(overridden)")

        let target = scratch.folder("link-target")
        write(target + "/keep", "keep")
        symlink(target, scratch.folder("links") + "/claude")
        _ = scratch.folder("dots/claude")
        _ = scratch.folder("dots/a")
        let claudeHome = scratch.folder("claude")
        _ = scratch.folder("claude/user")
        let linked = scratch.folder("linked-home")
        write(linked + "/.claude-x/brim/claude/accounts.json", "{}")
        _ = scratch.folder("linked-home/.config")
        symlink(linked + "/.claude-x/brim", linked + "/.config/brim")
        let refused: [(folder: String, home: String, what: String)] = [
            (scratch.root + "/links/claude", home, "a link named claude"),
            (scratch.folder("refuse-home/.claude-work/claude"), home, "a folder inside ~/.claude*"),
            (scratch.folder("refuse/state"), home, "a folder with another name"),
            (scratch.root + "/dots/a/../claude", home, "a path with .. in it"),
            (scratch.root + "/dots/claude/", home, "a path with an empty part"),
            (claudeHome, claudeHome, "the home folder"),
            (claudeHome, claudeHome + "/user", "a folder above the home folder"),
            (linked + "/.config/brim/claude", linked, "a folder that resolves inside ~/.claude*"),
        ]
        for refusal in refused {
            let report = ClaudeInstallsRemoval.removeState(paths: ClaudeAccountsPaths(stateDirectory: refusal.folder), home: refusal.home)
            suite.expect(report.refused && ClaudeFileIO.exists(refusal.folder),
                         "\(refusal.what) is left alone: \(report.lines)")
        }
        suite.expect(ClaudeFileIO.isSymlink(scratch.root + "/links/claude") && read(target + "/keep") == "keep"
                        && read(linked + "/.claude-x/brim/claude/accounts.json") == "{}",
                     "and nothing a refused link points at is touched")
    }

    // MARK: Launching

    private static func terminalScript(_ suite: TestSuite) {
        let home = "/Users/someone"
        let defaultScript = ClaudeLaunchEnvironment.terminalScript(forFolder: "", arguments: ["--resume", "abc"],
                                                                   executable: "/Users/someone/.local/bin/claude", directory: home)
        let other = ClaudeLaunchEnvironment.terminalScript(forFolder: "/Users/someone/.claude-new one", arguments: [],
                                                           executable: "claude", directory: home)
        suite.expect(defaultScript.hasPrefix("#!/bin/zsh\nrm -f -- \"$0\"\ncd -- /Users/someone || exit 1\n")
                        && defaultScript.contains("env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CONFIG_DIR /Users/someone/.local/bin/claude --resume abc")
                        && !defaultScript.contains("CLAUDE_CONFIG_DIR=")
                        && other.contains("CLAUDE_CONFIG_DIR='\\''/Users/someone/.claude-new one'\\''")
                        && other.contains("-u CLAUDE_SECURESTORAGE_CONFIG_DIR"),
                     "Terminal starts the default account with CLAUDE_CONFIG_DIR removed and others with their exact folder")
    }

    // MARK: Island

    private static func islandCards(_ suite: TestSuite) {
        let accounts = BrimClaudeAccountsTests.todaysAccounts()
        let readings = BrimClaudeAccountsTests.todaysReadings()
        let ranks = ClaudeAccountRanking.rank(accounts, readings: readings, model: "fable", now: now, launchable: anyFolder)
        let stern = ranks.first { !$0.account.isDefault }
        let limits = stern.flatMap(ClaudeAccountsAppSupport.limits)
        suite.expect(limits?.provider == .claude && limits?.source == .account
                        && limits?.windows.map(\.id).allSatisfy { $0.hasPrefix("claude.575e0284.") } == true
                        && limits?.windows.contains { $0.scope == "Fable" && $0.usedPercent == 62 && $0.kind == .weekly } == true,
                     "an account's card shows its own windows, the scoped one by model")
        let renewed = ClaudeAccountRanking.rank(accounts, readings: readings, model: nil,
                                                now: BrimClaudeAccountsTests.sternWeeklyReset.addingTimeInterval(60),
                                                launchable: anyFolder)
        let estimated = renewed.first { !$0.account.isDefault }.flatMap(ClaudeAccountsAppSupport.limits)?
            .windows.first { $0.kind == .weekly && $0.scope == nil }
        suite.expect(estimated?.usedPercent == 0 && estimated?.resetsAt == nil && estimated?.estimatedResetsAt != nil,
                     "a renewed window shows its estimate as an estimate")
        let live = ClaudeLiveFile(observedAt: now, folder: "", sessionId: "s", cwd: nil, model: nil, fiveHour: nil, sevenDay: nil)
        let older = ClaudeLiveFile(observedAt: now.addingTimeInterval(-60), folder: BrimClaudeAccountsTests.stern, sessionId: "t",
                                   cwd: nil, model: nil, fiveHour: nil, sevenDay: nil)
        let both = [ranks[0].account.id: 1, ranks[1].account.id: 1]
        suite.expect(ClaudeAccountsAppSupport.focus(ranks, liveSessions: both, live: ["default": live, "575e0284": older],
                                                    newSessions: .auto)?.account.isDefault == true
                        && ClaudeAccountsAppSupport.focus(ranks, liveSessions: [:], live: [:], newSessions: .auto)?.account.id == ranks[0].account.id
                        && ClaudeAccountsAppSupport.focus(ranks, liveSessions: [:], live: [:], newSessions: .account("default"))?.account.isDefault == true,
                     "the island follows the account whose session reported last, else the one new sessions use")
        let max = AgentPlan(name: "Max 20x", monthlyPrice: 200)
        suite.expect(ClaudeAccountsAppSupport.plan([max]) == max
                        && ClaudeAccountsAppSupport.plan([max, max]) == AgentPlan(name: "2 × Max 20x", monthlyPrice: 400)
                        && ClaudeAccountsAppSupport.plan([max, AgentPlan(name: "Pro", monthlyPrice: nil)])
                            == AgentPlan(name: "Max 20x + Pro", monthlyPrice: nil)
                        && ClaudeAccountsAppSupport.plan([]) == nil,
                     "the plan compared with API value counts every account")
        suite.expect(DefaultsKey.panelShowClaude == "panelShowClaude"
                        && MenuPanelSectionGateContract.PanelSectionID.claude.featureGate == [.notchAgents]
                        && MenuPanelSectionGateContract.PanelSectionID.allCases.last == .claude,
                     "the panel's Claude section belongs to the AI agents feature, not the island")
    }

    /// ~/.claude and ~/.claude-stern signed in to one account, and
    /// ~/.claude-rhodesconsulting signing in: found from the disk as folders,
    /// then one account in the island, its notices and the plan.
    private static func sharedSignIn(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let home = scratch.folder("shared-home")
        let uuid = "00000000-0000-4000-8000-00000000000a"
        write(home + "/.claude.json", config(uuid, email: "elliot@rhodesconsulting.com"))
        let stern = scratch.folder("shared-home/.claude-stern")
        write(stern + "/.claude.json", config(uuid, email: "elliot@rhodesconsulting.com"))
        let rhodes = scratch.folder("shared-home/.claude-rhodesconsulting")
        write(rhodes + "/.claude.json", #"{"numStartups":1}"#)
        let scan = ClaudeAccountsDiscovery.scan(home: home, listed: [])
        var accounts = ClaudeAccountsDiscovery.merge(stored: [], discovered: scan.discovered, states: scan.states)
        let groups = ClaudeAccountsDiscovery.groups(accounts, launchable: anyFolder)
        suite.expect(accounts.map(\.folder) == ["", stern] && groups.count == 1 && groups[0].members.map(\.folder) == ["", stern]
                        && accounts.allSatisfy { $0.organizationUuid == "00000000-0000-4000-8000-0000000000ff" },
                     "both signed-in folders are listed, as one account in the default folder; a folder still signing in is not yet")
        write(rhodes + "/.claude.json", config("00000000-0000-4000-8000-00000000000c", email: "elliot@rhodesconsulting.co"))
        let signedIn = ClaudeAccountsDiscovery.scan(home: home, listed: accounts.map(\.folder))
        accounts = ClaudeAccountsDiscovery.merge(stored: accounts, discovered: signedIn.discovered, states: signedIn.states)
        suite.expect(ClaudeAccountsDiscovery.groups(accounts, launchable: anyFolder).map { $0.members.count } == [2, 1],
                     "once ~/.claude-rhodesconsulting signs in to another account it is a second account")
        // The same login in a team organization: its own plan limits, so
        // its own account, never merged with the personal one.
        write(stern + "/.claude.json", config(uuid, email: "elliot@rhodesconsulting.com",
                                              organization: "00000000-0000-4000-8000-0000000000ee"))
        let team = ClaudeAccountsDiscovery.scan(home: home, listed: accounts.map(\.folder))
        let teamAccounts = ClaudeAccountsDiscovery.merge(stored: accounts, discovered: team.discovered, states: team.states)
        suite.expect(ClaudeAccountsDiscovery.groups(teamAccounts, launchable: anyFolder).map { $0.members.count } == [1, 1, 1],
                     "one login in two organizations is two accounts")
        write(stern + "/.claude.json", config(uuid, email: "elliot@rhodesconsulting.com"))

        func reading(_ fiveHour: Double, observed: Date) -> ClaudeAccountReading {
            ClaudeAccountReading(fiveHour: ClaudeUsageWindow(utilization: fiveHour, resetsAt: now.addingTimeInterval(3_600),
                                                             observedAt: observed, source: .live),
                                 sevenDay: ClaudeUsageWindow(utilization: 20, resetsAt: now.addingTimeInterval(86_400),
                                                             observedAt: observed, source: .live))
        }
        let sternID = ClaudeAccountKey.key(forFolder: stern)
        let rhodesID = ClaudeAccountKey.key(forFolder: rhodes)
        let ranks = ClaudeAccountRanking.rank(accounts, readings: ["default": reading(10, observed: now.addingTimeInterval(-600)),
                                                                   sternID: reading(92, observed: now),
                                                                   rhodesID: reading(5, observed: now)],
                                              model: nil, now: now, launchable: anyFolder)
        let shared = ranks.first { $0.sharesSignIn }
        suite.expect(ranks.count == 2 && shared?.account.isDefault == true
                        && shared?.windows.first { $0.kind == .fiveHour }?.utilization == 92,
                     "the account ranks once, on stern's newer status line")
        let news = ClaudeLimitAlerts.news(ranks, liveSessions: [sternID: 1], notified: [])
        suite.expect(news.news.map(\.accountID) == ["default"] && news.news.first?.kind == .fiveHour
                        && ClaudeLimitAlerts.target(for: "default", in: ranks)?.account.folder == rhodes,
                     "a session in ~/.claude-stern near the limit notifies once for the account and names the other one")
        let live = ClaudeLiveFile(observedAt: now, folder: stern, sessionId: "s", cwd: nil, model: nil, fiveHour: nil, sevenDay: nil)
        let older = ClaudeLiveFile(observedAt: now.addingTimeInterval(-60), folder: rhodes, sessionId: "t", cwd: nil,
                                   model: nil, fiveHour: nil, sevenDay: nil)
        suite.expect(ClaudeAccountsAppSupport.focus(ranks, liveSessions: [sternID: 1, rhodesID: 1],
                                                    live: [sternID: live, rhodesID: older], newSessions: .auto)?.account.isDefault == true
                        && ClaudeAccountsAppSupport.focus(ranks, liveSessions: [:], live: [:],
                                                          newSessions: .account(sternID))?.account.isDefault == true,
                     "the island follows the shared account for a session or a choice in either folder")
        let identity = ClaudeIdentity(accountUuid: uuid, email: nil, organizationUuid: nil, organizationType: "claude_max",
                                      rateLimitTier: "default_claude_max_20x", planDisplayName: nil)
        let other = ClaudeIdentity(accountUuid: "00000000-0000-4000-8000-00000000000c", email: nil, organizationUuid: nil,
                                   organizationType: "claude_max", rateLimitTier: "default_claude_max_5x", planDisplayName: nil)
        let once = ClaudeAccountsAppSupport.accountIdentities(ClaudeAccountsDiscovery.groups(accounts, launchable: anyFolder),
                                                              identities: ["default": identity, sternID: identity, rhodesID: other])
        suite.expect(once == [identity, other], "the plan counts the shared account once")
        let text = FeatureStrings.claudeAccounts(.enUS)
        suite.expect(text.sameSignIn(2) == "Same sign-in in 2 folders", "the accounts list says the folders share a sign-in")
    }

    private static func strings(_ suite: TestSuite) {
        for language in AppLanguage.allCases {
            let text = FeatureStrings.claudeAccounts(language)
            let empty = Mirror(reflecting: text).children.compactMap { child -> String? in
                guard let value = child.value as? String else { return nil }
                return value.isEmpty ? child.label : nil
            }
            suite.expect(empty.isEmpty && text.left("38%") == "38% left" && text.running(2) == "2 running"
                            && text.notifyBody(window: "5h", percent: "92%", target: "work").contains("cx --to work"),
                         "Claude accounts have every string in \(language.rawValue) (English until translated): empty \(empty)")
        }
    }
}
