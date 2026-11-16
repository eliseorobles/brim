// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// Everything the MCP page shows, read off the main thread in one pass.
struct ClaudeMCPSnapshot: Equatable {
    var repos: [ClaudeMCPRepo] = []
    var root: String?
    var servers: ClaudeMCPRepoServers?
    var openHere = 0
    /// This repo's own servers onto every account folder.
    var repoMirror = ClaudeMCPPlan()
    /// The person's own servers (user scope) onto every account folder.
    var userMirror = ClaudeMCPPlan()
    var userBackups = false
    var copySources: [ClaudeMCPCopySource] = []
    /// Every server name any folder, repo, plugin or Brim record uses.
    var takenEverywhere: Set<String> = []
    /// The folders that hold each of this repo's local servers.
    var holders: [String: [String]] = [:]
    /// The account folders whose .claude.json was read, in launch order:
    /// the only ones any plan touches.
    var readableFolders: [String] = []
    /// Labels of the accounts whose .claude.json is missing or unreadable.
    var unreadable: [String] = []
    /// Why Brim's own record cannot be read, or nil.
    var stateProblem: String?
}

/// Reads the folders, plugins and repo files for a snapshot. It is used on
/// the model's serial work queue only (its cache is never touched from two
/// threads), which is what makes handing it to that queue safe.
/// A .claude.json is parsed again only when its size or change time moved.
final class ClaudeMCPReader: @unchecked Sendable {
    struct Input {
        var home: String
        var paths: ClaudeAccountsPaths
        /// Every account folder Claude Code can start in, in launch order,
        /// with its label.
        var folders: [(folder: String, label: String)]
        var root: String?
    }

    private struct Stamp: Equatable {
        var modified: Date?
        var size: Int64
        var cacheModified: Date?
    }

    private var cache: [String: (stamp: Stamp, config: ClaudeMCPFolderConfig)] = [:]

    func configs(_ input: Input) -> [ClaudeMCPFolderConfig] {
        input.folders.map { entry in
            let file = ClaudeUsageDecoding.configFile(forFolder: entry.folder, home: input.home)
            let needsAuth = ClaudeMCPNeedsAuth.path(configDirectory: ClaudeSessionIndex.configDirectory(forFolder: entry.folder,
                                                                                                         home: input.home))
            var info = stat()
            let stamp = Stamp(modified: ClaudeFileIO.modificationDate(file),
                              size: stat(file, &info) == 0 ? Int64(info.st_size) : -1,
                              cacheModified: ClaudeFileIO.modificationDate(needsAuth))
            if let hit = cache[file], hit.stamp == stamp, hit.config.label == entry.label { return hit.config }
            let config = ClaudeMCPFolderConfig(folder: entry.folder, label: entry.label,
                                               configData: ClaudeFileIO.read(file, limit: ClaudeUsageDecoding.configSizeLimit),
                                               needsAuthCache: ClaudeFileIO.read(needsAuth, limit: 1 << 20))
            cache[file] = (stamp, config)
            return config
        }
    }

    func snapshot(_ input: Input) -> ClaudeMCPSnapshot {
        let configs = configs(input)
        let readable = configs.filter(\.readable)
        var snapshot = ClaudeMCPSnapshot()
        var state = ClaudeMCPState()
        switch ClaudeMCPState.read(input.paths) {
        case .success(let read): state = read
        case .failure(let problem): snapshot.stateProblem = problem.message
        }
        snapshot.readableFolders = readable.map(\.folder)
        snapshot.unreadable = configs.filter { !$0.readable }.map(\.label)
        // Each account keeps its own conversations: a repo's last use is the
        // newest across every account's projects/.
        let projects = ([input.home + "/.claude"] + input.folders.map {
            ClaudeSessionIndex.configDirectory(forFolder: $0.folder, home: input.home)
        }).map { $0 + "/projects" }
        snapshot.repos = ClaudeMCPRepoList.build(keys: readable.flatMap(\.projects.keys), added: state.repos,
                                                 projectsDirectories: projects)
        let plugins = ClaudeMCPPlugins.scan(home: input.home)
        // Built in steps: as one expression, Swift 6.0's type checker gives up on it.
        var taken = Set<String>(state.servers.keys)
        taken.formUnion(plugins.map(\.runtimeName))
        for config in readable {
            taken.formUnion(config.userServers.keys)
            for project in config.projects.values {
                taken.formUnion((ClaudeJSON.object(project["mcpServers"]) ?? [:]).keys)
            }
        }
        snapshot.takenEverywhere = taken
        let labels = Dictionary(input.folders.map { ($0.folder, $0.label) }, uniquingKeysWith: { a, _ in a })

        // The user-scope mirror: the union of the readable folders' servers.
        var user: [String: [String: Any]] = [:]
        for config in readable { user[config.folder] = config.userServers }
        snapshot.userMirror = ClaudeMCPMirror.plan(servers: user, folders: snapshot.readableFolders,
                                                   describe: { labels[$0] ?? $0 })
        snapshot.userBackups = !ClaudeMCPBackup.pending(input.paths).isEmpty

        guard let root = input.root else { return snapshot }
        snapshot.root = root
        let userSettings = ClaudeFileIO.read(input.home + "/.claude/settings.json", limit: ClaudeMCPSettingsFile.sizeLimit)
            .flatMap { ClaudeJSON.parse($0) as? [String: Any] } ?? [:]
        snapshot.servers = ClaudeMCPCatalog.build(root: root, folders: configs, files: ClaudeMCPRepoFiles.read(root: root),
                                                  userSettings: userSettings, plugins: plugins, state: state)
        let sessions = input.folders.flatMap {
            ClaudeSessionIndex.liveSessions(configDirectory: ClaudeSessionIndex.configDirectory(forFolder: $0.folder, home: input.home))
        }
        snapshot.openHere = ClaudeMCPCatalog.openSessions(sessions, root: root)
        var local: [String: [String: Any]] = [:]
        for config in readable { local[config.folder] = config.localServers(root) }
        snapshot.repoMirror = ClaudeMCPMirror.localPlan(repo: root, servers: local, folders: snapshot.readableFolders,
                                                        describe: { labels[$0] ?? $0 })
        for folder in snapshot.readableFolders {
            for name in (local[folder] ?? [:]).keys { snapshot.holders[name, default: []].append(folder) }
        }
        snapshot.copySources = ClaudeMCPCatalog.copyable(folders: configs, excluding: root)
        return snapshot
    }
}

/// One FileEventStream over the files the page reads, while it is open: each
/// folder's .claude.json and sessions folder, the shared settings and plugin
/// list, Brim's MCP record and the chosen repo's .claude folder and
/// .mcp.json. No timer here: a batch of events, or a look again after lost
/// events or a new registration, is one reload. The transcript folders that
/// order the repo list are not watched (sessions write them constantly); the
/// order is read again on each reload.
final class ClaudeMCPWatcher {
    private let queue = DispatchQueue(label: "brim.claude-mcp.watch", qos: .utility)
    private let changed: () -> Void
    // Confined to `queue`. Events coalesced over a second: a burst of
    // rewrites (Claude Code saves .claude.json often) is one reload.
    private lazy var stream = FileEventStream(name: "claude-mcp", queue: queue, configuration: .init(latency: 1.0),
                                              handler: { [weak self] _ in self?.changed() },
                                              resync: { [weak self] in self?.changed() })

    init(changed: @escaping () -> Void) { self.changed = changed }

    func watch(_ paths: [String]) {
        queue.async { [self] in stream.watch(paths) }
    }

    func stop() {
        queue.async { [self] in stream.stop() }
    }
}

/// The MCP page of Claude accounts (one place for MCP): a list of repos and,
/// for the chosen one, a switch per server. A switch writes a deny into the
/// repo's .claude/settings.local.json (ClaudeMCPSettingsFile), which every
/// account folder reads; servers are added, copied to every folder and
/// removed with Claude Code's own CLI (ClaudeMCPRun), after a review.
/// Brim never writes a .claude.json.
@MainActor
final class ClaudeMCPModel: ObservableObject {
    static let shared = ClaudeMCPModel()

    struct Notice: Equatable {
        var text: String
        var problem: Bool
    }

    enum AddRequest {
        case stripe(nickname: String)
        case copy(ClaudeMCPCopySource)
        case paste(name: String, json: String)
    }

    @Published private(set) var snapshot = ClaudeMCPSnapshot()
    @Published private(set) var selection: String?
    @Published private(set) var notice: Notice?
    @Published private(set) var busy = false
    @Published private(set) var loaded = false

    private let service = ClaudeAccountsService.shared
    /// Reads, git checks and settings writes; Claude Code runs go on the
    /// service's process queue, one process at a time.
    private let work = DispatchQueue(label: "brim.claude-mcp.work", qos: .userInitiated)
    private let reader = ClaudeMCPReader()
    private var watcher: ClaudeMCPWatcher?
    private var visible = false
    private var reloading = false
    private var reloadAgain = false

    private var text: ClaudeAccountsStrings { service.strings }

    // MARK: Lifecycle

    func appear() {
        guard !visible else { return }
        visible = true
        service.syncWithPreferences()
        watcher = ClaudeMCPWatcher {
            DispatchQueue.main.async { MainActor.assumeIsolated { ClaudeMCPModel.shared.reload() } }
        }
        reload()
    }

    func disappear() {
        visible = false
        watcher?.stop()
        watcher = nil
    }

    func select(_ root: String?) {
        guard root != selection else { return }
        selection = root
        notice = nil
        reload()
    }

    /// Every account folder Claude Code can start in, the default first,
    /// with its label.
    private var folders: [(folder: String, label: String)] {
        let accounts = service.accounts.filter { ClaudeLaunchEnvironment.launchProblem(forFolder: $0.folder, home: service.home) == nil }
        guard !accounts.isEmpty else { return [("", service.strings.defaultAccount)] }
        return (accounts.filter(\.isDefault) + accounts.filter { !$0.isDefault }).map { ($0.folder, $0.label) }
    }

    private var labels: [String: String] {
        Dictionary(folders.map { ($0.folder, $0.label) }, uniquingKeysWith: { a, _ in a })
    }

    func label(_ folder: String) -> String { labels[folder] ?? service.shortFolder(folder) }

    func reload() {
        guard visible else { return }
        if reloading {
            reloadAgain = true
            return
        }
        reloading = true
        let input = ClaudeMCPReader.Input(home: service.home, paths: service.paths, folders: folders, root: selection)
        watcher?.watch(watchedPaths(input))
        let reader = self.reader
        work.async {
            let snapshot = reader.snapshot(input)
            DispatchQueue.main.async { MainActor.assumeIsolated { ClaudeMCPModel.shared.take(snapshot) } }
        }
    }

    private func take(_ next: ClaudeMCPSnapshot) {
        reloading = false
        if next != snapshot { snapshot = next }
        loaded = true
        if selection == nil, let first = next.repos.first { select(first.root) }
        if reloadAgain {
            reloadAgain = false
            reload()
        }
    }

    private func watchedPaths(_ input: ClaudeMCPReader.Input) -> [String] {
        var list = input.folders.map { ClaudeUsageDecoding.configFile(forFolder: $0.folder, home: input.home) }
        list += input.folders.map { ClaudeSessionIndex.configDirectory(forFolder: $0.folder, home: input.home) + "/sessions" }
        list += [input.home + "/.claude/settings.json", input.home + "/.claude/plugins/installed_plugins.json",
                 ClaudeMCPState.path(input.paths)]
        if let root = input.root { list += [root + "/.claude", root + "/.mcp.json"] }
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    // MARK: Brim's record

    /// Brim's record, read now, or nil after saying why it cannot be.
    private func readState() -> ClaudeMCPState? {
        switch ClaudeMCPState.read(service.paths) {
        case .success(let state): return state
        case .failure(let problem):
            notice = Notice(text: problem.message, problem: true)
            return nil
        }
    }

    /// Changes the record and saves it when the change changed it. Refuses,
    /// saving nothing, when the record on disk cannot be read: saving would
    /// replace it with an empty one and lose which denies are Brim's.
    @discardableResult
    private func updateState(_ change: (inout ClaudeMCPState) -> Void) -> Bool {
        guard var state = readState() else { return false }
        let before = state
        change(&state)
        guard state != before else { return true }
        do {
            try state.save(service.paths)
            return true
        } catch {
            notice = Notice(text: ClaudeFileError.message(error), problem: true)
            return false
        }
    }

    // MARK: Repos

    func addRepo(_ path: String) {
        let root = ClaudeRepoKey.root(of: path)
        guard updateState({ state in if !state.repos.contains(root) { state.repos.append(root) } }) else { return }
        select(root)
    }

    // MARK: Switches

    /// Off writes Brim's deny for the server into the repo's
    /// .claude/settings.local.json; on removes only Brim's own.
    func setSwitch(_ entry: ClaudeMCPEntry, on: Bool) {
        guard entry.switchable || !on else { return }
        if on {
            guard entry.deny == .brim else { return }
            write(ClaudeMCPSwitchChange(allow: [entry.name]))
        } else {
            write(ClaudeMCPSwitchChange(deny: [entry.name]))
        }
    }

    /// Removes a deny Brim did not write, once the person confirmed.
    func turnOnOutside(_ entry: ClaudeMCPEntry) {
        guard entry.deny == .outside(removable: true) else { return }
        write(ClaudeMCPSwitchChange(allow: [entry.name]))
    }

    /// "Turn off for all accounts" for a server one account's /mcp toggle
    /// turned off: Brim's deny, Claude Code's own toggle left as it is.
    func turnOffEverywhere(_ entry: ClaudeMCPEntry) {
        setSwitch(entry, on: false)
    }

    func setConnectors(on: Bool) {
        guard let servers = snapshot.servers else { return }
        if on {
            guard servers.connectors == .brim else { return }
            write(ClaudeMCPSwitchChange(connectorsOff: false))
        } else {
            guard servers.connectors == .none else { return }
            write(ClaudeMCPSwitchChange(connectorsOff: true))
        }
    }

    func turnOnOutsideConnectors() {
        guard snapshot.servers?.connectors == .outside(removable: true) else { return }
        write(ClaudeMCPSwitchChange(connectorsOff: false))
    }

    /// The git check (refuse a committed file, exclude an unignored one) and
    /// the settings write run off the main thread; the record is then
    /// updated here, the one place that writes it, claiming a deny only when
    /// the write added it. Nothing is written while the record is unreadable.
    private func write(_ change: ClaudeMCPSwitchChange, in repo: String? = nil) {
        guard let root = repo ?? selection, !busy, readState() != nil else { return }
        busy = true
        let home = service.home
        let text = self.text
        work.async {
            var problem: String?
            var excluded: String?
            var changed = false
            switch ClaudeMCPGit.prepare(root: root, home: home) {
            case .tracked: problem = text.mcpTracked
            case .gitFailed(let status): problem = text.mcpGitFailed(status)
            case .excludeFailed(let detail): problem = text.mcpExcludeFailed(detail)
            case .ready(let written):
                excluded = written
                do {
                    changed = try ClaudeMCPSettingsFile.apply(root: root, change: change)
                } catch let error as ClaudeMCPSettingsError {
                    problem = error.message
                } catch {
                    problem = ClaudeFileError.message(error)
                }
            }
            let outcome = (problem: problem, excluded: excluded, changed: changed)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ClaudeMCPModel.shared.wrote(change, root: root, problem: outcome.problem, excluded: outcome.excluded,
                                                changed: outcome.changed)
                }
            }
        }
    }

    private func wrote(_ change: ClaudeMCPSwitchChange, root: String, problem: String?, excluded: String?, changed: Bool) {
        busy = false
        var said: String?
        let saved = updateState { state in
            if problem == nil { state.record(change, in: root, changed: changed) }
            if let excluded, !state.excluded.contains(root) {
                state.excluded.append(root)
                said = text.mcpExcluded(excluded)
            }
        }
        if let problem {
            notice = Notice(text: problem, problem: true)
        } else if saved, let said {
            notice = Notice(text: said, problem: false)
        }
        reload()
    }

    // MARK: Review lines shared by every change

    /// The lines every review that runs `claude mcp` commands ends with.
    private func runNotes(_ commands: [ClaudeMCPCommand]) -> [String] {
        var lines: [String] = []
        if commands.contains(where: { $0.kind == .add && ClaudeMCPMirror.mayHoldSecrets($0.arguments.last ?? "") }) {
            lines.append(text.mcpCommandLineNote)
        }
        if !snapshot.unreadable.isEmpty { lines.append(text.mcpLeftOut(snapshot.unreadable)) }
        return lines
    }

    // MARK: Repo servers on every account

    /// This repo's own servers onto every account folder.
    func reviewRepoMirror() -> ClaudeReview {
        let plan = snapshot.repoMirror
        var lines = plan.lines.isEmpty ? [text.nothingToChange] : plan.lines
        if plan.commands.contains(where: { command in
            snapshot.servers?.entry("\(ClaudeMCPEntry.Group.repo.rawValue)|\(command.server)")?.info?.signsInItself == true
        }) {
            lines.append(text.mcpNeedsLogin + ": each account signs in to it once.")
        }
        lines += runNotes(plan.commands)
        var run: ClaudeReview.Run?
        if !plan.isEmpty { run = { done in ClaudeMCPModel.shared.run(plan.commands) { done($0.install.lines) } } }
        return ClaudeReview(title: text.mcpCopyToAll.replacingOccurrences(of: "…", with: ""), lines: lines, run: run)
    }

    // MARK: Your servers on every account (the user-scope mirror)

    func reviewUserMirror() -> ClaudeReview {
        let plan = snapshot.userMirror
        // Server names only: a server's configuration can hold its keys.
        var run: ClaudeReview.Run?
        if !plan.isEmpty { run = { done in ClaudeMCPModel.shared.runUserMirror(plan) { done($0.lines) } } }
        let lines = (plan.lines.isEmpty ? [text.nothingToChange] : plan.lines) + runNotes(plan.commands)
        return ClaudeReview(title: text.mcpYourServers, lines: lines, run: run)
    }

    /// Saves each folder's own version of the servers the plan replaces
    /// (ClaudeMCPBackup), then runs its commands; refuses, changing nothing,
    /// when another change is running or the backup cannot be written.
    func runUserMirror(_ plan: ClaudeMCPPlan, _ completion: @escaping @MainActor (ClaudeInstallReport) -> Void) {
        guard !busy else {
            completion(.refusal([text.mcpBusy]))
            return
        }
        let backups: [String]
        do {
            backups = try ClaudeMCPBackup.save(plan.replaced, paths: service.paths, now: Date())
        } catch {
            completion(.refusal(["the servers it would replace could not be saved first (\(error))"]))
            return
        }
        run(plan.commands) { report in
            var install = report.install
            install.lines = backups.map { "saved the replaced servers' own versions to \($0)" } + install.lines
            completion(install)
        }
    }

    /// Undo for the user-scope mirror: every replaced server back as its
    /// folder had it. Servers the mirror added stay.
    func reviewUndoUserMirror() -> ClaudeReview {
        let pending = ClaudeMCPBackup.pending(service.paths)
        let home = service.home
        let plan = ClaudeMCPBackup.undoPlan(pending.map(\.backup), current: { folder in
            ClaudeFileIO.read(ClaudeUsageDecoding.configFile(forFolder: folder, home: home), limit: ClaudeUsageDecoding.configSizeLimit)
                .flatMap(ClaudeMCPMirror.servers) ?? [:]
        })
        let files = pending.map(\.path)
        // Even with nothing left to put back, running marks the backups used.
        var run: ClaudeReview.Run?
        if !files.isEmpty {
            run = { done in
                ClaudeMCPModel.shared.run(plan.commands) { report in
                    if report.install.succeeded { ClaudeMCPBackup.markRestored(files) }
                    done(report.install.lines)
                }
            }
        }
        return ClaudeReview(title: text.mcpYourServers + " · " + text.undo,
                            lines: plan.lines + ["Servers the mirror added stay."] + runNotes(plan.commands), run: run)
    }

    // MARK: Add server…

    /// Why the request cannot be added, or nil.
    func problem(_ request: AddRequest) -> String? {
        let repoNames = Set(snapshot.servers?.entries.filter { $0.group != .connector }.map(\.name) ?? [])
        switch request {
        case .stripe(let nickname):
            switch ClaudeMCPStripe.nicknameProblem(nickname, taken: snapshot.takenEverywhere.union(repoNames)) {
            case .empty?: return text.mcpNicknameHelp
            case .characters?: return text.mcpNicknameCharacters
            case .taken?: return text.mcpNameTaken
            case nil: return nil
            }
        case .copy(let source):
            return repoNames.contains(source.name) ? text.mcpNameInRepo(source.name) : nil
        case .paste(let name, let json):
            if let problem = ClaudeMCPMirror.nameProblem(name) { return problem }
            if repoNames.contains(name) { return text.mcpNameInRepo(name) }
            if case .failure(let problem) = ClaudeMCPMirror.pastedServer(json) { return problem.message }
            return nil
        }
    }

    /// The review of adding the server to this repo in every account folder
    /// Brim can read.
    func reviewAdd(_ request: AddRequest) -> ClaudeReview? {
        guard let root = selection, problem(request) == nil else { return nil }
        let repo = ClaudeMCPRepoList.name(root, home: service.home)
        let folders = snapshot.readableFolders
        var lines: [String] = []
        let name: String
        let json: String
        var kind: String?
        switch request {
        case .stripe(let nickname):
            name = ClaudeMCPStripe.serverName(nickname: nickname)
            json = ClaudeMCPStripe.config
            kind = ClaudeMCPStripe.kind
            lines += folders.map { "\(label($0)): add \(name) to \(repo) (http · \(ClaudeMCPStripe.host))" }
            lines.append(text.mcpStripeSignInReview(name))
        case .copy(let source):
            name = source.name
            json = source.json
            let from = ClaudeMCPRepoList.name(source.repo, home: service.home)
            lines += folders.map { "\(label($0)): add \(name) to \(repo) (\(source.info.summary), copied from \(from))" }
        case .paste(let pasted, let body):
            name = pasted
            guard case .success(let compact) = ClaudeMCPMirror.pastedServer(body) else { return nil }
            json = compact
            let info = ClaudeMCPServerInfo(ClaudeJSON.parse(Data(compact.utf8)))
            lines += folders.map { "\(label($0)): add \(name) to \(repo) (\(info.summary))" }
        }
        let commands = folders.map { ClaudeMCPCommand.addLocal(name, json: json, folder: $0, repo: root) }
        lines += runNotes(commands)
        var review = ClaudeReview(title: text.mcpAddTitle(repo), lines: lines) { done in
            ClaudeMCPModel.shared.runAdd(request, name: name, kind: kind, root: root, commands: commands) { done($0) }
        }
        if let problem = snapshot.stateProblem { review.problems = [problem] }
        if folders.isEmpty { review.problems.append(text.mcpNoReadableAccount) }
        return review
    }

    private func runAdd(_ request: AddRequest, name: String, kind: String?, root: String, commands: [ClaudeMCPCommand],
                        _ completion: @escaping @MainActor ([String]) -> Void) {
        run(commands) { [self] report in
            if !report.refused {
                switch request {
                case .stripe, .copy:
                    updateState { $0.recordAdded(name, kind: kind, root: root, folders: report.succeededCount) }
                case .paste:
                    break
                }
            }
            reload()
            completion(report.install.lines)
        }
    }

    // MARK: Remove

    /// Removing a server of this repo from every folder that holds it. Claude
    /// Code also clears its MCP sign-in there.
    func reviewRemove(_ entry: ClaudeMCPEntry) -> ClaudeReview? {
        guard let root = selection, entry.group == .repo, entry.source == .local else { return nil }
        let name = entry.name
        let holders = snapshot.holders[name] ?? []
        let unreadable = snapshot.unreadable
        let commands = holders.map { ClaudeMCPCommand.removeLocal(name, folder: $0, repo: root) }
        var lines = holders.map { "\(label($0)): remove \(name) from this repo" }
        lines.append(text.mcpRemoveSignIn)
        if entry.conflict { lines.append(text.mcpRemoveDiffers(name)) }
        if !unreadable.isEmpty { lines.append(text.mcpRemoveUnchecked(unreadable)) }
        let ownedDeny = entry.deny == .brim
        if ownedDeny { lines.append("Remove Brim's switch for \(name) from .claude/settings.local.json once no account has it.") }
        let labels = self.labels
        var review = ClaudeReview(title: text.mcpRemove.replacingOccurrences(of: "…", with: "") + ": " + name, lines: lines) { done in
            ClaudeMCPModel.shared.runRemove(name: name, root: root, commands: commands, unreadable: unreadable,
                                            labels: labels, ownedDeny: ownedDeny) { done($0) }
        }
        if let problem = snapshot.stateProblem { review.problems = [problem] }
        return review
    }

    /// Brim's record of the server, and its switch, go only once every
    /// folder dropped it; otherwise the result says where it still is.
    private func runRemove(name: String, root: String, commands: [ClaudeMCPCommand], unreadable: [String],
                           labels: [String: String], ownedDeny: Bool,
                           _ completion: @escaping @MainActor ([String]) -> Void) {
        run(commands) { [self] report in
            var lines = report.install.lines
            if !report.refused {
                let removal = ClaudeMCPRun.removal(report, unreadable: unreadable, labels: labels)
                if !removal.stillIn.isEmpty { lines.append(text.mcpStillIn(name, removal.stillIn)) }
                if !unreadable.isEmpty { lines.append(text.mcpRemoveUnchecked(unreadable)) }
                updateState { $0.recordRemoved(name, root: root, everywhere: removal.everywhere) }
                if removal.everywhere && ownedDeny { write(ClaudeMCPSwitchChange(allow: [name]), in: root) }
            }
            reload()
            completion(lines)
        }
    }

    // MARK: Running Claude Code

    /// Runs the commands with Claude Code's own CLI, one at a time, each
    /// under its account's environment (ClaudeMCPRun.environment) and, for
    /// a repo's server, in the repo. Refused while another change runs.
    func run(_ commands: [ClaudeMCPCommand], _ completion: @escaping @MainActor (ClaudeMCPRun.Report) -> Void) {
        guard !busy else {
            completion(ClaudeMCPRun.Report(refusal: text.mcpBusy))
            return
        }
        let homeURL = URL(fileURLWithPath: service.home)
        let labels = self.labels
        busy = true
        service.processQueue.async {
            let report: ClaudeMCPRun.Report
            if let executable = AgentClaudeServer.executable(home: homeURL, searchPath: ProcessInfo.processInfo.environment["PATH"]) {
                let base = ClaudeMCPRun.base(executable: executable, home: homeURL)
                report = ClaudeMCPRun.run(commands, labels: labels) { command in
                    let result = BoundedProcessRunner.run(executable.path, command.arguments, timeout: 60, maxOutputBytes: 64 << 10,
                                                          environment: ClaudeMCPRun.environment(for: command, base: base, home: homeURL),
                                                          input: FileHandle.nullDevice, currentDirectory: command.directory)
                    return (result.status, result.timedOut)
                }
            } else {
                report = ClaudeMCPRun.Report(refusal: "Claude Code was not found")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ClaudeMCPModel.shared.busy = false
                    completion(report)
                }
            }
        }
    }
}
