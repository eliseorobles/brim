// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import AppKit
import SwiftUI

/// MCP servers by repo: the repos on the left, the chosen one's servers on
/// the right, one switch each. Every change that runs Claude Code is shown
/// in full first (ClaudeReviewSheet); a switch writes at once and applies to
/// new sessions.
struct ClaudeMCPPage: View {
    @ObservedObject private var model = ClaudeMCPModel.shared
    @ObservedObject private var service = ClaudeAccountsService.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var search = ""
    @State private var sheet: Sheet?
    @State private var confirm: Confirm?

    private var text: ClaudeAccountsStrings { FeatureStrings.claudeAccounts(l10n.language) }

    private enum Sheet: Identifiable {
        case review(ClaudeReview)
        case add

        var id: String {
            switch self {
            case .review(let review): return "review-" + review.id.uuidString
            case .add: return "add"
            }
        }
    }

    private enum Confirm: Identifiable {
        case turnOn(ClaudeMCPEntry)
        case connectorsOn

        var id: String {
            switch self {
            case .turnOn(let entry): return "on-" + entry.id
            case .connectorsOn: return "connectors"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            repoColumn.frame(width: 250)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .review(let review): ClaudeReviewSheet(review: review, text: text)
            case .add: ClaudeMCPAddServerSheet(text: text) { review in self.sheet = .review(review) }
            }
        }
        .alert(item: $confirm) { confirm in
            Alert(title: Text(text.mcpTurnOnTitle), message: Text(text.mcpTurnOnBody),
                  primaryButton: .destructive(Text(text.mcpTurnOn.replacingOccurrences(of: "…", with: ""))) {
                      switch confirm {
                      case .turnOn(let entry): model.turnOnOutside(entry)
                      case .connectorsOn: model.turnOnOutsideConnectors()
                      }
                  },
                  secondaryButton: .cancel(Text(text.cancel)))
        }
    }

    // MARK: Repos

    private var shownRepos: [ClaudeMCPRepo] { ClaudeMCPRepoList.filter(model.snapshot.repos, search) }

    private var repoColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text.mcpReposTitle).font(.subheadline.weight(.medium)).padding(.horizontal, 12).padding(.top, 12)
            if model.snapshot.repos.count > 8 {
                TextField(text.mcpSearch, text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
            }
            if model.loaded && model.snapshot.repos.isEmpty {
                Text(text.mcpNoRepos).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                ForEach(shownRepos) { repo in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ClaudeMCPRepoList.name(repo.root, home: service.home)).lineLimit(1)
                        Text(service.shortFolder(repo.root))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(repo.root)
                    .tag(repo.root)
                }
            }
            .listStyle(.sidebar)
            HStack {
                Button(text.mcpAddRepo, action: chooseRepo)
                Spacer()
                if !model.loaded || model.busy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: service.home + "/Code")
        if panel.runModal() == .OK, let url = panel.url { model.addRepo(url.path) }
    }

    // MARK: The chosen repo

    @ViewBuilder private var detail: some View {
        if let servers = model.snapshot.servers, servers.root == model.selection {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(servers)
                    section(text.mcpRepoOnly, servers.group(.repo)) {
                        if !model.snapshot.repoMirror.isEmpty || !model.snapshot.repoMirror.conflicts.isEmpty {
                            Button(text.mcpCopyToAll) { sheet = .review(model.reviewRepoMirror()) }.disabled(model.busy)
                        }
                        Button(text.mcpAddServer) { sheet = .add }.disabled(model.busy)
                    }
                    section(text.mcpYourServers, servers.group(.user)) {
                        if model.snapshot.userBackups {
                            Button(text.undo) { sheet = .review(model.reviewUndoUserMirror()) }.disabled(model.busy)
                        }
                        if !model.snapshot.userMirror.isEmpty {
                            Button(text.mcpCopyToAll) { sheet = .review(model.reviewUserMirror()) }.disabled(model.busy)
                        }
                    }
                    section(text.mcpPlugins, servers.group(.plugin)) { EmptyView() }
                    connectors(servers)
                    footer
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack {
                Spacer()
                if model.loaded { Text(text.mcpPickRepo).foregroundStyle(.secondary) } else { ProgressView() }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func header(_ servers: ClaudeMCPRepoServers) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ClaudeMCPRepoList.name(servers.root, home: service.home)).font(.headline)
            Text(service.shortFolder(servers.root)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach([model.snapshot.stateProblem, servers.settingsProblem].compactMap { $0 }, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !servers.unreadable.isEmpty {
                Label(text.mcpLeftOut(servers.unreadable), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.notice {
                Label(notice.text, systemImage: notice.problem ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(notice.problem ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func section<Actions: View>(_ title: String, _ entries: [ClaudeMCPEntry],
                                        @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                actions().controlSize(.small)
            }
            if entries.isEmpty {
                Text(text.mcpNone).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                row(entry)
                if entry.id != entries.last?.id { Divider() }
            }
        }
    }

    private func connectors(_ servers: ClaudeMCPRepoServers) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text.mcpConnectors).font(.subheadline.weight(.medium))
            HStack(alignment: .firstTextBaseline) {
                Text(text.mcpAllConnectors).font(.system(size: 12, weight: .medium))
                Spacer()
                switch servers.connectors {
                case .outside(let removable):
                    Text(text.mcpOffOutside).font(.caption2).foregroundStyle(.secondary)
                        .help(removable ? "" : text.mcpOffOutsideHelp)
                    if removable { Button(text.mcpTurnOn) { confirm = .connectorsOn }.controlSize(.small) }
                default:
                    Toggle(text.mcpAllConnectors, isOn: Binding(get: { servers.connectors == .none },
                                                                 set: { model.setConnectors(on: $0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                        .disabled(!canSwitch(servers))
                }
            }
            Divider()
            if servers.group(.connector).isEmpty { Text(text.mcpNone).font(.caption).foregroundStyle(.secondary) }
            ForEach(servers.group(.connector)) { entry in
                row(entry)
                if entry.id != servers.group(.connector).last?.id { Divider() }
            }
        }
    }

    /// A switch writes the repo's settings.local.json and Brim's record:
    /// neither may be in a state Brim refuses to write.
    private func canSwitch(_ servers: ClaudeMCPRepoServers?) -> Bool {
        !model.busy && servers?.settingsProblem == nil && model.snapshot.stateProblem == nil
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text.mcpAppliesToNew)
            if model.snapshot.openHere > 0 { Text(text.mcpOpenHere(model.snapshot.openHere)) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    // MARK: One server

    private func row(_ entry: ClaudeMCPEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1).textSelection(.enabled)
                if let summary = entry.info?.summary, !summary.isEmpty {
                    Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                notes(entry)
            }
            Spacer(minLength: 8)
            control(entry)
            if entry.group == .repo, entry.source == .local {
                Menu {
                    Button(text.mcpRemove) { if let review = model.reviewRemove(entry) { sheet = .review(review) } }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.busy || model.snapshot.stateProblem != nil)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func control(_ entry: ClaudeMCPEntry) -> some View {
        if let hidden = entry.hidden {
            Text(describe(hidden)).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        } else if case .outside(let removable) = entry.deny {
            VStack(alignment: .trailing, spacing: 2) {
                Text(text.mcpOffOutside).font(.caption2).foregroundStyle(.secondary)
                    .help(removable ? "" : text.mcpOffOutsideHelp)
                if removable {
                    Button(text.mcpTurnOn) { confirm = .turnOn(entry) }.controlSize(.small).disabled(!canSwitch(model.snapshot.servers))
                }
            }
        } else {
            Toggle(entry.name, isOn: Binding(get: { entry.isOn }, set: { model.setSwitch(entry, on: $0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(!canSwitch(model.snapshot.servers))
        }
    }

    @ViewBuilder private func notes(_ entry: ClaudeMCPEntry) -> some View {
        let servers = model.snapshot.servers
        Group {
            if entry.isOn && !entry.toggledIn.isEmpty {
                HStack(spacing: 6) {
                    Text(text.mcpOffInAccount(some(entry.toggledIn))).foregroundStyle(.orange)
                    Button(text.mcpTurnOffAll) { model.turnOffEverywhere(entry) }
                        .buttonStyle(.link).disabled(!canSwitch(servers) || !entry.switchable)
                }
            }
            if entry.conflict { Text(text.mcpConflict).foregroundStyle(.orange) }
            if !entry.missingIn.isEmpty && !entry.conflict { Text(text.mcpMissing(entry.missingIn)).foregroundStyle(.secondary) }
            if entry.shadowed {
                Text(text.mcpShadowed).foregroundStyle(.secondary)
            } else if !entry.shadowedIn.isEmpty {
                Text(text.mcpShadowedIn(entry.shadowedIn)).foregroundStyle(.secondary)
            }
            if entry.sharesName { Text(text.mcpSharesName).foregroundStyle(.secondary) }
            accountNotes(entry)
        }
        .font(.caption2)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// What differs between accounts: where it is dropped, declined, not
    /// approved or waiting for a sign-in.
    @ViewBuilder private func accountNotes(_ entry: ClaudeMCPEntry) -> some View {
        Group {
            if entry.hidden == nil && !entry.hiddenIn.isEmpty { Text(text.mcpHiddenIn(entry.hiddenIn)).foregroundStyle(.secondary) }
            if entry.hidden == nil && !entry.declinedIn.isEmpty { Text(text.mcpDeclinedIn(entry.declinedIn)).foregroundStyle(.secondary) }
            if entry.hidden == nil && !entry.notApprovedIn.isEmpty {
                Text(text.mcpNotApprovedIn(entry.notApprovedIn)).foregroundStyle(.secondary)
            }
            if !entry.signInIn.isEmpty {
                Text(text.mcpNeedsLoginIn(some(entry.signInIn))).foregroundStyle(.secondary)
            }
            if entry.addedKind == ClaudeMCPStripe.kind { Text(text.mcpStripeSignIn).foregroundStyle(.secondary) }
            if !entry.untrustedIn.isEmpty { Text(text.mcpUntrusted(entry.untrustedIn)).foregroundStyle(.secondary) }
        }
        .font(.caption2)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The labels, or nil when they name every account Brim read.
    private func some(_ labels: [String]) -> [String]? {
        model.snapshot.servers.map { $0.some(labels) } ?? labels
    }

    private func describe(_ hidden: ClaudeMCPEntry.Hidden) -> String {
        switch hidden {
        case .repoHasItsOwn: return text.mcpHiddenRepo
        case .userHasSame: return text.mcpHiddenUser
        case .pluginOff: return text.mcpPluginOff
        case .connectorsOff: return text.mcpOffWithConnectors
        case .notApproved: return text.mcpNotApproved
        case .declined: return text.mcpDeclined
        }
    }
}

// MARK: - Add server…

/// Stripe (Stripe's hosted server, each account signing in with Stripe's own
/// OAuth), a server copied from another repo, or pasted JSON; Review… hands
/// the change to the page's review sheet.
struct ClaudeMCPAddServerSheet: View {
    let text: ClaudeAccountsStrings
    let review: (ClaudeReview) -> Void
    @ObservedObject private var model = ClaudeMCPModel.shared
    @ObservedObject private var service = ClaudeAccountsService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var kind = Kind.stripe
    @State private var nickname = ""
    @State private var copyID: String?
    @State private var name = ""
    @State private var json = ""
    @State private var tried = false

    private enum Kind: Hashable { case stripe, copy, paste }

    private var request: ClaudeMCPModel.AddRequest? {
        switch kind {
        case .stripe: return .stripe(nickname: nickname.trimmingCharacters(in: .whitespaces))
        case .copy: return model.snapshot.copySources.first { $0.id == copyID }.map(ClaudeMCPModel.AddRequest.copy)
        case .paste: return .paste(name: name.trimmingCharacters(in: .whitespaces), json: json)
        }
    }

    var body: some View {
        let problem = request.flatMap(model.problem)
        VStack(alignment: .leading, spacing: 12) {
            Text(text.mcpAddTitle(ClaudeMCPRepoList.name(model.selection ?? "", home: service.home))).font(.headline)
            Picker("", selection: $kind) {
                Text(text.mcpStripe).tag(Kind.stripe)
                Text(text.mcpCopy).tag(Kind.copy)
                Text(text.mcpPaste).tag(Kind.paste)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch kind {
            case .stripe: stripe
            case .copy: copy
            case .paste: paste
            }
            if tried || kind == .copy, let problem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(text.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(text.review) {
                    tried = true
                    guard let request, problem == nil, let next = model.reviewAdd(request) else { return }
                    review(next)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(request == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { copyID = model.snapshot.copySources.first?.id }
    }

    private var stripe: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(text.mcpNickname, text: $nickname).textFieldStyle(.roundedBorder)
            Text(nickname.isEmpty ? text.mcpNicknameHelp : text.mcpServerNamed(ClaudeMCPStripe.serverName(nickname: nickname)))
                .font(.caption).foregroundStyle(.secondary)
            Text(text.mcpStripeHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var copy: some View {
        if model.snapshot.copySources.isEmpty {
            Text(text.mcpCopyNone).font(.caption).foregroundStyle(.secondary)
        } else {
            Picker(text.mcpCopyServer, selection: $copyID) {
                ForEach(model.snapshot.copySources) { source in
                    Text(source.name + " · " + ClaudeMCPRepoList.name(source.repo, home: service.home)
                         + (source.info.summary.isEmpty ? "" : " · " + source.info.summary))
                        .tag(Optional(source.id))
                }
            }
        }
    }

    private var paste: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(text.mcpServerName, text: $name).textFieldStyle(.roundedBorder)
            Text(text.mcpServerJSON).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $json)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
        }
    }
}

// MARK: - Window

/// The MCP page in a window of its own, opened from the Setup row "MCP
/// servers" in Claude accounts. Its files are watched only while it is open.
@MainActor
enum ClaudeMCPWindow {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    static func show() {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ClaudeMCPPage()))
            window.title = FeatureStrings.claudeAccounts(L10n.shared.language).mcpTitle
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 900, height: 640))
            window.center()
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                   queue: .main) { _ in
                MainActor.assumeIsolated { ClaudeMCPModel.shared.disappear() }
            }
            window.makeKeyAndOrderFront(nil)
            self.window = window
        }
        ClaudeMCPModel.shared.appear()
        NSApp.activate(ignoringOtherApps: true)
    }
}
