// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Darwin
import Foundation

/// What a config folder's .claude.json says right now.
enum ClaudeFolderState: Equatable {
    /// No .claude.json: never signed in, or signed out and cleaned up.
    case missing
    /// It exists but could not be read or parsed, or it is not a file of the
    /// folder's own (a link to another account's). What was known stays.
    case unreadable
    case snapshot(ClaudeConfigSnapshot)

    var snapshot: ClaudeConfigSnapshot? {
        if case .snapshot(let snapshot) = self { return snapshot }
        return nil
    }
}

/// The folders signed in to one Claude account. Claude Code keeps a sign-in
/// per folder, and two folders can hold the same sign-in (the same
/// oauthAccount.accountUuid in the same organizationUuid): they share one set
/// of plan limits, so Brim ranks, checks and shows them as one account and
/// launches in one of them.
struct ClaudeAccountGroup: Equatable {
    /// The folder launches and checks use first: of the folders that can be
    /// launched, the one the person's list expects to hold the account, else
    /// the default folder, else the shortest path, else the first listed
    /// (when none can be, the same order over all of them). Then the others
    /// in list order.
    var members: [ClaudeAccount]

    var primary: ClaudeAccount { members[0] }
    var sharesSignIn: Bool { members.count > 1 }

    func contains(_ id: String) -> Bool { members.contains { $0.id == id } }
}

/// Finds the person's Claude Code accounts and keeps accounts.json's list in
/// step with the folders on disk. Pure apart from reading the home folder and
/// each .claude.json; the app writes the result.
enum ClaudeAccountsDiscovery {
    static let folderPrefix = ".claude-"
    /// More than anyone keeps; a home full of look-alike folders is not read whole.
    static let maximumFolders = 32
    static let labelLimit = 40

    /// Every ~/.claude-<name> folder (a real folder, not a link), as
    /// home + "/" + name exactly: Claude Code keys the sign-in to that string.
    static func candidateFolders(home: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        return names.filter { $0.hasPrefix(folderPrefix) && $0.count > folderPrefix.count }
            .sorted()
            .map { home + "/" + $0 }
            .filter { ClaudeFileIO.isDirectory($0) }
            .prefix(maximumFolders)
            .map { $0 }
    }

    /// The folder's .claude.json. Another account's is read only when it is
    /// a regular file of its own: a link (or a second hard link) to another
    /// folder's would make two accounts out of one sign-in.
    static func state(folder: String, home: String) -> ClaudeFolderState {
        let path = ClaudeUsageDecoding.configFile(forFolder: folder, home: home)
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .missing : .unreadable }
        guard (info.st_mode & S_IFMT) == S_IFREG, folder.isEmpty || info.st_nlink == 1,
              let snapshot = ClaudeUsageDecoding.snapshot(configFile: path) else { return .unreadable }
        return .snapshot(snapshot)
    }

    /// One look at the disk: the state of the default folder, of every listed
    /// account's folder and of each ~/.claude-<name> candidate, and which
    /// candidates are signed in (those become accounts). Each file is read once.
    static func scan(home: String, listed: [String]) -> (discovered: [String], states: [String: ClaudeFolderState]) {
        var states: [String: ClaudeFolderState] = [:]
        var discovered: [String] = []
        for folder in [""] + listed where states[folder] == nil {
            states[folder] = state(folder: folder, home: home)
        }
        for folder in candidateFolders(home: home) {
            let current = states[folder] ?? state(folder: folder, home: home)
            states[folder] = current
            if current.snapshot?.signedIn == true { discovered.append(folder) }
        }
        return (discovered, states)
    }

    /// The account list after a look at the disk. The default account is
    /// always there. Accounts already listed keep their place and the label
    /// the person gave them while their folder is there (an account added but
    /// not signed in yet stays); folders found signed in join at the end,
    /// named from their email. Identity, plan and sign-in come from each
    /// folder's .claude.json; a file that could not be read leaves what was
    /// known.
    static func merge(stored: [ClaudeAccount], discovered: [String],
                      states: [String: ClaudeFolderState]) -> [ClaudeAccount] {
        var accounts: [ClaudeAccount] = []
        var seen = Set<String>()
        func add(_ account: ClaudeAccount) {
            guard seen.insert(account.folder).inserted else { return }
            accounts.append(account)
        }
        if !stored.contains(where: \.isDefault) {
            add(ClaudeAccount(label: "", folder: ""))
        }
        for account in stored {
            guard account.isDefault || ClaudeFileIO.isDirectory(account.folder, followingLinks: true) else { continue }
            add(account)
        }
        for folder in discovered where !seen.contains(folder) {
            add(ClaudeAccount(label: "", folder: folder))
        }
        for index in accounts.indices {
            switch states[accounts[index].folder] ?? .unreadable {
            case .missing:
                accounts[index].signedIn = false
            case .unreadable:
                break
            case .snapshot(let snapshot):
                accounts[index].signedIn = snapshot.signedIn
                if let identity = snapshot.identity {
                    accounts[index].accountUuid = identity.accountUuid
                    accounts[index].organizationUuid = identity.organizationUuid
                    accounts[index].email = identity.email
                    accounts[index].plan = identity.plan
                }
            }
        }
        // Names last, so a new account's never takes a listed one's.
        for index in accounts.indices where labelProblem(accounts[index].label, others: []) != nil {
            let taken = Set(accounts.enumerated().filter { $0.offset != index }.map { $0.element.label.lowercased() })
            accounts[index].label = label(email: accounts[index].email, folder: accounts[index].folder, taken: taken)
        }
        return accounts
    }

    // MARK: Launching

    /// Why Claude Code must not start on the folder for its account, or nil
    /// when it may: its folder string or the folder itself is unsafe
    /// (ClaudeLaunchEnvironment.launchProblem), or the folder holds another
    /// account than the one expected there. The app and brim-claude group,
    /// rank and launch with this one check.
    static func launchProblem(_ account: ClaudeAccount, home: String) -> String? {
        if account.holdsWrongAccount { return "its folder is signed in to another account; sign in from Brim" }
        return ClaudeLaunchEnvironment.launchProblem(forFolder: account.folder, home: home)
    }

    static func launchable(home: String) -> (ClaudeAccount) -> Bool {
        { launchProblem($0, home: home) == nil }
    }

    // MARK: Shared sign-ins

    /// The accounts as Claude accounts: folders that hold the same sign-in
    /// together, every other folder alone, in the order of each group's
    /// first folder in the list. A folder that is signed out, or whose
    /// account or organization is not known yet, is never grouped.
    /// `launchable` says whether Claude Code may start on a folder
    /// (ClaudeLaunchEnvironment.launchProblem): the app and brim-claude pass
    /// the same check, so both launch and check in the same folder.
    static func groups(_ accounts: [ClaudeAccount], launchable: (ClaudeAccount) -> Bool) -> [ClaudeAccountGroup] {
        var groups: [ClaudeAccountGroup] = []
        var index: [String: Int] = [:]
        for account in accounts {
            guard let key = signInKey(account) else {
                groups.append(ClaudeAccountGroup(members: [account]))
                continue
            }
            if let at = index[key] {
                groups[at].members.append(account)
            } else {
                index[key] = groups.count
                groups.append(ClaudeAccountGroup(members: [account]))
            }
        }
        return groups.map { group in
            guard group.sharesSignIn else { return group }
            let open = group.members.indices.filter { launchable(group.members[$0]) }
            guard let first = (open.isEmpty ? Array(group.members.indices) : open)
                    .min(by: { launchesBefore(group.members[$0], group.members[$1]) }),
                  first != 0 else { return group }
            var members = group.members
            members.insert(members.remove(at: first), at: 0)
            return ClaudeAccountGroup(members: members)
        }
    }

    /// The group `id` belongs to, or nil when no listed folder has that id.
    static func group(of id: String, in accounts: [ClaudeAccount],
                      launchable: (ClaudeAccount) -> Bool) -> ClaudeAccountGroup? {
        groups(accounts, launchable: launchable).first { $0.contains(id) }
    }

    /// The sign-in a folder holds, for grouping: its accountUuid and
    /// organizationUuid while it is not known to be signed out. One login
    /// can belong to several organizations, each with its own plan limits.
    static func signInKey(_ account: ClaudeAccount) -> String? {
        guard account.signedIn != false, let uuid = account.accountUuid?.lowercased(), !uuid.isEmpty,
              let organization = account.organizationUuid?.lowercased(), !organization.isEmpty else { return nil }
        return uuid + " " + organization
    }

    /// Whether two reads of one folder name the same sign-in: the same
    /// accountUuid (case ignored) and, when both name one, the same
    /// organization. What was read for one sign-in never counts for another.
    static func sameSignIn(accountUuid: String?, organizationUuid: String?,
                           as otherAccountUuid: String?, _ otherOrganizationUuid: String?) -> Bool {
        guard accountUuid?.lowercased() == otherAccountUuid?.lowercased() else { return false }
        guard let organizationUuid, let otherOrganizationUuid else { return true }
        return organizationUuid.lowercased() == otherOrganizationUuid.lowercased()
    }

    /// Whether work on a shared sign-in launches in `a` before `b`, of two
    /// folders that can both be launched: the folder the person's list
    /// expects to hold the account first (ClaudeAccountList: its duplicates
    /// are the others), then the default folder, then the shorter path.
    /// Equal ones keep their order in the list.
    static func launchesBefore(_ a: ClaudeAccount, _ b: ClaudeAccount) -> Bool {
        let aOwns = a.expectedEmail != nil && !a.holdsWrongAccount
        let bOwns = b.expectedEmail != nil && !b.holdsWrongAccount
        if aOwns != bOwns { return aOwns }
        if a.isDefault != b.isDefault { return a.isDefault }
        return a.folder.count < b.folder.count
    }

    // MARK: Labels

    /// Webmail domains, whose name says nothing about the account: the part
    /// before the @ names it instead.
    static let webmailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com", "live.com",
        "msn.com", "yahoo.com", "aol.com", "proton.me", "protonmail.com", "pm.me", "fastmail.com", "hey.com",
        "gmx.com", "zoho.com",
    ]

    /// A short name for a new account: the email's domain without ".com"
    /// ("rhodesconsulting"), the whole domain otherwise ("elliotgrayco.me"), the
    /// part before the @ for webmail, or the folder's name ("work" for
    /// ~/.claude-work, "default" for the default account). Made unique among
    /// `taken` (lowercased) with "-2", "-3", …
    static func label(email: String?, folder: String, taken: Set<String>) -> String {
        var base = ""
        if let email, let at = email.lastIndex(of: "@") {
            let local = String(email[..<at]).lowercased()
            let domain = String(email[email.index(after: at)...]).lowercased()
            if webmailDomains.contains(domain) {
                base = local
            } else if domain.hasSuffix(".com"), domain.count > 4 {
                base = String(domain.dropLast(4))
            } else {
                base = domain
            }
        }
        base = sanitized(base)
        if base.isEmpty {
            if folder.isEmpty {
                base = "default"
            } else {
                var name = (folder as NSString).lastPathComponent
                if name.hasPrefix(folderPrefix) { name.removeFirst(folderPrefix.count) }
                base = sanitized(name)
                if base.isEmpty { base = "account" }
            }
        }
        var candidate = base
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = base + "-\(number)"
            number += 1
        }
        return candidate
    }

    /// Letters, digits, ".", "-" and "_" only: a label is typed after `cc`
    /// and `cx --to`, so it must be one shell word.
    static func sanitized(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        let kept = String(text.filter { allowed.contains($0) })
        let trimmed = kept.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return String(trimmed.prefix(labelLimit))
    }

    /// Why `label` cannot name an account, or nil when it can.
    static func labelProblem(_ label: String, others: [String]) -> String? {
        if label.isEmpty { return "a name is needed" }
        if sanitized(label) != label { return "use letters, digits, \".\", \"-\" or \"_\" only, up to \(labelLimit)" }
        if label.lowercased() == ClaudeNewSessions.autoValue { return "\"auto\" is taken by the automatic choice" }
        if others.contains(where: { $0.lowercased() == label.lowercased() }) { return "another account has that name" }
        return nil
    }

    /// The folder a new account gets: ~/.claude-<label>, or with "-2", "-3", …
    /// when that name is taken by something already in the home folder.
    static func newFolder(label: String, home: String) -> String {
        let base = home + "/" + folderPrefix + (sanitized(label).isEmpty ? "account" : sanitized(label).lowercased())
        var candidate = base
        var number = 2
        while ClaudeFileIO.exists(candidate) {
            candidate = base + "-\(number)"
            number += 1
        }
        return candidate
    }
}
