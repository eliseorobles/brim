// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

import AppKit
import SwiftUI

// The pieces the Memory section of the menu panel and its Settings page
// share. Sizes are footprint, never RSS. Ages are read when a scan publishes;
// nothing here runs a timer.

/// Pressure, used of total, the compressor against the 10 GB rule, swap,
/// and whether a test run is going.
struct MemoryHeaderView: View {
    let summary: MemorySummary
    let testRunActive: Bool
    let text: MemoryStrings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PressureIndicator(pressure: summary.pressure)
                if summary.total > 0 {
                    Text(text.usedOf(MemoryFormat.bytes(summary.used), MemoryFormat.bytes(summary.total)))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if testRunActive { MemoryChip(text.testRunInProgress, systemImage: "hammer", tint: .orange) }
            }
            HStack(spacing: 8) {
                Text(text.compressed(MemoryFormat.bytes(summary.compressed)))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .lineLimit(1)
                // The bar spans twice the limit, so the marker sits in the middle.
                UsageBar(fraction: Double(summary.compressed) / Double(MemoryRules.heavyWorkCompressedLimit * 2),
                         tint: summary.roomForHeavyWork ? PanelMetricColor.green(for: colorScheme) : .orange)
                    .overlay(alignment: .center) {
                        Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 1, height: 9)
                    }
                    .frame(minWidth: 60)
                MemoryChip(summary.roomForHeavyWork ? text.roomForHeavyWork : text.wait,
                           tint: summary.roomForHeavyWork ? PanelMetricColor.green(for: colorScheme) : .orange)
            }
            if summary.swapTotal > 0 || summary.swapUsed > 0 {
                Text(text.swap(MemoryFormat.bytes(summary.swapUsed), MemoryFormat.bytes(summary.swapTotal)))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// What the person should see before anything else: Brim cannot alert them
/// (notifications are off while they want alerts), and a runaway Brim ended
/// that they have not dismissed yet (T-52). Shown only when one applies.
struct MemoryNoticesView: View {
    @ObservedObject var service: MemoryService
    @ObservedObject var permissions: Permissions
    let text: MemoryStrings

    static func shows(_ service: MemoryService, _ permissions: Permissions) -> Bool {
        permissions.notifications.showsWarning(wantsAlerts: service.settings.notify)
            || MemoryRunawayNotice.unseen(service.log, seenThrough: service.runawaySeenThrough) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if permissions.notifications.showsWarning(wantsAlerts: service.settings.notify) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "bell.slash.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(text.notificationsOff).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                        Button(text.openNotificationSettings) { permissions.openNotificationSettings() }
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let entry = MemoryRunawayNotice.unseen(service.log, seenThrough: service.runawaySeenThrough) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    Text(text.logSentence(entry)).font(.system(size: 11)).lineLimit(2).truncationMode(.middle)
                    Text(entry.date, format: .dateTime.hour().minute())
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        service.dismissRunawayNotice()
                    } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.borderless)
                    .help(text.dismiss)
                }
            }
        }
    }
}

/// A small capsule of text: "parent gone 23 h", "idle", "389 MB".
struct MemoryChip: View {
    let label: String
    var systemImage: String?
    var tint: Color?

    init(_ label: String, systemImage: String? = nil, tint: Color? = nil) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 8, weight: .semibold)) }
            Text(label).lineLimit(1)
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill((tint ?? .secondary).opacity(0.13)))
    }
}

/// The lists: Biggest now (open by default while something grows or
/// fseventsd leaks), Leftovers (open by default), Heavy & idle apps,
/// Long-running helpers, Running now, Activity. Each is closed while empty.
struct MemoryListsView: View {
    @ObservedObject var service: MemoryService
    let text: MemoryStrings
    /// Rows shown per list in the panel; nil shows every row (Settings).
    var limit: Int?
    @State private var open: Set<String> = ["leftovers"]
    /// Lists the person opened past the panel's row limit ("Show N more").
    @State private var unlimited: Set<String> = []

    private var leftovers: [MemoryFinding] {
        service.findings.filter { [.autoLeftover, .leftover, .orphanedDevServer].contains($0.bucket) }
    }
    private var helpers: [MemoryFinding] { service.findings.filter { $0.bucket == .longRunningHelper } }
    private var running: [MemoryFinding] {
        service.findings.filter { $0.bucket == .runningNow || $0.bucket == .selfDaemonized }
    }
    /// Something is growing, or fseventsd leaks: the list opens by itself.
    private var holderAlert: Bool { service.holders.contains { $0.growing || $0.isFSEventsLeak } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            group("biggest", text.biggestNow, count: service.holders.count, size: nil) {
                rows("biggest", service.holders) { MemoryHolderRow(holder: $0, service: service, text: text) }
            }
            if service.notMeasuredSystem > 0, open.contains("biggest"), !service.holders.isEmpty {
                Text(text.notMeasuredSystem(service.notMeasuredSystem))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 14)
            }
            group("leftovers", text.leftovers, count: leftovers.count, size: leftovers.reduce(0) { $0 + $1.footprint }) {
                rows("leftovers", leftovers) { MemoryFindingRow(finding: $0, service: service, text: text) }
            }
            group("idle", text.heavyIdle, count: service.idleApps.count,
                  size: service.idleApps.reduce(0) { $0 + $1.app.footprint }) {
                rows("idle", service.idleApps) { MemoryIdleAppRowView(row: $0, service: service, text: text) }
            }
            group("helpers", text.helpers, count: helpers.count, size: helpers.reduce(0) { $0 + $1.footprint }) {
                rows("helpers", helpers) { MemoryFindingRow(finding: $0, service: service, text: text) }
            }
            group("running", text.runningNow, count: running.count, size: running.reduce(0) { $0 + $1.footprint }) {
                rows("running", running) { MemoryFindingRow(finding: $0, service: service, text: text) }
            }
            group("activity", text.activity, count: service.log.entries.count, size: nil) {
                rows("activity", service.log.entries) { MemoryLogRow(entry: $0, service: service, text: text) }
            }
        }
        .onAppear { if holderAlert { open.insert("biggest") } }
        .onChange(of: holderAlert) { _, alert in if alert { open.insert("biggest") } }
    }

    @ViewBuilder
    private func group<Content: View>(_ id: String, _ title: String, count: Int, size: UInt64?,
                                      @ViewBuilder content: () -> Content) -> some View {
        let expanded = count > 0 && open.contains(id)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if open.contains(id) { open.remove(id) } else { open.insert(id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Text("\(count)").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 0)
                    if let size, size > 0 {
                        Text(MemoryFormat.bytes(size)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            if id == "leftovers", count == 0 {
                Text(text.nothingToClean).font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.leading, 14)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 0) { content() }.panelCard(padded: false)
            }
        }
    }

    @ViewBuilder
    private func rows<Item: Identifiable, Row: View>(_ id: String, _ items: [Item],
                                                     @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        let shown = unlimited.contains(id) ? items : (limit.map { Array(items.prefix($0)) } ?? items)
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
            if index > 0 { Divider() }
            row(item)
        }
        if let limit, items.count > limit {
            Divider()
            Button {
                if unlimited.contains(id) { unlimited.remove(id) } else { unlimited.insert(id) }
            } label: {
                Text(unlimited.contains(id) ? text.showFewer : text.showMore(items.count - shown.count))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// A leftover, helper, or running-now row.
struct MemoryFindingRow: View {
    let finding: MemoryFinding
    @ObservedObject var service: MemoryService
    let text: MemoryStrings

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(MemoryFormat.title(name: finding.name, count: finding.count, project: finding.project))
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(MemoryFormat.size(finding.footprint, incomplete: finding.footprintIncomplete, unknown: text.unknownSize))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                chips
                if let note { Text(note).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contextMenu {
            Button(text.keep) { service.keep(finding.members.first?.executableName ?? finding.name) }
        }
    }

    private var chips: some View {
        let now = Date()
        var labels: [(String, Color?)] = []
        if let kind = finding.running { labels.append((label(kind), nil)) }
        if finding.bucket == .selfDaemonized { labels.append((text.backgroundServer, nil)) }
        if let since = finding.orphanedSince { labels.append((text.parentGone(MemoryFormat.duration(now.timeIntervalSince(since))), nil)) }
        for reason in finding.reasons {
            switch reason {
            case .idle: labels.append((text.idle, nil))
            case .busy: labels.append((text.busy, nil))
            case .measuring: labels.append((text.measuring, nil))
            case .noNetwork: labels.append((text.noNetwork, nil))
            case .unreadable: labels.append((text.unreadable, .orange))
            case .parentGone, .listening, .belowFloor, .powerAssertion: break
            }
        }
        if !finding.ports.isEmpty { labels.append((text.ports(finding.ports.map(String.init).joined(separator: ", ")), .blue)) }
        if finding.listensLocally { labels.append((text.localSocket, .blue)) }
        if finding.simulators > 0 { labels.append((text.simulators(finding.simulators), nil)) }
        if finding.bucket == .runningNow { labels.append((text.runningFor(MemoryFormat.duration(now.timeIntervalSince(finding.started))), nil)) }
        if let leftBy = finding.leftBy, !leftBy.isEmpty { labels.append((text.leftBy(leftBy), nil)) }
        // The automatic tier acts only while memory is tight; the chip says so.
        if service.settings.autoClean {
            if finding.bucket == .autoLeftover {
                labels.append(service.memoryTight ? (text.endsAutomatically, .orange) : (text.autoWhenTight, nil))
            } else if let at = finding.eligibleAt, service.memoryTight {
                labels.append((text.autoIn(MemoryFormat.duration(at.timeIntervalSince(now))), nil))
            }
        }
        return FlowChips(labels: labels)
    }

    private var note: String? {
        switch finding.helper {
        case .languageServer?: return finding.inUse ? text.languageServerInUse : text.languageServerIdle
        case .staleMCP?: return text.staleMCP
        case .simulatorClone?: return text.simulatorClone
        case nil: return nil
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let stuck = service.stillRunningEntry(for: finding) {
            Button(text.force) { service.force(stuck.id) }.controlSize(.small)
        } else if service.busy.contains(finding.id) {
            Text(text.ending).font(.system(size: 10)).foregroundStyle(.secondary)
        } else if finding.canEnd, !(finding.helper == .simulatorClone && service.testRunActive) {
            Button(finding.helper == .simulatorClone ? text.shutDown : text.end) { service.end(finding) }
                .controlSize(.small)
        }
    }

    private func label(_ kind: MemoryRunningKind) -> String {
        switch kind {
        case .testRun: return text.testRun
        case .devServer: return text.devServer
        case .agentSession: return text.agentSession
        case .service: return text.service
        case .powerAssertion: return text.keepingAwake
        case .audio: return text.playingAudio
        case .network: return text.networkInUse
        case .terminal: return text.inTerminal
        case .kept: return text.kept
        case .protectedTool: return text.protectedTool
        }
    }
}

/// A "Biggest now" row: what holds memory, own or system. Only the person's
/// own processes that pass `canEnd` get End; a system process never does.
struct MemoryHolderRow: View {
    let holder: MemoryHolder
    @ObservedObject var service: MemoryService
    let text: MemoryStrings

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(MemoryFormat.title(name: holder.name, count: 1, project: holder.project))
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(MemoryFormat.size(holder.memory, unknown: text.unknownSize))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                FlowChips(labels: chips)
                ForEach(notes, id: \.self) { note in
                    Text(note).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var chips: [(String, Color?)] {
        var labels: [(String, Color?)] = []
        if holder.isSystem { labels.append((text.systemProcess, nil)) }
        if let agent = holder.agent { labels.append((text.inSession(agent), nil)) }
        if case .coalitionTotal(_, let members) = holder.memory { labels.append((text.groupOf(members), nil)) }
        if holder.growing, let perHour = holder.perHour { labels.append((text.growing(MemoryFormat.rate(perHour)), .orange)) }
        if holder.isFSEvents, holder.bytes >= MemoryHolderThresholds().systemListFloor {
            labels.append((text.aboveNormal, .orange))
            labels.append((text.healthyFseventsd, nil))
        }
        return labels
    }

    private var notes: [String] {
        var lines: [String] = []
        if holder.isSystem { lines.append(text.systemNeverEnded) }
        guard holder.isFSEvents else { return lines }
        lines.append(text.fseventsdLeakNote)
        if let at = service.daemonEvidence.tableTooLargeAt {
            lines.append(text.tableTooLarge(at.formatted(date: .omitted, time: .shortened)))
        }
        let clients = service.daemonEvidence.slowClients.map { client in
            client.name.map { "\($0) (pid \(client.pid))" } ?? "pid \(client.pid)"
        }
        if !clients.isEmpty { lines.append(text.slowClients(clients.joined(separator: ", "))) }
        return lines
    }

    @ViewBuilder
    private var actions: some View {
        if holder.isFSEvents {
            Button {
                MemoryService.copyRestartCommand()
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help(text.copyRestartCommand)
        } else if service.busy.contains(MemoryService.busyKey(holder)) {
            Text(text.ending).font(.system(size: 10)).foregroundStyle(.secondary)
        } else if holder.canEnd {
            Button(text.end) { service.endHolder(holder) }.controlSize(.small)
        }
    }
}

/// Chips laid out on as many lines as they need.
private struct FlowChips: View {
    let labels: [(String, Color?)]

    var body: some View {
        if !labels.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { chips(labels) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) { chips(Array(labels.prefix((labels.count + 1) / 2))) }
                    HStack(spacing: 4) { chips(Array(labels.dropFirst((labels.count + 1) / 2))) }
                }
            }
        }
    }

    private func chips(_ items: [(String, Color?)]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in MemoryChip(item.0, tint: item.1) }
    }
}

struct MemoryIdleAppRowView: View {
    let row: MemoryIdleAppRow
    @ObservedObject var service: MemoryService
    let text: MemoryStrings

    var body: some View {
        HStack(spacing: 8) {
            if let url = row.app.bundleURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.app.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Text(text.unusedFor(MemoryFormat.duration(row.idleFor)))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(MemoryFormat.bytes(row.app.footprint)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            if row.quitting {
                Text(text.waitingToQuit).font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Button(text.quit) { service.quit(row) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contextMenu {
            if let bundleID = row.app.bundleID { Button(text.keep) { service.keep(bundleID) } }
        }
    }
}

struct MemoryLogRow: View {
    let entry: MemoryActivityEntry
    @ObservedObject var service: MemoryService
    let text: MemoryStrings

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(text.logKind(entry)).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(entry.kind == .runawayEnded || entry.kind == .alertNotShown ? .orange : .secondary)
                    // A missed alert keeps its words: two lines before it truncates.
                    Text(text.logTitle(entry)).font(.system(size: 11))
                        .lineLimit(entry.kind == .alertNotShown ? 2 : 1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text(entry.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                    if let outcome { Text(outcome) }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                if let change = entry.measuredChange {
                    Text(text.measuredChange(change))
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .help(text.measuredHelp)
                }
            }
            Spacer(minLength: 0)
            if entry.outcome == .stillRunning {
                Button(text.force) { service.force(entry.id) }.controlSize(.small)
            } else if entry.kind == .quitApp, entry.outcome == .done, entry.bundleURL != nil {
                Button(text.reopen) { service.reopen(entry.id) }.controlSize(.small)
            }
            if let command = entry.commands.first {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.shellLine(command), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help(text.copyCommand)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// The footprint read before the action is an estimate, never "freed";
    /// what the Mac measurably did is the line under it. A runaway's size is
    /// in its title; its line says whether SIGKILL was needed.
    private var outcome: String? {
        if entry.kind == .runawayEnded, entry.outcome == .done { return entry.forced == true ? text.runawayForced : nil }
        switch entry.outcome {
        case .done: return entry.estimatedBytes > 0 ? text.estimated(MemoryFormat.bytes(entry.estimatedBytes)) : nil
        case .stillRunning: return text.stillRunning
        case .failed: return text.failed
        case .pending: return entry.kind == .quitApp ? text.waitingToQuit : text.ending
        case .nothingToDo: return nil
        }
    }

    /// `cd 'dir' && 'arg' 'arg'`: the command, quoted for a shell, to start it again.
    static func shellLine(_ command: MemoryActivityEntry.Command) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let line = command.arguments.map(quote).joined(separator: " ")
        guard let directory = command.workingDirectory else { return line }
        return "cd \(quote(directory)) && \(line)"
    }
}

/// The menu panel's Memory section. It belongs to the Memory monitor
/// feature and needs no Dynamic Island.
struct MemoryPanelSection: View {
    var collapsible = true
    @ObservedObject private var service = MemoryService.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var l10n = L10n.shared

    private var text: MemoryStrings { FeatureStrings.memory(l10n.language) }

    var body: some View {
        PanelSection(.memory, title: text.title, collapsible: collapsible) {
            VStack(alignment: .leading, spacing: 8) {
                if MemoryNoticesView.shows(service, permissions) {
                    MemoryNoticesView(service: service, permissions: permissions, text: text).panelCard()
                }
                MemoryHeaderView(summary: service.summary, testRunActive: service.testRunActive, text: text)
                    .panelCard()
                MemoryListsView(service: service, text: text, limit: 5)
                HStack {
                    Spacer(minLength: 0)
                    Button(text.settingsLink) {
                        SettingsRouter.shared.page = .memory
                        appDelegate()?.openSettingsWindow()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            }
        }
        // Opening the panel is one of the events that scan. The popover keeps
        // its views between openings, so its notice counts too.
        .onAppear {
            service.syncWithPreferences()
            service.foreground()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuPanelWillShow)) { _ in service.foreground() }
    }
}

/// Settings → Memory: the same header and lists, then the module's settings
/// and what each tier does.
struct MemorySettingsView: View {
    @ObservedObject private var service = MemoryService.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.memoryAutoClean) private var autoClean = true
    @AppStorage(DefaultsKey.memoryIdleHours) private var idleHours = 8
    @AppStorage(DefaultsKey.memoryNotify) private var notify = true
    @State private var newKeep = ""

    private var text: MemoryStrings { FeatureStrings.memory(l10n.language) }

    var body: some View {
        Form {
            if MemoryNoticesView.shows(service, permissions) {
                Section { MemoryNoticesView(service: service, permissions: permissions, text: text) }
            }
            Section {
                MemoryHeaderView(summary: service.summary, testRunActive: service.testRunActive, text: text)
                MemoryListsView(service: service, text: text, limit: nil)
            }
            Section {
                Toggle(text.autoCleanTitle, isOn: $autoClean)
                Text(text.autoCleanHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Stepper(value: $idleHours, in: MemorySettings.idleHoursRange) {
                    HStack {
                        Text(text.idleAfterTitle)
                        Spacer()
                        Text(text.hours(MemorySettings.sanitizedIdleHours(idleHours))).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text(text.idleAfterHelp).font(.caption).foregroundStyle(.secondary)
                Toggle(text.notifyTitle, isOn: $notify)
                Text(text.notifyHelp).font(.caption).foregroundStyle(.secondary)
            }
            Section(text.keepTitle) {
                Text(text.keepHelp).font(.caption).foregroundStyle(.secondary)
                ForEach(service.settings.keep, id: \.self) { entry in
                    HStack {
                        Text(entry).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button {
                            service.removeFromKeep(entry)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(text.remove)
                    }
                }
                HStack {
                    TextField(text.keepPlaceholder, text: $newKeep)
                        .onSubmit(addKeep)
                    Button(text.add, action: addKeep).disabled(newKeep.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section(text.tiersTitle) {
                Label(text.tierInform, systemImage: "eye")
                Label(text.tierNotify, systemImage: "bell")
                Label(text.tierOneClick, systemImage: "hand.tap")
                Label(text.tierAutomatic, systemImage: "wand.and.stars")
                Label(text.tierRunaway, systemImage: "exclamationmark.octagon")
                if let cost = service.lastScan {
                    Text(text.lastScan(String(format: "%.2f", locale: MetricFormat.locale, cost.duration),
                                       cost.processes.formatted(.number.grouping(.automatic))))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .formStyle(.grouped)
        .onChange(of: autoClean) { _, _ in service.reloadSettings() }
        .onChange(of: idleHours) { _, _ in service.reloadSettings() }
        .onChange(of: notify) { _, _ in service.reloadSettings() }
        .onAppear {
            service.syncWithPreferences()
            service.foreground()
        }
    }

    private func addKeep() {
        service.keep(newKeep)
        newKeep = ""
    }
}
