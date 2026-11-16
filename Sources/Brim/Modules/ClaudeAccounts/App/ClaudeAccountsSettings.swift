// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import SwiftUI

/// Claude accounts on their own Settings page and in their own
/// window: the account list (each email and the folder that holds it, with
/// Sign in where it is not signed in), which one new sessions use, and the
/// setup, each change shown in full before it runs and undoable afterwards.
struct ClaudeAccountsSettings: View {
    /// What the window opens on: the add sheet, or a sign-in.
    enum Start: Equatable {
        case add
        case signIn(String)
    }

    var start: Start? = nil
    /// The accounts window's own view, which takes the starts the window
    /// hands it while it stays up (ClaudeAccountsWindow.show).
    var takesWindowStarts = false
    @ObservedObject private var service = ClaudeAccountsService.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var sheet: Sheet?
    @State private var planning = false
    /// Read when the view appears and after each change, not on every draw.
    @State private var shell = ClaudeShellIntegration.Status.notInstalled
    @State private var statusLine = ClaudeStatusLineInstall.Status.notInstalled
    @State private var record = ClaudeInstallRecord()
    @State private var shared: [String] = []
    @State private var shareNeedsUpdate = false

    private var text: ClaudeAccountsStrings { FeatureStrings.claudeAccounts(l10n.language) }

    private enum Sheet: Identifiable {
        case review(ClaudeReview)
        case rename(id: String, name: String)
        case add
        case signIn

        var id: String {
            switch self {
            case .review(let review): return "review-" + review.id.uuidString
            case .rename(let id, _): return "rename-" + id
            case .add: return "add"
            case .signIn: return "sign-in"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ClaudeCommandsCard(text: text, shellInstalled: shell == .installed)
            Divider()
            Text(text.accountsTitle).font(.subheadline.weight(.medium))
            Text(text.accountsHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(service.settingsProblems, id: \.message) { problem in
                Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(service.items) { item in
                itemView(item)
                Divider()
            }
            if service.asksForOthers { ClaudeOthersPrompt(text: text) }
            SettingsRow(symbol: "arrow.triangle.branch", title: text.newSessionsUse) {
                ClaudeNewSessionsPicker(text: text).labelsHidden().fixedSize()
            }
            HStack {
                Button(text.addAccount) { sheet = .add }
                Button(text.refreshAll) { service.refreshAll() }
                if planning { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text(text.vscodeNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            Text(text.setupTitle).font(.subheadline.weight(.medium))
            SettingsRow(symbol: "terminal", title: text.shellTitle, caption: text.shellHelp) {
                HStack(spacing: 8) {
                    Text(describe(shell)).font(.caption).foregroundStyle(.secondary)
                    if record.shell != nil { Button(text.undo) { reviewUndoShell() } }
                    if shell != .installed { Button(text.review) { reviewShell() } }
                }
            }
            SettingsRow(symbol: "text.line.last.and.arrowtriangle.forward", title: text.statusLineTitle, caption: text.statusLineHelp) {
                HStack(spacing: 8) {
                    Text(describe(statusLine)).font(.caption).foregroundStyle(.secondary)
                    if record.statusLine != nil { Button(text.undo) { reviewUndoStatusLine() } }
                    if statusLine == .notInstalled { Button(text.review) { reviewStatusLine() } }
                }
            }
            SettingsRow(symbol: "link", title: text.shareTitle, caption: text.shareHelp) {
                HStack(spacing: 8) {
                    if planning { ProgressView().controlSize(.small) }
                    if shareNeedsUpdate { Text(text.shareNeedsUpdate).font(.caption).foregroundStyle(.orange) }
                    if !shared.isEmpty { Button(text.undo) { reviewUndoShare() } }
                    Button(text.review) { reviewShare() }.disabled(planning)
                }
            }
            // One place for MCP: switches per repo, each repo's own servers
            // and the user-scope mirror all live on the MCP page.
            SettingsRow(symbol: "server.rack", title: text.mcpTitle, caption: text.mcpHelp) {
                Button(text.mcpOpen) { ClaudeMCPWindow.show() }
            }
        }
        .onAppear {
            service.syncWithPreferences()
            service.foreground()
            readState()
            if let start { begin(start) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ClaudeAccountsWindow.startRequest)) { note in
            // A sheet that is up stays: the window only comes forward.
            guard takesWindowStarts, sheet == nil, service.signIn == nil,
                  let start = note.userInfo?[ClaudeAccountsWindow.startKey] as? Start else { return }
            begin(start)
        }
        .sheet(item: $sheet, onDismiss: readState) { sheet in
            switch sheet {
            case .review(let review):
                ClaudeReviewSheet(review: review, text: text)
            case .rename(let id, let name):
                ClaudeNameSheet(title: text.rename, help: text.renameHelp, confirm: text.save, text: text,
                                name: name) { service.rename(id: id, to: $0) }
            case .add:
                ClaudeAddAccountSheet(text: text)
            case .signIn:
                ClaudeSignInSheet(text: text)
            }
        }
    }

    /// An account of the list: its ranked row while it is signed in, else
    /// its status with Sign in; a ranked account that is no entry's alone.
    @ViewBuilder private func itemView(_ item: ClaudeAccountItem) -> some View {
        let failureText = FeatureStrings.notchAgents(l10n.language).claudeCode
        if let row = item.row {
            let named = item.entry?.account ?? row.account
            ClaudeAccountRowView(row: row, entry: item.entry, text: text, failureText: failureText, detailed: true,
                                 rename: { sheet = .rename(id: named.id, name: named.label) },
                                 signIn: item.entry.flatMap { entry in
                                     ClaudeAccountsAppSupport.offersSignIn(item) ? { signIn(entry.id) } : nil
                                 },
                                 tidyUp: item.entry.flatMap { entry in service.offersTidyUp(entry) ? { tidyUp(entry.id) } : nil })
        } else if let entry = item.entry {
            ClaudeAccountEntryRowView(entry: entry, text: text, detailed: true, signIn: { signIn(entry.id) },
                                      rename: { sheet = .rename(id: entry.id, name: entry.label) })
        }
    }

    private func begin(_ start: Start) {
        switch start {
        case .add: sheet = .add
        case .signIn(let id): signIn(id)
        }
    }

    private func signIn(_ id: String) {
        service.startSignIn(id: id)
        if service.signIn != nil { sheet = .signIn }
    }

    private func tidyUp(_ id: String) {
        planning = true
        service.planTidy(id: id) { plan in
            planning = false
            guard let plan else { return }
            var run: ClaudeReview.Run?
            if plan.canRun {
                run = { done in service.runTidy(id: id) { report in done(report.lines) } }
            }
            sheet = .review(ClaudeReview(title: text.tidyTitle, lines: plan.lines, problems: plan.problems, run: run))
        }
    }

    private func readState() {
        shell = service.shellStatus()
        statusLine = service.statusLineStatus()
        record = service.installRecord()
        shared = service.sharedFolders
        shareNeedsUpdate = service.shareNeedsUpdate
    }

    private func describe(_ status: ClaudeShellIntegration.Status) -> String {
        switch status {
        case .installed: return text.installed
        case .notInstalled: return text.notInstalled
        case .partial: return text.partlyInstalled
        }
    }

    private func describe(_ status: ClaudeStatusLineInstall.Status) -> String {
        switch status {
        case .installed: return text.installed
        case .notInstalled: return text.notInstalled
        case .other: return text.otherStatusLine
        }
    }

    private func reviewShell() {
        let plan = service.planShell()
        sheet = .review(ClaudeReview(title: text.shellTitle, lines: plan.lines, problems: plan.problems) { done in
            done(service.installShell().lines)
        })
    }

    private func reviewUndoShell() {
        sheet = .review(ClaudeReview(title: text.shellTitle + " · " + text.undo, lines: service.undoShellPlan()) { done in
            done(service.undoShell().lines)
        })
    }

    private func reviewStatusLine() {
        let plan = service.planStatusLine()
        sheet = .review(ClaudeReview(title: text.statusLineTitle, lines: plan.lines, problems: plan.problems) { done in
            done(service.installStatusLine().lines)
        })
    }

    private func reviewUndoStatusLine() {
        sheet = .review(ClaudeReview(title: text.statusLineTitle + " · " + text.undo, lines: service.undoStatusLinePlan()) { done in
            done(service.undoStatusLine().lines)
        })
    }

    private func reviewShare() {
        planning = true
        service.planShare { plan in
            planning = false
            var run: ClaudeReview.Run?
            if plan.changesSomething {
                run = { done in service.runShare { report in done(report.lines) } }
            }
            // A running session leaves only its folder out (the plan's lines
            // say so); what stops the whole change is shown as blocked.
            sheet = .review(ClaudeReview(title: text.shareTitle, lines: plan.lines,
                                         problems: plan.problems.filter(\.blocksAll).map(\.message), run: run))
        }
    }

    private func reviewUndoShare() {
        sheet = .review(ClaudeReview(title: text.shareTitle + " · " + text.undo, lines: service.undoSharePlan()) { done in
            service.undoShare { done($0.lines) }
        })
    }
}

/// What to type in Terminal: `claude` (and the account it starts on now),
/// `cc <account>` for each signed-in account, and `cx` to move the last
/// conversation after /exit. Each line copies its command.
struct ClaudeCommandsCard: View {
    let text: ClaudeAccountsStrings
    let shellInstalled: Bool
    @ObservedObject private var service = ClaudeAccountsService.shared
    @State private var copied: String?

    /// The account a plain `claude` starts on: the one picked in "New
    /// sessions use", else the best ranked account that has room.
    private var next: ClaudeAccountRow? {
        if case .account(let id) = service.newSessions,
           let chosen = service.rows.first(where: { $0.rank.contains(id) }) { return chosen }
        return service.rows.first(where: \.rank.isUsable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text.commandsTitle).font(.subheadline.weight(.medium))
            if !shellInstalled {
                Text(text.commandsNeedShell).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            line("claude", caption: next.map { text.commandStartsOn($0.account.label) } ?? text.commandStartsNone)
            ForEach(service.rows) { row in
                line("cc " + ClaudeLaunchEnvironment.shellQuote(row.account.label), caption: text.commandAccountHelp)
            }
            if let next {
                line("cx", caption: text.commandMove(next.account.label))
            }
        }
    }

    private func line(_ command: String, caption: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button(copied == command ? text.copied : text.copyCommand) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.declareBrimSource()
                pasteboard.setString(command, forType: .string)
                copied = command
            }
            .controlSize(.small)
        }
    }
}

/// Claude accounts as its own Settings page.
struct ClaudeAccountsSettingsPage: View {
    var body: some View {
        Form {
            Section { ClaudeAccountsSettings() }
        }
        .formStyle(.grouped)
    }
}
