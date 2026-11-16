// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

/// What an expected account's folder holds now.
enum ClaudeSignInStatus: Equatable {
    case signedIn
    case notSignedIn
    /// Signed in to another email than the one expected there.
    case wrongAccount(holds: String)
}

/// One account in the person's list: the email they expect and the folder
/// that should hold it, what that folder holds now, and the other folders
/// signed in to the same account that are no account's (duplicates, which
/// Tidy up removes).
struct ClaudeAccountEntry: Equatable, Identifiable {
    /// The folder's record; its expectedEmail is set.
    var account: ClaudeAccount
    var status: ClaudeSignInStatus
    /// Folders that share this account's sign-in and are no account's.
    /// Empty unless the account is signed in.
    var duplicates: [ClaudeAccount]

    var id: String { account.id }
    var email: String { account.expectedEmail ?? "" }
    var label: String { account.label }
    var folder: String { account.folder }
}

/// The account list is the plan: each account is an email the person
/// expects and the folder that should hold it (ClaudeAccount.expectedEmail,
/// kept in accounts.json; never a credential). Pure apart from reading the
/// state Brim already has.
enum ClaudeAccountList {
    // MARK: Emails

    /// Two emails are one when they match ignoring case and outer spaces.
    static func sameEmail(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let left = a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !left.isEmpty && left == b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The email in what the person typed or pasted, lowercased: outer
    /// spaces, a "mailto:" and a "Name <...>" wrapper are accepted. nil
    /// when it is not one address.
    static func normalizedEmail(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = value.lastIndex(of: "<"), let close = value.lastIndex(of: ">"), open < close {
            value = String(value[value.index(after: open)..<close])
        }
        if value.lowercased().hasPrefix("mailto:") { value.removeFirst(7) }
        value = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        guard value.count <= 254, value.filter({ $0 == "@" }).count == 1,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                  || CharacterSet.controlCharacters.contains($0) }),
              let at = value.firstIndex(of: "@") else { return nil }
        let local = value[..<at]
        let domain = value[value.index(after: at)...]
        guard !local.isEmpty, domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."),
              !domain.contains("..") else { return nil }
        return value.lowercased()
    }

    /// A short name for an email in the list's words ("Holds …"): its domain
    /// ("elliotgrayco.me"), or the whole address for a webmail domain, which
    /// says nothing about the account.
    static func shortName(email: String) -> String {
        let lowered = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = lowered.lastIndex(of: "@") else { return lowered }
        let domain = String(lowered[lowered.index(after: at)...])
        return domain.isEmpty || ClaudeAccountsDiscovery.webmailDomains.contains(domain) ? lowered : domain
    }

    // MARK: Statuses

    /// What an expected account's folder holds now; nil for a folder that is
    /// no account's.
    static func status(_ account: ClaudeAccount) -> ClaudeSignInStatus? {
        guard let expected = account.expectedEmail else { return nil }
        guard let held = account.heldEmail else { return .notSignedIn }
        return sameEmail(held, expected) ? .signedIn : .wrongAccount(holds: held)
    }

    /// The account in the person's list a folder's sign-in belongs to: the
    /// folder itself when it is expected to hold what it holds (or holds
    /// nothing yet), else the folder expected to hold that sign-in (the
    /// same account in the same organization) that holds it. nil when no
    /// folder in the list does, or the folder's sign-in is not known.
    static func owner(of account: ClaudeAccount, in accounts: [ClaudeAccount]) -> ClaudeAccount? {
        if account.expectedEmail != nil && !account.holdsWrongAccount { return account }
        guard let key = ClaudeAccountsDiscovery.signInKey(account) else { return nil }
        return accounts.first { other in
            other.id != account.id && other.expectedEmail != nil && !other.holdsWrongAccount
                && ClaudeAccountsDiscovery.signInKey(other) == key
        }
    }

    /// A folder that is no account's and shares its sign-in with one in the
    /// list: it runs as that account, and its own label (from what it held
    /// before) names nothing.
    static func isDuplicate(_ account: ClaudeAccount, in accounts: [ClaudeAccount]) -> Bool {
        account.expectedEmail == nil && owner(of: account, in: accounts) != nil
    }

    /// The list: every folder with an expected email, in list order.
    static func entries(_ accounts: [ClaudeAccount], launchable: (ClaudeAccount) -> Bool) -> [ClaudeAccountEntry] {
        let groups = ClaudeAccountsDiscovery.groups(accounts, launchable: launchable)
        return accounts.compactMap { account in
            guard let status = status(account) else { return nil }
            var duplicates: [ClaudeAccount] = []
            if status == .signedIn, let group = groups.first(where: { $0.contains(account.id) }) {
                duplicates = group.members.filter { $0.id != account.id && $0.expectedEmail == nil }
            }
            return ClaudeAccountEntry(account: account, status: status, duplicates: duplicates)
        }
    }

    // MARK: Filling the list

    /// Every email a folder is signed in to joins the list when no account
    /// expects it yet, on the folder launches use first among those that are
    /// no account's. On the first run that fills the list from the disk;
    /// later it lists a folder that signed in to a new account outside Brim,
    /// which would otherwise show nowhere. A folder already expected to hold
    /// another email keeps that (it holds the wrong account). A folder that
    /// starts to expect an email is named after it (labels follow the
    /// expected email), so a name kept from an earlier sign-in goes.
    ///
    /// The default folder is never a duplicate, since Tidy up never removes
    /// it: when it shares its sign-in with the folder expected to hold that
    /// account and expects nothing itself, the account moves to it. That
    /// happens after a run that filled the list while ~/.claude.json could
    /// not be read.
    static func expect(_ accounts: [ClaudeAccount], launchable: (ClaudeAccount) -> Bool) -> [ClaudeAccount] {
        var result = accounts
        if let index = result.firstIndex(where: \.isDefault), result[index].expectedEmail == nil,
           let owner = owner(of: result[index], in: result), let email = owner.expectedEmail,
           let from = result.firstIndex(where: { $0.id == owner.id }) {
            result[from].expectedEmail = nil
            name(index, after: email, in: &result)
        }
        for group in ClaudeAccountsDiscovery.groups(result, launchable: launchable) {
            guard let held = group.members.lazy.compactMap(\.heldEmail).first,
                  !result.contains(where: { sameEmail($0.expectedEmail, held) }),
                  let member = group.members.first(where: { $0.expectedEmail == nil && $0.heldEmail != nil }),
                  let index = result.firstIndex(where: { $0.folder == member.folder }) else { continue }
            name(index, after: held.lowercased(), in: &result)
        }
        return result
    }

    /// Expects `email` in the folder at `index` and names the folder after
    /// it (ClaudeAccountsDiscovery.label), unique among the other names. A
    /// folder that shares its sign-in and is no account's (a duplicate)
    /// gives that name up, for one from its folder's name.
    private static func name(_ index: Int, after email: String, in accounts: inout [ClaudeAccount]) {
        accounts[index].expectedEmail = email
        let key = ClaudeAccountsDiscovery.signInKey(accounts[index])
        let yields = { (other: ClaudeAccount) -> Bool in
            other.expectedEmail == nil && key != nil && ClaudeAccountsDiscovery.signInKey(other) == key
        }
        let taken = Set(accounts.indices.filter { $0 != index && !yields(accounts[$0]) }.map { accounts[$0].label.lowercased() })
        let label = ClaudeAccountsDiscovery.label(email: email, folder: accounts[index].folder, taken: taken)
        accounts[index].label = label
        for other in accounts.indices
        where other != index && yields(accounts[other]) && accounts[other].label.lowercased() == label.lowercased() {
            let others = Set(accounts.indices.filter { $0 != other }.map { accounts[$0].label.lowercased() })
            accounts[other].label = ClaudeAccountsDiscovery.label(email: nil, folder: accounts[other].folder, taken: others)
        }
    }

    /// A listed folder, or a ~/.claude-<name> folder found on disk, signed in
    /// to `email`; nil when none is.
    static func holder(of email: String, accounts: [ClaudeAccount], states: [String: ClaudeFolderState]) -> String? {
        if let account = accounts.first(where: { sameEmail($0.heldEmail, email) }) { return account.folder }
        return states.keys.sorted().first { folder in
            guard let snapshot = states[folder]?.snapshot, snapshot.signedIn else { return false }
            return sameEmail(snapshot.identity?.email, email)
        }
    }

    // MARK: Adding an account

    struct AddPlan: Equatable {
        var email: String
        var label: String
        var folder: String
        /// The folder is there already (reused or chosen); otherwise Brim
        /// creates it (mode 0700).
        var reuses: Bool
    }

    enum AddProblem: Error, Equatable {
        case invalidEmail
        /// An account in the list expects it (its label).
        case alreadyListed(String)
        /// A folder is signed in to it already.
        case alreadySignedIn(folder: String)
        /// The chosen folder is another account's (its label or email).
        case folderTaken(String)
        /// The chosen folder cannot be an account's folder.
        case folder(String)
    }

    /// What adding `text` would do: the label (from the email: its domain,
    /// or the part before the @ for webmail), and the folder, which is the
    /// one the person chose, else a free ~/.claude-<name> folder whose name
    /// matches the label (ClaudeAccountList.reusableFolder), else a new
    /// ~/.claude-<label>. An email the list has, or that a folder already
    /// holds, is refused and changes nothing.
    static func planAdd(email text: String, chosenFolder: String?, accounts: [ClaudeAccount], candidates: [String],
                        states: [String: ClaudeFolderState], home: String) -> Result<AddPlan, AddProblem> {
        guard let email = normalizedEmail(text) else { return .failure(.invalidEmail) }
        if let listed = accounts.first(where: { sameEmail($0.expectedEmail, email) }) {
            return .failure(.alreadyListed(listed.label))
        }
        if let folder = holder(of: email, accounts: accounts, states: states) {
            return .failure(.alreadySignedIn(folder: folder))
        }
        let base = ClaudeAccountsDiscovery.label(email: email, folder: "", taken: [])
        let folder: String
        let reuses: Bool
        if let chosen = chosenFolder {
            switch checkChosen(chosen, accounts: accounts, states: states, home: home) {
            case .success(let checked):
                folder = checked
                reuses = checked.isEmpty || ClaudeFileIO.isDirectory(checked, followingLinks: true)
            case .failure(let problem):
                return .failure(problem)
            }
        } else if let reused = reusableFolder(label: base, accounts: accounts, candidates: candidates, states: states) {
            folder = reused
            reuses = true
        } else {
            folder = ClaudeAccountsDiscovery.newFolder(label: base, home: home)
            reuses = false
        }
        let taken = Set(accounts.filter { $0.folder != folder }.map { $0.label.lowercased() })
        let label = ClaudeAccountsDiscovery.label(email: email, folder: folder, taken: taken)
        return .success(AddPlan(email: email, label: label, folder: folder, reuses: reuses))
    }

    /// Whether a folder can take a new account: it is no account's, and it
    /// is empty, signed out, or a duplicate: signed in to the same account
    /// in the same organization as a folder expected to hold that account
    /// (the same email in another organization is another Claude account,
    /// with limits of its own). A folder whose file cannot be read is never
    /// taken.
    static func isFree(_ folder: String, accounts: [ClaudeAccount], states: [String: ClaudeFolderState]) -> Bool {
        let listed = accounts.first { $0.folder == folder }
        if listed?.expectedEmail != nil { return false }
        switch states[folder] ?? .unreadable {
        case .missing:
            return true
        case .unreadable:
            return listed?.signedIn == false
        case .snapshot(let snapshot):
            guard snapshot.signedIn, let identity = snapshot.identity else { return true }
            let held = ClaudeAccount(label: "", folder: folder, accountUuid: identity.accountUuid,
                                     organizationUuid: identity.organizationUuid, email: identity.email, signedIn: true)
            return isDuplicate(held, in: accounts.filter { $0.folder != folder })
        }
    }

    /// A free ~/.claude-<name> folder whose name matches the label: the same
    /// letters and digits, or one starting with the other when the shorter
    /// has at least four ("rhodesconsulting" for "rhodesconsultingllc").
    /// An exact match wins, then the longest name, then the first in order.
    /// Never the default folder.
    static func reusableFolder(label: String, accounts: [ClaudeAccount], candidates: [String],
                               states: [String: ClaudeFolderState]) -> String? {
        var best: (score: Int, length: Int, folder: String)?
        for folder in Set(candidates).sorted() where !folder.isEmpty {
            guard let match = nameMatch(folder: folder, label: label),
                  isFree(folder, accounts: accounts, states: states) else { continue }
            if let current = best, (current.score, current.length) >= (match.score, match.length) { continue }
            best = (match.score, match.length, folder)
        }
        return best?.folder
    }

    /// How a ~/.claude-<name> folder's name matches a label: 2 for the same
    /// letters and digits, 1 when one starts with the other and the shorter
    /// has at least four, with the name's length; nil for no match.
    static func nameMatch(folder: String, label: String) -> (score: Int, length: Int)? {
        let wanted = squeezed(label)
        var name = (folder as NSString).lastPathComponent
        guard !wanted.isEmpty, !folder.isEmpty, name.hasPrefix(ClaudeAccountsDiscovery.folderPrefix) else { return nil }
        name.removeFirst(ClaudeAccountsDiscovery.folderPrefix.count)
        let suffix = squeezed(name)
        if suffix == wanted { return (2, suffix.count) }
        if min(suffix.count, wanted.count) >= 4, suffix.hasPrefix(wanted) || wanted.hasPrefix(suffix) { return (1, suffix.count) }
        return nil
    }

    /// The folder the person chose, as an account folder: ~/.claude spelled
    /// out is the default folder (""). Refused when its spelling would
    /// select another sign-in, when it is not theirs or others can write it,
    /// or when it is another account's.
    static func checkChosen(_ chosen: String, accounts: [ClaudeAccount], states: [String: ClaudeFolderState],
                            home: String) -> Result<String, AddProblem> {
        var folder = chosen
        if folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        // Spelled as written, or the same folder once links are resolved
        // (standardizing a path drops "/private" only for paths that exist).
        let spelledOut = home + "/.claude"
        if folder == spelledOut
            || (ClaudeFileIO.exists(folder) && ClaudeFileIO.realPath(folder) == ClaudeFileIO.realPath(spelledOut)) {
            folder = ""
        }
        if let problem = ClaudeLaunchEnvironment.folderProblem(folder, home: home) { return .failure(.folder(problem.message)) }
        if !folder.isEmpty, ClaudeFileIO.exists(folder),
           let problem = ClaudeLaunchEnvironment.launchProblem(forFolder: folder, home: home) {
            return .failure(.folder(problem))
        }
        if let owner = accounts.first(where: { $0.folder == folder && $0.expectedEmail != nil }) {
            return .failure(.folderTaken(owner.label))
        }
        let state = states[folder] ?? (ClaudeFileIO.exists(folder) || folder.isEmpty
            ? ClaudeAccountsDiscovery.state(folder: folder, home: home) : .missing)
        guard isFree(folder, accounts: accounts, states: [folder: state]) else {
            return .failure(.folderTaken(state.snapshot?.identity?.email ?? (folder.isEmpty ? "~/.claude" : folder)))
        }
        return .success(folder)
    }

    /// Letters and digits only, lowercased.
    static func squeezed(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
            .map(Character.init))
    }
}
