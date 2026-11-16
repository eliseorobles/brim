// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import SwiftUI

/// The menu panel's Claude section: every signed-in account in ranking order
/// with its limits, then the accounts waiting for their sign-in, which
/// account new sessions use, and the ways to act on them. It
/// belongs to the AI agents feature and needs no Dynamic Island.
struct ClaudeAccountsPanelSection: View {
    var collapsible = true
    @ObservedObject private var service = ClaudeAccountsService.shared
    @ObservedObject private var l10n = L10n.shared

    private var text: ClaudeAccountsStrings { FeatureStrings.claudeAccounts(l10n.language) }

    var body: some View {
        PanelSection(.claude, title: text.title, collapsible: collapsible) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(service.settingsProblems, id: \.message) { problem in
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Claude Code's /resume on the other accounts cannot list these.
                ForEach(service.held) { conversation in
                    Label(text.held(conversation), systemImage: conversation.paused ? "pause.circle" : "lock")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !service.claudeFound {
                    Text(text.claudeMissing).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(service.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        if let row = item.row {
                            ClaudeAccountRowView(row: row, entry: item.entry, text: text,
                                                 failureText: FeatureStrings.notchAgents(l10n.language).claudeCode,
                                                 signIn: item.entry.flatMap { entry in
                                                     ClaudeAccountsAppSupport.offersSignIn(item)
                                                         ? { ClaudeAccountsWindow.show(start: .signIn(entry.id)) } : nil
                                                 })
                        } else if let entry = item.entry {
                            // Sign-ins run from the accounts window, whose sheet stays put.
                            ClaudeAccountEntryRowView(entry: entry, text: text) {
                                ClaudeAccountsWindow.show(start: .signIn(entry.id))
                            }
                        }
                    }
                }
                .panelCard(padded: false)
                ClaudeNewSessionsPicker(text: text)
                    .font(.system(size: 11))
                    .controlSize(.small)
                HStack(spacing: 10) {
                    Button(text.refreshAll) { service.refreshAll() }
                    Button(text.addAccount) { ClaudeAccountsWindow.show(start: .add) }
                        .disabled(service.signIn != nil)
                    Spacer(minLength: 0)
                    Button(text.setUp) { ClaudeAccountsWindow.show() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                Text(text.vscodeNote)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Opening the panel is one of the events that check stale accounts.
        // The popover keeps its views between openings, so its notice counts.
        .onAppear { service.foreground() }
        .onReceive(NotificationCenter.default.publisher(for: .menuPanelWillShow)) { _ in service.foreground() }
    }
}
