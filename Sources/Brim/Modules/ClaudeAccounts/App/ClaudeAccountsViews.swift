// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import AppKit
import SwiftUI

// The pieces the Claude section of the menu panel and its Settings share.
// Countdowns and ages are SwiftUI's own relative dates, which update
// themselves; nothing here runs a timer.

/// One window: its name, a bar, the share used, and when it renews.
struct ClaudeWindowBarView: View {
    let title: String
    let window: ClaudeWindowState
    let text: ClaudeAccountsStrings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 52, alignment: .leading)
                UsageBar(fraction: window.utilization / 100, tint: window.blocks ? .red : nil)
                Text(AgentFormat.percent(window.utilization / 100))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
            if let resets = window.resetsAt {
                (Text(window.estimated ? text.renewedEstimate + " · " : "") + Text(text.resets + " ")
                    + Text(resets, style: .relative))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 60)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where an account's numbers came from and how old they are: "live",
/// "2 min ago", "checked Tue 4 PM", or "unknown".
struct ClaudeFreshnessText: View {
    let observed: Date?
    let source: ClaudeUsageSource?
    let text: ClaudeAccountsStrings

    var body: some View {
        if let observed {
            let age = Date().timeIntervalSince(observed)
            if source == .live && age < ClaudeAccountRanking.freshness {
                Text(text.live)
            } else if age < 3_600 {
                Text(min(observed, Date()), style: .relative) + Text(" " + text.ago)
            } else {
                Text(text.checked + " ") + Text(observed, format: .dateTime.weekday(.abbreviated).hour().minute())
            }
        } else {
            Text(text.unknown)
        }
    }
}

/// One account: name, plan, running sessions, its windows, the window that
/// binds for the model being run, and where the numbers came from. With its
/// entry in the list: the email, and the duplicate folders to tidy up.
struct ClaudeAccountRowView: View {
    let row: ClaudeAccountRow
    var entry: ClaudeAccountEntry? = nil
    let text: ClaudeAccountsStrings
    let failureText: (AgentClaudeServer.Failure) -> String
    /// The full row in Settings also shows the folder and renames.
    var detailed = false
    var rename: (() -> Void)? = nil
    /// Only once the account's check says its sign-in stopped working
    /// (ClaudeAccountsAppSupport.offersSignIn).
    var signIn: (() -> Void)? = nil
    var tidyUp: (() -> Void)? = nil
    @ObservedObject private var service = ClaudeAccountsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let entry {
                if detailed { signedInLine(entry) }
                if !entry.duplicates.isEmpty { duplicates(entry) }
            } else {
                if detailed && row.folders.count == 1 {
                    Text(folderName(row.account))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folderName(row.account))
                }
                if row.folders.count > 1 { sharedSignIn }
            }
            ForEach(Array(row.rank.windows.enumerated()), id: \.offset) { _, window in
                if shows(window) { ClaudeWindowBarView(title: title(window), window: window, text: text) }
            }
            if let binding = row.rank.binding, case .scoped(let model) = binding.kind {
                Text(model + " · " + text.left(AgentFormat.percent(binding.headroom / 100)))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(binding.blocks ? Color.red : Color.secondary)
            }
            footer
        }
        .padding(.vertical, 6)
        .padding(.horizontal, detailed ? 0 : 10)
    }

    private func folderName(_ account: ClaudeAccount) -> String {
        account.isDefault ? text.defaultFolder : account.folder
    }

    /// "✓ elliot@elliotgrayco.me · ~/.claude (default)".
    private func signedInLine(_ entry: ClaudeAccountEntry) -> some View {
        Label {
            Text(entry.email + " · " + service.shortFolder(entry.folder))
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help(text.statusSignedIn + ": " + entry.email)
    }

    /// "+ 1 duplicate folder  Tidy up…": other folders signed in to this
    /// account that are no account's.
    @ViewBuilder private func duplicates(_ entry: ClaudeAccountEntry) -> some View {
        let names = entry.duplicates.map { service.shortFolder($0.folder) }
        HStack(spacing: 8) {
            Text(text.duplicates(entry.duplicates.count))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .help(names.joined(separator: "\n"))
            if detailed, let tidyUp {
                Button(text.tidyUp, action: tidyUp).controlSize(.small)
            }
        }
        if detailed {
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(name)
            }
        }
    }

    /// "Same sign-in in 2 folders" and the folders, the one launches use
    /// first: one account, whose limits every folder shares.
    @ViewBuilder private var sharedSignIn: some View {
        let names = row.folders.map(folderName)
        Text(text.sameSignIn(row.folders.count))
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .help(names.joined(separator: "\n"))
        if detailed {
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(name)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(entry?.label ?? row.account.label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if let plan = row.account.plan {
                Text(plan)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            if row.position == 0 && row.rank.isUsable && service.rows.count > 1 {
                Text(text.next)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.accentColor))
            }
            Spacer(minLength: 4)
            if row.liveSessions > 0 {
                Label(text.running(row.liveSessions), systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }
            if row.checking {
                ProgressView().controlSize(.mini).help(text.checking)
            } else {
                Button { service.refresh(id: row.id) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(text.refresh)
                .accessibilityLabel(text.refresh)
            }
            actions
        }
    }

    private var actions: some View {
        Menu {
            Button(text.openTerminal) { service.openTerminal(id: row.id) }
            if let signIn { Button(text.signIn, action: signIn).disabled(service.signIn != nil) }
            Button(text.copyMove) { service.copyMoveCommand(id: row.id) }
                .help(text.copyMoveHelp)
            if let rename { Button(text.rename, action: rename) }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(row.launchProblem != nil && rename == nil)
    }

    /// The account's state when it is not simply usable.
    private var status: Text? {
        switch row.rank.status {
        case .usable:
            return nil
        case .signedOut:
            return Text(text.signedOut).foregroundStyle(.orange)
        case .unknown:
            return Text(text.noReading)
        case .limited(let until):
            guard let until else { return Text(text.overLimit + " · " + text.unknownRenewal).foregroundStyle(.red) }
            return (Text(text.overLimit + " · " + text.usableAgain + " ") + Text(until, style: .relative)).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 4) {
            if let status {
                status
                Text("·")
            }
            ClaudeFreshnessText(observed: row.rank.newestObservation,
                                source: row.rank.windows.max { $0.observedAt < $1.observedAt }?.source, text: text)
            Spacer(minLength: 0)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        if let problem = row.launchProblem {
            Text(problem).font(.system(size: 9.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else if let failure = row.failure {
            Text(failureText(failure)).font(.system(size: 9.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if detailed, !row.mcpNeedsLogin.isEmpty {
            Text(text.mcpNeedsLogin + ": " + row.mcpNeedsLogin.joined(separator: ", "))
                .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    /// Every 5-hour and weekly window, and a scoped one while it applies to
    /// the model being run or the server marks it as the limit the account
    /// is measured against now (whatever model the hint names).
    private func shows(_ window: ClaudeWindowState) -> Bool {
        if case .scoped = window.kind { return window.applies || window.serverActive || detailed }
        return true
    }

    private func title(_ window: ClaudeWindowState) -> String {
        switch window.kind {
        case .fiveHour: return text.fiveHour
        case .weekly: return text.weekly
        case .scoped(let model): return model
        }
    }
}

/// "New sessions use: Auto (soonest reset) | <account>".
struct ClaudeNewSessionsPicker: View {
    let text: ClaudeAccountsStrings
    @ObservedObject private var service = ClaudeAccountsService.shared

    var body: some View {
        Picker(text.newSessionsUse, selection: Binding(get: { service.newSessions.rawValue },
                                                       set: { service.setNewSessions(ClaudeNewSessions(rawValue: $0)) })) {
            Text(text.automatic).tag(ClaudeNewSessions.autoValue)
            ForEach(service.groups.map(\.primary), id: \.id) { account in
                Text(account.label).tag(account.id)
            }
        }
        .pickerStyle(.menu)
    }
}

// MARK: - Review before a change

/// A change shown in full before it runs: what it will do, what blocks it,
/// and, once run, what it did.
struct ClaudeReview: Identifiable {
    /// Runs the change and hands back, in words, what it did.
    typealias Run = @MainActor (@escaping @MainActor ([String]) -> Void) -> Void

    let id = UUID()
    var title: String
    var lines: [String]
    var problems: [String] = []
    /// nil when there is nothing to run.
    var run: Run?
}

struct ClaudeReviewSheet: View {
    let review: ClaudeReview
    let text: ClaudeAccountsStrings
    @Environment(\.dismiss) private var dismiss
    @State private var result: [String]?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(review.title).font(.headline)
            Text(result == nil ? text.reviewTitle + ". " + text.reviewHelp : text.resultTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array((result ?? review.lines).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if result == nil {
                        ForEach(Array(review.problems.enumerated()), id: \.offset) { _, problem in
                            Text(text.blocked + ": " + problem).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 160, maxHeight: 360)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                if result == nil {
                    Button(text.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    if let run = review.run, review.problems.isEmpty {
                        Button(text.run) {
                            running = true
                            run { lines in
                                running = false
                                result = lines
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running)
                    }
                } else {
                    Button(text.done) { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// Asks for an account's new name.
struct ClaudeNameSheet: View {
    let title: String
    let help: String
    let confirm: String
    let text: ClaudeAccountsStrings
    @State var name: String
    /// nil when accepted, else why not.
    let submit: (String) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(text.accountName, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(accept)
            Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(text.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm, action: accept).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func accept() {
        problem = submit(name.trimmingCharacters(in: .whitespaces))
        if problem == nil { dismiss() }
    }
}


// MARK: - Accounts waiting for their sign-in

/// An account in the list that is not signed in, or whose folder holds
/// another account: its status and one action, Sign in.
struct ClaudeAccountEntryRowView: View {
    let entry: ClaudeAccountEntry
    let text: ClaudeAccountsStrings
    var detailed = false
    let signIn: () -> Void
    var rename: (() -> Void)? = nil
    @ObservedObject private var service = ClaudeAccountsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(text.signIn, action: signIn)
                    .controlSize(.small)
                    .disabled(service.signIn != nil)
                if let rename {
                    Menu {
                        Button(text.rename, action: rename)
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            if detailed {
                Text(entry.email + " · " + service.shortFolder(entry.folder))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            status
        }
        .padding(.vertical, 6)
        .padding(.horizontal, detailed ? 0 : 10)
    }

    @ViewBuilder private var status: some View {
        switch entry.status {
        case .signedIn:
            Label(text.statusSignedIn, systemImage: "checkmark.circle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.green)
        case .notSignedIn:
            Label(text.statusNotSignedIn, systemImage: "circle")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        case .wrongAccount(let held):
            // The email's own name, never a label that may be stale.
            Label(text.holds(ClaudeAccountList.shortName(email: held)), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .help(held + ". " + text.wrongAccountHelp)
        }
    }
}

/// "Any other Claude accounts?" with one email field, under the list the
/// app filled from the disk. Adding an email lists it; nothing signs in.
struct ClaudeOthersPrompt: View {
    let text: ClaudeAccountsStrings
    @ObservedObject private var service = ClaudeAccountsService.shared
    @State private var email = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(service.entries.isEmpty ? text.firstAccountTitle : text.othersTitle)
                .font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                TextField(text.email, text: $email)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(text.add, action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text.othersHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if !service.entries.isEmpty {
                    Button(text.thatsAll) { service.finishAskingForOthers() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func add() {
        problem = service.addAccount(email: email, chosenFolder: nil)
        if problem == nil { email = "" }
    }
}

/// Add account: one email field. The folder Brim plans for it (a free one
/// whose name matches, else a new one) sits behind a disclosure, with
/// Choose folder… there.
struct ClaudeAddAccountSheet: View {
    let text: ClaudeAccountsStrings
    @ObservedObject private var service = ClaudeAccountsService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var chosen: String?
    @State private var showsFolder = false
    @State private var problem: String?

    private var plan: Result<ClaudeAccountList.AddPlan, ClaudeAccountList.AddProblem>? {
        email.trimmingCharacters(in: .whitespaces).isEmpty ? nil : service.planAdd(email: email, chosenFolder: chosen)
    }

    var body: some View {
        let plan = plan
        VStack(alignment: .leading, spacing: 12) {
            Text(text.addTitle).font(.headline)
            TextField(text.email, text: $email)
                .textFieldStyle(.roundedBorder)
                .onSubmit(accept)
                .onChange(of: email) { _, _ in problem = nil }
            Text(text.addHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: $showsFolder) {
                HStack(spacing: 8) {
                    Button(text.chooseFolder, action: choose)
                    if chosen != nil { Button(text.useSuggestedFolder) { chosen = nil } }
                }
                .controlSize(.small)
                .padding(.top, 4)
            } label: {
                Text(folderLine(plan))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let message = problem ?? shownProblem(plan) {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(text.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(text.add, action: accept)
                    .keyboardShortcut(.defaultAction)
                    .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func folderLine(_ plan: Result<ClaudeAccountList.AddPlan, ClaudeAccountList.AddProblem>?) -> String {
        guard case .success(let planned)? = plan else { return text.folder }
        return text.folder + ": " + text.folderPlan(service.shortFolder(planned.folder), reused: planned.reuses)
    }

    /// A refusal shows as it is typed, except a half-typed address.
    private func shownProblem(_ plan: Result<ClaudeAccountList.AddPlan, ClaudeAccountList.AddProblem>?) -> String? {
        guard case .failure(let failure)? = plan, failure != .invalidEmail else { return nil }
        return service.describe(failure)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: service.home)
        if panel.runModal() == .OK, let url = panel.url { chosen = url.path }
    }

    private func accept() {
        problem = service.addAccount(email: email, chosenFolder: chosen)
        if problem == nil { dismiss() }
    }
}

// MARK: - Sign-in

/// The sign-in Brim runs, live: three steps, the default folder's warning,
/// and one action at a time (Copy link and Cancel while it runs, Try again
/// once it ended). The right account closes it.
struct ClaudeSignInSheet: View {
    let text: ClaudeAccountsStrings
    @ObservedObject private var service = ClaudeAccountsService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied: URL?
    /// The sign-in this sheet shows now (Try again starts a new one).
    @State private var shown: UUID?

    private enum Mark { case done, active, pending, attention, failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let state = service.signIn {
                Text(text.signInTitle(state.email)).font(.headline).lineLimit(2)
                VStack(alignment: .leading, spacing: 9) {
                    step(1, firstMark(state), firstText(state))
                    step(2, secondMark(state), text.stepSignInThere(state.email))
                    step(3, thirdMark(state), text.stepCheck)
                }
                if state.isDefaultFolder { warning(text.defaultFolderWarning) }
                if !state.liveSessions.isEmpty {
                    warning(text.liveSessionsWarning(state.liveSessions.joined(separator: "; ")))
                }
                if let message = message(state) {
                    Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                buttons(state)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { shown = service.signIn?.id }
        .onChange(of: service.signIn?.id) { _, id in
            if let id { shown = id } else { dismiss() }
        }
        // Closing the sheet any way ends Brim's own login child, the one
        // it showed and no other.
        .onDisappear {
            if let shown { service.cancelSignIn(runID: shown) }
        }
    }

    private func warning(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func buttons(_ state: ClaudeSignInState) -> some View {
        HStack {
            Spacer()
            if state.ended {
                Button(text.close) { service.cancelSignIn(runID: state.id) }.keyboardShortcut(.cancelAction)
                Button(text.tryAgain) { service.retrySignIn() }.keyboardShortcut(.defaultAction)
            } else {
                let copyFirst = state.window == .copyLink
                Button(copied != nil && copied == state.link ? text.copied : text.copyLink) {
                    service.copySignInLink()
                    copied = state.link
                }
                .disabled(state.link == nil)
                .keyboardShortcut(copyFirst ? .defaultAction : nil)
                Button(text.cancel) { service.cancelSignIn(runID: state.id) }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func step(_ number: Int, _ mark: Mark, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 10)
            symbol(mark).frame(width: 16)
            Text(label)
                .foregroundStyle(mark == .pending ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func symbol(_ mark: Mark) -> some View {
        switch mark {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .active: ProgressView().controlSize(.mini)
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .attention: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func firstText(_ state: ClaudeSignInState) -> String {
        switch state.window {
        case .opened(let browser)?: return text.stepOpened(browser)
        case .copyLink?: return text.stepCopyLink
        case nil: return text.stepOpening
        }
    }

    private func firstMark(_ state: ClaudeSignInState) -> Mark {
        switch state.window {
        case .opened?: return .done
        case .copyLink?: return .attention
        case nil: return state.ended ? .failed : .active
        }
    }

    private func secondMark(_ state: ClaudeSignInState) -> Mark {
        switch state.phase {
        case .waiting: return .pending
        case .signingIn: return .active
        case .wrongAccount: return .done
        case .failed: return state.window == nil ? .pending : .failed
        }
    }

    private func thirdMark(_ state: ClaudeSignInState) -> Mark {
        if case .wrongAccount = state.phase { return .failed }
        return .pending
    }

    private func message(_ state: ClaudeSignInState) -> String? {
        switch state.phase {
        case .wrongAccount(let held): return text.wrongAccount(signedInAs: held, expected: state.email)
        case .failed(let message): return message
        case .waiting, .signingIn: return nil
        }
    }
}

// MARK: - Window

/// The Claude accounts Settings in a window of their own, for the menu
/// panel's Set up…, Add account… and Sign in: they work without the Dynamic
/// Island, whose Settings page also embeds them.
@MainActor
enum ClaudeAccountsWindow {
    private static var window: NSWindow?
    /// Hands a start to the window's view while it stays up; userInfo
    /// `startKey` is the ClaudeAccountsSettings.Start.
    static let startRequest = Notification.Name("BrimClaudeAccountsWindowStart")
    static let startKey = "start"

    static func show(start: ClaudeAccountsSettings.Start? = nil) {
        if let window {
            // A new view would close a sheet that is up, and a sign-in's
            // sheet ends its sign-in as it closes (ClaudeAccountsAppSupport.windowShow).
            switch ClaudeAccountsAppSupport.windowShow(onScreen: window.isVisible || window.isMiniaturized,
                                                       sheetUp: window.attachedSheet != nil,
                                                       signingIn: ClaudeAccountsService.shared.signIn != nil) {
            case .keep:
                if let start { NotificationCenter.default.post(name: startRequest, object: nil, userInfo: [startKey: start]) }
            case .rebuild:
                window.contentViewController = NSHostingController(rootView: content(start: start))
            }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentViewController: NSHostingController(rootView: content(start: start)))
            window.title = FeatureStrings.claudeAccounts(L10n.shared.language).title
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func content(start: ClaudeAccountsSettings.Start?) -> some View {
        ScrollView {
            ClaudeAccountsSettings(start: start, takesWindowStarts: true)
                .padding(20)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 520, idealHeight: 680)
    }
}
