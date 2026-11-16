// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// What a brim-claude run sees: its environment, the home folder, Brim's
/// state folder, the time and its working folder. Tests build their own.
struct ClaudeHelperContext {
    var environment: [String: String]
    var home: String
    var paths: ClaudeAccountsPaths
    var now: Date
    var currentDirectory: String
    var isAlive: ClaudeProcessProbe
    /// Where the sync (ClaudeSync) sends what it moves to the Trash; tests
    /// pass their own.
    var trash: (String) throws -> Void = ClaudeSync.trashItem
    /// A line for the person now, before a wait (stderr, unbuffered).
    var say: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    /// Waits on a folder's migration lock (ClaudeOwnFolders): a blocking
    /// shared flock the kernel wakes when Brim lets go. Tests pass their own.
    var waitForMigration: (Int32) -> Void = { _ = flock($0, LOCK_SH) }
    /// Waits until the process holding a conversation open exits (a kqueue
    /// process-exit source; Ctrl-C cancels it). Tests pass their own.
    var waitForExit: (ClaudeHolder) -> ClaudeHeldOpen.Outcome = { ClaudeHeldOpen.waitForExit($0) }

    static func current() -> ClaudeHelperContext {
        let environment = ProcessInfo.processInfo.environment
        let home = ClaudeHome.path(environment: environment)
        let pwd = environment["PWD"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        return ClaudeHelperContext(environment: environment, home: home,
                                   paths: ClaudeAccountsPaths(environment: environment, home: home), now: Date(),
                                   currentDirectory: pwd ?? FileManager.default.currentDirectoryPath,
                                   isAlive: ClaudeSessionIndex.processIsAlive)
    }

    /// The shared setup: the default account's config folder.
    var sharedRoot: String { home + "/.claude" }

    /// https://no-color.org: any non-empty NO_COLOR turns colour off.
    var useColor: Bool { (environment["NO_COLOR"] ?? "").isEmpty }
}

struct ClaudeHelperResult: Equatable {
    var status: Int32
    var stdout: String
    var stderr: String

    static func ok(_ line: String) -> Self { Self(status: 0, stdout: line + "\n", stderr: "") }
    static func fail(_ status: Int32, _ message: String) -> Self { Self(status: status, stdout: "", stderr: message + "\n") }
}

/// The brim-claude subcommands. Sources/BrimClaude/main.swift only reads the
/// arguments and stdin, calls `run` and prints the result.
enum ClaudeHelper {
    static let usage = """
        usage: brim-claude statusline                       (Claude Code's statusLine command; reads its JSON on stdin)
               brim-claude pick [--cwd <dir>] [--model <m>]   print the folder new sessions use (empty: default account)
               brim-claude pick --account <label>             print that account's folder
               brim-claude move [<session-id>] [--to <label>] [--cwd <dir>]
                                                              sync the newest conversation here (or that one) to another
                                                              account and print "<folder>\\n<session-id>" to resume it there
               brim-claude resume (--id <session-id> | --continue | --picker) [--cwd <dir>] [--model <m>]
                                  [--account <label> | --folder <config dir>]
                                                              plan `claude --resume`/`--continue`: sync, then print
                                                              "<folder>\\n<session-id for -c>" (empty: run the arguments as given)
               brim-claude account-name <text>                print the account whose label <text> is (exit 0), else nothing (exit 1)
               brim-claude resolve                            show accounts, readings, ranking and live sessions
               brim-claude <https link>                       Brim's BROWSER while it signs in: hands the link to Brim
               brim-claude --selftest

        move and resume wait while the conversation they continue is still open in another process (they say
        where), then go on. Exit statuses: 0 done; 1 failed (move: also an unknown or ambiguous --to name);
        2 nothing to move (move), an unknown or ambiguous --account name (pick, resume); 3 the conversation is
        open in the session this runs in; 5 move does not know the conversation's account (name --to);
        130 the wait was cancelled (Ctrl-C), nothing started.
        """

    /// move's and resume's exit statuses (the usage text lists them).
    enum MoveStatus {
        static let failed: Int32 = 1
        static let nothingToMove: Int32 = 2
        /// The conversation is open in the Claude Code session brim-claude
        /// runs under (waiting would never end).
        static let sessionRunning: Int32 = 3
        static let ownerUnknown: Int32 = 5
        /// The wait for another process to let go was cancelled (Ctrl-C).
        static let cancelled: Int32 = 130
    }

    static func run(_ arguments: [String], input: () -> Data, context: ClaudeHelperContext) -> ClaudeHelperResult {
        // Claude Code opens its sign-in link with `$BROWSER <url>`: one
        // argument, the link.
        if arguments.count == 1, let link = arguments.first, ClaudeSignIn.looksLikeLink(link) {
            return browser(link, context: context)
        }
        let rest = Array(arguments.dropFirst())
        switch arguments.first {
        case "statusline": return statusline(input: input(), context: context).result
        case "pick": return pick(rest, context: context)
        case "move": return move(rest, context: context)
        case "resume": return resume(rest, context: context)
        case "account-name": return accountName(rest, context: context)
        case "resolve": return resolve(context: context)
        case "--selftest", "selftest": return selftest()
        case "-h", "--help", "help": return ClaudeHelperResult(status: 0, stdout: usage + "\n", stderr: "")
        default: return .fail(1, usage)
        }
    }

    // MARK: Options

    struct Options {
        var values: [String: String] = [:]
        var positional: [String] = []
        var error: String?
    }

    static func options(_ arguments: [String], valued: Set<String>, flags: Set<String> = []) -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if let equals = argument.firstIndex(of: "="), argument.hasPrefix("--"),
               valued.contains(String(argument[..<equals])) {
                options.values[String(argument[..<equals])] = String(argument[argument.index(after: equals)...])
            } else if valued.contains(argument) {
                guard index < arguments.count else {
                    options.error = "\(argument) needs a value"
                    return options
                }
                options.values[argument] = arguments[index]
                index += 1
            } else if flags.contains(argument) {
                options.values[argument] = ""
            } else if argument.hasPrefix("-") {
                options.error = "unknown option \(argument)"
                return options
            } else {
                options.positional.append(argument)
            }
        }
        return options
    }

    // MARK: statusline

    /// Claude Code's status line. Records which account the session runs on
    /// (ClaudeSessionOwners) and its plan windows in live/<key>.json (only
    /// when a whole-number percent, a reset time, the model or the session
    /// changed; a window's use never goes down within one renewal) and prints
    /// one short line. Never fails: on any problem it prints a minimal line
    /// and exits 0. No network, no subprocess.
    static func statusline(input: Data, context: ClaudeHelperContext) -> (result: ClaudeHelperResult, wroteLiveFile: Bool) {
        let folder = ClaudeAccountKey.folder(environment: context.environment)
        let key = ClaudeAccountKey.key(forFolder: folder)
        let accounts = ClaudeAccountsFile.load(context.paths)
        let label = statusLabel(accounts?.account(id: key), folder: folder, accounts: accounts?.accounts ?? [])
        guard let parsed = ClaudeUsageDecoding.statusLineInput(input) else {
            return (.ok(label), false)
        }
        if let session = parsed.sessionId {
            ClaudeSessionOwners.record(sessionId: session, folder: folder, paths: context.paths, now: context.now)
        }
        var wrote = false
        // A render without rate_limits (a session before its first answer)
        // knows nothing about the account, so it keeps what the last one saw.
        if parsed.hasRateLimits {
            let window = { (input: ClaudeStatusLineInput.Window?) -> ClaudeLiveFile.Window? in
                input.map { ClaudeLiveFile.Window(usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt) }
            }
            let model = parsed.modelId == nil && parsed.modelDisplayName == nil ? nil
                : ClaudeLiveFile.Model(id: parsed.modelId, displayName: parsed.modelDisplayName)
            var live = ClaudeLiveFile(observedAt: context.now, folder: folder, sessionId: parsed.sessionId,
                                      cwd: parsed.cwd, model: model, fiveHour: window(parsed.fiveHour),
                                      sevenDay: window(parsed.sevenDay))
            let path = context.paths.liveFile(key: key)
            let previous = ClaudeLiveFile.load(path)
            live.keepHigherUse(than: previous)
            if live.differs(from: previous), let data = try? ClaudeJSON.encoder().encode(live) {
                do {
                    try context.paths.ensureDirectory(context.paths.liveDirectory)
                    // A new helper process runs on every render: one stable
                    // temporary name under a lock, not a new path each time.
                    try ClaudeFileIO.writeAtomically(data, to: path, temporary: .stableLocked)
                    wrote = true
                } catch {
                    // The session's status line matters more than the record.
                }
            }
        }
        // The account's saved readings, from every folder that shares its sign-in.
        let saved = accounts.flatMap { file in
            ClaudeAccountRanking.reading(ClaudeAccountsDiscovery.group(of: key, in: file.accounts,
                                                                       launchable: launchable(context))?.members ?? [], file.readings)
        }
        let scoped = saved?.scoped.first { window in
            ClaudeAccountRanking.scope(window.model, appliesTo: parsed.modelId)
                || ClaudeAccountRanking.scope(window.model, appliesTo: parsed.modelDisplayName)
        }
        let line = renderStatusLine(label: label, input: parsed, scoped: scoped, now: context.now, color: context.useColor)
        return (.ok(line), wrote)
    }

    static func renderStatusLine(label: String, input: ClaudeStatusLineInput, scoped: ClaudeScopedWindow?,
                                 now: Date, color: Bool) -> String {
        var parts = [label]
        if let window = input.fiveHour {
            parts.append("5h " + percent(window.usedPercentage, color: color) + hint(window.resetsAt, now: now, weekly: false))
        }
        if let window = input.sevenDay {
            parts.append("wk " + percent(window.usedPercentage, color: color) + hint(window.resetsAt, now: now, weekly: true))
        }
        if let scoped {
            let state = ClaudeAccountRanking.state(.scoped(scoped.model), scoped.window,
                                                   limit: ClaudeAccountRanking.scopedLimit, applies: true, now: now)
            parts.append(clean(scoped.model, limit: 24) + " " + percent(state.utilization, color: color) + (state.estimated ? "~" : ""))
        }
        return parts.joined(separator: " | ")
    }

    private static func percent(_ value: Double, color: Bool) -> String {
        let whole = ClaudeLiveFile.wholePercent(value)
        let text = "\(whole)%"
        guard color else { return text }
        let code = whole >= 90 ? "31" : whole >= 70 ? "33" : "32"
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }

    /// " 2h10m" until a 5-hour renewal; " 13h" or " Sun" until a weekly one.
    private static func hint(_ resets: Date?, now: Date, weekly: Bool) -> String {
        guard let resets, resets > now, let minutes = Int(exactly: (resets.timeIntervalSince(now) / 60).rounded(.down))
        else { return "" }
        if weekly && minutes >= 24 * 60 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE"
            return " " + formatter.string(from: resets)
        }
        if minutes >= 60 {
            let hours = minutes / 60
            return weekly || hours >= 10 ? " \(hours)h" : " \(hours)h\(minutes % 60)m"
        }
        return " \(max(1, minutes))m"
    }

    /// The name a session in `folder` runs as: the account in the person's
    /// list its sign-in belongs to (ClaudeAccountList.owner: a folder that
    /// holds another account than its own, or shares an account's sign-in,
    /// runs as that account); for a folder holding an email no folder in the
    /// list is expected to hold, a name from that email. Never a name the
    /// folder kept from an earlier sign-in.
    static func statusLabel(_ account: ClaudeAccount?, folder: String, accounts: [ClaudeAccount]) -> String {
        guard let account else { return displayLabel(nil, folder: folder) }
        if let owner = ClaudeAccountList.owner(of: account, in: accounts) { return displayLabel(owner, folder: owner.folder) }
        if account.holdsWrongAccount, let held = account.heldEmail {
            return clean(ClaudeAccountsDiscovery.label(email: held, folder: account.folder, taken: []), limit: 40)
        }
        return displayLabel(account, folder: folder)
    }

    /// The account's label, or a name from its folder (".claude-work" is
    /// "work") when Brim has not listed it.
    static func displayLabel(_ account: ClaudeAccount?, folder: String) -> String {
        if let label = account?.label, !clean(label, limit: 40).isEmpty { return clean(label, limit: 40) }
        guard !folder.isEmpty else { return "default" }
        var name = (folder as NSString).lastPathComponent
        if name.hasPrefix(".claude-") { name.removeFirst(8) }
        while name.hasPrefix(".") { name.removeFirst() }
        return clean(name.isEmpty ? folder : name, limit: 40)
    }

    /// Text safe to print in a terminal: no control characters (so no escape
    /// sequences), at most `limit` characters.
    static func clean(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String(String.UnicodeScalarView(scalars)).prefix(limit))
    }

    // MARK: browser

    /// Brim's BROWSER while it runs a sign-in (ClaudeSignIn): Claude Code
    /// runs `brim-claude <link>`, and the link goes, atomically and mode
    /// 0600, to the file BRIM_SIGNIN_URL_FILE names, which Brim watches. It
    /// is never printed or logged. Only https links on claude.com, claude.ai
    /// or a subdomain of anthropic.com are taken; another is refused with a
    /// marker beside the file (no link in it) and exit 0, so Claude Code
    /// never tries another opener, and Brim ends the sign-in.
    static func browser(_ link: String, context: ClaudeHelperContext) -> ClaudeHelperResult {
        guard let file = context.environment[ClaudeSignIn.urlFileVariable], ClaudeSignIn.isURLFilePath(file),
              ClaudeSignIn.isPrivateDirectory((file as NSString).deletingLastPathComponent) else {
            return .fail(2, "brim-claude: asked to open a link, but no Brim sign-in is waiting for one")
        }
        guard ClaudeSignIn.acceptedLink(link) != nil else {
            try? ClaudeFileIO.writeAtomically(Data("refused\n".utf8), to: ClaudeSignIn.refusedFile(forURLFile: file))
            return ClaudeHelperResult(status: 0, stdout: "",
                                      stderr: "brim-claude: refused a sign-in link that is not https on claude.com, claude.ai or anthropic.com\n")
        }
        do {
            try ClaudeFileIO.writeAtomically(Data(link.utf8), to: file, mode: 0o600)
        } catch {
            return .fail(1, "brim-claude: could not hand the sign-in link to Brim")
        }
        return ClaudeHelperResult(status: 0, stdout: "", stderr: "")
    }

    // MARK: pick

    /// Why an account cannot be launched from here, or nil when it can: its
    /// folder string would select another sign-in (as ~/.claude spelled out),
    /// or the folder is gone (Claude Code would make an empty, signed-out one).
    static func launchProblem(_ account: ClaudeAccount, context: ClaudeHelperContext) -> String? {
        ClaudeAccountsDiscovery.launchProblem(account, home: context.home)
    }

    /// The launch check grouping takes (ClaudeAccountsDiscovery.groups), the
    /// same one the app passes.
    static func launchable(_ context: ClaudeHelperContext) -> (ClaudeAccount) -> Bool {
        ClaudeAccountsDiscovery.launchable(home: context.home)
    }

    /// The folder of `account`'s Claude account that work launches in (its
    /// group's first member: the first launchable folder that shares its
    /// sign-in), or nil with the reason none can be launched.
    static func launchFolder(_ account: ClaudeAccount, in file: ClaudeAccountsFile,
                             context: ClaudeHelperContext) -> (account: ClaudeAccount?, problem: String?) {
        // Its folder holds another account: launching the folder that does
        // hold that one would start the wrong account under this name.
        if account.holdsWrongAccount { return (nil, launchProblem(account, context: context)) }
        let folder = ClaudeAccountsDiscovery.group(of: account.id, in: file.accounts, launchable: launchable(context))?.primary ?? account
        if let problem = launchProblem(folder, context: context) { return (nil, problem) }
        return (folder, nil)
    }

    /// The folder a new session should use: an explicit account
    /// (`--account`), the one accounts.json's newSessions names, or the
    /// ranking's first. Without accounts.json, the default account (an empty
    /// line). Folders that share a sign-in are one account, launched in its
    /// first launchable folder (the default folder, else the shortest path).
    /// An account none of whose folders can be launched is never printed.
    /// Asks the app for a fresh check when a window that decides for the
    /// chosen account is older than 15 minutes (ClaudeAccountRanking.needsRefresh).
    static func pick(_ arguments: [String], context: ClaudeHelperContext) -> ClaudeHelperResult {
        let parsed = options(arguments, valued: ["--cwd", "--model", "--account"])
        if let error = parsed.error { return .fail(1, "brim-claude pick: \(error)\n" + usage) }
        let file = ClaudeAccountsFile.load(context.paths)
        // A name that is no account's fails before anything syncs (T-50).
        var named: ClaudeAccount?
        if let name = parsed.values["--account"], !(file == nil && name == ClaudeAccountKey.defaultKey) {
            let match = Self.account(named: name, in: file, context: context)
            guard let account = match.account else { return .fail(2, match.problem) }
            named = account
        }
        let notes = divergedNotes(syncHere(cwd: parsed.values["--cwd"] ?? context.currentDirectory, accounts: file?.accounts ?? [],
                                           context: context))
        var picked = pickAccount(parsed, named: named, file: file, context: context)
        if picked.status == 0 { picked.stderr = notes + picked.stderr }
        return picked
    }

    private static func pickAccount(_ parsed: Options, named: ClaudeAccount?, file: ClaudeAccountsFile?,
                                    context: ClaudeHelperContext) -> ClaudeHelperResult {
        if parsed.values["--account"] != nil {
            // The default account without accounts.json.
            guard let file, let account = named else { return .ok("") }
            let launch = launchFolder(account, in: file, context: context)
            guard let folder = launch.account else {
                return .fail(2, "brim-claude: \(account.label) cannot be launched: \(launch.problem ?? "no folder")")
            }
            waitWhileMigrating(folder, context: context)
            return .ok(folder.folder)
        }
        guard let file else { return .ok("") }
        guard let account = chosen(file, model: parsed.values["--model"], context: context)?.account else { return .ok("") }
        waitWhileMigrating(account, context: context)
        return .ok(account.folder)
    }

    /// Before a session starts on `account`, or a conversation is copied into
    /// it: while Brim gives its folder its own conversation folders, a
    /// session there would write half its conversation through the old link
    /// (ClaudeOwnFolders). Says so, then waits for it to finish.
    static func waitWhileMigrating(_ account: ClaudeAccount, context: ClaudeHelperContext) {
        ClaudeOwnFolders.waitWhileMigrating(folder: account.folder, paths: context.paths, note: {
            context.say("brim-claude: Brim is giving \(displayLabel(account, folder: account.folder)) its own conversation folders; "
                        + "Claude Code starts when that is done.")
        }, wait: context.waitForMigration)
    }

    /// The account new work runs on: the one accounts.json's newSessions
    /// names, else the ranking's first. Asks the app for a fresh check when
    /// a window that decides for it is older than 15 minutes.
    static func chosen(_ file: ClaudeAccountsFile, model explicit: String?, context: ClaudeHelperContext) -> ClaudeAccountRank? {
        let readings = ClaudeAccountRanking.readings(file, live: ClaudeLiveFile.loadAll(context.paths))
        let model = ClaudeAccountRanking.modelHint(explicit: explicit,
                                                   sharedSettings: ClaudeFileIO.read(context.sharedRoot + "/settings.json"))
        // Every folder is ranked, so a choice of a folder that cannot be
        // launched still names its account; only accounts with no folder to
        // launch in drop out.
        let isLaunchable = launchable(context)
        let ranked = ClaudeAccountRanking.rank(file.accounts, readings: readings, model: model, now: context.now,
                                               launchable: isLaunchable).filter { isLaunchable($0.account) }
        var chosen: ClaudeAccountRank?
        if case .account(let id) = file.newSessions { chosen = ranked.first { $0.contains(id) } }
        guard let chosen = chosen ?? ranked.first else { return nil }
        if ClaudeAccountRanking.needsRefresh(ClaudeAccountRanking.reading(chosen.folders, readings), model: model, now: context.now) {
            requestRefresh(chosen.account, reason: "pick", context: context)
        }
        return chosen
    }

    /// Syncs the working folder's conversations and its repo's memory across
    /// the account folders before a launch (ClaudeSync), so Claude Code's
    /// /resume lists every account's conversations and the memory is current
    /// even while the app is not running; `sessions` adds those
    /// conversations wherever they are. Claude Code keys a conversation by
    /// the folder it started in and a repo's memory by its git root (a
    /// linked worktree's main working tree), so both are synced. Every run
    /// also checks out the conversations running now and checks in those
    /// that ended (ClaudeSync's check-out), so this finishes a check-in the
    /// app could not (not running when the session ended). Returns the
    /// run's report (divergedNotes has its lines for stderr; `open` the
    /// conversations open in a folder, held out of view in the others).
    @discardableResult
    static func syncHere(cwd: String, accounts: [ClaudeAccount], sessions: Set<String> = [],
                         context: ClaudeHelperContext) -> ClaudeSync.Report {
        var places = [cwd, ClaudeFileIO.realPath(cwd)]
        if let root = memoryRoot(cwd) { places += [root, ClaudeFileIO.realPath(root)] }
        let scope = ClaudeSync.Scope(slugs: Set(places.map(ClaudeSessionIndex.projectSlug)), sessions: sessions)
        let report = ClaudeSync.reconcile(
            configDirectories: ClaudeAccount.configDirectories(home: context.home, accounts: accounts), scope: scope,
            statePath: ClaudeSync.statePath(context.paths),
            options: ClaudeSync.Options(isAlive: context.isAlive, trash: context.trash, now: context.now,
                                        cleanupDays: ClaudeSync.cleanupDays(sharedSettings: ClaudeFileIO.read(context.sharedRoot + "/settings.json")),
                                        waiting: { context.say(syncWaitNote) }))
        return report
    }

    /// A line per conversation a sync found continued on two accounts, for stderr.
    static func divergedNotes(_ report: ClaudeSync.Report) -> String {
        report.diverged.map { "brim-claude: \(ClaudeSync.shortId($0)) was continued on two accounts; each keeps its own version.\n" }
            .joined()
    }

    /// The label of the account whose config folder is `folder` (a real
    /// path, as ClaudeSync names folders); the folder itself when none is.
    static func label(ofConfig folder: String, accounts: [ClaudeAccount], context: ClaudeHelperContext) -> String {
        accounts.first { ClaudeFileIO.realPath($0.configDirectory(home: context.home)) == ClaudeFileIO.realPath(folder) }?.label ?? folder
    }

    /// Said while another sync (the app's) holds the sync's lock.
    static let syncWaitNote = "brim-claude: Brim is syncing conversations between accounts; Claude Code starts when that is done."

    /// The folder Claude Code keys `cwd`'s auto memory by: the top of the
    /// git working tree it is in, or for a linked worktree the main working
    /// tree; nil outside a repository. Read from .git on disk (no git run).
    static func memoryRoot(_ cwd: String) -> String? {
        var directory = (cwd as NSString).standardizingPath
        while !directory.isEmpty {
            let dotGit = directory + "/.git"
            if ClaudeFileIO.isDirectory(dotGit, followingLinks: true) { return directory }
            if ClaudeFileIO.isRegularFile(dotGit) {
                // "gitdir: <path>": a linked worktree (its gitdir names the
                // main repository's .git in commondir) or a submodule.
                let text = ClaudeFileIO.read(dotGit, limit: 4_096).map { String(decoding: $0, as: UTF8.self) } ?? ""
                guard let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return directory }
                var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                if !gitdir.hasPrefix("/") { gitdir = directory + "/" + gitdir }
                gitdir = (gitdir as NSString).standardizingPath
                if let common = ClaudeFileIO.read(gitdir + "/commondir", limit: 4_096)
                    .map({ String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }), !common.isEmpty {
                    let path = ((common.hasPrefix("/") ? common : gitdir + "/" + common) as NSString).standardizingPath
                    if (path as NSString).lastPathComponent == ".git" { return (path as NSString).deletingLastPathComponent }
                }
                return directory
            }
            if directory == "/" { return nil }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Touches requests/<ms>-<account id> so the app runs a get_usage check
    /// for the account; one pending request per account is enough.
    @discardableResult
    static func requestRefresh(_ account: ClaudeAccount, reason: String, context: ClaudeHelperContext) -> Bool {
        let directory = context.paths.requestsDirectory
        let suffix = "-" + account.id
        let pending = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        if pending.contains(where: { $0.hasSuffix(suffix) }) { return false }
        let milliseconds = Int64(context.now.timeIntervalSince1970 * 1_000)
        let body: [String: Any] = ["account": account.id, "reason": reason, "requested_at": ClaudeDate.format(context.now)]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return false }
        do {
            try context.paths.ensureDirectory(directory)
            try ClaudeFileIO.writeAtomically(data, to: directory + "/\(milliseconds)" + suffix)
            return true
        } catch {
            return false
        }
    }

    // MARK: move

    /// Finds the conversation to continue elsewhere (the one named, else the
    /// newest in this folder, running or not) and the account to continue it
    /// on, syncs it there (ClaudeSync: the transcript with its session folder,
    /// file history and tasks) and prints "<folder>\n<session id>" for the
    /// shell to run a plain `claude --resume <id>` there. While another
    /// process still holds that conversation open (a session left open, say
    /// paused at its usage limit), it never moves an older one instead: it
    /// says where it is open and waits for that process to exit
    /// (waitForHolder), then moves it; the newest ended one moves only when
    /// named. Exit 3 when the conversation is open in the session this runs
    /// in, 130 when the wait is cancelled, 2 when there is nothing to move, 5
    /// when Brim does not know the conversation's account and no --to names
    /// the target, 1 when the target cannot hold the same conversation (it
    /// went on on two accounts) or --to names no account. The conversation's
    /// account is what its status line recorded (ClaudeSessionOwners), never
    /// a guess; of its copies, the longest is the conversation.
    static func move(_ arguments: [String], context: ClaudeHelperContext) -> ClaudeHelperResult {
        let parsed = options(arguments, valued: ["--to", "--cwd"])
        if let error = parsed.error { return .fail(MoveStatus.failed, "brim-claude move: \(error)\n" + usage) }
        guard parsed.positional.count <= 1 else { return .fail(MoveStatus.failed, "brim-claude move: one session id at most\n" + usage) }
        let cwd = parsed.values["--cwd"] ?? context.currentDirectory
        guard let file = ClaudeAccountsFile.load(context.paths), !file.accounts.isEmpty else {
            return .fail(MoveStatus.failed, "brim-claude move: Brim has not listed any Claude account yet (\(context.paths.accountsFile))")
        }
        // A wrong --to fails before anything waits or syncs.
        var named: ClaudeAccount?
        if let name = parsed.values["--to"] {
            let match = Self.account(named: name, in: file, context: context)
            guard let account = match.account else { return .fail(MoveStatus.failed, match.problem) }
            named = account
        }
        let configDirectories = ClaudeAccount.configDirectories(home: context.home, accounts: file.accounts)
        let holders = ClaudeHeldOpen.holders(configDirectories: configDirectories, statePath: ClaudeSync.statePath(context.paths),
                                             isAlive: context.isAlive)
        var notes: [String] = []
        let transcript: ClaudeTranscript
        if let id = parsed.positional.first {
            guard ClaudeSessionIndex.isSessionId(id) else {
                return .fail(MoveStatus.failed, "brim-claude move: \"\(clean(id, limit: 80))\" is not a session id")
            }
            if let holder = holders[id] {
                return waitForHolder(holder, cwd: cwd, accounts: file.accounts, instead: nil, context: context) {
                    move(arguments, context: $0)
                }
            }
            guard let found = ClaudeSessionIndex.transcript(sessionId: id, cwd: cwd, configDirectories: configDirectories) else {
                return .fail(MoveStatus.nothingToMove, "brim-claude move: no conversation \(id) in any account's projects")
            }
            transcript = found
        } else {
            let all = ClaudeSessionIndex.transcripts(cwd: cwd, configDirectories: configDirectories)
            guard let newest = all.first else {
                return .fail(MoveStatus.nothingToMove, "brim-claude move: no Claude Code conversation in \(cwd)")
            }
            if let holder = holders[newest.sessionId] {
                // An older ended one moves only when named.
                let instead = all.first(where: { holders[$0.sessionId] == nil }).map { ended in
                    "brim-claude: to continue the newest ended conversation instead, name it: cx \(ended.sessionId)"
                        + (parsed.values["--to"].map { " --to " + clean($0, limit: 80) } ?? "")
                }
                return waitForHolder(holder, cwd: cwd, accounts: file.accounts, instead: instead, context: context) {
                    move(arguments + [newest.sessionId], context: $0)
                }
            }
            transcript = newest
        }
        // The account the conversation last ran on, as its status line
        // recorded it; nil when none reached Brim.
        let ownerFolder = ClaudeSessionOwners.folder(sessionId: transcript.sessionId, paths: context.paths)
        let ownerKey = ownerFolder.map(ClaudeAccountKey.key(forFolder:))
        // Every folder of the owner's account: moving between folders that
        // share a sign-in moves nothing.
        let isLaunchable = launchable(context)
        let ownerFolders = ownerKey.map { key in
            ClaudeAccountsDiscovery.group(of: key, in: file.accounts, launchable: isLaunchable)?.members.map(\.id) ?? [key]
        } ?? []
        let ownerLabel = ownerFolder.map { displayLabel(file.account(id: ClaudeAccountKey.key(forFolder: $0)), folder: $0) }
        let readings = ClaudeAccountRanking.readings(file, live: ClaudeLiveFile.loadAll(context.paths))
        let model = ClaudeAccountRanking.modelHint(explicit: nil, sharedSettings: ClaudeFileIO.read(context.sharedRoot + "/settings.json"))
        let target: ClaudeAccount
        if let account = named {
            let launch = launchFolder(account, in: file, context: context)
            guard let folder = launch.account else {
                return .fail(MoveStatus.failed, "brim-claude move: \(account.label) cannot be launched: \(launch.problem ?? "no folder")")
            }
            target = folder
        } else {
            guard ownerKey != nil else {
                return .fail(MoveStatus.ownerUnknown,
                             "brim-claude move: Brim does not know which account \(transcript.sessionId) last ran on (no status line of it reached Brim); name the target with --to <account> (accounts: \(file.named.map(\.label).joined(separator: ", ")))")
            }
            let ranked = ClaudeAccountRanking.rank(file.accounts, readings: readings, model: model, now: context.now,
                                                   launchable: isLaunchable)
                .filter { rank in isLaunchable(rank.account) && !ownerFolders.contains { rank.contains($0) } && rank.status != .signedOut }
            guard let best = ranked.first else {
                return .fail(MoveStatus.nothingToMove, "brim-claude move: no other signed-in account to move to")
            }
            target = best.account
        }
        if target.signedIn == false {
            return .fail(MoveStatus.failed, "brim-claude move: \(target.label) is signed out; sign in from Brim first")
        }
        if ownerFolders.contains(target.id) {
            return .fail(MoveStatus.nothingToMove, "brim-claude move: \(transcript.sessionId) already runs on \(target.label)")
        }
        // --resume finds a conversation under <config>/projects/<cwd folder>/,
        // so the shell must run in that working folder.
        let slug = ClaudeSessionIndex.slug(of: transcript)
        let slugs = Set([ClaudeSessionIndex.projectSlug(cwd), ClaudeSessionIndex.projectSlug(ClaudeFileIO.realPath(cwd))])
        guard slugs.contains(slug) else {
            return .fail(MoveStatus.failed, "brim-claude move: \(transcript.sessionId) was started in another folder (projects/\(slug)); run cx from that folder")
        }
        let targetFolders = ClaudeAccountsDiscovery.group(of: target.id, in: file.accounts, launchable: isLaunchable)?.members ?? [target]
        if ClaudeAccountRanking.needsRefresh(ClaudeAccountRanking.reading(targetFolders, readings), model: model, now: context.now) {
            requestRefresh(target, reason: "move", context: context)
        }
        waitWhileMigrating(target, context: context)
        let synced = syncHere(cwd: cwd, accounts: file.accounts, sessions: [transcript.sessionId], context: context)
        let diverged = divergedNotes(synced)
        // It opened since the look above (a check-out holds the other copies
        // out of view until its process exits): the same wait.
        if let open = synced.open[transcript.sessionId] {
            if !diverged.isEmpty { context.say(String(diverged.dropLast())) }
            let holder = ClaudeHolder(sessionId: transcript.sessionId, pid: open.pid, startedAt: open.started, configDirectory: open.config)
            return waitForHolder(holder, cwd: cwd, accounts: file.accounts, instead: nil, context: context) {
                move(parsed.positional.isEmpty ? arguments + [transcript.sessionId] : arguments, context: $0)
            }
        }
        if let held = holding(transcript, slug: slug, target: target, file: file, context: context) {
            return .fail(MoveStatus.failed, diverged + "brim-claude move: \(held.message)")
        }
        notes.append("Continuing \(transcript.sessionId) (\(ownerLabel ?? "account unknown")) on \(target.label).")
        notes += workflowLines(configDirectory: target.configDirectory(home: context.home), slug: slug, id: transcript.sessionId)
        return ClaudeHelperResult(status: 0, stdout: target.folder + "\n" + transcript.sessionId + "\n",
                                  stderr: diverged + notes.joined(separator: "\n") + "\n")
    }

    /// What `target` holds of a conversation it does not hold as far as it
    /// goes (the longest copy of all), after the sync.
    enum Holding: Equatable {
        /// No copy.
        case missing
        /// An older copy (a byte-prefix of another account's): continuing it
        /// would split the conversation.
        case older
        /// One version of a conversation continued on two accounts, not the
        /// longest; continuing it splits nothing more.
        case otherVersion
    }

    /// What `target` holds of the conversation after the sync, with the
    /// accounts that hold it further on, in words; nil when it holds the
    /// longest copy.
    static func holding(_ transcript: ClaudeTranscript, slug: String, target: ClaudeAccount, file: ClaudeAccountsFile,
                        context: ClaudeHelperContext) -> (kind: Holding, message: String)? {
        let configDirectories = ClaudeAccount.configDirectories(home: context.home, accounts: file.accounts)
        let id = transcript.sessionId
        let short = ClaudeSync.shortId(id)
        guard let longest = ClaudeSessionIndex.transcript(sessionId: id, cwd: nil, configDirectories: configDirectories) else {
            return (.missing, "no conversation \(id) in any account's projects")
        }
        let path = { (account: ClaudeAccount) in account.configDirectory(home: context.home) + "/projects/" + slug + "/" + id + ".jsonl" }
        let copy = path(target)
        if ClaudeFileIO.isRegularFile(ClaudeFileIO.realPath(copy))
            && (ClaudeFileIO.realPath(copy) == ClaudeFileIO.realPath(longest.path) || ClaudeFileCopy.identical(copy, longest.path)) {
            return nil
        }
        let further = file.accounts.filter { account in
            ClaudeFileIO.realPath(path(account)) != ClaudeFileIO.realPath(copy) && ClaudeFileIO.isRegularFile(path(account))
                && (!ClaudeFileIO.isRegularFile(copy) || ClaudeFileCopy.isStrictPrefix(copy, of: path(account)))
        }.map(\.label)
        guard ClaudeFileIO.isRegularFile(copy) else {
            return (.missing, "\(target.label) has no copy of \(short); resume it where it is (\(further.joined(separator: ", ")))")
        }
        if !further.isEmpty {
            return (.older, "\(target.label) holds an older copy of \(short), so continuing it there would split the conversation; "
                        + "resume it where it went on (\(further.joined(separator: ", "))), or run this again once that copy synced")
        }
        let others = file.accounts.filter { account in
            ClaudeFileIO.realPath(path(account)) != ClaudeFileIO.realPath(copy) && ClaudeFileIO.isRegularFile(path(account))
        }.map(\.label)
        return (.otherVersion, "\(short) was continued on two accounts, so each keeps its own version; \(target.label) holds one of them "
                    + "(the others: \(others.joined(separator: ", ")))")
    }

    /// How to resume each workflow of a conversation continued on another
    /// account. The transcript names a workflow's script by the path it had
    /// on the account it ran on, which Claude Code refuses on this one (its
    /// own allowed roots are under this account's folder); the synced copy
    /// under this account's folder is allowed. One line per script whose
    /// name ends in its run id (<name>-wf_<id>.js).
    static func workflowLines(configDirectory: String, slug: String, id: String) -> [String] {
        let scripts = configDirectory + "/projects/" + slug + "/" + id + "/workflows/scripts"
        return ((try? FileManager.default.contentsOfDirectory(atPath: scripts)) ?? []).sorted().compactMap { name in
            guard let run = workflowRunId(name), ClaudeFileIO.isRegularFile(scripts + "/" + name) else { return nil }
            return "To resume workflow \(run) there: Workflow({scriptPath: \"\(scripts)/\(name)\", resumeFromRunId: \"\(run)\"})"
        }
    }

    /// "wf_d11e42ef-bed" for "build-wf_d11e42ef-bed.js"; nil for a script
    /// whose name carries no run id.
    static func workflowRunId(_ name: String) -> String? {
        guard name.hasSuffix(".js"), let start = name.range(of: "wf_", options: .backwards)?.lowerBound,
              start == name.startIndex || name[name.index(before: start)] == "-" else { return nil }
        let run = String(name[start..<name.index(name.endIndex, offsetBy: -3)])
        return run.count > 3 && ClaudeSessionIndex.isSessionId(run) ? run : nil
    }

    // MARK: resume

    /// The plan for `claude --resume <id>`, `--resume=<id>`, `-r <id>`,
    /// `-c`/`--continue` and the bare picker, which the zsh wrapper asks for
    /// before it starts Claude Code. Every account holds a copy of every
    /// conversation (ClaudeSync), so a resume is always a plain one: this
    /// syncs the working folder's conversations (and the one named) into
    /// the account it picks, then prints "<folder>\n<session id>":
    ///   - <folder>: the account the conversation last ran on (its status line
    ///     record) while it can launch and has room, else the account a new
    ///     session would use; --account fixes it (cc <account>), --folder
    ///     fixes it to the config folder CLAUDE_CONFIG_DIR already names
    ///     (direnv, an export), exactly as spelled. A --folder that is none
    ///     of Brim's accounts (a test or per-project config) holds its own
    ///     conversations: nothing is synced and the arguments run as given;
    ///   - <session id>: only for -c, when Claude Code's own -c on that folder
    ///     would pick another conversation than the newest one across every
    ///     account (one the sync left alone): the wrapper then runs `--resume
    ///     <id>` in its place. Empty: the wrapper passes the arguments on
    ///     unchanged.
    /// The conversation meant (the one named, or for -c the newest here,
    /// running or not) still open in another process is never swapped for an
    /// older one: brim-claude says where it is open and waits for that
    /// process to exit (waitForHolder), then plans it. For -c the retry after
    /// the wait keeps that conversation (`meant`) and names it, even when
    /// another one became the newest meanwhile (the holder switched to it
    /// with /resume before it exited). So does the picker when the newest
    /// conversation here is held out of the projects/ folder the picked
    /// account reads (open on an account whose projects/ is another folder;
    /// an account whose projects/ is still a link into ~/.claude reads
    /// ~/.claude's). Exit 3 when it is open in the session this runs in, 130
    /// when the wait is cancelled; exit 1 when the target holds no copy or
    /// an older one (continuing that would split the conversation); 2 when
    /// --account names no account.
    static func resume(_ arguments: [String], context: ClaudeHelperContext, meant: String? = nil) -> ClaudeHelperResult {
        let parsed = options(arguments, valued: ["--cwd", "--model", "--account", "--folder", "--id"],
                             flags: ["--continue", "--picker"])
        if let error = parsed.error { return .fail(1, "brim-claude resume: \(error)\n" + usage) }
        let kinds = [parsed.values["--id"] != nil, parsed.values["--continue"] != nil, parsed.values["--picker"] != nil]
        guard kinds.filter({ $0 }).count == 1 else { return .fail(1, "brim-claude resume: name one of --id, --continue or --picker\n" + usage) }
        let cwd = parsed.values["--cwd"] ?? context.currentDirectory
        let fixed = parsed.values["--account"]
        let pinned = parsed.values["--folder"].flatMap { $0.isEmpty ? nil : $0 }
        if fixed != nil && pinned != nil { return .fail(1, "brim-claude resume: --account or --folder, not both\n" + usage) }
        let file = ClaudeAccountsFile.load(context.paths)
        let accounts = file?.accounts ?? []
        var notes = ""
        func plan(_ account: ClaudeAccount?, _ id: String = "") -> ClaudeHelperResult {
            if let account { waitWhileMigrating(account, context: context) }
            return ClaudeHelperResult(status: 0, stdout: (account?.folder ?? "") + "\n" + id + "\n", stderr: notes)
        }
        // The account the launch uses without a conversation to go by.
        var picked: ClaudeAccount?
        if let pinned {
            let config = ClaudeFileIO.realPath(ClaudeSessionIndex.configDirectory(forFolder: pinned, home: context.home))
            guard ClaudeAccount.configDirectories(home: context.home, accounts: accounts).contains(where: { ClaudeFileIO.realPath($0) == config })
            else { return plan(nil) }
            picked = accounts.first { ClaudeFileIO.realPath($0.configDirectory(home: context.home)) == config }
                ?? ClaudeAccount(label: displayLabel(nil, folder: pinned), folder: pinned)
        } else if let fixed {
            if file == nil && fixed == ClaudeAccountKey.defaultKey { return plan(nil) }
            let named = Self.account(named: fixed, in: file, context: context)
            guard let file, let account = named.account else { return .fail(2, named.problem) }
            let launch = launchFolder(account, in: file, context: context)
            guard let folder = launch.account else {
                return .fail(2, "brim-claude: \(account.label) cannot be launched: \(launch.problem ?? "no folder")")
            }
            picked = folder
        } else if let file {
            picked = chosen(file, model: parsed.values["--model"], context: context)?.account
        }
        let configDirectories = ClaudeAccount.configDirectories(home: context.home, accounts: accounts)
        let holders = ClaudeHeldOpen.holders(configDirectories: configDirectories, statePath: ClaudeSync.statePath(context.paths),
                                             isAlive: context.isAlive)
        let here = parsed.values["--id"] == nil ? ClaudeSessionIndex.transcripts(cwd: cwd, configDirectories: configDirectories) : []
        // The conversation, when the arguments name one Brim can find.
        var transcript: ClaudeTranscript?
        if parsed.values["--continue"] != nil, let meant {
            guard let found = ClaudeSessionIndex.transcript(sessionId: meant, cwd: cwd, configDirectories: configDirectories) else {
                return .fail(MoveStatus.failed, "brim-claude: no conversation \(meant) in any account's projects")
            }
            transcript = found
        } else if parsed.values["--continue"] != nil {
            transcript = here.first
        } else if let id = parsed.values["--id"], ClaudeSessionIndex.isSessionId(id) {
            transcript = ClaudeSessionIndex.transcript(sessionId: id, cwd: cwd, configDirectories: configDirectories)
        }
        // Still open in another process: wait for it, never an older one.
        if let transcript, let holder = holders[transcript.sessionId] {
            let instead = parsed.values["--continue"] == nil ? nil : here.first(where: { holders[$0.sessionId] == nil }).map {
                "brim-claude: to continue the newest ended conversation instead, name it: claude -r \($0.sessionId)"
            }
            return waitForHolder(holder, cwd: cwd, accounts: accounts, instead: instead, context: context) {
                resume(arguments, context: $0, meant: transcript.sessionId)
            }
        }
        // The picker on an account the newest conversation here is held out
        // of (open on an account that writes another projects/ folder): it
        // could not list it. Accounts that share one projects/ folder (one
        // still linked into ~/.claude) see the same conversations.
        if parsed.values["--picker"] != nil, let newest = here.first, let holder = holders[newest.sessionId] {
            let pickedConfig = (picked?.folder).map { ClaudeSessionIndex.configDirectory(forFolder: $0, home: context.home) } ?? context.sharedRoot
            if ClaudeFileIO.realPath(holder.configDirectory + "/projects") != ClaudeFileIO.realPath(pickedConfig + "/projects") {
                return waitForHolder(holder, cwd: cwd, accounts: accounts,
                                     instead: "brim-claude: to open another conversation instead, name it: claude -r <session id>",
                                     context: context) { resume(arguments, context: $0) }
            }
        }
        guard let transcript, let file else {
            // The picker, or nothing to go by: the working folder's
            // conversations are synced, so the picker lists them all.
            notes += divergedNotes(syncHere(cwd: cwd, accounts: accounts, context: context))
            return plan(picked)
        }
        let id = transcript.sessionId
        var target = picked
        // Where it last ran, while that account can take it.
        if fixed == nil, pinned == nil, let ownerFolder = ClaudeSessionOwners.folder(sessionId: id, paths: context.paths),
           let owner = file.accounts.first(where: { $0.folder == ownerFolder }), canRun(owner, file: file, context: context) {
            if owner.folder != picked?.folder { notes += "brim-claude: resuming \(ClaudeSync.shortId(id)) on \(owner.label), where it last ran.\n" }
            target = owner
        }
        let targetConfig = (target?.folder).map { ClaudeSessionIndex.configDirectory(forFolder: $0, home: context.home) }
            ?? context.sharedRoot
        if let target { waitWhileMigrating(target, context: context) }
        let synced = syncHere(cwd: cwd, accounts: accounts, sessions: [id], context: context)
        notes += divergedNotes(synced)
        // It opened since the look above (a check-out holds the other copies
        // out of view until its process exits): the same wait.
        if let open = synced.open[id] {
            if !notes.isEmpty { context.say(String(notes.dropLast())) }
            let holder = ClaudeHolder(sessionId: id, pid: open.pid, startedAt: open.started, configDirectory: open.config)
            return waitForHolder(holder, cwd: cwd, accounts: accounts, instead: nil, context: context) {
                resume(arguments, context: $0, meant: parsed.values["--continue"] == nil ? nil : id)
            }
        }
        let slug = ClaudeSessionIndex.slug(of: transcript)
        if let target, let held = holding(transcript, slug: slug, target: target, file: file, context: context) {
            guard held.kind == .otherVersion else { return .fail(MoveStatus.failed, notes + "brim-claude: " + held.message) }
            notes += "brim-claude: " + held.message + "\n"
        }
        // Continued on another account than the one it last ran on: its
        // workflows resume from this account's copies of their scripts.
        if let ranOn = ClaudeSessionOwners.folder(sessionId: id, paths: context.paths),
           ClaudeFileIO.realPath(ClaudeSessionIndex.configDirectory(forFolder: ranOn, home: context.home)) != ClaudeFileIO.realPath(targetConfig) {
            notes += workflowLines(configDirectory: targetConfig, slug: slug, id: id).map { "brim-claude: " + $0 + "\n" }.joined()
        }
        guard parsed.values["--continue"] != nil else { return plan(target) }
        // Claude Code's -c takes the folder's newest conversation; when that is
        // another one (a copy the sync left alone), name the one meant.
        let newest = ClaudeSessionIndex.transcripts(cwd: cwd, configDirectories: [targetConfig]).first?.sessionId
        return plan(target, newest == id ? "" : id)
    }

    /// Whether `account` can take a session now: it launches, is signed in,
    /// and is not over a limit.
    static func canRun(_ account: ClaudeAccount, file: ClaudeAccountsFile, context: ClaudeHelperContext) -> Bool {
        let isLaunchable = launchable(context)
        guard isLaunchable(account), account.signedIn != false else { return false }
        let readings = ClaudeAccountRanking.readings(file, live: ClaudeLiveFile.loadAll(context.paths))
        let model = ClaudeAccountRanking.modelHint(explicit: nil, sharedSettings: ClaudeFileIO.read(context.sharedRoot + "/settings.json"))
        guard let rank = ClaudeAccountRanking.rank(file.accounts, readings: readings, model: model, now: context.now,
                                                   launchable: isLaunchable).first(where: { $0.contains(account.id) }) else { return false }
        switch rank.status {
        case .usable, .unknown: return true
        case .limited, .signedOut: return false
        }
    }

    // MARK: Held open (T-50)

    /// When the conversation to continue is still open in another process
    /// (`holder`): says where (account, tab, pid, and when its transcript ends
    /// on a usage-limit notice, that it waits there) and how to let go, then
    /// waits for that process to exit (context.waitForExit: a kqueue
    /// process-exit source, no polling) and runs `retry` with that process
    /// counted as gone, which syncs (the check-in) and continues it. `instead`
    /// is a line naming the explicit way to an older conversation. Never
    /// waits on the session this runs in (exit 3); a cancelled wait (Ctrl-C)
    /// exits 130 with nothing started.
    static func waitForHolder(_ holder: ClaudeHolder, cwd: String, accounts: [ClaudeAccount], instead: String?,
                              context: ClaudeHelperContext,
                              retry: (ClaudeHelperContext) -> ClaudeHelperResult) -> ClaudeHelperResult {
        let short = ClaudeSync.shortId(holder.sessionId)
        let account = label(ofConfig: holder.configDirectory, accounts: accounts, context: context)
        if ClaudeHeldOpen.isSelfOrAncestor(holder.pid) {
            return .fail(MoveStatus.sessionRunning,
                         "brim-claude: \(short) is open in the Claude Code session this runs in (pid \(holder.pid) on \(account)); end it with /exit first."
                            + (instead.map { "\n" + $0 } ?? ""))
        }
        let configDirectories = ClaudeAccount.configDirectories(home: context.home, accounts: accounts)
        context.say(heldMessage(holder, account: account, terminal: ClaudeHeldOpen.terminal(pid: holder.pid),
                                paused: ClaudeHeldOpen.pausedAtUsageLimit(sessionId: holder.sessionId, cwd: cwd,
                                                                          configDirectories: configDirectories)))
        if let instead { context.say(instead) }
        switch context.waitForExit(holder) {
        case .cancelled:
            return .fail(MoveStatus.cancelled, "brim-claude: cancelled; nothing was started.")
        case .exited:
            context.say("brim-claude: \(short) ended on \(account); continuing it.")
            // Its pid may still answer until its parent reaps it.
            var next = context
            let probe = context.isAlive
            let gone = holder.pid
            next.isAlive = { pid, started in pid != gone && probe(pid, started) }
            return retry(next)
        }
    }

    /// "brim-claude: 8d866fb8 is still open on sparkfx.ai (tab ttys012, pid
    /// 4242, paused at its usage limit). Press Esc and type /exit there; I'll
    /// continue here as soon as it ends. Ctrl-C to cancel."
    static func heldMessage(_ holder: ClaudeHolder, account: String, terminal: String?, paused: Bool) -> String {
        var details: [String] = []
        if let terminal { details.append("tab \(clean(terminal, limit: 40))") }
        details.append("pid \(holder.pid)")
        if paused { details.append("paused at its usage limit") }
        return "brim-claude: \(ClaudeSync.shortId(holder.sessionId)) is still open on \(account) (\(details.joined(separator: ", "))). "
            + "Press Esc and type /exit there; I'll continue here as soon as it ends. Ctrl-C to cancel."
    }

    // MARK: Account names

    /// The account `name` stands for (ClaudeAccountsFile.match, the one rule
    /// `cc`, `cx --to` and `account-name` share; account-name takes labels
    /// only), or why none: the message
    /// lists every name exactly as those commands take it.
    static func account(named name: String, in file: ClaudeAccountsFile?,
                        context: ClaudeHelperContext) -> (account: ClaudeAccount?, problem: String) {
        let shown = clean(name, limit: 80)
        guard let file, !file.named.isEmpty else {
            return (nil, "brim-claude: no Claude account is named \"\(shown)\" (Brim has not listed any account yet)")
        }
        switch file.match(name, home: context.home) {
        case .one(let account):
            return (account, "")
        case .none:
            return (nil, "brim-claude: no Claude account is named \"\(shown)\". Use one of these names exactly:\n"
                        + accountList(file, context: context))
        case .several(let accounts):
            return (nil, "brim-claude: \"\(shown)\" names \(accounts.count) accounts whose names differ only in case; "
                        + "name one by its folder instead:\n" + accountList(file, context: context))
        }
    }

    /// One line per named account: the name `cc` takes, then its folder.
    static func accountList(_ file: ClaudeAccountsFile, context: ClaudeHelperContext) -> String {
        let labels = file.named.map { clean($0.label, limit: 40) }
        let width = labels.map(\.count).max() ?? 0
        return zip(labels, file.named).map { label, account in
            let folder = account.isDefault ? "default: ~/.claude"
                : account.folder.hasPrefix(context.home + "/") ? "~" + account.folder.dropFirst(context.home.count) : account.folder
            return "  " + label.padding(toLength: width, withPad: " ", startingAt: 0) + "  (" + clean(folder, limit: 200) + ")"
        }.joined(separator: "\n")
    }

    /// `brim-claude account-name <text>`: the account's exact name when
    /// <text> is an account's label as `cc` lists it, in any case (exit 0),
    /// else nothing (exit 1); never an id or a folder, so `claude default`
    /// is a prompt. The zsh `claude` asks it about a lone argument, so
    /// `claude sparkfx.ai` asks "did you mean cc sparkfx.ai?" instead of
    /// sending that as a prompt.
    static func accountName(_ arguments: [String], context: ClaudeHelperContext) -> ClaudeHelperResult {
        guard arguments.count == 1, let file = ClaudeAccountsFile.load(context.paths),
              case .one(let account) = file.match(arguments[0], labelsOnly: true) else {
            return ClaudeHelperResult(status: 1, stdout: "", stderr: "")
        }
        return .ok(clean(account.label, limit: 40))
    }

    // MARK: resolve

    /// A debugging view: accounts, merged readings, ranking and live sessions.
    /// Labels and folders only; no email, account id or token.
    static func resolve(context: ClaudeHelperContext) -> ClaudeHelperResult {
        var lines = ["state: \(context.paths.stateDirectory)"]
        guard let file = ClaudeAccountsFile.load(context.paths) else {
            lines.append("accounts.json: missing or unreadable; new sessions use the default account")
            return ClaudeHelperResult(status: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
        }
        let live = ClaudeLiveFile.loadAll(context.paths)
        let readings = ClaudeAccountRanking.readings(file, live: live)
        let model = ClaudeAccountRanking.modelHint(explicit: nil, sharedSettings: ClaudeFileIO.read(context.sharedRoot + "/settings.json"))
        lines.append("new sessions: \(file.newSessions == .auto ? "auto (ranking)" : file.newSessions.rawValue)")
        lines.append("model hint: \(model ?? "none")")
        lines.append("")
        lines.append("accounts:")
        let isLaunchable = launchable(context)
        for group in ClaudeAccountsDiscovery.groups(file.accounts, launchable: isLaunchable) {
            let account = group.primary
            let signedIn = account.signedIn.map { $0 ? "signed in" : "SIGNED OUT" } ?? "sign-in unknown"
            lines.append("  \(account.label) [\(account.id)] \(describeFolder(account)); \(account.plan ?? "plan unknown"); \(signedIn)")
            if group.sharesSignIn {
                lines.append("    " + sameSignIn(group.members))
            }
            for folder in group.members {
                if let problem = launchProblem(folder, context: context) {
                    lines.append("    PROBLEM\(group.sharesSignIn ? " (" + folder.label + ")" : ""): \(problem); never picked")
                }
            }
            let sessions = group.members.flatMap {
                ClaudeSessionIndex.liveSessions(configDirectory: $0.configDirectory(home: context.home), isAlive: context.isAlive)
            }
            lines.append("    live sessions: \(sessions.count)" + (sessions.isEmpty ? "" : " (" + sessions.map {
                "pid \($0.pid) \($0.status ?? "?") in \($0.cwd ?? "?")"
            }.joined(separator: "; ") + ")"))
        }
        lines.append("")
        lines.append("ranking (now \(ClaudeDate.format(context.now))):")
        for (index, rank) in ClaudeAccountRanking.rank(file.accounts, readings: readings, model: model, now: context.now,
                                                       launchable: isLaunchable).enumerated() {
            let binding = rank.binding.map { "binding \($0.kind.label) \(format($0.headroom))% left" } ?? "no binding window"
            let shared = rank.sharesSignIn ? " (" + sameSignIn(rank.folders) + ")" : ""
            lines.append("  \(index + 1). \(rank.account.label)\(shared): \(describe(rank.status)); \(binding)")
            for window in rank.windows {
                let resets = window.resetsAt.map { ClaudeDate.format($0) } ?? "no reset time"
                let age = Int(context.now.timeIntervalSince(window.observedAt) / 60)
                lines.append("     \(window.kind.label): \(format(window.utilization))%\(window.estimated ? " (renewed, estimated)" : ""), resets \(resets); \(window.source.rawValue), \(age) min ago\(window.applies ? "" : ", not for this model")")
            }
        }
        return ClaudeHelperResult(status: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    private static func describeFolder(_ account: ClaudeAccount) -> String {
        account.isDefault ? "(default: CLAUDE_CONFIG_DIR unset)" : account.folder
    }

    /// "same sign-in in 2 folders: rhodesconsulting (default: CLAUDE_CONFIG_DIR
    /// unset), stern (/Users/x/.claude-stern)", launches' folder first.
    static func sameSignIn(_ folders: [ClaudeAccount]) -> String {
        "same sign-in in \(folders.count) folders: "
            + folders.map { "\($0.label) \($0.isDefault ? "(default: CLAUDE_CONFIG_DIR unset)" : "(" + $0.folder + ")")" }
                .joined(separator: ", ")
    }

    private static func describe(_ status: ClaudeAccountStatus) -> String {
        switch status {
        case .usable: return "usable"
        case .limited(let until): return "over a limit until " + (until.map { ClaudeDate.format($0) } ?? "unknown")
        case .unknown: return "UNKNOWN (no weekly reading)"
        case .signedOut: return "signed out"
        }
    }

    /// resolve's numbers, like its UTC dates, read the same on every Mac: a
    /// point for the decimal, whatever the region.
    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value))
            : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    // MARK: selftest

    /// Parses built-in fixtures and checks the results; build.sh runs it on
    /// every build. Touches no file.
    static func selftest() -> ClaudeHelperResult {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

        check(ClaudeAccountKey.key(forFolder: "") == "default", "the default account's key")
        check(ClaudeAccountKey.key(forFolder: "/Users/elliotgrayco/.claude-stern") == "575e0284", "a folder's key is its keychain suffix")

        let config = """
            {"oauthAccount":{"accountUuid":"00000000-0000-4000-8000-000000000001","emailAddress":"person@example.com",
             "organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x"},
             "cachedUsageUtilization":{"fetchedAtMs":1794510510573,"accountUuid":"00000000-0000-4000-8000-000000000001",
             "utilization":{"five_hour":null,"seven_day":{"utilization":39,"resets_at":"2026-11-15T14:00:00.469636+00:00"},
             "limits":[{"kind":"weekly_all","group":"weekly","percent":39,"resets_at":"2026-11-15T14:00:00.469636+00:00","is_active":false},
                       {"kind":"weekly_scoped","group":"weekly","percent":62,"resets_at":"2026-11-15T14:00:00.469819+00:00",
                        "scope":{"model":{"id":null,"display_name":"Fable"}},"is_active":true}]}}}
            """
        let snapshot = ClaudeUsageDecoding.snapshot(configData: Data(config.utf8))
        let reading = snapshot?.usage?.reading
        check(snapshot?.usageStatus == .accepted && snapshot?.identity?.plan == "Max 20x", "a .claude.json decodes")
        check(reading?.sevenDay?.utilization == 39 && reading?.scopedWindow(model: "Fable")?.utilization == 62
              && reading?.fiveHour == nil, "its windows decode")

        let status = """
            {"session_id":"s1","cwd":"/tmp","model":{"id":"claude-fable-5","display_name":"Fable 5"},
             "rate_limits":{"five_hour":{"used_percentage":12.4,"resets_at":1794600000},
                            "seven_day":{"used_percentage":39,"resets_at":1794751200}}}
            """
        let input = ClaudeUsageDecoding.statusLineInput(Data(status.utf8))
        check(input?.fiveHour?.usedPercentage == 12.4 && input?.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1_794_751_200),
              "a status line input decodes")
        if let input {
            let line = renderStatusLine(label: "work", input: input, scoped: reading?.scoped.first, now: Date(timeIntervalSince1970: 1_794_590_000), color: false)
            check(line.hasPrefix("work | 5h 12% ") && line.contains("wk 39%") && line.contains("Fable 62%"), "a status line renders: \(line)")
        }

        let now = Date(timeIntervalSince1970: 1_794_517_800)
        let accounts = [ClaudeAccount(label: "one", folder: "", signedIn: true),
                        ClaudeAccount(label: "two", folder: "/tmp/.claude-two", signedIn: true)]
        let soon = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 39, resetsAt: now.addingTimeInterval(2 * 86_400),
                                                                     observedAt: now, source: .cache))
        let later = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 1, resetsAt: now.addingTimeInterval(4 * 86_400),
                                                                      observedAt: now, source: .cache))
        let anyFolder: (ClaudeAccount) -> Bool = { _ in true }
        let ranked = ClaudeAccountRanking.rank(accounts, readings: [accounts[0].id: later, accounts[1].id: soon], model: nil, now: now,
                                               launchable: anyFolder)
        check(ranked.map(\.account.label) == ["two", "one"], "the soonest weekly renewal ranks first")
        let shared = [ClaudeAccount(label: "two", folder: "/tmp/.claude-two", accountUuid: "u", organizationUuid: "o", signedIn: true),
                      ClaudeAccount(label: "one", folder: "", accountUuid: "U", organizationUuid: "O", signedIn: true)]
        let newer = ClaudeAccountReading(sevenDay: ClaudeUsageWindow(utilization: 39, resetsAt: now.addingTimeInterval(2 * 86_400),
                                                                      observedAt: now.addingTimeInterval(60), source: .live))
        let one = ClaudeAccountRanking.rank(shared, readings: [shared[0].id: newer, shared[1].id: later], model: nil, now: now,
                                            launchable: anyFolder)
        check(one.count == 1 && one.first?.account.isDefault == true && one.first?.folders.count == 2
              && one.first?.windows.first?.utilization == 39,
              "folders that share a sign-in rank once, in the default folder, on the newest reading")
        let blocked = ClaudeAccountRanking.rank(shared, readings: [:], model: nil, now: now, launchable: { !$0.isDefault })
        check(blocked.first?.account.label == "two", "a shared sign-in launches in its first folder that can be launched")
        var team = shared
        team[1].organizationUuid = "another"
        check(ClaudeAccountRanking.rank(team, readings: [:], model: nil, now: now, launchable: anyFolder).count == 2,
              "one login in two organizations is two accounts")

        let environment = ClaudeLaunchEnvironment.environment(forFolder: "", base: ["CLAUDE_CONFIG_DIR": "/x", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/y"])
        check(environment["CLAUDE_CONFIG_DIR"] == nil && environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil,
              "the default account launches without CLAUDE_CONFIG_DIR")

        check(ClaudeSignIn.acceptedLink("https://claude.com/cai/oauth/authorize?login_hint=a%40b.com") != nil
              && ClaudeSignIn.acceptedLink("https://console.anthropic.com/x") != nil
              && ClaudeSignIn.acceptedLink("http://claude.com/x") == nil
              && ClaudeSignIn.acceptedLink("https://claude.com@evil.example/x") == nil
              && ClaudeSignIn.acceptedLink("https://claude.com.evil.example/x") == nil,
              "only https sign-in links on claude.com, claude.ai or anthropic.com are opened")
        let signIn = ClaudeSignIn.environment(folder: "", base: ["CLAUDE_CONFIG_DIR": "/x", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/y"],
                                              helper: "/h/brim-claude", urlFile: "/s/signin/t.url")
        check(signIn["CLAUDE_CONFIG_DIR"] == nil && signIn["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil
              && signIn["BROWSER"] == "/h/brim-claude" && signIn[ClaudeSignIn.urlFileVariable] == "/s/signin/t.url",
              "a sign-in in the default folder runs without CLAUDE_CONFIG_DIR, with brim-claude as its browser")
        check(ClaudeAccountList.normalizedEmail(" Pat <Pat@Example.COM> ") == "pat@example.com"
              && ClaudeAccountsDiscovery.label(email: "pat@rhodesconsultingllc.com", folder: "", taken: []) == "rhodesconsultingllc",
              "an email is taken as typed or pasted, and names its account")

        check(ClaudeMCPStripe.config == #"{"type":"http","url":"https://mcp.stripe.com"}"#
              && ClaudeMCPStripe.nicknameProblem("acme", taken: []) == nil
              && ClaudeMCPStripe.nicknameProblem("Acme", taken: []) == .characters,
              "a repo's Stripe server is Stripe's hosted server alone, signed in with OAuth")

        if failures.isEmpty { return .ok("brim-claude: ok") }
        return .fail(1, "brim-claude selftest failed:\n  " + failures.joined(separator: "\n  "))
    }
}
