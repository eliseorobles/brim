// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import AppKit
import Combine
import Foundation
import os.log

/// The browser that opens https links.
struct ClaudeSignInBrowser {
    var app: URL
    var bundleIdentifier: String?
    var name: String

    @MainActor
    static func current() -> ClaudeSignInBrowser? {
        guard let probe = URL(string: "https://claude.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        var name = FileManager.default.displayName(atPath: app.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        return ClaudeSignInBrowser(app: app, bundleIdentifier: Bundle(url: app)?.bundleIdentifier, name: name)
    }
}

/// An account's card on the island's AI page.
struct ClaudeAccountCard {
    var name: String
    var limits: AgentLimits?
    var plan: String?
    var checking: Bool
    var failure: AgentClaudeServer.Failure?
}

/// Brim's Claude Code accounts: one Claude Code config folder per account
/// (CLAUDE_CONFIG_DIR, never set for the default account), ranked by which
/// to use next. The person's list says which email each folder should hold
/// (ClaudeAccountList); Brim runs Claude Code's own sign-in for an account
/// (ClaudeSignIn) and checks the email it got. Claude Code signs in and
/// refreshes its own tokens; nothing here reads, copies, refreshes or writes
/// a credential.
///
/// Feeds, all event-driven (ClaudeAccountsWatcher): each session's status
/// line (live/), Claude Code's saved usage in each .claude.json, and, on
/// demand, a get_usage check (ClaudeRefreshGate says when). The app alone
/// writes accounts.json, atomically and only when it changes; the brim-claude
/// helper reads it to pick an account for `claude`, `cc` and `cx`.
@MainActor
final class ClaudeAccountsService: ObservableObject {
    static let shared = ClaudeAccountsService()

    @Published private(set) var accounts: [ClaudeAccount] = []
    @Published private(set) var rows: [ClaudeAccountRow] = []
    /// The person's list: one entry per expected email (ClaudeAccountList).
    @Published private(set) var entries: [ClaudeAccountEntry] = []
    /// What the panel and Settings list: signed-in accounts in ranking
    /// order, then the accounts waiting for their sign-in.
    @Published private(set) var items: [ClaudeAccountItem] = []
    /// The person answered "Any other Claude accounts?".
    @Published private(set) var othersAsked = false
    /// The sign-in Brim runs now, if any; one at a time.
    @Published private(set) var signIn: ClaudeSignInState?
    @Published private(set) var newSessions: ClaudeNewSessions = .auto
    /// The model new sessions run by default (the shared settings.json).
    @Published private(set) var modelHint: String?
    /// The shared settings.json sets what would send every account to one
    /// folder or move every sign-in.
    @Published private(set) var settingsProblems: [ClaudeShareProblem] = []
    /// False after a check found no Claude Code to run.
    @Published private(set) var claudeFound = true
    @Published private(set) var isRunning = false
    /// Conversations held open on one account, out of the others' /resume
    /// (the menu says where, T-50).
    @Published private(set) var held: [ClaudeHeldConversation] = []

    let home: String
    let paths: ClaudeAccountsPaths

    nonisolated private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brim", category: "claude-accounts")

    /// Readings from Claude Code's saved usage and Brim's checks, by account
    /// id: what accounts.json keeps.
    private var savedReadings: [String: ClaudeAccountReading] = [:]
    private var live: [String: ClaudeLiveFile] = [:]
    /// A live file older than this belongs to the sign-in before (by id).
    private var liveSince: [String: Date] = [:]
    private var cacheFetched: [String: Int64] = [:]
    private var identities: [String: ClaudeIdentity] = [:]
    private var liveCounts: [String: Int] = [:]
    private var failures: [String: AgentClaudeServer.Failure] = [:]
    private var mcpNeedsLogin: [String: [String]] = [:]
    /// Every folder whose .claude.json is watched: accounts and candidates.
    private var watchedFolders: [String] = []
    private var gate = ClaudeRefreshGate()
    private var request: AgentClaudeServer.Request?
    private var notified: Set<String> = []
    /// The first ranking after a start is the baseline: a window already
    /// over its alert level then is not news.
    private var primed = false
    private var pushed: (limits: AgentLimits?, plan: AgentPlan?)?
    private var reportedFolders: [String]?
    private var deadline: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var watcher: ClaudeAccountsWatcher?
    /// Keeps every account's conversations, plans and memory one (ClaudeSync).
    private var syncWatcher: ClaudeSyncWatcher?
    /// The sync's newest list of held conversations (ClaudeSync.Report.open).
    private var heldOpen: [String: ClaudeSync.Open] = [:]
    private var terminateObserver: NSObjectProtocol?
    private var signInRun: ClaudeSignInRun?
    /// The newest .claude.json state of every folder looked at, for
    /// planning a new account's folder without reading them all again.
    private var folderStates: [String: ClaudeFolderState] = [:]
    /// get_usage checks and MCP commands (ClaudeMCPModel): one Claude Code
    /// process at a time.
    let processQueue = DispatchQueue(label: "brim.claude-accounts.process", qos: .utility)
    /// Share-setup and tidy-up plans and runs, which can walk large folders.
    private let workQueue = DispatchQueue(label: "brim.claude-accounts.work", qos: .userInitiated)
    /// Opening the sign-in link in a private window.
    private let signInQueue = DispatchQueue(label: "brim.claude-accounts.signin", qos: .userInitiated)

    init(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        paths = ClaudeAccountsPaths(environment: environment, home: home)
    }

    // MARK: Entry points for callers on the main thread that are not marked so

    /// The feature runtime's binding for the AI agents feature.
    nonisolated static func syncWithFeature() {
        MainActor.assumeIsolated { shared.syncWithPreferences() }
    }

    /// Every account's folder, whose logs AgentUsageService reads ("" is the
    /// default account).
    nonisolated static func logFolders() -> [String] {
        MainActor.assumeIsolated {
            shared.syncWithPreferences()
            return shared.accounts.isEmpty ? [""] : shared.accounts.map(\.folder)
        }
    }

    /// One id per Claude account, for its card on the island.
    nonisolated static func accountIDs() -> [String] {
        MainActor.assumeIsolated { shared.cardIDs }
    }

    /// One id per Claude account (the folder launches use): folders that
    /// share a sign-in have one card and one place in the pickers.
    var cardIDs: [String] { groups.map(\.primary.id) }

    /// The Claude accounts: folders that share a sign-in together, each led
    /// by the folder launches and checks use.
    var groups: [ClaudeAccountGroup] { ClaudeAccountsDiscovery.groups(accounts, launchable: launchable) }

    private func group(of id: String) -> ClaudeAccountGroup? {
        ClaudeAccountsDiscovery.group(of: id, in: accounts, launchable: launchable)
    }

    /// The launch check grouping takes, the one brim-claude passes too: the
    /// app checks an account in the folder the helper launches it in.
    private var launchable: (ClaudeAccount) -> Bool {
        ClaudeAccountsDiscovery.launchable(home: home)
    }

    /// The AI page appeared.
    nonisolated static func foregroundEvent() {
        MainActor.assumeIsolated { shared.foreground() }
    }

    // MARK: Lifecycle

    /// Runs while the AI agents feature is installed, with or without the
    /// Dynamic Island.
    func syncWithPreferences() {
        if AppFeature.notchAgents.isAvailable { start() } else { stop() }
    }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        do {
            try paths.ensureDirectory(paths.liveDirectory)
            try paths.ensureDirectory(paths.requestsDirectory)
        } catch {
            Self.log.error("claude state folder: \(String(describing: error), privacy: .public)")
        }
        // No sign-in runs yet: whatever a sign-in left is stale.
        ClaudeSignIn.sweep(directory: paths.signInDirectory)
        let stored = ClaudeAccountsFile.load(paths)
        newSessions = stored?.newSessions ?? .auto
        savedReadings = stored?.readings ?? [:]
        othersAsked = stored?.othersAsked ?? false
        accounts = stored?.accounts ?? []
        let scan = ClaudeAccountsDiscovery.scan(home: home, listed: accounts.map(\.folder))
        absorb(scan.states, discovered: scan.discovered, folders: Array(scan.states.keys))
        live = ClaudeLiveFile.loadAll(paths)
        applySettings(ClaudeFileIO.read(home + "/.claude/settings.json", limit: 4 << 20))
        for account in accounts {
            liveCounts[account.id] = ClaudeSessionIndex.liveSessions(configDirectory: account.configDirectory(home: home)).count
        }
        readMCPLogins()
        let watcher = ClaudeAccountsWatcher { change in
            DispatchQueue.main.async { MainActor.assumeIsolated { ClaudeAccountsService.shared.apply(change) } }
        }
        self.watcher = watcher
        syncWatcher = ClaudeSyncWatcher(statePath: ClaudeSync.statePath(paths), sharedSettings: home + "/.claude/settings.json",
                                        diverged: { ids in
            DispatchQueue.main.async { MainActor.assumeIsolated { ClaudeAccountsService.shared.notifyDiverged(ids) } }
        }, held: { open in
            DispatchQueue.main.async { MainActor.assumeIsolated { ClaudeAccountsService.shared.updateHeld(open) } }
        })
        rewatch()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ClaudeAccountsService.shared.foreground() }
        }
        // A sign-in's child is Brim's own: it ends with the app.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ClaudeAccountsService.shared.cancelSignIn() }
        }
        // Requests left while Brim was not running.
        for id in ClaudeRefreshRequests.consume(paths) { queueCheck(id, force: false) }
        update()
        primed = true
        if accounts.count > 1 { Notifier.requestPermission() }
        pump()
    }

    private func stop() {
        guard isRunning else { return }
        cancelSignIn()
        isRunning = false
        request?.cancel()
        request = nil
        gate.cancelled()
        watcher?.stop()
        watcher = nil
        syncWatcher?.stop()
        syncWatcher = nil
        heldOpen = [:]
        held = []
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
        deadline?.invalidate()
        deadline = nil
        accounts = []
        rows = []
        entries = []
        items = []
        folderStates = [:]
        live = [:]
        liveSince = [:]
        liveCounts = [:]
        failures = [:]
        cacheFetched = [:]
        identities = [:]
        notified = []
        primed = false
        watchedFolders = []
        reportedFolders = nil
        pushed = nil
        AgentUsageService.shared.setClaude(limits: nil, plan: nil)
    }

    // MARK: Foreground events

    /// The menu panel, the AI page or Settings appeared, or the Mac woke:
    /// checks the accounts whose newest reading is older than 15 minutes,
    /// and reads again what file events may have missed.
    func foreground() {
        guard isRunning else { return }
        watcher?.lookAgain()
        // Whether a held conversation now waits at its usage limit shows in
        // its transcript, which nothing watches: read it when the menu opens.
        if !heldOpen.isEmpty { describeHeld() }
        for account in checkedAccounts { queueCheck(account.id, force: false) }
        pump()
    }

    /// One folder per signed-in Claude account: a check answers for every
    /// folder that shares the sign-in.
    private var checkedAccounts: [ClaudeAccount] {
        groups.map(\.primary).filter { $0.signedIn != false }
    }

    /// Refresh: checks the account now, fresh reading or not; one check at a
    /// time still.
    func refresh(id: String) {
        guard isRunning else { return }
        queueCheck(id, force: true)
        pump()
    }

    func refreshAll() {
        guard isRunning else { return }
        for account in checkedAccounts { queueCheck(account.id, force: true) }
        pump()
    }

    // MARK: Feeds

    private func apply(_ change: ClaudeAccountsWatcher.Change) {
        guard isRunning else { return }
        if let scan = change.scan {
            absorb(scan.states, discovered: scan.discovered, folders: Array(scan.states.keys))
        }
        if !change.states.isEmpty {
            // A candidate folder that signed in becomes an account.
            let discovered = change.states.filter { folder, state in
                !accounts.contains { $0.folder == folder } && state.snapshot?.signedIn == true
            }.map(\.key)
            absorb(change.states, discovered: discovered, folders: watchedFolders)
        }
        for (folder, count) in change.sessions {
            liveCounts[ClaudeAccountKey.key(forFolder: folder)] = count
        }
        if let files = change.live { live = files }
        if let settings = change.settings { applySettings(settings) }
        for id in change.requests { queueCheck(id, force: false) }
        if change.scan != nil || !change.sessions.isEmpty { readMCPLogins() }
        update()
        pump()
    }

    /// Takes what the disk says about the folders: the account list, each
    /// sign-in, and Claude Code's saved usage when it is news. Every email a
    /// folder holds that no account expects joins the list
    /// (ClaudeAccountList.expect).
    private func absorb(_ states: [String: ClaudeFolderState], discovered: [String], folders: [String]) {
        let previous = accounts
        folderStates.merge(states) { _, new in new }
        let merged = ClaudeAccountList.expect(ClaudeAccountsDiscovery.merge(stored: accounts, discovered: discovered,
                                                                            states: states), launchable: launchable)
        if merged != accounts { accounts = merged }
        gate.keep(only: Set(merged.map(\.id)))
        for account in merged {
            guard let snapshot = states[account.folder]?.snapshot else { continue }
            take(snapshot, for: account, previously: previous.first { $0.folder == account.folder })
        }
        watchedFolders = Array(Set(folders + merged.map(\.folder))).sorted()
        // The watcher restarts its stream only when the paths changed.
        rewatch()
    }

    private func take(_ snapshot: ClaudeConfigSnapshot, for account: ClaudeAccount, previously: ClaudeAccount?) {
        let id = account.id
        let known = identities[id]
        let before = known?.accountUuid ?? previously?.accountUuid
        let beforeOrganization = known.map(\.organizationUuid) ?? previously?.organizationUuid
        if let identity = snapshot.identity {
            identities[id] = identity
            // Another sign-in in this folder (another account, or the same
            // login in another organization): what was read is the one before's.
            if before != nil, !ClaudeAccountsDiscovery.sameSignIn(accountUuid: before, organizationUuid: beforeOrganization,
                                                                  as: identity.accountUuid, identity.organizationUuid) {
                savedReadings[id] = nil
                cacheFetched[id] = nil
                failures[id] = nil
                liveSince[id] = Date()
            }
        }
        if ClaudeUsageDecoding.isNewer(snapshot, than: cacheFetched[id]), let usage = snapshot.usage {
            cacheFetched[id] = usage.fetchedAtMs
            if let reading = usage.reading { savedReadings[id] = ClaudeAccountRanking.merge([savedReadings[id], reading]) }
        }
        // A sign-in finished while Brim watched: check the account now.
        if primed, previously?.signedIn != true, snapshot.signedIn {
            failures[id] = nil
            queueCheck(id, force: true)
        }
    }

    private func applySettings(_ data: Data?) {
        let problems = ClaudeSetupSharing.settingsProblems(data)
        if problems != settingsProblems { settingsProblems = problems }
        let model = ClaudeAccountRanking.modelHint(explicit: nil, sharedSettings: data)
        if model != modelHint { modelHint = model }
    }

    /// The MCP servers each account still has to sign in to, from Claude
    /// Code's own record (ClaudeMCPNeedsAuth, names only).
    private func readMCPLogins() {
        var found: [String: [String]] = [:]
        for account in accounts {
            let path = ClaudeMCPNeedsAuth.path(configDirectory: account.configDirectory(home: home))
            let names = ClaudeMCPNeedsAuth.names(ClaudeFileIO.read(path, limit: 1 << 20))
            if !names.isEmpty { found[account.id] = names.sorted() }
        }
        mcpNeedsLogin = found
    }

    private func rewatch() {
        guard let watcher else { return }
        watcher.update(ClaudeAccountsWatcher.Plan(home: home, paths: paths, folders: watchedFolders,
                                                  accountFolders: accounts.map(\.folder)))
        syncWatcher?.update(configDirectories: ClaudeAccount.configDirectories(home: home, accounts: accounts))
    }

    // MARK: Ranking

    /// Accounts.json's readings (saved usage and checks) merged with the live
    /// feed, per window, newest first, for one folder.
    private func folderReading(_ id: String) -> ClaudeAccountReading? {
        var liveReading = live[id]?.reading
        if let since = liveSince[id], let file = live[id], file.observedAt < since { liveReading = nil }
        return ClaudeAccountRanking.merge([savedReadings[id], liveReading])
    }

    /// The reading of the Claude account `id` belongs to: every folder that
    /// shares its sign-in, merged per window, newest first.
    private func reading(_ id: String) -> ClaudeAccountReading? {
        let folders = group(of: id)?.members.map(\.id) ?? [id]
        return ClaudeAccountRanking.merge(folders.map(folderReading))
    }

    private func update() {
        guard isRunning else { return }
        let now = Date()
        // A choice of a folder that shares its sign-in is the choice of the
        // account, kept under the folder launches use.
        if case .account(let id) = newSessions, let group = self.group(of: id),
           group.primary.id != id {
            newSessions = .account(group.primary.id)
        }
        var readings: [String: ClaudeAccountReading] = [:]
        for account in accounts { readings[account.id] = folderReading(account.id) }
        let ranks = ClaudeAccountRanking.rank(accounts, readings: readings, model: modelHint, now: now, launchable: launchable)
        let next = ranks.enumerated().map { position, rank in
            let ids = rank.folders.map(\.id)
            return ClaudeAccountRow(rank: rank, position: position, liveSessions: ids.reduce(0) { $0 + (liveCounts[$1] ?? 0) },
                                    checking: ids.contains(where: gate.isChecking),
                                    failure: failures[rank.account.id] ?? ids.lazy.compactMap { self.failures[$0] }.first,
                                    launchProblem: ClaudeAccountsDiscovery.launchProblem(rank.account, home: home),
                                    mcpNeedsLogin: Array(Set(ids.flatMap { mcpNeedsLogin[$0] ?? [] })).sorted())
        }
        if next != rows { rows = next }
        let list = ClaudeAccountList.entries(accounts, launchable: launchable)
        if list != entries { entries = list }
        let shown = ClaudeAccountsAppSupport.items(rows: next, entries: list)
        if shown != items { items = shown }
        save()
        push(ranks)
        alert(ranks)
        armDeadline(ranks, now: now)
        reportFolders()
    }

    /// accounts.json, when its content changed.
    private func save() {
        let ids = Set(accounts.map(\.id))
        savedReadings = savedReadings.filter { ids.contains($0.key) }
        do {
            try ClaudeAccountsFile(accounts: accounts, newSessions: newSessions, readings: savedReadings,
                                   othersAsked: othersAsked).save(paths)
        } catch {
            Self.log.error("accounts.json: \(String(describing: error), privacy: .public)")
        }
    }

    /// Gives the island the account Claude works on and the plan.
    private func push(_ ranks: [ClaudeAccountRank]) {
        let focus = ClaudeAccountsAppSupport.focus(ranks, liveSessions: liveCounts, live: live, newSessions: newSessions)
        let limits = focus.flatMap(ClaudeAccountsAppSupport.limits)
        let plans = ClaudeAccountsAppSupport.accountIdentities(groups, identities: identities).compactMap {
            AgentPlans.claude(organizationType: $0.organizationType, rateLimitTier: $0.rateLimitTier)
        }
        let plan = ClaudeAccountsAppSupport.plan(plans)
        if let pushed, pushed.limits == limits, pushed.plan == plan { return }
        pushed = (limits, plan)
        AgentUsageService.shared.setClaude(limits: limits, plan: plan)
    }

    /// AgentUsageService reads every account's logs; when the folders change
    /// it starts its reading over.
    private func reportFolders() {
        let folders = accounts.map(\.folder)
        guard let reportedFolders else {
            self.reportedFolders = folders
            return
        }
        guard folders != reportedFolders else { return }
        self.reportedFolders = folders
        // Only while it reads at all (the island's AI section is on).
        DispatchQueue.main.async {
            if NotchAgentSupport.isEnabled() { AgentUsageService.shared.syncWithPreferences() }
        }
    }

    /// The sync found the held conversations changed.
    func updateHeld(_ open: [String: ClaudeSync.Open]) {
        heldOpen = open
        describeHeld()
    }

    /// Puts the held conversations in words off the main thread (it reads
    /// the end of each transcript), then shows them.
    private func describeHeld() {
        let open = heldOpen
        let accounts = accounts
        let home = home
        workQueue.async {
            let described = ClaudeHeldConversation.describe(open, accounts: accounts, home: home)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let service = ClaudeAccountsService.shared
                    // A newer list arrived meanwhile: its own pass shows it.
                    guard service.heldOpen == open, service.held != described else { return }
                    service.held = described
                }
            }
        }
    }

    /// A notice per conversation the sync found continued on two accounts
    /// (each keeps its own version); the sync reports each one once.
    func notifyDiverged(_ ids: [String]) {
        for id in ids {
            Notifier.post(title: strings.divergedTitle, body: strings.divergedBody(ClaudeSync.shortId(id)))
        }
    }

    /// A notice when an account with running sessions reaches 90 % of its
    /// 5-hour window or 95 % of a weekly one, once per window, naming the
    /// best account to move to and the `cx` command.
    private func alert(_ ranks: [ClaudeAccountRank]) {
        let result = ClaudeLimitAlerts.news(ranks, liveSessions: liveCounts, notified: notified)
        notified = result.remembered
        guard primed else { return }
        let text = strings
        for crossing in result.news {
            let target = ClaudeLimitAlerts.target(for: crossing.accountID, in: ranks)
            let window = crossing.kind == .fiveHour ? text.fiveHour
                : crossing.kind == .weekly ? text.weekly : crossing.kind.label
            let percent = AgentFormat.percent(crossing.utilization / 100)
            Notifier.post(title: text.notifyTitle(crossing.label),
                          body: text.notifyBody(window: window, percent: percent, target: target?.account.label))
        }
    }

    /// Rule 1 exception, recorded here: ONE one-shot timer, never repeating,
    /// at the earliest coming renewal (resets_at) of any window. No feed
    /// reports a renewal, so without it the ranking and the panel would keep
    /// a renewed window's old use until the next event. It is armed again on
    /// every change; it only ranks again and starts no Claude Code process.
    /// Only renewals a feed reported arm it: an estimated one (a week after a
    /// renewal Brim has not seen confirmed) would wake the app on a guess.
    private func armDeadline(_ ranks: [ClaudeAccountRank], now: Date) {
        deadline?.invalidate()
        deadline = nil
        guard let next = ranks.flatMap(\.windows).filter({ !$0.estimated }).compactMap(\.resetsAt).filter({ $0 > now }).min()
        else { return }
        let timer = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { ClaudeAccountsService.shared.update() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        deadline = timer
    }

    // MARK: Checks

    /// A check of the Claude account `id` belongs to runs in the folder its
    /// launches use: one check answers for every folder of a shared sign-in.
    private func queueCheck(_ id: String, force: Bool) {
        guard let account = group(of: id)?.primary else { return }
        if !force && account.signedIn == false { return }
        if gate.request(account.id, reading: reading(account.id), model: modelHint, now: Date(), force: force) {
            update()
        }
    }

    /// Starts the next queued check when none runs.
    private func pump() {
        guard isRunning, request == nil else { return }
        while let id = gate.next() {
            guard let account = accounts.first(where: { $0.id == id }),
                  ClaudeLaunchEnvironment.launchProblem(forFolder: account.folder, home: home) == nil else {
                gate.finished(id, succeeded: false, at: Date())
                continue
            }
            let request = AgentClaudeServer.Request()
            self.request = request
            let homeURL = URL(fileURLWithPath: home)
            let folder = account.folder
            processQueue.async {
                let result: Result<AgentClaudeServer.Summary, AgentClaudeServer.Failure>
                if let executable = AgentClaudeServer.executable(home: homeURL, searchPath: ProcessInfo.processInfo.environment["PATH"]) {
                    var environment = AgentCodexServer.environment(for: executable, searchPath: nil)
                    environment["PATH"] = AgentClaudeServer.searchPath(after: environment["PATH"] ?? "", home: homeURL)
                    result = request.run(executable, home: homeURL, environment: environment, folder: folder)
                } else {
                    result = .failure(.missing)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { ClaudeAccountsService.shared.finish(id, request: request, result: result) }
                }
            }
            update()
            return
        }
    }

    private func finish(_ id: String, request: AgentClaudeServer.Request,
                        result: Result<AgentClaudeServer.Summary, AgentClaudeServer.Failure>) {
        guard self.request === request else { return }
        self.request = nil
        let now = Date()
        switch result {
        case .success(let summary):
            gate.finished(id, succeeded: true, at: now)
            failures[id] = nil
            claudeFound = true
            // Kept only while the folder still holds the sign-in it checked.
            if ClaudeAccountsDiscovery.sameSignIn(accountUuid: summary.identity?.accountUuid,
                                                  organizationUuid: summary.identity?.organizationUuid,
                                                  as: identities[id]?.accountUuid, identities[id]?.organizationUuid) {
                savedReadings[id] = ClaudeAccountRanking.merge([savedReadings[id], summary.reading])
            }
        case .failure(let failure):
            gate.finished(id, succeeded: false, at: now)
            failures[id] = failure
            claudeFound = failure != .missing
        }
        update()
        pump()
    }

    // MARK: For the views

    var strings: ClaudeAccountsStrings { FeatureStrings.claudeAccounts(L10n.shared.language) }

    /// The row of the Claude account `id` (any of its folders) belongs to.
    func row(id: String) -> ClaudeAccountRow? { rows.first { $0.rank.contains(id) } }

    /// The island's card for an account, its windows as they stand at `now`.
    func card(id: String, now: Date) -> ClaudeAccountCard? {
        guard let row = row(id: id) else { return nil }
        let rank = ClaudeAccountRanking.assess(row.account, reading: reading(row.id), model: modelHint, now: now)
        return ClaudeAccountCard(name: row.account.label, limits: ClaudeAccountsAppSupport.limits(rank),
                                 plan: row.account.plan, checking: row.checking, failure: row.failure)
    }

    /// The bundled helper and zsh file of this copy of Brim.
    var bundledHelper: String { Bundle.main.bundlePath + "/Contents/Helpers/brim-claude" }
    var bundledShellScript: Data? { ClaudeFileIO.read(Bundle.main.bundlePath + "/Contents/Resources/brim-claude.zsh") }

    /// The helper path the status line runs: the shell integration's link to
    /// this copy of Brim when it is in place, else the bundled helper.
    var statusLineHelper: String {
        let link = ClaudeShellIntegration.linkPath(home: home)
        return ClaudeFileIO.linkDestination(link) == bundledHelper ? link : bundledHelper
    }

    // MARK: Actions (each runs only when the person asks)

    func setNewSessions(_ choice: ClaudeNewSessions) {
        guard choice != newSessions else { return }
        newSessions = choice
        update()
    }

    /// nil when renamed, else why not.
    func rename(id: String, to label: String) -> String? {
        let others = accounts.filter { $0.id != id }.map(\.label)
        if let problem = ClaudeAccountsDiscovery.labelProblem(label, others: others) { return problem }
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return nil }
        accounts[index].label = label
        update()
        return nil
    }

    /// A Terminal window running Claude Code on the account. nil when opened,
    /// else why not.
    @discardableResult
    func openTerminal(id: String) -> String? {
        guard let account = accounts.first(where: { $0.id == id }) else { return nil }
        if let problem = ClaudeLaunchEnvironment.launchProblem(forFolder: account.folder, home: home) { return problem }
        let executable = AgentClaudeServer.executable(home: URL(fileURLWithPath: home),
                                                      searchPath: ProcessInfo.processInfo.environment["PATH"])?.path ?? "claude"
        let script = ClaudeLaunchEnvironment.terminalScript(forFolder: account.folder, arguments: [],
                                                             executable: executable, directory: home)
        let file = FileManager.default.temporaryDirectory.appending(path: "brim-claude-\(UUID().uuidString).command")
        do {
            try ClaudeFileIO.writeAtomically(Data(script.utf8), to: file.path, mode: 0o700)
        } catch {
            return ClaudeFileError.message(error)
        }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            try? FileManager.default.removeItem(at: file)
            return "Terminal was not found"
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: configuration) { _, error in
            if let error { Self.log.error("terminal: \(error.localizedDescription, privacy: .public)") }
        }
        return nil
    }

    /// "cx --to <label>" on the clipboard: after /exit, it continues the
    /// conversation on that account.
    func copyMoveCommand(id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareBrimSource()
        pasteboard.setString("cx --to " + ClaudeLaunchEnvironment.shellQuote(account.label), forType: .string)
    }

    // MARK: The account list

    /// Show "Any other Claude accounts?": until the person answered it, and
    /// whenever the list is empty.
    var asksForOthers: Bool { isRunning && (!othersAsked || entries.isEmpty) }

    /// "~/.claude (default)" or the folder with the home folder as "~".
    func shortFolder(_ folder: String) -> String {
        if folder.isEmpty { return strings.defaultFolder }
        return folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder
    }

    /// What adding `email` would do (ClaudeAccountList.planAdd), from the
    /// states Brim already read.
    func planAdd(email: String, chosenFolder: String?) -> Result<ClaudeAccountList.AddPlan, ClaudeAccountList.AddProblem> {
        let candidates = ClaudeAccountsDiscovery.candidateFolders(home: home) + accounts.map(\.folder).filter { !$0.isEmpty }
        var states = folderStates
        for folder in [""] + candidates where states[folder] == nil {
            states[folder] = ClaudeAccountsDiscovery.state(folder: folder, home: home)
        }
        return ClaudeAccountList.planAdd(email: email, chosenFolder: chosenFolder, accounts: accounts,
                                         candidates: candidates, states: states, home: home)
    }

    func describe(_ problem: ClaudeAccountList.AddProblem) -> String {
        let text = strings
        switch problem {
        case .invalidEmail: return text.invalidEmail
        case .alreadyListed(let label): return text.alreadyListed(label)
        case .alreadySignedIn(let folder): return text.alreadySignedIn(shortFolder(folder))
        case .folderTaken(let owner): return text.folderTaken(owner)
        case .folder(let message): return message
        }
    }

    /// Adds the account to the list: its folder is the one planned (a free
    /// one reused, the chosen one, or a new ~/.claude-<label>, made mode
    /// 0700). Nothing signs in; the row offers Sign in. nil when added,
    /// else why not.
    func addAccount(email: String, chosenFolder: String?) -> String? {
        guard isRunning else { return nil }
        let plan: ClaudeAccountList.AddPlan
        switch planAdd(email: email, chosenFolder: chosenFolder) {
        case .success(let planned): plan = planned
        case .failure(let problem): return describe(problem)
        }
        if !plan.reuses {
            do {
                try FileManager.default.createDirectory(atPath: plan.folder, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                return error.localizedDescription
            }
        }
        if let index = accounts.firstIndex(where: { $0.folder == plan.folder }) {
            accounts[index].expectedEmail = plan.email
            accounts[index].label = plan.label
        } else {
            let state = folderStates[plan.folder] ?? ClaudeAccountsDiscovery.state(folder: plan.folder, home: home)
            accounts.append(ClaudeAccount(label: plan.label, folder: plan.folder,
                                          signedIn: state == .missing ? false : state.snapshot?.signedIn,
                                          expectedEmail: plan.email))
        }
        othersAsked = true
        let scan = ClaudeAccountsDiscovery.scan(home: home, listed: accounts.map(\.folder))
        absorb(scan.states, discovered: scan.discovered, folders: Array(scan.states.keys))
        update()
        return nil
    }

    /// "That's all": the list is complete for now.
    func finishAskingForOthers() {
        guard !othersAsked else { return }
        othersAsked = true
        update()
    }

    // MARK: Sign-in (Brim runs it; ClaudeSignIn)

    /// Runs `claude auth login --claudeai --email <expected>` on the
    /// account's folder as Brim's own child, with brim-claude as its
    /// browser. Problems show in the sheet.
    func startSignIn(id: String) {
        guard isRunning, let account = accounts.first(where: { $0.id == id }), let email = account.expectedEmail else { return }
        // One at a time. The sheet's state is replaced, never cleared, so
        // Try again keeps the sheet open.
        signInRun?.cancel()
        signInRun = nil
        var state = ClaudeSignInState(accountID: id, label: account.label, email: email, folder: account.folder)
        state.liveSessions = ClaudeSessionIndex.liveSessions(configDirectory: account.configDirectory(home: home))
            .map(ClaudeSessionIndex.describe)
        func fail(_ message: String) {
            state.phase = .failed(message)
            signIn = state
        }
        if let problem = ClaudeLaunchEnvironment.launchProblem(forFolder: account.folder, home: home) { return fail(problem) }
        let homeURL = URL(fileURLWithPath: home)
        guard let executable = AgentClaudeServer.executable(home: homeURL, searchPath: ProcessInfo.processInfo.environment["PATH"]) else {
            claudeFound = false
            return fail(strings.claudeMissing)
        }
        guard FileManager.default.isExecutableFile(atPath: bundledHelper) else { return fail(strings.helperMissing) }
        let urlFile = ClaudeSignIn.urlFile(directory: paths.signInDirectory, token: ClaudeSignIn.newToken())
        var base = AgentCodexServer.environment(for: executable, searchPath: nil)
        base["PATH"] = AgentClaudeServer.searchPath(after: base["PATH"] ?? "", home: homeURL)
        let environment = ClaudeSignIn.environment(folder: account.folder,
                                                   base: AgentClaudeServer.environment(base, home: homeURL, folder: account.folder),
                                                   helper: bundledHelper, urlFile: urlFile)
        let runID = state.id
        let run = ClaudeSignInRun(executable: executable.path, arguments: ClaudeSignIn.arguments(email: email),
                                  environment: environment, urlFile: urlFile) { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ClaudeAccountsService.shared.signInEvent(event, runID: runID) }
            }
        }
        do {
            try run.start()
        } catch {
            return fail(ClaudeFileError.message(error))
        }
        signInRun = run
        signIn = state
    }

    /// Try again: a new sign-in (and a new private window) for the same account.
    func retrySignIn() {
        guard let id = signIn?.accountID else { return }
        startSignIn(id: id)
    }

    /// Ends Brim's own login child, if one runs, deletes its link file and
    /// closes the sheet. With `runID`, only while that sign-in is the one
    /// running: a sheet that goes away never ends a sign-in it was not
    /// showing.
    func cancelSignIn(runID: UUID? = nil) {
        guard runID == nil || signIn?.id == runID else { return }
        signInRun?.cancel()
        signInRun = nil
        signIn = nil
    }

    /// The sign-in link on the clipboard, marked so clipboard histories do
    /// not keep it.
    func copySignInLink() {
        guard let link = signIn?.link else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareBrimSource()
        pasteboard.setString(link.absoluteString, forType: .string)
        for marker in ["org.nspasteboard.TransientType", ClipboardHistorySensitiveText.concealedPasteboardType] {
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
    }

    private func signInEvent(_ event: ClaudeSignInRun.Event, runID: UUID) {
        guard var state = signIn, state.id == runID else { return }
        switch event {
        case .link(let link):
            state.link = link
            signIn = state
            openPrivateWindow(link, runID: runID)
        case .refused:
            state.phase = .failed(strings.refusedLink)
            signIn = state
            signInRun?.cancel()
        case .finished(let exit):
            signInRun = nil
            // Refused or cancelled: what the sheet says stays.
            guard !exit.cancelled, !state.ended else { return }
            if exit.timedOut {
                state.phase = .failed(strings.signInTimedOut)
            } else if exit.status != 0 {
                state.phase = .failed(ClaudeSignIn.errorText(exit.output) ?? strings.signInStopped(Int(exit.status)))
            } else {
                let file = ClaudeUsageDecoding.configFile(forFolder: state.folder, home: home)
                switch ClaudeSignIn.outcome(expected: state.email, snapshot: ClaudeUsageDecoding.snapshot(configFile: file)) {
                case .rightAccount:
                    signIn = nil
                    signedIn(folder: state.folder)
                    return
                case .otherAccount(let email):
                    state.phase = .wrongAccount(email)
                case .notSignedIn:
                    state.phase = .failed(strings.notSignedInAfter)
                }
            }
            signIn = state
            // The folder may hold another sign-in now.
            absorb([state.folder: ClaudeAccountsDiscovery.state(folder: state.folder, home: home)], discovered: [],
                   folders: watchedFolders)
            update()
        }
    }

    /// The right account signed in: read the folder now, then check its limits.
    private func signedIn(folder: String) {
        absorb([folder: ClaudeAccountsDiscovery.state(folder: folder, home: home)], discovered: [], folders: watchedFolders)
        queueCheck(ClaudeAccountKey.key(forFolder: folder), force: true)
        update()
        pump()
    }

    /// A private window of the default browser on the link
    /// (`open -na <app> --args <flag> <link>`), or, for a browser without a
    /// private-window flag, the sheet's copy-the-link step.
    private func openPrivateWindow(_ link: URL, runID: UUID) {
        guard let browser = ClaudeSignInBrowser.current(),
              let flag = ClaudeSignIn.privateWindowFlag(bundleIdentifier: browser.bundleIdentifier) else {
            return setSignInWindow(.copyLink, runID: runID)
        }
        let arguments = ClaudeSignIn.openArguments(app: browser.app.path, flag: flag, link: link)
        let name = browser.name
        signInQueue.async {
            let result = BoundedProcessRunner.run(ClaudeSignIn.openTool, arguments, timeout: 15, maxOutputBytes: 4 << 10,
                                                  input: FileHandle.nullDevice)
            let opened = result.status == 0 && !result.timedOut
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ClaudeAccountsService.shared.setSignInWindow(opened ? .opened(browser: name) : .copyLink, runID: runID)
                }
            }
        }
    }

    private func setSignInWindow(_ window: ClaudeSignInState.Window, runID: UUID) {
        guard var state = signIn, state.id == runID, !state.ended else { return }
        state.window = window
        state.phase = .signingIn
        signIn = state
    }

    // MARK: Tidy up (duplicate folders)

    /// Only once the person answered "Any other Claude accounts?": until
    /// then a duplicate may be the folder meant for an email still to add
    /// (Add reuses it, and it stops being a duplicate).
    private func tidyTarget(_ id: String) -> ClaudeAccountEntry? {
        guard othersAsked else { return nil }
        return entries.first { $0.id == id && $0.status == .signedIn }
    }

    /// Whether the account's row offers Tidy up…: it has duplicate folders
    /// and the list is answered (tidyTarget).
    func offersTidyUp(_ entry: ClaudeAccountEntry) -> Bool {
        !entry.duplicates.isEmpty && tidyTarget(entry.id) != nil
    }

    /// The tidy-up of the account's duplicate folders, in words; nothing
    /// changes until the person confirms.
    func planTidy(id: String, _ completion: @escaping @MainActor (ClaudeTidyPlan?) -> Void) {
        guard let entry = tidyTarget(id) else { return completion(nil) }
        let home = home
        let listed = entries.map(\.label)
        workQueue.async {
            let plan = ClaudeTidyUp.plan(keep: entry.account, duplicates: entry.duplicates, home: home, listed: listed)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(plan) } }
        }
    }

    /// Tidies the account's duplicate folders (ClaudeTidyUp.execute): merge,
    /// `claude auth logout` under each folder's own environment, then the
    /// Trash; the folders that went leave the list.
    func runTidy(id: String, _ completion: @escaping @MainActor (ClaudeTidyReport) -> Void) {
        guard let entry = tidyTarget(id) else {
            return completion(ClaudeTidyReport(lines: ["Nothing to tidy."], refused: true, failures: 0, removed: []))
        }
        let home = home
        let homeURL = URL(fileURLWithPath: home)
        workQueue.async {
            let logout = { (folder: String) -> String? in
                // Never the default folder: its sign-in is every default session's.
                guard !folder.isEmpty else { return "the default folder is never signed out" }
                guard let executable = AgentClaudeServer.executable(home: homeURL,
                                                                    searchPath: ProcessInfo.processInfo.environment["PATH"]) else {
                    return "Claude Code was not found"
                }
                var base = AgentCodexServer.environment(for: executable, searchPath: nil)
                base["PATH"] = AgentClaudeServer.searchPath(after: base["PATH"] ?? "", home: homeURL)
                let result = BoundedProcessRunner.run(executable.path, ["auth", "logout"], timeout: 60, maxOutputBytes: 16 << 10,
                                                      environment: AgentClaudeServer.environment(base, home: homeURL, folder: folder),
                                                      input: FileHandle.nullDevice)
                if result.timedOut { return "timed out" }
                guard result.status == 0 else {
                    return ClaudeSignIn.errorText(String(decoding: result.output, as: UTF8.self)) ?? "exit \(result.status)"
                }
                return nil
            }
            let trash = { (folder: String) throws -> String in
                var resulting: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: folder), resultingItemURL: &resulting)
                return resulting?.path ?? "the Trash"
            }
            let report = ClaudeTidyUp.execute(keep: entry.account, duplicates: entry.duplicates, home: home,
                                              logout: logout, trash: trash)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ClaudeAccountsService.shared.tidied(report.removed)
                    completion(report)
                }
            }
        }
    }

    private func tidied(_ removed: [String]) {
        guard !removed.isEmpty else { return }
        accounts.removeAll { removed.contains($0.folder) }
        update()
        foreground()
    }

    // MARK: Setup actions: a plan to read, then a run only after confirming

    /// The other accounts' folders that Claude Code can start in: what
    /// sharing the setup and the user-scope MCP mirror change.
    var shareFolders: [String] {
        accounts.filter { !$0.isDefault && ClaudeLaunchEnvironment.launchProblem(forFolder: $0.folder, home: home) == nil }
            .map(\.folder)
    }

    /// The share folders' labels, for the review's words.
    private var shareLabels: [String: String] {
        Dictionary(accounts.map { ($0.folder, $0.label) }, uniquingKeysWith: { first, _ in first })
    }

    func planShare(_ completion: @escaping @MainActor (ClaudeSharePlan) -> Void) {
        let root = home + "/.claude"
        let folders = shareFolders
        let labels = shareLabels
        workQueue.async {
            let plan = ClaudeSetupSharing.plan(sharedRoot: root, folders: folders, labels: labels)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(plan) } }
        }
    }

    func runShare(_ completion: @escaping @MainActor (ClaudeShareReport) -> Void) {
        let root = home + "/.claude"
        let folders = shareFolders
        let paths = paths
        let labels = shareLabels
        workQueue.async {
            let report = ClaudeSetupSharing.execute(sharedRoot: root, folders: folders, paths: paths, labels: labels)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let service = ClaudeAccountsService.shared
                    // A folder that got its own folders joins the watched
                    // ones (the run itself synced everything into it).
                    service.syncWatcher?.update(configDirectories: ClaudeAccount.configDirectories(home: service.home, accounts: service.accounts))
                    service.foreground()
                    completion(report)
                }
            }
        }
    }

    /// Whether a folder still links its conversations to ~/.claude: the
    /// setup row then asks for a review (ClaudeOwnFolders).
    var shareNeedsUpdate: Bool {
        shareFolders.contains(where: ClaudeOwnFolders.needsOwnFolders)
    }

    /// The folders Brim shared, which an undo puts back.
    var sharedFolders: [String] {
        shareFolders.filter { !(ClaudeShareManifest.load(folder: $0)?.entries.isEmpty ?? true) }
    }

    func undoSharePlan() -> [String] {
        sharedFolders.flatMap { ClaudeSetupSharing.undoPlan(folder: $0, sharedRoot: home + "/.claude") }
    }

    func undoShare(_ completion: @escaping @MainActor (ClaudeShareReport) -> Void) {
        let root = home + "/.claude"
        let folders = sharedFolders
        workQueue.async {
            var lines: [String] = []
            var failures = 0
            var refused = false
            for folder in folders {
                let report = ClaudeSetupSharing.undo(folder: folder, sharedRoot: root)
                lines += report.lines
                failures += report.failures
                refused = refused || report.refused
            }
            let report = ClaudeShareReport(lines: lines.isEmpty ? ["Nothing to undo."] : lines, refused: refused, failures: failures)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(report) } }
        }
    }

    func shellStatus() -> ClaudeShellIntegration.Status {
        ClaudeShellIntegration.status(home: home, helper: bundledHelper, template: bundledShellScript)
    }

    func planShell() -> (lines: [String], problems: [String]) {
        ClaudeShellIntegration.plan(home: home, helper: bundledHelper, template: bundledShellScript)
    }

    func installShell() -> ClaudeInstallReport {
        ClaudeShellIntegration.install(home: home, helper: bundledHelper, template: bundledShellScript, paths: paths)
    }

    func undoShellPlan() -> [String] { ClaudeShellIntegration.undoPlan(paths: paths) }
    func undoShell() -> ClaudeInstallReport { ClaudeShellIntegration.undo(paths: paths) }

    func statusLineStatus() -> ClaudeStatusLineInstall.Status { ClaudeStatusLineInstall.status(home: home) }

    func planStatusLine() -> (lines: [String], problems: [String]) {
        ClaudeStatusLineInstall.plan(home: home, helper: statusLineHelper)
    }

    func installStatusLine() -> ClaudeInstallReport {
        ClaudeStatusLineInstall.install(home: home, helper: statusLineHelper, paths: paths)
    }

    func undoStatusLinePlan() -> [String] { ClaudeStatusLineInstall.undoPlan(paths: paths) }
    func undoStatusLine() -> ClaudeInstallReport { ClaudeStatusLineInstall.undo(paths: paths) }

    /// What Brim installed and can undo.
    func installRecord() -> ClaudeInstallRecord { ClaudeInstallRecord.load(paths) }
}

/// The service starts a check on its process queue and may cancel it from the
/// main thread. Request was built for that: every field it changes (cancelled,
/// the running conversation) is read and written under its own NSLock. It is
/// declared here, beside the one main-actor caller that hands it across.
extension AgentClaudeServer.Request: @unchecked Sendable {}
