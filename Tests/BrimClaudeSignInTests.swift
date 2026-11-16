// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// The account list and Brim's own sign-in (ClaudeAccountList, ClaudeSignIn,
/// ClaudeSignInRun, ClaudeTidyUp, brim-claude's browser mode). Everything
/// runs in temporary folders with stand-ins for `claude` and the browser: no
/// real Claude Code folder, Brim state, browser, keychain item or `claude` is
/// touched, and no sign-in starts.
///
/// The fixture is the real case with made-up ids: ~/.claude, ~/.claude-stern
/// and ~/.claude-rhodesconsulting all signed in to one account
/// (elliot@elliotgrayco.me in one organization), before and after the person
/// adds elliot@rhodesconsultingllc.com.
enum BrimClaudeSignInTests {
    static func run(_ suite: TestSuite) {
        let scratch = BrimClaudeAccountsTests.Scratch()
        defer { scratch.remove() }
        emails(suite)
        links(suite)
        environment(suite)
        privateWindows(suite)
        outcomes(suite)
        accountList(suite, scratch)
        followsEmail(suite, scratch)
        duplicates(suite, scratch)
        appSupport(suite)
        browserMode(suite, scratch)
        sweep(suite, scratch)
        runner(suite, scratch)
        tidyUp(suite, scratch)
        sources(suite)
    }

    static let uuid = "00000000-0000-4000-8000-0000000000a1"
    static let organization = "00000000-0000-4000-8000-0000000000f1"
    static let personal = "elliot@elliotgrayco.me"
    static let business = "elliot@rhodesconsultingllc.com"

    static func config(_ email: String, uuid: String = uuid) -> String {
        """
        {"numStartups":3,"oauthAccount":{"accountUuid":"\(uuid)","emailAddress":"\(email)",
         "organizationUuid":"\(organization)","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x"}}
        """
    }

    // MARK: Pure parts

    private static func emails(_ suite: TestSuite) {
        suite.expect(ClaudeAccountList.normalizedEmail("  Elliot@RhodesConsultingLLC.com ") == business
                        && ClaudeAccountList.normalizedEmail("mailto:" + business) == business
                        && ClaudeAccountList.normalizedEmail("Elliot Rhodes <\(business)>") == business,
                     "an email is taken as typed or pasted: spaces, case, mailto: and a name around it")
        suite.expect(ClaudeAccountList.normalizedEmail("elliot") == nil && ClaudeAccountList.normalizedEmail("a@b") == nil
                        && ClaudeAccountList.normalizedEmail("a b@c.com") == nil && ClaudeAccountList.normalizedEmail("a@@c.com") == nil
                        && ClaudeAccountList.normalizedEmail("a@c..com") == nil && ClaudeAccountList.normalizedEmail("") == nil,
                     "anything that is not one address is refused")
        suite.expect(ClaudeAccountList.sameEmail(" Elliot@ElliotGrayCo.me", personal) && !ClaudeAccountList.sameEmail(personal, business)
                        && !ClaudeAccountList.sameEmail(nil, personal) && !ClaudeAccountList.sameEmail("", ""),
                     "emails compare ignoring case and spaces")
        let label = { (email: String) in ClaudeAccountsDiscovery.label(email: email, folder: "", taken: []) }
        suite.expect(label(business) == "rhodesconsultingllc" && label(personal) == "elliotgrayco.me"
                        && label("pat@proton.me") == "pat" && label("pat@gmail.com") == "pat" && label("pat@icloud.com") == "pat"
                        && label("pat@me.com") == "pat" && label("pat@outlook.com") == "pat" && label("pat@hotmail.com") == "pat"
                        && label("pat@yahoo.com") == "pat" && label("pat@protonmail.com") == "pat",
                     "an account is named from its email's domain, or the part before the @ for a common provider")
    }

    private static func links(_ suite: TestSuite) {
        let real = "https://claude.com/cai/oauth/authorize?code=true&client_id=x&response_type=code"
            + "&redirect_uri=http%3A%2F%2Flocalhost%3A62194%2Fcallback&code_challenge_method=S256&state=s&login_hint=a%40b.com"
        suite.expect(ClaudeSignIn.acceptedLink(real) != nil && ClaudeSignIn.acceptedLink("https://claude.ai/oauth") != nil
                        && ClaudeSignIn.acceptedLink("https://console.anthropic.com/oauth") != nil
                        && ClaudeSignIn.acceptedLink("HTTPS://CLAUDE.COM/x") != nil,
                     "Claude Code's sign-in links are accepted (claude.com, claude.ai, a subdomain of anthropic.com)")
        for bad in ["http://claude.com/x", "https://evil.example/x", "https://claude.com.evil.example/x",
                    "https://claude.com@evil.example/x", "https://user:pw@claude.com/x", "https://claude.com:8443/x",
                    "https://anthropic.com/x", "https://xanthropic.com/x", "https://claude.com/x y", "https://claude.com/x\n",
                    "file:///etc/passwd", "javascript:alert(1)", "https://claude.com/" + String(repeating: "a", count: 9_000),
                    "https://cl\u{430}ude.com/x", ""] {
            suite.expect(ClaudeSignIn.acceptedLink(bad) == nil, "a link Brim does not open is refused: \(bad.prefix(60))")
        }
        suite.expect(ClaudeSignIn.looksLikeLink("https://x") && ClaudeSignIn.looksLikeLink("HTTP://x")
                        && !ClaudeSignIn.looksLikeLink("statusline") && !ClaudeSignIn.looksLikeLink("pick"),
                     "brim-claude takes a link as its browser mode, a word as a subcommand")
    }

    private static func environment(_ suite: TestSuite) {
        let base = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/Users/x/.claude", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/s",
                    "BROWSER": "/usr/bin/open", "HOME": "/Users/x"]
        let helper = "/Applications/Brim.app/Contents/Helpers/brim-claude"
        let file = "/Users/x/.config/brim/claude/signin/" + String(repeating: "a", count: 32) + ".url"
        let inDefault = ClaudeSignIn.environment(folder: "", base: base, helper: helper, urlFile: file)
        suite.expect(inDefault["CLAUDE_CONFIG_DIR"] == nil && inDefault["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil
                        && inDefault["BROWSER"] == helper && inDefault["BRIM_SIGNIN_URL_FILE"] == file && inDefault["PATH"] == "/usr/bin:/bin",
                     "a sign-in in the default folder runs with CLAUDE_CONFIG_DIR and the secure-storage folder removed, brim-claude as BROWSER")
        let other = ClaudeSignIn.environment(folder: "/Users/x/.claude-rhodesconsulting", base: base, helper: helper, urlFile: file)
        suite.expect(other["CLAUDE_CONFIG_DIR"] == "/Users/x/.claude-rhodesconsulting" && other["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil
                        && other["BROWSER"] == helper,
                     "a sign-in in another folder gets its exact folder string")
        suite.expect(ClaudeSignIn.arguments(email: business) == ["auth", "login", "--claudeai", "--email", business],
                     "Brim runs claude auth login --claudeai --email <the expected email>")
        // The app's own environment for Claude Code keeps no foreign token
        // or folder, and the sign-in adds only its browser and link file.
        let app = AgentClaudeServer.environment(base.merging(["ANTHROPIC_API_KEY": "k", "CLAUDE_CODE_OAUTH_TOKEN": "t"]) { a, _ in a },
                                                home: URL(fileURLWithPath: "/Users/x"), folder: "")
        let child = ClaudeSignIn.environment(folder: "", base: app, helper: helper, urlFile: file)
        suite.expect(child["ANTHROPIC_API_KEY"] == nil && child["CLAUDE_CODE_OAUTH_TOKEN"] == nil && child["CLAUDE_CONFIG_DIR"] == nil
                        && child["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil && child["BROWSER"] == helper,
                     "the login child never inherits a token or another account's folder")
    }

    private static func privateWindows(_ suite: TestSuite) {
        let cases: [(String, String?)] = [
            ("com.google.Chrome", "--incognito"), ("com.google.Chrome.canary", "--incognito"), ("com.brave.Browser", "--incognito"),
            ("org.chromium.Chromium", "--incognito"), ("com.vivaldi.Vivaldi", "--incognito"), ("com.microsoft.edgemac", "--inprivate"),
            ("org.mozilla.firefox", "--private-window"), ("org.mozilla.firefoxdeveloperedition", "--private-window"),
            ("com.apple.Safari", nil), ("company.thebrowser.Browser", nil), ("com.example.unknown", nil),
        ]
        for (bundle, flag) in cases {
            suite.expect(ClaudeSignIn.privateWindowFlag(bundleIdentifier: bundle) == flag,
                         "\(bundle) opens a private window with \(flag ?? "no flag (the sheet asks to copy the link)")")
        }
        suite.expect(ClaudeSignIn.privateWindowFlag(bundleIdentifier: nil) == nil, "an unknown browser gets the copy-link step")
        let link = URL(string: "https://claude.com/cai/oauth/authorize?x=1")!
        suite.expect(ClaudeSignIn.openTool == "/usr/bin/open"
                        && ClaudeSignIn.openArguments(app: "/Applications/Google Chrome.app", flag: "--incognito", link: link)
                            == ["-na", "/Applications/Google Chrome.app", "--args", "--incognito", link.absoluteString],
                     "the window opens with open -na <app> --args <flag> <link>")
    }

    private static func outcomes(_ suite: TestSuite) {
        let snapshot = { (email: String) in ClaudeUsageDecoding.snapshot(configData: Data(config(email).utf8)) }
        suite.expect(ClaudeSignIn.outcome(expected: business, snapshot: snapshot("Elliot@RhodesConsultingLLC.com")) == .rightAccount,
                     "the expected email, in any case, is the right account")
        // The real failure: the default browser was signed in to claude.ai as
        // elliotgrayco.me, so the business folder was approved as that.
        suite.expect(ClaudeSignIn.outcome(expected: business, snapshot: snapshot(personal)) == .otherAccount(personal),
                     "a sign-in that came back as another email is caught")
        suite.expect(ClaudeSignIn.outcome(expected: business, snapshot: ClaudeUsageDecoding.snapshot(configData: Data(#"{"numStartups":1}"#.utf8))) == .notSignedIn
                        && ClaudeSignIn.outcome(expected: business, snapshot: nil) == .notSignedIn,
                     "a folder left without an account is not signed in")
        let output = "\u{1B}[2mOpening browser to sign in…\u{1B}[0m\nIf the browser didn't open, visit: https://claude.com/cai/oauth/authorize?state=secret\n"
            + "Paste code here if prompted > \nOAuth error: timeout of 15000ms exceeded\n"
        let text = ClaudeSignIn.errorText(output)
        suite.expect(text == "OAuth error: timeout of 15000ms exceeded" && !(text ?? "").contains("http") && !(text ?? "").contains("\u{1B}"),
                     "the error text is Claude Code's last words, without its prompts, terminal codes or the link: \(text ?? "nil")")
        suite.expect(ClaudeSignIn.errorText("If the browser didn't open, visit: https://claude.com/x\n") == nil
                        && (ClaudeSignIn.errorText(String(repeating: "x", count: 500))?.count ?? 0) <= 240,
                     "routine output is no error text, and a long one is cut")
        // The real shape (Claude Code 2.1.325): the link as an OSC-8
        // hyperlink, the paste prompt with no newline after it, and the
        // error from stderr, which shares the pipe, on the prompt's line.
        let url = "https://claude.com/cai/oauth/authorize?state=secret"
        let real = "Opening browser to sign in\u{2026}\n"
            + "If the browser didn't open, visit: \u{1B}]8;;\(url)\u{1B}\\\(url)\u{1B}]8;;\u{1B}\\\n"
            + "Paste code here if prompted > Login failed: Request failed with status code 403\n"
        let said = ClaudeSignIn.errorText(real)
        suite.expect(said == "Login failed: Request failed with status code 403",
                     "Claude Code's error after the paste prompt, on the same line, is kept: \(said ?? "nil")")
        suite.expect(ClaudeSignIn.errorText("Paste code here if prompted > \n") == nil
                        && ClaudeSignIn.errorText("Paste code here if prompted > Login failed: X\nRun with --debug\n") == "Login failed: X Run with --debug",
                     "the prompt alone is no error text; a hint after the error stays with it")
    }

    // MARK: The list

    private static func accountList(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let home = scratch.folder("list-home")
        let stern = home + "/.claude-stern"
        let rhodes = home + "/.claude-rhodesconsulting"
        write(home + "/.claude.json", config(personal))
        write(stern + "/.claude.json", config(personal))
        write(rhodes + "/.claude.json", config(personal))
        let launchable = ClaudeAccountsDiscovery.launchable(home: home)
        let scan = ClaudeAccountsDiscovery.scan(home: home, listed: [])
        var accounts = ClaudeAccountList.expect(ClaudeAccountsDiscovery.merge(stored: [], discovered: scan.discovered, states: scan.states),
                                                launchable: launchable)
        suite.expect(accounts.map(\.folder) == ["", rhodes, stern]
                        && accounts.map(\.expectedEmail) == [personal, nil, nil],
                     "the first run lists every email found signed in, once, on the default folder: \(accounts.map(\.expectedEmail))")
        var entries = ClaudeAccountList.entries(accounts, launchable: launchable)
        suite.expect(entries.count == 1 && entries[0].status == .signedIn && entries[0].folder == ""
                        && entries[0].duplicates.map(\.folder) == [rhodes, stern],
                     "elliotgrayco.me is signed in, and the two other folders on it are its duplicates")
        suite.expect(ClaudeAccountList.expect(accounts, launchable: launchable) == accounts,
                     "filling the list again changes nothing")

        // Adding an email the list has, or that a folder holds, does nothing.
        let candidates = ClaudeAccountsDiscovery.candidateFolders(home: home)
        func plan(_ email: String, chosen: String? = nil) -> Result<ClaudeAccountList.AddPlan, ClaudeAccountList.AddProblem> {
            ClaudeAccountList.planAdd(email: email, chosenFolder: chosen, accounts: accounts, candidates: candidates,
                                      states: scan.states, home: home)
        }
        suite.expect(plan("Elliot@ElliotGrayCo.me") == .failure(.alreadyListed("elliotgrayco.me")) && plan("nope") == .failure(.invalidEmail),
                     "an email already in the list, or not an email, is refused")
        var unlisted = accounts
        unlisted[0].expectedEmail = nil
        suite.expect(ClaudeAccountList.planAdd(email: personal, chosenFolder: nil, accounts: unlisted, candidates: candidates,
                                               states: scan.states, home: home) == .failure(.alreadySignedIn(folder: "")),
                     "an email a folder already holds says where, and does nothing else")

        // The business email reuses ~/.claude-rhodesconsulting: its name
        // matches and it only holds a duplicate.
        let added = plan(" Elliot@RhodesConsultingLLC.com ")
        suite.expect(added == .success(ClaudeAccountList.AddPlan(email: business, label: "rhodesconsultingllc", folder: rhodes, reuses: true)),
                     "the new account reuses the free folder whose name matches its label: \(added)")
        suite.expect((try? plan("pat@example.org").get())?.folder == home + "/.claude-example.org"
                        && (try? plan("pat@example.org").get())?.reuses == false,
                     "with no free folder of that name, a new ~/.claude-<label> is planned")
        suite.expect((try? plan(business, chosen: home + "/.claude/").get())?.folder == nil
                        && plan(business, chosen: home + "/.claude/") == .failure(.folderTaken("elliotgrayco.me")),
                     "the default folder chosen by its path is the default folder, which is elliotgrayco.me's")
        suite.expect(plan(business, chosen: stern) == .success(ClaudeAccountList.AddPlan(email: business, label: "rhodesconsultingllc",
                                                                                         folder: stern, reuses: true))
                        && plan(business, chosen: "relative/path") == .failure(.folder("the folder must be an absolute path")),
                     "a chosen folder is used when it is free, and refused when it cannot be an account's")
        // A folder holding an account of its own is never reused.
        let other = home + "/.claude-rhodesconsulting-old"
        write(other + "/.claude.json", config("someone@else.example", uuid: "00000000-0000-4000-8000-0000000000b2"))
        let otherState = ["": scan.states[""]!, other: ClaudeAccountsDiscovery.state(folder: other, home: home)]
        suite.expect(!ClaudeAccountList.isFree(other, accounts: accounts, states: otherState)
                        && ClaudeAccountList.isFree(rhodes, accounts: accounts, states: scan.states)
                        && ClaudeAccountList.isFree(home + "/.claude-empty", accounts: accounts, states: [home + "/.claude-empty": .missing])
                        && !ClaudeAccountList.isFree(rhodes, accounts: accounts, states: [rhodes: .unreadable]),
                     "a free folder is empty, signed out or a duplicate; one holding its own account, or unread, is not")
        try? FileManager.default.removeItem(atPath: other)
        suite.expect(ClaudeAccountList.reusableFolder(label: "rhodes", accounts: accounts, candidates: candidates, states: scan.states) == rhodes
                        && ClaudeAccountList.reusableFolder(label: "rob", accounts: accounts, candidates: candidates, states: scan.states) == nil
                        && ClaudeAccountList.reusableFolder(label: "stern", accounts: accounts, candidates: candidates, states: scan.states) == stern
                        && ClaudeAccountList.reusableFolder(label: "work", accounts: accounts, candidates: candidates, states: scan.states) == nil,
                     "a name matches exactly, or one starts with the other from four letters on")

        // After adding: the folder is the business account's, holding the
        // personal one until the person signs in there.
        let index = accounts.firstIndex { $0.folder == rhodes }!
        accounts[index].expectedEmail = business
        accounts[index].label = "rhodesconsultingllc"
        entries = ClaudeAccountList.entries(accounts, launchable: launchable)
        suite.expect(entries.map(\.label) == ["elliotgrayco.me", "rhodesconsultingllc"]
                        && entries[0].status == .signedIn && entries[0].duplicates.map(\.folder) == [stern]
                        && entries[1].status == .wrongAccount(holds: personal) && entries[1].duplicates.isEmpty,
                     "elliotgrayco.me with ~/.claude-stern as its duplicate; rhodesconsultingllc holds elliotgrayco.me")
        suite.expect(accounts[index].holdsWrongAccount && !accounts[0].holdsWrongAccount && ClaudeAccountList.status(accounts[2]) == nil,
                     "only the business folder holds the wrong account; stern is no account's")
        let groups = ClaudeAccountsDiscovery.groups(accounts, launchable: launchable)
        suite.expect(groups.count == 1 && groups[0].primary.isDefault && ClaudeAccountsDiscovery.launchProblem(accounts[index], home: home) != nil,
                     "work on the personal account still launches in the default folder, never in the business folder")
        var signedOut = accounts
        signedOut[index].signedIn = false
        suite.expect(ClaudeAccountList.status(signedOut[index]) == .notSignedIn && !signedOut[index].holdsWrongAccount,
                     "a signed-out folder is not signed in")
        var fixed = accounts
        fixed[index].email = business
        fixed[index].accountUuid = "00000000-0000-4000-8000-0000000000c3"
        suite.expect(ClaudeAccountList.entries(fixed, launchable: launchable).map(\.status) == [.signedIn, .signedIn],
                     "once the business folder holds its email, both accounts are signed in")
        suite.expect(ClaudeAccountList.expect(accounts, launchable: launchable) == accounts,
                     "a folder holding the wrong account keeps the email expected there")

        // The list's lines: the signed-in account's ranked row, then the
        // account waiting for its sign-in.
        let ranks = ClaudeAccountRanking.rank(accounts, readings: [:], model: nil, now: BrimClaudeAccountsTests.now, launchable: launchable)
        let rows = ranks.enumerated().map { position, rank in
            ClaudeAccountRow(rank: rank, position: position, liveSessions: 0, checking: false, failure: nil, launchProblem: nil, mcpNeedsLogin: [])
        }
        let items = ClaudeAccountsAppSupport.items(rows: rows, entries: entries)
        suite.expect(items.count == 2 && items[0].entry?.label == "elliotgrayco.me" && items[0].row?.account.isDefault == true
                        && items[1].entry?.label == "rhodesconsultingllc" && items[1].row == nil,
                     "the panel lists elliotgrayco.me with its limits, then rhodesconsultingllc waiting for its sign-in")

        // accounts.json keeps the list and the answer to the question.
        let paths = ClaudeAccountsPaths(stateDirectory: home + "/.config/brim/claude")
        let file = ClaudeAccountsFile(accounts: accounts, othersAsked: true)
        _ = try? file.save(paths)
        suite.expect(ClaudeAccountsFile.load(paths) == file && read(paths.accountsFile).contains("\"expectedEmail\" : \"\(business)\""),
                     "the expected emails and the answer are saved in accounts.json")
        suite.expect((try? ClaudeJSON.decoder().decode(ClaudeAccountsFile.self, from: Data(#"{"accounts":[]}"#.utf8)))?.othersAsked == false,
                     "an accounts.json from before asks the question")

        // brim-claude: `cc rhodesconsultingllc` never starts the personal
        // account under the business name; the status line in that folder
        // names the account it runs on.
        let context = ClaudeHelperContext(environment: ["HOME": home, "NO_COLOR": "1", "CLAUDE_CONFIG_DIR": rhodes], home: home, paths: paths,
                                          now: BrimClaudeAccountsTests.now, currentDirectory: "/tmp", isAlive: { _, _ in false })
        let picked = ClaudeHelper.pick(["--account", "rhodesconsultingllc"], context: context)
        suite.expect(picked.status == 2 && picked.stdout.isEmpty && picked.stderr.contains("signed in to another account"),
                     "picking the business account while its folder holds the personal one is refused: \(picked)")
        suite.expect(ClaudeHelper.pick(["--account", "elliotgrayco.me"], context: context) == .ok("") && ClaudeHelper.pick([], context: context) == .ok(""),
                     "the personal account and new sessions still launch in the default folder")
        let line = ClaudeHelper.statusline(input: Data(#"{"session_id":"s"}"#.utf8), context: context).result.stdout
        suite.expect(line == "elliotgrayco.me\n", "the status line in the business folder names the account it runs on: \(line)")
        suite.expect(ClaudeHelper.resolve(context: context).stdout.contains("PROBLEM (rhodesconsultingllc): its folder is signed in to another account"),
                     "resolve says why the business folder is never picked")
    }

    // MARK: Labels follow the expected email (T-17)

    /// accounts.json from before the list named each folder after what it
    /// held then. The list names an account after its email; a duplicate
    /// runs as its account, and its old name names nothing.
    private static func followsEmail(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let home = scratch.folder("follows-home")
        let stern = home + "/.claude-stern"
        let rhodes = home + "/.claude-rhodesconsulting"
        for path in [home + "/.claude.json", stern + "/.claude.json", rhodes + "/.claude.json"] { write(path, config(personal)) }
        let launchable = ClaudeAccountsDiscovery.launchable(home: home)
        let stored = [ClaudeAccount(label: "default", folder: ""), ClaudeAccount(label: "oldwork", folder: stern),
                      ClaudeAccount(label: "elliotgrayco.me", folder: rhodes)]
        let scan = ClaudeAccountsDiscovery.scan(home: home, listed: stored.map(\.folder))
        let accounts = ClaudeAccountList.expect(ClaudeAccountsDiscovery.merge(stored: stored, discovered: scan.discovered, states: scan.states),
                                                launchable: launchable)
        suite.expect(accounts.map(\.label) == ["elliotgrayco.me", "oldwork", "rhodesconsulting"]
                        && accounts.map(\.expectedEmail) == [personal, nil, nil],
                     "the folder expected to hold an email is named after it, and a duplicate gives that name up: \(accounts.map(\.label))")
        suite.expect(ClaudeAccountList.expect(accounts, launchable: launchable) == accounts, "naming is done once")
        let paths = ClaudeAccountsPaths(stateDirectory: home + "/.config/brim/claude")
        _ = try? ClaudeAccountsFile(accounts: accounts, othersAsked: true).save(paths)
        func context(_ folder: String?) -> ClaudeHelperContext {
            var environment = ["HOME": home, "NO_COLOR": "1"]
            environment["CLAUDE_CONFIG_DIR"] = folder
            return ClaudeHelperContext(environment: environment, home: home, paths: paths, now: BrimClaudeAccountsTests.now,
                                       currentDirectory: "/tmp", isAlive: { _, _ in false })
        }
        let line = ClaudeHelper.statusline(input: Data(#"{"session_id":"s"}"#.utf8), context: context(stern)).result.stdout
        suite.expect(line == "elliotgrayco.me\n",
                     "a session in a duplicate folder shows the account it runs on, never the folder's old name: \(line)")
        let old = ClaudeHelper.pick(["--account", "oldwork"], context: context(nil))
        suite.expect(old.status == 2 && old.stdout.isEmpty
                        && old.stderr.hasSuffix("Use one of these names exactly:\n  elliotgrayco.me  (default: ~/.claude)\n")
                        && !old.stderr.contains("rhodesconsulting"),
                     "a duplicate's old name starts nothing, and only the list's names are offered: \(old)")
        suite.expect(ClaudeHelper.pick(["--account", "elliotgrayco.me"], context: context(nil)) == .ok("")
                        && ClaudeHelper.pick(["--account", stern], context: context(nil)) == .ok(""),
                     "the account's name, or the duplicate's exact folder, starts the account in its own folder")

        // A folder holding an email no folder is expected to hold runs
        // under a name from that email, never its folder's.
        let third = home + "/.claude-third"
        let thirdUuid = "00000000-0000-4000-8000-0000000000d4"
        write(third + "/.claude.json", config("pat@thirdco.com", uuid: thirdUuid))
        var held = accounts
        held.append(ClaudeAccount(label: "rhodesconsultingllc", folder: third, accountUuid: thirdUuid, organizationUuid: organization,
                                  email: "pat@thirdco.com", signedIn: true, expectedEmail: business))
        _ = try? ClaudeAccountsFile(accounts: held, othersAsked: true).save(paths)
        let thirdLine = ClaudeHelper.statusline(input: Data("{}".utf8), context: context(third)).result.stdout
        suite.expect(thirdLine == "thirdco\n", "a folder holding an unlisted email runs under that email's name: \(thirdLine)")
        suite.expect(ClaudeAccountList.shortName(email: personal) == "elliotgrayco.me"
                        && ClaudeAccountList.shortName(email: " Pat@Gmail.com") == "pat@gmail.com"
                        && FeatureStrings.claudeAccounts(.enUS).holds(ClaudeAccountList.shortName(email: personal)) == "Holds elliotgrayco.me",
                     "Holds names the email held (its domain, or the address for webmail), never a stored label")

        // The run that fills the list while ~/.claude.json cannot be read
        // puts the account on another folder; once it can be read, the
        // account moves to the default folder, which is never a duplicate.
        let race = scratch.folder("race-home")
        let raceStern = race + "/.claude-stern"
        let raceRhodes = race + "/.claude-rhodesconsulting"
        write(race + "/.claude.json", "{")
        write(raceStern + "/.claude.json", config(personal))
        write(raceRhodes + "/.claude.json", config(personal))
        let raceLaunchable = ClaudeAccountsDiscovery.launchable(home: race)
        let first = ClaudeAccountsDiscovery.scan(home: race, listed: [])
        let early = ClaudeAccountList.expect(ClaudeAccountsDiscovery.merge(stored: [], discovered: first.discovered, states: first.states),
                                             launchable: raceLaunchable)
        suite.expect(first.states[""] == .unreadable && early.first { $0.folder == raceStern }?.expectedEmail == personal,
                     "with ~/.claude.json unreadable, the first fill puts the account on ~/.claude-stern")
        write(race + "/.claude.json", config(personal))
        let second = ClaudeAccountsDiscovery.scan(home: race, listed: early.map(\.folder))
        let settled = ClaudeAccountList.expect(ClaudeAccountsDiscovery.merge(stored: early, discovered: second.discovered,
                                                                             states: second.states), launchable: raceLaunchable)
        let raceEntries = ClaudeAccountList.entries(settled, launchable: raceLaunchable)
        suite.expect(raceEntries.count == 1 && raceEntries[0].folder == "" && raceEntries[0].label == "elliotgrayco.me"
                        && Set(raceEntries[0].duplicates.map(\.folder)) == [raceStern, raceRhodes]
                        && settled.first { $0.folder == raceStern }?.label == "stern",
                     "once it can be read, the account moves to the default folder and the others are its duplicates: \(raceEntries.map(\.folder))")
        suite.expect(ClaudeTidyUp.plan(keep: raceEntries[0].account, duplicates: raceEntries[0].duplicates, home: race,
                                       isAlive: { _, _ in false }).canRun,
                     "so Tidy up can remove them")
    }

    // MARK: Duplicates

    private static func duplicates(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let home = scratch.folder("dup-home")
        let team = home + "/.claude-team"
        let teamOrganization = "00000000-0000-4000-8000-0000000000f2"
        write(home + "/.claude.json", config(personal))
        write(team + "/.claude.json", config(personal).replacingOccurrences(of: organization, with: teamOrganization))
        let launchable = ClaudeAccountsDiscovery.launchable(home: home)
        let scan = ClaudeAccountsDiscovery.scan(home: home, listed: [])
        let accounts = ClaudeAccountList.expect(ClaudeAccountsDiscovery.merge(stored: [], discovered: scan.discovered, states: scan.states),
                                                launchable: launchable)
        suite.expect(accounts.first { $0.folder == team }?.expectedEmail == nil
                        && !ClaudeAccountList.isFree(team, accounts: accounts, states: scan.states)
                        && ClaudeAccountList.reusableFolder(label: "team", accounts: accounts, candidates: [team], states: scan.states) == nil,
                     "the same email in another organization is another Claude account: its folder is never taken for a new one")

        // The business account's folder leads its group, before a shorter
        // duplicate: launches, checks and Tidy up use it.
        let rc = home + "/.claude-rc"
        let rhodes = home + "/.claude-rhodesconsulting"
        let businessUuid = "00000000-0000-4000-8000-0000000000c3"
        for folder in [rc, rhodes] { write(folder + "/.claude.json", config(business, uuid: businessUuid)) }
        var listed = accounts
        listed.append(ClaudeAccount(label: "rhodesconsultingllc", folder: rhodes, expectedEmail: business))
        let rescan = ClaudeAccountsDiscovery.scan(home: home, listed: listed.map(\.folder))
        let merged = ClaudeAccountList.expect(ClaudeAccountsDiscovery.merge(stored: listed, discovered: rescan.discovered,
                                                                            states: rescan.states), launchable: launchable)
        let group = ClaudeAccountsDiscovery.group(of: ClaudeAccountKey.key(forFolder: rc), in: merged, launchable: launchable)
        suite.expect(group?.members.map(\.folder) == [rhodes, rc],
                     "the folder the list expects to hold an account leads its group: \(group?.members.map(\.folder) ?? [])")
        let entry = ClaudeAccountList.entries(merged, launchable: launchable).first { $0.email == business }
        suite.expect(entry?.folder == rhodes && entry?.duplicates.map(\.folder) == [rc], "~/.claude-rc is the business account's duplicate")
        let paths = ClaudeAccountsPaths(stateDirectory: home + "/.config/brim/claude")
        _ = try? ClaudeAccountsFile(accounts: merged, othersAsked: true).save(paths)
        let context = ClaudeHelperContext(environment: ["HOME": home, "NO_COLOR": "1", "CLAUDE_CONFIG_DIR": rc], home: home, paths: paths,
                                          now: BrimClaudeAccountsTests.now, currentDirectory: "/tmp", isAlive: { _, _ in false })
        suite.expect(ClaudeHelper.pick(["--account", "rhodesconsultingllc"], context: context) == .ok(rhodes),
                     "cc rhodesconsultingllc starts in the account's own folder, never in its duplicate")
        let line = ClaudeHelper.statusline(input: Data("{}".utf8), context: context).result.stdout
        suite.expect(line == "rhodesconsultingllc\n", "a session in the duplicate runs as the business account: \(line)")
    }

    // MARK: The app's decisions

    private static func appSupport(_ suite: TestSuite) {
        let account = ClaudeAccount(label: "elliotgrayco.me", folder: "", accountUuid: uuid, organizationUuid: organization,
                                    email: personal, signedIn: true, expectedEmail: personal)
        let rank = ClaudeAccountRanking.rank([account], readings: [:], model: nil, now: BrimClaudeAccountsTests.now, launchable: { _ in true })[0]
        func row(_ failure: AgentClaudeServer.Failure?) -> ClaudeAccountRow {
            ClaudeAccountRow(rank: rank, position: 0, liveSessions: 0, checking: false, failure: failure, launchProblem: nil, mcpNeedsLogin: [])
        }
        let entry = ClaudeAccountList.entries([account], launchable: { _ in true })[0]
        suite.expect(!ClaudeAccountsAppSupport.offersSignIn(ClaudeAccountItem(entry: entry, row: row(nil)))
                        && !ClaudeAccountsAppSupport.offersSignIn(ClaudeAccountItem(entry: entry, row: row(.unreachable)))
                        && ClaudeAccountsAppSupport.offersSignIn(ClaudeAccountItem(entry: entry, row: row(.needsSignIn))),
                     "a signed-in account (the default folder's) offers Sign in only once its check says the sign-in stopped working")
        var waiting = account
        waiting.folder = "/x/.claude-rhodesconsulting"
        waiting.expectedEmail = business
        let wrong = ClaudeAccountList.entries([waiting], launchable: { _ in true })[0]
        suite.expect(wrong.status == .wrongAccount(holds: personal) && ClaudeAccountsAppSupport.offersSignIn(ClaudeAccountItem(entry: wrong, row: nil))
                        && !ClaudeAccountsAppSupport.offersSignIn(ClaudeAccountItem(entry: nil, row: row(nil))),
                     "a folder holding the wrong account offers Sign in; a ranked folder that is no account's does not")

        // The accounts window never swaps its view while a sheet may be up:
        // a sign-in's sheet ends its sign-in as it closes.
        suite.expect(ClaudeAccountsAppSupport.windowShow(onScreen: false, sheetUp: false, signingIn: true) == .keep
                        && ClaudeAccountsAppSupport.windowShow(onScreen: false, sheetUp: true, signingIn: false) == .keep
                        && ClaudeAccountsAppSupport.windowShow(onScreen: true, sheetUp: false, signingIn: false) == .keep
                        && ClaudeAccountsAppSupport.windowShow(onScreen: false, sheetUp: false, signingIn: false) == .rebuild,
                     "showing the window during a sign-in brings it forward as it is; only a closed, idle window gets a new view")

        // Sessions running on the folder are named in the sheet, whatever
        // the folder.
        let session = ClaudeLiveSession(pid: 4242, sessionId: "s", cwd: "/x/Code/App", status: "busy", kind: nil, startedAt: nil,
                                        configDirectory: waiting.folder)
        var state = ClaudeSignInState(accountID: waiting.id, label: "rhodesconsultingllc", email: business, folder: waiting.folder)
        suite.expect(state.liveSessions.isEmpty && !state.isDefaultFolder, "a sign-in starts with no sessions named")
        state.liveSessions = [ClaudeSessionIndex.describe(session)]
        let text = FeatureStrings.claudeAccounts(.enUS)
        suite.expect(text.liveSessionsWarning(state.liveSessions.joined(separator: "; "))
                        == "Sessions running in this folder switch to this account: pid 4242 in /x/Code/App (busy).",
                     "the sheet names the sessions that switch account: \(text.liveSessionsWarning(state.liveSessions[0]))")
        suite.expect(text.stepSignInThere(business) == "Sign in there as \(business)" && !text.stepSignInThereFormat.contains("filled"),
                     "step 2 does not claim the page fills the email in (T-23)")
        suite.expect(ClaudeFileError.posix("make /x/signin private", EACCES).message == "Could not make /x/signin private: Permission denied."
                        && ClaudeFileError.message(ClaudeFileError.posix("open /x", 0)) == "Could not open /x.",
                     "a file error reads as a sentence, not as Swift's description of it")
    }

    // MARK: brim-claude browser mode

    private static func browserMode(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let state = scratch.folder("browser-state")
        let directory = state + "/signin"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory, 0o700)
        let token = ClaudeSignIn.newToken()
        let file = ClaudeSignIn.urlFile(directory: directory, token: token)
        let link = "https://claude.com/cai/oauth/authorize?code=true&state=abc&login_hint=elliot%40rhodesconsultingllc.com"
        func context(_ environment: [String: String]) -> ClaudeHelperContext {
            ClaudeHelperContext(environment: environment, home: scratch.folder("browser-home"), paths: ClaudeAccountsPaths(stateDirectory: state),
                                now: BrimClaudeAccountsTests.now, currentDirectory: "/tmp", isAlive: { _, _ in false })
        }
        suite.expect(token.count == 32 && ClaudeSignIn.isToken(Substring(token)) && token != ClaudeSignIn.newToken(),
                     "each sign-in has its own random token")
        let written = ClaudeHelper.run([link], input: { Data() }, context: context(["BRIM_SIGNIN_URL_FILE": file]))
        suite.expect(written == ClaudeHelperResult(status: 0, stdout: "", stderr: "") && read(file) == link,
                     "Claude Code's `$BROWSER <link>` hands the link to Brim, exactly, and prints nothing: \(written)")
        suite.expect(mode(file) == 0o600, "the link file is mode 0600")
        unlink(file)
        let refused = ClaudeHelper.run(["https://evil.example/x?state=abc"], input: { Data() }, context: context(["BRIM_SIGNIN_URL_FILE": file]))
        suite.expect(refused.status == 0 && !ClaudeFileIO.exists(file) && ClaudeFileIO.isRegularFile(ClaudeSignIn.refusedFile(forURLFile: file))
                        && !refused.stderr.contains("evil") && !read(ClaudeSignIn.refusedFile(forURLFile: file)).contains("evil"),
                     "another link is refused: no link file, a marker without the link, and exit 0 so no other opener runs")
        unlink(ClaudeSignIn.refusedFile(forURLFile: file))
        let alone = ClaudeHelper.run([link], input: { Data() }, context: context([:]))
        suite.expect(alone.status == 2 && !alone.stderr.contains("claude.com") && !ClaudeFileIO.exists(file),
                     "without a sign-in waiting, the link goes nowhere and is not printed")
        for wrong in [state + "/" + token + ".url", directory + "/notatoken.url", directory + "/" + token + ".txt",
                      directory + "/../signin/" + token + ".url", "relative/signin/" + token + ".url"] {
            let result = ClaudeHelper.run([link], input: { Data() }, context: context(["BRIM_SIGNIN_URL_FILE": wrong]))
            suite.expect(result.status == 2 && !ClaudeFileIO.exists(wrong), "brim-claude writes a link nowhere but <state>/signin/<token>.url: \(wrong)")
        }
        chmod(directory, 0o755)
        let open = ClaudeHelper.run([link], input: { Data() }, context: context(["BRIM_SIGNIN_URL_FILE": file]))
        suite.expect(open.status == 2 && !ClaudeFileIO.exists(file), "nor into a sign-in folder others can open")
        chmod(directory, 0o700)
        suite.expect(ClaudeHelper.run([link, "extra"], input: { Data() }, context: context(["BRIM_SIGNIN_URL_FILE": file])).status == 1
                        && !ClaudeFileIO.exists(file),
                     "browser mode is exactly one argument")
        let usage = ClaudeHelper.run(["--help"], input: { Data() }, context: context([:])).stdout
        suite.expect(usage.contains("brim-claude <https link>"), "the usage names browser mode")
    }

    private static func sweep(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let directory = scratch.folder("sweep/signin")
        let token = ClaudeSignIn.newToken()
        write(directory + "/" + token + ".url", "https://claude.com/x")
        write(directory + "/" + token + ".refused", "refused\n")
        write(directory + "/." + token + ".url.123.456.tmp", "https://claude.com/x")
        write(directory + "/keep.json", "{}")
        suite.expect(ClaudeSignIn.sweep(directory: directory) == 3
                        && ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []) == ["keep.json"],
                     "the links and markers a sign-in left are swept when the app starts, and nothing else")
        suite.expect(ClaudeSignIn.sweep(directory: scratch.root + "/none") == 0, "a missing sign-in folder sweeps nothing")
        let paths = ClaudeAccountsPaths(stateDirectory: "/s")
        suite.expect(paths.signInDirectory == "/s/signin", "sign-in links live in <state>/signin")
    }

    // MARK: The login child

    /// Stand-ins: a `claude` that records what it got, calls $BROWSER like
    /// Claude Code, then waits or exits; a browser that writes the link the
    /// way brim-claude does (a file in the folder, renamed into place).
    private static func runner(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let bin = scratch.folder("runner-bin")
        let claude = bin + "/claude"
        write(claude, """
            #!/bin/sh
            printf '%s\\n' "$$" "CONFIG=${CLAUDE_CONFIG_DIR-<unset>}" "SECURE=${CLAUDE_SECURESTORAGE_CONFIG_DIR-<unset>}" "ARGS=$*" > "$REPORT"
            if read line; then echo "STDIN=$line" >> "$REPORT"; else echo "STDIN=none" >> "$REPORT"; fi
            "$BROWSER" "$LINK"
            [ -n "$HOLD" ] && exec /bin/sleep 30
            [ -n "$CONFIG" ] && printf '%s' "$CONFIG" > "$CONFIG_FILE"
            echo "If the browser didn't open, visit: $LINK"
            [ -n "$SAY" ] && echo "$SAY"
            exit ${CODE:-0}

            """)
        write(bin + "/browser", """
            #!/bin/sh
            printf '%s' "$1" > "$BRIM_SIGNIN_URL_FILE.part" && /bin/mv "$BRIM_SIGNIN_URL_FILE.part" "$BRIM_SIGNIN_URL_FILE"

            """)
        chmod(claude, 0o755)
        chmod(bin + "/browser", 0o755)
        let link = "https://claude.com/cai/oauth/authorize?state=abc&login_hint=elliot%40rhodesconsultingllc.com"
        let directory = scratch.root + "/runner-state/signin"

        final class Events: @unchecked Sendable {
            let lock = NSLock()
            var list: [ClaudeSignInRun.Event] = []
            let linked = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            func add(_ event: ClaudeSignInRun.Event) {
                lock.withLock { list.append(event) }
                if case .finished = event { finished.signal() } else { linked.signal() }
            }
            var all: [ClaudeSignInRun.Event] { lock.withLock { list } }
        }

        func start(_ extra: [String: String], folder: String = "") -> (ClaudeSignInRun, Events, String) {
            let report = scratch.root + "/runner-report-\(UUID().uuidString)"
            let file = ClaudeSignIn.urlFile(directory: directory, token: ClaudeSignIn.newToken())
            let base = ["PATH": "/usr/bin:/bin", "REPORT": report, "LINK": link, "CLAUDE_CONFIG_DIR": "/elsewhere",
                        "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/secure"].merging(extra) { _, new in new }
            let environment = ClaudeSignIn.environment(folder: folder, base: base, helper: bin + "/browser", urlFile: file)
            let events = Events()
            let run = ClaudeSignInRun(executable: claude, arguments: ClaudeSignIn.arguments(email: business), environment: environment,
                                      urlFile: file, timeout: 20) { events.add($0) }
            do {
                try run.start()
            } catch {
                suite.expect(false, "the sign-in starts: \(error)")
            }
            return (run, events, report)
        }

        // A sign-in that finishes: the link arrives, the file goes, the exit comes.
        let configFile = scratch.root + "/runner-folder/.claude.json"
        try? FileManager.default.createDirectory(atPath: scratch.root + "/runner-folder", withIntermediateDirectories: true)
        let (_, done, report) = start(["CONFIG": config(business), "CONFIG_FILE": configFile])
        let linkArrived = done.linked.wait(timeout: .now() + 10) == .success
        let finished = done.finished.wait(timeout: .now() + 10) == .success
        let lines = read(report).components(separatedBy: "\n")
        suite.expect(linkArrived && finished && done.all.first == .link(URL(string: link)!),
                     "the link Claude Code gives its browser reaches Brim through the watched folder: \(done.all)")
        suite.expect(lines.contains("CONFIG=<unset>") && lines.contains("SECURE=<unset>")
                        && lines.contains("ARGS=auth login --claudeai --email \(business)") && lines.contains("STDIN=none"),
                     "the child runs on the default folder with CLAUDE_CONFIG_DIR unset, no secure-storage folder, and stdin from /dev/null: \(lines)")
        if case .finished(let exit)? = done.all.last {
            suite.expect(exit.status == 0 && !exit.timedOut && !exit.cancelled && exit.output.contains("If the browser didn't open"),
                         "the exit and Claude Code's output come back for the check")
        } else {
            suite.expect(false, "the sign-in finishes: \(done.all)")
        }
        suite.expect(((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).isEmpty && mode(directory) == 0o700,
                     "no link file is left behind, in a 0700 folder")
        suite.expect(ClaudeSignIn.outcome(expected: business, snapshot: ClaudeUsageDecoding.snapshot(configFile: configFile)) == .rightAccount,
                     "the folder it signed in is checked by its email")

        // A sign-in that fails says why, in Claude Code's words without the link.
        let (_, failing, _) = start(["CODE": "3", "SAY": "OAuth error: access denied"])
        _ = failing.finished.wait(timeout: .now() + 10)
        if case .finished(let exit)? = failing.all.last {
            suite.expect(exit.status == 3 && ClaudeSignIn.errorText(exit.output) == "OAuth error: access denied",
                         "a failed sign-in comes back with its exit and plain words: \(exit.status)")
        } else {
            suite.expect(false, "the failing sign-in finishes")
        }

        // Cancel ends Brim's own child only.
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["30"]
        try? bystander.run()
        let (run, held, heldReport) = start(["HOLD": "1"], folder: scratch.root + "/runner-folder")
        _ = held.linked.wait(timeout: .now() + 10)
        let childPid = Int32(read(heldReport).components(separatedBy: "\n").first ?? "") ?? 0
        let heldLines = read(heldReport).components(separatedBy: "\n")
        suite.expect(childPid > 0 && kill(childPid, 0) == 0 && heldLines.contains("CONFIG=\(scratch.root)/runner-folder"),
                     "the held sign-in runs on its folder's exact path")
        run.cancel()
        let ended = held.finished.wait(timeout: .now() + 10) == .success
        let childGone = kill(childPid, 0) == -1 && errno == ESRCH
        suite.expect(ended && childGone && bystander.isRunning,
                     "Cancel ends Brim's login child and nothing else (the bystander still runs)")
        if case .finished(let exit)? = held.all.last {
            suite.expect(exit.cancelled, "the end of a cancelled sign-in is marked cancelled")
        }
        suite.expect(((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).isEmpty,
                     "Cancel deletes the link file")
        bystander.terminate()
        bystander.waitUntilExit()

        // A link the stand-in browser writes that Brim does not open.
        let (refusedRun, refused, _) = start(["LINK": "https://evil.example/x", "HOLD": "1"])
        let refusal = refused.linked.wait(timeout: .now() + 10) == .success
        suite.expect(refusal && refused.all.first == .refused, "a link Brim does not open is reported as refused, never opened")
        refusedRun.cancel()
        _ = refused.finished.wait(timeout: .now() + 10)
    }

    // MARK: Tidy up

    private static func tidyUp(_ suite: TestSuite, _ scratch: BrimClaudeAccountsTests.Scratch) {
        let home = scratch.folder("tidy-home")
        let root = home + "/.claude"
        let stern = home + "/.claude-stern"
        write(home + "/.claude.json", config(personal))
        write(stern + "/.claude.json", config(personal))
        let slug = ClaudeSessionIndex.projectSlug("/tmp/brim-tidy/App")
        write(root + "/projects/\(slug)/shared.jsonl", "{\"a\":1}\n")
        write(root + "/history.jsonl", #"{"display":"one","timestamp":1}"# + "\n")
        write(stern + "/projects/\(slug)/stern-only.jsonl", "{\"b\":2}\n")
        write(stern + "/projects/\(slug)/shared.jsonl", "{\"a\":1}\n")
        write(stern + "/history.jsonl", #"{"display":"one","timestamp":1}"# + "\n" + #"{"display":"two","timestamp":2}"# + "\n")
        write(stern + "/settings.json", "{}")
        let keep = ClaudeAccount(label: "elliotgrayco.me", folder: "", accountUuid: uuid, organizationUuid: organization, email: personal,
                                 signedIn: true, expectedEmail: personal)
        let duplicate = ClaudeAccount(label: "stern", folder: stern, accountUuid: uuid, organizationUuid: organization, email: personal,
                                      signedIn: true)
        let nobody: ClaudeProcessProbe = { _, _ in false }
        let plan = ClaudeTidyUp.plan(keep: keep, duplicates: [duplicate], home: home, isAlive: nobody)
        let text = plan.lines.joined(separator: "\n")
        suite.expect(plan.canRun && plan.folders.map(\.folder) == [stern] && plan.folders[0].copies.count == 1
                        && plan.folders[0].identical == 1 && plan.folders[0].historyLines == 1,
                     "the plan merges stern's own conversation and prompt line, skipping what the shared setup has")
        suite.expect(text.contains("claude auth logout") && text.contains("Trash (recoverable)") && text.contains("history.jsonl: add 1 line(s)"),
                     "the plan says it signs the folder out with Claude Code and moves it to the Trash: \(text)")
        // `claude auth logout` revokes the folder's sign-in at Anthropic
        // (2.1.325); that the others stay signed in is not verified (T-25).
        suite.expect(!text.contains("keep theirs") && text.contains("revokes this folder's sign-in at Anthropic")
                        && text.contains("cannot be undone")
                        && text.contains("Not verified yet: that the other folders on this account stay signed in."),
                     "the plan says the logout revokes the sign-in at Anthropic and claims nothing unverified about the other folders")
        suite.expect(plan.lines.first == "Tidy up the folders signed in to the same account as elliotgrayco.me, which stays in ~/.claude, the default folder."
                        && !text.contains("(default))"),
                     "the plan's first line has no nested parentheses: \(plan.lines.first ?? "")")
        suite.expect(text.contains("Not merged, so it goes to the Trash with the folder: .claude.json, settings.json."),
                     "the plan names what goes to the Trash without being merged")
        let unnamed = ClaudeTidyUp.plan(keep: keep, duplicates: [duplicate], home: home, listed: ["elliotgrayco.me"], isAlive: nobody)
        let named = ClaudeTidyUp.plan(keep: keep, duplicates: [duplicate], home: home, listed: ["elliotgrayco.me", "stern"], isAlive: nobody)
        suite.expect(unnamed.lines.contains { $0.contains("Its name matches no account in the list") }
                        && !named.lines.contains { $0.contains("matches no account") },
                     "a duplicate whose name matches no listed account may be meant for one not added yet, and the plan says so")

        // Never the default folder.
        let reversed = ClaudeTidyUp.plan(keep: duplicate, duplicates: [keep], home: home, isAlive: nobody)
        suite.expect(!reversed.canRun && reversed.folders.isEmpty && reversed.problems.contains { $0.contains("default folder") },
                     "the default folder is never tidied away")
        // Never a folder a session runs on, and the session is named.
        let me = getpid()
        write(stern + "/sessions/\(me).json",
              #"{"pid":\#(me),"sessionId":"live-1","cwd":"/tmp/brim-tidy/App","status":"busy","startedAt":\#(Int64(Date().timeIntervalSince1970 * 1_000))}"#)
        let live = ClaudeTidyUp.plan(keep: keep, duplicates: [duplicate], home: home)
        suite.expect(!live.canRun && live.problems.first?.contains("pid \(me) in /tmp/brim-tidy/App (busy)") == true
                        && live.problems.first?.contains("/exit") == true,
                     "a folder with a live session is refused, naming the session: \(live.problems)")
        var calls: [String] = []
        let blocked = ClaudeTidyUp.execute(keep: keep, duplicates: [duplicate], home: home,
                                           logout: { calls.append($0); return nil }, trash: { calls.append("trash " + $0); return $0 })
        suite.expect(blocked.refused && calls.isEmpty && ClaudeFileIO.isDirectory(stern) && blocked.removed.isEmpty,
                     "with a session running, nothing is merged, signed out or moved")
        unlink(stern + "/sessions/\(me).json")

        // A logout that leaves the folder signed in never moves it.
        let stuck = ClaudeTidyUp.execute(keep: keep, duplicates: [duplicate], home: home, isAlive: nobody,
                                         logout: { calls.append($0); return nil }, trash: { calls.append("trash " + $0); return $0 })
        suite.expect(stuck.failures == 1 && stuck.removed.isEmpty && calls == [stern] && ClaudeFileIO.isDirectory(stern),
                     "a folder still signed in after the logout stays where it is: \(stuck.lines)")
        calls = []
        let failed = ClaudeTidyUp.execute(keep: keep, duplicates: [duplicate], home: home, isAlive: nobody,
                                          logout: { _ in "exit 1" }, trash: { calls.append("trash " + $0); return $0 })
        suite.expect(failed.failures == 1 && calls.isEmpty && ClaudeFileIO.isDirectory(stern), "a failed logout moves nothing")

        // The whole tidy-up, with stand-ins for Claude Code's logout and the Trash.
        calls = []
        let trashFolder = scratch.folder("tidy-trash")
        let report = ClaudeTidyUp.execute(keep: keep, duplicates: [duplicate], home: home, isAlive: nobody, logout: { folder in
            calls.append(folder)
            // What Claude Code does: the folder's oauthAccount goes.
            write(folder + "/.claude.json", #"{"numStartups":3}"#)
            return nil
        }, trash: { folder in
            let destination = trashFolder + "/" + (folder as NSString).lastPathComponent
            try FileManager.default.moveItem(atPath: folder, toPath: destination)
            return destination
        })
        suite.expect(report.failures == 0 && !report.refused && report.removed == [stern] && calls == [stern]
                        && !ClaudeFileIO.exists(stern) && ClaudeFileIO.isDirectory(trashFolder + "/.claude-stern"),
                     "stern is merged, signed out by Claude Code under its own folder, and moved to the Trash: \(report.lines)")
        suite.expect(read(root + "/projects/\(slug)/stern-only.jsonl") == "{\"b\":2}\n"
                        && read(root + "/history.jsonl").contains("\"two\"") && ClaudeFileIO.exists(home + "/.claude.json"),
                     "its conversation and prompt history are in the shared setup, and the default folder is untouched")

        // Each account keeps its own conversations (T-38): when the account
        // that stays is not the default one, a duplicate's conversations go
        // into that account's own folders, never into ~/.claude.
        let other = scratch.folder("tidy-own-home")
        let keepFolder = other + "/.claude-keep"
        let dupFolder = other + "/.claude-dup"
        write(other + "/.claude/projects/\(slug)/default-only.jsonl", "{}\n")
        write(keepFolder + "/.claude.json", config(personal))
        write(keepFolder + "/projects/\(slug)/kept.jsonl", "{\"k\":1}\n")
        write(keepFolder + "/projects/\(slug)/grown.jsonl", "{\"g\":1}\n")
        write(dupFolder + "/.claude.json", config(personal))
        write(dupFolder + "/projects/\(slug)/dup-only.jsonl", "{\"d\":1}\n")
        write(dupFolder + "/projects/\(slug)/grown.jsonl", "{\"g\":1}\n{\"g\":2}\n")
        write(dupFolder + "/plans/p.md", "plan")
        write(dupFolder + "/history.jsonl", #"{"display":"dup","timestamp":5}"# + "\n")
        let kept = ClaudeAccount(label: "keep", folder: keepFolder, accountUuid: uuid, organizationUuid: organization, email: personal,
                                 signedIn: true, expectedEmail: personal)
        let dup = ClaudeAccount(label: "dup", folder: dupFolder, accountUuid: uuid, organizationUuid: organization, email: personal,
                                signedIn: true)
        let ownPlan = ClaudeTidyUp.plan(keep: kept, duplicates: [dup], home: other, isAlive: nobody)
        suite.expect(ownPlan.canRun && ownPlan.folders.first?.copies.contains { $0.to == keepFolder + "/projects/\(slug)/dup-only.jsonl" } == true
                        && ownPlan.folders.first?.copies.contains { $0.to == keepFolder + "/projects/\(slug)/grown.jsonl" && $0.kind == .replace } == true
                        && ownPlan.lines.contains { $0.contains("into \(keepFolder)/projects") },
                     "the plan merges into the kept account's own folders: \(ownPlan.lines)")
        let ownReport = ClaudeTidyUp.execute(keep: kept, duplicates: [dup], home: other, isAlive: nobody, logout: { folder in
            write(folder + "/.claude.json", #"{"numStartups":3}"#)
            return nil
        }, trash: { folder in
            let destination = trashFolder + "/own-" + (folder as NSString).lastPathComponent
            try FileManager.default.moveItem(atPath: folder, toPath: destination)
            return destination
        })
        suite.expect(ownReport.failures == 0 && read(keepFolder + "/projects/\(slug)/dup-only.jsonl") == "{\"d\":1}\n"
                        && read(keepFolder + "/projects/\(slug)/grown.jsonl") == "{\"g\":1}\n{\"g\":2}\n"
                        && read(keepFolder + "/plans/p.md") == "plan" && read(keepFolder + "/history.jsonl").contains("\"dup\"")
                        && !ClaudeFileIO.exists(other + "/.claude/projects/\(slug)/dup-only.jsonl")
                        && !ClaudeFileIO.exists(other + "/.claude/plans") && !ClaudeFileIO.exists(other + "/.claude/history.jsonl"),
                     "the duplicate's conversations, plans and prompt history land in the kept folder; ~/.claude is untouched: \(ownReport.lines)")
    }

    // MARK: Sources

    /// The Terminal sign-in is gone (code rule 2): the only `auth login` in
    /// the module is Brim's own child.
    private static func sources(_ suite: TestSuite) {
        let folder = "Sources/Brim/Modules/ClaudeAccounts"
        let files = (FileManager.default.enumerator(atPath: folder)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".swift") }
        suite.expect(files.count >= 20, "the Claude accounts sources are in the tree (\(files.count))")
        let logins = files.filter { read(folder + "/" + $0).contains("\"auth\", \"login\"") }
        suite.expect(logins == ["ClaudeSignIn.swift"], "only ClaudeSignIn names claude auth login: \(logins)")
        let service = read(folder + "/App/ClaudeAccountsService.swift")
        suite.expect(service.contains("func openTerminal(id: String) -> String?") && service.contains("arguments: [],")
                        && !service.contains("func signIn(id:") && !service.contains("arguments: [\"auth\""),
                     "Open Terminal starts a plain session; no Terminal sign-in remains")
        let strings = read(folder + "/App/ClaudeAccountsStrings.swift")
        suite.expect(!strings.contains("opens Terminal for you to sign in") && !strings.contains("createAndSignIn"),
                     "no copy promises a Terminal sign-in")
        // Rule 1: the sign-in waits on file events and the child's exit.
        let run = read(folder + "/App/ClaudeSignInRun.swift")
        suite.expect(run.contains("makeFileSystemObjectSource") && !run.contains("Timer") && !run.contains("asyncAfter")
                        && !run.contains("usleep") && !run.contains("sleep("),
                     "the sign-in watches its folder with a DispatchSource and never polls")
        // The sign-in's sheet ends only the sign-in it shows, and the
        // accounts window never swaps its view (closing a sheet) while one
        // may be up.
        let views = read(folder + "/App/ClaudeAccountsViews.swift")
        suite.expect(views.contains("service.cancelSignIn(runID: shown)") && !views.contains("service.cancelSignIn()")
                        && views.components(separatedBy: "window.contentViewController = ").count == 2
                        && views.contains("case .rebuild:\n                window.contentViewController = ")
                        && views.contains("ClaudeAccountsAppSupport.windowShow("),
                     "the sheet cancels its own sign-in only, and the window keeps its view under a sheet")
        // Sign in is offered where the list says, Tidy up once the list is
        // answered, and the sheet names the folder's sessions.
        let panel = read(folder + "/App/ClaudeAccountsPanelSection.swift")
        let settings = read(folder + "/App/ClaudeAccountsSettings.swift")
        suite.expect(panel.contains("ClaudeAccountsAppSupport.offersSignIn(item)") && settings.contains("ClaudeAccountsAppSupport.offersSignIn(item)")
                        && !panel.contains("signIn: item.entry.map") && !settings.contains("signIn: item.entry.map")
                        && settings.contains("service.offersTidyUp(entry)") && service.contains("guard othersAsked else { return nil }")
                        && views.contains("text.liveSessionsWarning("),
                     "the rows offer Sign in and Tidy up only where they may run, and the sheet warns about running sessions")
        let text = FeatureStrings.claudeAccounts(.enUS)
        suite.expect(text.signInTitle(business) == "Sign in as \(business)" && text.stepOpened("Chrome") == "Opened a private Chrome window"
                        && text.holds("elliotgrayco.me") == "Holds elliotgrayco.me" && text.duplicates(1) == "+ 1 duplicate folder"
                        && text.duplicates(2) == "+ 2 duplicate folders"
                        && text.wrongAccount(signedInAs: personal, expected: business) == "That signed in as \(personal), not \(business).",
                     "the sheet and the list read as the spec words them")
        let all = Mirror(reflecting: text).children.compactMap { $0.value as? String }
        suite.expect(all.allSatisfy { !$0.contains("\u{2014}") }, "no em dash in the Claude accounts copy")
    }

    // MARK: Helpers

    private static func write(_ path: String, _ text: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private static func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private static func mode(_ path: String) -> Int {
        var info = stat()
        return stat(path, &info) == 0 ? Int(info.st_mode & 0o777) : -1
    }
}
