// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// Brim's Claude Code accounts core (Sources/Brim/Modules/ClaudeAccounts):
/// keys, launch environments, decoding, ranking, the brim-claude subcommands,
/// the session index, sharing the setup, MCP mirroring and the build and
/// shell contracts. Everything runs in temporary folders; nothing reads or
/// writes a real Claude Code folder, Brim's real state or a credential, and
/// no `claude` is started.
///
/// Fixtures follow the shapes of today's .claude.json files (Claude Code
/// 2.1.322) with made-up ids and example.com addresses.
enum BrimClaudeAccountsTests {
    static func run(_ suite: TestSuite) {
        let scratch = Scratch()
        defer { scratch.remove() }
        keys(suite)
        launchEnvironment(suite)
        dates(suite)
        configDecoding(suite)
        getUsageDecoding(suite)
        statusLineDecoding(suite)
        ranking(suite)
        merging(suite)
        accountsFile(suite, scratch)
        statusline(suite, scratch)
        pick(suite, scratch)
        sessionIndex(suite, scratch)
        move(suite, scratch)
        heldOpen(suite, scratch)
        sharedSignIn(suite, scratch)
        sharing(suite, scratch)
        historyLock(suite, scratch)
        mcpMirror(suite, scratch)
        selftest(suite, scratch)
        shellIntegration(suite, scratch)
        buildContract(suite)
        sourceRules(suite)
    }

    /// Each account's own conversation folders, kept in sync (ticket
    /// T-38): the migration from linked folders, the sync and resume planning
    /// (the zsh wrapper's side is in shellIntegration).
    static func ownFolderChecks(_ suite: TestSuite) {
        let scratch = Scratch()
        defer { scratch.remove() }
        ownFolders(suite, scratch)
        sync(suite, scratch)
        syncRecreatedFolder(suite, scratch)
        syncEndsWithProcess(suite, scratch)
        syncCheckout(suite, scratch)
        syncCheckoutEdges(suite, scratch)
        resume(suite, scratch)
    }

    // MARK: Fixtures

    static let stern = "/Users/elliotgrayco/.claude-stern"
    static let defaultUuid = "00000000-0000-4000-8000-00000000000a"
    static let sternUuid = "00000000-0000-4000-8000-00000000000b"
    /// 2026-11-12T20:10Z, when today's numbers were read.
    static let now = Date(timeIntervalSince1970: 1_794_514_200)
    /// The launch check for fixtures whose folders are not on disk.
    static let anyFolder: (ClaudeAccount) -> Bool = { _ in true }
    /// 2026-11-15T14:00Z and 2026-11-17T10:00Z.
    static let sternWeeklyReset = Date(timeIntervalSince1970: 1_794_751_200)
    static let defaultWeeklyReset = Date(timeIntervalSince1970: 1_794_909_600)

    static func config(accountUuid: String = sternUuid, cacheUuid: String? = sternUuid,
                       fetchedAtMs: Int64 = 1_794_510_510_573, startups: Int = 7) -> String {
        let owner = cacheUuid.map { "\"accountUuid\":\"\($0)\"," } ?? ""
        return """
            {"numStartups":\(startups),"projects":{"/tmp/a":{"allowedTools":[],"history":[]}},
             "cachedGrowthBookFeatures":{"flag_a":true,"flag_b":{"nested":[1,2,3]}},
             "oauthAccount":{"accountUuid":"\(accountUuid)","emailAddress":"person@example.com",
              "organizationUuid":"00000000-0000-4000-8000-0000000000ff","billingType":"stripe_subscription",
              "planDisplayName":"Ultra","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x",
              "userRateLimitTier":null},
             "cachedUsageUtilization":{"fetchedAtMs":\(fetchedAtMs),\(owner)
              "utilization":{"five_hour":null,
               "seven_day":{"utilization":39,"resets_at":"2026-11-15T14:00:00.469636+00:00","limit_dollars":null},
               "seven_day_opus":null,"seven_day_sonnet":null,"cinder_cove":null,
               "extra_usage":{"is_enabled":false,"monthly_limit":117500,"used_credits":1966,"utilization":1.6731914893617021,
                "currency":"USD","decimal_places":2,"disabled_reason":"out_of_credits"},
               "limits":[{"kind":"weekly_all","group":"weekly","percent":39,"severity":"normal",
                          "resets_at":"2026-11-15T14:00:00.469636+00:00","scope":null,"is_active":false},
                         {"kind":"weekly_scoped","group":"weekly","percent":62,"severity":"normal",
                          "resets_at":"2026-11-15T14:00:00.469819+00:00",
                          "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}],
               "spend":{"percent":2,"severity":"normal"},"seven_day_breakdown":{"rows":[]}}}}
            """
    }

    static func todaysAccounts(folder: String = stern, signedIn: Bool? = true) -> [ClaudeAccount] {
        [ClaudeAccount(label: "rhodesconsulting", folder: "", accountUuid: defaultUuid, plan: "Max 20x", signedIn: signedIn),
         ClaudeAccount(label: "elliotgrayco.me", folder: folder, accountUuid: sternUuid, plan: "Max 20x", signedIn: signedIn)]
    }

    /// Today's readings: the default account at 1 % of its week, renewing
    /// Tuesday; elliotgrayco.me at 39 % of its week and 62 % of its Fable
    /// allowance, renewing Sunday.
    static func todaysReadings(sternKey: String = "575e0284", defaultObserved: Date = now.addingTimeInterval(-252 * 60),
                               sternObserved: Date = now.addingTimeInterval(-61 * 60)) -> [String: ClaudeAccountReading] {
        let defaultReading = ClaudeAccountReading(
            sevenDay: ClaudeUsageWindow(utilization: 1, resetsAt: defaultWeeklyReset, observedAt: defaultObserved, source: .cache),
            scoped: [ClaudeScopedWindow(model: "Fable", utilization: 0, resetsAt: defaultWeeklyReset, active: false,
                                        observedAt: defaultObserved, source: .cache)])
        let sternReading = ClaudeAccountReading(
            sevenDay: ClaudeUsageWindow(utilization: 39, resetsAt: sternWeeklyReset, observedAt: sternObserved, source: .cache),
            scoped: [ClaudeScopedWindow(model: "Fable", utilization: 62, resetsAt: sternWeeklyReset, active: true,
                                        observedAt: sternObserved, source: .cache)])
        return ["default": defaultReading, sternKey: sternReading]
    }

    // MARK: Keys

    private static func keys(_ suite: TestSuite) {
        suite.expect(ClaudeAccountKey.key(forFolder: "") == "default", "the default account's key is \"default\"")
        suite.expect(ClaudeAccountKey.key(forFolder: stern) == "575e0284",
                     "a folder's key is Claude Code's keychain suffix for it (sha256 of the exact string)")
        suite.expect(ClaudeAccountKey.key(forFolder: "/tmp/caf\u{E9}") == ClaudeAccountKey.key(forFolder: "/tmp/cafe\u{301}"),
                     "the key hashes the folder in NFC")
        suite.expect(ClaudeAccountKey.key(forFolder: stern) != ClaudeAccountKey.key(forFolder: stern + "/"),
                     "another spelling of a folder is another key, as it is another keychain item")
        suite.expect(ClaudeAccountKey.folder(environment: [:]) == ""
                     && ClaudeAccountKey.folder(environment: ["CLAUDE_CONFIG_DIR": ""]) == ""
                     && ClaudeAccountKey.folder(environment: ["CLAUDE_CONFIG_DIR": stern]) == stern,
                     "a session's folder is its exact CLAUDE_CONFIG_DIR, empty when unset")
        suite.expect(ClaudeAccount(label: "x", folder: stern).id == "575e0284" && ClaudeAccount(label: "y", folder: "").id == "default",
                     "an account's id is its key")
    }

    // MARK: Launch environment

    private static func launchEnvironment(_ suite: TestSuite) {
        let base = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/Users/elliotgrayco/.claude",
                    "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/elsewhere", "HOME": "/Users/elliotgrayco"]
        let defaults = ClaudeLaunchEnvironment.environment(forFolder: "", base: base)
        suite.expect(defaults["CLAUDE_CONFIG_DIR"] == nil,
                     "the default account launches with CLAUDE_CONFIG_DIR removed, never set to ~/.claude")
        suite.expect(defaults["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil && defaults["PATH"] == "/usr/bin:/bin",
                     "CLAUDE_SECURESTORAGE_CONFIG_DIR is removed and the rest is kept")
        let other = ClaudeLaunchEnvironment.environment(forFolder: stern, base: base)
        suite.expect(other["CLAUDE_CONFIG_DIR"] == stern && other["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil,
                     "another account gets its exact folder string and no secure-storage override")
        for account in todaysAccounts() {
            let environment = ClaudeLaunchEnvironment.environment(for: account, base: base)
            suite.expect(environment["CLAUDE_CONFIG_DIR"] != "/Users/elliotgrayco/.claude"
                         && environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil,
                         "\(account.label) never launches on an explicit ~/.claude")
        }
        suite.expect(ClaudeLaunchEnvironment.commandLine(forFolder: "", arguments: ["--resume", "abc", "--fork-session"])
                     == "env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CONFIG_DIR claude --resume abc --fork-session",
                     "the default account's command line removes both variables")
        suite.expect(ClaudeLaunchEnvironment.commandLine(forFolder: "/Users/x/My Claude", arguments: ["it's"])
                     == "env -u CLAUDE_SECURESTORAGE_CONFIG_DIR CLAUDE_CONFIG_DIR='/Users/x/My Claude' claude 'it'\\''s'",
                     "another account's command line quotes the folder and arguments")
        let home = "/Users/elliotgrayco"
        suite.expect(ClaudeLaunchEnvironment.folderProblem("/Users/elliotgrayco/.claude", home: home) == .defaultFolderSpelledOut
                     && ClaudeLaunchEnvironment.folderProblem("/Users/elliotgrayco/./.claude", home: home) == .defaultFolderSpelledOut,
                     "~/.claude spelled out is refused as an account folder")
        suite.expect(ClaudeLaunchEnvironment.folderProblem(stern, home: home) == nil
                     && ClaudeLaunchEnvironment.folderProblem("", home: home) == nil,
                     "the default account and a folder of its own are fine")
        suite.expect(ClaudeLaunchEnvironment.folderProblem(stern + "/", home: home) == .trailingSlash
                     && ClaudeLaunchEnvironment.folderProblem(".claude-x", home: home) == .relative
                     && ClaudeLaunchEnvironment.folderProblem(home, home: home) == .notAFolderOfItsOwn,
                     "spellings that select another sign-in or no folder are refused")
    }

    // MARK: Decoding

    private static func dates(_ suite: TestSuite) {
        let reset = sternWeeklyReset.timeIntervalSince1970
        suite.expectClose(ClaudeDate.parse("2026-11-15T14:00:00Z")?.timeIntervalSince1970 ?? 0, reset, "a Z date")
        suite.expectClose(ClaudeDate.parse("2026-11-15T14:00:00+00:00")?.timeIntervalSince1970 ?? 0, reset, "an offset date")
        suite.expectClose(ClaudeDate.parse("2026-11-15T14:00:00.469636+00:00")?.timeIntervalSince1970 ?? 0, reset + 0.469636,
                          "a date with microseconds", tol: 0.000_01)
        suite.expectClose(ClaudeJSON.date(NSNumber(value: reset))?.timeIntervalSince1970 ?? 0, reset, "epoch seconds")
        suite.expectClose(ClaudeJSON.date(NSNumber(value: reset * 1_000))?.timeIntervalSince1970 ?? 0, reset, "epoch milliseconds")
        suite.expect(ClaudeDate.parse("soon") == nil && ClaudeJSON.date(NSNumber(value: true)) == nil, "not dates")
        suite.expect(ClaudeJSON.date(NSNumber(value: 1e300)) == nil && ClaudeJSON.date(NSNumber(value: 86_400)) == nil
                     && ClaudeJSON.date("9999-01-01T00:00:00Z") == nil && ClaudeDate.epoch(.infinity) == nil,
                     "times outside 2000...2200 are not taken")
        suite.expect(ClaudeJSON.percent(NSNumber(value: 1e300)) == 1_000 && ClaudeJSON.percent(NSNumber(value: -5)) == 0
                     && ClaudeJSON.percent(NSNumber(value: 101.5)) == 101.5, "percentages are held to 0...1000")
        suite.expect(ClaudeLiveFile.wholePercent(1e300) == 1_000_000 && ClaudeLiveFile.wholePercent(.nan) == 0
                     && ClaudeLiveFile.wholeSecond(Date(timeIntervalSince1970: 1e300)) == nil
                     && ClaudeLiveFile.wholeSecond(sternWeeklyReset) == 1_794_751_200,
                     "whole numbers never trap on a number out of range")
        suite.expect(ClaudeDate.format(sternWeeklyReset.addingTimeInterval(0.4)) == "2026-11-15T14:00:00Z",
                     "Brim writes whole-second UTC dates")
    }

    private static func configDecoding(_ suite: TestSuite) {
        guard let snapshot = ClaudeUsageDecoding.snapshot(configData: Data(config().utf8)) else {
            suite.expect(false, "today's .claude.json shape decodes")
            return
        }
        suite.expect(snapshot.signedIn && snapshot.identity?.accountUuid == sternUuid
                     && snapshot.identity?.email == "person@example.com" && snapshot.identity?.plan == "Max 20x",
                     "oauthAccount gives the identity and the plan")
        suite.expect(snapshot.usageStatus == .accepted && snapshot.usage?.fetchedAtMs == 1_794_510_510_573,
                     "a cache of the signed-in account is accepted")
        let reading = snapshot.usage?.reading
        suite.expect(reading?.fiveHour == nil, "five_hour null is no running 5-hour window")
        suite.expect(reading?.sevenDay?.utilization == 39 && reading?.sevenDay?.source == .cache
                     && reading?.sevenDay?.observedAt == snapshot.usage?.fetchedAt,
                     "seven_day is the weekly window, observed when Claude Code fetched it")
        suite.expectClose(reading?.sevenDay?.resetsAt?.timeIntervalSince1970 ?? 0, sternWeeklyReset.timeIntervalSince1970 + 0.469636,
                          "the weekly renewal keeps its fraction", tol: 0.000_01)
        let fable = reading?.scopedWindow(model: "fable")
        suite.expect(fable?.utilization == 62 && fable?.active == true && reading?.scoped.count == 1,
                     "limits[] weekly_scoped gives the Fable window")
        suite.expect(reading?.scopedReportedAt == snapshot.usage?.fetchedAt,
                     "limits[] is a full report of the scoped windows, as of the fetch")
        suite.expect(snapshot.usage?.extraUsage == ClaudeExtraUsage(isEnabled: false, monthlyLimit: 117_500, usedCredits: 1_966,
                                                                    utilization: 1.6731914893617021, currency: "USD",
                                                                    disabledReason: "out_of_credits"),
                     "extra_usage decodes")

        let mismatch = ClaudeUsageDecoding.snapshot(configData: Data(config(cacheUuid: defaultUuid).utf8))
        suite.expect(mismatch?.usageStatus == .accountMismatch && mismatch?.usage == nil && mismatch?.identity?.accountUuid == sternUuid,
                     "a cache whose accountUuid is not oauthAccount's is rejected")
        let unowned = ClaudeUsageDecoding.snapshot(configData: Data(config(cacheUuid: nil).utf8))
        suite.expect(unowned?.usageStatus == .accountMismatch && unowned?.usage == nil,
                     "a cache without an accountUuid cannot be checked and is rejected")
        let signedOut = ClaudeUsageDecoding.snapshot(configData: Data(#"{"cachedUsageUtilization":{"fetchedAtMs":5,"accountUuid":"u","utilization":{}}}"#.utf8))
        suite.expect(signedOut?.signedIn == false && signedOut?.usageStatus == .accountMismatch,
                     "a folder without oauthAccount is signed out and its cache unused")
        let none = ClaudeUsageDecoding.snapshot(configData: Data(#"{"oauthAccount":{"accountUuid":"u"}}"#.utf8))
        suite.expect(none?.usageStatus == .missing && none?.signedIn == true, "no cache is missing usage")
        suite.expect(ClaudeUsageDecoding.snapshot(configData: Data("[1]".utf8)) == nil
                     && ClaudeUsageDecoding.snapshot(configData: Data("{".utf8)) == nil, "not a JSON object")

        // The file is rewritten constantly for other keys: only a larger
        // fetchedAtMs is news.
        let rewritten = ClaudeUsageDecoding.snapshot(configData: Data(config(startups: 8).utf8))
        let previous = snapshot.usage?.fetchedAtMs
        suite.expect(rewritten.map { !ClaudeUsageDecoding.isNewer($0, than: previous) } == true,
                     "same fetchedAtMs => no change, whatever else the file says")
        let fetchedAgain = ClaudeUsageDecoding.snapshot(configData: Data(config(fetchedAtMs: 1_794_510_600_000).utf8))
        suite.expect(fetchedAgain.map { ClaudeUsageDecoding.isNewer($0, than: previous) } == true
                     && ClaudeUsageDecoding.isNewer(snapshot, than: nil),
                     "a larger fetchedAtMs, or the first one, is news")
        let older = ClaudeUsageDecoding.snapshot(configData: Data(config(fetchedAtMs: 1_794_500_000_000).utf8))
        suite.expect(older.map { !ClaudeUsageDecoding.isNewer($0, than: previous) } == true
                     && mismatch.map { !ClaudeUsageDecoding.isNewer($0, than: nil) } == true,
                     "an older cache, or one of another account, is not news")

        suite.expect(ClaudeUsageDecoding.planLabel(organizationType: "claude_max", rateLimitTier: "default_claude_max_5x", planDisplayName: nil) == "Max 5x"
                     && ClaudeUsageDecoding.planLabel(organizationType: "claude_pro", rateLimitTier: nil, planDisplayName: "Pro plan") == "Pro"
                     && ClaudeUsageDecoding.planLabel(organizationType: "other", rateLimitTier: nil, planDisplayName: "Ultra") == "Ultra",
                     "plan labels")
        suite.expect(ClaudeUsageDecoding.configFile(forFolder: "", home: "/Users/x") == "/Users/x/.claude.json"
                     && ClaudeUsageDecoding.configFile(forFolder: stern, home: "/Users/x") == stern + "/.claude.json",
                     "the default account's config is ~/.claude.json, outside ~/.claude")
    }

    private static func getUsageDecoding(_ suite: TestSuite) {
        let response = object("""
            {"subscription_type":"max","rate_limits_available":true,
             "rate_limits":{"five_hour":{"utilization":12,"resets_at":"2026-11-12T23:00:00Z"},
              "seven_day":{"utilization":39,"resets_at":"2026-11-15T14:00:00.469636+00:00"},
              "seven_day_opus":null,"seven_day_sonnet":{"utilization":4,"resets_at":null},
              "model_scoped":[{"display_name":"Fable","utilization":62,"resets_at":"2026-11-15T14:00:00.469819Z"}],
              "extra_usage":{"is_enabled":false}}}
            """)
        let reading = ClaudeUsageDecoding.reading(getUsage: response, observedAt: now)
        suite.expect(reading?.fiveHour?.utilization == 12 && reading?.fiveHour?.source == .check
                     && reading?.sevenDay?.utilization == 39 && reading?.sevenDay?.observedAt == now,
                     "get_usage's named windows decode as a check")
        suite.expect(reading?.scopedWindow(model: "Fable")?.utilization == 62 && reading?.scopedWindow(model: "Sonnet")?.utilization == 4
                     && reading?.scopedWindow(model: "Opus") == nil,
                     "model_scoped and the named per-model windows become scoped windows")
        suite.expect(reading?.scopedReportedAt == nil,
                     "model_scoped alone (a filtered projection of limits[]) is not a full report")
        let fromLimits = object("""
            {"rate_limits_available":true,"rate_limits":{"limits":[
              {"kind":"session","percent":40,"resets_at":"2026-11-12T22:00:00Z","is_active":true},
              {"kind":"weekly_all","percent":50,"resets_at":"2026-11-15T14:00:00Z"},
              {"kind":"weekly_scoped","percent":70,"resets_at":"2026-11-15T14:00:00Z",
               "scope":{"model":{"display_name":"Fable"}},"is_active":true},
              {"kind":"something_new","percent":99}]}}
            """)
        let limits = ClaudeUsageDecoding.reading(getUsage: fromLimits, observedAt: now)
        suite.expect(limits?.fiveHour?.utilization == 40 && limits?.sevenDay?.utilization == 50
                     && limits?.scopedWindow(model: "Fable")?.utilization == 70 && limits?.scoped.count == 1
                     && limits?.scopedReportedAt == now,
                     "limits[] alone gives the session, weekly and scoped windows; unknown kinds are skipped")
        let huge = ClaudeUsageDecoding.reading(utilization: object(#"{"seven_day":{"utilization":1e300,"resets_at":1e300}}"#),
                                               observedAt: now, source: .check)
        suite.expect(huge?.sevenDay?.utilization == 1_000 && huge?.sevenDay?.resetsAt == nil,
                     "an absurd percentage is held to 1000 and an absurd time dropped")
        suite.expect(ClaudeUsageDecoding.reading(getUsage: ["rate_limits_available": false, "rate_limits": NSNull()], observedAt: now) == nil
                     && ClaudeUsageDecoding.reading(getUsage: ["rate_limits_available": true, "rate_limits": [String: Any]()], observedAt: now) == nil,
                     "no plan limits, no reading")
        let boolean = ClaudeUsageDecoding.reading(utilization: object(#"{"seven_day":{"utilization":true}}"#), observedAt: now, source: .check)
        suite.expect(boolean == nil, "a JSON boolean is not a percentage")
    }

    private static func statusLineDecoding(_ suite: TestSuite) {
        let full = """
            {"session_id":"11111111-1111-4111-8111-111111111111","transcript_path":"/tmp/t.jsonl","cwd":"/Users/x/Code/App",
             "model":{"id":"claude-fable-5","display_name":"Fable"},
             "workspace":{"current_dir":"/Users/x/Code/App/sub","project_dir":"/Users/x/Code/App"},
             "version":"2.1.322","context_window":{"used_percentage":12},
             "rate_limits":{"five_hour":{"used_percentage":12.4,"resets_at":1794522000},
                            "seven_day":{"used_percentage":39,"resets_at":1794751200}}}
            """
        let input = ClaudeUsageDecoding.statusLineInput(Data(full.utf8))
        suite.expect(input?.sessionId == "11111111-1111-4111-8111-111111111111" && input?.cwd == "/Users/x/Code/App"
                     && input?.projectDirectory == "/Users/x/Code/App" && input?.modelId == "claude-fable-5"
                     && input?.modelDisplayName == "Fable", "the status line's session, folder and model")
        suite.expect(input?.fiveHour == ClaudeStatusLineInput.Window(usedPercentage: 12.4, resetsAt: Date(timeIntervalSince1970: 1_794_522_000))
                     && input?.sevenDay?.resetsAt == sternWeeklyReset,
                     "rate_limits give percentages and epoch-second renewals, not the context window's percentage")
        let bare = ClaudeUsageDecoding.statusLineInput(Data(#"{"workspace":{"current_dir":"/w"}}"#.utf8))
        suite.expect(bare?.cwd == "/w" && bare?.hasRateLimits == false && bare?.sessionId == nil,
                     "missing fields are tolerated; workspace.current_dir stands in for cwd")
        suite.expect(ClaudeUsageDecoding.statusLineInput(Data("not json".utf8)) == nil
                     && ClaudeUsageDecoding.statusLineInput(Data()) == nil, "garbage is no input")
    }

    // MARK: Ranking

    private static func ranking(_ suite: TestSuite) {
        let accounts = todaysAccounts()
        let readings = todaysReadings()
        let fable = ClaudeAccountRanking.rank(accounts, readings: readings, model: "fable", now: now, launchable: anyFolder)
        suite.expect(fable.map(\.account.label) == ["elliotgrayco.me", "rhodesconsulting"],
                     "today: elliotgrayco.me (renews Sunday) ranks before rhodesconsulting (renews Tuesday)")
        suite.expect(fable.first?.status == .usable && fable.first?.binding?.kind == .scoped("Fable"),
                     "for Fable work the Fable weekly window binds elliotgrayco.me")
        suite.expectClose(fable.first?.bindingHeadroom ?? -1, 38, "elliotgrayco.me has 38 % of its Fable allowance left")
        suite.expect(fable.last?.binding?.kind == .weekly, "rhodesconsulting's binding window is its week")
        suite.expectClose(fable.last?.bindingHeadroom ?? -1, 99, "rhodesconsulting has 99 % of its week left")
        suite.expect(fable.first?.weeklyResetsAt == sternWeeklyReset && fable.first?.fiveHourHeadroom == 100,
                     "the weekly renewal orders; no 5-hour window is all headroom")

        for model in [nil, "opus"] as [String?] {
            let other = ClaudeAccountRanking.rank(accounts, readings: readings, model: model, now: now, launchable: anyFolder)
            suite.expect(other.first?.account.label == "elliotgrayco.me" && other.first?.binding?.kind == .weekly
                         && other.first?.bindingHeadroom == 61,
                         "without Fable (\(model ?? "no model")) the week binds elliotgrayco.me at 61 % left")
            suite.expect(other.first?.windows.first { $0.kind == .scoped("Fable") }?.applies == false,
                         "the Fable window is shown but does not count for \(model ?? "no model")")
            suite.expect(other.first?.windows.first { $0.kind == .scoped("Fable") }?.serverActive == true
                         && other.last?.windows.first { $0.kind == .scoped("Fable") }?.serverActive == false,
                         "the server marks elliotgrayco.me's Fable window active (the panel shows it), not rhodesconsulting's")
        }

        // Fable nearly spent: Fable work goes elsewhere, other work does not.
        var spent = readings
        spent["575e0284"]?.scoped[0].utilization = 98
        let spentFable = ClaudeAccountRanking.rank(accounts, readings: spent, model: "claude-fable-5", now: now, launchable: anyFolder)
        suite.expect(spentFable.map(\.account.label) == ["rhodesconsulting", "elliotgrayco.me"]
                     && spentFable.last?.status == .limited(until: sternWeeklyReset),
                     "a scoped window at 98 % makes the account wait for its renewal, for that model only")
        suite.expect(ClaudeAccountRanking.rank(accounts, readings: spent, model: nil, now: now, launchable: anyFolder).first?.account.label == "elliotgrayco.me",
                     "for other models it still ranks first")

        // Over the 5-hour limit, by when each becomes usable; then unknown;
        // then signed out.
        let crowd = [ClaudeAccount(label: "late", folder: "/x/.claude-late"), ClaudeAccount(label: "spare", folder: "/x/.claude-spare"),
                     ClaudeAccount(label: "early", folder: "/x/.claude-early"), ClaudeAccount(label: "gone", folder: "/x/.claude-gone", signedIn: false),
                     ClaudeAccount(label: "free", folder: "/x/.claude-free")]
        func reading(fiveHour: Double, fiveHourReset: TimeInterval, weekly: Double = 10) -> ClaudeAccountReading {
            ClaudeAccountReading(fiveHour: ClaudeUsageWindow(utilization: fiveHour, resetsAt: now.addingTimeInterval(fiveHourReset),
                                                             observedAt: now, source: .live),
                                 sevenDay: ClaudeUsageWindow(utilization: weekly, resetsAt: now.addingTimeInterval(3 * 86_400),
                                                             observedAt: now, source: .live))
        }
        let crowdReadings: [String: ClaudeAccountReading] = [
            crowd[0].id: reading(fiveHour: 99, fiveHourReset: 4 * 3_600),
            crowd[2].id: reading(fiveHour: 95, fiveHourReset: 2 * 3_600),
            crowd[3].id: reading(fiveHour: 0, fiveHourReset: 3_600),
            crowd[4].id: reading(fiveHour: 94.9, fiveHourReset: 3_600),
        ]
        let ranked = ClaudeAccountRanking.rank(crowd, readings: crowdReadings, model: nil, now: now, launchable: anyFolder)
        suite.expect(ranked.map(\.account.label) == ["free", "early", "late", "spare", "gone"],
                     "usable, then over a limit by renewal, then unknown, then signed out: \(ranked.map(\.account.label))")
        suite.expect(ranked[1].status == .limited(until: now.addingTimeInterval(2 * 3_600)) && ranked[3].status == .unknown
                     && ranked[4].status == .signedOut, "each status is reported")
        let weeklyFull = ClaudeAccountRanking.assess(crowd[4], reading: reading(fiveHour: 0, fiveHourReset: 3_600, weekly: 98), model: nil, now: now)
        suite.expect(weeklyFull.status == .limited(until: now.addingTimeInterval(3 * 86_400)), "the week at 98 % is over the limit")

        // Equal renewals: more 5-hour headroom first.
        let twins = [ClaudeAccount(label: "busy", folder: "/x/.claude-busy"), ClaudeAccount(label: "calm", folder: "/x/.claude-calm")]
        let twinReadings = [twins[0].id: reading(fiveHour: 80, fiveHourReset: 3_600), twins[1].id: reading(fiveHour: 10, fiveHourReset: 3_600)]
        suite.expect(ClaudeAccountRanking.rank(twins, readings: twinReadings, model: nil, now: now, launchable: anyFolder).map(\.account.label) == ["calm", "busy"],
                     "on the same weekly renewal the account with more 5-hour headroom ranks first")

        // A window whose renewal passed counts as renewed at 0 %, estimated.
        let renewed = ClaudeAccountReading(
            fiveHour: ClaudeUsageWindow(utilization: 97, resetsAt: now.addingTimeInterval(-600), observedAt: now.addingTimeInterval(-3 * 3_600), source: .live),
            sevenDay: ClaudeUsageWindow(utilization: 99, resetsAt: now.addingTimeInterval(-3_600), observedAt: now.addingTimeInterval(-2 * 86_400), source: .cache))
        let rolled = ClaudeAccountRanking.assess(twins[0], reading: renewed, model: nil, now: now)
        let week = rolled.windows.first { $0.kind == .weekly }
        suite.expect(rolled.status == .usable && rolled.estimated && week?.utilization == 0 && week?.estimated == true,
                     "renewed windows are usable again, flagged as estimated")
        let fiveHour = rolled.windows.first { $0.kind == .fiveHour }
        suite.expect(week?.resetsAt == now.addingTimeInterval(-3_600 + 7 * 86_400),
                     "the next weekly renewal is estimated a week on")
        suite.expect(fiveHour?.utilization == 0 && fiveHour?.estimated == true && fiveHour?.resetsAt == nil
                     && rolled.fiveHourHeadroom == 100,
                     "a 5-hour window that ran out shows 0 % and no renewal: none runs until the next request")

        suite.expect(ClaudeAccountRanking.scope("Fable", appliesTo: "fable") && ClaudeAccountRanking.scope("Fable", appliesTo: "claude-fable-5")
                     && ClaudeAccountRanking.scope("Fable", appliesTo: "Fable 5") && ClaudeAccountRanking.scope("Sonnet 4.5", appliesTo: "claude-sonnet-4-5"),
                     "a scoped window applies to its model's alias, id and display name")
        suite.expect(!ClaudeAccountRanking.scope("Fable", appliesTo: "opus") && !ClaudeAccountRanking.scope("Fable", appliesTo: nil)
                     && !ClaudeAccountRanking.scope("Fable", appliesTo: "fabler"), "and to nothing else")

        let settings = Data(#"{"model":"opus","env":{}}"#.utf8)
        suite.expect(ClaudeAccountRanking.modelHint(explicit: "fable", sharedSettings: settings) == "fable"
                     && ClaudeAccountRanking.modelHint(explicit: nil, sharedSettings: settings) == "opus"
                     && ClaudeAccountRanking.modelHint(explicit: "  ", sharedSettings: settings) == "opus"
                     && ClaudeAccountRanking.modelHint(explicit: nil, sharedSettings: Data("{}".utf8)) == nil
                     && ClaudeAccountRanking.modelHint(explicit: nil, sharedSettings: nil) == nil,
                     "the model hint: --model, else the shared settings' model, else none")
    }

    private static func merging(_ suite: TestSuite) {
        let early = now.addingTimeInterval(-600)
        let cache = ClaudeAccountReading(
            fiveHour: ClaudeUsageWindow(utilization: 50, resetsAt: now.addingTimeInterval(3_600), observedAt: early, source: .cache),
            sevenDay: ClaudeUsageWindow(utilization: 39, resetsAt: sternWeeklyReset, observedAt: early, source: .cache),
            scoped: [ClaudeScopedWindow(model: "Fable", utilization: 62, resetsAt: sternWeeklyReset, active: true, observedAt: early, source: .cache)])
        let live = ClaudeAccountReading(
            fiveHour: ClaudeUsageWindow(utilization: 60, resetsAt: now.addingTimeInterval(3_600), observedAt: now, source: .live))
        let merged = ClaudeAccountRanking.merge([cache, live])
        suite.expect(merged?.fiveHour?.utilization == 60 && merged?.fiveHour?.source == .live
                     && merged?.sevenDay?.utilization == 39 && merged?.sevenDay?.source == .cache
                     && merged?.scoped.first?.source == .cache,
                     "per window the newest observation wins and keeps its source; a missing window overrides nothing")
        suite.expect(merged?.observedAt == now && merged?.source == .live, "the reading is as new as its newest window")
        let stale = ClaudeAccountReading(
            sevenDay: ClaudeUsageWindow(utilization: 10, resetsAt: sternWeeklyReset, observedAt: now.addingTimeInterval(-86_400), source: .live),
            scoped: [ClaudeScopedWindow(model: "fable", utilization: 1, resetsAt: nil, active: nil, observedAt: now, source: .check)])
        let mergedStale = ClaudeAccountRanking.merge([cache, stale])
        suite.expect(mergedStale?.sevenDay?.utilization == 39 && mergedStale?.scoped.count == 1
                     && mergedStale?.scoped.first?.utilization == 1,
                     "an older window loses; scoped windows merge by model regardless of case")
        suite.expect(ClaudeAccountRanking.merge([nil, ClaudeAccountReading()]) == nil, "nothing merges to nothing")
        suite.expect(ClaudeAccountRanking.needsRefresh(nil, model: nil, now: now)
                     && ClaudeAccountRanking.needsRefresh(cache, model: nil, now: now.addingTimeInterval(16 * 60))
                     && !ClaudeAccountRanking.needsRefresh(cache, model: nil, now: now),
                     "a reading older than 15 minutes asks for a check")

        // The real failure: a session keeps the weekly window live while the
        // Fable window (the binding one, never in a status line) is days old.
        let days = now.addingTimeInterval(-3 * 86_400)
        let busy = ClaudeAccountRanking.merge([
            ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 39, resetsAt: sternWeeklyReset, observedAt: days, source: .cache),
                                 scoped: [ClaudeScopedWindow(model: "Fable", utilization: 62, resetsAt: sternWeeklyReset, active: false,
                                                             observedAt: days, source: .cache)]),
            ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 46, resetsAt: sternWeeklyReset, observedAt: now, source: .live))])
        suite.expect(busy?.observedAt == now && ClaudeAccountRanking.needsRefresh(busy, model: "fable", now: now),
                     "a stale scoped window for the model being run asks for a check, however new the weekly one")
        suite.expect(!ClaudeAccountRanking.needsRefresh(busy, model: "opus", now: now),
                     "a scoped window for another model, not active, does not")
        var active = busy
        active?.scoped[0].active = true
        suite.expect(ClaudeAccountRanking.needsRefresh(active, model: "opus", now: now),
                     "one the server marks active does, whatever the model")
        suite.expect(ClaudeAccountRanking.needsRefresh(live, model: nil, now: now),
                     "no weekly window is no reading to rank by")

        // A full report drops the scoped windows it no longer lists.
        var report = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 40, resetsAt: sternWeeklyReset, observedAt: now, source: .check))
        report.scopedReportedAt = now
        let dropped = ClaudeAccountRanking.merge([cache, report])
        suite.expect(dropped?.scoped.isEmpty == true && dropped?.scopedReportedAt == now,
                     "a scoped window an newer full report does not list is gone")
        // The real failure: a shared sign-in merges its folders in launch
        // order, so the newer report (the folder checks run in) comes first
        // and another folder's older reading still holds the dropped window.
        suite.expect(ClaudeAccountRanking.merge([report, cache])?.scoped.isEmpty == true,
                     "a newer report drops the window wherever it sits in the list")
        var older = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 30, resetsAt: sternWeeklyReset,
                                                                     observedAt: early.addingTimeInterval(-60), source: .check))
        older.scopedReportedAt = early.addingTimeInterval(-60)
        suite.expect(ClaudeAccountRanking.merge([cache, live])?.scoped.count == 1
                     && ClaudeAccountRanking.merge([cache, older])?.scoped.count == 1
                     && ClaudeAccountRanking.merge([older, cache])?.scoped.count == 1,
                     "a status line, or an older report, drops nothing, in either order")
        var again = report
        again.scoped = [ClaudeScopedWindow(model: "FABLE", utilization: 5, resetsAt: nil, active: nil, observedAt: now, source: .check)]
        suite.expect(ClaudeAccountRanking.merge([cache, report, again])?.scoped.map(\.utilization) == [5]
                     && ClaudeAccountRanking.merge([again, report, cache])?.scoped.map(\.utilization) == [5],
                     "a window that comes back is listed once")
        let lists = [[cache, report, live, older], [older, live, report, cache], [live, cache, older, report]]
        let results = lists.map { ClaudeAccountRanking.merge($0) }
        suite.expect(results.allSatisfy { $0 == results[0] } && results[0]?.scoped.isEmpty == true,
                     "the merge does not depend on the order of its feeds")
    }

    // MARK: State files

    private static func accountsFile(_ suite: TestSuite, _ scratch: Scratch) {
        let paths = ClaudeAccountsPaths(stateDirectory: scratch.folder("state-file") + "/brim/claude")
        let whole = ClaudeAccountReading(
            fiveHour: ClaudeUsageWindow(utilization: 12, resetsAt: Date(timeIntervalSince1970: 1_794_522_000), observedAt: now, source: .live),
            sevenDay: ClaudeUsageWindow(utilization: 39, resetsAt: sternWeeklyReset, observedAt: now.addingTimeInterval(-60), source: .cache),
            scoped: [ClaudeScopedWindow(model: "Fable", utilization: 62, resetsAt: sternWeeklyReset, active: true, observedAt: now, source: .check)],
            scopedReportedAt: now)
        let file = ClaudeAccountsFile(accounts: todaysAccounts(), newSessions: .account("575e0284"), readings: ["575e0284": whole])
        do {
            suite.expect(try file.save(paths), "accounts.json is written")
            suite.expect(try !file.save(paths), "an unchanged accounts.json is not written again")
        } catch {
            suite.expect(false, "accounts.json saves: \(error)")
        }
        suite.expect(ClaudeAccountsFile.load(paths) == file, "accounts.json reads back as written")
        suite.expect(mode(paths.accountsFile) == 0o600 && mode(paths.stateDirectory) == 0o700
                     && mode((paths.stateDirectory as NSString).deletingLastPathComponent) == 0o700,
                     "the state folder is 0700 and accounts.json 0600")
        let text = (try? String(contentsOfFile: paths.accountsFile, encoding: .utf8)) ?? ""
        suite.expect(text.contains("\"newSessions\" : \"575e0284\"") && text.contains("\"id\" : \"default\"")
                     && text.contains("\"folder\" : \"\"") && text.contains("\"resets_at\" : \"2026-11-15T14:00:00Z\""),
                     "the contract: newSessions, ids, the default folder \"\", ISO dates")
        suite.expect(ClaudeAccountsFile.load(paths)?.readings["575e0284"]?.scopedReportedAt == now
                     && text.contains("\"scoped_reported_at\""),
                     "a full report's time is saved, so a merge from accounts.json still knows what it dropped")

        let foreign = """
            {"version":1,"newSessions":"auto",
             "accounts":[{"id":"wrong","label":"Work","folder":"/x/.claude-work"}],
             "readings":{"\(ClaudeAccountKey.key(forFolder: "/x/.claude-work"))":
               {"observed_at":"2026-11-12T20:00:00Z","source":"cache","seven_day":{"utilization":5},
                "scoped":[{"model":"Fable","utilization":7}]}}}
            """
        let decoded = try? ClaudeJSON.decoder().decode(ClaudeAccountsFile.self, from: Data(foreign.utf8))
        let workId = ClaudeAccountKey.key(forFolder: "/x/.claude-work")
        suite.expect(decoded?.accounts.first?.id == workId && decoded?.newSessions == .auto,
                     "an account's id is recomputed from its folder")
        suite.expect(decoded?.readings[workId]?.sevenDay?.observedAt == ClaudeDate.parse("2026-11-12T20:00:00Z")
                     && decoded?.readings[workId]?.scoped.first?.source == .cache,
                     "windows without their own observation take the reading's")
        func named(_ name: String) -> ClaudeAccount? {
            if case .one(let account) = decoded?.match(name) { return account }
            return nil
        }
        suite.expect(named("work")?.folder == "/x/.claude-work" && named(workId) != nil
                     && named("/x/.claude-work") != nil && named("nobody") == nil,
                     "accounts are found by label, id or folder")

        let customPaths = ClaudeAccountsPaths(environment: ["BRIM_CLAUDE_STATE_DIR": "/tmp/state"], home: "/Users/x")
        suite.expect(customPaths.stateDirectory == "/tmp/state"
                     && ClaudeAccountsPaths(environment: [:], home: "/Users/x").stateDirectory == "/Users/x/.config/brim/claude"
                     && ClaudeAccountsPaths(environment: ["BRIM_CLAUDE_STATE_DIR": "relative"], home: "/Users/x").stateDirectory
                        == "/Users/x/.config/brim/claude",
                     "the state folder: BRIM_CLAUDE_STATE_DIR when absolute, else ~/.config/brim/claude")
        suite.expect(ClaudeAccountsPaths.variantFolder == "brim" && customPaths.sessionsDirectory == "/tmp/state/sessions"
                     && customPaths.sessionFile("abc") == "/tmp/state/sessions/abc.json",
                     "a build without the Developer flag keeps its state in ~/.config/brim (the Developer build: brim-dev)")
        suite.expect(ClaudeHome.path(environment: ["HOME": "/Users/x/"]) == "/Users/x", "home from HOME")
    }

    private static func makeContext(_ scratch: Scratch, _ name: String, environment: [String: String] = [:],
                                at time: Date = now, cwd: String = "/tmp") -> ClaudeHelperContext {
        let home = scratch.folder(name + "-home")
        var context = ClaudeHelperContext(environment: environment.merging(["HOME": home]) { a, _ in a }, home: home,
                                          paths: ClaudeAccountsPaths(stateDirectory: home + "/.config/brim/claude"), now: time,
                                          currentDirectory: cwd, isAlive: ClaudeSessionIndex.processIsAlive)
        // What the sync sends to the Trash stays in the scratch folder.
        let trash = scratch.folder(name + "-trash")
        context.trash = { path in
            try FileManager.default.moveItem(atPath: path, toPath: trash + "/" + UUID().uuidString + "-" + (path as NSString).lastPathComponent)
        }
        return context
    }

    // MARK: statusline

    private static func statusline(_ suite: TestSuite, _ scratch: Scratch) {
        var context = makeContext(scratch, "statusline", environment: ["CLAUDE_CONFIG_DIR": stern, "NO_COLOR": "1"])
        let file = ClaudeAccountsFile(accounts: todaysAccounts(), readings: todaysReadings())
        _ = try? file.save(context.paths)
        func input(fiveHour: Double = 12.4, session: String = "11111111-1111-4111-8111-111111111111") -> Data {
            Data("""
                {"session_id":"\(session)","cwd":"/Users/x/Code/App","model":{"id":"claude-fable-5","display_name":"Fable"},
                 "rate_limits":{"five_hour":{"used_percentage":\(fiveHour),"resets_at":\(Int(now.timeIntervalSince1970) + 7_800)},
                                "seven_day":{"used_percentage":39,"resets_at":1794751200}}}
                """.utf8)
        }
        let weekday = { () -> String in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE"
            return formatter.string(from: sternWeeklyReset)
        }()
        let first = ClaudeHelper.statusline(input: input(), context: context)
        suite.expect(first.result == .ok("elliotgrayco.me | 5h 12% 2h10m | wk 39% \(weekday) | Fable 62%"),
                     "the status line shows the account, both windows with their renewals and the model's scoped window: \(first.result.stdout)")
        suite.expect(first.wroteLiveFile, "the first render records the session")
        let livePath = context.paths.liveFile(key: "575e0284")
        let live = ClaudeLiveFile.load(livePath)
        suite.expect(live?.folder == stern && live?.sessionId == "11111111-1111-4111-8111-111111111111"
                     && live?.cwd == "/Users/x/Code/App" && live?.model?.id == "claude-fable-5"
                     && live?.fiveHour?.usedPercentage == 12.4 && live?.sevenDay?.resetsAt == sternWeeklyReset
                     && live?.observedAt == now, "live/<key>.json holds what the status line saw")
        suite.expect(mode(livePath) == 0o600 && mode(context.paths.liveDirectory) == 0o700, "the live file is 0600 in a 0700 folder")
        suite.expect(live?.reading?.fiveHour?.source == .live && live?.reading?.sevenDay?.utilization == 39,
                     "a live file is a reading from the live source")
        suite.expect(ClaudeSessionOwners.folder(sessionId: "11111111-1111-4111-8111-111111111111", paths: context.paths) == stern,
                     "the status line records which account the session runs on")
        let bytes = FileManager.default.contents(atPath: livePath)

        context.now = now.addingTimeInterval(60)
        let same = ClaudeHelper.statusline(input: input(), context: context)
        let nearly = ClaudeHelper.statusline(input: input(fiveHour: 12.3), context: context)
        suite.expect(!same.wroteLiveFile && !nearly.wroteLiveFile && FileManager.default.contents(atPath: livePath) == bytes,
                     "identical input, or the same whole percent, does not rewrite the live file")
        suite.expect(ClaudeHelper.statusline(input: input(fiveHour: 13), context: context).wroteLiveFile
                     && ClaudeHelper.statusline(input: input(fiveHour: 13, session: "22222222-2222-4222-8222-222222222222"), context: context).wroteLiveFile,
                     "a new whole percent or another session rewrites it")

        let firstRender = ClaudeHelper.statusline(input: Data(#"{"session_id":"33333333-3333-4333-8333-333333333333","model":{"id":"x"}}"#.utf8),
                                                  context: context)
        suite.expect(!firstRender.wroteLiveFile && ClaudeLiveFile.load(livePath)?.fiveHour != nil,
                     "a new session's first render, before any rate limits, keeps what the account's live file knew")
        let garbage = ClaudeHelper.statusline(input: Data("not json".utf8), context: context)
        suite.expect(garbage.result == .ok("elliotgrayco.me") && !garbage.wroteLiveFile,
                     "unreadable input still prints a minimal line and exits 0")
        let run = ClaudeHelper.run(["statusline"], input: { Data("{".utf8) }, context: context)
        suite.expect(run.status == 0 && run.stdout == "elliotgrayco.me\n", "the statusline subcommand never fails")

        var colored = context
        colored.environment["NO_COLOR"] = nil
        suite.expect(ClaudeHelper.statusline(input: input(), context: colored).result.stdout.contains("\u{1B}["),
                     "percentages are coloured unless NO_COLOR is set")
        suite.expect(!first.result.stdout.contains("\u{1B}"), "NO_COLOR prints no escape sequence")

        var defaultSession = context
        defaultSession.environment["CLAUDE_CONFIG_DIR"] = nil
        let byDefault = ClaudeHelper.statusline(input: input(), context: defaultSession)
        suite.expect(byDefault.result.stdout.hasPrefix("rhodesconsulting | 5h 12%") && !byDefault.result.stdout.contains("Fable 62%")
                     && ClaudeLiveFile.load(context.paths.liveFile(key: "default"))?.folder == "",
                     "a session without CLAUDE_CONFIG_DIR is the default account's")
        suite.expect(ClaudeSessionOwners.folder(sessionId: "11111111-1111-4111-8111-111111111111", paths: context.paths) == "",
                     "a session that runs on another account is recorded there")

        // The real failure: an idle session drawing again with older numbers
        // for the same window lowered a busier session's newer reading.
        let steady = makeContext(scratch, "statusline-steady", environment: ["NO_COLOR": "1"])
        func weekly(_ used: Double, session: String, resets: Int = 1_794_909_600) -> Data {
            Data(#"{"session_id":"\#(session)","rate_limits":{"seven_day":{"used_percentage":\#(used),"resets_at":\#(resets)}}}"#.utf8)
        }
        _ = ClaudeHelper.statusline(input: weekly(46.2, session: "s1"), context: steady)
        _ = ClaudeHelper.statusline(input: weekly(30, session: "s2"), context: steady)
        let steadyFile = ClaudeLiveFile.load(steady.paths.liveFile(key: "default"))
        suite.expect(steadyFile?.sevenDay?.usedPercentage == 46.2 && steadyFile?.sessionId == "s2",
                     "within one renewal the use recorded never goes down")
        _ = ClaudeHelper.statusline(input: weekly(5, session: "s2", resets: 1_795_514_400), context: steady)
        suite.expect(ClaudeLiveFile.load(steady.paths.liveFile(key: "default"))?.sevenDay?.usedPercentage == 5,
                     "a new window starts from its own number")

        // The real failure: numbers no Int holds trapped the status line.
        let absurd = ClaudeHelper.run(["statusline"], input: {
            Data(#"{"session_id":"s3","rate_limits":{"seven_day":{"used_percentage":1e300,"resets_at":1e300},"five_hour":{"used_percentage":-1e300}}}"#.utf8)
        }, context: steady)
        suite.expect(absurd.status == 0 && absurd.stdout == "default | 5h 0% | wk 1000%\n",
                     "absurd numbers print held to range and never stop the status line: \(absurd.stdout)")

        var unlisted = makeContext(scratch, "statusline-unlisted", environment: ["CLAUDE_CONFIG_DIR": stern, "NO_COLOR": "1"])
        unlisted.now = now
        suite.expect(ClaudeHelper.statusline(input: Data("{}".utf8), context: unlisted).result == .ok("stern")
                     && !FileManager.default.fileExists(atPath: unlisted.paths.liveDirectory),
                     "without accounts.json the label comes from the folder; input without rate limits records nothing")
        suite.expect(ClaudeHelper.displayLabel(ClaudeAccount(label: "evil\u{1B}[31m name", folder: ""), folder: "") == "evil[31m name",
                     "labels lose control characters before they reach the terminal")
    }

    // MARK: pick

    private static func pick(_ suite: TestSuite, _ scratch: Scratch) {
        let context = makeContext(scratch, "pick")
        suite.expect(ClaudeHelper.pick([], context: context) == .ok("")
                     && !FileManager.default.fileExists(atPath: context.paths.stateDirectory),
                     "without accounts.json new sessions use the default account and nothing is written")
        suite.expect(ClaudeHelper.pick(["--account", "default"], context: context) == .ok(""),
                     "the default account is known without accounts.json")
        write(context.sharedRoot + "/settings.json", #"{"model":"opus"}"#)
        // The second account's folder, as ~/.claude-stern is on this Mac.
        let work = context.home + "/.claude-stern"
        let workKey = ClaudeAccountKey.key(forFolder: work)
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)

        var file = ClaudeAccountsFile(accounts: todaysAccounts(folder: work), readings: todaysReadings(sternKey: workKey))
        _ = try? file.save(context.paths)
        let picked = ClaudeHelper.pick(["--cwd", "/tmp", "--model", "fable"], context: context)
        suite.expect(picked == .ok(work), "Auto picks elliotgrayco.me today")
        let requests = (try? FileManager.default.contentsOfDirectory(atPath: context.paths.requestsDirectory)) ?? []
        suite.expect(requests.count == 1 && requests.first?.hasSuffix("-" + workKey) == true,
                     "a reading older than 15 minutes asks the app for a check: \(requests)")
        _ = ClaudeHelper.pick([], context: context)
        suite.expect(((try? FileManager.default.contentsOfDirectory(atPath: context.paths.requestsDirectory)) ?? []).count == 1,
                     "one pending request per account is enough")

        // A newer live 5-hour reading over the limit outranks the cache.
        let liveFile = ClaudeLiveFile(observedAt: now, folder: work, sessionId: "s", cwd: nil, model: nil,
                                      fiveHour: .init(usedPercentage: 96, resetsAt: now.addingTimeInterval(3_600)), sevenDay: nil)
        try? context.paths.ensureDirectory(context.paths.liveDirectory)
        try? ClaudeFileIO.writeAtomically((try? ClaudeJSON.encoder().encode(liveFile)) ?? Data(),
                                          to: context.paths.liveFile(key: workKey))
        suite.expect(ClaudeHelper.pick([], context: context) == .ok(""),
                     "live status-line numbers merge in: elliotgrayco.me at 96 % of its 5 hours yields to the default account")
        try? FileManager.default.removeItem(atPath: context.paths.liveDirectory)

        file.newSessions = .account("default")
        _ = try? file.save(context.paths)
        suite.expect(ClaudeHelper.pick([], context: context) == .ok(""), "newSessions naming an account wins")
        file.newSessions = .account("gone")
        _ = try? file.save(context.paths)
        suite.expect(ClaudeHelper.pick(["--model", "fable"], context: context) == .ok(work), "an unknown newSessions id falls to Auto")

        suite.expect(ClaudeHelper.pick(["--account", "ELLIOTGRAYCO.ME"], context: context) == .ok(work)
                     && ClaudeHelper.pick(["--account=rhodesconsulting"], context: context) == .ok(""),
                     "--account names an account by label")
        suite.expect(ClaudeHelper.pick(["--account", "nobody"], context: context).status == 2
                     && ClaudeHelper.pick(["--frobnicate"], context: context).status == 1
                     && ClaudeHelper.pick(["--model"], context: context).status == 1,
                     "an unknown account or option fails")

        // Folders that would launch the wrong sign-in, or none, are never printed.
        let soonest = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 1, resetsAt: now.addingTimeInterval(3_600),
                                                                       observedAt: now, source: .cache))
        let spelledOut = ClaudeAccount(label: "explicit", folder: context.home + "/.claude", signedIn: true)
        let missing = ClaudeAccount(label: "missing", folder: context.home + "/.claude-missing", signedIn: true)
        var risky = ClaudeAccountsFile(accounts: [spelledOut, missing] + todaysAccounts(folder: work),
                                       readings: todaysReadings(sternKey: workKey))
        risky.readings[spelledOut.id] = soonest
        risky.readings[missing.id] = soonest
        _ = try? risky.save(context.paths)
        suite.expect(ClaudeHelper.pick(["--model", "fable"], context: context) == .ok(work),
                     "~/.claude spelled out and a missing folder are skipped even when they rank first")
        suite.expect(ClaudeHelper.pick(["--account", "explicit"], context: context).status == 2
                     && ClaudeHelper.pick(["--account", "missing"], context: context).status == 2,
                     "and refused when named")
        risky.newSessions = .account(spelledOut.id)
        _ = try? risky.save(context.paths)
        suite.expect(ClaudeHelper.pick(["--model", "fable"], context: context) == .ok(work),
                     "even newSessions cannot select them")
        suite.expect(ClaudeHelper.resolve(context: context).stdout.contains("PROBLEM:"), "resolve names the problem")
        suite.expect(ClaudeHelper.format(61) == "61" && ClaudeHelper.format(38.5) == "38.5"
                     && ClaudeHelper.format(0.04) == "0.0",
                     "resolve prints whole percents bare and others with one decimal point, whatever the Mac's region")

        var fresh = todaysReadings(sternKey: workKey, sternObserved: now.addingTimeInterval(-300))
        fresh["default"] = nil
        let freshContext = makeContext(scratch, "pick-fresh")
        let freshWork = freshContext.home + "/.claude-stern"
        try? FileManager.default.createDirectory(atPath: freshWork, withIntermediateDirectories: true)
        var freshReadings: [String: ClaudeAccountReading] = [:]
        freshReadings[ClaudeAccountKey.key(forFolder: freshWork)] = fresh[workKey]
        _ = try? ClaudeAccountsFile(accounts: todaysAccounts(folder: freshWork), readings: freshReadings).save(freshContext.paths)
        suite.expect(ClaudeHelper.pick(["--model", "fable"], context: freshContext) == .ok(freshWork)
                     && !FileManager.default.fileExists(atPath: freshContext.paths.requestsDirectory),
                     "a fresh reading asks for nothing")
    }

    // MARK: Sessions

    private static func sessionIndex(_ suite: TestSuite, _ scratch: Scratch) {
        suite.expect(ClaudeSessionIndex.projectSlug("/Users/elliotgrayco/Code/Util") == "-Users-elliotgrayco-Code-Util"
                     && ClaudeSessionIndex.projectSlug("/Users/elliotgrayco/Code/GreenUp/.claude/worktrees/agent-a2f1890f9ab4f15ff")
                        == "-Users-elliotgrayco-Code-GreenUp--claude-worktrees-agent-a2f1890f9ab4f15ff",
                     "projects/ names follow Claude Code's rule")
        suite.expect(ClaudeSessionIndex.projectSlug("/tmp/caf\u{E9}") == "-tmp-caf-" && ClaudeSessionIndex.projectSlug("/a/\u{1F600}") == "-a---",
                     "each UTF-16 unit that is not an ASCII letter or digit is a dash")
        suite.expect(ClaudeSessionIndex.javaHash("hello") == 99_162_322, "the long-name hash is Java's String.hashCode")
        let long = "/" + String(repeating: "a", count: 250)
        let slug = ClaudeSessionIndex.projectSlug(long)
        suite.expect(slug.hasPrefix("-" + String(repeating: "a", count: 199) + "-")
                     && slug == "-" + String(repeating: "a", count: 199) + "-" + String(abs(Int64(ClaudeSessionIndex.javaHash(long))), radix: 36),
                     "a name over 200 is cut and given a base-36 hash")
        suite.expect(ClaudeSessionIndex.isSessionId("0c3a5e8e-1b2f-4f0a-9d1e-2a3b4c5d6e7f") && !ClaudeSessionIndex.isSessionId("../x")
                     && !ClaudeSessionIndex.isSessionId("a/b") && !ClaudeSessionIndex.isSessionId(""), "session ids are names, never paths")

        let config = scratch.folder("sessions-config")
        let me = getpid()
        let started = Date().timeIntervalSince1970 * 1_000
        write(config + "/sessions/\(me).json", #"{"pid":\#(me),"sessionId":"live-1","cwd":"/tmp/p","status":"busy","kind":"interactive","startedAt":\#(Int64(started))}"#)
        write(config + "/sessions/\(me).abc.key", "not json")
        write(config + "/sessions/999999.json", #"{"pid":999999,"sessionId":"dead-1","cwd":"/tmp/p"}"#)
        write(config + "/sessions/broken.json", "{")
        let live = ClaudeSessionIndex.liveSessions(configDirectory: config)
        suite.expect(live.map(\.sessionId) == ["live-1"] && live.first?.pid == me && live.first?.status == "busy"
                     && live.first?.configDirectory == config,
                     "live sessions are the registry entries whose process runs (this test process)")
        suite.expect(ClaudeSessionIndex.liveSessions(configDirectory: config, isAlive: { _, _ in true }).count == 2,
                     "the process probe decides which entries count")
        suite.expect(ClaudeSessionIndex.processIsAlive(me, startedAt: nil) && ClaudeSessionIndex.processIsAlive(me, startedAt: Date())
                     && !ClaudeSessionIndex.processIsAlive(me, startedAt: Date(timeIntervalSince1970: 1_000_000))
                     && !ClaudeSessionIndex.processIsAlive(0, startedAt: nil),
                     "a process that started long after the session registered reuses the pid and is not it")

        let owners = ClaudeAccountsPaths(stateDirectory: scratch.folder("owners-state"))
        suite.expect(ClaudeSessionOwners.folder(sessionId: "abc", paths: owners) == nil, "no record, no account")
        suite.expect(ClaudeSessionOwners.record(sessionId: "abc", folder: stern, paths: owners, now: now)
                     && ClaudeSessionOwners.folder(sessionId: "abc", paths: owners) == stern
                     && !ClaudeSessionOwners.record(sessionId: "abc", folder: stern, paths: owners, now: now),
                     "a session's account is recorded once, and again only when it changes")
        suite.expect(mode(owners.sessionFile("abc")) == 0o600 && mode(owners.sessionsDirectory) == 0o700,
                     "the record is 0600 in a 0700 folder")
        suite.expect(ClaudeSessionOwners.record(sessionId: "abc", folder: "", paths: owners, now: now)
                     && ClaudeSessionOwners.folder(sessionId: "abc", paths: owners) == "",
                     "the default account is recorded as the empty folder")
        suite.expect(!ClaudeSessionOwners.record(sessionId: "../x", folder: stern, paths: owners, now: now)
                     && ClaudeSessionOwners.folder(sessionId: "../x", paths: owners) == nil,
                     "a session id is never a path")
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-61 * 86_400)],
                                               ofItemAtPath: owners.sessionFile("abc"))
        ClaudeSessionOwners.record(sessionId: "def", folder: stern, paths: owners, now: now)
        suite.expect(ClaudeSessionOwners.folder(sessionId: "abc", paths: owners) == nil
                     && ClaudeSessionOwners.folder(sessionId: "def", paths: owners) == stern,
                     "a new record removes those older than 60 days")

        // One conversation that two account folders hold (ClaudeSync keeps a
        // copy in each): listed once, by its longest copy.
        let one = scratch.folder("dedupe/.claude")
        let two = scratch.folder("dedupe/.claude-two")
        let cwd = "/tmp/brim-dedupe/App"
        let folder = "/projects/" + ClaudeSessionIndex.projectSlug(cwd)
        let id = "cccccccc-0000-4000-8000-000000000001"
        write(one + folder + "/\(id).jsonl", "{\"a\":1}\n")
        write(two + folder + "/\(id).jsonl", "{\"a\":1}\n{\"b\":2}\n")
        write(two + folder + "/cccccccc-0000-4000-8000-000000000002.jsonl", "{}\n")
        let listed = ClaudeSessionIndex.transcripts(cwd: cwd, configDirectories: [one, two])
        suite.expect(listed.filter { $0.sessionId == id }.count == 1 && listed.count == 2
                        && listed.first { $0.sessionId == id }?.configDirectory == two,
                     "a conversation in two folders is listed once, by its longest copy: \(listed.map(\.path))")
        suite.expect(ClaudeSessionIndex.transcript(sessionId: id, cwd: nil, configDirectories: [one, two])?.configDirectory == two
                        && ClaudeSessionIndex.transcript(sessionId: id, cwd: cwd, configDirectories: [two, one])?.configDirectory == two,
                     "the lookup of one session takes the longest copy too, whatever the folders' order")
        write(one + folder + "/\(id).jsonl", "{\"a\":1}\n{\"b\":2}\n")
        suite.expect(ClaudeSessionIndex.transcripts(cwd: cwd, configDirectories: [one, two]).filter { $0.sessionId == id }.count == 1,
                     "identical copies are listed once")
    }

    // MARK: move

    private static func move(_ suite: TestSuite, _ scratch: Scratch) {
        let base = makeContext(scratch, "move", cwd: "/tmp/brim-move/App")
        let shared = base.sharedRoot
        let work = base.home + "/.claude-work"
        let slug = ClaudeSessionIndex.projectSlug("/tmp/brim-move/App")
        let accounts = [ClaudeAccount(label: "rhodesconsulting", folder: "", accountUuid: defaultUuid, signedIn: true),
                        ClaudeAccount(label: "work", folder: work, accountUuid: sternUuid, signedIn: true)]
        let reading = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 10, resetsAt: sternWeeklyReset,
                                                                       observedAt: now, source: .cache))
        _ = try? ClaudeAccountsFile(accounts: accounts, readings: ["default": reading, accounts[1].id: reading]).save(base.paths)
        /// A transcript with Claude Code's own session-owner record, which
        /// Brim does not go by (a fork copies the original account's).
        func transcript(_ id: String, owner: String, age: TimeInterval) {
            let path = shared + "/projects/\(slug)/\(id).jsonl"
            write(path, #"{"type":"session-owner","accountUuid":"\#(owner)","sessionId":"\#(id)"}"# + "\n")
            let date = Date().addingTimeInterval(-age)
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
        /// What the session's status line records: the account it ran on.
        func ranOn(_ id: String, _ folder: String) {
            ClaudeSessionOwners.record(sessionId: id, folder: folder, paths: base.paths, now: now)
        }
        let ended = "aaaaaaaa-0000-4000-8000-000000000001"
        let running = "aaaaaaaa-0000-4000-8000-000000000002"
        transcript(ended, owner: defaultUuid, age: 3_600)
        transcript(running, owner: defaultUuid, age: 60)
        ranOn(ended, "")
        ranOn(running, "")
        let me = getpid()
        write(shared + "/sessions/\(me).json",
              #"{"pid":\#(me),"sessionId":"\#(running)","cwd":"/tmp/brim-move/App","startedAt":\#(Int64(Date().timeIntervalSince1970 * 1_000))}"#)
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)

        // The ended conversation's session folder (a workflow's journal and
        // script) and its file history, which a resume on work needs there.
        write(shared + "/projects/\(slug)/\(ended)/subagents/workflows/run-1/journal.jsonl", "{\"step\":1}\n")
        write(shared + "/projects/\(slug)/\(ended)/workflows/scripts/flow.js", "export default 1\n")
        write(shared + "/projects/\(slug)/\(ended)/workflows/scripts/build-wf_1234abcd-0a1.js", "export default 2\n")
        write(shared + "/file-history/\(ended)/backup@v1", "before")

        // The newest conversation here runs, open in the very process this
        // runs in: move never takes the older ended one in its place (T-50)
        // and never waits on its own session.
        let cloned = work + "/projects/\(slug)/\(ended).jsonl"
        let own = ClaudeHelper.move([], context: base)
        suite.expect(own.status == ClaudeHelper.MoveStatus.sessionRunning && own.stdout.isEmpty
                        && own.stderr.contains("aaaaaaaa is open in the Claude Code session this runs in (pid \(me) on rhodesconsulting)")
                        && own.stderr.contains("name it: cx \(ended)") && !ClaudeFileIO.exists(cloned),
                     "move does not fall back to the newest ended conversation while the newest runs: \(own.stderr)")
        // The target has no projects/ of its own yet: move syncs the
        // conversation in and the shell resumes it there by its own id.
        let moved = ClaudeHelper.move([ended], context: base)
        suite.expect(moved.status == 0 && moved.stdout == work + "\n" + ended + "\n",
                     "move prints two lines, the target folder and the session named: \(moved.stdout)\(moved.stderr)")
        suite.expect(ClaudeFileIO.isRegularFile(cloned) && !ClaudeFileIO.isSymlink(work + "/projects")
                        && read(cloned) == read(shared + "/projects/\(slug)/\(ended).jsonl"),
                     "the transcript is synced into the target's own projects/ (no link, no share needed)")
        suite.expect(read(work + "/projects/\(slug)/\(ended)/subagents/workflows/run-1/journal.jsonl") == "{\"step\":1}\n"
                        && read(work + "/projects/\(slug)/\(ended)/workflows/scripts/flow.js") == "export default 1\n"
                        && read(work + "/file-history/\(ended)/backup@v1") == "before",
                     "its session folder goes along under the same id, so its workflows resume there, with its file history")
        suite.expect(!ClaudeFileIO.exists(work + "/projects/\(slug)/\(running).jsonl"),
                     "a running conversation is not copied while it runs")
        suite.expect(!moved.stderr.contains("still running here") && moved.stderr.contains("(rhodesconsulting) on work.")
                        && !moved.stderr.contains("fork"),
                     "it says where the conversation goes: \(moved.stderr)")
        // The real failure (review of T-38): the transcript names a workflow's
        // script by the default account's path, which Claude Code refuses on
        // work; move said the workflows resume there as they are.
        let script = work + "/projects/\(slug)/\(ended)/workflows/scripts/build-wf_1234abcd-0a1.js"
        suite.expect(moved.stderr.contains("To resume workflow wf_1234abcd-0a1 there: Workflow({scriptPath: \"\(script)\", resumeFromRunId: \"wf_1234abcd-0a1\"})")
                        && !moved.stderr.contains("flow.js") && !moved.stderr.contains("resume there with their run ids"),
                     "it names each workflow's script by the target account's copy: \(moved.stderr)")
        suite.expect(ClaudeHelper.workflowRunId("brim-own-conversation-folders-wf_d11e42ef-bed.js") == "wf_d11e42ef-bed"
                        && ClaudeHelper.workflowRunId("symlink-repro.js") == nil && ClaudeHelper.workflowRunId("xwf_ab.js") == nil
                        && ClaudeHelper.workflowRunId("wf_.js") == nil && ClaudeHelper.workflowRunId("a-wf_1.json") == nil,
                     "a script's run id is the end of its name")
        // Again: the target's copy is identical, nothing is written over.
        suite.expect(ClaudeHelper.move([ended, "--to", "work"], context: base).status == 0 && read(cloned) == read(shared + "/projects/\(slug)/\(ended).jsonl"),
                     "moving again keeps the identical copy")
        // The conversation went on in the default account: the target's
        // copy is an older prefix of it and is replaced.
        let source = shared + "/projects/\(slug)/\(ended).jsonl"
        let older = read(source)
        write(source, older + "{\"type\":\"user\",\"more\":1}\n")
        // It stays the conversation that ended an hour ago.
        let hourAgo = Date().addingTimeInterval(-3_600)
        try? FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: source)
        suite.expect(ClaudeHelper.move([ended, "--to", "work"], context: base).status == 0 && read(cloned) == read(source),
                     "a strict byte-prefix copy in the target is replaced with the longer one")
        // A copy that is not a prefix (the conversation went on on both) is
        // never written over, and the move is refused.
        write(cloned, "a different conversation\n")
        let refusedCopy = ClaudeHelper.move([ended, "--to", "work"], context: base)
        suite.expect(refusedCopy.status == ClaudeHelper.MoveStatus.failed && refusedCopy.stdout.isEmpty
                        && refusedCopy.stderr.contains("continued on two accounts") && read(cloned) == "a different conversation\n",
                     "a different copy in the target refuses the move and stays: \(refusedCopy.stderr)")
        write(cloned, read(source))
        try? FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: cloned)
        let alive = ClaudeHelper.move([running], context: base)
        suite.expect(alive.status == ClaudeHelper.MoveStatus.sessionRunning && alive.stdout.isEmpty
                     && alive.stderr.contains("pid \(me)"),
                     "move refuses (exit 3) while the session's pid is alive in any folder")
        suite.expect(ClaudeHelper.move([ended, "--to", "work"], context: base).stdout == work + "\n" + ended + "\n",
                     "an explicit session and target")
        suite.expect(ClaudeHelper.move([ended, "--to", "rhodesconsulting"], context: base).status == ClaudeHelper.MoveStatus.nothingToMove,
                     "moving a conversation to the account it is on moves nothing")
        suite.expect(ClaudeHelper.move(["--to", "nobody"], context: base).status == ClaudeHelper.MoveStatus.failed
                     && ClaudeHelper.move(["../etc"], context: base).status == ClaudeHelper.MoveStatus.failed
                     && ClaudeHelper.move(["a", "b"], context: base).status == ClaudeHelper.MoveStatus.failed,
                     "bad targets and ids fail")
        var elsewhere = base
        elsewhere.currentDirectory = "/tmp/brim-move/Other"
        suite.expect(ClaudeHelper.move([], context: elsewhere).status == ClaudeHelper.MoveStatus.nothingToMove,
                     "nothing ended here: exit 2")
        suite.expect(ClaudeHelper.move([ended], context: elsewhere).status == ClaudeHelper.MoveStatus.failed,
                     "a conversation from another working folder must be continued from there")

        // A conversation that last ran on the other account comes back to the
        // default one: an empty first line.
        ranOn(ended, work)
        suite.expect(ClaudeHelper.move([ended], context: base).stdout == "\n" + ended + "\n",
                     "the default target is the best account other than the conversation's own")

        // The real failure: `cx` forked a default-account conversation onto
        // work; the fork's transcript holds only the copied record naming the
        // default account. Brim goes by what the fork's status line recorded.
        let fork = "aaaaaaaa-0000-4000-8000-000000000003"
        transcript(fork, owner: defaultUuid, age: 1_800)
        ranOn(fork, work)
        let back = ClaudeHelper.move([fork], context: base)
        suite.expect(back.status == 0 && back.stdout == "\n" + fork + "\n" && back.stderr.contains("(work) on rhodesconsulting"),
                     "a fork that ran on work moves back to the default account: \(back.stdout)\(back.stderr)")
        suite.expect(ClaudeHelper.move([fork, "--to", "rhodesconsulting"], context: base).status == 0
                     && ClaudeHelper.move([fork, "--to", "work"], context: base).status == ClaudeHelper.MoveStatus.nothingToMove,
                     "it may be sent back by name, and moving it to work, where it ran, moves nothing")

        // No record (the status line never drew for it): Brim claims nothing.
        let stray = "aaaaaaaa-0000-4000-8000-000000000004"
        transcript(stray, owner: sternUuid, age: 1_200)
        let unknown = ClaudeHelper.move([stray], context: base)
        suite.expect(unknown.status == ClaudeHelper.MoveStatus.ownerUnknown && unknown.stdout.isEmpty
                     && unknown.stderr.contains("--to") && unknown.stderr.contains(stray),
                     "without a record and without --to, move asks for the target: \(unknown.stderr)")
        let named = ClaudeHelper.move([stray, "--to", "rhodesconsulting"], context: base)
        suite.expect(named.status == 0 && named.stdout == "\n" + stray + "\n" && named.stderr.contains("account unknown"),
                     "with --to it moves, saying the account is unknown rather than guessing")
        let none = makeContext(scratch, "move-none", cwd: "/tmp")
        suite.expect(ClaudeHelper.move([], context: none).status == ClaudeHelper.MoveStatus.failed,
                     "without accounts.json there is nowhere to move")
    }

    // MARK: resume

    /// `claude --resume <id>`, `-c` and the picker, planned by brim-claude for
    /// the zsh wrapper: every account holds every conversation, so each is a
    /// plain resume after a sync.
    private static func resume(_ suite: TestSuite, _ scratch: Scratch) {
        let cwd = "/tmp/brim-resume/App"
        let base = makeContext(scratch, "resume", cwd: cwd)
        let shared = base.sharedRoot
        let work = base.home + "/.claude-work"
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: true)
        let slug = ClaudeSessionIndex.projectSlug(cwd)
        let accounts = [ClaudeAccount(label: "rhodesconsulting", folder: "", accountUuid: defaultUuid, signedIn: true),
                        ClaudeAccount(label: "work", folder: work, accountUuid: sternUuid, signedIn: true)]
        func reading(_ used: Double, resets: Date) -> ClaudeAccountReading {
            ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: used, resetsAt: resets, observedAt: now, source: .cache))
        }
        // work renews first, so Auto picks it.
        func save(defaultUse: Double, newSessions: ClaudeNewSessions = .auto) {
            _ = try? ClaudeAccountsFile(accounts: accounts, newSessions: newSessions,
                                        readings: ["default": reading(defaultUse, resets: defaultWeeklyReset),
                                                   accounts[1].id: reading(10, resets: sternWeeklyReset)]).save(base.paths)
        }
        func path(_ config: String, _ id: String) -> String { config + "/projects/\(slug)/\(id).jsonl" }
        func conversation(_ config: String, _ id: String, age: TimeInterval, owner: String) {
            write(path(config, id), #"{"sessionId":"\#(id)"}"# + "\n")
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path(config, id))
            ClaudeSessionOwners.record(sessionId: id, folder: owner, paths: base.paths, now: now)
        }
        func run(_ arguments: [String]) -> ClaudeHelperResult {
            ClaudeHelper.run(["resume", "--cwd", cwd] + arguments, input: { Data() }, context: base)
        }
        let mine = "dddddddd-0000-4000-8000-000000000001"
        let theirs = "dddddddd-0000-4000-8000-000000000002"
        conversation(shared, mine, age: 3_600, owner: "")
        conversation(work, theirs, age: 60, owner: work)
        save(defaultUse: 10)

        let plain = run(["--id", mine])
        suite.expect(plain.status == 0 && plain.stdout == "\n\n" && plain.stderr.contains("on rhodesconsulting, where it last ran"),
                     "-r <id> resumes on the account it last ran on while that one has room: \(plain.stdout)\(plain.stderr)")
        suite.expect(read(path(work, mine)) == read(path(shared, mine)) && read(path(shared, theirs)) == read(path(work, theirs)),
                     "the working folder's conversations are synced into every account first, so /resume lists them all")
        save(defaultUse: 100)
        let fresh = "dddddddd-0000-4000-8000-000000000004"
        conversation(shared, fresh, age: 1_800, owner: "")
        let carried = run(["--id", fresh])
        suite.expect(carried.status == 0 && carried.stdout == work + "\n\n" && read(path(work, fresh)) == read(path(shared, fresh)),
                     "an owner over its limit: a plain resume on the picked account, which now holds the conversation: \(carried.stdout)\(carried.stderr)")
        let continued = run(["--continue"])
        suite.expect(continued.status == 0 && continued.stdout == work + "\n\n",
                     "-c is the newest conversation here across every account; Claude Code's -c finds it, so -c stays: \(continued.stdout)")
        // A running conversation is newer than the newest ended one: -c means
        // it (T-50), not the ended one.
        let busy = "dddddddd-0000-4000-8000-000000000003"
        conversation(work, busy, age: 1, owner: work)
        let me = getpid()
        write(work + "/sessions/\(me).json",
              #"{"pid":\#(me),"sessionId":"\#(busy)","cwd":"\#(cwd)","startedAt":\#(Int64(Date().timeIntervalSince1970 * 1_000))}"#)
        // T-50: -c never swaps it for the older ended one. Open in the
        // process this runs in, it is not waited on either.
        let named = run(["--continue"])
        suite.expect(named.status == ClaudeHelper.MoveStatus.sessionRunning && named.stdout.isEmpty
                        && named.stderr.contains("name it: claude -r \(theirs)") && !ClaudeFileIO.exists(path(shared, busy)),
                     "-c with a newer running conversation does not take the ended one, and the running one is not copied: \(named.stderr)")
        let elsewhere = run(["--account", "rhodesconsulting", "--id", busy])
        suite.expect(elsewhere.status == ClaudeHelper.MoveStatus.sessionRunning,
                     "a conversation running on another account is not resumed here")
        unlink(work + "/sessions/\(me).json")
        let only = "dddddddd-0000-4000-8000-000000000005"
        conversation(shared, only, age: 7_200, owner: "")
        let picker = run(["--picker"])
        suite.expect(picker.status == 0 && picker.stdout == work + "\n\n" && !picker.stderr.contains("cx")
                        && ClaudeFileIO.isRegularFile(path(work, only)),
                     "a bare --resume syncs the folder's conversations, then opens the picker on the picked account: \(picker.stderr)")
        suite.expect(run(["--id", "eeeeeeee-0000-4000-8000-000000000009"]).stdout == work + "\n\n"
                        && run(["--id", "fix the login bug"]).stdout == work + "\n\n",
                     "a value that names no conversation runs as given (Claude Code's search)")
        let fixed = run(["--account", "rhodesconsulting", "--id", theirs])
        suite.expect(fixed.status == 0 && fixed.stdout == "\n\n" && read(path(shared, theirs)) == read(path(work, theirs)),
                     "cc <account> with a resume target resumes it on that account: \(fixed.stdout)\(fixed.stderr)")
        suite.expect(run(["--folder", work, "--id", mine]).stdout == work + "\n\n",
                     "a CLAUDE_CONFIG_DIR already set is the target")
        save(defaultUse: 10, newSessions: .account(accounts[1].id))
        suite.expect(run(["--id", mine]).stdout == "\n\n",
                     "the account it last ran on is preferred over new sessions' account while it has room")
        suite.expect(run([]).status == 1 && run(["--id", mine, "--continue"]).status == 1,
                     "resume needs exactly one of --id, --continue or --picker")
        let none = makeContext(scratch, "resume-none", cwd: cwd)
        suite.expect(ClaudeHelper.run(["resume", "--id", mine], input: { Data() }, context: none).stdout == "\n\n",
                     "without accounts.json the arguments run as given on the default account")

        // The real failure (review of T-38): `claude -c` with CLAUDE_CONFIG_DIR
        // set to a folder Brim does not list (a test config) failed without
        // launching, though Claude Code's own -c works there.
        let unlisted = base.home + "/cfg-test"
        try? FileManager.default.createDirectory(atPath: unlisted, withIntermediateDirectories: true)
        let passed = run(["--folder", unlisted, "--continue"])
        suite.expect(passed.status == 0 && passed.stdout == "\n\n" && !ClaudeFileIO.exists(unlisted + "/projects"),
                     "a folder Brim does not list runs the arguments as given, and nothing is synced into it: \(passed.stdout)\(passed.stderr)")

        // The real failure (review of T-38): a resume onto an account whose
        // copy is older (the sync could not bring it up to date) went ahead
        // with a note, splitting the conversation.
        save(defaultUse: 10)
        let stale = "dddddddd-0000-4000-8000-000000000006"
        conversation(shared, stale, age: 600, owner: "")
        write(path(work, stale), "{\"sessionId\":\"\(stale)\"}\n")
        write(path(shared, stale), "{\"sessionId\":\"\(stale)\"}\n{\"more\":1}\n")
        let slugFolder = work + "/projects/\(slug)"
        chmod(slugFolder, 0o500)
        let older = run(["--account", "work", "--id", stale])
        chmod(slugFolder, 0o700)
        suite.expect(older.status == ClaudeHelper.MoveStatus.failed && older.stdout.isEmpty && older.stderr.contains("older copy")
                        && read(path(work, stale)) == "{\"sessionId\":\"\(stale)\"}\n",
                     "a resume onto an older copy is refused: \(older.stderr)")
        suite.expect(run(["--account", "work", "--id", stale]).status == 0 && read(path(work, stale)) == read(path(shared, stale)),
                     "once the sync can update it, the resume goes ahead")
        // A version of a conversation continued on two accounts may go on
        // where it is: that splits nothing more.
        let split = "dddddddd-0000-4000-8000-000000000007"
        conversation(shared, split, age: 900, owner: "")
        write(path(work, split), "{\"sessionId\":\"\(split)\"}\n{\"on\":\"work\"}\n")
        write(path(shared, split), "{\"sessionId\":\"\(split)\"}\n{\"on\":\"the default account\"}\n")
        let version = run(["--account", "work", "--id", split])
        suite.expect(version.status == 0 && version.stdout == work + "\n\n" && version.stderr.contains("continued on two accounts")
                        && read(path(work, split)) == "{\"sessionId\":\"\(split)\"}\n{\"on\":\"work\"}\n",
                     "continuing one version of a split conversation goes ahead, saying so: \(version.stderr)")
    }

    // MARK: Held open (T-50)

    /// ticket T-50, the passscan incident of 2026-11-14: 8d866fb8 ran
    /// on sparkfx.ai until "Usage limit reached · continuing automatically at
    /// 1:30am"; the session stayed open, so the check-out held it away from
    /// every other account; cx would have moved the older 3b2a8a2e instead;
    /// `cx --to sparkfx` used a partial name. Holders are real short-lived
    /// /bin/sleep children of this test; nothing else is ever signalled.
    private static func heldOpen(_ suite: TestSuite, _ scratch: Scratch) {
        let cwd = "/tmp/brim-held/passscan"
        var base = makeContext(scratch, "held", cwd: cwd)
        let shared = base.sharedRoot
        let stern = base.home + "/.claude-stern"
        let sparkfx = base.home + "/.claude-sparkfx.ai"
        for folder in [shared, stern, sparkfx] {
            try? FileManager.default.createDirectory(atPath: folder + "/projects", withIntermediateDirectories: true)
        }
        let slug = ClaudeSessionIndex.projectSlug(cwd)
        let accounts = [ClaudeAccount(label: "elliotgrayco.me", folder: "", accountUuid: defaultUuid, signedIn: true),
                        ClaudeAccount(label: "sternpartners", folder: stern, accountUuid: sternUuid, signedIn: true),
                        ClaudeAccount(label: "sparkfx.ai", folder: sparkfx, accountUuid: "00000000-0000-4000-8000-00000000000c",
                                      signedIn: true)]
        let file = ClaudeAccountsFile(accounts: accounts, readings: [
            "default": ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 10, resetsAt: defaultWeeklyReset, observedAt: now, source: .cache)),
            accounts[1].id: ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 10, resetsAt: sternWeeklyReset, observedAt: now, source: .cache)),
            // sparkfx.ai: its 5-hour window is used up.
            accounts[2].id: ClaudeAccountReading(fiveHour: ClaudeUsageWindow(utilization: 100, resetsAt: now.addingTimeInterval(3 * 3_600),
                                                                             observedAt: now, source: .live),
                                                 sevenDay: ClaudeUsageWindow(utilization: 40, resetsAt: sternWeeklyReset, observedAt: now, source: .live))])
        _ = try? file.save(base.paths)
        var said: [String] = []
        base.say = { said.append($0) }
        var waits: [ClaudeHolder] = []
        func path(_ config: String, _ id: String) -> String { config + "/projects/\(slug)/\(id).jsonl" }
        func conversation(_ config: String, _ id: String, _ text: String, age: TimeInterval) {
            write(path(config, id), text)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path(config, id))
            ClaudeSessionOwners.record(sessionId: id, folder: config == shared ? "" : config, paths: base.paths, now: now)
        }
        /// A session that waits at its usage limit, as Claude Code 2.1.325 wrote 8d866fb8's end.
        func paused(_ id: String) -> String {
            [#"{"type":"user","message":{"role":"user","content":"keep going"},"sessionId":"\#(id)"}"#,
             #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Your usage limit was reached, so I've stopped all background work."}]},"sessionId":"\#(id)"}"#,
             #"{"type":"system","subtype":"stop_hook_summary","level":"suggestion","sessionId":"\#(id)"}"#,
             #"{"type":"system","subtype":"informational","level":"notice","isMeta":false,"content":"Usage limit reached · continuing automatically at 1:30am · esc to cancel","sessionId":"\#(id)"}"#,
             #"{"type":"system","subtype":"turn_duration","sessionId":"\#(id)"}"#,
             #"{"type":"last-prompt","sessionId":"\#(id)"}"#].joined(separator: "\n") + "\n"
        }
        /// A real process that holds `id` open on `config` for `seconds`.
        func hold(_ id: String, on config: String, seconds: String = "1") -> Process? {
            let sleeper = Process()
            sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
            sleeper.arguments = [seconds]
            guard (try? sleeper.run()) != nil else { return nil }
            let pid = sleeper.processIdentifier
            write(config + "/sessions/\(pid).json",
                  #"{"pid":\#(pid),"sessionId":"\#(id)","cwd":"\#(cwd)","kind":"interactive","startedAt":\#(Int64(Date().timeIntervalSince1970 * 1_000))}"#)
            return sleeper
        }
        func release(_ sleeper: Process?, from config: String) {
            guard let sleeper else { return }
            sleeper.waitUntilExit()
            unlink(config + "/sessions/\(sleeper.processIdentifier).json")
        }

        // Why a session waits, from its transcript's end.
        let x = "8d866fb8-055a-4c1f-b833-662ace2a22a4"
        suite.expect(ClaudeHeldOpen.pausedAtUsageLimit(tail: Data(("\n" + paused(x)).utf8)),
                     "a transcript that ends on Claude Code's usage-limit notice is paused at its usage limit")
        suite.expect(!ClaudeHeldOpen.pausedAtUsageLimit(tail: Data(("\n" + paused(x) + #"{"type":"user","message":{"role":"user","content":"go on"}}"# + "\n").utf8))
                        && !ClaudeHeldOpen.pausedAtUsageLimit(tail: Data(("\n" + #"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}"# + "\n").utf8)),
                     "a prompt after the notice, or an ordinary last answer, is not")
        suite.expect(ClaudeHeldOpen.pausedAtUsageLimit(tail: Data(("\n" + #"{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Claude AI usage limit reached|1794600000"}]}}"# + "\n").utf8))
                        && !ClaudeHeldOpen.pausedAtUsageLimit(tail: Data(#"{"type":"system","content":"Usage limit reached"}"#.utf8)),
                     "the older API-error form counts; a first line cut off by the read does not")
        let holder = ClaudeHolder(sessionId: x, pid: 4_242, startedAt: nil, configDirectory: sparkfx)
        suite.expect(ClaudeHelper.heldMessage(holder, account: "sparkfx.ai", terminal: "ttys012", paused: true)
                        == "brim-claude: 8d866fb8 is still open on sparkfx.ai (tab ttys012, pid 4242, paused at its usage limit). "
                           + "Press Esc and type /exit there; I'll continue here as soon as it ends. Ctrl-C to cancel."
                        && ClaudeHelper.heldMessage(holder, account: "sparkfx.ai", terminal: nil, paused: false)
                           .hasPrefix("brim-claude: 8d866fb8 is still open on sparkfx.ai (pid 4242). Press Esc"),
                     "the message names the account, tab, pid and why")

        // The incident, set up: 3b2a8a2e ended earlier; 8d866fb8 is newer and
        // every account holds it, then it opens on sparkfx.ai and pauses.
        let older = "3b2a8a2e-0000-4000-8000-000000000001"
        conversation(sparkfx, older, #"{"sessionId":"\#(older)"}"# + "\n", age: 7_200)
        conversation(sparkfx, x, paused(x), age: 600)
        ClaudeHelper.syncHere(cwd: cwd, accounts: accounts, context: base)
        let first = hold(x, on: sparkfx)
        let started = Date()
        ClaudeHelper.syncHere(cwd: cwd, accounts: accounts, context: base)
        suite.expect(first != nil && !ClaudeSessionIndex.transcripts(cwd: cwd, configDirectories: [stern]).contains { $0.sessionId == x }
                        && ClaudeFileIO.exists(ClaudeSync.heldPath(stern, slug: slug, id: x)),
                     "the real failure's state: open on sparkfx.ai, 8d866fb8 is held out of stern's /resume")
        suite.expect(ClaudeHeldConversation.describe(ClaudeSync.openCheckouts(statePath: ClaudeSync.statePath(base.paths), isAlive: base.isAlive),
                                                     accounts: accounts, home: base.home)
                        == [ClaudeHeldConversation(id: x, account: "sparkfx.ai", paused: true)]
                        && FeatureStrings.claudeAccounts(.enUS).held(ClaudeHeldConversation(id: x, account: "sparkfx.ai", paused: true))
                           == "8d866fb8 is paused at its usage limit on sparkfx.ai; /exit it there to continue it on another account.",
                     "the menu names the held conversation, where it is open and why")

        // A wrong name fails first, listing the exact names (T-50: `cx --to sparkfx`).
        let partial = ClaudeHelper.move(["--to", "sparkfx"], context: base)
        suite.expect(partial.status == ClaudeHelper.MoveStatus.failed && partial.stdout.isEmpty
                        && partial.stderr.hasPrefix("brim-claude: no Claude account is named \"sparkfx\". Use one of these names exactly:\n")
                        && partial.stderr.contains("  sparkfx.ai       (~/.claude-sparkfx.ai)\n")
                        && partial.stderr.contains("  elliotgrayco.me  (default: ~/.claude)\n")
                        && partial.stderr.contains("  sternpartners    (~/.claude-stern)\n") && said.isEmpty,
                     "cx --to with a partial name lists every account's exact name and starts nothing: \(partial.stderr)")
        // cx: 8d866fb8, never the older 3b2a8a2e; it says where it is open and
        // why, waits for that process to end, then continues it on stern.
        let moved = ClaudeHelper.move([], context: base)
        let waited = Date().timeIntervalSince(started)
        suite.expect(moved.status == 0 && moved.stdout == stern + "\n" + x + "\n" && waited > 0.5,
                     "cx waits for the session holding 8d866fb8 to end, then moves 8d866fb8 (\(waited) s): \(moved.stdout)\(moved.stderr) \(said)")
        suite.expect(said.first?.hasPrefix("brim-claude: 8d866fb8 is still open on sparkfx.ai (") == true
                        && said.first?.contains("pid \(first?.processIdentifier ?? 0)") == true
                        && said.first?.contains("paused at its usage limit). Press Esc and type /exit there; I'll continue here as soon as it ends. Ctrl-C to cancel.") == true
                        && said.contains("brim-claude: to continue the newest ended conversation instead, name it: cx \(older)")
                        && said.contains("brim-claude: 8d866fb8 ended on sparkfx.ai; continuing it."),
                     "it names the account, the process and why, and the explicit way to the older one: \(said)")
        suite.expect(read(path(stern, x)) == paused(x) && !ClaudeFileIO.exists(ClaudeSync.heldPath(stern, slug: slug, id: x))
                        && moved.stderr.contains("Continuing \(x) (sparkfx.ai) on sternpartners."),
                     "the check-in ran: stern holds 8d866fb8 as it ended: \(moved.stderr)")
        release(first, from: sparkfx)

        // claude -c: the same, by the resume route.
        said = []
        let second = hold(x, on: sparkfx)
        ClaudeHelper.syncHere(cwd: cwd, accounts: accounts, context: base)
        let continued = ClaudeHelper.run(["resume", "--cwd", cwd, "--continue"], input: { Data() }, context: base)
        let plan = continued.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        suite.expect(continued.status == 0 && plan.first == stern && (plan.count > 1 && (plan[1] == "" || plan[1] == x))
                        && said.first?.hasPrefix("brim-claude: 8d866fb8 is still open on sparkfx.ai (") == true
                        && said.contains("brim-claude: to continue the newest ended conversation instead, name it: claude -r \(older)"),
                     "claude -c waits for 8d866fb8 and plans it, never 3b2a8a2e: \(continued.stdout)\(continued.stderr) \(said)")
        release(second, from: sparkfx)

        // Cancelled (Ctrl-C): non-zero, nothing planned or moved.
        var cancelling = base
        cancelling.waitForExit = { holder in
            waits.append(holder)
            return .cancelled
        }
        let third = hold(x, on: sparkfx, seconds: "2")
        let cancelled = ClaudeHelper.move([], context: cancelling)
        let cancelledResume = ClaudeHelper.run(["resume", "--cwd", cwd, "--id", x], input: { Data() }, context: cancelling)
        suite.expect(cancelled.status == ClaudeHelper.MoveStatus.cancelled && cancelled.stdout.isEmpty
                        && cancelled.stderr == "brim-claude: cancelled; nothing was started.\n"
                        && cancelledResume.status == 130 && cancelledResume.stdout.isEmpty
                        && waits.count == 2 && waits.allSatisfy { $0.pid == third?.processIdentifier && $0.sessionId == x },
                     "a cancelled wait exits 130 and starts nothing: \(cancelled) \(cancelledResume)")
        // Naming the newest ended one is the explicit way to it.
        waits = []
        let named = ClaudeHelper.move([older, "--to", "sternpartners"], context: cancelling)
        suite.expect(named.status == 0 && named.stdout == stern + "\n" + older + "\n" && waits.isEmpty,
                     "cx <id of the newest ended one> moves it without waiting: \(named.stderr)")
        // The picker on stern cannot list it: it waits too; on sparkfx.ai,
        // where it is in view, it opens at once.
        let picker = ClaudeHelper.run(["resume", "--cwd", cwd, "--picker"], input: { Data() }, context: cancelling)
        waits = []
        let there = ClaudeHelper.run(["resume", "--cwd", cwd, "--picker", "--account", "sparkfx.ai"], input: { Data() }, context: cancelling)
        suite.expect(picker.status == 130 && there.status == 0 && there.stdout == sparkfx + "\n\n" && waits.isEmpty,
                     "a bare --resume waits only where the newest conversation is held out of view: \(picker) \(there)")
        release(third, from: sparkfx)

        // Never a wait on the session this runs in (cx from its Bash tool).
        let me = getpid()
        write(sparkfx + "/sessions/\(me).json",
              #"{"pid":\#(me),"sessionId":"\#(x)","cwd":"\#(cwd)","startedAt":\#(Int64(Date().timeIntervalSince1970 * 1_000))}"#)
        waits = []
        let own = ClaudeHelper.move([x], context: cancelling)
        suite.expect(own.status == ClaudeHelper.MoveStatus.sessionRunning && waits.isEmpty
                        && own.stderr.contains("is open in the Claude Code session this runs in (pid \(me) on sparkfx.ai)"),
                     "a conversation open in this very session is refused, not waited on: \(own.stderr)")
        unlink(sparkfx + "/sessions/\(me).json")

        // The wait itself: a kqueue exit source and Ctrl-C.
        if let gone = hold(x, on: sparkfx, seconds: "0") {
            release(gone, from: sparkfx)
            let quick = ClaudeHeldOpen.waitForExit(ClaudeHolder(sessionId: x, pid: gone.processIdentifier, startedAt: nil, configDirectory: sparkfx),
                                                   isAlive: { pid, _ in pid != gone.processIdentifier })
            suite.expect(quick == .exited, "a process gone before the source listened ends the wait at once")
        }
        if let waiting = hold(x, on: sparkfx) {
            let interrupted = ClaudeHeldOpen.waitForExit(ClaudeHolder(sessionId: x, pid: waiting.processIdentifier, startedAt: nil,
                                                                      configDirectory: sparkfx),
                                                         armed: { kill(getpid(), SIGINT) })
            suite.expect(interrupted == .cancelled && waiting.isRunning, "Ctrl-C (SIGINT) cancels the wait while the process still runs")
            let exited = ClaudeHeldOpen.waitForExit(ClaudeHolder(sessionId: x, pid: waiting.processIdentifier, startedAt: nil,
                                                                 configDirectory: sparkfx))
            suite.expect(exited == .exited, "the wait ends when the process exits")
            release(waiting, from: sparkfx)
        }
        // Review fix: SIGINT was ignored before the signal source listened, so
        // a Ctrl-C at that moment was dropped and the wait went on. `armed`
        // runs the instant SIGINT is ignored (where the old order had no
        // source yet); the interrupt raised there must cancel, every time.
        if let waiting = hold(x, on: sparkfx) {
            let outcomes = (0..<5).map { _ in
                ClaudeHeldOpen.waitForExit(ClaudeHolder(sessionId: x, pid: waiting.processIdentifier, startedAt: nil, configDirectory: sparkfx),
                                           armed: { kill(getpid(), SIGINT) })
            }
            suite.expect(outcomes.allSatisfy { $0 == .cancelled } && waiting.isRunning,
                         "a Ctrl-C the moment SIGINT is ignored still cancels the wait: \(outcomes)")
            release(waiting, from: sparkfx)
        }

        // Review fix: claude -c waited for 8d866fb8, but the retry chose the
        // newest conversation again. The holder had switched to another one
        // with /resume before it exited, so -c resumed that one instead.
        let switched = "5a5a5a5a-0000-4000-8000-000000000002"
        if let fourth = hold(x, on: sparkfx) {
            ClaudeHelper.syncHere(cwd: cwd, accounts: accounts, context: base)
            var switching = base
            switching.waitForExit = { _ in
                // In the holder: /resume <switched>, which writes it last, then /exit.
                for config in [shared, stern, sparkfx] { write(path(config, switched), #"{"sessionId":"\#(switched)"}"# + "\n") }
                return .exited
            }
            let kept = ClaudeHelper.run(["resume", "--cwd", cwd, "--continue"], input: { Data() }, context: switching)
            let keptPlan = kept.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            suite.expect(kept.status == 0 && keptPlan.count > 1 && keptPlan[1] == x
                            && ClaudeSessionIndex.transcripts(cwd: cwd, configDirectories: [stern]).first?.sessionId == switched,
                         "after the wait, claude -c resumes 8d866fb8 by name, not the conversation that became the newest: \(kept)")
            release(fourth, from: sparkfx)
            for config in [shared, stern, sparkfx] { unlink(path(config, switched)) }
        }

        // Review fix: a pid file left by a crash names a pid another program
        // took. It started after the session registered, so it does not hold
        // the conversation (before: up to 120 s later still counted, and
        // without startedAt nothing was checked), and nothing waits on it.
        if let reused = hold(x, on: sparkfx) {
            let pid = reused.processIdentifier
            let pidFile = sparkfx + "/sessions/\(pid).json"
            write(pidFile, #"{"pid":\#(pid),"sessionId":"\#(x)","cwd":"\#(cwd)","startedAt":\#(Int64((Date().timeIntervalSince1970 - 60) * 1_000))}"#)
            let stale = ClaudeSessionIndex.liveSessions(configDirectory: sparkfx)
            write(pidFile, #"{"pid":\#(pid),"sessionId":"\#(x)","cwd":"\#(cwd)"}"#)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: pidFile)
            let undated = ClaudeSessionIndex.liveSessions(configDirectory: sparkfx)
            waits = []
            let notHeld = ClaudeHelper.run(["resume", "--cwd", cwd, "--id", x, "--account", "sternpartners"], input: { Data() },
                                           context: cancelling)
            write(pidFile, #"{"pid":\#(pid),"sessionId":"\#(x)","cwd":"\#(cwd)"}"#)
            let fresh = ClaudeSessionIndex.liveSessions(configDirectory: sparkfx)
            suite.expect(stale.isEmpty && undated.isEmpty && waits.isEmpty && notHeld.status == 0
                            && fresh.map(\.pid) == [pid] && fresh.first?.startedAt != nil,
                         "a pid that started after its session registered (by startedAt, else by the file's time) holds nothing: \(stale) \(undated) \(notHeld) \(fresh)")
            release(reused, from: sparkfx)
        }

        // Review fix: the picker waited whenever the holder's config folder
        // was not the picked one, but an account whose projects/ is still a
        // link into ~/.claude (before the T-38 switch-over) reads the same
        // conversations as ~/.claude: the picker there lists the open one.
        var linked = makeContext(scratch, "held-linked", cwd: cwd)
        let linkedShared = linked.sharedRoot
        let linkedStern = linked.home + "/.claude-stern"
        let linkedSparkfx = linked.home + "/.claude-sparkfx.ai"
        for folder in [linkedShared, linkedSparkfx] {
            try? FileManager.default.createDirectory(atPath: folder + "/projects", withIntermediateDirectories: true)
        }
        try? FileManager.default.createDirectory(atPath: linkedStern, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: linkedStern + "/projects", withDestinationPath: linkedShared + "/projects")
        let linkedAccounts = [ClaudeAccount(label: "elliotgrayco.me", folder: "", accountUuid: defaultUuid, signedIn: true),
                              ClaudeAccount(label: "sternpartners", folder: linkedStern, accountUuid: sternUuid, signedIn: true),
                              ClaudeAccount(label: "sparkfx.ai", folder: linkedSparkfx, accountUuid: "00000000-0000-4000-8000-00000000000c",
                                            signedIn: true)]
        _ = try? ClaudeAccountsFile(accounts: linkedAccounts).save(linked.paths)
        write(path(linkedShared, x), #"{"sessionId":"\#(x)"}"# + "\n")
        linked.waitForExit = { holder in
            waits.append(holder)
            return .cancelled
        }
        func pickerWaits(heldOn config: String, pickedOn account: String) -> Bool? {
            guard let sleeper = hold(x, on: config, seconds: "1") else { return nil }
            defer { release(sleeper, from: config) }
            waits = []
            let result = ClaudeHelper.run(["resume", "--cwd", cwd, "--picker", "--account", account], input: { Data() }, context: linked)
            return result.status == 130 && waits.count == 1 ? true : result.status == 0 && waits.isEmpty ? false : nil
        }
        let onStern = pickerWaits(heldOn: linkedStern, pickedOn: "elliotgrayco.me")
        let onDefault = pickerWaits(heldOn: linkedShared, pickedOn: "sternpartners")
        let elsewhere = pickerWaits(heldOn: linkedSparkfx, pickedOn: "sternpartners")
        suite.expect(onStern == false && onDefault == false && elsewhere == true,
                     "the picker waits only when the open conversation is held out of the projects/ folder it reads: \(String(describing: onStern)) \(String(describing: onDefault)) \(String(describing: elsewhere))")

        // Account names: one rule for cc, cx --to and account-name; exact,
        // any case, never a part of one.
        suite.expect(file.match("SparkFX.ai") == .one(accounts[2]) && file.match("sparkfx") == .none
                        && file.match("stern") == .none && file.match(accounts[1].id) == .one(accounts[1])
                        && file.match(stern) == .one(accounts[1]),
                     "a name is a label in any case, an id or a folder, never a prefix")
        let twins = ClaudeAccountsFile(accounts: [ClaudeAccount(label: "Work", folder: "/tmp/.claude-w1", accountUuid: defaultUuid, signedIn: true),
                                                  ClaudeAccount(label: "work", folder: "/tmp/.claude-w2", accountUuid: sternUuid, signedIn: true)])
        let ambiguous = ClaudeHelper.account(named: "WORK", in: twins, context: base)
        suite.expect(twins.match("work") == .several(twins.accounts) && ambiguous.account == nil
                        && ambiguous.problem.contains("differ only in case") && ambiguous.problem.contains("(/tmp/.claude-w2)"),
                     "labels that differ only in case are ambiguous: \(ambiguous.problem)")
        let fresh = "28c46ed2-0000-4000-8000-000000000001"
        write(path(stern, fresh), #"{"sessionId":"\#(fresh)"}"# + "\n")
        let pick = ClaudeHelper.run(["pick", "--account", "stern", "--cwd", cwd], input: { Data() }, context: base)
        let resumeNamed = ClaudeHelper.run(["resume", "--id", older, "--account", "sparkfx"], input: { Data() }, context: base)
        suite.expect(pick.status == 2 && pick.stdout.isEmpty && pick.stderr.contains("Use one of these names exactly:\n")
                        && pick.stderr.contains("  sternpartners    (~/.claude-stern)")
                        && resumeNamed.status == 2 && resumeNamed.stderr.contains("  sparkfx.ai ")
                        && !ClaudeFileIO.exists(path(sparkfx, fresh)),
                     "cc <unknown name> lists the names too, before anything syncs: \(pick.stderr)")
        let asked = ClaudeHelper.run(["account-name", "SPARKFX.AI"], input: { Data() }, context: base)
        let prompt = ClaudeHelper.run(["account-name", "sparkfx"], input: { Data() }, context: base)
        suite.expect(asked == .ok("sparkfx.ai") && prompt.status == 1 && prompt.stdout.isEmpty && prompt.stderr.isEmpty
                        && ClaudeHelper.run(["account-name", "fix the bug"], input: { Data() }, context: base).status == 1,
                     "account-name prints the exact name a lone `claude` argument stands for, else nothing")
        // Review fix: account-name also took an id, so `claude default` (the
        // default account's internal id) was refused as "a Claude account's
        // name". It takes labels only; cc still takes an id or a folder, and
        // ~/.claude for the default account, as the twins message suggests.
        let byId = ClaudeHelper.run(["account-name", "default"], input: { Data() }, context: base)
        let byKey = ClaudeHelper.run(["account-name", accounts[1].id], input: { Data() }, context: base)
        let byFolder = ClaudeHelper.run(["account-name", stern], input: { Data() }, context: base)
        suite.expect(byId.status == 1 && byId.stdout.isEmpty && byKey.status == 1 && byFolder.status == 1,
                     "account-name never answers for an id or a folder: \(byId) \(byKey) \(byFolder)")
        suite.expect(ClaudeHelper.account(named: "default", in: file, context: base).account == accounts[0]
                        && ClaudeHelper.account(named: stern, in: file, context: base).account == accounts[1]
                        && ClaudeHelper.account(named: base.home + "/.claude", in: file, context: base).account == accounts[0]
                        && ClaudeHelper.account(named: base.home + "/.claude-nobody", in: file, context: base).account == nil,
                     "cc and cx --to still take an id or a folder, ~/.claude naming the default account")
    }

    // MARK: Shared sign-ins

    /// The real case: ~/.claude and ~/.claude-stern signed in to the same
    /// account (one oauthAccount.accountUuid in one organization), and
    /// ~/.claude-rhodesconsulting being signed in. One account, launched in
    /// the default folder, ranked once on the newest reading of either folder.
    private static func sharedSignIn(_ suite: TestSuite, _ scratch: Scratch) {
        let base = makeContext(scratch, "shared", cwd: "/tmp/brim-shared/App")
        let stern = base.home + "/.claude-stern"
        let rhodes = base.home + "/.claude-rhodesconsulting"
        let other = "00000000-0000-4000-8000-00000000000c"
        let personal = "00000000-0000-4000-8000-0000000000ff"
        for folder in [stern, rhodes] { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        let accounts = [ClaudeAccount(label: "default", folder: "", accountUuid: defaultUuid, organizationUuid: personal,
                                      plan: "Max 20x", signedIn: true),
                        ClaudeAccount(label: "stern", folder: stern, accountUuid: defaultUuid.uppercased(), organizationUuid: personal.uppercased(),
                                      plan: "Max 20x", signedIn: true),
                        ClaudeAccount(label: "rhodesconsulting", folder: rhodes, accountUuid: other, organizationUuid: personal,
                                      plan: "Max 5x", signedIn: true)]

        let groups = ClaudeAccountsDiscovery.groups(accounts, launchable: anyFolder)
        suite.expect(groups.map { $0.members.map(\.label) } == [["default", "stern"], ["rhodesconsulting"]]
                        && groups[0].primary.isDefault && groups[0].sharesSignIn && !groups[1].sharesSignIn,
                     "folders signed in to one accountUuid in one organization are one account, the default folder first")
        let shortFirst = ClaudeAccountsDiscovery.groups([
            ClaudeAccount(label: "long", folder: base.home + "/.claude-longer-name", accountUuid: other, organizationUuid: personal, signedIn: true),
            ClaudeAccount(label: "short", folder: base.home + "/.claude-ab", accountUuid: other, organizationUuid: personal, signedIn: nil),
            ClaudeAccount(label: "same", folder: base.home + "/.claude-cd", accountUuid: other, organizationUuid: personal, signedIn: true)],
                                                         launchable: anyFolder)
        suite.expect(shortFirst.count == 1 && shortFirst[0].members.map(\.label) == ["short", "long", "same"],
                     "without the default folder the shortest path launches; an equal one keeps its place")
        let signedOut = ClaudeAccountsDiscovery.groups([accounts[0],
            ClaudeAccount(label: "old", folder: stern, accountUuid: defaultUuid, organizationUuid: personal, signedIn: false),
            ClaudeAccount(label: "new", folder: rhodes, accountUuid: nil, signedIn: nil),
            ClaudeAccount(label: "unsure", folder: base.home + "/.claude-unsure", accountUuid: defaultUuid, signedIn: true)],
                                                       launchable: anyFolder)
        suite.expect(signedOut.count == 4,
                     "a signed-out folder, or one whose account or organization is not known yet, is never grouped")
        var team = accounts
        team[1].organizationUuid = "00000000-0000-4000-8000-0000000000ee"
        suite.expect(ClaudeAccountsDiscovery.groups(team, launchable: anyFolder).count == 3,
                     "one login in a personal plan and a team seat is two accounts, each with its own limits")
        suite.expect(ClaudeAccountsDiscovery.sameSignIn(accountUuid: defaultUuid, organizationUuid: personal,
                                                        as: defaultUuid.uppercased(), personal.uppercased())
                        && ClaudeAccountsDiscovery.sameSignIn(accountUuid: defaultUuid, organizationUuid: nil, as: defaultUuid, personal)
                        && !ClaudeAccountsDiscovery.sameSignIn(accountUuid: defaultUuid, organizationUuid: personal,
                                                               as: defaultUuid, team[1].organizationUuid)
                        && !ClaudeAccountsDiscovery.sameSignIn(accountUuid: defaultUuid, organizationUuid: personal, as: other, personal),
                     "a folder that signs in to another organization holds another sign-in, as one that signs in to another account")

        // The default folder cannot be launched (its spelling would select
        // another sign-in): checks and launches use stern, the first folder
        // that can be, and the account keeps both folders.
        let blocked = ClaudeAccountsDiscovery.groups(accounts, launchable: { !$0.isDefault })
        suite.expect(blocked[0].members.map(\.label) == ["stern", "default"]
                        && ClaudeAccountsDiscovery.groups(accounts, launchable: { _ in false })[0].primary.isDefault,
                     "a shared sign-in launches in its first folder that can be launched; with none, its default folder leads")

        // The default folder read its usage an hour ago; stern's status line
        // just reported the same account at 45 % of its week.
        let older = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 39, resetsAt: sternWeeklyReset,
                                                                     observedAt: now.addingTimeInterval(-3_600), source: .cache))
        let newer = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 45, resetsAt: sternWeeklyReset,
                                                                     observedAt: now.addingTimeInterval(-60), source: .live))
        let later = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 1, resetsAt: defaultWeeklyReset,
                                                                     observedAt: now, source: .cache))
        let readings = ["default": older, accounts[1].id: newer, accounts[2].id: later]
        let ranks = ClaudeAccountRanking.rank(accounts, readings: readings, model: nil, now: now, launchable: anyFolder)
        suite.expect(ranks.count == 2 && ranks[0].account.isDefault && ranks[0].folders.map(\.label) == ["default", "stern"]
                        && ranks[0].windows.first { $0.kind == .weekly }?.utilization == 45
                        && ranks[0].windows.first { $0.kind == .weekly }?.source == .live
                        && ranks[1].account.label == "rhodesconsulting" && !ranks[1].sharesSignIn,
                     "the shared account ranks once, in the default folder, on the newest reading of either folder")

        var file = ClaudeAccountsFile(accounts: accounts, readings: readings)
        _ = try? file.save(base.paths)
        suite.expect(ClaudeHelper.pick([], context: base) == .ok(""),
                     "pick launches the shared account in the default folder, never in ~/.claude-stern")
        suite.expect(ClaudeHelper.pick(["--account", "stern"], context: base) == .ok("")
                        && ClaudeHelper.pick(["--account", "rhodesconsulting"], context: base) == .ok(rhodes),
                     "naming either folder of the shared account launches it in the default folder")
        file.newSessions = .account(accounts[1].id)
        _ = try? file.save(base.paths)
        suite.expect(ClaudeHelper.pick([], context: base) == .ok(""),
                     "new sessions set to ~/.claude-stern use the shared account's default folder")
        // Both readings 20 minutes old: one check, asked of the folder launches use.
        var stale = file
        stale.readings["default"] = nil
        stale.readings[accounts[1].id] = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(
            utilization: 45, resetsAt: sternWeeklyReset, observedAt: now.addingTimeInterval(-20 * 60), source: .live))
        _ = try? stale.save(base.paths)
        _ = ClaudeHelper.pick([], context: base)
        let requests = (try? FileManager.default.contentsOfDirectory(atPath: base.paths.requestsDirectory)) ?? []
        suite.expect(requests.count == 1 && requests.first?.hasSuffix("-default") == true,
                     "a stale shared account asks for one check, in the folder launches use: \(requests)")
        try? FileManager.default.removeItem(atPath: base.paths.requestsDirectory)
        _ = try? file.save(base.paths)

        let resolved = ClaudeHelper.resolve(context: base).stdout
        let listed = resolved.components(separatedBy: "\n").filter { $0.hasPrefix("  ") && !$0.hasPrefix("    ") }
        suite.expect(resolved.contains("same sign-in in 2 folders: default (default: CLAUDE_CONFIG_DIR unset), stern (\(stern))")
                        && listed.filter { $0.contains("default [default]") }.count == 1
                        && !listed.contains { $0.contains("stern [") }
                        && listed.filter { $0.contains(". default (same sign-in in 2 folders") }.count == 1
                        && !listed.contains { $0.contains(". stern") },
                     "resolve lists and ranks the shared account once, naming both folders: \(resolved)")

        // A conversation that ran in ~/.claude-stern is on the shared account:
        // cx moves it to the other account, and the default folder is no move.
        let slug = ClaudeSessionIndex.projectSlug("/tmp/brim-shared/App")
        let session = "bbbbbbbb-0000-4000-8000-000000000001"
        write(base.sharedRoot + "/projects/\(slug)/\(session).jsonl", "{}\n")
        symlink(base.sharedRoot + "/projects", rhodes + "/projects")
        ClaudeSessionOwners.record(sessionId: session, folder: stern, paths: base.paths, now: now)
        file.newSessions = .auto
        _ = try? file.save(base.paths)
        let moved = ClaudeHelper.move([], context: base)
        suite.expect(moved.status == 0 && moved.stdout == rhodes + "\n" + session + "\n",
                     "cx moves a conversation of the shared account to another account (still linked there): \(moved.stdout)\(moved.stderr)")
        suite.expect(ClaudeHelper.move([session, "--to", "default"], context: base).status == ClaudeHelper.MoveStatus.nothingToMove,
                     "moving it to the default folder of its own account moves nothing")

        // The status line in either folder shows the account's scoped window.
        var scoped = file
        scoped.readings[accounts[1].id] = ClaudeAccountReading(scoped: [ClaudeScopedWindow(
            model: "Fable", utilization: 62, resetsAt: sternWeeklyReset, active: true, observedAt: now, source: .cache)])
        _ = try? scoped.save(base.paths)
        var inDefault = base
        inDefault.environment["CLAUDE_CONFIG_DIR"] = nil
        inDefault.environment["NO_COLOR"] = "1"
        let input = #"{"session_id":"s","model":{"id":"claude-fable-5","display_name":"Fable 5"},"rate_limits":{"seven_day":{"used_percentage":45,"resets_at":1794751200}}}"#
        let line = ClaudeHelper.statusline(input: Data(input.utf8), context: inDefault).result.stdout
        suite.expect(line.contains("Fable 62%"), "the default folder's status line shows the window stern's check read: \(line)")

        // The real failure: checks run in the default folder, whose newest
        // report no longer lists Fable; stern still holds an older report
        // with Fable at 99 %. Merged in launch order (default first), the
        // dropped window must stay dropped, in the app and from accounts.json.
        var dropped = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 40, resetsAt: sternWeeklyReset,
                                                                       observedAt: now, source: .check))
        dropped.scopedReportedAt = now
        var sternReport = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 38, resetsAt: sternWeeklyReset,
                                                                           observedAt: now.addingTimeInterval(-3 * 3_600), source: .cache),
                                               scoped: [ClaudeScopedWindow(model: "Fable", utilization: 99, resetsAt: sternWeeklyReset,
                                                                           active: true, observedAt: now.addingTimeInterval(-3 * 3_600),
                                                                           source: .cache)])
        sternReport.scopedReportedAt = now.addingTimeInterval(-3 * 3_600)
        let reported = ["default": dropped, accounts[1].id: sternReport, accounts[2].id: later]
        let fable = ClaudeAccountRanking.rank(accounts, readings: reported, model: "fable", now: now, launchable: anyFolder)
        let sharedRank = fable.first(where: { $0.sharesSignIn })
        suite.expect(sharedRank?.status == ClaudeAccountStatus.usable
                        && sharedRank?.windows.contains(where: { $0.kind == ClaudeWindowKind.scoped("Fable") }) == false,
                     "a window the default folder's newer report dropped does not come back from stern's older one")
        var droppedFile = file
        droppedFile.readings = reported
        _ = try? droppedFile.save(base.paths)
        let afterDrop = ClaudeHelper.statusline(input: Data(input.utf8), context: inDefault).result.stdout
        suite.expect(!afterDrop.contains("Fable"), "nor in the status line, read from accounts.json: \(afterDrop)")

        // A choice of a folder that cannot be launched is still the choice
        // of its account: pick launches it in its other folder, never in the
        // ranking's first account.
        let gone = base.home + "/.claude-ab"
        let blockedAccounts = [ClaudeAccount(label: "ab", folder: gone, accountUuid: defaultUuid, organizationUuid: personal, signedIn: true),
                               accounts[1], accounts[2]]
        // rhodesconsulting renews within the hour, so the ranking puts it first.
        let renewsSoon = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 1, resetsAt: now.addingTimeInterval(3_600),
                                                                          observedAt: now, source: .cache))
        let blockedFile = ClaudeAccountsFile(accounts: blockedAccounts, newSessions: .account(blockedAccounts[0].id),
                                             readings: [blockedAccounts[0].id: older, accounts[1].id: older, accounts[2].id: renewsSoon])
        _ = try? blockedFile.save(base.paths)
        suite.expect(ClaudeHelper.pick([], context: base) == .ok(stern),
                     "new sessions set to a missing folder of a shared sign-in launch in its folder that can be")
        suite.expect(ClaudeHelper.pick(["--account", "ab"], context: base) == .ok(stern),
                     "naming the missing folder launches the account in its folder that can be")
        _ = try? file.save(base.paths)
    }

    // MARK: Sharing

    private static func sharing(_ suite: TestSuite, _ scratch: Scratch) {
        let home = scratch.folder("share")
        let state = ClaudeAccountsPaths(stateDirectory: home + "/.config/brim/claude")
        let root = home + "/.claude"
        let folder = home + "/.claude-work"
        write(root + "/settings.json", #"{"model":"opus"}"#)
        write(root + "/CLAUDE.md", "shared rules")
        write(root + "/skills/one/SKILL.md", "skill")
        write(root + "/agents/a.md", "agent")
        write(root + "/plugins/installed_plugins.json", "{}")
        write(root + "/file-history/s/1", "checkpoint")
        write(root + "/projects/p1/a.jsonl", "shared-a")
        write(root + "/projects/p1/same.jsonl", "same")
        write(root + "/history.jsonl", #"{"display":"one","timestamp":1000}"# + "\n" + #"{"display":"three","timestamp":3000}"# + "\n")

        write(folder + "/settings.json", #"{"model":"sonnet"}"#)
        write(folder + "/CLAUDE.md", "own rules")
        write(folder + "/rules/r.md", "own rule")
        write(folder + "/plans/plan.md", "own plan")
        symlink(root + "/skills", folder + "/skills")
        write(folder + "/projects/p1/a.jsonl", "work-a")
        write(folder + "/projects/p1/same.jsonl", "same")
        write(folder + "/projects/p2/new.jsonl", "new")
        write(folder + "/history.jsonl", #"{"display":"two","timestamp":2000}"# + "\n" + #"{"display":"one","timestamp":1000}"# + "\n"
              + #"{"display":"four","timestamp":4000}"# + "\n")
        write(folder + "/.claude.json", #"{"oauthAccount":{"accountUuid":"u"}}"#)
        write(folder + "/sessions/.keep", "")
        write(folder + "/.pre-brim/settings.json", "an earlier original")

        let unverified = ClaudeSetupSharing.unverifiedEntries.map { $0.name }
        suite.expect(Set(ClaudeSetupSharing.linkedEntries).count == ClaudeSetupSharing.linkedEntries.count
                     && !ClaudeSetupSharing.linkedEntries.contains(where: ClaudeSetupSharing.isNeverLinked)
                     && !unverified.contains { ClaudeSetupSharing.linkedEntries.contains($0) }
                     && !unverified.contains { ClaudeSetupSharing.isNeverLinked($0) },
                     "no entry is in two of the linked, unverified and never-linked lists")
        for name in [".claude.json", "sessions", "ide", ".credentials.json", ".oauth_refresh.lock", ".oauth_refresh.lock.owner",
                     "policy-limits.json", "policy-limits.signature.json", "remote-settings.json", "statsig", "telemetry", "cache",
                     "state", "stats-cache.json", "mcp-needs-auth-cache.json", "shell-snapshots", "session-env", "backups"] {
            suite.expect(ClaudeSetupSharing.isNeverLinked(name), "\(name) is never linked")
        }
        suite.expect(ClaudeSetupSharing.linkedEntries.contains("plugins") && unverified == ["history.jsonl"],
                     "plugins/ is shared (its gate passed); history.jsonl stays each account's own (Claude Code never uses a linked history.jsonl)")
        suite.expect(ClaudeOwnFolders.entries == ["projects", "file-history", "plans", "tasks"]
                        && !ClaudeOwnFolders.entries.contains(where: ClaudeSetupSharing.linkedEntries.contains),
                     "conversations are each account's own: projects, file-history, plans and tasks are never linked")

        let plan = ClaudeSetupSharing.plan(sharedRoot: root, folders: ["", folder])
        func action(_ name: String) -> ClaudeShareAction? { plan.steps.first { $0.name == name }?.action }
        suite.expect(plan.canExecute && plan.steps.count == ClaudeSetupSharing.linkedEntries.count + unverified.count
                     && plan.steps.allSatisfy { $0.folder == folder },
                     "the plan covers each linked entry of each non-default folder: \(plan.problems)")
        suite.expect(action("settings.json") == .replace(preBrimName: "settings.json.1") && action("CLAUDE.md") == .replace(preBrimName: "CLAUDE.md"),
                     "an original moves into .pre-brim, never over an earlier one")
        suite.expect(action("skills") == .alreadyLinked && action("agents") == .link && action("plugins") == .link
                     && action("rules") == .notInSharedRoot && action("keybindings.json") == .absent,
                     "links already in place, new links, and entries the shared folder lacks (left alone)")
        suite.expect(action("projects") == nil && action("plans") == nil && action("file-history") == nil
                        && !plan.needsOwnFolders,
                     "a folder sharing for the first time keeps its conversations: no step touches them")
        suite.expect(action("history.jsonl") == .mergeOnly && plan.steps.first { $0.name == "history.jsonl" }?.merge?.historyLines == 2,
                     "the shared history gains the two lines it lacks, without a link")
        suite.expect(plan.lines.contains { $0.contains("history.jsonl: add 2 line(s)") && $0.contains("not linked") }
                     && !plan.lines.contains { $0.hasPrefix("  plugins: not linked") },
                     "the dry run says why history.jsonl stays, and links plugins/")
        suite.expect(plan.lines.contains("  settings.json: move to .pre-brim/settings.json.1, then link to \(root)/settings.json")
                     && plan.lines.contains { $0.contains("Never linked") && $0.contains(".claude.json") },
                     "the dry run says what each step does: \(plan.lines)")

        // A live session on the folder keeps that folder out of the run.
        let me = getpid()
        write(folder + "/sessions/\(me).json", #"{"pid":\#(me),"sessionId":"x","startedAt":\#(Int64(Date().timeIntervalSince1970 * 1_000))}"#)
        let refused = ClaudeSetupSharing.execute(sharedRoot: root, folders: [folder], paths: state)
        let livePlan = ClaudeSetupSharing.plan(sharedRoot: root, folders: [folder])
        suite.expect(!refused.refused && refused.failures == 1 && !ClaudeFileIO.isSymlink(folder + "/settings.json")
                        && refused.lines.contains { $0.contains("not changed") && $0.contains("/exit") }
                        && livePlan.problems.contains { $0.kind == .liveSessions(1) } && livePlan.canExecute
                        && !livePlan.changesSomething && livePlan.blockedFolders == [folder],
                     "the executor leaves a folder a session runs on unchanged and says which: \(refused.lines)")
        try? FileManager.default.removeItem(atPath: folder + "/sessions/\(me).json")

        // The guard on the shared settings.
        write(root + "/settings.json", #"{"model":"opus","env":{"CLAUDE_CONFIG_DIR":"/tmp/one"}}"#)
        let guarded = ClaudeSetupSharing.execute(sharedRoot: root, folders: [folder], paths: state)
        suite.expect(guarded.refused && guarded.lines.contains { $0.contains("env.CLAUDE_CONFIG_DIR") }
                     && !ClaudeFileIO.isSymlink(folder + "/settings.json"),
                     "env.CLAUDE_CONFIG_DIR in the shared settings is a hard error")
        suite.expect(ClaudeSetupSharing.settingsProblems(Data(#"{"env":{"CLAUDE_SECURESTORAGE_CONFIG_DIR":"/x"}}"#.utf8)).map(\.kind) == [.settingsSetSecureStorage]
                     && ClaudeSetupSharing.settingsProblems(nil).isEmpty && ClaudeSetupSharing.settingsProblems(Data("{}".utf8)).isEmpty,
                     "the settings guard alone")
        write(root + "/settings.json", #"{"model":"opus"}"#)

        let report = ClaudeSetupSharing.execute(sharedRoot: root, folders: ["", folder], paths: state)
        suite.expect(report.succeeded, "the share runs: \(report.lines)")
        suite.expect(ClaudeSetupSharing.isLink(folder + "/settings.json", to: root + "/settings.json")
                     && read(folder + "/.pre-brim/settings.json.1") == #"{"model":"sonnet"}"#
                     && read(folder + "/.pre-brim/settings.json") == "an earlier original",
                     "settings.json is linked; its original sits in .pre-brim beside the earlier one")
        suite.expect(read(root + "/projects/p1/a.jsonl") == "shared-a" && !ClaudeFileIO.exists(root + "/projects/p1/a.from-claude-work.jsonl")
                     && !ClaudeFileIO.exists(root + "/projects/p2") && ClaudeFileIO.isDirectory(folder + "/projects")
                     && read(folder + "/projects/p1/a.jsonl") == "work-a" && read(folder + "/plans/plan.md") == "own plan",
                     "conversations stay the folder's own: nothing copied into the shared folder, nothing linked")
        let history = read(root + "/history.jsonl").split(separator: "\n").map(String.init)
        suite.expect(history.compactMap { line in (ClaudeJSON.parse(Data(line.utf8)) as? [String: Any])?["display"] as? String }
                        == ["one", "two", "three", "four"],
                     "history lines merged by time, duplicates once: \(history)")
        suite.expect(!ClaudeFileIO.exists(root + "/history.jsonl.lock"), "the history lock is released")
        suite.expect(ClaudeFileIO.isRegularFile(folder + "/history.jsonl") && read(folder + "/history.jsonl").contains("\"four\"")
                     && ClaudeSetupSharing.isLink(folder + "/plugins", to: root + "/plugins") && !ClaudeFileIO.exists(folder + "/.pre-brim/history.jsonl"),
                     "the folder keeps its own history.jsonl, a regular file, and its plugins/ links to the shared one")
        suite.expect(ClaudeFileIO.isRegularFile(folder + "/.claude.json") && ClaudeFileIO.isDirectory(folder + "/sessions")
                     && ClaudeFileIO.isDirectory(folder + "/rules") && ClaudeFileIO.isDirectory(folder + "/plans"),
                     "never-linked entries and entries the shared folder lacks stay the folder's own")
        let again = ClaudeSetupSharing.plan(sharedRoot: root, folders: [folder])
        suite.expect(!again.changesSomething && again.steps.first { $0.name == "agents" }?.action == .alreadyLinked,
                     "a second plan finds everything linked")

        let undoLines = ClaudeSetupSharing.undoPlan(folder: folder, sharedRoot: root)
        suite.expect(undoLines.contains("  settings.json: remove the link, move .pre-brim/settings.json.1 back")
                     && undoLines.contains("  agents: remove the link"), "the undo in words: \(undoLines)")
        let undone = ClaudeSetupSharing.undo(folder: folder, sharedRoot: root)
        suite.expect(undone.succeeded && ClaudeFileIO.isRegularFile(folder + "/settings.json")
                     && read(folder + "/settings.json") == #"{"model":"sonnet"}"#
                     && ClaudeFileIO.isDirectory(folder + "/projects") && read(folder + "/projects/p1/a.jsonl") == "work-a"
                     && !ClaudeFileIO.exists(folder + "/agents") && ClaudeFileIO.isSymlink(folder + "/skills")
                     && read(folder + "/.pre-brim/settings.json") == "an earlier original",
                     "the undo restores the originals and removes only Brim's links: \(undone.lines)")
        suite.expect(ClaudeShareManifest.load(folder: folder)?.entries.isEmpty == true,
                     "the manifest is emptied")

        suite.expect(ClaudeFileCopy.keptName("a.jsonl", tag: "claude-work", number: 1) == "a.from-claude-work.jsonl"
                     && ClaudeFileCopy.keptName("a.jsonl", tag: "claude-work", number: 2) == "a.from-claude-work.2.jsonl"
                     && ClaudeFileCopy.keptName("README", tag: "t", number: 1) == "README.from-t"
                     && ClaudeFileCopy.folderTag("/Users/x/.claude-stern") == "claude-stern",
                     "kept names")
        let merged = ClaudeSetupSharing.historyMerge(shared: Data(), own: Data("a\n{\"timestamp\":5}\na\n\n".utf8))
        suite.expect(merged.added == 2 && String(decoding: merged.data, as: UTF8.self) == "a\n{\"timestamp\":5}\n",
                     "history merge into an empty file keeps each line once")
        let blocked = ClaudeSetupSharing.plan(sharedRoot: root, folders: [root, "relative", home + "/missing"])
        suite.expect(blocked.problems.map(\.kind) == [.folderIsSharedRoot, .invalidFolder, .folderMissing],
                     "the shared folder, relative and missing folders are refused")
    }

    // MARK: Own folders (T-38)

    /// The migration of a folder Brim linked earlier (projects/, file-history/
    /// and plans/ to ~/.claude) back to its own folders.
    private static func ownFolders(_ suite: TestSuite, _ scratch: Scratch) {
        let home = scratch.folder("own")
        let root = home + "/.claude"
        let state = ClaudeAccountsPaths(stateDirectory: home + "/.config/brim/claude")
        let now = Date()
        let s1 = "11111111-0000-4000-8000-000000000001"
        let s2 = "11111111-0000-4000-8000-000000000002"
        let s4 = "11111111-0000-4000-8000-000000000004"
        let s5 = "11111111-0000-4000-8000-000000000005"
        // ~/.claude: every account's conversations, as the links left them.
        write(root + "/settings.json", "{}")
        write(root + "/projects/p1/\(s1).jsonl", "line 1\nline 2\n")
        write(root + "/projects/p1/\(s1)/subagents/workflows/run-1/journal.jsonl", "{\"step\":1}\n")
        write(root + "/projects/p1/\(s1)/workflows/scripts/flow.js", "export default 1\n")
        write(root + "/projects/p1/\(s1)/tool-results/r.txt", "result")
        write(root + "/projects/p1/\(s2).jsonl", "someone else's\n")
        write(root + "/projects/p1/\(s4).jsonl", "the shared copy\n")
        write(root + "/projects/p1/memory/MEMORY.md", "- shared memory\n")
        write(root + "/projects/p2/memory/notes/x.md", "x")
        write(root + "/file-history/\(s1)/f@v1", "before")
        write(root + "/file-history/\(s2)/f@v1", "theirs")
        write(root + "/plans/plan-a.md", "plan a")
        let files = { (folder: String) in (FileManager.default.enumerator(atPath: folder)?.allObjects as? [String] ?? []).sorted() }
        let before = Dictionary(uniqueKeysWithValues: files(root).map { ($0, read(root + "/" + $0)) })

        /// A folder as Brim's earlier share left it: the three entries linked,
        /// projects/ stored in .pre-brim when it had its own.
        func linkedFolder(_ name: String, storedProjects: Bool) -> String {
            let folder = home + "/" + name
            try? FileManager.default.createDirectory(atPath: folder + "/.pre-brim", withIntermediateDirectories: true)
            var manifest = ClaudeShareManifest()
            for entry in ["settings.json", "projects", "file-history", "plans"] {
                symlink(root + "/" + entry, folder + "/" + entry)
                let stored = entry == "projects" && storedProjects ? "projects" : nil
                manifest.entries.append(.init(name: entry, storedAs: stored, linkedTo: root + "/" + entry))
            }
            try? manifest.save(folder: folder)
            return folder
        }
        let work = linkedFolder(".claude-work", storedProjects: true)
        // Its pre-Brim copy: an older copy of s1 (a prefix), its own s4 that
        // differs from the shared one, a conversation of its own and memory.
        write(work + "/.pre-brim/projects/p1/\(s1).jsonl", "line 1\n")
        write(work + "/.pre-brim/projects/p1/\(s4).jsonl", "its own copy\n")
        write(work + "/.pre-brim/projects/p3/\(s5).jsonl", "own\n")
        write(work + "/.pre-brim/projects/p1/memory/OLD.md", "old memory")
        // A second folder, with a session running on it.
        let busy = linkedFolder(".claude-busy", storedProjects: false)
        let me = getpid()
        write(busy + "/sessions/\(me).json", #"{"pid":\#(me),"sessionId":"live","startedAt":\#(Int64(Date().timeIntervalSince1970 * 1_000))}"#)

        suite.expect(ClaudeOwnFolders.needsOwnFolders(work) && ClaudeOwnFolders.linkedEntry(folder: work, name: "tasks") == nil,
                     "a folder whose conversation entries are Brim's links needs its own folders")
        let plan = ClaudeSetupSharing.plan(sharedRoot: root, folders: [work, busy], labels: [work: "work"])
        let steps = plan.steps.filter { $0.folder == work && $0.action.changesFiles }
        suite.expect(steps.map(\.name) == ["projects", "file-history", "plans"]
                        && steps.first?.action == .ownFolder(base: "projects", resumes: false)
                        && steps[1].action == .ownFolder(base: nil, resumes: false),
                     "the review plans an own folder for each linked conversation entry: \(steps)")
        suite.expect(plan.lines.contains("  Gives work its own conversation folders so workflows, memory and plans work there. Every conversation stays listed in /resume on every account (clones, no extra disk).")
                        && plan.needsOwnFolders && plan.canExecute && plan.blockedFolders == [busy],
                     "the review says per folder what it does, and the busy folder is left out: \(plan.lines)")

        let trashFolder = scratch.folder("own-trash")
        let trash: (String) throws -> Void = { path in
            try FileManager.default.moveItem(atPath: path, toPath: trashFolder + "/" + UUID().uuidString)
        }
        let report = ClaudeSetupSharing.execute(sharedRoot: root, folders: [work, busy], paths: state, labels: [work: "work"],
                                                now: now, trash: trash)
        suite.expect(!report.refused && report.failures == 1 && report.lines.contains { $0.hasPrefix(busy) && $0.contains("not changed") }
                        && report.lines.contains { $0.hasPrefix("Synced every account's conversations") },
                     "the run goes ahead for work, syncs, and says the busy folder was left: \(report.lines)")
        suite.expect(ClaudeFileIO.isSymlink(busy + "/projects") && ClaudeOwnFolders.needsOwnFolders(busy),
                     "a folder a session runs on keeps its links")
        let projects = work + "/projects"
        suite.expect(ClaudeFileIO.isDirectory(projects) && !ClaudeFileIO.isSymlink(projects)
                        && ClaudeFileIO.isDirectory(work + "/file-history") && !ClaudeFileIO.isSymlink(work + "/plans")
                        && !ClaudeOwnFolders.needsOwnFolders(work) && !ClaudeFileIO.exists(work + "/.projects.brim-new"),
                     "work's projects/, file-history/ and plans/ are real folders now")
        suite.expect(read(projects + "/p1/\(s1).jsonl") == "line 1\nline 2\n"
                        && read(projects + "/p1/\(s1)/subagents/workflows/run-1/journal.jsonl") == "{\"step\":1}\n"
                        && read(projects + "/p1/\(s1)/workflows/scripts/flow.js") == "export default 1\n"
                        && read(projects + "/p1/\(s1)/tool-results/r.txt") == "result"
                        && read(projects + "/p1/\(s2).jsonl") == "someone else's\n",
                     "every conversation is synced in with its session folder; the older copy (a prefix) was replaced")
        suite.expect(read(projects + "/p1/\(s4).jsonl") == "its own copy\n" && read(root + "/projects/p1/\(s4).jsonl") == "the shared copy\n"
                        && report.lines.contains { $0.contains("Continued on two accounts") && $0.contains(s4) },
                     "a conversation that went on on both sides keeps both versions, each in its folder, and is reported")
        suite.expect(read(root + "/projects/p3/\(s5).jsonl") == "own\n",
                     "the folder's own conversations reach ~/.claude (and so every account)")
        suite.expect(read(projects + "/p1/memory/MEMORY.md") == "- shared memory\n" && read(projects + "/p2/memory/notes/x.md") == "x"
                        && !ClaudeFileIO.exists(projects + "/p1/memory/OLD.md") && !ClaudeFileIO.exists(root + "/projects/p1/memory/OLD.md")
                        && read(work + "/.pre-brim/memory-before-own-folders/p1/OLD.md") == "old memory",
                     "every repo's memory is the shared memory; the memory its old copy had moves aside, never deleted or spread")
        suite.expect(read(work + "/file-history/\(s1)/f@v1") == "before" && read(work + "/file-history/\(s2)/f@v1") == "theirs"
                        && read(work + "/plans/plan-a.md") == "plan a" && mode(work + "/file-history") == 0o700,
                     "file history and plans are synced in; new folders are 0700")
        suite.expect(!ClaudeFileIO.exists(work + "/.pre-brim/projects")
                        && before.allSatisfy { ClaudeFileIO.isDirectory(root + "/" + $0.key) || read(root + "/" + $0.key) == $0.value },
                     "the pre-Brim copy became the base; nothing in ~/.claude was changed or removed")
        let manifest = ClaudeShareManifest.load(folder: work)
        suite.expect(manifest?.entries.map(\.name) == ["settings.json"]
                        && manifest?.ownedFolders?.map(\.name) == ["projects", "file-history", "plans"]
                        && manifest?.ownedFolders?.first?.base == ".pre-brim/projects" && manifest?.ownedFolders?[1].base == "empty",
                     "the manifest drops the entries and notes the own folders: \(String(describing: manifest))")
        let synced = ClaudeSync.State.load(ClaudeSync.statePath(state))
        suite.expect(synced.sessions["p1/\(s1)"]?.holders.contains(ClaudeFileIO.realPath(work)) == true
                        && synced.memory["p1"]?.files["MEMORY.md"] == ClaudeSync.hash(Data("- shared memory\n".utf8)),
                     "the sync state records what it synced")
        let again = ClaudeSetupSharing.plan(sharedRoot: root, folders: [work])
        suite.expect(!again.needsOwnFolders && !again.changesSomething, "a second review has nothing left to do")
        // The whole-folder undo still works for the entries left linked.
        let undone = ClaudeSetupSharing.undo(folder: work, sharedRoot: root)
        suite.expect(undone.succeeded && !ClaudeFileIO.exists(work + "/settings.json")
                        && ClaudeFileIO.isDirectory(projects) && read(projects + "/p3/\(s5).jsonl") == "own\n",
                     "the undo removes the remaining links and leaves the own folders: \(undone.lines)")

        // A swap that fails puts the link, the pre-Brim copy and its memory back.
        let failing = linkedFolder(".claude-failing", storedProjects: true)
        write(failing + "/.pre-brim/projects/p9/kept.jsonl", "kept")
        write(failing + "/.pre-brim/projects/p9/memory/M.md", "m")
        do {
            _ = try ClaudeOwnFolders.perform(folder: failing, name: "projects", now: now, statePath: ClaudeSync.statePath(state),
                                             swap: { _, _ in
                errno = EACCES
                return -1
            })
            suite.expect(false, "the failing swap throws")
        } catch {
            suite.expect("\(error)".contains("Permission denied"), "it says why: \(error)")
        }
        suite.expect(ClaudeSetupSharing.isLink(failing + "/projects", to: root + "/projects")
                        && read(failing + "/.pre-brim/projects/p9/kept.jsonl") == "kept"
                        && read(failing + "/.pre-brim/projects/p9/memory/M.md") == "m"
                        && !ClaudeFileIO.exists(failing + "/.projects.brim-new")
                        && ClaudeShareManifest.load(folder: failing)?.entries.contains { $0.name == "projects" } == true,
                     "the link is back, the pre-Brim copy and its memory too, and the manifest still records the link")
        // The real failure (review of T-38): the swap was an unlink, then a
        // rename, outside the sync's lock; a sync in between could make the
        // entry and leave the folder with neither the link nor its own
        // folder. Now the link and the new folder trade places in one rename,
        // under the sync's lock.
        let swapped = linkedFolder(".claude-swapped", storedProjects: false)
        let syncState = ClaudeSync.statePath(state)
        var linkedAtSwap = false
        var syncLocked = false
        let atomic = try? ClaudeOwnFolders.perform(folder: swapped, name: "plans", now: now, statePath: syncState, swap: { from, to in
            linkedAtSwap = ClaudeFileIO.isSymlink(to)
            let probe = open(syncState + ".lock", O_RDWR | O_CLOEXEC)
            syncLocked = probe >= 0 && flock(probe, LOCK_EX | LOCK_NB) != 0
            if probe >= 0 { close(probe) }
            return renamex_np(from, to, UInt32(RENAME_SWAP))
        })
        suite.expect(atomic?.failed == false && linkedAtSwap && syncLocked
                        && ClaudeFileIO.isDirectory(swapped + "/plans") && !ClaudeFileIO.isSymlink(swapped + "/plans")
                        && !ClaudeFileIO.exists(swapped + "/.plans.brim-new") && read(root + "/plans/plan-a.md") == "plan a",
                     "the entry is the link until the one swap, which holds the sync's lock; the old link goes after: \(String(describing: atomic))")
        // A leftover new folder from an earlier run stops that entry only.
        try? FileManager.default.createDirectory(atPath: failing + "/.plans.brim-new", withIntermediateDirectories: true)
        write(failing + "/.plans.brim-new/x.md", "x")
        let resumed = ClaudeSetupSharing.plan(sharedRoot: root, folders: [failing])
        suite.expect(resumed.steps.contains { $0.name == "plans" && $0.action == .ownFolder(base: nil, resumes: true) },
                     "the review picks up a new folder a run that stopped part way left")
        let leftover = ClaudeSetupSharing.execute(sharedRoot: root, folders: [failing], paths: state, trash: trash)
        suite.expect(leftover.failures == 0 && !ClaudeFileIO.isSymlink(failing + "/plans") && read(failing + "/plans/x.md") == "x"
                        && !ClaudeFileIO.isSymlink(failing + "/projects"),
                     "the run takes it as it is and goes on: \(leftover.lines)")
    }

    // MARK: Sync

    /// ClaudeSync: every account folder holds every conversation, plan and
    /// repo's memory, so /resume lists them all on any account.
    private static func sync(_ suite: TestSuite, _ scratch: Scratch) {
        let home = scratch.folder("sync")
        let configs = ["/.claude", "/.claude-a", "/.claude-b"].map { home + $0 }
        for config in configs { try? FileManager.default.createDirectory(atPath: config + "/projects", withIntermediateDirectories: true) }
        // A folder still linked to ~/.claude/projects sees its files already.
        let linked = home + "/.claude-linked"
        try? FileManager.default.createDirectory(atPath: linked, withIntermediateDirectories: true)
        symlink(configs[0] + "/projects", linked + "/projects")
        let folders = ClaudeSync.folders(configDirectories: configs + [linked])
        let (root, a, b) = (folders[0], folders[1], folders[2])
        suite.expect(folders == configs.map(ClaudeFileIO.realPath),
                     "~/.claude and every account folder with real conversation folders take part; a linked one is skipped: \(folders)")
        let statePath = home + "/state/sync.json"
        var trashed: [String] = []
        var moves = 0
        let trashFolder = scratch.folder("sync-trash")
        let trash: (String) throws -> Void = { path in
            trashed.append(path)
            moves += 1
            try FileManager.default.moveItem(atPath: path, toPath: trashFolder + "/\(moves)-" + (path as NSString).lastPathComponent)
        }
        var participants = configs + [linked]
        func run(_ scope: ClaudeSync.Scope = .all, beforeWrite: @escaping (String) -> Void = { _ in }) -> ClaudeSync.Report {
            ClaudeSync.reconcile(configDirectories: participants, scope: scope, statePath: statePath,
                                 options: ClaudeSync.Options(trash: trash, now: Date(), cleanupDays: 30, beforeWrite: beforeWrite))
        }
        func date(_ path: String, _ seconds: TimeInterval) {
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: path)
        }
        func ago(_ path: String, days: Double) {
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: path)
        }
        func t(_ folder: String, _ id: String) -> String { folder + "/projects/-conv/\(id).jsonl" }
        func side(_ folder: String, _ id: String, _ rest: String) -> String { folder + "/projects/-conv/\(id)/" + rest }

        // A conversation on one account reaches the others, with its session
        // folder and file history.
        let s1 = "22222222-0000-4000-8000-000000000001"
        write(t(a, s1), "one\n")
        write(side(a, s1, "subagents/agent-1.jsonl"), "x\n")
        write(side(a, s1, "workflows/scripts/flow.js"), "v1")
        write(a + "/file-history/\(s1)/f@v1", "before")
        var report = run()
        suite.expect(read(t(root, s1)) == "one\n" && read(t(b, s1)) == "one\n"
                        && read(side(b, s1, "subagents/agent-1.jsonl")) == "x\n" && read(side(root, s1, "workflows/scripts/flow.js")) == "v1"
                        && read(b + "/file-history/\(s1)/f@v1") == "before" && mode(b + "/projects/-conv") == 0o700,
                     "a missing copy is cloned in with its session folder and file history; new folders are 0700: \(report)")
        suite.expect(ClaudeFileIO.modificationDate(t(b, s1)) == ClaudeFileIO.modificationDate(t(a, s1))
                        && !ClaudeFileIO.exists(linked + "/projects/-conv/\(s1).jsonl.from-claude-linked"),
                     "clones keep the dates, and the linked folder sees ~/.claude's copy")
        report = run()
        suite.expect(report.copied.isEmpty && report.trashed.isEmpty && report.conversations == 1,
                     "a second run writes nothing: \(report)")
        // It went on on b: the longest copy wins everywhere, and its session
        // files follow it.
        write(t(b, s1), "one\ntwo\n")
        write(side(b, s1, "subagents/agent-1.jsonl"), "x\ny\n")
        write(side(b, s1, "workflows/scripts/flow.js"), "v2")
        report = run(ClaudeSync.Scope(sessions: [s1]))
        suite.expect(read(t(a, s1)) == "one\ntwo\n" && read(t(root, s1)) == "one\ntwo\n"
                        && read(side(a, s1, "subagents/agent-1.jsonl")) == "x\ny\n" && read(side(root, s1, "workflows/scripts/flow.js")) == "v2",
                     "older copies (byte-prefixes) are replaced by the longest; other files follow the folder that holds it: \(report)")
        suite.expect(((try? FileManager.default.contentsOfDirectory(atPath: a + "/projects/-conv")) ?? []).allSatisfy { !$0.hasPrefix(".") },
                     "every write went through a temporary file and a rename; none is left")
        // It went on on two accounts between syncs: each version stays, and
        // a copy older than both takes the one it last ran with (the newest
        // change); reported once.
        write(t(a, s1), "one\ntwo\nthree on a\n")
        ago(t(a, s1), days: 0.01)
        write(t(b, s1), "one\ntwo\nthree on b\n")
        report = run()
        suite.expect(report.diverged == [s1] && read(t(a, s1)) == "one\ntwo\nthree on a\n" && read(t(b, s1)) == "one\ntwo\nthree on b\n"
                        && read(t(root, s1)) == "one\ntwo\nthree on b\n",
                     "a conversation continued on two accounts keeps both versions; an older copy takes the newest: \(report)")
        suite.expect(run().diverged.isEmpty, "it is reported once")
        // The real failure (review of T-38): a diverged conversation was left
        // alone everywhere from then on. Each version keeps syncing now.
        write(t(b, s1), "one\ntwo\nthree on b\nfour\n")
        report = run()
        suite.expect(report.diverged.isEmpty && read(t(root, s1)) == "one\ntwo\nthree on b\nfour\n"
                        && read(t(a, s1)) == "one\ntwo\nthree on a\n",
                     "a copy of one version follows it as it goes on; the other version is untouched: \(report)")
        write(t(a, s1), "one\ntwo\nthree on a\nfive\n")

        // A running conversation is never touched; it syncs when it ends.
        let s2 = "22222222-0000-4000-8000-000000000002"
        write(t(a, s2), "running\n")
        let me = getpid()
        write(a + "/sessions/\(me).json", #"{"pid":\#(me),"sessionId":"\#(s2)","startedAt":\#(Int64(Date().timeIntervalSince1970 * 1_000))}"#)
        report = run()
        suite.expect(!ClaudeFileIO.exists(t(b, s2)) && report.running == 1, "a running conversation is not copied: \(report)")
        unlink(a + "/sessions/\(me).json")
        _ = run(ClaudeSync.Scope(sessions: [s2]))
        suite.expect(read(t(b, s2)) == "running\n", "it syncs once it ended")

        // Deleted in one folder (Claude Code's cleanup): old copies go to the
        // Trash, recent ones stay and are not synced again; never brought back.
        let old = "22222222-0000-4000-8000-000000000003"
        write(t(a, old), "old\n")
        write(side(a, old, "tool-results/r.txt"), "r")
        ago(t(a, old), days: 40)
        _ = run()
        unlink(t(root, old))
        report = run()
        suite.expect(report.trashed.contains(t(a, old)) && report.trashed.contains(t(b, old)) && report.trashed.contains(a + "/projects/-conv/\(old)")
                        && !ClaudeFileIO.exists(t(a, old)) && !ClaudeFileIO.exists(t(root, old))
                        && FileManager.default.fileExists(atPath: trashFolder + "/1-\(old).jsonl"),
                     "an old conversation deleted in one folder goes to the Trash in the others, never unlinked: \(report.trashed)")
        let recent = "22222222-0000-4000-8000-000000000004"
        write(t(a, recent), "recent\n")
        _ = run()
        trashed = []
        unlink(t(root, recent))
        report = run()
        suite.expect(trashed.isEmpty && report.left.count == 1 && read(t(a, recent)) == "recent\n" && !ClaudeFileIO.exists(t(root, recent)),
                     "a recent one deleted in one folder stays in the others: \(report)")
        report = run()
        suite.expect(!ClaudeFileIO.exists(t(root, recent)) && report.copied.isEmpty, "and is not brought back")
        // A folder that never took part gets everything; nothing is read as deleted.
        let fresh = home + "/.claude-new"
        try? FileManager.default.createDirectory(atPath: fresh, withIntermediateDirectories: true)
        participants.append(fresh)
        report = run()
        suite.expect(read(t(fresh, s1)) == "one\ntwo\nthree on a\nfive\n" && read(t(fresh, s2)) == "running\n" && report.trashed.isEmpty
                        && read(t(b, s1)) == "one\ntwo\nthree on b\nfour\n",
                     "a new account folder gets every conversation, of one continued on two accounts the version it last ran with: \(report)")

        // Plans: the newest wins.
        write(a + "/plans/p.md", "plan")
        date(a + "/plans/p.md", Date().timeIntervalSince1970 - 100)
        _ = run()
        write(root + "/plans/p.md", "plan 2")
        report = run()
        suite.expect(read(b + "/plans/p.md") == "plan 2" && read(a + "/plans/p.md") == "plan 2" && read(fresh + "/plans/p.md") == "plan 2",
                     "a plan reaches every account, and its newest change wins: \(report)")

        // Memory.
        func memory(_ folder: String, _ name: String = "MEMORY.md") -> String { folder + "/projects/-repo/memory/" + name }
        let memoryScope = ClaudeSync.Scope(memory: ["-repo"])
        write(memory(a), "one")
        date(memory(a), 1_000)
        report = run()
        suite.expect(read(memory(root)) == "one" && read(memory(b)) == "one"
                        && ClaudeFileIO.modificationDate(memory(b)) == Date(timeIntervalSince1970: 1_000)
                        && mode(b + "/projects/-repo") == 0o700,
                     "a new memory file reaches every folder, with its date: \(report)")
        write(memory(b), "two")
        date(memory(b), 2_000)
        report = run(memoryScope)
        suite.expect(read(memory(root)) == "two" && read(memory(a)) == "two", "the newest change wins: \(report)")
        write(memory(a), "three")
        date(memory(a), 3_000)
        write(memory(b), "four")
        date(memory(b), 3_000)
        report = run()
        suite.expect(read(memory(a)) == "three" && read(memory(b)) == "four" && read(memory(root)) == "two"
                        && report.skipped.contains { $0.contains("at the same time") },
                     "two different changes at the same moment are left alone and reported: \(report.skipped)")
        write(memory(a), "four")
        date(memory(a), 3_000)
        _ = run()
        suite.expect(read(memory(root)) == "four", "once they agree, it goes everywhere")
        // A copy changed on its own and older than the winner is kept in the Trash.
        write(memory(b), "edited on b")
        date(memory(b), 3_500)
        write(memory(a), "edited on a")
        date(memory(a), 4_000)
        trashed = []
        report = run(memoryScope)
        suite.expect(read(memory(b)) == "edited on a" && trashed.contains(memory(b)) && report.kept.count == 1,
                     "an edit that loses to a newer one goes to the Trash before it is replaced: \(report)")
        // Deleted in one folder: the other copies go to the Trash.
        trashed = []
        unlink(memory(a))
        report = run()
        suite.expect(!ClaudeFileIO.exists(memory(root)) && !ClaudeFileIO.exists(memory(b)) && trashed.count == 3
                        && ClaudeSync.State.load(statePath).memory["-repo"] == nil,
                     "a synced memory file deleted in one folder goes to the Trash in the others: \(report)")
        // What memory sync leaves alone.
        write(memory(a, ".hidden.md"), "x")
        write(memory(a, "draft.md.tmp.123"), "x")
        write(memory(a, "notes.md~"), "x")
        symlink("/etc/hosts", memory(a, "link.md"))
        write(memory(a, "big.md"), String(repeating: "x", count: (1 << 20) + 1))
        report = run()
        suite.expect([".hidden.md", "draft.md.tmp.123", "notes.md~", "link.md", "big.md"].allSatisfy { !ClaudeFileIO.exists(memory(b, $0)) }
                        && report.skipped.contains { $0.contains("link.md") && $0.contains("a link") }
                        && report.skipped.contains { $0.contains("big.md") && $0.contains("over 1 MB") },
                     "dotfiles, temporary names, links and files over 1 MB are skipped: \(report.skipped)")
        // A destination that changes during the sync is not written over.
        write(memory(a, "race.md"), "from a")
        date(memory(a, "race.md"), 5_000)
        write(memory(b, "race.md"), "old b")
        date(memory(b, "race.md"), 4_000)
        report = run(memoryScope, beforeWrite: { destination in
            if destination == memory(b, "race.md") { write(destination, "b changed meanwhile") }
        })
        suite.expect(read(memory(b, "race.md")) == "b changed meanwhile" && read(memory(root, "race.md")) == "from a"
                        && report.skipped.contains { $0.contains("race.md") && $0.contains("changed during the sync") }
                        && ClaudeSync.State.load(statePath).memory["-repo"]?.files["race.md"] == nil,
                     "a copy that changed during the sync is skipped and left unrecorded for the next run: \(report.skipped)")
        suite.expect(ClaudeSync.memorySlug(ofEvent: a + "/projects/-repo/memory/MEMORY.md", folders: folders) == "-repo"
                        && ClaudeSync.memorySlug(ofEvent: a + "/projects/-repo/abc.jsonl", folders: folders) == nil
                        && ClaudeSync.memorySlug(ofEvent: "/elsewhere/projects/-repo/memory/x", folders: folders) == nil,
                     "an event names a slug only inside a memory folder")
        suite.expect(ClaudeSync.reconcile(configDirectories: [configs[0], linked], scope: .all, statePath: statePath) == ClaudeSync.Report(),
                     "one folder alone has nothing to sync")
        suite.expect(ClaudeSync.cleanupDays(sharedSettings: Data(#"{"cleanupPeriodDays":7}"#.utf8)) == 7
                        && ClaudeSync.cleanupDays(sharedSettings: nil) == 30,
                     "the cleanup period comes from the shared settings, 30 days when they name none")

        // brim-claude pick syncs the working folder before a launch.
        let context = makeContext(scratch, "sync-pick", cwd: "/tmp/brim-sync/App")
        let other = context.home + "/.claude-other"
        let slug = ClaudeSessionIndex.projectSlug("/tmp/brim-sync/App")
        let s9 = "22222222-0000-4000-8000-000000000009"
        try? FileManager.default.createDirectory(atPath: other + "/projects", withIntermediateDirectories: true)
        write(context.sharedRoot + "/projects/\(slug)/memory/MEMORY.md", "picked")
        write(context.sharedRoot + "/projects/\(slug)/\(s9).jsonl", "here\n")
        write(context.sharedRoot + "/projects/-elsewhere/memory/MEMORY.md", "not this repo")
        write(context.sharedRoot + "/projects/-elsewhere/\(s9.dropLast())8.jsonl", "elsewhere\n")
        _ = try? ClaudeAccountsFile(accounts: [ClaudeAccount(label: "one", folder: "", signedIn: true),
                                               ClaudeAccount(label: "other", folder: other, signedIn: true)]).save(context.paths)
        _ = ClaudeHelper.pick([], context: context)
        suite.expect(read(other + "/projects/\(slug)/memory/MEMORY.md") == "picked" && read(other + "/projects/\(slug)/\(s9).jsonl") == "here\n"
                        && !ClaudeFileIO.exists(other + "/projects/-elsewhere"),
                     "pick brings the working folder's conversations and memory to every account, and only that repo's")
        // The app's sync holds the lock (a full run takes seconds): pick says
        // so before it waits, so `claude` never looks frozen.
        let held = open(ClaudeSync.statePath(context.paths) + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        flock(held, LOCK_EX)
        var said: [String] = []
        var waiting = context
        waiting.say = { line in
            said.append(line)
            flock(held, LOCK_UN)
        }
        _ = ClaudeHelper.pick([], context: waiting)
        close(held)
        _ = ClaudeHelper.pick([], context: waiting)
        suite.expect(said == [ClaudeHelper.syncWaitNote],
                     "pick says it waits for Brim's sync, once, and only while the sync runs: \(said)")

        // Tidy up replaces an older copy the way the sync does (one
        // primitive): only while both files are as the review saw them.
        let mergeFrom = scratch.folder("merge-from")
        let mergeTo = scratch.folder("merge-to")
        write(mergeFrom + "/c.jsonl", "a\nb\n")
        write(mergeTo + "/c.jsonl", "a\n")
        let merge = ClaudeFileCopy.plan(from: mergeFrom, into: mergeTo, tag: "t")
        write(mergeFrom + "/c.jsonl", "a\nb\nc\n")
        var refused = false
        do { try ClaudeFileCopy.apply(merge) } catch { refused = true }
        suite.expect(merge.copies.map(\.kind) == [.replace] && refused && read(mergeTo + "/c.jsonl") == "a\n",
                     "a source that changed since the plan is not copied over the older copy")
        let replanned = ClaudeFileCopy.plan(from: mergeFrom, into: mergeTo, tag: "t")
        suite.expect((try? ClaudeFileCopy.apply(replanned)) != nil && read(mergeTo + "/c.jsonl") == "a\nb\nc\n"
                        && ((try? FileManager.default.contentsOfDirectory(atPath: mergeTo)) ?? []) == ["c.jsonl"],
                     "planned again, it is replaced through a temporary clone and a rename")
    }

    /// The real failure (review of T-38): a folder deleted and made again
    /// outside Brim (removed, then `claude auth login`), then a scoped run (a
    /// pick in another repo) before the next full run. The scoped run
    /// recorded the new folder's identity, so the full run read every
    /// conversation the folder lacked as deleted there: old copies went to
    /// the Trash in every folder and recent ones stopped syncing.
    private static func syncRecreatedFolder(_ suite: TestSuite, _ scratch: Scratch) {
        let home = scratch.folder("sync-recreated")
        let configs = ["/.claude", "/.claude-a", "/.claude-b"].map { home + $0 }
        for config in configs { try? FileManager.default.createDirectory(atPath: config + "/projects", withIntermediateDirectories: true) }
        let folders = ClaudeSync.folders(configDirectories: configs)
        let (root, b) = (folders[0], folders[2])
        let statePath = home + "/state/sync.json"
        var trashed: [String] = []
        func run(_ scope: ClaudeSync.Scope) -> ClaudeSync.Report {
            ClaudeSync.reconcile(configDirectories: configs, scope: scope, statePath: statePath,
                                 options: ClaudeSync.Options(trash: { trashed.append($0) }, now: Date(), cleanupDays: 30))
        }
        let recent = "33333333-0000-4000-8000-000000000001"
        let old = "33333333-0000-4000-8000-000000000002"
        let other = "33333333-0000-4000-8000-000000000003"
        func t(_ folder: String, _ slug: String, _ id: String) -> String { folder + "/projects/\(slug)/\(id).jsonl" }
        write(t(root, "-App", recent), "recent\n")
        write(t(root, "-App", old), "old\n")
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 86_400)], ofItemAtPath: t(root, "-App", old))
        _ = run(.all)
        suite.expect(read(t(b, "-App", recent)) == "recent\n" && read(t(b, "-App", old)) == "old\n", "the full run fills every folder")
        try? FileManager.default.removeItem(atPath: b)
        try? FileManager.default.createDirectory(atPath: b + "/projects", withIntermediateDirectories: true)
        write(t(root, "-Other", other), "other\n")
        _ = run(ClaudeSync.Scope(slugs: ["-Other"]))
        let report = run(.all)
        suite.expect(report.trashed.isEmpty && trashed.isEmpty && report.left.isEmpty
                        && read(t(b, "-App", recent)) == "recent\n" && read(t(b, "-App", old)) == "old\n"
                        && read(t(root, "-App", old)) == "old\n" && read(t(b, "-Other", other)) == "other\n",
                     "a folder made again is filled again, even after a scoped run; nothing is read as deleted: \(report)")
    }

    /// The real failure (review of T-38): Claude Code removes sessions/<pid>.json
    /// early in its shutdown and writes the transcript's last rows after, so a
    /// sync on the file's removal cloned the transcript short, and nothing
    /// synced it again. A conversation ends when its process exits.
    private static func syncEndsWithProcess(_ suite: TestSuite, _ scratch: Scratch) {
        var running = ClaudeSync.RunningSessions()
        let x = "44444444-0000-4000-8000-000000000001"
        let y = "44444444-0000-4000-8000-000000000002"
        let pid: Int32 = 4_242
        suite.expect(running.update(live: [pid: x], isAlive: { _ in true }).isEmpty && running.ids == [x],
                     "a session with a pid file runs")
        suite.expect(running.update(live: [:], isAlive: { _ in true }).isEmpty && running.ids == [x],
                     "its pid file gone while its process runs: it has not ended")
        let home = scratch.folder("sync-exit")
        let configs = [home + "/.claude", home + "/.claude-a"]
        for config in configs { try? FileManager.default.createDirectory(atPath: config + "/projects", withIntermediateDirectories: true) }
        let folders = ClaudeSync.folders(configDirectories: configs)
        let statePath = home + "/state/sync.json"
        func run(_ scope: ClaudeSync.Scope) -> ClaudeSync.Report {
            ClaudeSync.reconcile(configDirectories: configs, scope: scope, statePath: statePath,
                                 options: ClaudeSync.Options(trash: { _ in }, now: Date(), running: running.ids))
        }
        let source = folders[1] + "/projects/-App/\(x).jsonl"
        let copy = folders[0] + "/projects/-App/\(x).jsonl"
        write(source, "row 1\n")
        let early = run(.all)
        suite.expect(early.running == 1 && !ClaudeFileIO.exists(copy), "every run counts it as running meanwhile: \(early)")
        write(source, "row 1\nexit rows\n")
        let ended = running.update(live: [:], exited: [pid], isAlive: { _ in true })
        _ = run(ClaudeSync.Scope(sessions: ended))
        suite.expect(ended == [x] && running.ids.isEmpty && read(copy) == "row 1\nexit rows\n",
                     "it ends when its process exits, and is synced with its last rows")
        // /resume inside a session: the file names the new conversation; the
        // one it left ends with the process.
        let other: Int32 = 4_243
        _ = running.update(live: [other: x], isAlive: { _ in true })
        suite.expect(running.update(live: [other: y], isAlive: { _ in true }).isEmpty && running.ids == [x, y],
                     "a conversation left by an in-session /resume runs until its process exits")
        suite.expect(running.update(live: [:], isAlive: { _ in false }) == [x, y] && running.ids.isEmpty,
                     "a process found gone ends every conversation it ran")
    }

    /// ClaudeSync's check-out (T-40, "library checkout"): while a conversation
    /// is open in one account folder, its copies in the others are out of
    /// Claude Code's view (a dot folder Claude Code 2.1.325 never lists), so
    /// no other account's /resume continues an old copy and splits it; when
    /// its process exits they come back, brought up to date.
    private static func syncCheckout(_ suite: TestSuite, _ scratch: Scratch) {
        let home = scratch.folder("checkout")
        let configs = ["/.claude", "/.claude-a", "/.claude-b"].map { home + $0 }
        for config in configs { try? FileManager.default.createDirectory(atPath: config + "/projects", withIntermediateDirectories: true) }
        let linked = home + "/.claude-linked"
        try? FileManager.default.createDirectory(atPath: linked, withIntermediateDirectories: true)
        symlink(configs[0] + "/projects", linked + "/projects")
        let folders = ClaudeSync.folders(configDirectories: configs)
        let (root, a, b) = (folders[0], folders[1], folders[2])
        let statePath = home + "/state/sync.json"
        let me = getpid()
        var trashed: [String] = []
        let trashFolder = scratch.folder("checkout-trash")
        /// Processes treated as gone (they exited).
        var gone = Set<Int32>()
        func run(_ scope: ClaudeSync.Scope = ClaudeSync.Scope(), exited: Set<Int32> = []) -> ClaudeSync.Report {
            ClaudeSync.reconcile(configDirectories: configs + [linked], scope: scope, statePath: statePath,
                                 options: ClaudeSync.Options(isAlive: { pid, _ in !gone.contains(pid) && (pid == me || pid == 4_242) },
                                                             trash: { path in
                                                                 trashed.append(path)
                                                                 try FileManager.default.moveItem(atPath: path, toPath: trashFolder + "/" + UUID().uuidString)
                                                             },
                                                             now: Date(), cleanupDays: 30, exited: exited))
        }
        let cwd = "/tmp/brim-checkout/App"
        let slug = ClaudeSessionIndex.projectSlug(cwd)
        func t(_ folder: String, _ id: String) -> String { folder + "/projects/\(slug)/\(id).jsonl" }
        func held(_ folder: String, _ id: String) -> String { ClaudeSync.heldPath(folder, slug: slug, id: id) }
        func open(_ config: String, _ id: String, pid: Int32 = getpid()) {
            write(config + "/sessions/\(pid).json",
                  #"{"pid":\#(pid),"sessionId":"\#(id)","cwd":"\#(cwd)","startedAt":\#(Int64(Date().timeIntervalSince1970 * 1_000))}"#)
        }
        func end(_ config: String, pid: Int32 = getpid()) { unlink(config + "/sessions/\(pid).json") }
        let x = "55555555-0000-4000-8000-000000000001"
        let z = "55555555-0000-4000-8000-000000000002"
        write(t(a, x), "x1\n")
        write(t(a, z), "z1\n")
        _ = run(.all)
        suite.expect(read(t(root, x)) == "x1\n" && read(t(b, x)) == "x1\n", "every folder holds the conversation to begin with")
        // z went another way on b before it opened on a.
        write(t(b, z), "z1\nz on b\n")
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: t(b, z))
        write(t(a, z), "z1\nz on a\n")
        _ = run(.all)

        // x opens on a: its copies elsewhere go out of view within the run.
        open(configs[1], x)
        var report = run()
        suite.expect(!ClaudeFileIO.exists(t(root, x)) && !ClaudeFileIO.exists(t(b, x)) && read(held(root, x)) == "x1\n"
                        && read(held(b, x)) == "x1\n" && read(t(a, x)) == "x1\n"
                        && Set(report.checkedOut) == [t(root, x), t(b, x)] && report.open[x]?.config == a
                        && report.open[x]?.pid == me
                        && ClaudeSync.openCheckouts(statePath: statePath, isAlive: { pid, _ in pid == me })[x]?.pid == me
                        && mode(root + "/projects/\(slug)/" + ClaudeSync.checkoutFolder) == 0o700,
                     "a conversation open on a is held out of view in the other folders (a rename into a 0700 dot folder): \(report)")
        let record = ClaudeSync.State.load(statePath).checkouts[slug + "/" + x]
        suite.expect(record?.live == a && record?.pid == me && Set(record?.held ?? []) == [root, b],
                     "the check-out is recorded with the process holding it open: \(String(describing: record))")
        // Claude Code lists <slug>/*.jsonl and finds --resume <id> one level
        // under projects/<slug>; every reader of projects/ does the same.
        suite.expect(ClaudeSessionIndex.transcripts(cwd: cwd, configDirectories: [configs[0], configs[2]]).allSatisfy { $0.sessionId != x }
                        && ClaudeSessionIndex.transcript(sessionId: x, cwd: nil, configDirectories: [configs[0], configs[2]]) == nil
                        && ClaudeSessionIndex.transcript(sessionId: x, cwd: cwd, configDirectories: configs)?.path == t(a, x),
                     "the session index never lists a held copy; the open folder's is the conversation")
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3_600)], ofItemAtPath: held(root, x))
        suite.expect(ClaudeMCPRepoList.newestTranscript(in: root + "/projects/\(slug)").map { $0 < Date().addingTimeInterval(1_800) } ?? true,
                     "the MCP page's last use ignores a held copy")
        let usageRoot = AgentLogRoot(provider: .claude, url: AgentLogRoot.canonical(URL(fileURLWithPath: root + "/projects")))
        suite.expect(!usageRoot.accepts(held(root, x)) && usageRoot.accepts(t(root, z))
                        && !AgentLogReader.discover([usageRoot], since: .distantPast).contains { $0.path.contains(ClaudeSync.checkoutFolder) },
                     "usage never reads a held copy")
        suite.expect(ClaudeFileCopy.plan(from: root + "/projects", into: scratch.folder("checkout-tidy"), tag: "t").copies
                        .allSatisfy { !$0.from.contains(ClaudeSync.checkoutFolder) },
                     "tidy up never merges a held copy into the kept account")
        // z diverged: its copy on b is left where it is (the divergence rule
        // takes it); its older copy on root is held.
        open(configs[1], z, pid: 4_242)
        report = run()
        suite.expect(read(t(b, z)) == "z1\nz on b\n" && !ClaudeFileIO.exists(held(b, z)) && ClaudeFileIO.exists(held(root, z))
                        && ClaudeSync.State.load(statePath).checkouts[slug + "/" + z]?.left?[b] != nil,
                     "a copy that went another way stays in view, and is not read again while unchanged: \(report)")
        // Idempotent, and no run syncs it while it is open: not a full run, not
        // one scoped to it (its gaps are never read as deletions or filled).
        write(t(a, x), "x1\nx2\n")
        report = run(.all)
        let scoped = run(ClaudeSync.Scope(sessions: [x]))
        suite.expect(report.checkedOut.isEmpty && report.copied.allSatisfy { !$0.contains(x) } && scoped.copied.isEmpty
                        && report.trashed.isEmpty && !ClaudeFileIO.exists(t(root, x)) && read(held(b, x)) == "x1\n",
                     "while it is open nothing more moves and nothing refills its places: \(report)")

        // An in-session /resume: the session's pid file names y now. y is
        // checked out too; x stays held until the process exits.
        let y = "55555555-0000-4000-8000-000000000003"
        write(t(root, y), "y1\n")
        _ = run(ClaudeSync.Scope(sessions: [y]))
        suite.expect(read(t(a, y)) == "y1\n", "y is everywhere")
        open(configs[1], y)
        report = run()
        suite.expect(!ClaudeFileIO.exists(t(root, y)) && !ClaudeFileIO.exists(t(b, y)) && read(held(b, y)) == "y1\n"
                        && read(held(root, x)) == "x1\n" && report.open.keys.sorted() == [x, y, z].sorted(),
                     "the conversation a /resume switched to is checked out; the one it left stays held while the process runs: \(report)")

        // The pid file is gone (Claude Code removes it early in its shutdown)
        // while the process still writes: still open.
        end(configs[1])
        report = run(.all)
        suite.expect(ClaudeFileIO.exists(held(root, x)) && report.open[x]?.config == a && !ClaudeFileIO.exists(t(root, x)),
                     "a conversation stays checked out until its process exits, not when its pid file goes: \(report)")

        // The process exits: every held copy comes back and takes the newest.
        write(t(a, x), "x1\nx2\nexit rows\n")
        report = run(exited: [me])
        suite.expect(read(t(root, x)) == "x1\nx2\nexit rows\n" && read(t(b, x)) == "x1\nx2\nexit rows\n"
                        && read(t(root, y)) == "y1\n" && read(t(b, y)) == "y1\n"
                        && !ClaudeFileIO.exists(held(root, x)) && !ClaudeFileIO.exists(root + "/projects/\(slug)/" + ClaudeSync.checkoutFolder + "/\(y).jsonl")
                        && ClaudeSync.State.load(statePath).checkouts[slug + "/" + x] == nil && report.open[x] == nil
                        && Set(report.checkedIn).isSuperset(of: [t(root, x), t(b, x), t(root, y), t(b, y)]) && trashed.isEmpty,
                     "when its process exits it is checked in and synced in the same run, the newest copy in every folder: \(report)")
        suite.expect(ClaudeSessionIndex.transcripts(cwd: cwd, configDirectories: [configs[2]]).contains { $0.sessionId == x },
                     "and every account's /resume lists it again")
        report = run()
        suite.expect(report.checkedIn.isEmpty && report.checkedOut.isEmpty && report.copied.isEmpty,
                     "a second run moves nothing: \(report)")
        // z's process still runs: still held on root, b's own version untouched.
        suite.expect(ClaudeFileIO.exists(held(root, z)) && read(t(b, z)) == "z1\nz on b\n", "another open conversation stays as it was")
        gone.insert(4_242)
        end(configs[1], pid: 4_242)
        report = run()
        suite.expect(read(t(root, z)) == "z1\nz on a\n" && read(t(b, z)) == "z1\nz on b\n" && !ClaudeFileIO.exists(held(root, z)),
                     "a process found gone (Brim was not running when it exited) is checked in too; the diverged copy keeps its version: \(report)")
        gone.remove(4_242)

        // Crash safety: the record is written before anything moves. A run
        // that stopped part way (record written, one copy moved) is finished
        // while the session runs, and undone once it ended.
        let w = "55555555-0000-4000-8000-000000000004"
        write(t(a, w), "w1\n")
        _ = run(ClaudeSync.Scope(sessions: [w]))
        var state = ClaudeSync.State.load(statePath)
        state.checkouts[slug + "/" + w] = ClaudeSync.State.Checkout(live: a, pid: me, started: Date().timeIntervalSince1970, held: [root, b])
        try? state.save(statePath)
        try? FileManager.default.createDirectory(atPath: (held(root, w) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        rename(t(root, w), held(root, w))
        open(configs[1], w)
        report = run()
        suite.expect(ClaudeFileIO.exists(held(root, w)) && ClaudeFileIO.exists(held(b, w)) && !ClaudeFileIO.exists(t(b, w)),
                     "a check-out left part way is finished on the next run: \(report)")
        end(configs[1])
        gone.insert(me)
        report = run()
        gone.remove(me)
        suite.expect(read(t(root, w)) == "w1\n" && read(t(b, w)) == "w1\n" && !ClaudeFileIO.exists(held(root, w))
                        && ClaudeSync.State.load(statePath).checkouts.isEmpty,
                     "after a restart, a check-out whose session ended is undone from the state: \(report)")
        // A held copy whose place filled meanwhile: removed when every byte
        // of it is in the copy there, else kept in the Trash.
        let v = "55555555-0000-4000-8000-000000000005"
        write(t(a, v), "v1\n")
        _ = run(ClaudeSync.Scope(sessions: [v]))
        open(configs[1], v)
        _ = run()
        write(t(root, v), "v1\nmore\n")
        write(t(b, v), "something else\n")
        end(configs[1])
        trashed = []
        report = run(exited: [me])
        suite.expect(!ClaudeFileIO.exists(held(root, v)) && !ClaudeFileIO.exists(held(b, v)) && trashed == [held(b, v)]
                        && read(t(root, v)) == "v1\nmore\n" && report.kept.count == 1,
                     "a held prefix of what is there now is removed; a held copy that differs goes to the Trash: \(report)")

        // Open in two folders at once (already split): nothing moves.
        let u = "55555555-0000-4000-8000-000000000006"
        write(t(a, u), "u1\n")
        _ = run(ClaudeSync.Scope(sessions: [u]))
        open(configs[1], u)
        open(configs[2], u, pid: 4_242)
        report = run()
        suite.expect(report.checkedOut.isEmpty && read(t(root, u)) == "u1\n" && ClaudeSync.State.load(statePath).checkouts.isEmpty,
                     "a conversation open in two folders is left to the divergence rule: \(report)")
        end(configs[1])
        end(configs[2], pid: 4_242)
        // A folder still linked to ~/.claude writes into ~/.claude's projects/:
        // a session there holds the other folders' copies.
        open(linked, u)
        report = run()
        suite.expect(ClaudeFileIO.exists(held(a, u)) && ClaudeFileIO.exists(held(b, u)) && read(t(root, u)) == "u1\n"
                        && report.open[u]?.config == ClaudeFileIO.realPath(linked) && ClaudeSync.State.load(statePath).checkouts[slug + "/" + u]?.live == root,
                     "a session on a linked folder is open in the folder its projects/ lands in, and reported on its own account: \(report)")
        end(linked)
        _ = run(exited: [me])

        // brim-claude: a resume or move onto another account never goes on
        // while a check-out holds it, even once its pid file is gone (here
        // the holder is this very process, so exit 3 rather than a wait,
        // T-50); once its process exited, the launch's own sync checks it in.
        let context = makeContext(scratch, "checkout-resume", cwd: cwd)
        let work = context.home + "/.claude-work"
        try? FileManager.default.createDirectory(atPath: work + "/projects", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: context.sharedRoot + "/projects", withIntermediateDirectories: true)
        _ = try? ClaudeAccountsFile(accounts: [ClaudeAccount(label: "rhodesconsulting", folder: "", accountUuid: defaultUuid, signedIn: true),
                                               ClaudeAccount(label: "work", folder: work, accountUuid: sternUuid, signedIn: true)]).save(context.paths)
        let s = "55555555-0000-4000-8000-000000000007"
        write(work + "/projects/\(slug)/\(s).jsonl", "s1\n")
        ClaudeSessionOwners.record(sessionId: s, folder: work, paths: context.paths, now: now)
        _ = ClaudeHelper.pick(["--cwd", cwd], context: context)
        open(work, s)
        _ = ClaudeHelper.pick(["--cwd", cwd], context: context)
        let sharedHeld = ClaudeSync.heldPath(ClaudeFileIO.realPath(context.sharedRoot), slug: slug, id: s)
        suite.expect(ClaudeFileIO.exists(sharedHeld), "a launch's own sync checks out a conversation open on another account")
        end(work)
        let refused = ClaudeHelper.run(["resume", "--cwd", cwd, "--account", "rhodesconsulting", "--id", s], input: { Data() }, context: context)
        let moved = ClaudeHelper.run(["move", s, "--to", "rhodesconsulting", "--cwd", cwd], input: { Data() }, context: context)
        suite.expect(refused.status == ClaudeHelper.MoveStatus.sessionRunning && refused.stderr.contains("(pid \(getpid()) on work)")
                        && moved.status == ClaudeHelper.MoveStatus.sessionRunning && moved.stderr.contains("(pid \(getpid()) on work)")
                        && ClaudeFileIO.exists(sharedHeld)
                        && !ClaudeFileIO.exists(context.sharedRoot + "/projects/\(slug)/\(s).jsonl"),
                     "resume and move refuse a conversation still open elsewhere, its pid file gone: \(refused.stderr)\(moved.stderr)")
        write(work + "/projects/\(slug)/\(s).jsonl", "s1\ns2\n")
        var ended = context
        ended.isAlive = { pid, _ in pid != me }
        let resumed = ClaudeHelper.run(["resume", "--cwd", cwd, "--account", "rhodesconsulting", "--id", s], input: { Data() }, context: ended)
        suite.expect(resumed.status == 0 && resumed.stdout == "\n\n" && !ClaudeFileIO.exists(sharedHeld)
                        && read(context.sharedRoot + "/projects/\(slug)/\(s).jsonl") == "s1\ns2\n",
                     "once its process exited, a resume checks it in (Brim not running) and continues the newest copy: \(resumed.stdout)\(resumed.stderr)")
    }

    /// The check-out's edges (review of Amendment B, 2026-11-14), each a
    /// failure seen in a driver before the fix: a process that exited but is
    /// not yet reaped (its pid file left behind) was checked in and out again
    /// in one run; a conversation open twice in one folder was never checked
    /// out; with one folder left (an account removed from the list) held
    /// copies were never checked in; for a still-linked account, resume
    /// refused to continue a conversation on the account it is open on and
    /// named the default account; uninstalling deleted the check-out records
    /// with copies still held, hiding them from Claude Code for good.
    private static func syncCheckoutEdges(_ suite: TestSuite, _ scratch: Scratch) {
        let home = scratch.folder("checkout-edges")
        let configs = ["/.claude", "/.claude-a", "/.claude-b"].map { home + $0 }
        for config in configs { try? FileManager.default.createDirectory(atPath: config + "/projects", withIntermediateDirectories: true) }
        let folders = ClaudeSync.folders(configDirectories: configs)
        let (root, a, b) = (folders[0], folders[1], folders[2])
        let statePath = home + "/state/sync.json"
        var alive = Set<Int32>()
        var trashed: [String] = []
        func run(_ configDirectories: [String] = configs, exited: Set<Int32> = []) -> ClaudeSync.Report {
            ClaudeSync.reconcile(configDirectories: configDirectories, scope: ClaudeSync.Scope(), statePath: statePath,
                                 options: ClaudeSync.Options(isAlive: { pid, _ in alive.contains(pid) },
                                                             trash: { trashed.append($0) }, now: Date(), cleanupDays: 30, exited: exited))
        }
        let cwd = "/tmp/brim-checkout-edges/App"
        let slug = ClaudeSessionIndex.projectSlug(cwd)
        func t(_ folder: String, _ id: String) -> String { folder + "/projects/\(slug)/\(id).jsonl" }
        func held(_ folder: String, _ id: String) -> String { ClaudeSync.heldPath(folder, slug: slug, id: id) }
        func open(_ config: String, _ id: String, pid: Int32) {
            alive.insert(pid)
            write(config + "/sessions/\(pid).json", #"{"pid":\#(pid),"sessionId":"\#(id)","cwd":"\#(cwd)"}"#)
        }
        func end(_ config: String, pid: Int32) {
            alive.remove(pid)
            unlink(config + "/sessions/\(pid).json")
        }
        func record(_ id: String) -> ClaudeSync.State.Checkout? { ClaudeSync.State.load(statePath).checkouts[slug + "/" + id] }

        // Exited but not yet reaped: the pid still answers and its pid file
        // is still there (Claude Code killed or crashed). The exit run checks
        // it in and syncs it; it never checks it out again.
        let x = "66666666-0000-4000-8000-000000000001"
        write(t(a, x), "x1\n")
        _ = ClaudeSync.reconcile(configDirectories: configs, scope: ClaudeSync.Scope(sessions: [x]), statePath: statePath,
                                 options: ClaudeSync.Options(isAlive: { _, _ in false }, trash: { _ in }))
        open(configs[1], x, pid: 7_001)
        _ = run()
        suite.expect(ClaudeFileIO.exists(held(root, x)) && ClaudeFileIO.exists(held(b, x)), "x is checked out while it is open")
        write(t(a, x), "x1\nexit rows\n")
        var report = run(exited: [7_001])
        suite.expect(read(t(root, x)) == "x1\nexit rows\n" && read(t(b, x)) == "x1\nexit rows\n"
                        && !ClaudeFileIO.exists(held(root, x)) && !ClaudeFileIO.exists(held(b, x))
                        && record(x) == nil && report.checkedOut.isEmpty && report.open[x] == nil,
                     "a process seen to exit is checked in and synced, even while its pid answers and its pid file is left: \(report)")
        end(configs[1], pid: 7_001)

        // Open twice in one folder (two terminals on one account write one
        // file): one conversation, checked out; it stays out until the last
        // of them exits.
        let y = "66666666-0000-4000-8000-000000000002"
        write(t(a, y), "y1\n")
        _ = ClaudeSync.reconcile(configDirectories: configs, scope: ClaudeSync.Scope(sessions: [y]), statePath: statePath,
                                 options: ClaudeSync.Options(isAlive: { _, _ in false }, trash: { _ in }))
        open(configs[1], y, pid: 7_002)
        open(configs[1], y, pid: 7_003)
        report = run()
        suite.expect(ClaudeFileIO.exists(held(root, y)) && ClaudeFileIO.exists(held(b, y)) && !ClaudeFileIO.exists(t(b, y))
                        && report.open[y] != nil,
                     "a conversation open twice in one folder is checked out of the others: \(report)")
        end(configs[1], pid: 7_002)
        report = run(exited: [7_002])
        suite.expect(ClaudeFileIO.exists(held(root, y)) && !ClaudeFileIO.exists(t(b, y)) && record(y)?.pid == 7_003,
                     "one of them exiting leaves it held for the other: \(report)")
        write(t(a, y), "y1\ny2\n")
        end(configs[1], pid: 7_003)
        report = run(exited: [7_003])
        suite.expect(read(t(root, y)) == "y1\ny2\n" && read(t(b, y)) == "y1\ny2\n" && record(y) == nil,
                     "the last one exiting checks it in: \(report)")

        // One folder left: an account removed from the list while a
        // conversation was open on it. Its process exits; the held copies
        // still come back.
        let z = "66666666-0000-4000-8000-000000000003"
        write(t(a, z), "z1\n")
        _ = ClaudeSync.reconcile(configDirectories: configs, scope: ClaudeSync.Scope(sessions: [z]), statePath: statePath,
                                 options: ClaudeSync.Options(isAlive: { _, _ in false }, trash: { _ in }))
        open(configs[1], z, pid: 7_004)
        _ = run()
        suite.expect(ClaudeFileIO.exists(held(root, z)) && ClaudeFileIO.exists(held(b, z)), "z is checked out")
        end(configs[1], pid: 7_004)
        report = run([configs[0]], exited: [7_004])
        suite.expect(read(t(root, z)) == "z1\n" && read(t(b, z)) == "z1\n" && !ClaudeFileIO.exists(held(root, z))
                        && !ClaudeFileIO.exists(held(b, z)) && record(z) == nil && Set(report.checkedIn) == [t(root, z), t(b, z)],
                     "with one folder left, a check-out whose process is gone is still checked in: \(report)")
        report = run([configs[0]])
        suite.expect(report == ClaudeSync.Report() && trashed.isEmpty, "and a later one-folder run does nothing: \(report)")
        // The app's watcher hands every run to ClaudeSync.reconcile, which
        // decides; it returned early with fewer than two folders, so its exit
        // source never checked a held copy in.
        let watcher = read("Sources/Brim/Modules/ClaudeAccounts/App/ClaudeSyncWatcher.swift")
        let watcherRun = watcher.components(separatedBy: "private func reconcile(").dropFirst().first?
            .components(separatedBy: "ClaudeSync.reconcile(").first ?? ""
        suite.expect(!watcherRun.isEmpty && !watcherRun.contains("folders.count") && !watcherRun.contains("return"),
                     "the watcher's run never skips ClaudeSync.reconcile for the number of folders")

        // brim-claude on a still-linked account: its sessions write into
        // ~/.claude's projects/, and the check-out names the account itself.
        let context = makeContext(scratch, "checkout-linked", cwd: cwd)
        let work = context.home + "/.claude-work"
        let linked = context.home + "/.claude-linked"
        try? FileManager.default.createDirectory(atPath: work + "/projects", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: context.sharedRoot + "/projects", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: linked, withIntermediateDirectories: true)
        symlink(context.sharedRoot + "/projects", linked + "/projects")
        _ = try? ClaudeAccountsFile(accounts: [ClaudeAccount(label: "rhodesconsulting", folder: "", accountUuid: defaultUuid, signedIn: true),
                                               ClaudeAccount(label: "work", folder: work, accountUuid: sternUuid, signedIn: true),
                                               ClaudeAccount(label: "linked", folder: linked,
                                                             accountUuid: "00000000-0000-4000-8000-00000000000c", signedIn: true)])
            .save(context.paths)
        let s = "66666666-0000-4000-8000-000000000004"
        write(work + "/projects/\(slug)/\(s).jsonl", "s1\n")
        _ = ClaudeHelper.pick(["--cwd", cwd], context: context)
        let me = getpid()
        write(linked + "/sessions/\(me).json",
              #"{"pid":\#(me),"sessionId":"\#(s)","cwd":"\#(cwd)","startedAt":\#(Int64(Date().timeIntervalSince1970 * 1_000))}"#)
        _ = ClaudeHelper.pick(["--cwd", cwd], context: context)
        let workHeld = ClaudeSync.heldPath(ClaudeFileIO.realPath(work), slug: slug, id: s)
        suite.expect(ClaudeFileIO.exists(workHeld), "a session on the linked account holds work's copy out of view")
        // T-50: a conversation open in another process is not opened a second
        // time, on its own account either (the holder here is this very
        // process: exit 3, where another would be waited on).
        let there = ClaudeHelper.run(["resume", "--cwd", cwd, "--account", "linked", "--id", s], input: { Data() }, context: context)
        suite.expect(there.status == ClaudeHelper.MoveStatus.sessionRunning && there.stdout.isEmpty
                        && there.stderr.contains("(pid \(me) on linked)"),
                     "resume does not open it again on the linked account it is open on: \(there.status) \(there.stdout)\(there.stderr)")
        unlink(linked + "/sessions/\(me).json")
        let thereAgain = ClaudeHelper.run(["resume", "--cwd", cwd, "--account", "linked", "--id", s], input: { Data() }, context: context)
        let elsewhere = ClaudeHelper.run(["resume", "--cwd", cwd, "--account", "work", "--id", s], input: { Data() }, context: context)
        let moved = ClaudeHelper.run(["move", s, "--to", "work", "--cwd", cwd], input: { Data() }, context: context)
        suite.expect(thereAgain.status == ClaudeHelper.MoveStatus.sessionRunning && elsewhere.status == ClaudeHelper.MoveStatus.sessionRunning
                        && elsewhere.stderr.contains("(pid \(me) on linked)")
                        && moved.status == ClaudeHelper.MoveStatus.sessionRunning && moved.stderr.contains("(pid \(me) on linked)"),
                     "with its pid file gone too, the check-out still names the process and the linked account: \(thereAgain.stderr)\(elsewhere.stderr)\(moved.stderr)")
        var exited = context
        exited.isAlive = { pid, _ in pid != me }
        _ = ClaudeHelper.pick(["--cwd", cwd], context: exited)

        // Uninstall: every held copy comes back before the state (and its
        // records) goes, and so does one whose record was lost.
        let uninstallHome = scratch.folder("checkout-uninstall")
        let environment = ["HOME": uninstallHome]
        let paths = ClaudeAccountsPaths(environment: environment, home: uninstallHome)
        let shared = uninstallHome + "/.claude"
        let other = uninstallHome + "/.claude-other"
        for config in [shared, other] { try? FileManager.default.createDirectory(atPath: config + "/projects", withIntermediateDirectories: true) }
        _ = try? ClaudeAccountsFile(accounts: [ClaudeAccount(label: "rhodesconsulting", folder: "", accountUuid: defaultUuid, signedIn: true),
                                               ClaudeAccount(label: "other", folder: other, accountUuid: sternUuid, signedIn: true)])
            .save(paths)
        let both = [shared, other].map(ClaudeFileIO.realPath)
        let c = "66666666-0000-4000-8000-000000000005"
        let d = "66666666-0000-4000-8000-000000000006"
        let e = "66666666-0000-4000-8000-000000000007"
        write(t(both[1], c), "c1\n")
        _ = ClaudeSync.reconcile(configDirectories: [shared, other], scope: .all, statePath: ClaudeSync.statePath(paths),
                                 options: ClaudeSync.Options(isAlive: { _, _ in false }, trash: { _ in }))
        write(other + "/sessions/7005.json", #"{"pid":7005,"sessionId":"\#(c)","cwd":"\#(cwd)"}"#)
        _ = ClaudeSync.reconcile(configDirectories: [shared, other], scope: ClaudeSync.Scope(), statePath: ClaudeSync.statePath(paths),
                                 options: ClaudeSync.Options(isAlive: { pid, _ in pid == 7_005 }, trash: { _ in }))
        write(held(both[0], d), "d1\n")
        write(held(both[1], e), "e1\n")
        write(t(both[1], e), "e1\ne2\n")
        suite.expect(ClaudeFileIO.exists(held(both[0], c)) && !ClaudeFileIO.exists(t(both[0], c))
                        && !ClaudeSync.State.load(ClaudeSync.statePath(paths)).checkouts.isEmpty,
                     "a conversation is checked out before the uninstall")
        let lines = ClaudeInstallsRemoval.uninstall(environment: environment)
        suite.expect(read(t(both[0], c)) == "c1\n" && read(t(both[0], d)) == "d1\n" && read(t(both[1], e)) == "e1\ne2\n"
                        && !ClaudeFileIO.exists(both[0] + "/projects/\(slug)/" + ClaudeSync.checkoutFolder)
                        && !ClaudeFileIO.exists(both[1] + "/projects/\(slug)/" + ClaudeSync.checkoutFolder)
                        && !ClaudeFileIO.exists(paths.stateDirectory),
                     "uninstalling puts every held copy back in view (a prefix of what is there now is removed), then removes the state: \(lines)")
    }

    private static func historyLock(_ suite: TestSuite, _ scratch: Scratch) {
        let file = scratch.folder("lock") + "/history.jsonl"
        write(file, "")
        mkdir(file + ".lock", 0o700)
        let busy = (try? ClaudeHistoryLock.acquire(file, attempts: 2)) == nil
        suite.expect(busy, "a fresh lock held by Claude Code is waited for, then given up")
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: file + ".lock")
        let lock = try? ClaudeHistoryLock.acquire(file, attempts: 2)
        suite.expect(lock != nil && ClaudeFileIO.isDirectory(file + ".lock"), "a stale lock is taken over")
        lock?.release()
        suite.expect(!ClaudeFileIO.exists(file + ".lock"), "releasing removes the lock")
    }

    // MARK: MCP

    private static func mcpMirror(_ suite: TestSuite, _ scratch: Scratch) {
        let canonical = object("""
            {"a":{"type":"http","url":"https://a.example.com/mcp"},
             "b":{"command":"npx","args":["server-b","--two"],"env":{"KEY":"value"}},
             "c":{"type":"stdio","command":"c"}}
            """)
        let current = object("""
            {"a":{"url":"https://a.example.com/mcp","type":"http"},
             "b":{"command":"npx","args":["server-b","--one"],"env":{"KEY":"value"}},
             "d":{"type":"http","url":"https://d.example.com"}}
            """)
        let describe: (String) -> String = { $0.isEmpty ? "rhodes" : $0 }
        let plan = ClaudeMCPMirror.plan(servers: ["": canonical, stern: current], folders: ["", stern], describe: describe)
        suite.expect(plan.commands.map { "\($0.kind) \($0.server)" } == ["remove b", "add b", "add c", "add d"],
                     "a differing server is replaced, a missing one added, an identical one left alone: \(plan.commands.map(\.server))")
        // The real failure: the mirror removed d, which only this folder had,
        // keeping no copy of its configuration. Now it is never removed, and
        // it spreads to the accounts that lack it (the union across accounts).
        suite.expect(!plan.commands.contains { $0.server == "d" && $0.kind == .remove }
                     && plan.commands.last.map { $0.server == "d" && $0.folder.isEmpty } == true,
                     "a server only one folder has is never removed; it is added where it is missing")
        suite.expect(plan.replaced == [stern: ["b": #"{"args":["server-b","--one"],"command":"npx","env":{"KEY":"value"}}"#]],
                     "the folder's own version of each replaced server is kept for its backup")
        suite.expect(plan.lines == ["\(stern): replace b with rhodes's version (its own is saved first; Undo puts it back)",
                                    "\(stern): add c", "rhodes: add d (from \(stern))"]
                     && !plan.lines.joined().contains("value"),
                     "the review names servers, never their configuration: \(plan.lines)")
        suite.expect(plan.commands.first?.arguments == ["mcp", "remove", "-s", "user", "b"]
                     && plan.commands[2].arguments == ["mcp", "add-json", "-s", "user", "c", #"{"command":"c","type":"stdio"}"#],
                     "Claude Code's own CLI does the change, at user scope")
        let environment = plan.commands.first.map {
            ClaudeMCPRun.environment(for: $0, base: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": "/x", "PATH": "/bin"],
                                     home: URL(fileURLWithPath: scratch.folder("mcp-env-home")))
        }
        suite.expect(environment?["CLAUDE_CONFIG_DIR"] == stern && environment?["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil
                     && environment?["PATH"] == "/bin", "each command runs under its folder's launch environment")
        suite.expect(ClaudeMCPMirror.plan(servers: ["": canonical, stern: canonical], folders: ["", stern], describe: describe).isEmpty
                     && ClaudeMCPMirror.plan(servers: ["": canonical], folders: [""], describe: describe).isEmpty,
                     "nothing to do when they match, or with one account")
        suite.expect(ClaudeMCPMirror.servers(configData: Data("{}".utf8))?.isEmpty == true
                     && ClaudeMCPMirror.servers(configData: Data(#"{"mcpServers":{"x":{"type":"http"}}}"#.utf8))?.count == 1
                     && ClaudeMCPMirror.servers(configData: Data("nope".utf8)) == nil, "mcpServers from a .claude.json")

        // The backup, and the undo that puts the folder's own versions back.
        let paths = ClaudeAccountsPaths(stateDirectory: scratch.folder("mcp-state"))
        let files = (try? ClaudeMCPBackup.save(plan.replaced, paths: paths, now: now)) ?? []
        let again = (try? ClaudeMCPBackup.save(plan.replaced, paths: paths, now: now)) ?? []
        suite.expect(files.count == 1 && again.count == 1 && files != again && files.allSatisfy { mode($0) == 0o600 }
                     && mode(paths.mcpBackupsDirectory) == 0o700,
                     "each folder's backup is a 0600 file of its own, never over another")
        let pending = ClaudeMCPBackup.pending(paths)
        suite.expect(pending.count == 2 && pending.first?.backup.servers == plan.replaced[stern], "the backups read back")
        var mirrored = current
        mirrored["b"] = canonical["b"]
        mirrored["c"] = canonical["c"]
        let undo = ClaudeMCPBackup.undoPlan(pending.map(\.backup), current: { $0 == stern ? mirrored : [:] })
        suite.expect(undo.commands.map { "\($0.kind) \($0.server)" } == ["remove b", "add b"]
                     && undo.commands.last?.arguments.last == plan.replaced[stern]?["b"]
                     && undo.lines == ["\(stern): put back its own b"],
                     "the undo replaces the shared version with the folder's own; added servers stay")
        suite.expect(ClaudeMCPBackup.undoPlan(pending.map(\.backup), current: { _ in current }).commands.isEmpty,
                     "nothing to put back once the folder has its own again")
        ClaudeMCPBackup.markRestored(pending.map(\.path))
        suite.expect(ClaudeMCPBackup.pending(paths).isEmpty && files.allSatisfy { ClaudeFileIO.isRegularFile($0 + ".restored") },
                     "a used backup is kept, renamed, and not offered again")
    }

    private static func selftest(_ suite: TestSuite, _ scratch: Scratch) {
        let result = ClaudeHelper.run(["--selftest"], input: { Data() }, context: makeContext(scratch, "selftest"))
        suite.expect(result == .ok("brim-claude: ok"), "the helper's selftest passes: \(result.stderr)")
    }

    // MARK: Shell

    /// Runs the zsh integration with stand-ins for `claude` and `brim-claude`
    /// that only print what they were given.
    private static func shellIntegration(_ suite: TestSuite, _ scratch: Scratch) {
        let template = "Resources/claude.zsh"
        let text = read(template)
        suite.expect(!text.isEmpty, "the zsh integration is in the tree")
        suite.expect(runProcess("/bin/zsh", ["-n", template]).status == 0, "zsh -n accepts it")
        suite.expect(!text.contains("CLAUDE_SECURESTORAGE_CONFIG_DIR=") && !text.contains("CLAUDE_CONFIG_DIR=\"$HOME/.claude\"")
                     && !text.contains("CLAUDE_CONFIG_DIR=~/.claude") && !text.contains("security "),
                     "it never sets the secure-storage folder, never names ~/.claude and never touches the keychain")
        let launches = text.components(separatedBy: "\n").filter { $0.contains("command env") }
        suite.expect(launches.count == 3 && launches.allSatisfy { $0.contains("-u CLAUDE_SECURESTORAGE_CONFIG_DIR") },
                     "every launch removes CLAUDE_SECURESTORAGE_CONFIG_DIR")

        let bin = scratch.folder("shell-bin")
        write(bin + "/claude", """
            #!/bin/sh
            echo "CONFIG=${CLAUDE_CONFIG_DIR-<unset>} SECURE=${CLAUDE_SECURESTORAGE_CONFIG_DIR-<unset>} ARGS=$*"

            """)
        let log = scratch.folder("shell-log") + "/calls"
        write(bin + "/brim-claude", """
            #!/bin/sh
            [ -n "$BRIM_TEST_LOG" ] && echo "$*" >> "$BRIM_TEST_LOG"
            case "$1" in
              pick) if [ "$2" = "--account" ]; then [ "$3" = "work" ] && echo "/tmp/My Work" && exit 0
                      [ -n "$BRIM_TEST_FOLDER" ] && [ "$3" = "$BRIM_TEST_FOLDER" ] && echo "$3" && exit 0; exit 2; fi
                    echo "$BRIM_TEST_PICK";;
              move) printf '%s\\n%s\\n' "$BRIM_TEST_MOVE_DIR" "abc-123";;
              account-name) [ "$2" = "work" ] && { echo work; exit 0; }; exit 1;;
              resume) [ -n "$BRIM_TEST_RESUME_FAIL" ] && { echo "brim-claude: refused" >&2; exit "$BRIM_TEST_RESUME_FAIL"; }
                      printf '%s\\n%s\\n' "$BRIM_TEST_RESUME_DIR" "$BRIM_TEST_RESUME_SID";;
            esac

            """)
        write(bin + "/cc", """
            #!/bin/sh
            echo "COMPILER ARGS=$*"

            """)
        chmod(bin + "/claude", 0o755)
        chmod(bin + "/brim-claude", 0o755)
        chmod(bin + "/cc", 0o755)
        func zsh(_ command: String, _ extra: [String: String] = [:]) -> String {
            var environment = ["PATH": bin + ":/usr/bin:/bin", "HOME": scratch.folder("shell-home"),
                               "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/secure"]
            environment.merge(extra) { _, new in new }
            return runProcess("/bin/zsh", ["-f", "-c", "source \(template); \(command)"], environment: environment).stdout
        }
        suite.expect(zsh("claude --model fable 'a b'", ["BRIM_TEST_PICK": ""]) == "CONFIG=<unset> SECURE=<unset> ARGS=--model fable a b\n",
                     "claude on the default account runs with both variables removed")
        suite.expect(zsh("claude x", ["BRIM_TEST_PICK": "/tmp/.claude-work"]) == "CONFIG=/tmp/.claude-work SECURE=<unset> ARGS=x\n",
                     "claude on another account gets its folder")
        suite.expect(zsh("claude x", ["CLAUDE_CONFIG_DIR": "/tmp/direnv"]) == "CONFIG=/tmp/direnv SECURE=<unset> ARGS=x\n",
                     "a CLAUDE_CONFIG_DIR already set wins")
        suite.expect(zsh("PATH=\(bin)/none:/usr/bin:/bin; claude x") == "",
                     "without brim-claude or claude on PATH nothing runs")
        suite.expect(zsh("cc work y") == "CONFIG=/tmp/My Work SECURE=<unset> ARGS=y\n", "cc starts on the named account")
        suite.expect(zsh("claude mcp add x", ["BRIM_TEST_PICK": "/tmp/.claude-work"]) == "CONFIG=<unset> SECURE=<unset> ARGS=mcp add x\n"
                     && zsh("claude auth logout", ["BRIM_TEST_PICK": "/tmp/.claude-work"]) == "CONFIG=<unset> SECURE=<unset> ARGS=auth logout\n"
                     && zsh("cc work mcp list") == "CONFIG=/tmp/My Work SECURE=<unset> ARGS=mcp list\n",
                     "management subcommands stay on the default account unless cc names one")
        suite.expect(zsh("cc nobody y; echo status=$?") == "status=2\n", "cc fails for an unknown account")
        // Review fix: two labels that differ only in case are named by folder,
        // but `cc <existing folder>` ran the C compiler. A folder goes to
        // brim-claude; an existing regular file still goes to the compiler.
        let accountFolder = scratch.folder("shell-account-folder")
        let source = scratch.folder("shell-source") + "/x.c"
        write(source, "int main(void) { return 0; }\n")
        suite.expect(zsh("cc '\(accountFolder)' y", ["BRIM_TEST_FOLDER": accountFolder]) == "CONFIG=\(accountFolder) SECURE=<unset> ARGS=y\n"
                        && zsh("cc '\(source)'") == "COMPILER ARGS=\(source)\n",
                     "cc <folder> starts on that account; cc <file> is the compiler")
        // The real failure: Claude Code's shell snapshot carries these
        // functions into its Bash tool, where `claude -p` was re-routed.
        suite.expect(zsh("claude -p hi", ["CLAUDECODE": "1", "BRIM_TEST_PICK": "/tmp/.claude-work"])
                        == "CONFIG=<unset> SECURE=<unset> ARGS=-p hi\n"
                     && zsh("claude -p hi", ["CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CONFIG_DIR": "/tmp/.claude-own",
                                             "BRIM_TEST_PICK": ""]) == "CONFIG=/tmp/.claude-own SECURE=<unset> ARGS=-p hi\n",
                     "inside a Claude Code session, claude stays on the session's account")
        suite.expect(zsh("cc work y", ["CLAUDECODE": "1"]) == "COMPILER ARGS=work y\n" && zsh("cc -c x.c") == "COMPILER ARGS=-c x.c\n",
                     "inside a session cc is the compiler, as it is outside for an option")
        suite.expect(zsh("cx", ["BRIM_TEST_MOVE_DIR": ""]) == "CONFIG=<unset> SECURE=<unset> ARGS=--resume abc-123\n"
                     && zsh("cx", ["BRIM_TEST_MOVE_DIR": "/tmp/.claude-work"])
                        == "CONFIG=/tmp/.claude-work SECURE=<unset> ARGS=--resume abc-123\n",
                     "cx resumes the conversation on the target by its own id, the default account with CLAUDE_CONFIG_DIR removed")

        // Resuming: the wrapper asks brim-claude where (it syncs the
        // conversation there first) and passes the arguments on unchanged.
        func calls(_ command: String, _ extra: [String: String]) -> (output: String, calls: [String]) {
            try? FileManager.default.removeItem(atPath: log)
            let output = zsh(command, extra.merging(["BRIM_TEST_LOG": log]) { a, _ in a })
            return (output, read(log).split(separator: "\n").map(String.init))
        }
        let work = ["BRIM_TEST_RESUME_DIR": "/tmp/.claude-work", "BRIM_TEST_RESUME_SID": ""]
        let home = ["BRIM_TEST_RESUME_DIR": "", "BRIM_TEST_RESUME_SID": ""]
        let short = calls("claude -r abc-123 --model fable 'a b'", work)
        suite.expect(short.output == "CONFIG=/tmp/.claude-work SECURE=<unset> ARGS=-r abc-123 --model fable a b\n"
                        && short.calls.count == 1 && short.calls[0].hasPrefix("resume --cwd ")
                        && short.calls[0].hasSuffix(" --id abc-123 --model fable"),
                     "-r <id>: a plain resume where brim-claude says, every argument as given: \(short)")
        let long = calls("claude --resume abc-123 -p hi", home)
        suite.expect(long.output == "CONFIG=<unset> SECURE=<unset> ARGS=--resume abc-123 -p hi\n"
                        && !long.output.contains("fork"),
                     "--resume <id> on the default account, never a fork: \(long)")
        let equals = calls("claude --resume=abc-123", work)
        suite.expect(equals.output == "CONFIG=/tmp/.claude-work SECURE=<unset> ARGS=--resume=abc-123\n"
                        && equals.calls.first?.hasSuffix(" --id abc-123") == true,
                     "--resume=<id> too: \(equals)")
        let cont = calls("claude -c --verbose", work)
        let named = calls("claude --verbose -c 'x y'", work.merging(["BRIM_TEST_RESUME_SID": "abc-123"]) { _, new in new })
        suite.expect(cont.output == "CONFIG=/tmp/.claude-work SECURE=<unset> ARGS=-c --verbose\n"
                        && cont.calls.first?.hasSuffix(" --continue") == true
                        && named.output == "CONFIG=/tmp/.claude-work SECURE=<unset> ARGS=--verbose --resume abc-123 x y\n",
                     "-c stays -c, unless brim-claude names the conversation, which takes its place: \(cont) \(named)")
        let picker = calls("claude --resume", work)
        let search = calls("claude -r 'login bug'", home)
        suite.expect(picker.output == "CONFIG=/tmp/.claude-work SECURE=<unset> ARGS=--resume\n"
                        && picker.calls.first?.hasSuffix(" --picker") == true
                        && search.output == "CONFIG=<unset> SECURE=<unset> ARGS=-r login bug\n",
                     "a bare --resume (the picker) and a search term run as given on the account brim-claude names: \(picker) \(search)")
        let fresh = calls("claude x", ["BRIM_TEST_PICK": "/tmp/.claude-work"])
        suite.expect(fresh.output == "CONFIG=/tmp/.claude-work SECURE=<unset> ARGS=x\n" && fresh.calls.count == 2
                        && fresh.calls[0] == "account-name x" && fresh.calls[1].hasPrefix("pick --cwd "),
                     "without a resume target, claude checks a lone argument is no account's name, then picks: \(fresh)")
        // The real failure (T-50): `claude sparkfx.ai` started a conversation
        // whose first prompt was "sparkfx.ai".
        let mistyped = calls("claude work 2>&1; echo status=$?", ["BRIM_TEST_PICK": "/tmp/.claude-work"])
        suite.expect(mistyped.output.hasPrefix("claude: did you mean cc work? \"work\" is a Claude account's name, so Claude Code did not start.\n")
                        && mistyped.output.contains("(To send it to Claude Code as a prompt: claude -- work)") && mistyped.output.hasSuffix("status=2\n")
                        && !mistyped.output.contains("ARGS=") && mistyped.calls == ["account-name work"],
                     "an account's name as the only argument asks \"did you mean cc <account>?\" and starts nothing: \(mistyped)")
        // Review fix: the hint was `command claude work`, which skips the
        // wrapper: no pick, and CLAUDE_SECURESTORAGE_CONFIG_DIR reached Claude
        // Code. `claude -- work` sends the word on the account Brim picks.
        let dashed = calls("claude -- work", ["BRIM_TEST_PICK": "/tmp/.claude-work"])
        suite.expect(dashed.output == "CONFIG=/tmp/.claude-work SECURE=<unset> ARGS=-- work\n"
                        && dashed.calls.count == 1 && dashed.calls[0].hasPrefix("pick --cwd ")
                        && zsh("claude work --verbose", ["BRIM_TEST_PICK": ""]) == "CONFIG=<unset> SECURE=<unset> ARGS=work --verbose\n"
                        && zsh("claude work", ["CLAUDECODE": "1"]) == "CONFIG=<unset> SECURE=<unset> ARGS=work\n",
                     "claude -- <name> sends it as a prompt through the wrapper; with more arguments, or inside a session, it is not checked: \(dashed)")
        let afterDashes = calls("claude -p x -- -c", ["BRIM_TEST_PICK": ""])
        suite.expect(afterDashes.output == "CONFIG=<unset> SECURE=<unset> ARGS=-p x -- -c\n" && afterDashes.calls.first?.hasPrefix("pick") == true,
                     "nothing after -- is read: \(afterDashes)")
        let account = calls("cc work -r abc-123 y", work)
        suite.expect(account.output == "CONFIG=/tmp/.claude-work SECURE=<unset> ARGS=-r abc-123 y\n"
                        && account.calls.first?.hasSuffix(" --id abc-123 --account work") == true,
                     "cc <account> with a resume target asks for that account: \(account)")
        let pinned = calls("claude -c", work.merging(["CLAUDE_CONFIG_DIR": "/tmp/direnv"]) { a, _ in a })
        suite.expect(pinned.output == "CONFIG=/tmp/direnv SECURE=<unset> ARGS=-c\n"
                        && pinned.calls.first?.hasSuffix(" --continue --folder /tmp/direnv") == true,
                     "a CLAUDE_CONFIG_DIR already set stays the folder, and brim-claude syncs into it: \(pinned)")
        let failed = calls("claude -r abc-123; echo status=$?", work.merging(["BRIM_TEST_RESUME_FAIL": "3"]) { a, _ in a })
        suite.expect(failed.output == "status=3\n", "a refused resume runs nothing and passes brim-claude's status on: \(failed)")
        suite.expect(calls("claude mcp list -c", work).output == "CONFIG=<unset> SECURE=<unset> ARGS=mcp list -c\n"
                        && calls("claude -p hi -c", work.merging(["CLAUDECODE": "1"]) { a, _ in a }).output
                            == "CONFIG=<unset> SECURE=<unset> ARGS=-p hi -c\n",
                     "management subcommands and claude inside a session are never routed")
    }

    // MARK: Build

    private static func buildContract(_ suite: TestSuite) {
        let build = read("build.sh").components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        suite.expect(build.filter { $0.contains("brim_add_claude_helper \"$STAGE\"") }.count == 1,
                     "build.sh stages the Claude helper with one hook line")
        suite.expect(build.contains { $0.trimmingCharacters(in: .whitespaces) == "Sources/Brim/Modules/ClaudeAccounts/*.swift" },
                     "the test binary compiles the Claude accounts core")
        suite.expect(build.contains { $0.contains("BRIM_CLAUDE_HELPER_ID=\"$APP_BUNDLE_ID.claude-helper\"") }
                     && build.contains { $0.contains("\"build/$BRIM_CLAUDE_HELPER\" --selftest") }
                     && build.contains { $0.contains("Sources/BrimClaude/main.swift") }
                     && build.contains { $0.contains("$bundle/Contents/Helpers/$BRIM_CLAUDE_HELPER") },
                     "build.sh compiles brim-claude, runs its selftest and stages it in Contents/Helpers")
        guard let start = build.firstIndex(where: { $0.hasPrefix("codesign_app()") }),
              let end = build[start...].firstIndex(where: { $0 == "}" }) else {
            suite.expect(false, "build.sh defines codesign_app")
            return
        }
        let body = Array(build[start ... end])
        let helper = body.firstIndex { $0.contains("codesign_claude_helper") }
        let app = body.firstIndex { $0.contains("brim_codesign \"$1\" --entitlements") }
        suite.expect(helper != nil && app != nil && helper! < app!, "codesign_app signs the helper inside the bundle first")
        suite.expect(build.contains { $0.contains("brim_codesign \"$1\" --identifier \"$BRIM_CLAUDE_HELPER_ID\"") },
                     "the helper is signed with Brim's identity, hardened runtime and its own identifier")
        suite.expect(build.contains { $0.contains("\"${BUILD_VARIANT_FLAGS[@]}\" -module-name BrimClaude") },
                     "the helper is built for the app's variant, so both keep their state in the same folder")
        let guardLine = build.firstIndex { $0.contains("brim_refuse_foreign_bundle \"/Applications/$APP_NAME.app\" || exit 1") }
        let stopLine = build.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "stop_process \"$EXECUTABLE\"" }
        suite.expect(guardLine != nil && stopLine != nil && guardLine! < stopLine!
                     && read("Tools/uninstall.sh").contains("brim_refuse_foreign_bundle \"$APP\" || exit 1"),
                     "--install and the uninstaller refuse an app of the same name with another bundle ID before stopping or removing it")
    }

    /// The core must stay Foundation-only, credential-free, process-free,
    /// network-free and timer-free: the helper compiles it into every session.
    private static func sourceRules(_ suite: TestSuite) {
        let folder = "Sources/Brim/Modules/ClaudeAccounts"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".swift") }
        suite.expect(names.count >= 8, "the Claude accounts sources are in the tree (\(names.count))")
        for name in names + ["../../../BrimClaude/main.swift"] {
            let code = read(folder + "/" + name).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            suite.expect(!code.isEmpty, "\(name) reads back")
            for forbidden in ["import AppKit", "import SwiftUI", "import Combine", "SecItem", "kSecClass", "Process(", "NSTask",
                              "posix_spawn", "URLSession", "Timer", "asyncAfter", "/usr/bin/security",
                              "CLAUDE_SECURESTORAGE_CONFIG_DIR\"] = ", "[secureStorageVariable] = "] {
                suite.expect(!code.contains(forbidden), "\(name) never uses \(forbidden)")
            }
        }
    }

    // MARK: Helpers

    /// A temporary folder for the run, removed at the end.
    final class Scratch {
        let root: String

        init() {
            let base = ClaudeFileIO.realPath(NSTemporaryDirectory())
            root = base + "/brim-claude-tests-" + UUID().uuidString
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        }

        func folder(_ name: String) -> String {
            let path = root + "/" + name
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    private static func write(_ path: String, _ text: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private static func object(_ json: String) -> [String: Any] {
        ClaudeJSON.parse(Data(json.utf8)) as? [String: Any] ?? [:]
    }

    private static func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private static func mode(_ path: String) -> Int {
        var info = stat()
        return stat(path, &info) == 0 ? Int(info.st_mode & 0o777) : -1
    }

    private static func runProcess(_ executable: String, _ arguments: [String],
                                   environment: [String: String]? = nil) -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
