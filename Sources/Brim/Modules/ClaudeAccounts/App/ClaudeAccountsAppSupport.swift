// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import Foundation

// The app side of Brim's Claude accounts that has no UI: the accounts list's
// lines, how readings become the island's limits cards, which account the
// island follows, and the plan.
// Pure, so the tests compile it (build.sh TEST_SOURCES). The files in the
// folder above are the shared core the brim-claude helper compiles too; this
// folder uses app types and is compiled into the app only.

extension DefaultsKey {
    /// Whether the menu panel shows the Claude section. Read with its default
    /// (shown), so it needs no registration.
    static let panelShowClaude = "panelShowClaude"
}

/// One account as the menu panel and Settings show it, in ranking order.
/// Folders that share a sign-in are one row, named by the folder launches use.
struct ClaudeAccountRow: Identifiable, Equatable {
    var rank: ClaudeAccountRank
    /// Its place in the ranking, 0 first.
    var position: Int
    /// Running sessions in any of its folders.
    var liveSessions: Int
    /// A check is queued or running.
    var checking: Bool
    var failure: AgentClaudeServer.Failure?
    /// Why Brim will not start Claude Code on its folder, if it will not.
    var launchProblem: String?
    /// MCP servers that wait for this account's own sign-in.
    var mcpNeedsLogin: [String]

    var account: ClaudeAccount { rank.account }
    var id: String { rank.account.id }
    /// Every folder signed in to the account, the one launches use first.
    var folders: [ClaudeAccount] { rank.folders }
}

/// A sign-in Brim runs, as its sheet shows it.
struct ClaudeSignInState: Identifiable, Equatable {
    enum Phase: Equatable {
        /// Claude Code is starting; no link yet.
        case waiting
        /// The link is out; the person signs in.
        case signingIn
        /// Claude Code signed the folder in to this other email.
        case wrongAccount(String)
        case failed(String)
    }

    /// Step 1: how the link reached a private window.
    enum Window: Equatable {
        /// A private window of this browser opened on it.
        case opened(browser: String)
        /// The default browser takes no private-window flag, or opening it
        /// failed: the person copies the link into one.
        case copyLink
    }

    let id = UUID()
    var accountID: String
    var label: String
    var email: String
    var folder: String
    /// The Claude Code sessions running on the folder when the sign-in
    /// started (ClaudeSessionIndex.describe): they switch to whatever
    /// account it signs the folder in to.
    var liveSessions: [String] = []
    var phase: Phase = .waiting
    var window: Window?
    /// The sign-in link, in memory only, for Copy link.
    var link: URL?

    var isDefaultFolder: Bool { folder.isEmpty }
    var ended: Bool {
        switch phase {
        case .wrongAccount, .failed: return true
        default: return false
        }
    }
}

/// What showing the accounts window does with the window made before.
enum ClaudeAccountsWindowShow: Equatable {
    /// It comes forward as it is, and its view takes the start.
    case keep
    /// It gets a fresh view, opened on the start.
    case rebuild
}

/// One line of the accounts list: an account the person expects (its
/// email, folder, status and duplicate folders) and, while that account is
/// signed in, its ranked row with plan and limits. A ranked Claude account
/// that is no expected account's (a folder signed out, or a second
/// organization of one login) shows as a row alone.
struct ClaudeAccountItem: Identifiable, Equatable {
    var entry: ClaudeAccountEntry?
    var row: ClaudeAccountRow?

    var id: String { entry?.id ?? row?.id ?? "" }
}

enum ClaudeAccountsAppSupport {
    /// The list's lines: each signed-in account's row in ranking order, a
    /// ranked account no entry covers on its own, then the accounts waiting
    /// for their sign-in in list order.
    static func items(rows: [ClaudeAccountRow], entries: [ClaudeAccountEntry]) -> [ClaudeAccountItem] {
        var items: [ClaudeAccountItem] = []
        for row in rows {
            if let entry = entries.first(where: { $0.status == .signedIn && row.rank.contains($0.id) }) {
                items.append(ClaudeAccountItem(entry: entry, row: row))
            } else if !entries.contains(where: { row.rank.contains($0.id) }) {
                items.append(ClaudeAccountItem(entry: nil, row: row))
            }
        }
        return items + entries.filter { $0.status != .signedIn }.map { ClaudeAccountItem(entry: $0, row: nil) }
    }

    /// Whether the line offers Sign in: an account that is not signed in,
    /// or whose folder holds another account, and a signed-in one only once
    /// its check says the sign-in stopped working. A sign-in that works is
    /// never offered, since starting one on it (the default folder's, most
    /// of all) could switch it by mistake.
    static func offersSignIn(_ item: ClaudeAccountItem) -> Bool {
        guard let entry = item.entry else { return false }
        return entry.status != .signedIn || item.row?.failure == .needsSignIn
    }

    /// Showing the accounts window when it was made before: while it is on
    /// screen, a sheet is up on it or a sign-in runs, it keeps its view (a
    /// new one would close the sheet, and a sign-in's sheet ends its
    /// sign-in as it closes); a window closed with nothing running gets a
    /// fresh one.
    static func windowShow(onScreen: Bool, sheetUp: Bool, signingIn: Bool) -> ClaudeAccountsWindowShow {
        onScreen || sheetUp || signingIn ? .keep : .rebuild
    }

    /// An account's windows as the island's limits card shows them. A window
    /// that renewed since it was read shows its estimated 0 % and next
    /// renewal as an estimate, never as a confirmed time.
    static func limits(_ rank: ClaudeAccountRank) -> AgentLimits? {
        guard let observed = rank.newestObservation, !rank.windows.isEmpty else { return nil }
        let windows = rank.windows.map { window -> AgentLimitWindow in
            let id: String
            let scope: String?
            switch window.kind {
            case .fiveHour: (id, scope) = ("fh", nil)
            case .weekly: (id, scope) = ("sd", nil)
            case .scoped(let model): (id, scope) = ("sc." + model.lowercased(), model)
            }
            return AgentLimitWindow(id: "claude.\(rank.account.id).\(id)", kind: window.kind == .fiveHour ? .session : .weekly,
                                    minutes: window.kind == .fiveHour ? 300 : 10_080, scope: scope,
                                    usedPercent: min(100, max(0, window.utilization)),
                                    resetsAt: window.estimated ? nil : window.resetsAt,
                                    estimatedResetsAt: window.estimated ? window.resetsAt : nil)
        }
        return AgentLimits(provider: .claude, windows: windows, observedAt: observed, source: .account)
    }

    /// The account Claude works on now, which the island's strip, resting
    /// allowance and limit alerts follow: among accounts with running
    /// sessions, the one whose status line reported last (else the best
    /// ranked of them); with none running, the one new sessions would use.
    /// An account's folders count together: its sessions in any of them,
    /// and the newest status line among them.
    static func focus(_ ranks: [ClaudeAccountRank], liveSessions: [String: Int], live: [String: ClaudeLiveFile],
                      newSessions: ClaudeNewSessions) -> ClaudeAccountRank? {
        func sessions(_ rank: ClaudeAccountRank) -> Int { rank.folders.reduce(0) { $0 + (liveSessions[$1.id] ?? 0) } }
        func reported(_ rank: ClaudeAccountRank) -> Date {
            rank.folders.compactMap { live[$0.id]?.observedAt }.max() ?? .distantPast
        }
        let running = ranks.filter { sessions($0) > 0 }
        if !running.isEmpty {
            return running.max { left, right in
                let a = reported(left)
                let b = reported(right)
                if a != b { return a < b }
                // Equal: keep the better ranked, which comes first.
                return ranks.firstIndex(of: left)! > ranks.firstIndex(of: right)!
            }
        }
        if case .account(let id) = newSessions, let chosen = ranks.first(where: { $0.contains(id) }) { return chosen }
        return ranks.first
    }

    /// One identity per Claude account that is not signed out: folders that
    /// share a sign-in give theirs once, so a plan is never counted twice.
    static func accountIdentities(_ groups: [ClaudeAccountGroup], identities: [String: ClaudeIdentity]) -> [ClaudeIdentity] {
        groups.filter { $0.primary.signedIn != false }.compactMap { group in
            group.members.lazy.compactMap { identities[$0.id] }.first
        }
    }

    /// The plan the island compares Claude's API value against: one
    /// account's plan, or every signed-in account's together ("2 × Max 20x")
    /// with their prices added, when each is known.
    static func plan(_ plans: [AgentPlan]) -> AgentPlan? {
        guard let first = plans.first else { return nil }
        guard plans.count > 1 else { return first }
        let names = plans.map(\.name)
        let name = Set(names).count == 1 ? "\(plans.count) × \(first.name)" : names.joined(separator: " + ")
        let prices = plans.compactMap(\.monthlyPrice)
        return AgentPlan(name: name, monthlyPrice: prices.count == plans.count ? prices.reduce(0, +) : nil)
    }
}
